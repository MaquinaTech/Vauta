// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// A small vocabulary: every byte, a control token and some multi-byte pieces that cross grammar boundaries.
enum ToyVocabulary {
    static let pieces = ["{\"", "\":", "\",\"", "\"}", "\"]", "]}", "},{", ",\"", "true", "false", "null", "text", "seg", "\\n", "\\u00e9", "é", "日本", "[]", "\",", "12", "-0"]
    static let controlID = 0
    /// Built once: the random walks read it at every step.
    static let bytes: [[UInt8]] = [[]] + (0..<256).map { [UInt8($0)] } + pieces.map { Array($0.utf8) }
    static let control: [Bool] = [Bool](repeating: false, count: bytes.count).enumerated().map { $0.offset == 0 }
    static let index = TokenIndex(bytes: bytes, control: control)

    /// Greedy longest-match tokenisation over the toy pieces (every byte is a token, so this is total).
    static func encode(_ s: String) -> [Int32] {
        let b = Array(s.utf8)
        var out: [Int32] = []
        var i = 0
        while i < b.count {
            var best = (1, Int32(1 + Int(b[i])))
            for (k, p) in pieces.enumerated() {
                let pb = Array(p.utf8)
                if pb.count > best.0, i + pb.count <= b.count, Array(b[i..<(i + pb.count)]) == pb { best = (pb.count, Int32(257 + k)) }
            }
            out.append(best.1)
            i += best.0
        }
        return out
    }

    static func constraint(_ schema: OutputSchema, whitespace: Bool = false) -> SchemaConstraint {
        SchemaConstraint(grammar: SchemaGrammar(schema, whitespace: whitespace), stop: Int32(controlID), index: index, encode: { encode($0) }, bytes: { id in bytes[Int(id)] })
    }

    /// One random walk to the end of the value: the bytes written. `preferClose` biases towards ending strings and arrays.
    static func walk(_ schema: OutputSchema, seed: UInt64, maxSteps: Int = 40_000, whitespace: Bool = false) -> [UInt8]? {
        let c = constraint(schema, whitespace: whitespace)
        var rng = SyntheticLanguageModel.SplitMix(seed)
        var out: [UInt8] = []
        var steps = 0
        while steps < maxSteps {
            steps += 1
            let tokens: [Int32]
            switch c.nextMask() {
            case .free: return nil
            case .forced(let t): tokens = [t]
            case .forcedSequence(let ts): tokens = ts
            case .allowed(let bits):
                var ids: [Int32] = []
                var preferred: [Int32] = []
                for w in 0..<bits.count where bits[w] != 0 {
                    for b in 0..<64 where bits[w] & (1 << UInt64(b)) != 0 {
                        let id = Int32(w * 64 + b)
                        ids.append(id)
                        let bytes = Self.bytes[Int(id)]
                        if bytes.contains(UInt8(ascii: "\"")) || bytes.contains(UInt8(ascii: "]")) || bytes.contains(UInt8(ascii: "}")) { preferred.append(id) }
                    }
                }
                guard !ids.isEmpty else {
                    Issue.record("an empty mask at step \(steps): the grammar is in a dead state")
                    return nil
                }
                let pool = (!preferred.isEmpty && rng.next() % 6 == 0) ? preferred : ids
                tokens = [pool[Int(rng.next() % UInt64(pool.count))]]
            }
            for t in tokens {
                if t == Int32(ToyVocabulary.controlID) { return out }
                c.accept(t)
                out += bytes[Int(t)]
            }
        }
        return nil
    }
}

@Suite("Language model: constrained decoding")
struct LanguageModelConstraintTests {
    @Test func everySchemaCompilesAndStartsWithABraceOnly() {
        let offered = OutputSchemas.Offered(segments: [1, 2, 30], entities: [5, 6], documents: [1, 2])
        for schema in [OutputSchemas.minutes(offered), OutputSchemas.minutesExtract(offered), OutputSchemas.liveNotes(offered), OutputSchemas.noteSingle(offered),
                       OutputSchemas.noteBatch(count: 3, offered), OutputSchemas.answer(offered), OutputSchemas.answer(offered, documents: true), OutputSchemas.minutes()] {
            let c = ToyVocabulary.constraint(schema)
            // The first byte is forced: `{` (no code fence, no prose), written without asking the model.
            switch c.nextMask() {
            case .forcedSequence(let ts): #expect(ToyVocabulary.bytes[Int(ts[0])].first == UInt8(ascii: "{"))
            case .forced(let t): #expect(ToyVocabulary.bytes[Int(t)].first == UInt8(ascii: "{"))
            default: Issue.record("the first token must be forced")
            }
            #expect(!schema.jsonSchemaData().isEmpty)
        }
    }

