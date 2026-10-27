// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Minutes items whose segment number is wrong, or whose quote differs only by fillers, are kept on the segment that holds the words.
@Suite("Minutes: re-anchoring")
struct MinutesReanchorTests {
    static let segments: [Int64: CitableSegment] = [
        1: CitableSegment(id: 1, channel: .others, start: 5, text: "We agreed to keep the budget at 40000 euros this quarter"),
        2: CitableSegment(id: 2, channel: .others, start: 30, text: "uh Ana will um send the numbers on Friday the twelfth"),
        3: CitableSegment(id: 3, channel: .me, start: 60, text: "Let us talk about Kobaltix again next time"),
    ]

    static func validate(_ json: String) throws -> ValidatedMinutes {
        try VautaPrompts.validateMinutes(json, segments: segments, candidates: [], selfEntity: nil,
                                         reference: Date(timeIntervalSince1970: 1_104_537_600), timeZone: TimeZone(identifier: "UTC")!, language: "en")
    }

    @Test func aWrongSegmentIsKeptOnTheRightOne() throws {
        let json = #"{"title":"T","summary":"S","topics":[],"decisions":[{"text":"Keep the budget","seg":3,"quote":"agreed to keep the budget at 40000 euros"}],"tasks":[],"entities":[],"open_questions":[]}"#
        let m = try Self.validate(json)
        #expect(m.decisions.count == 1 && m.decisions[0].segment == 1 && m.decisions[0].t == 5)
        #expect(m.counts["decision.reanchored"] == 1 && m.dropped == 0)
    }

    @Test func fillersInTheSegmentDoNotDropATask() throws {
        let json = #"{"title":"T","summary":"S","topics":[],"decisions":[],"tasks":[{"text":"Send the numbers","owner":null,"owner_id":null,"due":null,"seg":2,"quote":"Ana will send the numbers on Friday"}],"entities":[],"open_questions":[]}"#
        let m = try Self.validate(json)
        #expect(m.tasks.count == 1 && m.tasks[0].segment == 2 && m.counts["task.modulo"] == 1 && m.dropped == 0)
    }

    @Test func figuresAreCheckedAgainstTheAnchoredSegment() throws {
        let json = #"{"title":"T","summary":"S","topics":[],"decisions":[{"text":"Keep the budget at 50000 euros","seg":3,"quote":"agreed to keep the budget at 40000 euros"}],"tasks":[],"entities":[],"open_questions":[]}"#
        let m = try Self.validate(json)
        #expect(m.decisions.count == 1 && m.decisions[0].unconfirmed, "the wrong figure is still marked")
    }

    @Test func aQuoteThatIsNowhereIsStillDropped() throws {
        let json = #"{"title":"T","summary":"S","topics":[],"decisions":[{"text":"Hire two people","seg":1,"quote":"we will hire two more people soon"}],"tasks":[],"entities":[],"open_questions":[]}"#
        let m = try Self.validate(json)
        #expect(m.decisions.isEmpty && m.drops["decision.quoteNotFound"] == 1)
    }
}
