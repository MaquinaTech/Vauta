// SPDX-License-Identifier: Apache-2.0 AND MIT
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
// Portions derived from mlx-lm (https://github.com/ml-explore/mlx-lm, v0.32.0, MIT), Copyright © 2023-2025 Apple Inc.

import Foundation
import MLX

public enum GenerationFinish: String, Sendable {
    case stop, length, loop, cancelled
    /// No allowed token had a finite logit (an empty grammar set, or NaN logits): the output was ended, closed as valid text when a
    /// constraint could, never filled with a token the mask forbids.
    case noToken
}

/// Which kept prefix a request reads and writes. Each slot has its own caches, so a job that keeps no prefix (note expansions)
/// runs on scratch caches and never touches the others. `meeting` is the meeting being recorded (or just recorded): live notes,
/// live answers, the incremental reading while recording, and the minutes; `ask` is anything else (a library question, another
/// meeting).
public enum PrefixSlot: Hashable, Sendable { case ask, meeting }

public struct GenerationRequest: Sendable {
    public var prompt: [Int32]
    public var maxTokens: Int
    public var sampling: DecodingParameters
    /// Length of the part of the prompt that the next request will probably share (system text, people, transcript). The
    /// engine keeps the state after `prefixLength - 16` tokens to continue from. nil = no reuse.
    public var sharedPrefix: Int?
    /// The slot the kept state lives in (only used with `sharedPrefix`).
    public var slot: PrefixSlot
    /// Stops writing after this many seconds of decoding (reading the prompt does not count) and ends a constrained value the way a
    /// token limit does: validly, finish `length`. nil = no limit.
    public var maxDecodeSeconds: Double?
    /// Called after every prefill chunk with the tokens of the prompt that are in the caches (reused ones included) and the prompt's
    /// length, for a progress bar.
    public var onPrefill: (@Sendable (Int, Int) -> Void)?

    public init(prompt: [Int32], maxTokens: Int, sampling: DecodingParameters = .greedy, sharedPrefix: Int? = nil, slot: PrefixSlot = .ask,
                maxDecodeSeconds: Double? = nil, onPrefill: (@Sendable (Int, Int) -> Void)? = nil) {
        self.onPrefill = onPrefill
        self.prompt = prompt
        self.maxDecodeSeconds = maxDecodeSeconds
        self.maxTokens = maxTokens
        self.sampling = sampling
        self.sharedPrefix = sharedPrefix
        self.slot = slot
    }
}

public struct GenerationResult: Sendable {
    public var tokens: [Int32]
    public var finish: GenerationFinish
    public var promptTokens: Int
    /// Prompt tokens that were not prefilled because a kept state covered them.
    public var reusedTokens: Int
    public var prefillSeconds: Double
    /// Time from the start of the call to the first generated token.
    public var firstTokenSeconds: Double
    public var decodeSeconds: Double
    public var peakFootprintMB: Int
    /// Host time spent turning allowed-token sets into the additive logit masks (and handing them to the GPU).
    public var maskUploadSeconds: Double = 0
    /// Prefill chunks that ran for this request (the kept prefix's included).
    public var prefillChunks = 0
    /// The longest stretch between two checkpoints while reading the prompt, and while decoding: the longest a more urgent job
    /// waited for the GPU because of this request.
    public var longestChunkSeconds = 0.0
    public var longestBurstSeconds = 0.0
}

/// Times the stretches between checkpoints of one request.
final class HoldClock {
    private var since = Date()
    private(set) var prefill = 0.0
    private(set) var decode = 0.0
    var decoding = false

    /// Ends a stretch: a checkpoint is about to run, or the request returns.
    func lap() {
        let held = Date().timeIntervalSince(since)
        if decoding { decode = max(decode, held) } else { prefill = max(prefill, held) }
    }
    /// Starts the next stretch (the checkpoint gave the GPU back).
    func resume() { since = Date() }

    func wrap(_ checkpoint: GenerationCheckpoint?) -> GenerationCheckpoint {
        { [self] in
            lap()
            try await checkpoint?()
            resume()
        }
    }
}

/// Called between prefill chunks and every `Gemma4Engine.decodeBurst` tokens: the place where a job gives the GPU to a more
/// urgent one, waits out a hot Mac, or is cancelled.
public typealias GenerationCheckpoint = () async throws -> Void

