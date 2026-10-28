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
