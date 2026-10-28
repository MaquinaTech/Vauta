// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
import MLX
@testable import VautaMLX
@testable import VautaCore

/// The layers that share keys and values (6-8 of the tiny model, 24-41 of the real one) write no cache, so they run only where their
/// output is read: not at all for a prefill chunk whose hidden states are thrown away, and for the last position only otherwise. On
/// prompts longer than the tiny model's window of 16, with chunks that leave the windowed mask causal, an array or absent, the cut
/// run must equal the uncut one: the same cache bits, and the same last hidden state and logits up to bf16 rounding.
@Suite("Language model: the shared layers run only where they are read", .serialized, .gpuExclusive)
struct LanguageModelSharedLayerCutTests {
    static func engine() throws -> Gemma4Engine { try LanguageModelEngineTests.engine() }

    static func worst(_ a: MLXArray, _ b: MLXArray) -> Float {
        abs(a.asType(.float32) - b.asType(.float32)).max().item(Float.self)
    }

    /// Every cache of every owner layer, bit for bit (the full buffers too, zeros past the offset included).
    static func same(_ a: LayerCaches, _ b: LayerCaches) -> Bool {
        guard a.offset == b.offset else { return false }
        for i in a.config.cacheOwners {
            let x = a.full[i].map { [$0.keys, $0.values] } ?? a.sliding[i].map { [$0.keys, $0.values] } ?? []
            let y = b.full[i].map { [$0.keys, $0.values] } ?? b.sliding[i].map { [$0.keys, $0.values] } ?? []
            guard x.count == 2, y.count == 2 else { return false }
            for (p, q) in zip(x, y) {
                guard let p, let q, arrayEqual(p, q).item(Bool.self) else { return false }
            }
        }
        return true
    }

    /// One position computed alone runs other kernels than the same position among the chunk's (matrix-vector products, the vector
    /// attention kernel), so the cut moves the result by bf16 rounding, compounded over the layers after the cut. Measured on an M2:
    /// up to 0.11 on hidden states whose largest entries are 3 to 5, and 0.77 on logits near 28; none at all up to 8 positions,
    /// where MLX picks the same kernels for one position and for several (which depends on the GPU, so it is not asserted). A
    /// wrong RoPE position or a missing window mask after the cut moves the hidden state by up to 1.8 and the logits by up to 14.
    /// The limit is that of the chunked prefill check: 6% of the largest reference value.
    static func close(_ cut: MLXArray, _ reference: MLXArray) -> Bool {
        worst(cut, reference) <= 0.06 * max(abs(reference).max().item(Float.self), 1)
    }

