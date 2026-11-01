// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Synchronization
import Testing
import MLX
@testable import VautaMLX
@testable import VautaCore

/// The grammar over the tiny model's 512-token vocabulary: ids 0 and 1 are control tokens (1 is the stop token of the tiny
/// configuration), then every byte, then the toy pieces.
enum TinyGrammarVocabulary {
    static let stop: Int32 = 1
    static var bytes: [[UInt8]] { [[], []] + (0..<256).map { [UInt8($0)] } + ToyVocabulary.pieces.map { Array($0.utf8) } }
    static let index = TokenIndex(bytes: bytes, control: (0..<bytes.count).map { $0 < 2 })

    static func encode(_ s: String) -> [Int32] {
        let b = Array(s.utf8)
        var out: [Int32] = []
        var i = 0
        while i < b.count {
            var best = (1, Int32(2 + Int(b[i])))
            for (k, p) in ToyVocabulary.pieces.enumerated() {
                let pb = Array(p.utf8)
                if pb.count > best.0, i + pb.count <= b.count, Array(b[i..<(i + pb.count)]) == pb { best = (pb.count, Int32(258 + k)) }
            }
            out.append(best.1)
            i += best.0
        }
        return out
    }

    static func constraint(_ schema: OutputSchema) -> SchemaConstraint {
        SchemaConstraint(grammar: SchemaGrammar(schema), stop: stop, index: index, encode: { encode($0) }, bytes: { id in bytes[Int(id)] })
    }

    static func text(_ ids: [Int32]) -> [UInt8] { ids.flatMap { bytes[Int($0)] } }
}

/// `SchemaConstraint` seen as the engine's `LogitConstraint` (the app does the same in `LanguageModelEngine`).
final class AdaptedConstraint: LogitConstraint, @unchecked Sendable {
    let inner: SchemaConstraint
    init(_ inner: SchemaConstraint) { self.inner = inner }
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

@Suite("Language model: generation limits, slots, gate and heat on the tiny model", .serialized, .gpuExclusive)
struct LanguageModelGenerationTests {
    static func engine() throws -> Gemma4Engine { try LanguageModelEngineTests.engine() }

    static func prompt(_ n: Int, seed: UInt64 = 7) -> [Int32] {
        var rng = SyntheticLanguageModel.SplitMix(seed)
        return (0..<n).map { _ in Int32(3 + rng.next() % 400) }
    }

    // MARK: Token limit and loop guard keep the JSON valid

    @Test func theTokenLimitInsideAStringOrAnArrayStillGivesValidJSON() async throws {
        let engine = try Self.engine()
        let offered = OutputSchemas.Offered(segments: [3, 4, 5, 120], entities: [7, 8], documents: nil)
        var truncated = 0
        for (schema, limit) in [(OutputSchemas.minutes(offered), 420), (OutputSchemas.minutes(offered), 700), (OutputSchemas.liveNotes(offered), 160),
                                (OutputSchemas.answer(offered), 260), (OutputSchemas.noteBatch(count: 3, offered), 300)] {
            for seed in 1...5 as ClosedRange<UInt64> {
                let c = TinyGrammarVocabulary.constraint(schema)
                let r = try await engine.generate(GenerationRequest(prompt: Self.prompt(30, seed: seed), maxTokens: limit, sampling: .card(seed: seed)), constraint: AdaptedConstraint(c))
                let bytes = TinyGrammarVocabulary.text(r.tokens)
                #expect(r.tokens.count <= limit, "the output stays within the limit: \(r.tokens.count) of \(limit)")
                let json = try? JSONSerialization.jsonObject(with: Data(bytes))
                #expect(json is [String: Any], "valid JSON at limit \(limit), finish \(r.finish): \(String(decoding: bytes, as: UTF8.self).suffix(80))")
                if r.finish == .length || r.finish == .loop { truncated += 1 }
                #expect(r.finish != .cancelled)
            }
        }
        #expect(truncated >= 5, "most of these runs hit the limit or the loop guard and were closed by the grammar: \(truncated)")
    }

