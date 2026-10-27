// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import EventKit
import Foundation
import VautaCore

/// The only file in Vauta that writes to Reminders or Calendar. A source-scan test fails if any other file calls EventKit's save,
/// remove or commit. It does exactly what `ActionWriter` allows: add one reminder, add one event, remove an item by the identifier the
/// ledger recorded, and read back titles, states and dates of the lists and calendars it is asked about. It never edits or completes
/// an item, never creates a list or a calendar, never removes by search, and never asks for Calendar access (a person who has not
/// turned Calendar on gets an `.ics` file instead).
final class EventKitActionWriter: ActionWriter, @unchecked Sendable {
    private let store: EKEventStore

    init(store: EKEventStore = EKEventStore()) { self.store = store }

    private func entity(_ kind: ActionKind) -> EKEntityType { kind == .reminder ? .reminder : .event }

    func access(_ kind: ActionKind) async -> ActionAccess {
        switch EKEventStore.authorizationStatus(for: entity(kind)) {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .writeOnly: .writeOnly
        case .fullAccess: .full
        @unknown default: .denied
        }
    }

    /// Reminders: the macOS prompt, from a button the person pressed. Calendar: never asked here; the answer is whether access exists.
    func requestAccess(_ kind: ActionKind) async -> Bool {
        switch kind {
        case .reminder: (try? await store.requestFullAccessToReminders()) ?? false
        case .event: EKEventStore.authorizationStatus(for: .event) == .fullAccess
        }
    }

    private func writable(_ kind: ActionKind) -> [EKCalendar] {
        store.calendars(for: entity(kind)).filter { $0.allowsContentModifications && $0.type != .subscription && $0.type != .birthday }
    }

    func containers(_ kind: ActionKind) async -> [ActionContainer] {
        guard await access(kind) != .notDetermined, await access(kind) != .denied, await access(kind) != .restricted else { return [] }
        return writable(kind).map { ActionContainer(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title) }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    func defaultContainerID(_ kind: ActionKind) async -> String? {
        let calendar = kind == .reminder ? store.defaultCalendarForNewReminders() : store.defaultCalendarForNewEvents
        return calendar.flatMap { writable(kind).contains($0) ? $0.calendarIdentifier : nil }
    }

    // MARK: Writing

    func addReminder(_ write: ReminderWrite) async throws -> ActionReceipt {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { throw ActionWriterError.accessDenied }
        guard let list = writable(.reminder).first(where: { $0.calendarIdentifier == write.containerID }) else { throw ActionWriterError.containerUnavailable }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = write.title
        reminder.notes = write.notes
        reminder.dueDateComponents = write.due
        if write.alert, write.due?.hour != nil { reminder.addAlarm(EKAlarm(relativeOffset: 0)) }
        do { try store.save(reminder, commit: true) } catch { throw ActionWriterError.saveFailed }
        return ActionReceipt(itemID: reminder.calendarItemIdentifier, externalID: reminder.calendarItemExternalIdentifier, containerID: list.calendarIdentifier)
    }

    func addEvent(_ write: EventWrite) async throws -> ActionReceipt {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw ActionWriterError.accessDenied }
        guard let calendar = writable(.event).first(where: { $0.calendarIdentifier == write.containerID }) else { throw ActionWriterError.containerUnavailable }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = write.title
        event.notes = write.notes
        var zoned = Calendar(identifier: .gregorian)
        zoned.timeZone = write.timeZone
        if let minute = write.minuteOfDay {
            guard let start = zoned.date(from: write.day.floatingComponents(minuteOfDay: minute)) else { throw ActionWriterError.saveFailed }
            event.startDate = start
            event.endDate = start.addingTimeInterval(Double(write.durationMinutes) * 60)
            if write.timeZone != .current { event.timeZone = write.timeZone }
        } else {
            guard let start = Calendar.current.date(from: write.day.floatingComponents) else { throw ActionWriterError.saveFailed }
            event.isAllDay = true
            event.startDate = start
            event.endDate = start
        }
        do { try store.save(event, span: .thisEvent, commit: true) } catch { throw ActionWriterError.saveFailed }
        return ActionReceipt(itemID: event.calendarItemIdentifier, externalID: event.calendarItemExternalIdentifier, containerID: calendar.calendarIdentifier)
    }

