// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Decisions that are not statements, and the meeting's date written into the prose.
@Suite("Minutes: decision filters and the restated date")
struct MinutesDecisionFilterTests {
    static let segments: [Int64: CitableSegment] = [
        1: CitableSegment(id: 1, channel: .others, start: 5, text: "We decided to keep the budget for this quarter"),
        2: CitableSegment(id: 2, channel: .others, start: 30, text: "Should we move the launch to March"),
        3: CitableSegment(id: 3, channel: .others, start: 60, text: "予算を承認します"),
        4: CitableSegment(id: 4, channel: .others, start: 90, text: "So honestly I think we should just ship the thing on Friday and then see who complains about it afterwards"),
    ]
    static let reference = Date(timeIntervalSince1970: 1_104_537_600)   // 2005-01-01

    static func run(_ decisions: String, title: String = "T", summary: String = "S", language: String? = "en") throws -> ValidatedMinutes {
        let json = #"{"title":"\#(title)","summary":"\#(summary)","topics":[],"decisions":[\#(decisions)],"tasks":[],"entities":[],"open_questions":[]}"#
        return try VautaPrompts.validateMinutes(json, segments: segments, candidates: [], selfEntity: nil, reference: reference,
                                                timeZone: TimeZone(identifier: "UTC")!, language: language)
    }

    @Test func eachReasonHasItsCount() throws {
        let m = try Self.run("""
            {"text": "Yes", "seg": 1, "quote": "keep the budget for this quarter"},
            {"text": "Should the launch move to March?", "seg": 2, "quote": "Should we move the launch to March"},
            {"text": "We decided to keep the budget for this quarter", "seg": 1, "quote": "decided to keep the budget for this quarter"},
            {"text": "Budget stays as it is for this quarter", "seg": 1, "quote": "keep the budget for this quarter"}
            """)
        #expect(m.decisions.map(\.text) == ["Budget stays as it is for this quarter"], "\(m.decisions.map(\.text))")
        #expect(m.drops["decision.tooShort"] == 1 && m.drops["decision.question"] == 1 && m.drops["decision.rawQuote"] == 1, Comment(rawValue: "\(m.drops)"))
    }

    @Test func aTheLineCopiedAsTheDecisionIsRawEvenWithADifferentCase() throws {
        let m = try Self.run(#"{"text": "WE DECIDED TO KEEP THE BUDGET FOR THIS QUARTER!", "seg": 1, "quote": "keep the budget for this quarter"}"#)
        #expect(m.decisions.isEmpty && m.drops["decision.rawQuote"] == 1)
    }

    @Test func aVerbatimFragmentOfALongLineIsRawButAShortStatementIsNot() throws {
        let fragment = try Self.run(#"{"text": "we should just ship the thing on Friday", "seg": 4, "quote": "ship the thing on Friday"}"#)
        #expect(fragment.decisions.isEmpty && fragment.drops["decision.rawQuote"] == 1, Comment(rawValue: "\(fragment.drops)"))
        let paraphrase = try Self.run(#"{"text": "Release on Friday, complaints reviewed afterwards", "seg": 4, "quote": "ship the thing on Friday"}"#)
        #expect(paraphrase.decisions.count == 1, Comment(rawValue: "\(paraphrase.drops)"))
        let short = try Self.run(#"{"text": "ship the thing", "seg": 4, "quote": "ship the thing on Friday"}"#)
        #expect(short.decisions.count == 1, "three words are never judged a raw fragment")
    }

    @Test func shortCJKDecisionsAreKept() throws {
        let m = try Self.run(#"{"text": "予算を承認する", "seg": 3, "quote": "予算を承認します"}"#, language: "ja")
        #expect(m.decisions.count == 1, "\(m.drops)")
    }

    @Test func theMeetingDateIsDroppedFromTitleAndSummaryUnlessTheTranscriptSaysIt() throws {
        let m = try Self.run("", title: "Review of 2005-01-01", summary: "On 2005-01-01, the team kept the budget. It also met on January 1, 2005 again.")
        #expect(m.summary == "The team kept the budget. It also met on January 1, 2005 again." || m.summary.hasPrefix("The team kept the budget."), Comment(rawValue: m.summary))
        let es = try Self.run("", summary: "El 1 de enero de 2005, el equipo mantuvo el presupuesto.", language: "es")
        #expect(es.summary == "El equipo mantuvo el presupuesto.", Comment(rawValue: es.summary))
        // The transcript says that day and month: the date stays.
        let said: [Int64: CitableSegment] = [1: CitableSegment(id: 1, channel: .others, start: 5, text: "Today is January 1 so we start")]
        let json = #"{"title":"T","summary":"On 2005-01-01, the team met.","topics":[],"decisions":[],"tasks":[],"entities":[],"open_questions":[]}"#
        let kept = try VautaPrompts.validateMinutes(json, segments: said, candidates: [], selfEntity: nil, reference: Self.reference, timeZone: TimeZone(identifier: "UTC")!, language: "en")
        #expect(kept.summary == "On 2005-01-01, the team met.")
    }
}
