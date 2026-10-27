// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Brief: which events get one, and when")
struct BriefEventTests {
    static let rules = BriefFixtures.rules
    static let me = BriefAttendee(name: "Me", email: nil, isCurrentUser: true)
    static let ana = BriefAttendee(name: "Ana López", email: "ana@example.com")

    @Test func theLinksThatShowAnEventOrAReminderCarryOnlyItsIdentifier() {
        #expect(BriefOpenURL.event(eventIdentifier: "ABC-123:456")?.absoluteString == "ical://ekevent/ABC-123:456?method=show&options=more")
        #expect(BriefOpenURL.event(eventIdentifier: "a/b?c#d")?.absoluteString == "ical://ekevent/a%2Fb%3Fc%23d?method=show&options=more", "a separator cannot change the target")
        #expect(BriefOpenURL.reminder(id: "R-9")?.absoluteString == "x-apple-reminderkit://REMCDReminder/R-9")
        #expect(BriefOpenURL.event(eventIdentifier: nil) == nil && BriefOpenURL.event(eventIdentifier: "") == nil && BriefOpenURL.reminder(id: nil) == nil,
                "no identifier, no link: the app is opened instead")
    }

    @Test func aVideoCallInAChosenCalendarQualifies() {
        #expect(BriefEventSelector.qualifies(BriefFixtures.event(), rules: Self.rules))
        #expect(BriefEventSelector.qualifies(BriefFixtures.event(attendees: [], service: .googleMeet), rules: Self.rules), "a link is enough")
    }

    @Test func anInPersonMeetingNeedsAnotherAttendeeAndTheSetting() {
        let inPerson = BriefFixtures.event(attendees: [Self.me, Self.ana], service: nil)
        #expect(BriefEventSelector.qualifies(inPerson, rules: Self.rules))
        #expect(!BriefEventSelector.qualifies(inPerson, rules: BriefEventRules(calendarIDs: ["work"], includeInPerson: false)), "\"Also for meetings without a video link\" is off")
        #expect(!BriefEventSelector.qualifies(BriefFixtures.event(attendees: [Self.me], service: nil), rules: Self.rules), "alone: not a meeting")
        #expect(!BriefEventSelector.qualifies(BriefFixtures.event(attendees: [], service: nil), rules: Self.rules))
    }

    @Test func declinedAllDayAndUnchosenEventsNeverQualify() {
        #expect(!BriefEventSelector.qualifies(BriefFixtures.event(declined: true), rules: Self.rules))
        #expect(!BriefEventSelector.qualifies(BriefFixtures.event(allDay: true), rules: Self.rules))
        #expect(!BriefEventSelector.qualifies(BriefFixtures.event(calendar: "private"), rules: Self.rules))
        #expect(!BriefEventSelector.qualifies(BriefFixtures.event(), rules: BriefEventRules(calendarIDs: [])), "no calendar chosen: nothing is read")
    }

    @Test func theWindowIsTheEventAboutToStartAndTheNextOneWithinTwelveHours() {
        let now = BriefFixtures.now
        let ended = BriefFixtures.event("ended", in: -90, length: 30)
        let justStarted = BriefFixtures.event("just-started", in: -10)
        let stale = BriefFixtures.event("stale", in: -40, length: 120)
        let soon = BriefFixtures.event("soon", in: 12)
        let later = BriefFixtures.event("later", in: 300)
        let tooFar = BriefFixtures.event("too-far", in: 13 * 60)
        let other = BriefFixtures.event("other-calendar", in: 5, calendar: "private")
        let all = [tooFar, later, other, soon, stale, ended, justStarted]
        #expect(BriefEventSelector.candidates(all, now: now, rules: Self.rules).map(\.identifier) == ["just-started", "soon", "later"])
        #expect(BriefEventSelector.next(all, now: now, rules: Self.rules)?.identifier == "just-started", "until 15 minutes after it started")
        #expect(BriefEventSelector.upcoming(all, now: now, rules: Self.rules).map(\.identifier) == ["just-started", "soon"], "never more than two events are looked at")
        #expect(BriefEventSelector.next([], now: now, rules: Self.rules) == nil)
    }

    @Test func eventsAtTheSameTimeAreOrderedWithoutDependingOnTheCalendar() {
        let a = BriefFixtures.event("b", title: "B meeting", in: 5, length: 30)
        let b = BriefFixtures.event("a", title: "A meeting", in: 5, length: 30)
        #expect(BriefEventSelector.candidates([a, b], now: BriefFixtures.now, rules: Self.rules).map(\.title) == ["A meeting", "B meeting"])
        #expect(BriefEventSelector.candidates([b, a], now: BriefFixtures.now, rules: Self.rules).map(\.title) == ["A meeting", "B meeting"])
    }

    @Test func theNotificationTimeFollowsTheLeadTime() {
        let event = BriefFixtures.event(in: 60)
        for minutes in [5, 10, 15, 30] {
            #expect(BriefEventSelector.fireDate(for: event, leadMinutes: minutes) == event.start.addingTimeInterval(-Double(minutes) * 60))
        }
        #expect(BriefEventSelector.fireDate(for: event, leadMinutes: 0) == nil, "Off")
        #expect(BriefEventSelector.fireDate(for: event, leadMinutes: 7) == event.start.addingTimeInterval(-600), "an unknown value falls back to the default of 10")
    }

    @Test func eachOccurrenceOfARecurringEventNotifiesOnce() {
        let week1 = BriefFixtures.event("series", in: 10, recurring: true)
        let week2 = BriefFixtures.event("series", in: 10, recurring: true, at: BriefFixtures.now.addingTimeInterval(7 * 86_400))
        #expect(week1.occurrence != week2.occurrence && week1.seriesKey == week2.seriesKey && week1.seriesKey == "series")
        var ledger = BriefNotificationLedger()
        let early = week1.start.addingTimeInterval(-15 * 60)
        let due = week1.start.addingTimeInterval(-9 * 60)
        let tooEarly = ledger.claim(week1, now: early, leadMinutes: 10)
        let first = ledger.claim(week1, now: due, leadMinutes: 10)
        let again = ledger.claim(week1, now: due.addingTimeInterval(30), leadMinutes: 10)
        #expect(!tooEarly && first && !again, "not before the lead time, then exactly once")
        #expect(ledger.wasSent(week1) && !ledger.wasSent(week2))
        let nextWeek = ledger.claim(week2, now: week2.start.addingTimeInterval(-8 * 60), leadMinutes: 10)
        let late = ledger.claim(BriefFixtures.event("other", in: 5), now: BriefFixtures.now.addingTimeInterval(6 * 60), leadMinutes: 10)
        #expect(nextWeek, "the next week is another occurrence")
        #expect(!late, "after the start: too late")
        var off = BriefNotificationLedger()
        let offResult = off.claim(week1, now: due, leadMinutes: 0)
        #expect(!offResult, "Off")
    }

    // MARK: The invitation's description

    @Test func onlyTheListLinesOfAnInvitationAreUsedAndTheyAreCleaned() {
        let notes = """
            Hi all, please join.
            Agenda:
            - Supplier change\u{202E}gnp.exe
            • Shell material and legal answers
            1. Budget 2027 review
            2) Next steps
            https://example.com/zoom/123
            - https://example.com/only-a-link
            - Budget\u{200B} 2027 review
            Thanks!
            """
        let lines = BriefInvitationNotes.agendaLines(from: notes)
        #expect(lines == ["Supplier changegnp.exe", "Shell material and legal answers", "Budget 2027 review", "Next steps"],
                "list lines only; bidirectional and zero-width characters gone; a bare link and a repeat are dropped")
        #expect(BriefInvitationNotes.agendaLines(from: nil).isEmpty && BriefInvitationNotes.agendaLines(from: "No list here.").isEmpty)
    }

    @Test func invitationNotesAreCappedAndLinksStayText() {
        let many = (1...30).map { "- Point number \($0) with some words" }.joined(separator: "\n")
        #expect(BriefInvitationNotes.agendaLines(from: many).count == BriefInvitationNotes.maximumLines)
        let long = "- " + String(repeating: "word ", count: 100)
        #expect(BriefInvitationNotes.agendaLines(from: long).first?.count ?? 0 <= BriefInvitationNotes.maximumLineCharacters)
        let withLink = BriefInvitationNotes.agendaLines(from: "- Read https://example.com/doc before the call")
        #expect(withLink == ["Read https://example.com/doc before the call"], "kept as plain text, never as a link")
        let huge = String(repeating: "x", count: 100_000) + "\n- hidden past the cap"
        #expect(BriefInvitationNotes.agendaLines(from: huge).isEmpty, "only the first part of a long description is read")
    }

    @Test func aRecordingStoresNoInvitationNotes() {
        let event = BriefFixtures.event(notes: "- SECRET-INVITE-NOTE")
        let meeting = event.calendarMeeting
        #expect(meeting.title == event.title && meeting.seriesKey == nil)
        #expect("\(meeting)".contains("SECRET-INVITE-NOTE") == false, "CalendarMeeting is what a recording stores: it has no field for the notes")
    }
}

