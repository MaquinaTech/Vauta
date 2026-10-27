// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// `Gemma4Engine.closeSlack` (VautaMLX is not visible from here).
private let Gemma4EngineCloseSlack = 64

@Suite("Language model: surrogates, closing a value early, empty sets")
struct LanguageModelClosingTests {
    // MARK: Surrogates

    static func stringGrammar() -> SchemaGrammar { SchemaGrammar(.object([.init("t", .string(maxBytes: 64))])) }

    static func inString(_ g: SchemaGrammar) -> GrammarState {
        var s = GrammarState.start(g)
        for b in Array("{\"t\":\"".utf8) { _ = s.step(b, g) }
        return s
    }

    @Test func aSurrogateEscapeIsNeverAllowed() {
        let g = Self.stringGrammar()
        let start = Self.inString(g)
        // `\ud83d` (a high surrogate) and `\ude00` (a low one alone): refused at the second digit, so a lone surrogate cannot be written.
        for text in ["\\ud83d", "\\uD83D", "\\ude00", "\\uDC00", "\\udfff", "\\uD800", "\\ud8", "\\uDb"] {
            #expect(!LanguageModelConstraintTests.feed(start, Array(text.utf8), g).ok, "\(text) must be refused")
        }
        // The digits just outside D800...DFFF stay allowed, and so does every other escape.
        for text in ["\\ud7ff", "\\uD7FF", "\\ue000", "\\uE000", "\\u00e9", "\\u0000", "\\ud0ab", "\\uffff", "\\n", "\\\"", "\\\\"] {
            #expect(LanguageModelConstraintTests.feed(start, Array(text.utf8), g).ok, "\(text) is allowed")
        }
        #expect(LanguageModelConstraintTests.feed(start, Array("\\ud7ff\\ue000\\u00e9\\n".utf8), g).ok)
        // The mask after `\ud` offers only 0...7 (and none of 8...f).
        let afterD = LanguageModelConstraintTests.feed(start, Array("\\ud".utf8), g).state
        let allowed = afterD.allowed(g)
        #expect((0x30...0x37).allSatisfy { allowed.contains(UInt8($0)) } && !allowed.contains(0x38) && !allowed.contains(UInt8(ascii: "a")) && !allowed.contains(UInt8(ascii: "F")))
        // An astral character is written as raw UTF-8 (4 bytes), which stays allowed.
        #expect(LanguageModelConstraintTests.feed(start, Array("😀".utf8), g).ok)
    }

    @Test func textWithAnEscapedAstralCharacterNeverComesOutButStillParses() throws {
        // Every walk over a string schema is strict JSON that both decoders accept, whatever bytes the walk picked.
        let schema = OutputSchema.object([.init("t", .string(maxBytes: 200))])
        for seed in 0..<200 {
            guard let bytes = ToyVocabulary.walk(schema, seed: UInt64(seed)) else { continue }
            let json = try #require(JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
            #expect(json["t"] is String)
            struct T: Decodable { let t: String }
            _ = try JSONDecoder().decode(T.self, from: Data(bytes))
        }
    }

    // MARK: Closing early

    /// Writes random allowed tokens until `steps` have passed (or the value ends), then closes. Returns the bytes and whether
    /// the closing happened.
    static func walkThenClose(_ schema: OutputSchema, seed: UInt64, steps: Int) -> (bytes: [UInt8], closed: Bool, closingTokens: Int)? {
        let c = ToyVocabulary.constraint(schema)
        var rng = SyntheticLanguageModel.SplitMix(seed)
        var out: [UInt8] = []
        var n = 0
        var closingTokens = 0
        var pending = 0
        while true {
            let closing = n >= steps ? c.closing() : nil
            if let closing {
                switch closing {
                case .tokens(let ts):
                    closingTokens = ts.count
                    for t in ts { c.accept(t); out += ToyVocabulary.bytes[Int(t)] }
                    return (out, c.isComplete, closingTokens)
                case .unsupported: return nil
                case .notYet:
                    pending += 1
                    if pending > 8 { return nil }
                }
            }
            let tokens: [Int32]
            switch c.nextMask() {
            case .free: return nil
            case .forced(let t): if t == Int32(ToyVocabulary.controlID) { return (out, c.isComplete, 0) }; tokens = [t]
            case .forcedSequence(let ts): tokens = ts
            case .allowed(let bits):
                var ids: [Int32] = []
                for w in 0..<bits.count where bits[w] != 0 { for b in 0..<64 where bits[w] & (1 << UInt64(b)) != 0 { ids.append(Int32(w * 64 + b)) } }
                guard !ids.isEmpty else { return nil }
                tokens = [ids[Int(rng.next() % UInt64(ids.count))]]
            }
            for t in tokens { c.accept(t); out += ToyVocabulary.bytes[Int(t)] }
            n += tokens.count
        }
    }

