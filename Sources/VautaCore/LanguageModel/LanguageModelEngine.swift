// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Dispatch
import Foundation
import Synchronization
internal import VautaMLX

/// How the next token is chosen: greedy, or sampled with a seed (the model card's settings by default).
public struct DecodingSettings: Sendable, Equatable {
    public var temperature: Float
    public var topK: Int
    public var topP: Float
    public var seed: UInt64
    public init(temperature: Float = 0, topK: Int = 64, topP: Float = 0.95, seed: UInt64 = 0) {
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.seed = seed
    }
    public static let greedy = DecodingSettings()
    /// Temperature 1.0, top-k 64, top-p 0.95 (the model's generation config).
    public static func card(seed: UInt64) -> DecodingSettings { DecodingSettings(temperature: 1.0, topK: 64, topP: 0.95, seed: seed) }
}

/// What the next token may be, from a grammar: any token, exactly one, or a set (bit `i` of word `i / 64` is token `i`).
public enum TokenMask: Sendable {
    case free
    case forced(Int32)
    /// Several tokens that are the only valid continuation: written without asking the model, then the model goes on.
    case forcedSequence([Int32])
    case allowed([UInt64])
}

/// How to end a constrained output early, as valid text.
public enum ConstraintClosing: Sendable, Equatable {
    /// Tokens (possibly none) that complete the value in the fewest bytes.
    case tokens([Int32])
    /// In the middle of a character or an escape: a few more tokens from the model come first.
    case notYet
    /// The constraint cannot close a value early.
    case unsupported
}

/// A grammar that constrains decoding (see `SchemaGrammar`).
public protocol OutputConstraint: AnyObject, Sendable {
    func nextMask() -> TokenMask
    func accept(_ token: Int32)
    /// The shortest valid ending from the current state.
    func closing() -> ConstraintClosing
}

public extension OutputConstraint {
    func closing() -> ConstraintClosing { .unsupported }
}

private final class ConstraintAdapter: LogitConstraint, @unchecked Sendable {
    let inner: any OutputConstraint
    init(_ inner: any OutputConstraint) { self.inner = inner }
    func nextMask() -> LogitMask {
        switch inner.nextMask() {
        case .free: .free
        case .forced(let t): .forced(t)
        case .forcedSequence(let t): .forcedSequence(t)
        case .allowed(let b): .allowed(b)
        }
    }
    func accept(_ token: Int32) { inner.accept(token) }
    func closing() -> LogitClosing {
        switch inner.closing() {
        case .tokens(let t): .tokens(t)
        case .notYet: .notYet
        case .unsupported: .unsupported
        }
    }
}

/// What one generation produced, with the measurements the evaluation and the guards need.
public struct LanguageModelOutput: Sendable {
    public var text: String
    public var tokens: [Int32]
    public var promptTokens: Int
    public var reusedTokens: Int
    public var finish: String
    public var prefillSeconds: Double
    /// From the start of the engine's own generation (after the model is loaded, the prompt tokenised and the lease taken).
    public var firstTokenSeconds: Double
    /// From the entry of `LanguageModelEngine.generate`: includes the load check, tokenisation, the wait for the slot and the
    /// gate, and prefill. nil when no token was produced.
    public var firstTokenSinceCallSeconds: Double?
    public var decodeSeconds: Double
    public var peakFootprintMB: Int
    public var maskUploadSeconds: Double = 0
    /// Where the time went before the first token (see `LatencyBreakdown`).
    public var tokenizeSeconds: Double = 0
    public var slotWaitSeconds: Double = 0
    public var gateWaitSeconds: Double = 0
    public var prefillChunks: Int = 0
    /// The longest stretches between two checkpoints, reading the prompt and decoding (`GenerationResult`).
    public var longestChunkSeconds: Double = 0
    public var longestBurstSeconds: Double = 0
}

