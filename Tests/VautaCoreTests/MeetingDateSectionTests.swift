// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The sections of the meetings list, in the user's calendar and time zone.
@Suite struct MeetingDateSectionTests {
    /// A Gregorian calendar whose weeks start on `firstWeekday` (1 Sunday, 2 Monday), in `zone`.
    private func calendar(firstWeekday: Int = 2, zone: String = "Europe/Madrid") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = firstWeekday
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ text: String, _ calendar: Calendar) -> Date {
        let parts = text.split(whereSeparator: { "- :".contains($0) }).map { Int($0)! }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4]))!
    }

    @Test func eachDayGoesToItsSection() {
        let cal = calendar()
        // Thursday, 15 October 2026: the week began on Monday the 12th.
        let now = date("2026-10-15 10:00", cal)
        let section = { (text: String) in MeetingDateSection.of(self.date(text, cal), now: now, calendar: cal) }
        #expect(section("2026-10-15 00:00") == .today)
        #expect(section("2026-10-15 23:30") == .today, "later today (a clock that was changed) is still today")
        #expect(section("2026-10-14 23:59") == .yesterday)
        #expect(section("2026-10-14 00:00") == .yesterday)
        #expect(section("2026-10-13 23:59") == .thisWeek)
        #expect(section("2026-10-12 00:00") == .thisWeek)
        #expect(section("2026-10-11 23:59") == .thisMonth)
        #expect(section("2026-10-01 00:00") == .thisMonth)
        #expect(section("2026-09-30 23:59") == .month(year: 2026, month: 9))
        #expect(section("2025-10-20 12:00") == .month(year: 2025, month: 10))
    }

    @Test func theUsersFirstWeekdayDecidesTheWeek() {
        // Tuesday, 20 October 2026: Sunday the 18th is in this week when weeks start on Sunday, and in the one before when
        // they start on Monday.
        let monday = calendar(firstWeekday: 2), sunday = calendar(firstWeekday: 1)
        let tuesdayNow = date("2026-10-20 09:00", monday)
        #expect(MeetingDateSection.of(date("2026-10-18 12:00", monday), now: tuesdayNow, calendar: monday) == .thisMonth)
        #expect(MeetingDateSection.of(date("2026-10-18 12:00", sunday), now: tuesdayNow, calendar: sunday) == .thisWeek)
    }

    @Test func aWeekThatBeganLastMonthKeepsItsDays() {
        let cal = calendar()
        // Friday, 2 October 2026: the week began on Monday, 28 September.
        let now = date("2026-10-02 18:00", cal)
        #expect(MeetingDateSection.of(date("2026-09-29 10:00", cal), now: now, calendar: cal) == .thisWeek)
        #expect(MeetingDateSection.of(date("2026-09-27 10:00", cal), now: now, calendar: cal) == .month(year: 2026, month: 9))
    }

    @Test func theDayIsTheOneInTheUsersTimeZone() {
        let madrid = calendar(zone: "Europe/Madrid"), tokyo = calendar(zone: "Asia/Tokyo")
        let now = date("2026-10-15 10:00", madrid)
        // 22:30 the evening before in Madrid is already today in Tokyo (UTC+9 against UTC+2).
        let evening = date("2026-10-14 22:30", madrid)
        #expect(MeetingDateSection.of(evening, now: now, calendar: madrid) == .yesterday)
        #expect(MeetingDateSection.of(evening, now: now, calendar: tokyo) == .today)
    }

    @Test func theFirstDayOfTheMonthHasNoEarlierDaysInIt() {
        let cal = calendar()
        // Sunday, 1 November 2026, at the end of a week that began in October.
        let now = date("2026-11-01 09:00", cal)
        #expect(MeetingDateSection.of(date("2026-10-31 20:00", cal), now: now, calendar: cal) == .yesterday)
        #expect(MeetingDateSection.of(date("2026-10-27 20:00", cal), now: now, calendar: cal) == .thisWeek)
        #expect(MeetingDateSection.of(date("2026-10-25 20:00", cal), now: now, calendar: cal) == .month(year: 2026, month: 10))
    }

    @Test func groupsKeepTheListOrderAndShowEachSectionOnce() {
        let cal = calendar()
        let now = date("2026-10-15 10:00", cal)
        let dates = ["2026-10-15 09:00", "2026-10-15 08:00", "2026-10-14 12:00", "2026-10-01 12:00", "2026-09-03 12:00",
                     "2026-08-30 12:00", "2026-08-01 12:00"].map { date($0, cal) }
        let groups = MeetingDateSection.group(Array(dates.enumerated()), now: now, calendar: cal) { $0.element }
        #expect(groups.map(\.section) == [.today, .yesterday, .thisMonth, .month(year: 2026, month: 9), .month(year: 2026, month: 8)])
        #expect(groups.map { $0.items.map(\.offset) } == [[0, 1], [2], [3], [4], [5, 6]])
        // A list out of order (a meeting moved to the top) still shows each section once.
        let shuffled = MeetingDateSection.group([dates[4], dates[0], dates[5]], now: now, calendar: cal) { $0 }
        #expect(shuffled.map(\.section) == [.month(year: 2026, month: 9), .today, .month(year: 2026, month: 8)])
        #expect(MeetingDateSection.group([Date](), now: now, calendar: cal) { $0 }.isEmpty)
    }

    /// The list is grouped on every update of the sidebar: ten years of meetings take a moment, not a frame.
    @Test func aLongListIsGroupedOnce() {
        let cal = calendar()
        let now = date("2026-10-15 10:00", cal)
        let dates = (0..<10_000).map { now.addingTimeInterval(-Double($0) * 8 * 3600) }
        let start = Date()
        let groups = MeetingDateSection.group(dates, now: now, calendar: cal) { $0 }
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(groups.map(\.items.count).reduce(0, +) == 10_000)
        #expect(Set(groups.map(\.section)).count == groups.count)
    }
}