    @Test func theTimeLimitOfADecodeClosesTheValueLikeTheTokenLimit() async throws {
        let engine = try Self.engine()
        let offered = OutputSchemas.Offered(segments: [3, 4, 5, 120], entities: [7, 8], documents: nil)
        for seed in 1...4 as ClosedRange<UInt64> {
            // No time at all: the first step already closes the answer as the shortest valid one of either branch.
            let c = TinyGrammarVocabulary.constraint(OutputSchemas.answer(offered, live: true))
            let r = try await engine.generate(GenerationRequest(prompt: Self.prompt(30, seed: seed), maxTokens: 600, sampling: .card(seed: seed), maxDecodeSeconds: 0),
                                              constraint: AdaptedConstraint(c))
            #expect(r.finish == .length && r.tokens.count < 60, "closed at once: \(r.tokens.count) tokens, finish \(r.finish)")
            let object = try #require(JSONSerialization.jsonObject(with: Data(TinyGrammarVocabulary.text(r.tokens))) as? [String: Any])
            let claims = object["claims"] as? [Any] ?? []
            #expect(object["found"] as? Bool == true ? !claims.isEmpty : claims.isEmpty)
        }
        // A generous limit changes nothing: the same text as without one.
        let c1 = TinyGrammarVocabulary.constraint(OutputSchemas.liveNotes(offered)), c2 = TinyGrammarVocabulary.constraint(OutputSchemas.liveNotes(offered))
        let plain = try await engine.generate(GenerationRequest(prompt: Self.prompt(30), maxTokens: 120, sampling: .card(seed: 3)), constraint: AdaptedConstraint(c1))
        let limited = try await engine.generate(GenerationRequest(prompt: Self.prompt(30), maxTokens: 120, sampling: .card(seed: 3), maxDecodeSeconds: 3_600), constraint: AdaptedConstraint(c2))
        #expect(plain.tokens == limited.tokens)
        // Without a grammar the time limit simply stops the text.
        let free = try await engine.generate(GenerationRequest(prompt: Self.prompt(30), maxTokens: 400, sampling: .card(seed: 3), maxDecodeSeconds: 0), constraint: nil)
        #expect(free.finish == .length && free.tokens.isEmpty)
    }

    /// A constraint that allows only one repeating cycle of token ids, as a model stuck in a loop would write, and closes with 2 tokens.
    final class Cycle: LogitConstraint, @unchecked Sendable {
        private let n = Mutex(0)
        let closeAfterNotYet: Int
        let period: Int
        private let askedClosing = Mutex(0)
        init(notYet: Int = 0, period: Int = 16) { closeAfterNotYet = notYet; self.period = period }
        func nextMask() -> LogitMask { .forced(Int32(10 + n.withLock { $0 } % period)) }
        func accept(_ token: Int32) { n.withLock { $0 += 1 } }
        func closing() -> LogitClosing {
            let asked = askedClosing.withLock { let v = $0; $0 += 1; return v }
            return asked < closeAfterNotYet ? .notYet : .tokens([300, 301])
        }
    }

    @Test func theLoopGuardClosesTheValueInsteadOfCuttingIt() async throws {
        let engine = try Self.engine()
        let r = try await engine.generate(GenerationRequest(prompt: Self.prompt(10), maxTokens: 5000, sampling: .greedy), constraint: Cycle())
        #expect(r.finish == .loop && r.tokens.suffix(2) == [300, 301] && r.tokens.count < 200, "stopped at \(r.tokens.count) with \(r.finish)")
        // In the middle of a character: a few sampled tokens first, then the closing.
        let pending = try await engine.generate(GenerationRequest(prompt: Self.prompt(10), maxTokens: 5000, sampling: .greedy), constraint: Cycle(notYet: 3))
        #expect(pending.finish == .loop && pending.tokens.suffix(2) == [300, 301])
        // Free text has no closing: it just stops at the guard, as before.
        let free = try await engine.generate(GenerationRequest(prompt: Self.prompt(10), maxTokens: 5000, sampling: .greedy), constraint: Cycle2())
        #expect(free.finish == .loop && !free.tokens.contains(300))
    }

    final class Cycle2: LogitConstraint, @unchecked Sendable {
        private let n = Mutex(0)
        func nextMask() -> LogitMask { .forced(Int32(10 + n.withLock { $0 } % 16)) }
        func accept(_ token: Int32) { n.withLock { $0 += 1 } }
    }

