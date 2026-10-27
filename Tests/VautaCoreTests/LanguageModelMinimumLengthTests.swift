// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// A text with a minimum length: the closing quote is not allowed before it, in the mask and in the early closing.
@Suite("Language model: minimum length of a string")
struct LanguageModelMinimumLengthTests {
    static let schema = OutputSchema.object([.init("t", .text(minBytes: 4, maxBytes: 20))])

    @Test func theStringCannotCloseBeforeItsMinimum() {
        let g = SchemaGrammar(Self.schema)
        let start = LanguageModelClosingTests.inString(g)
        #expect(!start.allowed(g).contains(UInt8(ascii: "\"")), "an empty text is not allowed")
        #expect(!LanguageModelConstraintTests.feed(start, Array("abc\"}".utf8), g).ok)
        #expect(LanguageModelConstraintTests.feed(start, Array("abcd\"}".utf8), g).ok)
        // An escape counts its bytes, and an escaped quote is text, not the end.
        #expect(LanguageModelConstraintTests.feed(start, Array("a\\\"b\\\"\"}".utf8), g).ok)
        #expect(LanguageModelConstraintTests.feed(start, Array("é é\"}".utf8), g).ok)
        let afterThree = LanguageModelConstraintTests.feed(start, Array("abc".utf8), g).state
        #expect(!afterThree.allowed(g).contains(UInt8(ascii: "\"")))
        let afterFour = LanguageModelConstraintTests.feed(start, Array("abcd".utf8), g).state
        #expect(afterFour.allowed(g).contains(UInt8(ascii: "\"")))
    }

    @Test func aWalkNeverWritesAShortTextAndTheEarlyClosingFillsTheMinimum() throws {
        for seed in 0..<100 {
            guard let bytes = ToyVocabulary.walk(Self.schema, seed: UInt64(seed)) else { continue }
            _ = try #require(JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
            // The minimum counts the bytes as written (an escape is two), so the raw text between the quotes is measured.
            let raw = String(decoding: bytes, as: UTF8.self)
            #expect(raw.utf8.count - #"{"t":""}"#.utf8.count >= 4, "\(raw)")
        }
        let g = SchemaGrammar(Self.schema)
        // Cut before the text, and in the middle of it: both end as valid JSON with at least the minimum.
        for prefix in ["{\"t\":", "{\"t\":\"", "{\"t\":\"a", "{\"t\":\"abc"] {
            var s = GrammarState.start(g)
            for b in Array(prefix.utf8) { _ = s.step(b, g) }
            guard case .bytes(let rest) = s.shortestCompletion(g) else { Issue.record("no completion after \(prefix)"); continue }
            let text = prefix + String(decoding: rest, as: UTF8.self)
            _ = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], "\(text)")
            #expect(text.utf8.count - #"{"t":""}"#.utf8.count >= 4, "\(text)")
        }
    }

    @Test func theAnswerSchemaGivesNoEmptyClaimTextOrQuote() throws {
        let g = SchemaGrammar(OutputSchemas.answer(OutputSchemas.Offered(segments: [1, 2]), live: true), whitespace: true)
        var s = GrammarState.start(g)
        for b in Array(#"{"found":true,"answer":"x","claims":[{"text":""#.utf8) { _ = s.step(b, g) }
        #expect(!s.allowed(g).contains(UInt8(ascii: "\"")), "a claim's sentence cannot be empty")
        // A cap that fires right after the citation closes with filler the checks recognise as a cut claim.
        var t = GrammarState.start(g)
        for b in Array(#"{"found":true,"answer":"The budget stays.","claims":[{"text":"Kept","citations":[1],"quote":"#.utf8) { _ = t.step(b, g) }
        guard case .bytes(let rest) = t.shortestCompletion(g) else { Issue.record("no completion"); return }
        let text = #"{"found":true,"answer":"The budget stays.","claims":[{"text":"Kept","citations":[1],"quote":"# + String(decoding: rest, as: UTF8.self)
        let answer = try VautaPrompts.verifyAnswer(text, sent: [1: CitableSegment(id: 1, channel: .others, start: 0, text: "The budget stays as it is")], keepCutAnswer: true)
        #expect(answer.found && answer.cutShort && answer.isUnverified)
    }
}
