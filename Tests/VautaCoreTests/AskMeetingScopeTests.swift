// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Where a question across the library looks: the meetings of the place it names, else those of its time, else all of them, resolved
/// once for Ask, the answers to questions heard and the evaluation.
@Suite("Ask: where a question across the library looks")
struct AskMeetingScopeTests {
    static let day: TimeInterval = 86_400

    static func period(_ from: Date, _ to: Date) -> AskTimeScope {
        AskTimeScope(interval: DateInterval(start: from, end: to), span: .range, applies: true)
    }

    @Test func thePlaceFirstThenTheTimeThenEverything() async throws {
        let f = try KnowledgeFixture()
        _ = try await f.store.saveEntity(EntityDraft(kind: .project, name: "Kobaltix"))
        let now = Date.now, day = Self.day
        let old = try await f.meeting(["The kickoff with Kobaltix went well"], at: now - 30 * day)
        let second = try await f.meeting(["The budget for the quarter"], at: now - 5 * day)
        let latest = try await f.meeting(["Kobaltix asked for the pricing again"], at: now - 2 * day)
        let live = try await f.store.startMeeting(at: now)
        let last = AskMeetingPlace(which: .last(1), ofNamed: false), q = "What did we decide?"

        #expect(try await f.store.askScope(q, period: nil, place: last) == AskMeetingScope(within: latest, placed: true), "one meeting is read whole")
        #expect(try await f.store.askScope(q, period: nil, place: AskMeetingPlace(which: .last(2), ofNamed: false))
                == AskMeetingScope(meetings: [latest, second], placed: true))
        #expect(try await f.store.askScope(q, period: Self.period(now - 40 * day, now - 10 * day), place: last) == AskMeetingScope(within: old, placed: true),
                "the last meeting of that time")
        #expect(try await f.store.askScope("What did we decide in the first meeting about Kobaltix?", period: nil, place: AskMeetingPlace(which: .first(1), ofNamed: true))
                == AskMeetingScope(within: old, placed: true))

        let week = Self.period(now - 7 * day, now + day)
        #expect(try await f.store.askScope("What did we decide in the first meeting about it?", period: week, place: AskMeetingPlace(which: .first(1), ofNamed: true))
                == AskMeetingScope(meetings: [live, latest, second]), "a place that needs a project the question doesn't name leaves it to the time")
        #expect(try await f.store.askScope(q, period: week, place: nil, excluding: live) == AskMeetingScope(meetings: [latest, second]),
                "never the meeting being recorded, for a question heard in it")
        #expect(try await f.store.askScope(q, period: Self.period(now - day, now + day), place: nil, excluding: live) == AskMeetingScope(noMeetingsInPeriod: true))
        #expect(try await f.store.askScope(q, period: Self.period(now - 20 * day, now - 10 * day), place: nil) == AskMeetingScope(noMeetingsInPeriod: true),
                "a time without meetings: all of them, and the answer says so")
        #expect(try await f.store.askScope(q, period: nil, place: nil) == .everywhere)
    }

    @Test func aQuestionNobodyCanTurnOnOrOffUsesOnlyATimeThatApplies() async throws {
        let f = try KnowledgeFixture()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        calendar.firstWeekday = 2
        // Thursday, October 29, 2026, noon: last week is October 19 to 25.
        let now = Date(timeIntervalSince1970: 1_793_275_200), day = Self.day
        _ = try await f.meeting(["The roadmap for next year"], at: now - 40 * day)
        let lastWeek = try await f.meeting(["We agreed on the pricing"], at: now - 8 * day)
        let latest = try await f.meeting(["The plants in the office"], at: now - 2 * day)

        #expect(try await f.store.askScope(of: "What did we decide last week?", languages: ["en"], now: now, calendar: calendar) == AskMeetingScope(meetings: [lastWeek]))
        #expect(try await f.store.askScope(of: "What were last week's numbers?", languages: ["en"], now: now, calendar: calendar) == .everywhere,
                "a time Ask only offers is not used where nobody can turn it on")
        #expect(try await f.store.askScope(of: "¿Qué decidimos exactamente en la última reunión?", languages: ["en"], now: now, calendar: calendar)
                == AskMeetingScope(within: latest, placed: true), "read in the question's own language when it can be told")
        #expect(try await f.store.askScope(of: "What did we decide about the pricing?", languages: ["en"], now: now, calendar: calendar) == .everywhere)
    }

    @Test func theTraceSaysWhatDecidedIt() {
        #expect(AskMeetingScope(within: 4, placed: true).trace == "place:1")
        #expect(AskMeetingScope(meetings: [1, 2, 3]).trace == "time:3")
        #expect(AskMeetingScope(noMeetingsInPeriod: true).trace == "none" && !AskMeetingScope(noMeetingsInPeriod: true).narrows)
        #expect(AskMeetingScope.everywhere.trace == "")
    }
}
