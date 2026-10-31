// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Where a meeting goes in the meetings list, by the day it started in the user's calendar: today, yesterday, earlier this
/// week, earlier this month, then one section per month. A meeting dated after now (a clock that was changed) is today's.
public enum MeetingDateSection: Hashable, Sendable {
    case today
    case yesterday
    /// Earlier in this calendar week (the user's first weekday), before yesterday.
    case thisWeek
    /// Earlier in this calendar month, before this week.
    case thisMonth
    /// An earlier month, by its year and month number in the calendar.
    case month(year: Int, month: Int)

    public static func of(_ date: Date, now: Date, calendar: Calendar) -> MeetingDateSection {
        Starts(now: now, calendar: calendar).section(of: date)
    }

    /// Where the sections begin, worked out once for a whole list.
    private struct Starts {
        let calendar: Calendar
        let today: Date
        let yesterday: Date
        let week: Date
        let month: Date

        init(now: Date, calendar: Calendar) {
            self.calendar = calendar
            today = calendar.startOfDay(for: now)
            yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            week = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
            month = calendar.dateInterval(of: .month, for: now)?.start ?? today
        }

        func section(of date: Date) -> MeetingDateSection {
            if date >= today { return .today }
            if date >= yesterday { return .yesterday }
            if date >= week { return .thisWeek }
            if date >= month { return .thisMonth }
            let parts = calendar.dateComponents([.year, .month], from: date)
            return .month(year: parts.year ?? 0, month: parts.month ?? 0)
        }
    }

    /// A section of the list and its items.
    public struct Group<Item>: Identifiable {
        public let section: MeetingDateSection
        public let items: [Item]
        public var id: MeetingDateSection { section }
    }

    /// The items in sections, each section once, in the order its first item comes (the list is newest first, so the
    /// sections are too); the items keep their order inside each.
    public static func group<Item>(_ items: [Item], now: Date, calendar: Calendar, date: (Item) -> Date) -> [Group<Item>] {
        let starts = Starts(now: now, calendar: calendar)
        var order: [MeetingDateSection] = []
        var grouped: [MeetingDateSection: [Item]] = [:]
        for item in items {
            let section = starts.section(of: date(item))
            if grouped[section] == nil { order.append(section) }
            grouped[section, default: []].append(item)
        }
        return order.map { Group(section: $0, items: grouped[$0] ?? []) }
    }
}
