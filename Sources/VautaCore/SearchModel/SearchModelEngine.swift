// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Dispatch
import Foundation
import Synchronization
internal import VautaMLX

/// What the engine needs from an encoder: one padded batch in, vectors out. The real one wraps `GemmaTextEncoder` (MLX); tests
/// use a fake. Not `Sendable`: it is owned by the engine actor.
protocol SearchEncoding: AnyObject {
    /// `dims` floats per input, L2-normalised, and which rows contain a NaN or infinity.
    func embedBatch(tokens: [[Int32]]) throws -> (vectors: [Float], nonFinite: [Bool])
}

/// Builds encoders. `fp32` is the slower, wider encoder used only to retry a row that produced a NaN in fp16.
struct SearchEncoderFactory: Sendable {
    var make: @Sendable (_ weights: URL, _ fp32: Bool) throws -> sending any SearchEncoding

    static let mlx = SearchEncoderFactory { weights, fp32 in
        MLXRuntime.configure()
        guard MLXRuntime.isSupported else { throw SearchModelError.unsupported }
        guard EncoderSelfTest.passed else { throw SearchModelError.selfTestFailed }
        return MLXSearchEncoder(try GemmaTextEncoder(url: weights, compute: fp32 ? .fp32 : .fp16))
    }
}

/// The reduced kernel self-test (the 17 checks of the encoder's ops, about 0.3 s warm), run once per process before the first
/// encoder is built. A failure means keyword search only; the full test is `Vauta mlx-selftest`.
enum EncoderSelfTest {
    private static let result = Mutex<Bool?>(nil)

    static var passed: Bool {
        if let known = result.withLock({ $0 }) { return known }
        let ok = KernelSelfTest.run(.encoder).ok
        result.withLock { $0 = ok }
        return ok
    }
}

private final class MLXSearchEncoder: SearchEncoding {
    private let encoder: GemmaTextEncoder
    init(_ encoder: GemmaTextEncoder) { self.encoder = encoder }

    func embedBatch(tokens: [[Int32]]) throws -> (vectors: [Float], nonFinite: [Bool]) {
        let batch = try encoder.embedBatch(tokens: tokens, matryoshka: SearchModelManifest.dimensions, padID: 0)
        return (batch.vectors, batch.nonFinite)
    }
}

/// How rows are grouped into batches: sorted by length, at most `maxRows` rows and `tokenBudget` padded tokens (rows times the
/// longest). The embedding-phase footprint peaks at about 1.15 GB with a budget of 1024 and costs no speed (spike 9c).
struct SearchBatchPlanner {
    static func plan(lengths: [Int], tokenBudget: Int, maxRows: Int) -> [[Int]] {
        let order = lengths.indices.sorted { lengths[$0] != lengths[$1] ? lengths[$0] < lengths[$1] : $0 < $1 }
        var batches: [[Int]] = []
        var s = 0
        while s < order.count {
            var e = s + 1
            while e < min(s + maxRows, order.count), (e - s + 1) * lengths[order[e]] <= tokenBudget { e += 1 }
            batches.append(Array(order[s..<e]))
            s = e
        }
        return batches
    }
}

/// Shrinks the batch budget when the process footprint grows and restores it after a calm period.
struct SearchFootprintGovernor: Sendable {
    var budget: Int
    let full: Int
    let minimum: Int
    let highMB: Int
    let lowMB: Int
    private var calmBatches = 0

    init(full: Int = 1024, minimum: Int = 256, highMB: Int = 1400, lowMB: Int = 900) {
        budget = full
        self.full = full
        self.minimum = minimum
        self.highMB = highMB
        self.lowMB = lowMB
    }

    /// Returns true when the caller should also free MLX's cache.
    mutating func observe(footprintMB: Int) -> Bool {
        if footprintMB > highMB {
            budget = max(minimum, budget / 2)
            calmBatches = 0
            return true
        }
        if footprintMB >= 0, footprintMB < lowMB {
            calmBatches += 1
            if calmBatches >= 20 { budget = full; calmBatches = 0 }
        } else {
            calmBatches = 0
        }
        return false
    }
}

public struct SearchEngineStats: Sendable, Equatable {
    public var batches = 0
    public var embedded = 0
    /// Rows that produced a NaN or infinity in fp16 and were run again in fp32.
    public var retriedInFP32 = 0
    /// Rows still not finite after the retry: skipped.
    public var skipped = 0
    /// Rows whose text was longer than the sequence limit (the tail was cut).
    public var truncated = 0
    public var currentBudget = 1024
}