/// Prefill and decode over `Gemma4TextModel`, with one kept prefix state per slot (see `GenerationRequest.sharedPrefix`).
/// Not `Sendable`: owned by one actor. Cancellation and checkpoints run between prefill chunks and between decode bursts; a
/// prefill chunk (`prefillChunk` tokens) takes about as long as a decode burst on the real model, so neither waits long.
public final class Gemma4Engine {
    public let model: Gemma4TextModel
    /// A kept prefix: its token ids, its caches, and the states it can be rewound to, by length, ascending. The last one is the
    /// full length (`ids.count`). A prompt that differs from the ids at token `d` continues from the latest checkpoint at or before
    /// `d`: the full-attention layers are cut back to its length and the sliding windows restored, which is exact; only the tokens
    /// between that checkpoint and the end of the new prefix are computed again.
    private struct Kept {
        var ids: [Int32]
        var caches: LayerCaches
        var checkpoints: [LayerCaches.Snapshot]
        var snapshot: LayerCaches.Snapshot { checkpoints[checkpoints.count - 1] }
    }
    private var slots: [PrefixSlot: Kept] = [:]
    /// Called with the largest `phys_footprint` seen (MB) after every prefill chunk, for the thermal / memory guard.
    public var memoryProbe: (@Sendable (Int) -> Void)?

    static let margin = 16
    public static let maxContext = 65_536
    /// Decode steps between two checkpoints: about as long as a prefill chunk on the real model (0.41 to 0.56 s on an M2, where 16
    /// tokens held the GPU 1.07 to 1.21 s), so a more urgent job waits as little during decoding as during prefill, for a decode
    /// 0.2 to 0.9 % slower.
    public static let decodeBurst = 8
    /// Tokens kept in reserve when a constrained output must end at the token limit: the shortest valid ending can grow by this
    /// much with one more token, so closing at this distance always fits.
    static let closeSlack = 64
    /// Distance from the token limit at which the shortest ending is first computed.
    static let closeWindow = 256

    /// Prompt tokens per prefill chunk. Chunks end at the multiples of it (positions in the prompt, not in one call), so every reading
    /// of a prompt runs the same chunks: from the start, from a kept prefix, or continued while a meeting is recorded. The bf16 sums
    /// depend on the chunking, and a near tie between two tokens flips with them: chunks sized by the measured speed gave other
    /// minutes on every run. A chunk of 128 tokens holds the GPU about as long as a decode burst (0.36 to 0.45 s on an M2 at 363
    /// to 376 tokens a second, up to 19,656 tokens), and reads faster than the speed-sized chunks did (345 to 352 tokens a second).
    public static let prefillChunk = 128
    /// Test hook: a smaller prefill chunk (nil = `prefillChunk`, or `fixedChunk`).
    public var chunkLimit: Int?
    /// Test and self-test hook: another prefill chunk (the goldens of mlx-lm are made with 512), cut by the memory rule.
    public var fixedChunk: Int?
    /// Measured prefill speed (tokens per second, smoothed); nil until the first chunk has run.
    private(set) var prefillRate: Double?
    public var measuredPrefillRate: Double? { prefillRate }
    /// Prefill chunks run so far (the difference between two reads is the chunks of one request).
    private(set) var chunksRun = 0

    public init(url: URL, config: Gemma4TextConfig = .pinned) throws {
        model = try Gemma4TextModel(url: url, config: config)
    }

    public func keptPrefixTokens(_ slot: PrefixSlot = .ask) -> Int { slots[slot]?.ids.count ?? 0 }
    /// Lengths of the checkpoints a slot can be rewound to (tests and diagnostics).
    func checkpointLengths(_ slot: PrefixSlot) -> [Int] { slots[slot]?.checkpoints.map(\.length) ?? [] }
    /// The keys and values a slot holds, as floats (tests: two readings of the same prompt hold the same bits).
    func keptValues(_ slot: PrefixSlot) -> [[Float]] {
        (slots[slot]?.caches.usedArrays ?? []).map { $0.asType(.float32).reshaped([-1]).asArray(Float.self) }
    }
    /// Memory held by the kept prefixes: their caches and checkpoints.
    public var cacheBytes: Int { slots.values.reduce(0) { $0 + $1.caches.byteCount + $1.checkpoints.reduce(0) { $0 + $1.byteCount } } }
    /// Memory held by one slot.
    public func cacheBytes(_ slot: PrefixSlot) -> Int {
        slots[slot].map { $0.caches.byteCount + $0.checkpoints.reduce(0) { $0 + $1.byteCount } } ?? 0
    }