    func remove(_ kind: ActionKind, itemID: String) async throws {
        guard EKEventStore.authorizationStatus(for: entity(kind)) == .fullAccess else { throw ActionWriterError.accessDenied }
        guard let found = store.calendarItem(withIdentifier: itemID) else { throw ActionWriterError.saveFailed }
        do {
            switch (kind, found) {
            case (.reminder, let reminder as EKReminder): try store.remove(reminder, commit: true)
            case (.event, let event as EKEvent): try store.remove(event, span: .thisEvent, commit: true)
            default: throw ActionWriterError.saveFailed
            }
        } catch { throw ActionWriterError.saveFailed }
    }

    // MARK: Reading back (titles, states and dates; never notes, URLs, locations or attendees)

    func item(_ kind: ActionKind, itemID: String?, externalID: String?, containerID: String?) async -> ActionItem? {
        guard EKEventStore.authorizationStatus(for: entity(kind)) == .fullAccess else { return nil }
        var found: EKCalendarItem?
        if let itemID, let candidate = store.calendarItem(withIdentifier: itemID) { found = candidate }
        if found == nil, let externalID {
            found = store.calendarItems(withExternalIdentifier: externalID).first { containerID == nil || $0.calendar.calendarIdentifier == containerID }
        }
        return found.flatMap { Self.map($0, kind: kind) }
    }

    func incompleteReminders(in containerID: String) async -> [ActionItem] {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess,
              let list = store.calendars(for: .reminder).first(where: { $0.calendarIdentifier == containerID }) else { return [] }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [list])
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).compactMap { Self.map($0, kind: .reminder) })
            }
        }
    }

    func completedReminders(in containerID: String, since date: Date) async -> [ActionItem] {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess,
              let list = store.calendars(for: .reminder).first(where: { $0.calendarIdentifier == containerID }) else { return [] }
        let predicate = store.predicateForCompletedReminders(withCompletionDateStarting: date, ending: nil, calendars: [list])
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).compactMap { Self.map($0, kind: .reminder) })
            }
        }
    }

    func events(around day: DueDay, in containerID: String, timeZone: TimeZone) async -> [ActionItem] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
              let calendar = store.calendars(for: .event).first(where: { $0.calendarIdentifier == containerID }) else { return [] }
        var zoned = Calendar(identifier: .gregorian)
        zoned.timeZone = timeZone
        guard let from = zoned.date(from: day.adding(days: -1).floatingComponents), let to = zoned.date(from: day.adding(days: 2).floatingComponents) else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: [calendar])).compactMap { Self.map($0, kind: .event) }
    }

    private static func map(_ item: EKCalendarItem, kind: ActionKind) -> ActionItem? {
        var day: DueDay?
        var minute: Int?
        var completed = false
        switch (kind, item) {
        case (.reminder, let reminder as EKReminder):
            completed = reminder.isCompleted
            if let c = reminder.dueDateComponents, let y = c.year, let m = c.month, let d = c.day { day = DueDay(year: y, month: m, day: d) }
        case (.event, let event as EKEvent):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = event.timeZone ?? .current
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: event.startDate)
            if let y = c.year, let m = c.month, let d = c.day { day = DueDay(year: y, month: m, day: d) }
            if !event.isAllDay, let h = c.hour, let min = c.minute { minute = h * 60 + min }
        default:
            return nil
        }
        return ActionItem(itemID: item.calendarItemIdentifier, externalID: item.calendarItemExternalIdentifier, containerID: item.calendar.calendarIdentifier,
                          title: item.title ?? "", isCompleted: completed, day: day, minuteOfDay: minute, creationDate: item.creationDate, lastModified: item.lastModifiedDate)
    }
}