/// Runs the search model: loads it on first use, embeds in batches under a footprint governor and unloads it after a quiet
/// period, on memory pressure or on request. MLX work runs on a utility-QoS serial queue, never on the cooperative pool.
public actor SearchModelEngine {
    private let queue = DispatchSerialQueue(label: "app.vauta.search-model", qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let store: SearchModelStore
    private let factory: SearchEncoderFactory
    private let footprint: @Sendable () -> Int
    private let clearCache: @Sendable () -> Void
    private let appBuild: String
    private let idleTimeout: Duration
    /// Every piece of GPU work (building the encoder with its kernel self-test, a batch, freeing MLX's cache) goes through this
    /// gate, shared with the language model: MLX has one stream and one device, and two queues must not encode on it at once.
    private let gate: MLXWorkGate
    /// Embeddings running or waiting: the model is not unloaded for being idle while there are any.
    private var inFlight = 0
    /// How long bulk embedding waits after a memory-pressure event before it loads the model again.
    private let pressureCooldown: Duration
    private let maxRows = 32

    private var tokenizer: GemmaTokenizer?
    private var encoder: (any SearchEncoding)?
    private var governor: SearchFootprintGovernor
    private var verifiedThisLaunch = false
    private var warmedUp = false
    private var idleTask: Task<Void, Never>?
    private var pressure: DispatchSourceMemoryPressure?
    private var stats = SearchEngineStats()
    private var onUnusable: (@Sendable (SearchModelError) -> Void)?
    private var lastPressure: ContinuousClock.Instant?
    #if DEBUG
    /// Tests: rows (by position in a batch) to treat as non-finite in fp16.
    var forceNonFiniteRows: Set<Int> = []
    var forceNonFiniteInFP32 = false
    #endif

    init(store: SearchModelStore, factory: SearchEncoderFactory = .mlx, appBuild: String = SearchModelDownloader.currentBuild,
         idleTimeout: Duration = .seconds(180), footprint: @escaping @Sendable () -> Int = { MLXRuntime.physFootprintMB() },
         clearCache: @escaping @Sendable () -> Void = { MLXRuntime.clearCache() }, pressureCooldown: Duration = .seconds(30),
         gate: MLXWorkGate = .shared) {
        self.store = store
        self.gate = gate
        self.pressureCooldown = pressureCooldown
        self.factory = factory
        self.appBuild = appBuild
        self.idleTimeout = idleTimeout
        self.footprint = footprint
        self.clearCache = clearCache
        governor = SearchFootprintGovernor()
    }

    /// Called when loading fails for a reason that makes the installed model unusable (a file that no longer matches, no GPU, a
    /// failed self-test).
    public func setUnusableHandler(_ handler: @escaping @Sendable (SearchModelError) -> Void) { onUnusable = handler }

    public var isLoaded: Bool { encoder != nil && tokenizer != nil }
    public var currentStats: SearchEngineStats {
        var s = stats
        s.currentBudget = governor.budget
        return s
    }

    #if DEBUG
    func setForcedNonFinite(rows: Set<Int>, inFP32: Bool = false) {
        forceNonFiniteRows = rows
        forceNonFiniteInFP32 = inFP32
    }
    #endif

    // MARK: Loading

    /// Verifies the files (the full check once per launch), loads the tokenizer and the encoder and warms the kernels up.
    public func prepare() async throws {
        inFlight += 1
        defer { inFlight -= 1 }
        try preload()
        // Building the encoder and the warm-up (the first run compiles the GPU kernels, about 2 s once per install or OS update)
        // are GPU work: under the gate.
        try await gate.run(.interactive) {
            try load()
            if !warmedUp {
                _ = try run(tokens: [tokenizer!.encode("warm up", prefix: SearchModelManifest.documentPrompt).ids])
                warmedUp = true
            }
        }
        armIdle()
    }

    /// Everything that needs no GPU: the tokenizer, and the weights file checked against its pins (the full hash once per launch).
    private func preload() throws {
        if encoder != nil, tokenizer != nil { return }
        do {
            try loadTokenizerOnly()
            try verifyWeights()
        } catch let error as SearchModelError {
            reportUnusable(error)
            throw error
        }
    }

    /// The tokenizer and the encoder, for embedding. Counting tokens (chunk planning) uses `loadTokenizer` only: no GPU.
    /// GPU work (the weights are evaluated and the kernels self-tested): call it only inside `gate.run`.
    private func load() throws {
        if encoder != nil, tokenizer != nil { return }
        do {
            try verifyWeights()
            try loadTokenizer()
            try buildEncoder()
        } catch let error as SearchModelError {
            reportUnusable(error)
            throw error
        }
    }

    /// Only the tokenizer: verified against its pinned hash and parsed. No GPU work, no weights in memory.
    private func loadTokenizerOnly() throws {
        if tokenizer != nil { return }
        do { try loadTokenizer() } catch let error as SearchModelError {
            reportUnusable(error)
            throw error
        }
    }

    private func reportUnusable(_ error: SearchModelError) {
        switch error {
        case .mismatch, .unsupported, .selfTestFailed, .tokenizerUnreadable: onUnusable?(error)
        default: break
        }
    }

    /// Size and SHA-256 of `tokenizer.json` (32 MB, about 20 ms), then the parse. A tokenizer that is not the pinned one would
    /// give other token ids and put vectors in the frozen space that do not belong there.
    private func loadTokenizer() throws {
        do { try SearchModelVerifier.verifyTokenizer(file: store.tokenizerURL, spec: store.spec) } catch SearchModelError.mismatch {
            throw SearchModelError.mismatch
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SearchModelError.tokenizerUnreadable
        }
        do { tokenizer = try GemmaTokenizer(tokenizerJSON: store.tokenizerURL) } catch { throw SearchModelError.tokenizerUnreadable }
    }

    /// Size, header and (once per launch) the full SHA-256 of the weights and the tokenizer. CPU and disk only.
    private func verifyWeights() throws {
        guard SearchModelVerifier.quickCheck(file: store.weightsURL, spec: store.spec),
              SearchModelVerifier.quickCheckTokenizer(file: store.tokenizerURL, spec: store.spec) else { throw SearchModelError.mismatch }
        if !verifiedThisLaunch {
            try SearchModelVerifier.fullVerify(file: store.weightsURL, spec: store.spec)
            verifiedThisLaunch = true
            if case .installed(var record) = store.disk(), record.verifiedByBuild != appBuild {
                record.verifiedByBuild = appBuild
                try? store.updateRecord(record)
            }
        }
    }

    /// Builds the encoder: evaluates all the weights and, once per process, runs the kernel self-test. Gate only.
    private func buildEncoder() throws {
        do { encoder = try factory.make(store.weightsURL, false) } catch let e as SearchModelError { tokenizer = nil; throw e } catch {
            tokenizer = nil
            throw SearchModelError.encoderFailed
        }
        watchMemoryPressure()
    }

    /// Drops the weights and the tokenizer and frees MLX's cache (under the gate, so it never runs beside another MLX job).
    public func unload() async {
        dropState()
        await clearCacheUnderGate()
    }

    private func dropState() {
        idleTask?.cancel()
        idleTask = nil
        pressure?.cancel()
        pressure = nil
        encoder = nil
        tokenizer = nil
        governor = SearchFootprintGovernor()
    }

    private func clearCacheUnderGate() async {
        let clear = clearCache
        try? await gate.run(.interactive) { clear() }
    }

    /// The system is short of memory: the weights go, and bulk embedding does not bring them back until the pressure has been quiet for
    /// the cooldown (a question reloads at once: it is one short batch the person is waiting for). When it does, it starts with the
    /// smallest batches.
    func memoryPressure() async {
        lastPressure = .now
        dropState()
        governor.budget = governor.minimum
        await clearCacheUnderGate()
    }

    /// Before a batch of bulk (document-purpose) embedding: waits while the last memory-pressure event is recent, so the model is not
    /// reloaded into a Mac that is still short of memory. Cancellable.
    private func waitOutPressure(_ purpose: EmbeddingPurpose) async throws {
        guard purpose == .document, encoder == nil else { return }
        while let at = lastPressure, ContinuousClock.now - at < pressureCooldown {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private func armIdle() {
        idleTask?.cancel()
        let timeout = idleTimeout
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() async {
        if inFlight == 0 { await unload() }
    }

    private func watchMemoryPressure() {
        pressure?.cancel()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        source.setEventHandler { [weak self] in
            Task { await self?.memoryPressure() }
        }
        source.resume()
        pressure = source
    }

    // MARK: Tokens

    /// The tokenizer (loaded on demand), for planning chunks. The caller may keep it for as long as it needs it.
    public func planningTokenizer() throws -> GemmaTokenizer {
        try loadTokenizerOnly()
        armIdle()
        return tokenizer!
    }

    /// The number of tokens of the text with its prompt, without bos and eos.
    public func tokenCounts(_ texts: [String], purpose: EmbeddingPurpose) throws -> [Int] {
        try loadTokenizerOnly()
        armIdle()
        let prompt = Self.prompt(purpose)
        return texts.map { tokenizer!.count($0, prefix: prompt) }
    }

    /// Tokens available for a text's own words: the sequence limit minus bos, eos and the prompt.
    public func bodyBudget(purpose: EmbeddingPurpose) throws -> Int {
        try loadTokenizerOnly()
        armIdle()
        return SearchModelManifest.maxSequence - 2 - tokenizer!.count("", prefix: Self.prompt(purpose))
    }

    static func prompt(_ purpose: EmbeddingPurpose) -> String {
        purpose == .query ? SearchModelManifest.queryPrompt : SearchModelManifest.documentPrompt
    }

    // MARK: Embedding

    /// True inside a task that embeds a document-style text for a question being answered now (the live gate re-scoring a passage): the
    /// batch then waits at interactive priority, not behind a running generation like bulk indexing.
    @TaskLocal public static var interactiveDocuments = false

    /// 256-dimensional, L2-normalised vectors in input order. A text that cannot be embedded (still not finite after the fp32
    /// retry) gives an empty vector. Cancellable between batches (a running batch cannot be interrupted).
    public func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        inFlight += 1
        defer { inFlight -= 1 }
        try await waitOutPressure(purpose)
        // Files and tokenizer here (no GPU); the encoder is built only inside the gate below.
        try preload()
        let prompt = Self.prompt(purpose)
        let encoded = texts.map { tokenizer!.encode($0, prefix: prompt, maxTokens: SearchModelManifest.maxSequence) }
        stats.truncated += encoded.filter(\.truncated).count
        let tokens = encoded.map(\.ids)
        var out = [[Float]](repeating: [], count: texts.count)
        var remaining = Array(tokens.indices)
        while !remaining.isEmpty {
            try Task.checkCancellation()
            // The budget can change after every batch, so what is left is planned again (shortest rows first).
            let plan = SearchBatchPlanner.plan(lengths: remaining.map { tokens[$0].count }, tokenBudget: governor.budget, maxRows: maxRows)
            let batch = plan[0].map { remaining[$0] }
            // Memory pressure can unload the model between two batches: bulk embedding waits for the pressure to pass, then loads it
            // again (a few hundred milliseconds); a question loads it at once.
            try await waitOutPressure(purpose)
            // One GPU job at a time across both MLX models: a question goes first, bulk embedding waits for a generation.
            let batchTokens = batch.map { tokens[$0] }
            let vectors = try await gate.run(purpose == .document && !Self.interactiveDocuments ? .bulk : .interactive) {
                // The model may have been unloaded while this waited for the gate (memory pressure), or never built: build it, then run.
                try load()
                let vectors = try run(tokens: batchTokens)
                if governor.observe(footprintMB: footprint()) { clearCache() }
                return vectors
            }
            for (row, index) in batch.enumerated() { out[index] = vectors[row] }
            let done = Set(batch)
            remaining.removeAll { done.contains($0) }
            await Task.yield()
        }
        armIdle()
        return out
    }

    /// One batch: fp16, then the rows that were not finite one by one in fp32 (the wide encoder is built once for the batch).
    private func run(tokens: [[Int32]]) throws -> [[Float]] {
        guard let encoder else { throw SearchModelError.encoderFailed }
        let dims = SearchModelManifest.dimensions
        let result: (vectors: [Float], nonFinite: [Bool])
        do { result = try encoder.embedBatch(tokens: tokens) } catch { throw SearchModelError.encoderFailed }
        guard result.vectors.count == tokens.count * dims, result.nonFinite.count == tokens.count else { throw SearchModelError.encoderFailed }
        stats.batches += 1
        var out = [[Float]](repeating: [], count: tokens.count)
        var flagged: [Int] = []
        for row in 0..<tokens.count {
            if result.nonFinite[row] || forcedNonFinite(row) {
                flagged.append(row)
            } else {
                out[row] = Array(result.vectors[row * dims..<(row + 1) * dims])
                stats.embedded += 1
            }
        }
        if !flagged.isEmpty {
            let wide = retryInFP32(flagged.map { tokens[$0] })
            for (i, row) in flagged.enumerated() { out[row] = wide[i] }
        }
        return out
    }

    private func forcedNonFinite(_ row: Int) -> Bool {
        #if DEBUG
        forceNonFiniteRows.contains(row)
        #else
        false
        #endif
    }

    private var forcedNonFiniteInFP32: Bool {
        #if DEBUG
        forceNonFiniteInFP32
        #else
        false
        #endif
    }

    /// Runs the flagged rows one at a time in fp32 and frees the wide encoder (760 MB) right after. A row that is still not
    /// finite, or all of them when the wide encoder cannot be built, gives an empty vector.
    private func retryInFP32(_ rows: [[Int32]]) -> [[Float]] {
        stats.retriedInFP32 += rows.count
        var wide: (any SearchEncoding)?
        wide = try? factory.make(store.weightsURL, true)
        defer {
            wide = nil
            clearCache()
        }
        var out: [[Float]] = []
        for tokens in rows {
            if let encoder = wide, let r = try? encoder.embedBatch(tokens: [tokens]), r.nonFinite.first == false, !forcedNonFiniteInFP32 {
                stats.embedded += 1
                out.append(r.vectors)
            } else {
                stats.skipped += 1
                out.append([])
            }
        }
        return out
    }
}