    /// Checkpoints are dense near the end of a prefix (the transcript's newest segments are the ones that still change) and sparse
    /// further back.
    public var checkpointNearEnd = 1024
    public var checkpointNearSpacing = 512
    public var checkpointFarSpacing = 8192

    /// Which of the checkpoint lengths to keep for a prefix of `end` tokens: the last one, `boundary` (the last chunk boundary
    /// before it, where a longer prompt continues), one per `nearSpacing` tokens within `nearEnd` of the end, and one per
    /// `farSpacing` further back. The boundaries of earlier, shorter prefixes are thinned like any other checkpoint.
    static func pruned(_ lengths: [Int], end: Int, boundary: Int? = nil, nearEnd: Int, nearSpacing: Int, farSpacing: Int) -> [Int] {
        var kept: [Int] = []
        var last = 0
        for l in lengths.sorted() where l <= end {
            let spacing = end - l <= nearEnd ? nearSpacing : farSpacing
            if l == end || l == boundary || l - last >= spacing {
                kept.append(l)
                last = l
            }
        }
        return kept
    }

    /// Frees kept prefixes until the kept memory is at most `budget` bytes, never the slot named `keeping`. The Ask prefix goes first
    /// (it is the cheaper one to read again), then the meeting's. Returns the slots dropped.
    @discardableResult
    public func enforceBudget(_ budget: Int, keeping: PrefixSlot?) -> [PrefixSlot] {
        var dropped: [PrefixSlot] = []
        for slot in [PrefixSlot.ask, .meeting] where slot != keeping && cacheBytes > budget && slots[slot] != nil {
            slots[slot] = nil
            dropped.append(slot)
        }
        return dropped
    }

    public func dropKeptPrefix() { slots = [:] }
    public func dropKeptPrefix(_ slot: PrefixSlot) { slots[slot] = nil }

    /// Largest power-of-two chunk (at most 512) whose unfused attention scores (8 heads x chunk x context x 4 bytes) stay under 256 MiB.
    static func chunkSize(context: Int) -> Int {
        var c = 512
        while c > 16, 8 * c * max(context, 1) * 4 > 256 << 20 { c /= 2 }
        return c
    }

    /// The chunk of a prompt that `contextEnd` tokens of context will follow: `prefillChunk` (or the test hooks), cut by the memory rule.
    func chunkUnit(contextEnd: Int) -> Int {
        min(fixedChunk ?? Self.prefillChunk, chunkLimit ?? Int.max, Self.chunkSize(context: contextEnd))
    }

    /// Where the chunk that starts at position `start` ends: the next multiple of `unit`, or `end`.
    static func chunkEnd(from start: Int, end: Int, unit: Int) -> Int {
        min(end, (start / unit + 1) * unit)
    }

    private func prefill(_ ids: ArraySlice<Int32>, caches: LayerCaches, contextEnd: Int, wantHidden: Bool,
                         checkpoint: GenerationCheckpoint?, afterChunk: ((Int) -> Void)? = nil, isolation: isolated (any Actor)? = #isolation) async throws -> MLXArray? {
        var last: MLXArray?
        var i = ids.startIndex
        let unit = chunkUnit(contextEnd: contextEnd)
        while i < ids.endIndex {
            try Task.checkCancellation()
            try await checkpoint?()
            // `ids` keeps the prompt's indices, so `i` is the position in the prompt.
            let j = Self.chunkEnd(from: i, end: ids.endIndex, unit: unit)
            let started = Date()
            let h = try model.forward(Array(ids[i..<j]), caches: caches)
            // Only the last chunk's hidden state is ever read, and only when the caller wants it. For any other chunk, evaluating the
            // caches alone runs only what they need (MLX evaluates lazily): the layers that own keys and values, up to the keys and
            // values of the last of them, and none of the 18 layers that share them (24-41 of 42). Its hidden state is not kept either:
            // unevaluated, it would hold the old cache buffers alive.
            let keep = wantHidden && j == ids.endIndex
            eval(keep ? [h] + caches.arrays : caches.arrays)
            let elapsed = Date().timeIntervalSince(started)
            // Short tails say little about the speed; the rest feed a moving average.
            if j - i >= 16, elapsed > 0 {
                let measured = Double(j - i) / elapsed
                prefillRate = prefillRate.map { 0.5 * $0 + 0.5 * measured } ?? measured
            }
            chunksRun += 1
            memoryProbe?(MLXRuntime.physFootprintMB())
            afterChunk?(caches.offset)
            if keep { last = h }
            i = j
        }
        return last
    }

