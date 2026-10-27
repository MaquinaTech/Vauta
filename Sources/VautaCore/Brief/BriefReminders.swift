// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// One reminder, as little of it as the brief needs: title, due date, list and priority. Notes, URLs, locations and completed
/// reminders are never read. Memory only.
public struct BriefReminder: Sendable, Equatable, Identifiable {
    /// Opaque identifier (to open the reminder in Reminders).
    public let id: String
    public let title: String
    public let due: Date?
    public let listID: String
    public let listName: String
    /// EventKit's scale: 0 none, 1 (high) to 9 (low).
    public let priority: Int
    public let isCompleted: Bool
    /// The identifier that survives a sync re-identifying the item; the ledger of reminders Vauta created matches on it too.
    public let externalID: String?

    public init(id: String, title: String, due: Date?, listID: String, listName: String, priority: Int = 0, isCompleted: Bool = false, externalID: String? = nil) {
        self.id = id
        self.title = title
        self.due = due
        self.listID = listID
        self.listName = listName
        self.priority = priority
        self.isCompleted = isCompleted
        self.externalID = externalID
    }
}

public struct BriefReminderList: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let source: String
    public init(id: String, title: String, source: String) {
        self.id = id
        self.title = title
        self.source = source
    }
}

/// What the app may do with Reminders right now.
public enum BriefReminderAccess: Sendable, Equatable {
    case notDetermined
    case denied
    case granted
}

/// Where reminders come from. The app reads EventKit (read-only: no save, remove or commit exists on this protocol); tests and the
/// evaluation use fixtures.
public protocol BriefReminderSource: Sendable {
    var access: BriefReminderAccess { get async }
    func lists() async -> [BriefReminderList]
    /// Incomplete reminders of these lists (at most `limit`, most recent first). Nothing else is read.
    func incompleteReminders(in listIDs: Set<String>, limit: Int) async -> [BriefReminder]
}

public enum BriefReminderFilter {
    /// Fetched per build, in memory only.
    public static let maximumFetched = 500
    /// Due dates from this long before the meeting to this long after it (or no due date).
    public static let daysBefore = 14
    public static let daysAfter = 7
    public static let maximumShown = 3

    /// The reminders that may appear in the brief of `event`: in a chosen list, incomplete, due within −14…+7 days of the meeting's
    /// start or with no due date, with a usable title. Titles are cleaned to one line. Order is kept.
    /// `ledger` holds the reminders Vauta created or linked from a task: they are left out (the task is shown once, as the task).
    public static func eligible(_ reminders: [BriefReminder], listIDs: Set<String>, event start: Date, ledger: LedgerIdentifiers = LedgerIdentifiers()) -> [BriefReminder] {
        let from = start.addingTimeInterval(-Double(daysBefore) * 86_400), to = start.addingTimeInterval(Double(daysAfter) * 86_400)
        var out: [BriefReminder] = []
        for reminder in reminders.prefix(maximumFetched) {
            guard listIDs.contains(reminder.listID), !reminder.isCompleted else { continue }
            if ledger.itemIDs.contains(reminder.id) || (reminder.externalID.map { ledger.externalIDs.contains($0) } ?? false) { continue }
            if let due = reminder.due, due < from || due > to { continue }
            let title = TextSanitizer.oneLine(reminder.title, limit: 200)
            guard !title.isEmpty else { continue }
            out.append(BriefReminder(id: reminder.id, title: title, due: reminder.due, listID: reminder.listID, listName: reminder.listName,
                                     priority: reminder.priority, isCompleted: false, externalID: reminder.externalID))
        }
        return out
    }
}
