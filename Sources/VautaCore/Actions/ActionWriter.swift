// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What the person has allowed for Reminders or Calendar. Reminders only ever have `.full`; events can also be `.writeOnly`, which
/// Vauta treats like `.notDetermined` for reading (it cannot check for duplicates) and never asks for.
public enum ActionAccess: Sendable, Equatable {
    case notDetermined, denied, restricted, writeOnly, full
}

/// Reminders and events are the two things Vauta can add.
public enum ActionKind: String, Sendable {
    case reminder, event
}

/// A reminder list or a calendar the person could add to.
public struct ActionContainer: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    /// The account the list lives in ("iCloud", "Exchange"), shown next to it.
    public let account: String
    public init(id: String, title: String, account: String) {
        self.id = id
        self.title = title
        self.account = account
    }
}

/// Exactly the fields of a reminder Vauta writes. Nothing else is set (no priority, URL, location or start date).
public struct ReminderWrite: Sendable, Equatable {
    public let title: String
    public let containerID: String
    /// Year, month and day only (no calendar, no time zone): the due date floats with the person. With an alert it also has the hour
    /// and minute, still floating.
    public let due: DateComponents?
    /// One alarm at the due time (a relative offset of 0 from the floating due time), never an absolute date.
    public let alert: Bool
    public let notes: String?
    public init(title: String, containerID: String, due: DateComponents?, alert: Bool, notes: String?) {
        self.title = title
        self.containerID = containerID
        self.due = due
        self.alert = alert
        self.notes = notes
    }
}

/// Exactly the fields of a calendar event Vauta writes: no attendees, URL, alarm or recurrence.
public struct EventWrite: Sendable, Equatable {
    public let title: String
    public let containerID: String
    public let day: DueDay
    /// nil for an all-day event.
    public let minuteOfDay: Int?
    public let durationMinutes: Int
    /// The zone the day and time were said in (the meeting's).
    public let timeZone: TimeZone
    public let notes: String?
    public var isAllDay: Bool { minuteOfDay == nil }
    public init(title: String, containerID: String, day: DueDay, minuteOfDay: Int?, durationMinutes: Int, timeZone: TimeZone, notes: String?) {
        self.title = title
        self.containerID = containerID
        self.day = day
        self.minuteOfDay = minuteOfDay
        self.durationMinutes = durationMinutes
        self.timeZone = timeZone
        self.notes = notes
    }
}

/// An item read back from Reminders or Calendar: only what the checks need (titles, state, dates), in memory.
public struct ActionItem: Sendable, Equatable {
    public var itemID: String
    public var externalID: String?
    public var containerID: String
    public var title: String
    public var isCompleted: Bool
    /// The due day of a reminder (floating components as they are), or the start day of an event.
    public var day: DueDay?
    /// The start time of an event with a time (minutes since midnight in the event's own zone); nil for a reminder or an all-day event.
    public var minuteOfDay: Int?
    public var creationDate: Date?
    public var lastModified: Date?
    public init(itemID: String, externalID: String? = nil, containerID: String, title: String, isCompleted: Bool = false, day: DueDay? = nil,
                minuteOfDay: Int? = nil, creationDate: Date? = nil, lastModified: Date? = nil) {
        self.itemID = itemID
        self.externalID = externalID
        self.containerID = containerID
        self.title = title
        self.isCompleted = isCompleted
        self.day = day
        self.minuteOfDay = minuteOfDay
        self.creationDate = creationDate
        self.lastModified = lastModified
    }
}

public struct ActionReceipt: Sendable, Equatable {
    public let itemID: String
    public let externalID: String?
    public let containerID: String
    public init(itemID: String, externalID: String?, containerID: String) {
        self.itemID = itemID
        self.externalID = externalID
        self.containerID = containerID
    }
}

public enum ActionWriterError: Error, Equatable {
    case accessDenied
    case containerUnavailable
    case saveFailed
}

/// The whole of what Vauta may do to Reminders and Calendar. The one app-side implementation is `EventKitActionWriter` (the only file
/// that calls EventKit's save, remove or commit; a source-scan test enforces it). Tests and the evaluation use `FakeActionWriter`.
///
/// The surface is the policy: there is no call that changes an item, completes a reminder or removes by search. `remove` takes the
/// identifier of an item Vauta created and recorded.
public protocol ActionWriter: Sendable {
    func access(_ kind: ActionKind) async -> ActionAccess
    /// Asks macOS for access. Called only from a button the person pressed.
    func requestAccess(_ kind: ActionKind) async -> Bool
    /// Writable lists or calendars only (not subscribed, birthdays or read-only).
    func containers(_ kind: ActionKind) async -> [ActionContainer]
    func defaultContainerID(_ kind: ActionKind) async -> String?

    /// Saves one reminder and commits. Throws `saveFailed` when nothing was saved.
    func addReminder(_ write: ReminderWrite) async throws -> ActionReceipt
    func addEvent(_ write: EventWrite) async throws -> ActionReceipt
    /// Removes the item with this identifier. Only ever called with an identifier from the ledger.
    func remove(_ kind: ActionKind, itemID: String) async throws

    /// The item by identifier, else by external identifier within `containerID`. nil: it is gone.
    func item(_ kind: ActionKind, itemID: String?, externalID: String?, containerID: String?) async -> ActionItem?
    /// Incomplete reminders of one list (titles in memory, for the duplicate check and crash recovery). Nothing from other lists.
    func incompleteReminders(in containerID: String) async -> [ActionItem]
    /// Reminders of one list completed since `date` (crash recovery only: a reminder that was saved and then completed before the ledger
    /// knew about it). Titles in memory; nothing from other lists.
    func completedReminders(in containerID: String, since date: Date) async -> [ActionItem]
    /// Events of one calendar between the day before and the day after `day`.
    func events(around day: DueDay, in containerID: String, timeZone: TimeZone) async -> [ActionItem]
}
