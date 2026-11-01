// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import EventKit
import Foundation
import VautaCore

/// Reads the calendar events the brief is made from. Read-only: nothing here saves, removes or commits anything. An event is read only
/// when the caller asks for the window it needs, and only the first `limit` events that qualify (the one about to start and the one after
/// it) are turned into a `BriefEvent`: the others are looked at for their start and calendar only. The event's description is read only
/// when "Use the invitation's notes" is on, for the events returned, and it stays in memory.
final class EventKitBriefEventSource: BriefEventSource, @unchecked Sendable {
    private let store: EKEventStore
    private let readNotes: @Sendable () -> Bool
    private let qualifies: @Sendable (BriefEvent) -> Bool
    private let limit: Int

    init(store: EKEventStore, readNotes: @escaping @Sendable () -> Bool, limit: Int = 2, qualifies: @escaping @Sendable (BriefEvent) -> Bool) {
        self.store = store
        self.readNotes = readNotes
        self.limit = limit
        self.qualifies = qualifies
    }

    func events(from: Date, to: Date, calendarIDs: Set<String>) async -> [BriefEvent] {
        read(from: from, to: to, calendarIDs: calendarIDs, limit: limit, matching: nil)
    }

    /// The events of these occurrences only, whatever else is in the window: no limit applies to them.
    func events(from: Date, to: Date, calendarIDs: Set<String>, matching occurrences: Set<BriefOccurrence>) async -> [BriefEvent] {
        guard !occurrences.isEmpty else { return [] }
        return read(from: from, to: to, calendarIDs: calendarIDs, limit: occurrences.count, matching: occurrences)
    }

    /// "Today": every event of the day in the chosen calendars, all-day ones and ones that are not meetings too. Title, time, calendar,
    /// attendees and link only: the description is never read here (a brief built on demand reads it as any brief does).
    func dayEvents(from: Date, to: Date, calendarIDs: Set<String>, limit: Int) async -> [BriefEvent] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess, !calendarIDs.isEmpty else { return [] }
        let calendars = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: calendars))
            .sorted { $0.startDate < $1.startDate }.prefix(limit).map { Self.briefEvent($0, notes: false) }
    }

    private func read(from: Date, to: Date, calendarIDs: Set<String>, limit: Int, matching occurrences: Set<BriefOccurrence>?) -> [BriefEvent] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess, !calendarIDs.isEmpty else { return [] }
        let calendars = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let withNotes = readNotes()
        let ordered = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: calendars))
            .filter { !$0.isAllDay }.sorted { $0.startDate < $1.startDate }
        var out: [BriefEvent] = []
        for event in ordered {
            // Qualified without the description first; only an event that is going to be shown has its description read.
            let bare = Self.briefEvent(event, notes: false)
            if let occurrences, !occurrences.contains(bare.occurrence) { continue }
            guard qualifies(bare) else { continue }
            out.append(Self.briefEvent(event, notes: withNotes))
            if out.count >= limit { break }
        }
        return out
    }

    private static func briefEvent(_ event: EKEvent, notes: Bool) -> BriefEvent {
        let attendees = (event.attendees ?? []).map { p -> BriefAttendee in
            let address = p.url.absoluteString
            return BriefAttendee(name: p.name ?? "", email: address.lowercased().hasPrefix("mailto:") ? String(address.dropFirst(7)) : nil,
                                 isCurrentUser: p.isCurrentUser)
        }
        let declined = (event.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined }
        return BriefEvent(identifier: event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "",
                          start: event.startDate, end: event.endDate, calendarID: event.calendar.calendarIdentifier, isAllDay: event.isAllDay,
                          currentUserDeclined: declined, attendees: attendees, isRecurring: event.hasRecurrenceRules,
                          service: CalendarWatcher.link(of: event)?.service, invitationNotes: notes ? event.notes : nil,
                          calendarColor: event.calendar.cgColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }.map {
                              BriefColor(red: Double($0.redComponent), green: Double($0.greenComponent), blue: Double($0.blueComponent))
                          }, eventIdentifier: event.eventIdentifier)
    }
}

/// Reads the reminders the brief shows: incomplete ones in the lists the person chose, with their title, due date, list and priority.
/// Notes, URLs, locations and completed reminders are never read. Read-only; macOS offers no read-only access, so Vauta asks for full
/// access, only when the person turns reminders on.
final class EventKitReminderSource: BriefReminderSource, @unchecked Sendable {
    private let store: EKEventStore

    init(store: EKEventStore) { self.store = store }

    var access: BriefReminderAccess {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// Shows the system prompt (only when access was never asked).
    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToReminders()) ?? false
    }

    func lists() async -> [BriefReminderList] {
        guard access == .granted else { return [] }
        return store.calendars(for: .reminder).map { BriefReminderList(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title) }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    func incompleteReminders(in listIDs: Set<String>, limit: Int) async -> [BriefReminder] {
        guard access == .granted, !listIDs.isEmpty else { return [] }
        let calendars = store.calendars(for: .reminder).filter { listIDs.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        // Only the fields the brief needs leave the callback (EKReminder is not Sendable).
        let fetched: [(reminder: BriefReminder, modified: Date)] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let calendar = Calendar.current
                continuation.resume(returning: (reminders ?? []).map { r in
                    (BriefReminder(id: r.calendarItemIdentifier, title: r.title ?? "", due: r.dueDateComponents.flatMap { calendar.date(from: $0) },
                                   listID: r.calendar.calendarIdentifier, listName: r.calendar.title, priority: r.priority, isCompleted: r.isCompleted,
                                   externalID: r.calendarItemExternalIdentifier),
                     r.lastModifiedDate ?? r.creationDate ?? .distantPast)
                })
            }
        }
        return fetched.sorted { $0.modified > $1.modified }.prefix(limit).map(\.reminder)
    }
}