    @Test func randomWalksAlwaysParseWithTheAppsOwnDecoders() throws {
        let offered = OutputSchemas.Offered(segments: [3, 4, 5, 120], entities: [7, 8], documents: [1, 2])
        var counts = (minutes: 0, answer: 0, live: 0, notes: 0)
        for seed in 0..<25 {
            let s = UInt64(seed)
            if let bytes = ToyVocabulary.walk(OutputSchemas.minutes(offered), seed: s) {
                let text = String(decoding: bytes, as: UTF8.self)
                let raw = try ModelOutput.decodeObject(VautaPrompts.RawMinutes.self, from: text)
                _ = raw
                try Self.expectStrictJSON(bytes)
                #expect(bytes.starts(with: Array("{\"title\":\"".utf8)) && bytes.last == UInt8(ascii: "}"), "no text before or after the object")
                counts.minutes += 1
            }
            if let bytes = ToyVocabulary.walk(OutputSchemas.answer(offered), seed: s) {
                _ = try ModelOutput.decodeObject(VautaPrompts.RawAnswer.self, from: String(decoding: bytes, as: UTF8.self))
                try Self.expectStrictJSON(bytes)
                counts.answer += 1
            }
            if let bytes = ToyVocabulary.walk(OutputSchemas.liveNotes(offered), seed: s) {
                _ = try ModelOutput.decodeObject(VautaPrompts.RawLiveNotes.self, from: String(decoding: bytes, as: UTF8.self))
                try Self.expectStrictJSON(bytes)
                counts.live += 1
            }
            if let bytes = ToyVocabulary.walk(OutputSchemas.noteBatch(count: 2, offered), seed: s) {
                _ = try ModelOutput.decodeObject(VautaPrompts.RawNoteExpansion.self, from: String(decoding: bytes, as: UTF8.self))
                try Self.expectStrictJSON(bytes)
                counts.notes += 1
            }
        }
        #expect(counts.minutes > 15 && counts.answer > 15 && counts.live > 15 && counts.notes > 15, "most walks reach the end: \(counts)")
    }

    static func expectStrictJSON(_ bytes: [UInt8]) throws {
        let obj = try JSONSerialization.jsonObject(with: Data(bytes))
        #expect(obj is [String: Any], "strict JSON, one object")
    }

