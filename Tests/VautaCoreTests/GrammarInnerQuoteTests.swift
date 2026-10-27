// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// A string never closes right after a space: the raw quote of an inner quotation must not end the value (the cut summary of 11a.1).
@Suite("Language model: no closing quote after a space")
struct GrammarInnerQuoteTests {
    static let schema = OutputSchema.object([.init("a", .string(maxBytes: 40)), .init("b", .string(maxBytes: 40))])

    static func feed(_ text: String, whitespace: Bool = true) -> (ok: Bool, state: GrammarState, g: SchemaGrammar) {
        let g = SchemaGrammar(schema, whitespace: whitespace)
        let r = LanguageModelConstraintTests.feed(GrammarState.start(g), Array(text.utf8), g)
        return (r.ok, r.state, g)
    }

    @Test func theClosingQuoteIsRefusedAfterASpaceAndAllowedAfterALetter() {
        #expect(Self.feed(#"{"a":"como "#).ok)
        #expect(!Self.feed(#"{"a":"como ""#).ok, "a raw quote after a space does not close the string")
        #expect(Self.feed(#"{"a":"como""#).ok)
        #expect(Self.feed(#"{"a":"como \"x\"","b":"y"}"#).ok, "an escaped inner quote is fine")
        #expect(Self.feed(#"{"a":"como «x» ","#, whitespace: true).ok == false, "still no close after the space of a guillemet")
        #expect(Self.feed(#"{"a":"como «x»","b":"y"}"#).ok)
    }

    @Test func anEscapedOpeningQuoteNeedsAnEscapedClosingOne() {
        // The model escapes the opening quote of an inner quotation and ends it with a raw one: the raw quote must not end the value.
        #expect(Self.feed(#"{"a":"el \"presupuesto"#).ok)
        #expect(!Self.feed(#"{"a":"el \"presupuesto""#).ok, "a raw quote does not close while an escaped one is open")
        #expect(Self.feed(#"{"a":"el \"presupuesto\"","b":"y"}"#).ok, "closed with its own escape, then the string closes")
        #expect(Self.feed(#"{"a":"el \"x\" y \"z\"","b":"y"}"#).ok, "two quotations")
        // The value that ends when the budget runs out still closes (room is the only thing that lifts the rule).
        let g = SchemaGrammar(.object([.init("a", .string(maxBytes: 6))]), whitespace: true)
        let tight = LanguageModelConstraintTests.feed(GrammarState.start(g), Array(#"{"a":"\"abcd"#.utf8), g)
        #expect(tight.ok && tight.state.allowed(g).contains(UInt8(ascii: "\"")), "no room left: the string must be able to close")
    }

    @Test func theShortestCompletionClosesAnOpenInnerQuoteFirst() throws {
        let r = Self.feed(#"{"a":"el \"presupuesto"#)
        guard case .bytes(let rest) = r.state.shortestCompletion(r.g) else { Issue.record("no completion"); return }
        let text = #"{"a":"el \"presupuesto"# + String(decoding: rest, as: UTF8.self)
        try LanguageModelConstraintTests.expectStrictJSON(Array(text.utf8))
        let again = LanguageModelConstraintTests.feed(r.state, rest, r.g)
        #expect(again.ok && again.state.isFinished)
    }

    @Test func aSpaceBeforeAnEscapeOrAfterOneIsHandled() {
        // The flag follows the last byte written, not the last space.
        #expect(Self.feed(#"{"a":"x \n"#).ok)
        #expect(Self.feed(#"{"a":"x \n""#).ok, "an escape between the space and the quote")
        #expect(Self.feed(#"{"a":"x é""#).ok)
    }

    @Test func aStringWithNoRoomLeftStillCloses() {
        let g = SchemaGrammar(.object([.init("a", .string(maxBytes: 3))]), whitespace: true)
        let r = LanguageModelConstraintTests.feed(GrammarState.start(g), Array(#"{"a":"ab "#.utf8), g)
        #expect(r.ok)
        #expect(r.state.allowed(g).contains(UInt8(ascii: "\"")), "the budget is spent: the string must be able to close")
    }

    @Test func theShortestCompletionAfterATrailingSpaceIsValidJSON() throws {
        let r = Self.feed(#"{"a":"como "#)
        guard case .bytes(let rest) = r.state.shortestCompletion(r.g) else { Issue.record("no completion"); return }
        let text = #"{"a":"como "# + String(decoding: rest, as: UTF8.self)
        try LanguageModelConstraintTests.expectStrictJSON(Array(text.utf8))
        // The ending is also accepted by the grammar byte for byte.
        let again = LanguageModelConstraintTests.feed(r.state, rest, r.g)
        #expect(again.ok && again.state.isFinished)
        #expect(rest.count <= 40, "bounded")
    }

    @Test func theForcedEndingOfAStringStillBelowItsMinimumKeepsTheGrammarIntact() throws {
        // An escaped quote is open and the minimum length is not reached: the dots, then its own escape, then the quote.
        let g = SchemaGrammar(.object([.init("a", .text(minBytes: 12, maxBytes: 40))]), whitespace: true)
        let start = Array(#"{"a":"el \"pre"#.utf8)
        let r = LanguageModelConstraintTests.feed(GrammarState.start(g), start, g)
        #expect(r.ok)
        guard case .bytes(let rest) = r.state.shortestCompletion(g) else { Issue.record("no completion"); return }
        try LanguageModelConstraintTests.expectStrictJSON(start + rest)
        let again = LanguageModelConstraintTests.feed(r.state, rest, g)
        #expect(again.ok && again.state.isFinished, "the forced bytes are accepted by the grammar itself")
    }

    @Test func aLoneEscapedQuoteDoesNotForceTheStringToItsMaximum() {
        let g = SchemaGrammar(.object([.init("a", .string(maxBytes: 3000))]), whitespace: true)
        let quote = UInt8(ascii: "\"")
        var r = LanguageModelConstraintTests.feed(GrammarState.start(g), Array(#"{"a":"a 5\" screen"#.utf8), g)
        #expect(r.ok && !r.state.allowed(g).contains(quote), "right after an unclosed escaped quote the raw quote is held back")
        r = LanguageModelConstraintTests.feed(r.state, Array(String(repeating: "x", count: 200).utf8), g)
        #expect(r.ok && r.state.allowed(g).contains(quote), "after enough text the raw quote may close the string")
    }
}