    @Test func theTokenLimitReservesRoomForTheClosing() async throws {
        let engine = try Self.engine()
        // 5000 tokens would be allowed; with a limit of 300 the closing must start early enough to fit.
        let r = try await engine.generate(GenerationRequest(prompt: Self.prompt(10), maxTokens: 300, sampling: .greedy), constraint: Cycle(period: 40))
        #expect(r.tokens.count <= 300 && r.tokens.suffix(2) == [300, 301] && r.finish != .stop, "\(r.tokens.count) \(r.finish)")
        #expect(Gemma4Engine.closeSlack == 64)
    }

    // MARK: Slots

    @Test func aMinutesCallDoesNotThrowAwayTheAskPrefix() async throws {
        let engine = try Self.engine()
        let ask = Self.prompt(110, seed: 1)
        let live = Self.prompt(100, seed: 2)
        let minutes = Self.prompt(120, seed: 3)
        let first = try await engine.generate(GenerationRequest(prompt: ask, maxTokens: 3, sharedPrefix: 100, slot: .ask))
        #expect(first.reusedTokens == 0 && engine.keptPrefixTokens(.ask) == 84)
        // Live notes with a prompt of their own, and a minutes call that keeps nothing.
        let l = try await engine.generate(GenerationRequest(prompt: live, maxTokens: 3, sharedPrefix: 90, slot: .meeting))
        #expect(l.reusedTokens == 0 && engine.keptPrefixTokens(.meeting) == 74)
        _ = try await engine.generate(GenerationRequest(prompt: minutes, maxTokens: 3))
        let l2 = try await engine.generate(GenerationRequest(prompt: live + [9, 9], maxTokens: 3, sharedPrefix: 90, slot: .meeting))
        #expect(l2.reusedTokens == 74, "live notes reuse their own prefix")
        // The Ask prefix survived all of it and gives the same text as a cold run.
        let again = try await engine.generate(GenerationRequest(prompt: ask, maxTokens: 3, sharedPrefix: 100, slot: .ask))
        #expect(again.reusedTokens == 84 && again.tokens == first.tokens)
        let cold = try await engine.generate(GenerationRequest(prompt: ask, maxTokens: 3))
        #expect(cold.tokens == first.tokens)
        // A live prompt that diverges replaces the live prefix only.
        let other = try await engine.generate(GenerationRequest(prompt: Self.prompt(100, seed: 9), maxTokens: 2, sharedPrefix: 90, slot: .meeting))
        #expect(other.reusedTokens == 0 && engine.keptPrefixTokens(.ask) == 84)
    }

    // MARK: Rewinding a kept prefix

    @Test func aCancelledPrefillOfASharedPrefixLeavesAStateTheOldPromptCanResumeFrom() async throws {
        let engine = try Self.engine()
        engine.chunkLimit = 24
        (engine.checkpointNearEnd, engine.checkpointNearSpacing, engine.checkpointFarSpacing) = (1000, 24, 64)
        let base = Self.prompt(200, seed: 4)
        let primed = try await engine.generate(GenerationRequest(prompt: base, maxTokens: 6, sampling: .greedy, sharedPrefix: 180))
        var edited = base
        edited[60] = edited[60] == 77 ? 78 : 77
        // The edited prompt resumes from a checkpoint at or before 60 and is cancelled after two chunks have overwritten the caches.
        struct Stop: Error {}
        let calls = Mutex(0)
        await #expect(throws: Stop.self) {
            _ = try await engine.generate(GenerationRequest(prompt: edited, maxTokens: 6, sampling: .greedy, sharedPrefix: 180), checkpoint: {
                if calls.withLock({ $0 += 1; return $0 }) > 2 { throw Stop() }
            })
        }
        // The slot claims the tokens the caches hold up to its last checkpoint (the edited prompt's, stored as the prefill went), never
        // more: a state that a later prompt can resume from.
        #expect(engine.checkpointLengths(.ask).allSatisfy { $0 <= engine.keptPrefixTokens(.ask) }, "\(engine.checkpointLengths(.ask)) of \(engine.keptPrefixTokens(.ask))")
        #expect(engine.keptPrefixTokens(.ask) < 180 - 16, "the stopped prefill did not claim the whole prefix: \(engine.keptPrefixTokens(.ask))")
        // The original prompt agrees with the old ids beyond the edit: it must not resume from an old checkpoint over overwritten keys.
        let back = try await engine.generate(GenerationRequest(prompt: base, maxTokens: 6, sampling: .greedy, sharedPrefix: 180))
        let cold = try await engine.generate(GenerationRequest(prompt: base, maxTokens: 6, sampling: .greedy))
        #expect(back.tokens == cold.tokens && back.tokens == primed.tokens && back.reusedTokens <= 60)
    }