    @Test func theCutGivesTheSameCachesAndTheSameLastHiddenStateAsEveryLayerOnEveryPosition() throws {
        let model = try Self.engine().model
        let prompt = LanguageModelGenerationTests.prompt(150, seed: 11)
        // 1: no cut at all; 5 and 16: a causal mask first, then a windowed array; 17, 40 and 150: an array from the first chunk.
        for chunk in [1, 5, 16, 17, 40, 150] {
            // Every layer on every position (the reference), the last position after the cut on every chunk, and the caches only
            // until the last chunk (what a prefill does).
            let reference = model.newCaches(), last = model.newCaches(), cachesOnly = model.newCaches()
            var i = 0
            while i < prompt.count {
                let j = min(prompt.count, i + chunk)
                let ids = Array(prompt[i..<j])
                let all = try #require(try model.forward(ids, caches: reference, output: .allHidden))
                let h = try #require(try model.forward(ids, caches: last, output: .lastHidden))
                let filled = try model.forward(ids, caches: cachesOnly, output: j == prompt.count ? .lastHidden : .cachesOnly)
                #expect(all.shape == [1, ids.count, model.config.hiddenSize] && h.shape == [1, 1, model.config.hiddenSize])
                #expect((filled == nil) == (j < prompt.count), "only the last chunk gives a hidden state")
                let expected = all[0..., (ids.count - 1)..., 0...]
                eval([all, h] + [filled].compactMap { $0 } + reference.arrays + last.arrays + cachesOnly.arrays)
                let at = "chunk \(chunk), tokens \(i)..<\(j)"
                #expect(Self.same(last, reference) && Self.same(cachesOnly, reference), "\(at): the caches")
                let refLogits = model.logits(expected).reshaped([-1]), cutLogits = model.logits(h).reshaped([-1])
                #expect(Self.close(h, expected), "\(at): hidden state off by \(Self.worst(h, expected))")
                #expect(Self.close(cutLogits, refLogits), "\(at): logits off by \(Self.worst(cutLogits, refLogits))")
                #expect(argMax(cutLogits).item(Int32.self) == argMax(refLogits).item(Int32.self), "\(at): the best token")
                if let filled { #expect(arrayEqual(filled, h).item(Bool.self), "\(at): a prefill's last chunk is the same as a cut one") }
                i = j
            }
        }
    }

    /// What `layerProbe` reports: the positions each layer ran its queries for, one list per `forward`.
    final class LayerTrace {
        var runs: [[Int]] = []
        func attach(_ model: Gemma4TextModel) {
            model.layerProbe = { [self] layer, positions in
                if layer == 0 { runs.append([]) }
                runs[runs.count - 1].append(positions)
            }
        }
    }

    /// The parity tests pass just as well when nothing is cut, so this one checks that the cut is made, and where.
    @Test func theSharedLayersRunOnTheLastPositionOnlyAndNotAtAllForTheCachesOnly() throws {
        let model = try Self.engine().model
        let trace = LayerTrace()
        trace.attach(model)
        defer { model.layerProbe = nil }
        // The tiny model: layers 0-5 own keys and values and 6-8 read them, so the cut is at layer 5 (`firstSharedLayer - 1`).
        let (layers, cut) = (model.config.layers, model.config.firstSharedLayer - 1)
        #expect(layers == 9 && cut == 5)
        let prompt = LanguageModelGenerationTests.prompt(40, seed: 2)
        let expected: [(Gemma4TextModel.ForwardOutput, [Int])] = [
            (.allHidden, Array(repeating: 40, count: layers)),
            // Layer 5 writes its keys and values from all 40 positions, then runs its queries on the last one only.
            (.lastHidden, Array(repeating: 40, count: cut) + Array(repeating: 1, count: layers - cut)),
            // Layer 5 writes its keys and values, and nothing runs after that.
            (.cachesOnly, Array(repeating: 40, count: cut)),
        ]
        for (output, positions) in expected {
            trace.runs = []
            _ = try model.forward(prompt, caches: model.newCaches(), output: output)
            #expect(trace.runs == [positions], "\(output)")
        }
        // One position: nothing to cut.
        trace.runs = []
        _ = try model.forward([7], caches: model.newCaches(), output: .lastHidden)
        #expect(trace.runs == [Array(repeating: 1, count: layers)])
    }

    @Test func aPrefillRunsTheSharedLayersOnlyOnTheLastPositionOfAPromptThatIsDecodedFrom() async throws {
        let engine = try Self.engine()
        let trace = LayerTrace()
        trace.attach(engine.model)
        defer { engine.model.layerProbe = nil; engine.cutsSharedLayers = true }
        let (layers, cut) = (engine.model.config.layers, engine.model.config.firstSharedLayer - 1)
        func cachesOnly(_ n: Int) -> [Int] { Array(repeating: n, count: cut) }
        func last(_ n: Int) -> [Int] { Array(repeating: n, count: cut) + Array(repeating: 1, count: layers - cut) }
        func every(_ n: Int) -> [Int] { Array(repeating: n, count: layers) }
        engine.fixedChunk = 33
        let prompt = LanguageModelGenerationTests.prompt(150, seed: 4)
        // 150 tokens: four chunks of 33 that only fill the caches and a last one of 18; then the decode, one position a step.
        _ = try await engine.generate(GenerationRequest(prompt: prompt, maxTokens: 3))
        #expect(Array(trace.runs.prefix(5)) == [cachesOnly(33), cachesOnly(33), cachesOnly(33), cachesOnly(33), last(18)])
        #expect(trace.runs.dropFirst(5).allSatisfy { $0 == every(1) })
        // A kept prefix of 100 - 16 = 84 tokens only fills the caches (33, 33, 18); the 66 tokens after it are two chunks of 33.
        trace.runs = []
        let kept = try await engine.generate(GenerationRequest(prompt: prompt, maxTokens: 1, sharedPrefix: 100))
        #expect(kept.reusedTokens == 0)
        #expect(trace.runs == [cachesOnly(33), cachesOnly(33), cachesOnly(18), cachesOnly(33), last(33)])
        // A decode step that feeds the five tokens a grammar forces is cut the same way.
        trace.runs = []
        _ = try await engine.generate(GenerationRequest(prompt: Array(prompt.prefix(20)), maxTokens: 12), constraint: Forced())
        #expect(Array(trace.runs.prefix(3)) == [last(20), every(1), last(5)])
        // The path of the golden check against mlx-lm (`lastLogits`), and the reference, which runs every layer on every position.
        for (cuts, expected) in [(true, [cachesOnly(33), last(7)]), (false, [every(33), every(7)])] {
            engine.cutsSharedLayers = cuts
            trace.runs = []
            _ = try await engine.lastLogits(Array(prompt.prefix(40)))
            #expect(trace.runs == expected, "cuts \(cuts)")
        }
    }

    /// Forces a few tokens at once (a decode step that feeds several positions, as a grammar does), then writes freely.
    final class Forced: LogitConstraint, @unchecked Sendable {
        var step = 0
        func nextMask() -> LogitMask {
            step += 1
            return step == 2 ? .forcedSequence([20, 21, 22, 23, 24]) : .free
        }
        func accept(_ token: Int32) {}
    }

    @Test func greedyTextColdAndFromAKeptPrefixIsTheSameAsWithEveryLayerOnEveryPosition() async throws {
        let engine = try Self.engine()
        defer { engine.cutsSharedLayers = true }
        for (n, seed) in [(40, 3), (150, 5), (300, 8)] as [(Int, UInt64)] {
            let prompt = LanguageModelGenerationTests.prompt(n, seed: seed)
            for chunk in [7, 33, 512] {
                engine.fixedChunk = chunk
                var runs: [[[Int32]]] = []
                var logits: [[Float]] = []
                for cut in [false, true] {
                    engine.cutsSharedLayers = cut
                    engine.dropKeptPrefix()
                    let cold = try await engine.generate(GenerationRequest(prompt: prompt, maxTokens: 8)).tokens
                    // The first run keeps the prefix (caches only), the second continues from it.
                    let keeping = try await engine.generate(GenerationRequest(prompt: prompt, maxTokens: 8, sharedPrefix: n - 4))
                    let kept = try await engine.generate(GenerationRequest(prompt: prompt, maxTokens: 8, sharedPrefix: n - 4))
                    #expect(keeping.reusedTokens == 0 && kept.reusedTokens == n - 4 - 16)
                    let forced = try await engine.generate(GenerationRequest(prompt: prompt, maxTokens: 12), constraint: Forced()).tokens
                    runs.append([cold, keeping.tokens, kept.tokens, forced])
                    logits.append(try await engine.lastLogits(prompt))
                }
                let at = "\(n) tokens, chunk \(chunk)"
                #expect(runs[0] == runs[1], "\(at): the same text without and with the cut")
                #expect(runs[1][0] == runs[1][1] && runs[1][0] == runs[1][2], "\(at): a kept prefix gives the cold text")
                #expect(Self.close(MLXArray(logits[1]), MLXArray(logits[0])), "\(at): the last logits")
            }
        }
    }
}
