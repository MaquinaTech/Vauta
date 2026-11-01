// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Meetings › Upcoming › Today: every event of the person's calendar day in the chosen calendars, all-day ones and ones that are not
/// meetings too; a meeting the brief is for has its brief on demand.
@Suite("Brief: Today")
struct BriefTodayTests {
    static func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone) ?? .gmt
        return c
    }

    static let madrid = calendar("Europe/Madrid")
    /// 2026-11-03 10:30 in Madrid.
    static let now = madrid.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 10, minute: 30)) ?? .now
    static let rules = BriefEventRules(calendarIDs: ["work", "home"])
    static let me = BriefAttendee(name: "Me", email: nil, isCurrentUser: true)
    static let ana = BriefAttendee(name: "Ana López", email: "ana@example.com")

    static func at(_ hour: Int, _ minute: Int = 0, day: Int = 3, _ c: Calendar = madrid) -> Date {
        c.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)) ?? .now
    }

    static func event(_ id: String, _ start: Date, _ minutes: Double = 60, calendar: String = "work", allDay: Bool = false, declined: Bool = false,
                      attendees: [BriefAttendee] = [], service: ConferencingService? = nil) -> BriefEvent {
        BriefEvent(identifier: id, title: id, start: start, end: start.addingTimeInterval(minutes * 60), calendarID: calendar, isAllDay: allDay,
                   currentUserDeclined: declined, attendees: attendees, service: service)
    }

    @Test func theDayIsMidnightToMidnightInThePersonsTimeZone() {
        let day = BriefToday.window(now: Self.now, calendar: Self.madrid)
        #expect(day.start == Self.at(0) && day.end == Self.at(0, day: 4))
        // The same instant is still 2 November in Los Angeles.
        let la = Self.calendar("America/Los_Angeles")
        let there = BriefToday.window(now: Self.now, calendar: la)
        #expect(la.component(.day, from: there.start) == 3 && there.duration == 86_400, "10:30 in Madrid is 01:30 in Los Angeles, the same day there")
        let early = Self.madrid.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 0, minute: 30)) ?? .now
        #expect(la.component(.day, from: BriefToday.window(now: early, calendar: la).start) == 2)
        // The day the clocks go back has 25 hours.
        let fallBack = Self.madrid.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12)) ?? .now
        #expect(BriefToday.window(now: fallBack, calendar: Self.madrid).duration == 25 * 3600)
    }

    @Test func everyEventOfTheDayIsListedAllDayFirstAndEachSaysWhenItIs() {
        let events = [
            Self.event("Standup", Self.at(9), 15, attendees: [Self.me, Self.ana], service: .zoom),
            Self.event("Supplier review", Self.at(10), 90, attendees: [Self.me, Self.ana], service: .teams),
            Self.event("Lunch", Self.at(13), calendar: "home"),
            Self.event("Holiday in Bilbao", Self.at(0), 24 * 60, calendar: "home", allDay: true),
            Self.event("Board", Self.at(16), declined: true, attendees: [Self.me, Self.ana]),
            Self.event("Design review", Self.at(15), attendees: [Self.me, Self.ana]),
            Self.event("Dentist", Self.at(18), 30),
            Self.event("Tomorrow's call", Self.at(9, day: 4), service: .zoom),
            Self.event("Yesterday's call", Self.at(17, day: 2), service: .zoom),
            Self.event("Other calendar", Self.at(11), calendar: "birthdays"),
        ]
        let items = BriefToday.items(events, now: Self.now, rules: Self.rules, calendar: Self.madrid)
        #expect(items.map(\.event.title) == ["Holiday in Bilbao", "Standup", "Supplier review", "Lunch", "Design review", "Board", "Dentist"])
        #expect(items.map(\.moment) == [.allDay, .past, .now, .next, .later, .later, .later])
        // A brief only for the meetings it is for: a link or someone else invited, not declined, not all day.
        #expect(items.filter(\.hasBrief).map(\.event.title) == ["Standup", "Supplier review", "Design review"])
        var noInPerson = Self.rules
        noInPerson.includeInPerson = false
        #expect(BriefToday.items(events, now: Self.now, rules: noInPerson, calendar: Self.madrid).filter(\.hasBrief).map(\.event.title) == ["Standup", "Supplier review"])
    }

    @Test func anEventFromTheNightBeforeIsTodaysButOneThatEndsAtMidnightIsNot() {
        let overnight = Self.event("Release night", Self.at(23, day: 2), 120)
        let endsAtMidnight = Self.event("Late call", Self.at(23, day: 2), 60)
        let atMidnight = Self.event("Reminder", Self.at(0), 0)
        let items = BriefToday.items([overnight, endsAtMidnight, atMidnight], now: Self.now, rules: Self.rules, calendar: Self.madrid)
        #expect(items.map(\.event.title) == ["Release night", "Reminder"])
        #expect(items.map(\.moment) == [.past, .past])
    }

    @Test func anOccurrenceIsListedOnceAndTwoAtTheSameTimeKeepAStableOrder() {
        let a = Self.event("A", Self.at(12), 30), b = Self.event("B", Self.at(12), 60), c = Self.event("C", Self.at(12), 60)
        let items = BriefToday.items([c, a, b, c], now: Self.now, rules: Self.rules, calendar: Self.madrid)
        #expect(items.map(\.event.title) == ["B", "C", "A"], "the longer first, then by title; the same occurrence twice is one line")
        #expect(items.map(\.moment) == [.next, .later, .later], "one next event, even when several start together")
    }
}
