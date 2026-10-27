// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The grammar masks over the REAL 262k-token vocabulary. Needs only the installed model's tokenizer (VAUTA_LLM_MODEL_DIR), not
/// its weights. `VAUTA_LLM_WALKS` (default 6 per schema) sets the random walks; the design's 10,000-walk check is run once as a tool
/// job with `VAUTA_LLM_WALKS=10000` and its result is recorded in docs/LANGUAGE_MODEL.md.
@Suite("Language model: grammar masks on the real vocabulary", .serialized)
struct LanguageModelRealVocabularyTests {
    struct Walk { var bytes: [UInt8]; var durations: [Double]; var ended: Bool }

    static func walk(_ constraint: SchemaConstraint, tokenizer: GemmaTokenizer, seed: UInt64, maxSteps: Int = 6_000) -> Walk {
        var rng = SyntheticLanguageModel.SplitMix(seed)
        var out: [UInt8] = []
        var steps = 0
        while steps < maxSteps {
            steps += 1
            let tokens: [Int32]
            switch constraint.nextMask() {
            case .free: return Walk(bytes: out, durations: constraint.stats.maskDurations, ended: false)
            case .forced(let t): tokens = [t]
            case .forcedSequence(let ts): tokens = ts
            case .allowed(let bits):
                // A uniformly random allowed token, picked by counting bits instead of listing a hundred thousand ids.
                let total = bits.reduce(0) { $0 + $1.nonzeroBitCount }
                guard total > 0 else { return Walk(bytes: out, durations: constraint.stats.maskDurations, ended: false) }
                var k = Int(rng.next() % UInt64(total))
                var chosen: Int32 = 0
                for w in 0..<bits.count {
                    let n = bits[w].nonzeroBitCount
                    if k >= n { k -= n; continue }
                    var word = bits[w]
                    for _ in 0..<k { word &= word - 1 }
                    chosen = Int32(w * 64 + word.trailingZeroBitCount)
                    break
                }
                tokens = [chosen]
            }
            for t in tokens {
                if t == SchemaConstraint.stopToken { return Walk(bytes: out, durations: constraint.stats.maskDurations, ended: true) }
                constraint.accept(t)
                out += tokenizer.tokenBytes(t)
            }
        }
        return Walk(bytes: out, durations: constraint.stats.maskDurations, ended: false)
    }

    static func percentile(_ d: [Double], _ p: Double) -> Double {
        let s = d.sorted()
        return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count - 1) * p))]
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VAUTA_LLM_MODEL_DIR"] != nil), .timeLimit(.minutes(120)))
    func masksOnTheRealVocabularyAreFastAndEveryWalkThatEndsParses() async throws {
        let env = ProcessInfo.processInfo.environment
        let walks = Int(env["VAUTA_LLM_WALKS"] ?? "") ?? 6
        let engine = LanguageModelEngine(store: LanguageModelSelfTest.store())
        let tokenizer = try await engine.loadedTokenizer()
        let offered = OutputSchemas.Offered(segments: Set(1...400), entities: Set(1...12), documents: Set(1...6))
        let schemas: [(String, OutputSchema)] = [("minutes", OutputSchemas.minutes(offered)), ("answer", OutputSchemas.answer(offered)),
                                                 ("live", OutputSchemas.liveNotes(offered)), ("noteBatch", OutputSchemas.noteBatch(count: 3, offered))]
        // The first constraint of the process builds the trie of the 262k tokens.
        let t0 = Date()
        _ = SchemaConstraint(schema: schemas[0].1, tokenizer: tokenizer)
        let build = Date().timeIntervalSince(t0)
        print("grammar: first constraint (builds the TokenIndex of \(tokenizer.vocabularySize) tokens) \(String(format: "%.3f", build)) s")
        var all: [Double] = []
        for (name, schema) in schemas {
            var durations: [Double] = [], ended = 0, parsed = 0
            for seed in 0..<walks {
                let c = SchemaConstraint(schema: schema, tokenizer: tokenizer)
                let w = Self.walk(c, tokenizer: tokenizer, seed: UInt64(1_000 + seed))
                durations += w.durations
                if w.ended {
                    ended += 1
                    if (try? JSONSerialization.jsonObject(with: Data(w.bytes))) is [String: Any] { parsed += 1 } else { Issue.record("\(name) walk \(seed) did not parse: \(String(decoding: w.bytes.prefix(300), as: UTF8.self))") }
                }
            }
            all += durations
            print("grammar: \(name) \(walks) walks, \(ended) ended, \(parsed) parsed, \(durations.count) masks: p50 \(String(format: "%.2f", Self.percentile(durations, 0.5) * 1000)) ms, p99 \(String(format: "%.2f", Self.percentile(durations, 0.99) * 1000)) ms, max \(String(format: "%.2f", (durations.max() ?? 0) * 1000)) ms")
            #expect(parsed == ended)
        }
        // Loose bounds so a loaded shared Mac does not fail it; the numbers above are the evidence.
        #expect(Self.percentile(all, 0.5) < 0.020, "median mask \(Self.percentile(all, 0.5)) s")
        #expect(Self.percentile(all, 0.99) < 0.250, "p99 mask \(Self.percentile(all, 0.99)) s")
    }
}