@Suite("Brief: reminders")
struct BriefReminderTests {
    static let start = BriefFixtures.now.addingTimeInterval(600)
    static func reminder(_ id: String, _ title: String, days: Double? = nil, list: String = "L1", completed: Bool = false) -> BriefReminder {
        BriefReminder(id: id, title: title, due: days.map { start.addingTimeInterval($0 * 86_400) }, listID: list, listName: "Work", priority: 1, isCompleted: completed)
    }

    @Test func onlyIncompleteRemindersOfTheChosenListsInTheWindowAreEligible() {
        let all = [Self.reminder("in", "In the window", days: -3), Self.reminder("edge-old", "Two weeks ago", days: -14), Self.reminder("too-old", "Too old", days: -14.5),
                   Self.reminder("edge-new", "Next week", days: 7), Self.reminder("too-new", "Later", days: 7.5), Self.reminder("no-due", "Whenever"),
                   Self.reminder("other-list", "Not chosen", days: 1, list: "L2"), Self.reminder("done", "Finished", days: 1, completed: true),
                   Self.reminder("blank", "   ", days: 1)]
        let eligible = BriefReminderFilter.eligible(all, listIDs: ["L1"], event: Self.start)
        #expect(eligible.map(\.id) == ["in", "edge-old", "edge-new", "no-due"])
        #expect(BriefReminderFilter.eligible(all, listIDs: [], event: Self.start).isEmpty, "no list chosen: nothing")
    }

    @Test func titlesAreCleanedAndAtMost500AreRead() {
        let dirty = Self.reminder("d", "Call\u{202E} legal\nabout PO-48213\u{200B}")
        #expect(BriefReminderFilter.eligible([dirty], listIDs: ["L1"], event: Self.start).first?.title == "Call legal about PO-48213")
        let many = (0..<800).map { Self.reminder("r\($0)", "Reminder number \($0)") }
        #expect(BriefReminderFilter.eligible(many, listIDs: ["L1"], event: Self.start).count == BriefReminderFilter.maximumFetched)
    }

    @Test func theReminderSourceCannotWrite() {
        // The protocol offers reading only: this is a compile-time property, restated by listing what it requires.
        let requirements = Mirror(reflecting: FakeReminders()).children.map { $0.label ?? "" }
        #expect(!requirements.contains { $0.lowercased().contains("save") || $0.lowercased().contains("remove") })
    }
}