    public func generate(_ request: GenerationRequest, constraint: LogitConstraint? = nil,
                         onToken: (@Sendable (Int32) -> Void)? = nil, checkpoint: GenerationCheckpoint? = nil,
                         isolation: isolated (any Actor)? = #isolation) async throws -> GenerationResult {
        let start = Date()
        let prompt = request.prompt
        guard !prompt.isEmpty else { throw Gemma4Error.emptyPrompt }
        guard prompt.count + request.maxTokens <= Self.maxContext else { throw Gemma4Error.tooLong(prompt.count) }
        let cfg = model.config
        let chunksBefore = chunksRun
        let total = prompt.count
        let report = request.onPrefill
        let progress: ((Int) -> Void)? = report.map { r in { (done: Int) -> Void in r(done, total) } }
        let clock = HoldClock()
        let checkpoint = clock.wrap(checkpoint)
        // 1. Get the caches to the shared prefix: reuse the slot's kept state when the prompt starts with it. A request with no
        // shared prefix runs on scratch caches and leaves every slot as it was.
        let target = request.sharedPrefix.map { max(0, min($0, prompt.count - 1) - Self.margin) } ?? 0
        let caches: LayerCaches
        let keeps = target > 0
        var reused = 0
        let prefixStart = Date()
        var prefixSeconds = 0.0
        if keeps {
            let kept = try await keepPrefix(prompt, target: target, slot: request.slot, checkpoint: checkpoint, onPrefill: progress)
            caches = kept.caches
            reused = kept.reused
            prefixSeconds = Date().timeIntervalSince(prefixStart)
        } else {
            caches = model.newCaches()
        }
        defer {
            // The part after the shared prefix (question, generated text) is never reused.
            if keeps, let kept = slots[request.slot] { caches.restore(kept.snapshot) }
        }
        // 2. The rest of the prompt; its last hidden state gives the first token.
        let prefillStart = Date()
        let from = caches.offset
        guard let hidden = try await prefill(prompt[from...], caches: caches, contextEnd: prompt.count + request.maxTokens, wantHidden: true, checkpoint: checkpoint,
                                             afterChunk: progress) else {
            throw Gemma4Error.emptyPrompt
        }
        // The shared prefix and the rest of the prompt: everything read before the first token.
        let prefillSeconds = prefixSeconds + Date().timeIntervalSince(prefillStart)
        // Between the last chunk and the first burst too, so a waiter never waits for both.
        try await checkpoint()
        // 3. Decode.
        clock.decoding = true
        var sampler = Sampler(params: request.sampling, vocab: cfg.vocab)
        var out: [Int32] = []
        var finish = GenerationFinish.length
        var firstToken = 0.0
        let decodeStart = Date()
        var logits = model.logits(hidden)
        var peak = MLXRuntime.physFootprintMB()
        var sinceCheckpoint = 0
        var maskUpload = 0.0
        // Set when the output has to end now (token limit close, repeating) but a constrained value must still be closed.
        var closing: GenerationFinish?
        var closeSteps = 0
        decoding: while true {
            try Task.checkCancellation()
            if closing == nil, out.count >= request.maxTokens { finish = .length; break }
            if closing == nil, let limit = request.maxDecodeSeconds, Date().timeIntervalSince(decodeStart) >= limit {
                if constraint == nil { finish = .length; break }
                closing = .length
            }
            if let reason = closing {
                switch constraint?.closing() ?? .unsupported {
                case .tokens(let ts):
                    for t in ts.prefix(Self.closeWindow * 2) {
                        constraint?.accept(t)
                        out.append(t)
                        onToken?(t)
                    }
                    finish = reason
                    break decoding
                case .unsupported:
                    finish = reason
                    break decoding
                case .notYet:
                    closeSteps += 1
                    if closeSteps > 8 { finish = reason; break decoding }
                }
            } else if let constraint, request.maxTokens - out.count <= Self.closeWindow,
                      case .tokens(let ts) = constraint.closing(), ts.count + Self.closeSlack >= request.maxTokens - out.count {
                closing = .length
                continue
            }
            var chosen: [Int32]
            switch constraint?.nextMask() ?? .free {
            case .forced(let t): chosen = [t]
            case .forcedSequence(let ts): chosen = ts
            case .free:
                guard let t = sampler.sample(logits, mask: nil) else { chosen = []; break }
                chosen = [t]
            case .allowed(let bits):
                let u0 = Date()
                let additive = sampler.additiveMask(bits)
                maskUpload += Date().timeIntervalSince(u0)
                guard let t = sampler.sample(logits, mask: additive) else { chosen = []; break }
                chosen = [t]
            }
            if chosen.isEmpty {
                // Nothing valid can be sampled. A constrained output is closed as valid text (or ends as it is if it cannot be
                // closed, or was already being closed); free text has nothing to show for it.
                if constraint == nil { throw Gemma4Error.noValidToken }
                if closing == nil { closing = .noToken; continue }
                finish = .noToken
                break decoding
            }
            if out.isEmpty { firstToken = Date().timeIntervalSince(start) }
            var feed: [Int32] = []
            var done = false
            for token in chosen {
                constraint?.accept(token)
                if cfg.stopIDs.contains(token) { finish = .stop; done = true; break }
                out.append(token)
                feed.append(token)
                onToken?(token)
                if closing == nil, Self.repeats(out) {
                    // A constrained value is closed properly; free text just stops.
                    if constraint != nil { closing = .loop } else { finish = .loop; done = true }
                    break
                }
                if closing == nil, out.count == request.maxTokens { done = true; break }
            }
            if done { break }
            let h = try model.forward(feed, caches: caches)
            logits = model.logits(h)
            eval(logits)
            if out.count % 16 < feed.count { peak = max(peak, MLXRuntime.physFootprintMB()) }
            sinceCheckpoint += feed.count
            if sinceCheckpoint >= Self.decodeBurst {
                sinceCheckpoint = 0
                try await checkpoint()
            }
        }
        peak = max(peak, MLXRuntime.physFootprintMB())
        clock.lap()
        return GenerationResult(tokens: out, finish: finish, promptTokens: prompt.count, reusedTokens: reused, prefillSeconds: prefillSeconds,
                                firstTokenSeconds: firstToken, decodeSeconds: Date().timeIntervalSince(decodeStart), peakFootprintMB: peak, maskUploadSeconds: maskUpload,
                                prefillChunks: chunksRun - chunksBefore, longestChunkSeconds: clock.prefill, longestBurstSeconds: clock.decode)
    }

