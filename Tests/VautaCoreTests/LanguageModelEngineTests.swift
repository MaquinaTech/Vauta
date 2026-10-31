// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Synchronization
import Testing
import MLX
@testable import VautaMLX
@testable import VautaCore

/// The model on a tiny synthetic Gemma 4 (9 layers, 3 of them sharing keys and values, a window of 16, proportional RoPE,
/// per-layer inputs, 4-bit weights made by Vauta's quantizer) against the goldens mlx-lm Python gives on the same file.
@Suite("Language model: engine on a tiny model", .serialized, .gpuExclusive)
struct LanguageModelEngineTests {
    struct Golden: Decodable { let n: Int; let ids: [Int32]; let top: [Int]; let topValues: [Double]; let greedy: [Int32]; let logitsMax: Double }
    struct Goldens: Decodable { let goldens: [Golden] }

    static var dir: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/LanguageModel/tiny") }

    static func goldens() throws -> [Golden] {
        try JSONDecoder().decode(Goldens.self, from: Data(contentsOf: dir.appendingPathComponent("tiny_goldens.json"))).goldens
    }

    static func engine() throws -> Gemma4Engine {
        MLXRuntime.configure()
        return try Gemma4Engine(url: dir.appendingPathComponent("model.safetensors"), config: .tiny)
    }

    @Test func lastPositionLogitsMatchMLXLM() async throws {
        let engine = try Self.engine()
        for g in try Self.goldens() {
            let logits = try await engine.lastLogits(g.ids)
            #expect(logits.count == 512)
            let order = logits.indices.sorted { logits[$0] > logits[$1] }
            // The CI runners' paravirtual GPU sometimes rounds differently (measured: 0.6875 on one token at n = 120, which also swapped
            // the third and fourth tokens; on a Mac 60 runs in a row give the same 0.1875): there the two best tokens and 4% are checked.
            let ranked = TestMachine.isVirtual ? 2 : 3
            #expect(Array(order.prefix(ranked)) == Array(g.top.prefix(ranked)), "n = \(g.n): the \(ranked) best tokens")
            let share = TestMachine.isVirtual ? 0.04 : 0.02
            for (t, v) in zip(g.top, g.topValues) {
                // Measured on this model: 0.0 (5 tokens), 0.125 (40) and 0.1875 (120) on logits near 28, where bf16 moves in steps of 0.125.
                // 2% of the largest logit is about three steps: a wrong scale, a missing offset or a mis-ordered operation on any
                // layer type shows up here, which the real model's wider end-to-end limit (1.25, see LanguageModelSelfTest) cannot.
                #expect(abs(Double(logits[t]) - v) <= share * max(g.logitsMax, 1), "n = \(g.n), token \(t): \(logits[t]) against \(v)")
            }
        }
    }

    @Test func greedyOutputEqualsMLXLMForTheFirstTokens() async throws {
        let engine = try Self.engine()
        for g in try Self.goldens() {
            let out = try await engine.generate(GenerationRequest(prompt: g.ids, maxTokens: 4, sampling: .greedy))
            #expect(Array(out.tokens.prefix(2)) == Array(g.greedy.prefix(2)), "n = \(g.n)")
        }
    }

    @Test func chunkedPrefillEqualsOneShotAcrossTheSlidingWindow() async throws {
        let engine = try Self.engine()
        let g = try #require(try Self.goldens().last)   // 120 tokens, a window of 16: the rotating window wraps many times
        let whole = try await engine.lastLogits(g.ids)
        let ref = whole.max() ?? 1
        for chunk in [1, 7, 16, 33, 64] {
            engine.chunkLimit = chunk
            let l = try await engine.lastLogits(g.ids)
            let worst = zip(l, whole).map { abs($0 - $1) }.max() ?? 0
            #expect(worst <= 0.06 * max(ref, 1), "chunk \(chunk): largest difference \(worst) of a best logit \(ref)")
            #expect(l.indices.max { l[$0] < l[$1] } == whole.indices.max { whole[$0] < whole[$1] }, "chunk \(chunk): same best token")
        }
    }

    @Test func aKeptPrefixGivesTheSameTextAsAFreshRunAndIsReused() async throws {
        let engine = try Self.engine()
        let g = try #require(try Self.goldens().last)
        let prompt = g.ids
        let fresh = try await engine.generate(GenerationRequest(prompt: prompt, maxTokens: 6, sampling: .greedy)).tokens
        // The same prompt twice with a shared prefix: the second run reuses the kept state.
        let a = try await engine.generate(GenerationRequest(prompt: prompt, maxTokens: 6, sampling: .greedy, sharedPrefix: 100))
        let b = try await engine.generate(GenerationRequest(prompt: prompt, maxTokens: 6, sampling: .greedy, sharedPrefix: 100))
        #expect(a.tokens == fresh && b.tokens == fresh)
        #expect(a.reusedTokens == 0 && b.reusedTokens == 100 - 16, "the state after prefix - 16 tokens is kept")
        // A longer prompt that starts with the kept prefix, and a different one that does not.
        let longer = prompt + [5, 6, 7, 8, 9, 10]
        let c = try await engine.generate(GenerationRequest(prompt: longer, maxTokens: 4, sampling: .greedy, sharedPrefix: 110))
        let d = try await engine.generate(GenerationRequest(prompt: longer, maxTokens: 4, sampling: .greedy))
        #expect(c.tokens == d.tokens && c.reusedTokens == 100 - 16)
        let other = Array(prompt.reversed())
        let e = try await engine.generate(GenerationRequest(prompt: other, maxTokens: 4, sampling: .greedy, sharedPrefix: 100))
        #expect(e.reusedTokens == 0, "a prompt that diverges inside the prefix starts again")
        let f = try await engine.generate(GenerationRequest(prompt: other, maxTokens: 4, sampling: .greedy))
        #expect(e.tokens == f.tokens)
    }

