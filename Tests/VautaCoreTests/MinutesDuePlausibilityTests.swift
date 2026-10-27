// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// A due day nobody said (years before the meeting, the day before it, more than a year after it) is dropped by the validator and
/// counted, and the task stays. The evaluation found model output dated 2005 for 2026 meetings.
@Suite("Minutes: plausible due days")
struct MinutesDuePlausibilityTests {
    static let zone = TimeZone(identifier: "UTC")!
    /// The meeting: 2026-10-05, 10:00 UTC.
    static let reference = Date(timeIntervalSince1970: 1_791_194_400)

    static func validate(due: [String]) throws -> ValidatedMinutes {
        let items = due.enumerated().map { i, day in
            #"{"text": "Send numbers \#(i)", "owner": null, "owner_id": null, "due": "\#(day)", "seg": 2, "quote": "send the numbers on Friday"}"#
        }
        let json = #"{"title": "T", "summary": "S", "topics": [], "decisions": [], "entities": [], "open_questions": [], "tasks": [\#(items.joined(separator: ","))]}"#
        return try VautaPrompts.validateMinutes(json, segments: MinutesChecksTests.segments, candidates: [], selfEntity: nil, reference: reference, timeZone: zone)
    }

    @Test func theReferenceIsTheMeetingDay() {
        #expect(DueDay.containing(Self.reference, in: Self.zone) == DueDay(year: 2026, month: 10, day: 5))
    }

    @Test func aDayYearsBeforeTheMeetingIsDroppedAndTheTaskStays() throws {
        let m = try Self.validate(due: ["2005-01-03"])
        #expect(m.tasks.count == 1)
        #expect(m.tasks[0].due == nil && m.tasks[0].dueDay == nil)
        // The day parser already refuses a year that far from the meeting (unreadable); either way it is dropped and counted.
        #expect(m.dueGiven == 1 && m.dueRuleViolations + m.dueUnreadable == 1)
    }

    @Test func theBoundariesAreTheDayBeforeAndAYearAndADayAfter() throws {
        let m = try Self.validate(due: ["2026-10-04", "2026-10-07", "2027-10-06", "2027-10-07"])
        #expect(m.tasks.count == 4, "no task is lost")
        #expect(m.tasks.map { $0.dueDay?.string } == [nil, "2026-10-07", "2027-10-06", nil], "\(m.tasks.map { $0.dueDay?.string ?? "-" })")
        #expect(m.dueRuleViolations == 2)
    }
}