    @Test func theSamplerNeverFallsBackToAMaskedToken() {
        // Rounding left the cumulative sum below r: the last candidate with probability, not the last candidate.
        #expect(Sampler.pick((ids: [10, 11, 12, 13], probs: [0.5, 0.4999999, 0, 0]), r: 0.9999999999) == 11)
        #expect(Sampler.pick((ids: [10, 11, 12], probs: [0.6, 0.4, 0]), r: 0.7) == 11)
        #expect(Sampler.pick((ids: [10, 11], probs: [0, 0]), r: 0.1) == nil)
    }

    @Test func onlyThePostRecordingJobsTrimTheKeptPrefixesToTheSmallBudget() {
        // A note expansion (live, no prefix) or a retrieval answer (interactive, no prefix) must not drop the live prefix of a long meeting.
        let live = LanguageModelEngine.trimPolicy(keepsPrefix: false, priority: .live, slot: .meeting)
        #expect(live.budget == LanguageModelEngine.totalBudget && live.keeping == .meeting)
        let ask = LanguageModelEngine.trimPolicy(keepsPrefix: false, priority: .interactive, slot: .ask)
        #expect(ask.budget == LanguageModelEngine.totalBudget && ask.keeping == .ask)
        for p in [MLXWorkGate.Priority.minutes, .bulk] {
            let t = LanguageModelEngine.trimPolicy(keepsPrefix: false, priority: p, slot: .ask)
            #expect(t.budget == LanguageModelEngine.minutesBudget && t.keeping == nil)
        }
        let kept = LanguageModelEngine.trimPolicy(keepsPrefix: true, priority: .minutes, slot: .meeting)
        #expect(kept.budget == LanguageModelEngine.totalBudget && kept.keeping == .meeting)
    }

    @Test func aTranscriptEditedNearTheEndIsRewoundNotRebuilt() async throws {
        let engine = try Self.engine()
        engine.chunkLimit = 24
        (engine.checkpointNearEnd, engine.checkpointNearSpacing, engine.checkpointFarSpacing) = (1000, 24, 64)
        let base = Self.prompt(200, seed: 1)
        let primed = try await engine.generate(GenerationRequest(prompt: base, maxTokens: 6, sampling: .greedy, sharedPrefix: 180))
        #expect(primed.reusedTokens == 0 && engine.keptPrefixTokens(.ask) == 164)
        let lengths = engine.checkpointLengths(.ask)
        #expect(lengths.count > 3 && lengths.last == 164 && lengths == lengths.sorted(), "checkpoints along the prefix: \(lengths)")
        // An edit near the end (inside the last window), one further back, and one in the middle: same text as a cold run, and the
        // prefix up to the checkpoint before the edit is reused.
        for index in [158, 120, 50] {
            var edited = base
            edited[index] = edited[index] == 77 ? 78 : 77
            let warm = try await engine.generate(GenerationRequest(prompt: edited, maxTokens: 6, sampling: .greedy, sharedPrefix: 180))
            let cold = try await engine.generate(GenerationRequest(prompt: edited, maxTokens: 6, sampling: .greedy))
            #expect(warm.tokens == cold.tokens, "edit at \(index)")
            #expect(warm.reusedTokens > 0 && warm.reusedTokens <= index, "edit at \(index) reused \(warm.reusedTokens)")
            #expect(engine.keptPrefixTokens(.ask) == 164, "the slot holds the new prefix")
            // Back to the original text: rewinds again.
            let back = try await engine.generate(GenerationRequest(prompt: base, maxTokens: 6, sampling: .greedy, sharedPrefix: 180))
            #expect(back.tokens == primed.tokens && back.reusedTokens > 0 && back.reusedTokens <= index)
        }
    }