/// A running generation was asked to give way to a more urgent one that needs the same kept prefix (live notes and the incremental
/// reading step aside for an answer, and try again on their next turn).
public struct GenerationPreempted: Error, Sendable {}

/// Why the language model cannot be used.
public enum LanguageModelUnavailableReason: String, Sendable, Equatable {
    case unsupportedHardware, selfTestFailed, verificationFailed, tokenizerUnreadable
}

/// Runs the integrated language model: loads it on first use (full verification once per launch), generates under the shared
/// `MLXWorkGate`, keeps one prefix state per purpose (Ask and live notes), and unloads after a quiet period, on critical memory
/// pressure or on request. MLX work runs on a utility-QoS serial queue, never on the cooperative pool. Every piece of GPU work,
/// load and kernel self-test included, goes through the gate; a generation takes it per prefill chunk and per decode burst
/// (`GenerationLease`), so a search embedding or a more urgent generation runs between two of them, and minutes and bulk work
/// wait out a hot Mac without holding it.
public actor LanguageModelEngine {
    private let queue = DispatchSerialQueue(label: "app.vauta.language-model", qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private let pressureQueue = DispatchQueue(label: "app.vauta.language-model.pressure", qos: .utility)

    private let store: LanguageModelStore
    private let idleTimeout: Duration
    private let gate: MLXWorkGate
    private let thermal: ThermalSource
    private var engine: Gemma4Engine?
    private var tokenizer: GemmaTokenizer?
    private var template: GemmaChatTemplate?
    private var verifiedThisLaunch = false
    /// The files failed their check: nothing is hashed again until `reset()`, and the owner of the engine is told once.
    private var damaged = false
    private var onDamaged: (@Sendable () -> Void)?
    private var idleTask: Task<Void, Never>?
    private var askDropTask: Task<Void, Never>?
    private var pressure: DispatchSourceMemoryPressure?
    private var keepWarm = false
    /// The meeting's prefix is kept after a recording stops, until its minutes are written (or `pinTimeout`): the minutes read only
    /// what came after it. Nothing else drops it while pinned.
    private var meetingPinned = false
    private var pinTask: Task<Void, Never>?
    static let pinTimeout: Duration = .seconds(15 * 60)
    /// The Mac warned about memory: no new reading of a meeting starts until this time.
    private var warmingPausedUntil: Date?
    private let physicalMemory: UInt64
    /// Generations running or waiting: the model is never unloaded for being idle while there are any.
    private var inFlight = 0
    /// Counts unloads: a generation that began before one stops at its next checkpoint instead of holding the weights.
    private(set) var epoch = 0
    /// One load at a time (a second caller waits for the first and finds the model loaded).
    private let loadLock = MLXWorkGate()
    /// One generation at a time per kept prefix: the slot's caches are one set of buffers.
    private let slotLocks: [PrefixSlot: MLXWorkGate] = [.ask: MLXWorkGate(), .meeting: MLXWorkGate()]

    public init(store: LanguageModelStore, idleTimeout: Duration = .seconds(300), gate: MLXWorkGate = .shared,
                thermal: ThermalSource = .system, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                onDamaged: (@Sendable () -> Void)? = nil) {
        self.physicalMemory = physicalMemory
        self.store = store
        self.idleTimeout = idleTimeout
        self.gate = gate
        self.thermal = thermal
        self.onDamaged = onDamaged
    }

    /// Where the files are: identifies the store this engine serves.
    nonisolated var root: URL { store.root }

    public var isLoaded: Bool { engine != nil }
    public var isDamaged: Bool { damaged }

    /// Runs prefill in chunks of `n` tokens, ending at the multiples of `n` (nil = `Gemma4Engine.prefillChunk`, as in the app). The
    /// parity check against mlx-lm's goldens uses 512, the chunking they were made with.
    public func setPrefillChunk(_ n: Int?) {
        fixedChunk = n
        engine?.fixedChunk = n
    }
    private var fixedChunk: Int?

    /// Forgets a damaged verdict (the files were replaced).
    public func reset() { damaged = false; verifiedThisLaunch = false }

    /// While recording, the model stays loaded so a live answer is fast (`LanguageModelAccess.setRecording` calls this from the
    /// recorder's lifecycle). Turning it off lets the idle timer unload the model. It does not pin the meeting's prefix: only the
    /// service that read the meeting knows the minutes will use it, so it pins (`pinMeetingPrefix`) and unpins it itself.
    public func setKeepWarm(_ on: Bool) {
        keepWarm = on
        if on {
            idleTask?.cancel()
            idleTask = nil
        } else {
            if engine != nil, inFlight == 0 { armIdle() }
        }
    }

    /// Keeps the meeting's prefix until `unpinMeetingPrefix()` (the minutes of that meeting are written) or 15 minutes.
    public func pinMeetingPrefix() {
        meetingPinned = true
        pinTask?.cancel()
        pinTask = Task { [weak self] in
            try? await Task.sleep(for: Self.pinTimeout)
            guard !Task.isCancelled else { return }
            await self?.unpinMeetingPrefix()
        }
    }

    /// Forgets the transcripts the engine keeps in memory (both prefixes by default) and, with the meeting's, its pin: a meeting was
    /// deleted or all of them were erased. A slot that is not listed (another meeting's, still recorded) is left alone.
    public func dropKeptTranscripts(_ slots: Set<KeptSlot> = [.meeting, .ask]) {
        if slots.contains(.meeting) {
            meetingPinned = false
            pinTask?.cancel()
            pinTask = nil
            engine?.dropKeptPrefix(.meeting)
        }
        if slots.contains(.ask) { engine?.dropKeptPrefix(.ask) }
    }

    /// The normal idle rules apply again to the meeting's prefix.
    public func unpinMeetingPrefix() {
        meetingPinned = false
        pinTask?.cancel()
        pinTask = nil
        if inFlight == 0, !keepWarm { armAskDrop() }
    }

    public var isMeetingPinned: Bool { meetingPinned }

    public var isKeptWarm: Bool { keepWarm }

    /// Memory held by the kept prefixes (caches and checkpoints), for the footprint guard and the evaluation.
    public var keptCacheBytes: Int { engine?.cacheBytes ?? 0 }
    func keptPrefixTokens(_ slot: PrefixSlot) -> Int { engine?.keptPrefixTokens(slot) ?? 0 }
    public func keptMeetingTokens() -> Int { engine?.keptPrefixTokens(.meeting) ?? 0 }
    public func keptMeetingBytes() -> Int { engine?.cacheBytes(.meeting) ?? 0 }
    public func keptAskTokens() -> Int { engine?.keptPrefixTokens(.ask) ?? 0 }
    /// Tokens per second the engine read prompts at, smoothed; nil before it read anything.
    public func readingRate() -> Double? { engine?.measuredPrefillRate }

    /// Kept prefixes are memory: with the search model's bulk embedding and a minutes job on top they must fit the 6 GB budget. A job
    /// that keeps nothing (notes) runs when the kept state is at most `minutesBudget`; a job with a prefix of its own leaves
    /// the other prefix only while both fit in the total budget: 1.5 GiB, and 1 GiB on a Mac with 16 GB, where the meeting's prefix
    /// may take 768 MiB of it.
    static let minutesBudget = 512 << 20
    static let totalBudget = 1536 << 20
    static let smallMacTotalBudget = 1024 << 20
    static let smallMacMeetingBudget = 768 << 20
    /// A Mac of 16 GB (the smallest the model runs on) reports a little under 17 GiB.
    static func isSmallMac(_ physicalMemory: UInt64) -> Bool { physicalMemory <= 17 << 30 }
    public var totalKeptBudget: Int { Self.isSmallMac(physicalMemory) ? Self.smallMacTotalBudget : Self.totalBudget }
    /// The most the meeting's prefix may hold: the incremental reading stops extending it there.
    public var meetingPrefixBudget: Int { Self.isSmallMac(physicalMemory) ? Self.smallMacMeetingBudget : Self.totalBudget }

    /// The tokenizer (loaded with the model), for budgets and the evaluation.
    public func loadedTokenizer() throws -> GemmaTokenizer {
        if let tokenizer { return tokenizer }
        guard LanguageModelVerifier.quickCheckTokenizer(file: store.tokenizerURL, spec: store.spec) else { throw IntegratedModelError.tokenizerUnreadable }
        do {
            try LanguageModelVerifier.verifyTokenizer(file: store.tokenizerURL, spec: store.spec)
            let t = try GemmaTokenizer(tokenizerJSON: store.tokenizerURL)
            tokenizer = t
            template = GemmaChatTemplate(tokenizer: t)
            return t
        } catch { throw IntegratedModelError.tokenizerUnreadable }
    }

    private func markDamaged() {
        guard !damaged else { return }
        damaged = true
        onDamaged?()
    }

    /// Loads the model: hardware gate, kernel self-test, file verification, tokenizer, weights. The GPU work (self-test, weights)
    /// runs under the gate; hashing the files does not need it.
    public func load() async throws {
        if engine != nil { return }
        if damaged { throw IntegratedModelError.mismatch }
        try await loadLock.run(.interactive) {
            if engine != nil { return }
            MLXRuntime.configure()
            if let refusal = LanguageModelGate.refusal(gpuSupported: MLXRuntime.isSupported) { throw IntegratedModelError.unsupported(refusal) }
            guard MLXRuntime.recommendedWorkingSetBytes >= 8 << 30 else { throw IntegratedModelError.unsupported("The GPU can use less than 8 GB of memory.") }
            guard LanguageModelVerifier.quickCheck(file: store.weightsURL, spec: store.spec) else {
                markDamaged()
                throw IntegratedModelError.mismatch
            }
            if !verifiedThisLaunch {
                do { try LanguageModelVerifier.fullVerify(file: store.weightsURL, spec: store.spec) } catch {
                    markDamaged()
                    throw IntegratedModelError.mismatch
                }
                verifiedThisLaunch = true
            }
            let tokenizer: GemmaTokenizer
            do { tokenizer = try loadedTokenizer() } catch {
                markDamaged()
                throw error
            }
            // The token index of the grammars (about 2 s on the 262k-token vocabulary) is built while the weights load and the first
            // prompt is read, not before its first token: a constraint made meanwhile waits for this one.
            Task.detached(priority: .utility) { _ = TokenIndexCache.shared.index(for: tokenizer) }
            let url = store.weightsURL
            try await gate.run(.interactive) {
                guard LanguageModelKernelCheck.passed else { throw IntegratedModelError.unsupported("The GPU self-test failed.") }
                do { engine = try Gemma4Engine(url: url) } catch { throw IntegratedModelError.engineFailed("The model could not be loaded.") }
                engine?.fixedChunk = fixedChunk
                MLXRuntime.setCacheLimit(for: .languageModel)
            }
            watchMemoryPressure()
            if !keepWarm { armIdle() }
        }
    }

    /// Drops the weights and the kept prefixes. The allocator's limits and cache are changed under the gate, so they never change
    /// while the search model's encoder (or a generation, which stops at its next checkpoint) is running.
    ///
    /// `keepingTokenizer`: unloaded for being idle, the tokenizer, its chat template and its token index (about 2 s to build, tens of
    /// MB) stay, so the next question after a quiet spell does not build them again. Memory pressure and an unload asked for (the model
    /// deleted or replaced) drop them too.
    public func unload(keepingTokenizer: Bool = false) async {
        dropState(keepingTokenizer: keepingTokenizer)
        let gate = gate
        try? await gate.run(.interactive) {
            MLXRuntime.setCacheLimit(for: .encoderOnly)
            MLXRuntime.clearCache()
        }
    }

    private func dropState(keepingTokenizer: Bool = false) {
        askDropTask?.cancel()
        askDropTask = nil
        idleTask?.cancel()
        idleTask = nil
        pressure?.cancel()
        pressure = nil
        engine = nil
        epoch += 1
        guard !keepingTokenizer else { return }
        tokenizer = nil
        template = nil
        TokenIndexCache.shared.clear()
    }

    func memoryPressure() async { await unload() }

    /// A memory warning (below critical): the Ask prefix goes and the incremental reading of the meeting pauses for a while.
    func memoryWarning() {
        engine?.dropKeptPrefix(.ask)
        warmingPausedUntil = Date().addingTimeInterval(300)
    }

    var isWarmingPaused: Bool { warmingPausedUntil.map { $0 > Date() } ?? false }

    /// The idle timer fired. While a recording keeps the model warm it never unloads for being idle (memory pressure still does).
    func unloadIfIdle() async {
        guard !keepWarm else { return }
        if inFlight == 0 { await unload(keepingTokenizer: true) } else { armIdle() }
    }

    private func begin() { inFlight += 1; idleTask?.cancel(); askDropTask?.cancel() }
    private func end() {
        inFlight -= 1
        guard inFlight == 0, engine != nil else { return }
        if !keepWarm { armIdle() }
        armAskDrop()
    }

    /// The Ask prefix is dropped after a quiet period even while the model is kept warm for a recording.
    private func armAskDrop() {
        askDropTask?.cancel()
        let timeout = idleTimeout
        askDropTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.dropAskIfIdle()
        }
    }

    private func dropAskIfIdle() {
        guard inFlight == 0 else { return }
        engine?.dropKeptPrefix(.ask)
        // The meeting's prefix stays while it is recorded or pinned for the minutes; otherwise it is idle like the rest.
        if !keepWarm, !meetingPinned { engine?.dropKeptPrefix(.meeting) }
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

    /// The pressure source has a queue of its own: a generation never delays it. The unload itself runs on the actor at the next
    /// checkpoint (at most one prefill chunk or decode burst later) and the running generation stops there.
    private func watchMemoryPressure() {
        pressure?.cancel()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: pressureQueue)
        source.setEventHandler { [weak self, weak source] in
            let critical = source?.data.contains(.critical) ?? false
            Task { if critical { await self?.memoryPressure() } else { await self?.memoryWarning() } }
        }
        source.resume()
        pressure = source
    }

    /// A constraint for `schema`, built with the loaded tokenizer (the string tables are shared between calls).
    public func constraint(for schema: OutputSchema) throws -> SchemaConstraint {
        SchemaConstraint(schema: schema, tokenizer: try loadedTokenizer())
    }

    /// Token ids of a chat prompt and the length of its shareable prefix.
    public func promptIDs(_ messages: [ChatMessage]) throws -> (ids: [Int32], prefixLength: Int) {
        _ = try loadedTokenizer()
        return template!.ids(messages)
    }

    /// The kept prefix a call uses when it does not name one: live work and the minutes belong to the meeting, an answer to Ask.
    static func slot(for priority: MLXWorkGate.Priority) -> PrefixSlot {
        switch priority {
        case .interactive: .ask
        case .live, .warm, .minutes, .autoAnswer: .meeting
        case .bulk, .brief: .ask
        }
    }

    static func prefixSlot(_ kept: KeptSlot?, priority: MLXWorkGate.Priority) -> PrefixSlot {
        switch kept {
        case .meeting?: .meeting
        case .ask?: .ask
        case nil: slot(for: priority)
        }
    }

    /// How much kept state a request leaves in memory before it runs, and which slot it never drops. A call that keeps a prefix leaves
    /// the other one while both fit in the total budget (the Ask prefix is dropped first). A call that keeps nothing (a note
    /// expansion, bulk work) trims to `minutesBudget`, but never the meeting's prefix while it is recorded or pinned for its minutes:
    /// a 50 to 60 minute meeting needs more than 512 MiB of it and costs minutes to read again. The same holds for a call that keeps the
    /// Ask prefix while the meeting's is protected.
    static func trimPolicy(keepsPrefix: Bool, priority: MLXWorkGate.Priority, slot: PrefixSlot, meetingProtected: Bool = false,
                           totalBudget: Int = LanguageModelEngine.totalBudget) -> (budget: Int, keeping: PrefixSlot?) {
        // A question about a past meeting during a recording (or before its minutes) must not push the live meeting's prefix out: when
        // the kept memory is over budget, the Ask slot's old content goes instead, even though this call keeps that slot.
        if keepsPrefix { return (totalBudget, meetingProtected && slot == .ask ? .meeting : slot) }
        switch priority {
        case .minutes, .bulk, .warm, .brief: return (minutesBudget, meetingProtected ? .meeting : nil)
        case .live, .autoAnswer: return (totalBudget, .meeting)
        case .interactive: return (totalBudget, .ask)
        }
    }

    /// Where a request waited before it ran, for the evaluation's breakdown.
    private struct Waits { var slot = 0.0, gate = 0.0 }

    /// Runs one request: the slot's lock, then the lease on the gate, then the engine.
    private func run(_ request: GenerationRequest, constraint: (any LogitConstraint)?, priority: MLXWorkGate.Priority,
                     onToken: (@Sendable (Int32) -> Void)?) async throws -> (GenerationResult, Waits) {
        guard let engine else { throw IntegratedModelError.engineFailed("The model is not loaded.") }
        let startEpoch = epoch
        let trim = Self.trimPolicy(keepsPrefix: request.sharedPrefix != nil, priority: priority, slot: request.slot,
                                   meetingProtected: keepWarm || meetingPinned, totalBudget: totalKeptBudget)
        engine.enforceBudget(trim.budget, keeping: trim.keeping)
        let lock = request.sharedPrefix != nil ? slotLocks[request.slot] : nil
        let waits = Mutex(Waits())
        let entered = Date()
        let body: () async throws -> GenerationResult = {
            waits.withLock { $0.slot = Date().timeIntervalSince(entered) }
            let lease = GenerationLease(gate: self.gate, priority: priority, thermal: self.thermal)
            let gateStart = Date()
            try await lease.begin()
            waits.withLock { $0.gate = Date().timeIntervalSince(gateStart) }
            defer { lease.end() }
            return try await engine.generate(request, constraint: constraint, onToken: onToken, checkpoint: {
                // Unloaded meanwhile (memory pressure, delete): stop and let go of the weights.
                if self.epoch != startEpoch { throw IntegratedModelError.engineFailed("The model was unloaded.") }
                // Live notes (and the reading of the meeting) step aside for a more urgent call that waits for this prefix.
                if priority == .live || priority == .warm, let lock, lock.hasWaiter(above: priority) { throw GenerationPreempted() }
                try await lease.checkpoint()
            })
        }
        let result: GenerationResult
        if let lock { result = try await lock.run(priority, body) } else { result = try await body() }
        return (result, waits.withLock { $0 })
    }

    /// Generates a reply. `sharedPrefix` keeps the state of everything before the last message for the next call, in `slot` (by
    /// priority when nil).
    public func generate(_ messages: [ChatMessage], maxTokens: Int, sampling: DecodingSettings, constraint: (any OutputConstraint)? = nil,
                         priority: MLXWorkGate.Priority = .interactive, sharedPrefix: Bool = false, slot: KeptSlot? = nil, maxDecodeSeconds: Double? = nil,
                         onProgress: (@Sendable (Int) -> Void)? = nil, onPrefill: (@Sendable (Int, Int) -> Void)? = nil) async throws -> LanguageModelOutput {
        let entered = Date()
        begin()
        defer { end() }
        try await load()
        let tokenizeStart = Date()
        let (ids, prefix) = try promptIDs(messages)
        let tokenizeSeconds = Date().timeIntervalSince(tokenizeStart)
        guard let tokenizer else { throw IntegratedModelError.engineFailed("The model is not loaded.") }
        let request = GenerationRequest(prompt: ids, maxTokens: maxTokens, sampling: DecodingParameters(temperature: sampling.temperature, topK: sampling.topK, topP: sampling.topP, seed: sampling.seed),
                                        sharedPrefix: sharedPrefix ? prefix : nil, slot: Self.prefixSlot(slot, priority: priority),
                                        maxDecodeSeconds: maxDecodeSeconds, onPrefill: onPrefill)
        let counter = TokenCounter(report: onProgress)
        let result: GenerationResult
        let waits: Waits
        do {
            (result, waits) = try await run(request, constraint: constraint.map { ConstraintAdapter($0) }, priority: priority, onToken: { counter.add($0) })
        } catch Gemma4Error.tooLong {
            throw LLMError.contextLengthExceeded(message: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch is GenerationPreempted {
            throw GenerationPreempted()
        } catch is GenerationTooWarm {
            throw GenerationTooWarm()
        } catch let error as IntegratedModelError {
            throw error
        } catch {
            throw LLMError.modelUnavailable
        }
        var decoder = StreamingDecoder()
        var text = decoder.append(tokenizer.decode(result.tokens))
        text += decoder.finish()
        return LanguageModelOutput(text: text, tokens: result.tokens, promptTokens: result.promptTokens, reusedTokens: result.reusedTokens,
                                   finish: result.finish.rawValue, prefillSeconds: result.prefillSeconds,
                                   firstTokenSeconds: result.firstTokenSeconds, firstTokenSinceCallSeconds: counter.firstTokenAt.map { $0.timeIntervalSince(entered) },
                                   decodeSeconds: result.decodeSeconds,
                                   peakFootprintMB: result.peakFootprintMB, maskUploadSeconds: result.maskUploadSeconds,
                                   tokenizeSeconds: tokenizeSeconds, slotWaitSeconds: waits.slot, gateWaitSeconds: waits.gate,
                                   prefillChunks: result.prefillChunks, longestChunkSeconds: result.longestChunkSeconds, longestBurstSeconds: result.longestBurstSeconds)
    }

    /// What reading a meeting's transcript into the kept prefix did.
    public struct PrefixReading: Sendable, Equatable {
        public var promptTokens: Int
        public var reusedTokens: Int
        public var seconds: Double
    }

    /// Reads `messages` (the transcript so far, ending at its last line) into the meeting's kept prefix and stops, without writing
    /// anything, so that the minutes or an answer start from the end of it. Runs at `.warm` priority: it yields the GPU to everything
    /// else at every chunk, steps aside for any call that needs the same prefix, and waits out a hot Mac. Throws
    /// `GenerationPreempted` when it stepped aside (what it had read stays) and `IntegratedModelError` when the model cannot run.
    @discardableResult
    public func prefillPrefix(_ messages: [ChatMessage], slot: KeptSlot = .meeting, onPrefill: (@Sendable (Int, Int) -> Void)? = nil) async throws -> PrefixReading {
        let started = Date()
        if isWarmingPaused { throw GenerationPreempted() }
        begin()
        defer { end() }
        try await load()
        guard let engine, let lock = slotLocks[Self.prefixSlot(slot, priority: .warm)] else { throw IntegratedModelError.engineFailed("The model is not loaded.") }
        let kept = Self.prefixSlot(slot, priority: .warm)
        // The prefix is the messages themselves: the generation prompt and a last message would follow in a real request.
        let (ids, prefix) = try promptIDs(messages + [.user("")])
        let startEpoch = epoch
        let trim = Self.trimPolicy(keepsPrefix: true, priority: .warm, slot: kept, totalBudget: totalKeptBudget)
        engine.enforceBudget(trim.budget, keeping: trim.keeping)
        let gate = self.gate, thermal = self.thermal
        let reused: Int = try await lock.run(.warm) {
            let lease = GenerationLease(gate: gate, priority: .warm, thermal: thermal)
            try await lease.begin()
            defer { lease.end() }
            return try await engine.prefillPrefix(ids, prefixLength: prefix, slot: kept, checkpoint: {
                if self.epoch != startEpoch { throw IntegratedModelError.engineFailed("The model was unloaded.") }
                if self.isWarmingPaused || lock.hasWaiter(above: .warm) { throw GenerationPreempted() }
                try await lease.checkpoint()
            }, onPrefill: onPrefill)
        }
        return PrefixReading(promptTokens: prefix, reusedTokens: reused, seconds: Date().timeIntervalSince(started))
    }

    /// Greedy continuation of raw ids (golden checks): the first `maxTokens` generated ids.
    public func generateIDs(_ ids: [Int32], maxTokens: Int) async throws -> [Int32] {
        begin()
        defer { end() }
        try await load()
        return try await run(GenerationRequest(prompt: ids, maxTokens: maxTokens, sampling: DecodingParameters.greedy), constraint: nil, priority: .interactive, onToken: nil).0.tokens
    }

    /// A greedy run of raw ids with its timings (benchmarks).
    public func generateTimed(_ ids: [Int32], maxTokens: Int) async throws -> LanguageModelOutput {
        begin()
        defer { end() }
        try await load()
        let r = try await run(GenerationRequest(prompt: ids, maxTokens: maxTokens, sampling: DecodingParameters.greedy), constraint: nil, priority: .interactive, onToken: nil).0
        return LanguageModelOutput(text: "", tokens: r.tokens, promptTokens: r.promptTokens, reusedTokens: r.reusedTokens, finish: r.finish.rawValue,
                                   prefillSeconds: r.prefillSeconds, firstTokenSeconds: r.firstTokenSeconds, firstTokenSinceCallSeconds: nil, decodeSeconds: r.decodeSeconds,
                                   peakFootprintMB: r.peakFootprintMB, longestChunkSeconds: r.longestChunkSeconds, longestBurstSeconds: r.longestBurstSeconds)
    }

    /// Last-position logits for ids (the golden check), under the gate like any other GPU work.
    public func lastLogits(_ ids: [Int32]) async throws -> [Float] {
        begin()
        defer { end() }
        try await load()
        guard let engine else { throw IntegratedModelError.engineFailed("The model is not loaded.") }
        let lease = GenerationLease(gate: gate, priority: .interactive, thermal: thermal)
        try await lease.begin()
        defer { lease.end() }
        return try await engine.lastLogits(ids, checkpoint: { try await lease.checkpoint() })
    }

    public func residentWeightBytes() -> Int { engine?.model.residentBytes ?? 0 }
}

/// Counts the tokens as the generation makes them, on whichever thread it runs, and when the first one came. The progress is
/// reported outside the lock.
private final class TokenCounter: Sendable {
    private struct State {
        var count = 0
        var firstTokenAt: Date?
    }
    private let state = Mutex(State())
    private let report: (@Sendable (Int) -> Void)?
    init(report: (@Sendable (Int) -> Void)?) { self.report = report }
    var firstTokenAt: Date? { state.withLock { $0.firstTokenAt } }
    func add(_ t: Int32) {
        let n = state.withLock { s in
            if s.count == 0 { s.firstTokenAt = Date() }
            s.count += 1
            return s.count
        }
        if n % 16 == 0 { report?(n) }
    }
}

/// The reduced kernel self-test of the language model's ops, run once per process (under the gate, before the first load).
enum LanguageModelKernelCheck {
    private static let result = Mutex<Bool?>(nil)
    static var passed: Bool {
        if let known = result.withLock({ $0 }) { return known }
        let ok = KernelSelfTest.run(.llm).ok
        result.withLock { $0 = ok }
        return ok
    }
}
