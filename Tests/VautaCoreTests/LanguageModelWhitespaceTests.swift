// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Bounded JSON whitespace between tokens, and the tagged answer object (`found` decides what the rest must be).
@Suite("Language model: JSON whitespace and the found-or-not answer")
struct LanguageModelWhitespaceTests {
    static let offered = OutputSchemas.Offered(segments: [3, 4, 5, 120], entities: [7, 8], documents: [1, 2])

    static func feed(_ schema: OutputSchema, _ text: String, whitespace: Bool) -> (ok: Bool, finished: Bool) {
        let g = SchemaGrammar(schema, whitespace: whitespace)
        let r = LanguageModelConstraintTests.feed(GrammarState.start(g), Array(text.utf8), g)
        return (r.ok, r.state.isFinished)
    }

    // MARK: Whitespace

    @Test func prettyPrintedMinutesAreAcceptedOnlyWithWhitespace() {
        let schema = OutputSchemas.minutes(Self.offered)
        // The way the prompt shows the JSON, and the way models write it: spaces after colons, newlines and indentation between items.
        let pretty = """
            {"title": "T",
             "summary": "S",
             "topics": ["a",
              "b"],
             "decisions": [ ],
             "tasks": [{"text": "x", "owner": null, "owner_id": null, "due": null, "seg": 3, "quote": "q"}],
             "entities": [],
             "open_questions": []
            }
            """
        let withSpace = Self.feed(schema, pretty, whitespace: true)
        #expect(withSpace.ok && withSpace.finished)
        #expect(!Self.feed(schema, pretty, whitespace: false).ok, "the compact grammar refuses the first space")
    }

    @Test func emptyArraysAndTheClosingBracketsAreWritableInEveryLayout() {
        let schema = OutputSchemas.minutes(Self.offered)
        let head = #"{"title":"T","summary":"S","topics":[],"decisions":[],"tasks":[],"entities":[],"open_questions":"#
        for tail in ["[]}", "[]\n}", "[ ]\n}", "[\n]\n}", "[\n  ]\n\n}", "[\"a\"]\n}", "[\"a\",\n \"b\"\n ]\n}"] {
            let r = Self.feed(schema, head + tail, whitespace: true)
            #expect(r.ok && r.finished, "\(tail.debugDescription) must be generable")
        }
    }

    @Test func whitespaceIsBoundedAndNeverTrailsTheObject() {
        let schema = OutputSchema.object([.init("a", .anyInteger(maxDigits: 3))])
        let g = SchemaGrammar(schema, whitespace: true)
        let start = LanguageModelConstraintTests.feed(GrammarState.start(g), Array("{".utf8), g)
        let twelve = LanguageModelConstraintTests.feed(start.state, Array(String(repeating: " ", count: 12).utf8), g)
        #expect(twelve.ok)
        #expect(!LanguageModelConstraintTests.feed(twelve.state, Array(" ".utf8), g).ok, "the 13th byte of a run is refused: only the key may follow")
        #expect(LanguageModelConstraintTests.feed(twelve.state, Array("\"a\": 1 }".utf8), g).ok)
        // After the closing brace nothing may come (the stop token is forced), also no trailing newline.
        let done = LanguageModelConstraintTests.feed(GrammarState.start(g), Array("{\"a\":1}".utf8), g)
        #expect(done.ok && done.state.isFinished && !LanguageModelConstraintTests.feed(done.state, Array("\n".utf8), g).ok)
    }

    @Test func aGrammarWithoutWhitespaceIsUnchangedAndForcesItsKeys() {
        let g = SchemaGrammar(OutputSchemas.liveNotes(.init(segments: [4])), whitespace: false)
        #expect(String(decoding: GrammarState.start(g).forcedBytes(g), as: UTF8.self) == #"{"points":["#, "keys, colons and the first bracket are written without asking the model")
        let w = SchemaGrammar(OutputSchemas.liveNotes(.init(segments: [4])), whitespace: true)
        #expect(String(decoding: GrammarState.start(w).forcedBytes(w), as: UTF8.self) == "{", "with whitespace only the first brace is forced")
    }

