// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// One line of "Today".
public struct BriefTodayItem: Sendable, Equatable, Identifiable {
    public enum Moment: Sendable, Equatable {
        /// An all-day event: it has no time.
        case allDay
        /// It ended before now.
        case past
        /// It is on now.
        case now
        /// The first event that starts after now.
        case next
        /// After the next one.
        case later
    }

    public let event: BriefEvent
    public let moment: Moment
    /// It is a meeting the brief is for (`BriefEventSelector.qualifies`): its brief can be built on demand.
    public let hasBrief: Bool
    public var id: BriefOccurrence { event.occurrence }

    public init(event: BriefEvent, moment: Moment, hasBrief: Bool) {
        self.event = event
        self.moment = moment
        self.hasBrief = hasBrief
    }
}

/// Meetings › Upcoming › Today: every event of today in the chosen calendars, with no model and nothing written. A meeting the brief is
/// for has its brief on demand; any other event (all day, declined, with nobody else, in a calendar the brief does not read) is only
/// listed. Today is the person's own calendar day, from midnight to midnight in their time zone.
public enum BriefToday {
    /// More than a person's day ever holds: the reader stops there.
    public static let limit = 100

    /// Midnight to midnight of the day that holds `now`, in `calendar` (a day of 23 or 25 hours when the clocks change).
    public static func window(now: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }

    /// The list: all-day events first (by title), then the others by start, the longer first when two start together. Each says when it
    /// is relative to `now`, and whether it has a brief. An event that only touches the day's edges (ends at midnight) is not today's.
    public static func items(_ events: [BriefEvent], now: Date, rules: BriefEventRules, calendar: Calendar) -> [BriefTodayItem] {
        let day = window(now: now, calendar: calendar)
        var seen = Set<BriefOccurrence>()
        let today = events.filter { event in
            rules.calendarIDs.contains(event.calendarID) && overlaps(event, day) && seen.insert(event.occurrence).inserted
        }
        let allDay = today.filter(\.isAllDay).sorted { ($0.title, $0.identifier) < ($1.title, $1.identifier) }
        let timed = today.filter { !$0.isAllDay }.sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end > b.end }
            return (a.title, a.identifier) < (b.title, b.identifier)
        }
        let next = timed.first { $0.start > now }?.occurrence
        return allDay.map { BriefTodayItem(event: $0, moment: .allDay, hasBrief: false) } + timed.map { event in
            let moment: BriefTodayItem.Moment = event.end <= now ? .past : event.start <= now ? .now : event.occurrence == next ? .next : .later
            return BriefTodayItem(event: event, moment: moment, hasBrief: BriefEventSelector.qualifies(event, rules: rules))
        }
    }

    /// An event of length zero counts on the day it is at; any other must share some time with the day.
    static func overlaps(_ event: BriefEvent, _ day: DateInterval) -> Bool {
        if event.end == event.start { return event.start >= day.start && event.start < day.end }
        return event.start < day.end && event.end > day.start
    }
}