    /// Brings the slot's caches to hold `prompt[0..<target]`, continuing from the longest valid checkpoint, and stores the result
    /// as the slot's kept prefix. Progress is stored as it goes (every checkpoint), so a prefill that is stopped keeps what it did.
    /// Returns the caches and the tokens that were already there.
    private func keepPrefix(_ prompt: [Int32], target: Int, slot: PrefixSlot, checkpoint: GenerationCheckpoint?,
                            onPrefill: ((Int) -> Void)?, isolation: isolated (any Actor)? = #isolation) async throws -> (caches: LayerCaches, reused: Int) {
        var reused = 0
        var checkpoints: [LayerCaches.Snapshot] = []
        let caches: LayerCaches
        let unit = chunkUnit(contextEnd: target)
        if let kept = slots[slot], let resume = Self.resumePoint(kept.ids, prompt: prompt, limit: target, checkpoints: kept.checkpoints, unit: unit) {
            // Continue from the latest checkpoint at or before the first differing token.
            caches = kept.caches
            caches.restore(resume)
            reused = resume.length
            checkpoints = kept.checkpoints.filter { $0.length <= resume.length }
            // The caches are about to be written past `resume.length` by the new prompt. Until the new prefix is stored, the slot
            // says exactly what is valid (the ids and checkpoints up to there), so a prefill that is cancelled or fails leaves a
            // state that a later prompt can resume from, never old checkpoints over overwritten keys and values.
            slots[slot] = Kept(ids: Array(kept.ids.prefix(resume.length)), caches: caches, checkpoints: checkpoints)
        } else {
            caches = model.newCaches()
            slots[slot] = nil
        }
        onPrefill?(reused)
        let from = caches.offset
        var lastCheckpoint = from
        let (nearEnd, nearSpacing, farSpacing) = (checkpointNearEnd, checkpointNearSpacing, checkpointFarSpacing)
        _ = try await prefill(prompt[from..<target], caches: caches, contextEnd: target, wantHidden: false, checkpoint: checkpoint, afterChunk: { offset in
            onPrefill?(offset)
            guard offset < target else { return }
            let near = offset >= target - nearEnd && offset - lastCheckpoint >= nearSpacing
            // The last chunk boundary before the end: a longer prompt (the next lines of a recording) continues from it, not from
            // the end, so it runs the chunks a cold reading of that prompt runs.
            let lastBoundary = target - offset < unit
            if near || lastBoundary || offset - lastCheckpoint >= farSpacing {
                checkpoints.append(caches.compactSnapshot())
                lastCheckpoint = offset
                // What a stopped prefill has done so far stays valid: the ids and checkpoints up to this one.
                self.slots[slot] = Kept(ids: Array(prompt[0..<offset]), caches: caches, checkpoints: checkpoints)
            }
        })
        if checkpoints.last?.length != target { checkpoints.append(caches.snapshot()) }
        let keepLengths = Set(Self.pruned(checkpoints.map(\.length), end: target, boundary: (target - 1) / unit * unit,
                                          nearEnd: nearEnd, nearSpacing: nearSpacing, farSpacing: farSpacing))
        slots[slot] = Kept(ids: Array(prompt[0..<target]), caches: caches, checkpoints: checkpoints.filter { keepLengths.contains($0.length) })
        return (caches, reused)
    }