    @Test func aSeedGivesTheSameSampledTextAndTheLoopGuardStopsARepeat() async throws {
        let engine = try Self.engine()
        let g = try #require(try Self.goldens().first)
        let s1 = try await engine.generate(GenerationRequest(prompt: g.ids, maxTokens: 12, sampling: .card(seed: 4))).tokens
        let s2 = try await engine.generate(GenerationRequest(prompt: g.ids, maxTokens: 12, sampling: .card(seed: 4))).tokens
        #expect(s1 == s2 && s1.count == 12)
        // Different seeds give different text from a flat distribution (the sampler itself, on fixed logits).
        let flat = MLXArray([Float](repeating: 0, count: 512))
        var seen = Set<Int32>()
        for seed in 0..<12 as Range<UInt64> {
            var sampler = Sampler(params: .card(seed: seed), vocab: 512)
            if let t = sampler.sample(flat, mask: nil) { seen.insert(t) }
        }
        #expect(seen.count > 4, "a flat distribution is sampled widely")
        var greedy = Sampler(params: .greedy, vocab: 512)
        #expect(greedy.sample(MLXArray((0..<512).map { Float($0 == 77 ? 5 : 0) }), mask: nil) == 77)
        // top-k: only the k best can come out.
        var k3 = Sampler(params: DecodingParameters(temperature: 1, topK: 3, topP: 1, seed: 1), vocab: 512)
        let ranked = MLXArray((0..<512).map { Float($0 % 7) })
        for _ in 0..<50 { #expect(Int(k3.sample(ranked, mask: nil) ?? 0) % 7 == 6, "only tokens of the top logit value can come out") }
        #expect(Gemma4Engine.repeats((0..<3).flatMap { _ in (0..<32).map(Int32.init) }))
        #expect(!Gemma4Engine.repeats(Array(0..<96).map(Int32.init)))
    }

    @Test func theSamplerSaysSoWhenNoAllowedTokenHasAFiniteLogit() {
        var greedy = Sampler(params: .greedy, vocab: 512)
        var card = Sampler(params: .card(seed: 1), vocab: 512)
        let logits = MLXArray((0..<512).map { Float($0 % 9) })
        let none = MLXArray([Float](repeating: -.infinity, count: 512))
        #expect(greedy.sample(logits, mask: none) == nil && card.sample(logits, mask: none) == nil, "an empty allowed set")
        let nan = MLXArray([Float](repeating: .nan, count: 512))
        #expect(greedy.sample(nan, mask: nil) == nil && card.sample(nan, mask: nil) == nil, "all NaN")
        #expect(greedy.sample(logits, mask: nil) == 8 || greedy.sample(logits, mask: nil) == 17, "a normal step still gives a token")
    }

    /// Asks for tokens from an empty set, and can close with one token.
    final class DeadEnd: LogitConstraint, @unchecked Sendable {
        let accepted = Mutex<[Int32]>([])
        func nextMask() -> LogitMask { .allowed([]) }
        func accept(_ token: Int32) { accepted.withLock { $0.append(token) } }
        func closing() -> LogitClosing { .tokens([300]) }
    }

    @Test func anEmptyAllowedSetEndsThroughTheClosingNotThroughAForbiddenToken() async throws {
        let engine = try Self.engine()
        let g = try #require(try Self.goldens().first)
        let c = DeadEnd()
        let r = try await engine.generate(GenerationRequest(prompt: g.ids, maxTokens: 1000, sampling: .greedy), constraint: c)
        #expect(r.finish == .noToken && r.tokens == [300], "\(r.finish) \(r.tokens)")
        #expect(c.accepted.withLock { $0 } == [300], "only the closing token was taken")
    }

    @Test func aGrammarForcesTheOutputToItsShape() async throws {
        let engine = try Self.engine()
        let g = try #require(try Self.goldens().first)
        // A constraint that allows only the tokens 10...12 for 5 steps.
        final class Only: LogitConstraint, @unchecked Sendable {
            var n = 0
            func nextMask() -> LogitMask {
                if n >= 5 { return .forced(1) }
                var bits = [UInt64](repeating: 0, count: 8)
                for t in 10...12 { bits[t >> 6] |= 1 << UInt64(t & 63) }
                return .allowed(bits)
            }
            func accept(_ token: Int32) { n += 1 }
        }
        let out = try await engine.generate(GenerationRequest(prompt: g.ids, maxTokens: 20, sampling: .card(seed: 1)), constraint: Only())
        #expect(out.tokens.count == 5 && out.tokens.allSatisfy { (10...12).contains($0) } && out.finish == .stop)
    }

    @Test func cancellationStopsWithinHalfASecond() async throws {
        let engine = try Self.engine()
        let g = try #require(try Self.goldens().first)
        final class Box: @unchecked Sendable { let engine: Gemma4Engine; init(_ e: Gemma4Engine) { engine = e } }
        let box = Box(engine)
        let prompt = g.ids
        let task = Task.detached {
            try? await box.engine.generate(GenerationRequest(prompt: prompt, maxTokens: 50_000, sampling: .card(seed: 9)))
        }
        try await Task.sleep(for: .milliseconds(300))
        let cancelledAt = Date()
        task.cancel()
        _ = await task.value
        #expect(Date().timeIntervalSince(cancelledAt) < 0.5)
    }
}