    @Test func walksWithWhitespaceStillParseAndEndAtTheClosingBrace() throws {
        var ended = 0
        for seed in 0..<30 {
            for schema in [OutputSchemas.minutes(Self.offered), OutputSchemas.liveNotes(Self.offered), OutputSchemas.answer(Self.offered), OutputSchemas.noteBatch(count: 2, Self.offered)] {
                guard let bytes = ToyVocabulary.walk(schema, seed: UInt64(seed), whitespace: true) else { continue }
                try LanguageModelConstraintTests.expectStrictJSON(bytes)
                #expect(bytes.last == UInt8(ascii: "}"))
                ended += 1
            }
        }
        #expect(ended > 80)
    }

    @Test func closingEarlyWithWhitespaceStillGivesValidJSON() throws {
        let schemas: [OutputSchema] = [OutputSchemas.minutes(Self.offered), OutputSchemas.answer(Self.offered), OutputSchemas.answer(Self.offered, documents: true, live: true)]
        for schema in schemas {
            for seed in 0..<10 {
                for steps in [0, 3, 12, 40, 120] {
                    let c = ToyVocabulary.constraint(schema, whitespace: true)
                    var rng = SyntheticLanguageModel.SplitMix(UInt64(seed))
                    var out: [UInt8] = []
                    var n = 0
                    walking: while n < steps {
                        let tokens: [Int32]
                        switch c.nextMask() {
                        case .free: break walking
                        case .forced(let t): if t == Int32(ToyVocabulary.controlID) { break walking }; tokens = [t]
                        case .forcedSequence(let ts): tokens = ts
                        case .allowed(let bits):
                            var ids: [Int32] = []
                            for w in 0..<bits.count where bits[w] != 0 { for b in 0..<64 where bits[w] & (1 << UInt64(b)) != 0 { ids.append(Int32(w * 64 + b)) } }
                            tokens = [ids[Int(rng.next() % UInt64(ids.count))]]
                        }
                        for t in tokens { c.accept(t); out += ToyVocabulary.bytes[Int(t)] }
                        n += tokens.count
                    }
                    guard case .tokens(let closing) = c.closing() else { continue }   // in the middle of a character: the engine waits
                    for t in closing { out += ToyVocabulary.bytes[Int(t)] }
                    #expect(try JSONSerialization.jsonObject(with: Data(out)) is [String: Any], "steps \(steps): \(String(decoding: out, as: UTF8.self).suffix(80))")
                }
            }
        }
    }

    // MARK: found

    /// The answer object as parsed JSON, from walks over the schema.
    static func answers(live: Bool = false, documents: Bool = false, whitespace: Bool, seeds: Range<Int> = 0..<60) throws -> [[String: Any]] {
        try seeds.compactMap { seed in
            guard let bytes = ToyVocabulary.walk(OutputSchemas.answer(Self.offered, documents: documents, live: live), seed: UInt64(seed), whitespace: whitespace) else { return nil }
            return try #require(JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
        }
    }