    /// Reads `prompt[0..<target]` into the slot and stops (no decoding): the meeting's transcript so far, read while it is recorded,
    /// so that the minutes or an answer only read what came after. `target` is the shared prefix length minus the margin, like a
    /// request with `sharedPrefix`. Returns the tokens that were already in the slot.
    @discardableResult
    public func prefillPrefix(_ prompt: [Int32], prefixLength: Int, slot: PrefixSlot, checkpoint: GenerationCheckpoint? = nil,
                              onPrefill: (@Sendable (Int, Int) -> Void)? = nil, isolation: isolated (any Actor)? = #isolation) async throws -> Int {
        let target = max(0, min(prefixLength, prompt.count) - Self.margin)
        guard target > 0 else { return 0 }
        guard prompt.count <= Self.maxContext else { throw Gemma4Error.tooLong(prompt.count) }
        let total = prompt.count
        let progress: ((Int) -> Void)? = onPrefill.map { r in { (done: Int) -> Void in r(done, total) } }
        let kept = try await keepPrefix(prompt, target: target, slot: slot, checkpoint: checkpoint, onPrefill: progress)
        return kept.reused
    }

    /// The checkpoint a kept prefix continues from for `prompt`: the latest one at or before the first token where the two differ
    /// (and at or before `limit`, the length the new prefix will have) that a cold reading of the new prefix also stops at: a chunk
    /// boundary (a multiple of `unit`) or `limit` itself. nil when there is none, and the prompt starts again.
    static func resumePoint(_ kept: [Int32], prompt: [Int32], limit: Int, checkpoints: [LayerCaches.Snapshot], unit: Int) -> LayerCaches.Snapshot? {
        let n = min(kept.count, limit, prompt.count)
        var common = 0
        while common < n, kept[common] == prompt[common] { common += 1 }
        return checkpoints.last { $0.length <= common && $0.length > 0 && ($0.length % unit == 0 || $0.length == limit) }
    }

    /// Whether the last 32 tokens have just repeated for the third time in a row.
    public static func repeats(_ t: [Int32]) -> Bool {
        let n = 32
        guard t.count >= 3 * n else { return false }
        let a = t[(t.count - n)...], b = t[(t.count - 2 * n)..<(t.count - n)], c = t[(t.count - 3 * n)..<(t.count - 2 * n)]
        return a.elementsEqual(b) && b.elementsEqual(c)
    }

    /// Logits of the last position for `ids` with no kept state: the golden check against mlx-lm.
    public func lastLogits(_ ids: [Int32], checkpoint: GenerationCheckpoint? = nil,
                           isolation: isolated (any Actor)? = #isolation) async throws -> [Float] {
        let caches = model.newCaches()
        guard let h = try await prefill(ids[...], caches: caches, contextEnd: ids.count, wantHidden: true, checkpoint: checkpoint) else { throw Gemma4Error.emptyPrompt }
        let l = model.logits(h).reshaped([-1]).asType(.float32)
        eval(l)
        return l.asArray(Float.self)
    }
}
