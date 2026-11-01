// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// One attendee of the event being briefed, as the calendar lists them.
public struct BriefAttendee: Sendable, Equatable {
    public let name: String
    public let email: String?
    public let isCurrentUser: Bool

    public init(name: String, email: String?, isCurrentUser: Bool = false) {
        self.name = name
        self.email = email
        self.isCurrentUser = isCurrentUser
    }
}

/// The calendar event a brief is about. It lives in memory only: nothing here is ever stored, and `invitationNotes` (written by
/// whoever sent the invitation, so untrusted) is never copied into a snapshot that is persisted, a log or a request to a model server.
/// A calendar's colour as sRGB components, so the page can draw the dot the Calendar app shows. Not content: it says which calendar.
public struct BriefColor: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public struct BriefEvent: Sendable, Equatable {
    /// `calendarItemExternalIdentifier` of the event (the series' identifier when it repeats).
    public let identifier: String
    public let title: String
    public let start: Date
    public let end: Date
    public let calendarID: String
    public let isAllDay: Bool
    /// The person answered "decline" to the invitation.
    public let currentUserDeclined: Bool
    public let attendees: [BriefAttendee]
    public let isRecurring: Bool
    /// The service of the event's meeting link, if it has one.
    public let service: ConferencingService?
    /// The event's description, read only when "Use the invitation's notes" is on. Memory only.
    public let invitationNotes: String?
    /// The colour of the event's calendar, when known.
    public let calendarColor: BriefColor?
    /// The calendar store's own identifier of this occurrence (`EKEvent.eventIdentifier`), only to open the event in Calendar.
    public let eventIdentifier: String?

    public init(identifier: String, title: String, start: Date, end: Date, calendarID: String, isAllDay: Bool = false,
                currentUserDeclined: Bool = false, attendees: [BriefAttendee] = [], isRecurring: Bool = false,
                service: ConferencingService? = nil, invitationNotes: String? = nil, calendarColor: BriefColor? = nil, eventIdentifier: String? = nil) {
        self.identifier = identifier
        self.title = title
        self.start = start
        self.end = max(end, start)
        self.calendarID = calendarID
        self.isAllDay = isAllDay
        self.currentUserDeclined = currentUserDeclined
        self.attendees = attendees
        self.isRecurring = isRecurring
        self.service = service
        self.invitationNotes = invitationNotes
        self.calendarColor = calendarColor
        self.eventIdentifier = eventIdentifier
    }

    /// The same key `CalendarWatcher` uses to link a recording to its series.
    public var seriesKey: String? { isRecurring ? identifier : nil }

    public var occurrence: BriefOccurrence { BriefOccurrence(identifier: identifier, start: start) }

    public var otherAttendees: [BriefAttendee] { attendees.filter { !$0.isCurrentUser } }

    /// What a recording of this event stores (title, attendees and series), as `applyCalendar` takes it. The notes are not part of it.
    public var calendarMeeting: CalendarMeeting {
        CalendarMeeting(title: title, attendees: attendees.map { .init(name: $0.name, email: $0.email, isCurrentUser: $0.isCurrentUser) },
                        seriesKey: seriesKey)
    }
}

/// One occurrence of an event: a recurring event has the same identifier every time, so the start tells them apart.
public struct BriefOccurrence: Hashable, Sendable {
    public let identifier: String
    /// Whole seconds since 1970.
    public let startSeconds: Int64

    public init(identifier: String, start: Date) {
        self.identifier = identifier
        startSeconds = Int64(start.timeIntervalSince1970.rounded())
    }
}

/// Where the events come from. The app reads EventKit (read-only); tests and the evaluation use fixtures.
public protocol BriefEventSource: Sendable {
    /// Timed events that start in `[from, to]` in the chosen calendars. The caller picks the one to brief (`BriefEventSelector`).
    func events(from: Date, to: Date, calendarIDs: Set<String>) async -> [BriefEvent]

    /// The events of exactly these occurrences, found in `[from, to]`. A reader that limits how many events it returns must not let other
    /// meetings crowd these out (two meetings already in progress would otherwise hide a third that is due).
    func events(from: Date, to: Date, calendarIDs: Set<String>, matching occurrences: Set<BriefOccurrence>) async -> [BriefEvent]

    /// "Today" (`BriefToday`): every event that overlaps `[from, to)` in the chosen calendars, all-day ones and ones that are not meetings
    /// too, at most `limit`, earliest first, without their notes.
    func dayEvents(from: Date, to: Date, calendarIDs: Set<String>, limit: Int) async -> [BriefEvent]
}

extension BriefEventSource {
    /// A source that only knows meetings lists those.
    public func dayEvents(from: Date, to: Date, calendarIDs: Set<String>, limit: Int) async -> [BriefEvent] {
        Array(await events(from: from, to: to, calendarIDs: calendarIDs).prefix(limit))
    }

    public func events(from: Date, to: Date, calendarIDs: Set<String>, matching occurrences: Set<BriefOccurrence>) async -> [BriefEvent] {
        await events(from: from, to: to, calendarIDs: calendarIDs).filter { occurrences.contains($0.occurrence) }
    }
}

/// The rules of which calendar events get a brief and when.
public struct BriefEventRules: Sendable, Equatable {
    /// The calendars the person chose (empty: none).
    public var calendarIDs: Set<String>
    /// "Also for meetings without a video link": an event with at least one other attendee counts (in-person meetings).
    public var includeInPerson: Bool