    @Test(arguments: [false, true]) func foundComesFirstAndDecidesWhetherClaimsExist(whitespace: Bool) throws {
        let found = try Self.answers(whitespace: whitespace)
        #expect(found.count > 40)
        var trues = 0, falses = 0
        for a in found {
            let claims = try #require(a["claims"] as? [[String: Any]])
            if a["found"] as? Bool == true {
                trues += 1
                #expect(!claims.isEmpty, "found=true needs at least one claim")
                for c in claims { #expect(!(c["citations"] as? [Any] ?? []).isEmpty, "every claim cites a segment") }
            } else {
                falses += 1
                #expect(a["found"] as? Bool == false && claims.isEmpty, "found=false is a refusal with no claims")
            }
        }
        #expect(trues > 3 && falses > 3, "both branches are reachable (\(trues) found, \(falses) not)")
    }

    @Test func theFirstKeyIsFoundAndTheGrammarWritesItWithoutAsking() {
        let g = SchemaGrammar(OutputSchemas.answer(Self.offered), whitespace: false)
        let forced = String(decoding: GrammarState.start(g).forcedBytes(g), as: UTF8.self)
        #expect(forced == "{\"found\":", "the first key is found; the model chooses true or false next")
        // After `true,"answer":"x"` the claims array cannot be empty; after `false` it can only be empty.
        let yes = LanguageModelConstraintTests.feed(GrammarState.start(g), Array("{\"found\":true,\"answer\":\"x\",\"claims\":[".utf8), g)
        #expect(yes.ok && !yes.state.allowed(g).contains(UInt8(ascii: "]")) && yes.state.allowed(g).contains(UInt8(ascii: "{")))
        let no = LanguageModelConstraintTests.feed(GrammarState.start(g), Array("{\"found\":false,\"answer\":\"x\",\"claims\":[".utf8), g)
        #expect(no.ok && no.state.allowed(g).contains(UInt8(ascii: "]")) && !no.state.allowed(g).contains(UInt8(ascii: "{")) && !no.state.allowed(g).contains(UInt8(ascii: "\"")))
        #expect(!LanguageModelConstraintTests.feed(GrammarState.start(g), Array("{\"found\":true,\"answer\":\"x\",\"claims\":[]".utf8), g).ok)
        #expect(!LanguageModelConstraintTests.feed(GrammarState.start(g), Array("{\"found\":false,\"answer\":\"x\",\"claims\":[{".utf8), g).ok)
        // A claim must cite at least one segment.
        #expect(!LanguageModelConstraintTests.feed(GrammarState.start(g), Array("{\"found\":true,\"answer\":\"x\",\"claims\":[{\"text\":\"t\",\"citations\":[]".utf8), g).ok)
    }

    @Test func aCutOffAnswerIsClosedAsAValidOneOfEitherBranch() throws {
        let g = SchemaGrammar(OutputSchemas.answer(Self.offered), whitespace: true)
        for prefix in ["{", "{\"found\":", "{\"found\":t", "{\"found\":true,", "{\"found\":true,\"answer\":\"par", "{\"found\":true,\"answer\":\"x\",\"claims\":[{\"text\":\"t",
                       "{\"found\": false, \"answer\": \"no", "{\"found\":false,\"answer\":\"x\",\"claims\":["] {
            var s = GrammarState.start(g)
            for b in Array(prefix.utf8) {
                let accepted = s.step(b, g)
                #expect(accepted, "\(prefix) is a valid start")
            }
            guard case .bytes(let rest) = s.shortestCompletion(g) else { Issue.record("no completion after \(prefix)"); continue }
            let text = prefix + String(decoding: rest, as: UTF8.self)
            let parsed = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], "\(text)")
            let claims = parsed["claims"] as? [[String: Any]] ?? []
            #expect(parsed["found"] as? Bool == true ? !claims.isEmpty : claims.isEmpty, "\(text)")
        }
    }

    @Test func theLiveAnswerSchemaHasTighterBounds() throws {
        for a in try Self.answers(live: true, whitespace: true, seeds: 0..<40) {
            let claims = try #require(a["claims"] as? [[String: Any]])
            #expect(claims.count <= 3 && (a["answer"] as? String ?? "").utf8.count <= 700)
        }
    }

    @Test func theServerSchemaIsAFlatObjectWithFoundFirstAndNothingThatWasSent() throws {
        for documents in [false, true] {
            let data = OutputSchemas.answerForServer(documents: documents).jsonSchemaData()
            let text = String(decoding: data, as: UTF8.self)
            let schema = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            // No root-level anyOf (not every server's structured-output backend takes one): a plain object.
            #expect(schema["anyOf"] == nil && schema["type"] as? String == "object")
            let properties = try #require(schema["properties"] as? [String: Any])
            #expect((properties["found"] as? [String: Any])?["type"] as? String == "boolean")
            #expect((properties["claims"] as? [String: Any])?["minItems"] as? Int == 0)
            // `found` is written first, then `answer`, then `claims`.
            #expect(text.range(of: "\"found\"")!.lowerBound < text.range(of: "\"answer\"")!.lowerBound
                    && text.range(of: "\"answer\"")!.lowerBound < text.range(of: "\"claims\"")!.lowerBound)
            #expect(!text.contains("\"enum\":[3") && !text.contains("S120"), "nothing that was sent is listed")
            #expect(text.contains(documents ? "\"type\":\"string\"" : "\"type\":\"integer\""))
        }
    }
}
