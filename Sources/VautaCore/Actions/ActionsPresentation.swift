// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What a task row shows about its reminder, from the ledger row and what reading Reminders back found. Pure: the
/// views draw it, the tests check it. Every state is a symbol plus text, never colour alone.
public struct TaskActionState: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// No live reminder: the row is unchanged and the menu offers "Add to Reminders…".
        case none
        /// Vauta created a reminder for it.
        case inReminders
        /// The task is linked to a reminder the person already had.
        case linked
        /// The reminder is gone from Reminders: "Add Again…" or "Forget".
        case missing
        /// Completed in Reminders while the task is still open here: "Mark Done Here" (never automatic).
        case doneInReminders
        /// The reminder's due day differs from the task's: shown, never written.
        case dueDiffers(reminder: DueDay?, task: DueDay?)
    }

    public var kind: Kind
    /// The ledger row behind it.
    public var rowID: Int64?
    /// The list the reminder is in (its identifier), to name it next to "In Reminders".
    public var containerID: String?
    /// The reminder's identifier, for "Open in Reminders".
    public var itemID: String?
    /// The row is `linked` (Unlink instead of Remove).
    public var isLinked: Bool
    /// The reminder belongs to another task of the same chain (confirmed "same" links): this task only shows it. Forget, Unlink and Remove act
    /// on the task that owns the record, never from here.
    public var isBorrowed = false

    public static let none = TaskActionState(kind: .none, rowID: nil, containerID: nil, itemID: nil, isLinked: false)

    /// `row` is the newest ledger row of the task for Reminders (`latestAction`); `readBack` what `ActionService.readBack` found.
    public static func make(row: CreatedAction?, readBack: ActionStatus?, borrowed: Bool = false) -> TaskActionState {
        guard let row, row.target == .reminder else { return .none }
        let linked = row.state == .linked
        func state(_ kind: Kind) -> TaskActionState {
            TaskActionState(kind: kind, rowID: row.id, containerID: row.containerID, itemID: row.itemID, isLinked: linked, isBorrowed: borrowed)
        }
        switch row.state {
        case .missing:
            return state(.missing)
        case .created, .linked:
            switch readBack {
            case .missing?: return state(.missing)
            case .doneInReminders?: return state(.doneInReminders)
            case .dueDiffers(let reminder, let task)?: return state(.dueDiffers(reminder: reminder, task: task))
            case .inReminders?, nil: return state(linked ? .linked : .inReminders)
            }
        case .writing, .handedOff, .orphaned, .removed:
            return .none
        }
    }

    /// Whether Remove from Reminders… is offered (Vauta created it).
    public var canRemove: Bool {
        switch kind {
        case .inReminders, .doneInReminders, .dueDiffers: !isLinked && !isBorrowed
        case .none, .linked, .missing: false
        }
    }
    public var canUnlink: Bool {
        switch kind {
        case .inReminders, .linked, .doneInReminders, .dueDiffers: isLinked && !isBorrowed
        case .none, .missing: false
        }
    }
    public var canOpen: Bool {
        switch kind {
        case .inReminders, .linked, .doneInReminders, .dueDiffers: true
        case .none, .missing: false
        }
    }
}

/// A meeting whose minutes are ready and have not been reviewed: identifiers, counts and a time only. No title and no text are kept,
/// so the card needs nothing from the encrypted store to be drawn and shows nothing while Meetings are locked.
public struct FollowUpPending: Sendable, Equatable {
    public let meetingID: Int64
    public let readyAt: Date
    public var tasks: Int
    public var followUps: Int
    /// Follow-up meetings are looked for after the minutes, never while a recording runs: false until they were.
    public var detected: Bool
    public init(meetingID: Int64, readyAt: Date, tasks: Int, followUps: Int, detected: Bool = true) {
        self.meetingID = meetingID
        self.readyAt = readyAt
        self.tasks = tasks
        self.followUps = followUps
        self.detected = detected
    }
}

/// The panel's Follow-up card after a meeting: one card for back-to-back meetings, hidden while a
/// recording runs (the list is kept), gone 2 hours after the newest minutes, off with the setting. It can create nothing.
public enum FollowUpCard {
    public static let lifetime: TimeInterval = 2 * 3600

    public enum Content: Sendable, Equatable {
        case hidden
        /// Several meetings: "Minutes ready for 2 meetings". `newest` is the one Review… opens.
        case several(count: Int, newest: Int64)
        case one(FollowUpPending)

        public var newestMeetingID: Int64? {
            switch self {
            case .hidden: nil
            case .several(_, let newest): newest
            case .one(let pending): pending.meetingID
            }
        }
    }

    /// The pending meetings that are still worth showing: with something to review, and ready less than 2 hours before the newest.
    public static func visible(_ pending: [FollowUpPending], now: Date) -> [FollowUpPending] {
        let reviewable = pending.filter { $0.tasks > 0 || $0.followUps > 0 }
        guard let newest = reviewable.map(\.readyAt).max(), now.timeIntervalSince(newest) < lifetime else { return [] }
        return reviewable.sorted { $0.readyAt < $1.readyAt }
    }

    public static func content(_ pending: [FollowUpPending], now: Date, recording: Bool, enabled: Bool) -> Content {
        guard enabled, !recording else { return .hidden }
        let list = visible(pending, now: now)
        guard let newest = list.last else { return .hidden }
        return list.count == 1 ? .one(newest) : .several(count: list.count, newest: newest.meetingID)
    }

    /// When the card goes away on its own (so the panel can redraw then); nil with nothing pending.
    public static func expiry(_ pending: [FollowUpPending]) -> Date? {
        pending.map(\.readyAt).max().map { $0.addingTimeInterval(lifetime) }
    }
}

extension MeetingStore {
    /// The detector recipe that last ran on a meeting (0 = never), so opening the Follow-up sheet detects once.
    public func followUpsRecipe(_ meetingID: Int64) throws -> Int {
        Int(try db.query("SELECT follow_ups_recipe FROM meetings WHERE id = ?", [.integer(meetingID)]).first?.int(0) ?? 0)
    }
}