    @Test func segmentsAndEntitiesAreRestrictedToWhatWasOffered() throws {
        let offered = OutputSchemas.Offered(segments: [3, 4, 5, 120], entities: [7, 8], documents: nil)
        for seed in 0..<80 {
            guard let bytes = ToyVocabulary.walk(OutputSchemas.minutes(offered), seed: UInt64(seed)) else { continue }
            let json = try #require(JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
            for d in json["decisions"] as? [[String: Any]] ?? [] { #expect([3, 4, 5, 120].contains(d["seg"] as? Int ?? -1)) }
            for t in json["tasks"] as? [[String: Any]] ?? [] {
                #expect([3, 4, 5, 120].contains(t["seg"] as? Int ?? -1))
                if let id = t["owner_id"] as? Int { #expect([7, 8].contains(id)) } else { #expect(t["owner_id"] is NSNull) }
                if let due = t["due"] as? String {
                    #expect(due.range(of: #"^[1-9]\d{3}-[01]\d-[0-3]\d$"#, options: .regularExpression) != nil, "due is a date: \(due)")
                } else { #expect(t["due"] is NSNull) }
            }
            for e in json["entities"] as? [[String: Any]] ?? [] { if let id = e["id"] as? Int { #expect([7, 8].contains(id)) } }
            #expect((json["topics"] as? [Any] ?? []).count <= 8 && (json["open_questions"] as? [Any] ?? []).count <= 10)
        }
    }

    @Test func documentCitationsAreSegmentOrDocumentStrings() throws {
        let offered = OutputSchemas.Offered(segments: [3, 4], entities: nil, documents: [1, 2])
        for seed in 0..<80 {
            guard let bytes = ToyVocabulary.walk(OutputSchemas.answer(offered, documents: true), seed: UInt64(seed)) else { continue }
            let json = try #require(JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
            for c in json["claims"] as? [[String: Any]] ?? [] {
                for cite in c["citations"] as? [String] ?? [] { #expect(["S3", "S4", "D1", "D2"].contains(cite)) }
            }
        }
    }

    @Test func theMaskEqualsABruteForceCheckOfEveryToken() {
        let offered = OutputSchemas.Offered(segments: [3, 40], entities: [7], documents: nil)
        let g = SchemaGrammar(OutputSchemas.liveNotes(offered))
        let engine = TokenMaskEngine(grammar: g, index: ToyVocabulary.index)
        var rng = SyntheticLanguageModel.SplitMix(5)
        var state = GrammarState.start(g)
        var checked = 0
        for _ in 0..<400 {
            // Mask against brute force.
            let mask = engine.mask(for: state)
            for t in 1..<ToyVocabulary.bytes.count {
                var s = state
                var ok = !state.isFinished
                for b in ToyVocabulary.bytes[t] where ok { ok = s.step(b, g) }
                let bit = mask[t >> 6] & (1 << UInt64(t & 63)) != 0
                #expect(bit == ok, "token \(t) \(ToyVocabulary.bytes[t]) in state \(state.stack)")
                if bit != ok { return }
            }
            checked += 1
            // Take a random step (a forced byte if there is only one).
            guard !state.isFinished else { break }
            let allowed = ToyVocabulary.bytes.indices.dropFirst().filter { mask[$0 >> 6] & (1 << UInt64($0 & 63)) != 0 }
            guard let pick = allowed.randomElement(using: &rng) else { break }
            for b in ToyVocabulary.bytes[pick] { _ = state.step(b, g) }
        }
        #expect(checked > 100)
    }

    @Test func afterTheRootObjectOnlyTheStopTokenIsPossible() {
        let c = ToyVocabulary.constraint(.object([.init("a", .boolean)]))
        for b in Array("{\"a\":true}".utf8) { c.accept(Int32(1 + Int(b))) }
        #expect(c.isComplete)
        if case .forced(let t) = c.nextMask() { #expect(t == Int32(ToyVocabulary.controlID)) } else { Issue.record("expected the stop token") }
    }

    @Test func aDateCannotHaveAnImpossibleMonthOrDay() {
        let g = SchemaGrammar(.object([.init("d", .date)]))
        let start = GrammarState.start(g)
        func accepts(_ date: String) -> Bool {
            let r = Self.feed(start, Array(("{\"d\":\"" + date + "\"}").utf8), g)
            return r.ok && r.state.isFinished
        }
        for good in ["2026-10-13", "2026-01-31", "2024-02-29", "2026-12-31", "2026-04-30"] { #expect(accepts(good), "\(good)") }
        for bad in ["2026-00-10", "2026-13-01", "2026-19-01", "2026-10-00", "2026-10-32", "2026-10-39", "2026-02-30", "2026-04-31", "2026-1-01", "0999-10-10"] {
            #expect(!accepts(bad), "\(bad)")
        }
        // The shortest ending of a date in progress is a real date.
        let r = Self.feed(start, Array("{\"d\":\"2026-1".utf8), g)
        if case .bytes(let b) = r.state.shortestCompletion(g) { #expect(String(decoding: b, as: UTF8.self) == "0-01\"}") } else { Issue.record("expected a completion") }
    }

    @Test func aTokenTheGrammarRefusesIsCountedAndEndsTheOutputInsteadOfLeavingAWrongState() {
        let c = ToyVocabulary.constraint(.object([.init("a", .boolean)]))
        c.accept(Int32(1 + Int(UInt8(ascii: "["))))   // an object cannot start with "["
        #expect(c.stats.stepFailures == 1)
        if case .forced(let t) = c.nextMask() { #expect(t == Int32(ToyVocabulary.controlID)) } else { Issue.record("expected the stop token") }
        #expect(c.closing() == .unsupported)
        #expect(!c.isComplete)
    }

    /// Feeds `text` to a copy of the state; returns whether every byte was accepted and the new state.
    static func feed(_ state: GrammarState, _ text: [UInt8], _ g: SchemaGrammar) -> (ok: Bool, state: GrammarState) {
        var s = state
        for b in text where !s.step(b, g) { return (false, s) }
        return (true, s)
    }

    @Test func stringsKeepToTheirByteBudgetAndEscapes() {
        let g = SchemaGrammar(.object([.init("t", .string(maxBytes: 5))]))
        let start = Self.feed(GrammarState.start(g), Array("{\"t\":\"abc".utf8), g)
        #expect(start.ok)
        let escaped = Self.feed(start.state, Array("\\n".utf8), g)
        #expect(escaped.ok, "an escape takes two bytes of the budget")
        #expect(!Self.feed(escaped.state, Array("x".utf8), g).ok, "the budget is used up: only the quote may follow")
        #expect(Self.feed(escaped.state, Array("\"}".utf8), g).ok)
        #expect(!Self.feed(start.state, [0x0A], g).ok, "a raw control character is never allowed in a string")
        #expect(!Self.feed(start.state, [0xC0], g).ok && !Self.feed(start.state, [0xF5], g).ok, "overlong and out-of-range UTF-8 lead bytes are refused")
        #expect(!Self.feed(start.state, [0xC3, UInt8(ascii: "a")], g).ok, "a lead byte must be followed by a continuation byte")
        #expect(Self.feed(start.state, [0xC3, 0xA9], g).ok)
        #expect(!Self.feed(start.state, [0xE2, 0x82, 0xAC], g).ok, "a 3-byte character does not fit in the 2 bytes left")
    }

    @Test func numbersHaveNoLeadingZerosAndRespectTheirDigitBudget() {
        let g = SchemaGrammar(.object([.init("n", .anyInteger(maxDigits: 3))]))
        let zero = Self.feed(GrammarState.start(g), Array("{\"n\":0".utf8), g)
        #expect(zero.ok && !Self.feed(zero.state, Array("1".utf8), g).ok, "0 is a whole number: no digit may follow it")
        let three = Self.feed(GrammarState.start(g), Array("{\"n\":123".utf8), g)
        #expect(three.ok && !Self.feed(three.state, Array("4".utf8), g).ok && Self.feed(three.state, Array("}".utf8), g).ok)
    }

    @Test func theSchemasAreTheShapesOfThePrompts() throws {
        let m = OutputSchemas.minutes().jsonSchema as! [String: Any]
        #expect((m["required"] as? [String]) == ["title", "summary", "topics", "decisions", "tasks", "entities", "open_questions"])
        let live = OutputSchemas.liveNotes().jsonSchema as! [String: Any]
        #expect((live["required"] as? [String]) == ["points", "decisions", "tasks"])
        // The answer is one of two objects, chosen by `found`, which comes first.
        let a = OutputSchemas.answer().jsonSchema as! [String: Any]
        let branches = try #require(a["anyOf"] as? [[String: Any]])
        #expect(branches.count == 2 && branches.allSatisfy { ($0["required"] as? [String]) == ["found", "answer", "claims"] })
        let ex = OutputSchemas.minutesExtract().jsonSchema as! [String: Any]
        #expect((ex["required"] as? [String])?.first == "summary", "an extract has no title")
    }

    @Test func masksAreFastEnoughOnTheToyVocabularyAndCached() {
        let g = SchemaGrammar(OutputSchemas.minutes(.init(segments: Set(1...500), entities: [1], documents: nil)))
        let engine = TokenMaskEngine(grammar: g, index: ToyVocabulary.index)
        var s = GrammarState.start(g)
        for b in Array("{\"title\":\"ab".utf8) { _ = s.step(b, g) }
        let first = cpuSeconds { _ = engine.mask(for: s) }
        let cached = cpuSeconds { for _ in 0..<1000 { _ = engine.mask(for: s) } }
        #expect(!TestTiming.holdsBudgets || cached / 1000 < 0.001 || first < 0.5)
        #expect(!TestTiming.holdsBudgets || first < 1.0)
    }
}