    @Test func closingAtAnyPointGivesValidJSONThatEveryDecoderAccepts() throws {
        let offered = OutputSchemas.Offered(segments: [3, 4, 5, 120], entities: [7, 8], documents: [1, 2])
        let schemas: [(String, OutputSchema)] = [("minutes", OutputSchemas.minutes(offered)), ("extract", OutputSchemas.minutesExtract(offered)),
                                                 ("live", OutputSchemas.liveNotes(offered)), ("answer", OutputSchemas.answer(offered)),
                                                 ("answerDocs", OutputSchemas.answer(offered, documents: true)),
                                                 ("answerLive", OutputSchemas.answer(offered, live: true, laterGuard: true)), ("noteBatch", OutputSchemas.noteBatch(count: 3, offered)),
                                                 ("noteSingle", OutputSchemas.noteSingle(offered)), ("minutesAny", OutputSchemas.minutes())]
        var closedInsideString = 0
        var total = 0
        for (name, schema) in schemas {
            for seed in 0..<14 {
                for steps in [0, 2, 9, 30, 90, 300] {
                    guard let r = Self.walkThenClose(schema, seed: UInt64(seed), steps: steps) else {
                        Issue.record("\(name) seed \(seed) steps \(steps): no way to close")
                        continue
                    }
                    total += 1
                    #expect(r.closed, "\(name): the grammar is complete after the closing")
                    do {
                        let obj = try JSONSerialization.jsonObject(with: Data(r.bytes))
                        #expect(obj is [String: Any])
                    } catch { Issue.record("\(name) seed \(seed) steps \(steps): not JSON: \(String(decoding: r.bytes, as: UTF8.self).suffix(120))"); return }
                    if name == "minutes" { _ = try ModelOutput.decodeObject(VautaPrompts.RawMinutes.self, from: String(decoding: r.bytes, as: UTF8.self)); closedInsideString += 1 }
                    if name == "live" { _ = try ModelOutput.decodeObject(VautaPrompts.RawLiveNotes.self, from: String(decoding: r.bytes, as: UTF8.self)) }
                    if name == "answer" || name == "answerLive" { _ = try ModelOutput.decodeObject(VautaPrompts.RawAnswer.self, from: String(decoding: r.bytes, as: UTF8.self)) }
                }
            }
        }
        #expect(total > 600 && closedInsideString > 0)
    }