    @Test func aTranscriptEditedBeforeTheFirstCheckpointStartsAgain() async throws {
        let engine = try Self.engine()
        engine.chunkLimit = 24
        (engine.checkpointNearEnd, engine.checkpointNearSpacing, engine.checkpointFarSpacing) = (30, 24, 1000)
        let base = Self.prompt(200, seed: 2)
        _ = try await engine.generate(GenerationRequest(prompt: base, maxTokens: 3, sampling: .greedy, sharedPrefix: 180))
        var edited = base
        edited[5] = edited[5] == 77 ? 78 : 77
        let r = try await engine.generate(GenerationRequest(prompt: edited, maxTokens: 3, sampling: .greedy, sharedPrefix: 180))
        #expect(r.reusedTokens == 0)
    }

    @Test func checkpointsAreDenseNearTheEndAndSparseFurtherBack() {
        let all = Array(stride(from: 512, through: 30_000, by: 512)) + [30_100]
        let kept = Gemma4Engine.pruned(all, end: 30_100, nearEnd: 1024, nearSpacing: 512, farSpacing: 8192)
        #expect(kept.last == 30_100)
        #expect(kept.filter { 30_100 - $0 <= 1024 }.count == 3, "512, 1024 and the end")
        let far = kept.filter { 30_100 - $0 > 1024 }
        #expect(far.count <= 4 && zip(far, far.dropFirst()).allSatisfy { $1 - $0 >= 8192 }, "\(far)")
        // A recording read every few lines leaves the last chunk boundary of every reading: only the newest one stays, with the
        // near ones spaced as usual.
        let readings = [8_192, 8_704, 9_216, 9_344, 9_472, 9_600, 9_728, 9_856, 9_900]
        let thinned = Gemma4Engine.pruned(readings, end: 9_900, boundary: 9_856, nearEnd: 1024, nearSpacing: 512, farSpacing: 8192)
        #expect(thinned == [8_192, 9_216, 9_728, 9_856, 9_900], "\(thinned)")
    }

    // MARK: Chunks

    @Test func prefillChunksEndAtTheMultiplesOfTheChunkWhereverTheReadingStarts() async throws {
        #expect(Gemma4Engine.prefillChunk == 128)
        #expect(Gemma4Engine.chunkEnd(from: 0, end: 1_000, unit: 128) == 128)
        #expect(Gemma4Engine.chunkEnd(from: 200, end: 1_000, unit: 128) == 256, "a reading that starts inside a chunk ends it where a cold one does")
        #expect(Gemma4Engine.chunkEnd(from: 256, end: 1_000, unit: 128) == 384)
        #expect(Gemma4Engine.chunkEnd(from: 900, end: 1_000, unit: 128) == 1_000)
        let engine = try Self.engine()
        #expect(engine.chunkUnit(contextEnd: 4_000) == 128)
        #expect(engine.chunkUnit(contextEnd: Gemma4Engine.maxContext) == 128, "the memory rule never cuts it within the model's context")
        engine.fixedChunk = 512
        #expect(engine.chunkUnit(contextEnd: 4_000) == 512 && engine.chunkUnit(contextEnd: 30_000) == 256, "the goldens' chunk, cut by the memory rule")
        engine.chunkLimit = 24
        #expect(engine.chunkUnit(contextEnd: 4_000) == 24)
    }

    @Test func aColdReadingGivesTheSameBitsWhateverRanBefore() async throws {
        // The chunks no longer follow the measured speed, which changes with every prompt read.
        let engine = try Self.engine()
        let p = Self.prompt(400, seed: 11)
        let first = try await engine.lastLogits(p)
        _ = try await engine.lastLogits(Self.prompt(40, seed: 12))
        _ = try await engine.generate(GenerationRequest(prompt: Self.prompt(300, seed: 13), maxTokens: 20, sampling: .greedy))
        #expect(try await engine.lastLogits(p) == first)
        let r = try await engine.generate(GenerationRequest(prompt: p, maxTokens: 20, sampling: .greedy))
        #expect(r.prefillChunks == 4 && r.longestChunkSeconds > 0 && r.longestBurstSeconds > 0, "400 tokens in chunks of 128; both stretches timed")
    }