    public init(calendarIDs: Set<String>, includeInPerson: Bool = true) {
        self.calendarIDs = calendarIDs
        self.includeInPerson = includeInPerson
    }
}

public enum BriefEventSelector {
    /// The brief of the next event is on screen until this long after it started.
    public static let lateGrace: TimeInterval = 15 * 60
    /// "Upcoming" looks at most this far ahead.
    public static let horizon: TimeInterval = 12 * 3600
    /// Lead times the person can choose, in minutes (0 = Off), and the default.
    public static let leadOptions = [0, 5, 10, 15, 30]
    public static let defaultLeadMinutes = 10

    public static func qualifies(_ event: BriefEvent, rules: BriefEventRules) -> Bool {
        guard !event.isAllDay, !event.currentUserDeclined, rules.calendarIDs.contains(event.calendarID) else { return false }
        if event.service != nil { return true }
        return rules.includeInPerson && !event.otherAttendees.isEmpty
    }

    /// The qualifying events that still matter at `now` (not ended, not started more than `lateGrace` ago, starting within the
    /// horizon), earliest first. Ties go to the longer event, then to the title, so the order does not depend on the calendar's.
    public static func candidates(_ events: [BriefEvent], now: Date, rules: BriefEventRules) -> [BriefEvent] {
        events.filter { event in
            qualifies(event, rules: rules) && event.end > now && event.start >= now - lateGrace && event.start <= now + horizon
        }.sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end > b.end }
            return (a.title, a.identifier) < (b.title, b.identifier)
        }
    }

    /// The event about to start (or just started).
    public static func next(_ events: [BriefEvent], now: Date, rules: BriefEventRules) -> BriefEvent? {
        candidates(events, now: now, rules: rules).first
    }

    /// What the Upcoming view reads: the event about to start and the one after it within the horizon. Nothing else is looked at.
    public static func upcoming(_ events: [BriefEvent], now: Date, rules: BriefEventRules) -> [BriefEvent] {
        Array(candidates(events, now: now, rules: rules).prefix(2))
    }

    /// When the notification goes out, or nil when the person turned it off.
    public static func fireDate(for event: BriefEvent, leadMinutes: Int) -> Date? {
        guard leadMinutes > 0 else { return nil }
        return event.start.addingTimeInterval(-Double(leadOptions.contains(leadMinutes) ? leadMinutes : defaultLeadMinutes) * 60)
    }
}

/// One notification per occurrence of an event: remembers which were sent (memory only; a relaunch may send the one still due once).
public struct BriefNotificationLedger: Sendable {
    private var sent: [BriefOccurrence: Date] = [:]

    public init() {}

    /// Whether to send the notification for `event` now, and if so marks it sent. It is due from the lead time until the event starts.
    public mutating func claim(_ event: BriefEvent, now: Date, leadMinutes: Int) -> Bool {
        sent = sent.filter { now.timeIntervalSince($0.value) < 86_400 }
        guard let fire = BriefEventSelector.fireDate(for: event, leadMinutes: leadMinutes), now >= fire, now < event.start,
              sent[event.occurrence] == nil else { return false }
        sent[event.occurrence] = now
        return true
    }

    public func wasSent(_ event: BriefEvent) -> Bool { sent[event.occurrence] != nil }

    public func wasSent(_ occurrence: BriefOccurrence) -> Bool { sent[occurrence] != nil }

    /// Marks an occurrence as notified before its event has been read (the wake-up knows only the occurrence), so it is never due twice.
    public mutating func markSent(_ occurrence: BriefOccurrence, at date: Date) { sent[occurrence] = date }
}

/// The agenda lines of an invitation's description. The description is written by whoever sent the invitation: it is cleaned of
/// hidden characters, shown as plain text (links are never made clickable), cut short, and only lines that look like a list are used.
public enum BriefInvitationNotes {
    public static let maximumCharacters = 4_000
    public static let maximumLines = 8
    public static let maximumLineCharacters = 160

    public static func agendaLines(from notes: String?) -> [String] {
        guard let notes else { return [] }
        let text = TextSanitizer.clean(String(notes.prefix(maximumCharacters)))
        var out: [String] = []
        var seen = Set<String>()
        for raw in text.split(separator: "\n") {
            guard let body = listItem(String(raw)) else { continue }
            let line = TextSanitizer.oneLine(body, limit: maximumLineCharacters)
            guard line.count >= 3, !isOnlyLink(line), seen.insert(TextKeys.norm(line)).inserted else { continue }
            out.append(line)
            if out.count == maximumLines { break }
        }
        return out
    }

    /// The text of a line that starts like a list item ("- x", "• x", "1. x", "2) x"), else nil.
    private static func listItem(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return nil }
        if "-*•–—·▪◦‣".contains(first) {
            let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
        if (1...2).contains(digits.count) {
            let after = trimmed.dropFirst(digits.count)
            if let mark = after.first, ".)".contains(mark) {
                let rest = after.dropFirst().trimmingCharacters(in: .whitespaces)
                return rest.isEmpty ? nil : rest
            }
        }
        return nil
    }

    private static func isOnlyLink(_ line: String) -> Bool {
        let lower = line.lowercased()
        return (lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.")) && !lower.contains(" ")
    }
}