    @Test func theShortestCompletionIsShortAndIsTheLeastValue() throws {
        let g = SchemaGrammar(OutputSchemas.liveNotes(.init(segments: [4, 9])))
        // From the very start: every array empty.
        let start = GrammarState.start(g)
        if case .bytes(let b) = start.shortestCompletion(g) { #expect(String(decoding: b, as: UTF8.self) == "{\"points\":[],\"decisions\":[],\"tasks\":[]}") } else { Issue.record("no completion") }
        // Inside the first string of a point: close it and fill the rest with the least values (seg = the smallest offered, owner null).
        var s = GrammarState.start(g)
        for b in Array("{\"points\":[{\"text\":\"ab".utf8) { _ = s.step(b, g) }
        guard case .bytes(let rest) = s.shortestCompletion(g) else { Issue.record("no completion"); return }
        let full = "{\"points\":[{\"text\":\"ab" + String(decoding: rest, as: UTF8.self)
        #expect(full == "{\"points\":[{\"text\":\"ab\",\"seg\":4}],\"decisions\":[],\"tasks\":[]}", "\(full)")
        // In the middle of an escape or a character: not yet.
        var e = GrammarState.start(g)
        for b in Array("{\"points\":[{\"text\":\"a\\u00".utf8) { _ = e.step(b, g) }
        #expect(e.shortestCompletion(g) == .pending)
        var u = GrammarState.start(g)
        for b in Array("{\"points\":[{\"text\":\"é".utf8.dropLast()) { _ = u.step(b, g) }
        #expect(u.shortestCompletion(g) == .pending)
        // A number in the middle of its digits is complete as it stands.
        let n = SchemaGrammar(.object([.init("n", .anyInteger(maxDigits: 5)), .init("m", .nullable(.date))]))
        var ns = GrammarState.start(n)
        for b in Array("{\"n\":12".utf8) { _ = ns.step(b, n) }
        if case .bytes(let b) = ns.shortestCompletion(n) { #expect(String(decoding: b, as: UTF8.self) == ",\"m\":null}") } else { Issue.record("no completion") }
        // A closed set: the shortest member from where the walk is.
        let e2 = SchemaGrammar(.object([.init("k", .enumStrings(["alpha", "be", "beta"]))]))
        var es = GrammarState.start(e2)
        for b in Array("{\"k\":\"b".utf8) { _ = es.step(b, e2) }
        if case .bytes(let b) = es.shortestCompletion(e2) { #expect(String(decoding: b, as: UTF8.self) == "e\"}") } else { Issue.record("no completion") }
    }

    @Test func oneTokenNeverGrowsTheClosingByMoreThanTheSlack() {
        // The engine closes when `closing + closeSlack` reaches the room left, so one more token must not add more than the slack.
        // The toy vocabulary has a token for almost every byte, so its closings are longer than real ones (an upper bound).
        let offered = OutputSchemas.Offered(segments: Set(1...300), entities: Set(1...30), documents: [1, 2])
        var worst = 0
        for schema in [OutputSchemas.minutes(offered), OutputSchemas.liveNotes(offered), OutputSchemas.answer(offered, documents: true), OutputSchemas.noteBatch(count: 6, offered)] {
            for seed in 0..<12 {
                let c = ToyVocabulary.constraint(schema)
                var rng = SyntheticLanguageModel.SplitMix(UInt64(seed))
                var previous = 0
                if case .tokens(let t) = c.closing() { previous = t.count }
                for _ in 0..<1500 {
                    let tokens: [Int32]
                    switch c.nextMask() {
                    case .free: return
                    case .forced(let t): if t == Int32(ToyVocabulary.controlID) { tokens = [] } else { tokens = [t] }
                    case .forcedSequence(let ts): tokens = ts
                    case .allowed(let bits):
                        var ids: [Int32] = []
                        for w in 0..<bits.count where bits[w] != 0 { for b in 0..<64 where bits[w] & (1 << UInt64(b)) != 0 { ids.append(Int32(w * 64 + b)) } }
                        tokens = [ids[Int(rng.next() % UInt64(ids.count))]]
                    }
                    if tokens.isEmpty { break }
                    for t in tokens { c.accept(t) }
                    if case .tokens(let now) = c.closing() {
                        // A forced sequence is several tokens at once: its growth is counted for the sequence as a whole.
                        worst = max(worst, now.count - previous + tokens.count)
                        previous = now.count
                    }
                }
            }
        }
        #expect(worst <= Gemma4EngineCloseSlack - 8, "the largest growth of the closing in one step was \(worst) tokens")
    }

    // MARK: Empty sets

    @Test func anEmptyOfferedSetFallsBackToAnyNumberAndAnEmptyClosedSetEndsAtOnce() {
        let none = OutputSchemas.Offered(segments: [], entities: [], documents: [])
        for schema in [OutputSchemas.minutes(none), OutputSchemas.noteSingle(none), OutputSchemas.liveNotes(none), OutputSchemas.noteBatch(count: 2, none)] {
            let g = SchemaGrammar(schema)
            // No closed set in these schemas is empty: every trie has a way to end.
            for t in g.tries { #expect(t.shortest(from: 0) != nil) }
        }
        // A schema built by hand with an empty set: the mask is empty and the constraint ends the value (the stop token), it does not wait.
        let broken = OutputSchema.object([.init("a", .array(.integers([]), min: 1, max: 3))])
        let c = ToyVocabulary.constraint(broken)
        for b in Array("{\"a\":[".utf8) { c.accept(Int32(1 + Int(b))) }
        if case .forced(let t) = c.nextMask() { #expect(t == Int32(ToyVocabulary.controlID)) } else { Issue.record("expected the stop token for a dead state") }
        #expect(c.closing() == .unsupported, "no member exists, so there is no valid ending either")
    }
}