    // MARK: Sampler

    @Test func theSamplerSupportIsTheHuggingFaceOrderOnFixedLogits() {
        // Fixed logits, k = 4, p = 0.8: temperature, top-k, then top-p over the 4 survivors.
        let ids: [Int32] = [11, 12, 13, 14]
        let values: [Float] = [4, 3, 2, 1]
        var params = DecodingParameters(temperature: 1, topK: 4, topP: 0.8, seed: 0)
        let c1 = Sampler.candidates(ids: ids, values: values, params: params)
        // softmax(4,3,2,1) = 0.644, 0.237, 0.087, 0.032: cumulative 0.644, 0.881 -> the first two.
        #expect(c1?.ids == [11, 12])
        if let p = c1?.probs { #expect(abs(p.reduce(0, +) - 1) < 1e-9 && abs(p[0] - 0.644 / 0.881) < 0.01) }
        // At a low temperature the mass moves up: only the best token reaches 0.8.
        params.temperature = 0.5
        #expect(Sampler.candidates(ids: ids, values: values, params: params)?.ids == [11])
        // At temperature 1 mlx-lm (top-p over the whole vocabulary first, then top-k) keeps the same tokens when the k survivors hold
        // all of the mass top-p asks for: with these logits and a long tail below, both orders keep {11, 12}.
        let tail = [Float](repeating: -20, count: 200)
        let all = values + tail
        let soft = all.map { exp(Double($0)) }
        let total = soft.reduce(0, +)
        var cum = 0.0
        var mlxKeep = 0
        for p in soft.map({ $0 / total }) { cum += p; mlxKeep += 1; if cum >= 0.8 { break } }
        #expect(mlxKeep == 2)
        // top-k alone, and a masked (-inf) candidate has no probability.
        let k1 = Sampler.candidates(ids: [1, 2, 3], values: [2, -.infinity, -.infinity], params: DecodingParameters(temperature: 1, topK: 3, topP: 1, seed: 0))
        #expect(k1?.ids == [1, 2, 3] && k1?.probs[0] == 1 && k1?.probs[1] == 0)
        #expect(Sampler.candidates(ids: [1], values: [-.infinity], params: params) == nil)
    }

    @Test func theMaskBufferIsReusedAndOnlyTheAllowedTokensAreOpen() throws {
        var sampler = Sampler(params: .card(seed: 1), vocab: 512)
        var bits = [UInt64](repeating: 0, count: 8)
        for t in [3, 70, 400] { bits[t >> 6] |= 1 << UInt64(t & 63) }
        let m1 = sampler.additiveMask(bits).asArray(Float.self)
        #expect(m1.enumerated().allSatisfy { ([3, 70, 400].contains($0.offset)) == ($0.element == 0) && ([3, 70, 400].contains($0.offset) || $0.element == -.infinity) })
        var bits2 = [UInt64](repeating: 0, count: 8)
        for t in [70, 71] { bits2[t >> 6] |= 1 << UInt64(t & 63) }
        let m2 = sampler.additiveMask(bits2).asArray(Float.self)
        #expect(m2.enumerated().allSatisfy { ([70, 71].contains($0.offset)) == ($0.element == 0) }, "the entries of the previous mask are closed again")
    }

    // MARK: Runtime limits

    @Test func theMemoryLimitComesBackWhenTheLanguageModelIsUnloaded() {
        MLXRuntime.configure()
        let before = Memory.memoryLimit
        MLXRuntime.setCacheLimit(for: .languageModel)
        let raised = Memory.memoryLimit
        MLXRuntime.setCacheLimit(for: .languageModel)   // loading twice does not forget the first value
        MLXRuntime.setCacheLimit(for: .encoderOnly)
        #expect(Memory.memoryLimit == before, "back to \(before) from \(raised)")
        #expect(Memory.cacheLimit == MLXRuntime.cacheLimitBytes)
    }
}
