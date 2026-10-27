// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The ledger of what Vauta created in Reminders and Calendar (`created_actions`), the follow-up meetings (`follow_ups`) and the
/// meeting's time zone. Everything here is bookkeeping: nothing in this file talks to EventKit.
extension MeetingStore {
    private static let actionColumns = """
        SELECT id, target, src_kind, src_id, meeting_id, ek_id, ek_external_id, container_id, title_hash, state, written_at, updated_at, due_basis
        FROM created_actions
        """

    private static func action(_ r: Row) -> CreatedAction? {
        guard let target = ActionTarget(rawValue: r.string(1)), let source = ActionSource(rawValue: r.string(2)),
              let state = ActionState(rawValue: r.string(9)) else { return nil }
        return CreatedAction(id: r.int(0), target: target, source: source, sourceID: r.int(3), meetingID: r.optionalInt(4), itemID: r.optionalString(5),
                             externalID: r.optionalString(6), containerID: r.optionalString(7), titleHash: r.string(8), state: state,
                             writtenAt: Date(timeIntervalSince1970: r.double(10)), updatedAt: Date(timeIntervalSince1970: r.double(11)),
                             dueBasis: DueBasis(stored: r.optionalString(12)))
    }

    // MARK: Reading

    public func action(_ id: Int64) throws -> CreatedAction? {
        try db.query(Self.actionColumns + " WHERE id = ?", [.integer(id)]).compactMap(Self.action).first
    }

    /// The live row (`writing`, `created`, `linked`, `handed_off`) of this source and target, if any. There is at most one.
    public func liveAction(target: ActionTarget, source: ActionSource, sourceID: Int64) throws -> CreatedAction? {
        try db.query(Self.actionColumns + " WHERE target = ? AND src_kind = ? AND src_id = ? AND state IN ('writing','created','linked','handed_off')",
                     [.text(target.rawValue), .text(source.rawValue), .integer(sourceID)]).compactMap(Self.action).first
    }

    /// The newest row of this source and target, live or not (a `missing` row still says "Not in Reminders any more").
    public func latestAction(target: ActionTarget, source: ActionSource, sourceID: Int64) throws -> CreatedAction? {
        try db.query(Self.actionColumns + " WHERE target = ? AND src_kind = ? AND src_id = ? ORDER BY id DESC LIMIT 1",
                     [.text(target.rawValue), .text(source.rawValue), .integer(sourceID)]).compactMap(Self.action).first
    }

    /// Every row of a meeting, oldest first (live or not).
    public func actions(ofMeeting meetingID: Int64) throws -> [CreatedAction] {
        try db.query(Self.actionColumns + " WHERE meeting_id = ? ORDER BY id", [.integer(meetingID)]).compactMap(Self.action)
    }

    /// Rows whose write was never confirmed (a crash between the intent and the promotion).
    public func writingActions(ofMeeting meetingID: Int64? = nil) throws -> [CreatedAction] {
        if let meetingID {
            return try db.query(Self.actionColumns + " WHERE state = 'writing' AND meeting_id = ? ORDER BY id", [.integer(meetingID)]).compactMap(Self.action)
        }
        return try db.query(Self.actionColumns + " WHERE state = 'writing' ORDER BY id").compactMap(Self.action)
    }

    /// An `orphaned` row of the same meeting and target whose written title has this hash: the person deleted the task here and the
    /// reminder is still in Reminders. Newest first.
    public func orphanedAction(meetingID: Int64?, target: ActionTarget, titleHash: String) throws -> CreatedAction? {
        try db.query(Self.actionColumns + " WHERE state = 'orphaned' AND target = ? AND title_hash = ? AND meeting_id IS ? ORDER BY id DESC",
                     [.text(target.rawValue), .text(titleHash), meetingID.map { .integer($0) }]).compactMap(Self.action).first
    }

    /// Identifiers of every live reminder row, and the tasks that have one: the brief drops these reminders and shows the task once.
    public func liveReminderIdentifiers() throws -> LedgerIdentifiers {
        var out = LedgerIdentifiers()
        for r in try db.query("SELECT ek_id, ek_external_id, src_kind, src_id FROM created_actions WHERE target = 'reminder' AND state IN ('created','linked')") {
            if let id = r.optionalString(0) { out.itemIDs.insert(id) }
            if let id = r.optionalString(1) { out.externalIDs.insert(id) }
            if r.string(2) == ActionSource.task.rawValue { out.taskIDs.insert(r.int(3)) }
        }
        return out
    }

    /// How many reminders and events Vauta created from this meeting stay in Reminders and Calendar when it is deleted. A reminder the
    /// person already had and linked (`linked`) is not Vauta's, so it is not counted.
    public func createdActionCounts(ofMeeting meetingID: Int64) throws -> (reminders: Int, events: Int) {
        let rows = try db.query("""
            SELECT target, count(*) FROM created_actions WHERE meeting_id = ? AND state = 'created' AND target IN ('reminder','event') GROUP BY target
            """, [.integer(meetingID)])
        var counts = (reminders: 0, events: 0)
        for r in rows { if r.string(0) == "reminder" { counts.reminders = Int(r.int(1)) } else { counts.events = Int(r.int(1)) } }
        return counts
    }

    // MARK: Writing the ledger

    private static var now: Double { AppClock.now.timeIntervalSince1970 }

    /// Step (i) of a write: commits a `writing` row before anything reaches EventKit. For a task it also makes the task the person's
    /// (`source = 'user'`, as `markTaskChecked` does), in the same transaction, so a rewrite of the minutes never deletes it.
    /// Throws `alreadyLive` when this source already has a live row for the target: nothing is written then.
    /// `trackDue` records the task's due day and `writtenDay` (the day the reminder is written with) for the read-back.
    public func beginAction(target: ActionTarget, source: ActionSource, sourceID: Int64, containerID: String?, titleHash: String,
                            trackDue: Bool = false, writtenDay: DueDay? = nil) async throws -> ActionIntent {
        let intent: ActionIntent = try transaction {
            if let live = try liveAction(target: target, source: source, sourceID: sourceID) { throw ActionLedgerError.alreadyLive(live) }
            var meetingID: Int64?
            var restore: String?
            var basis: String?
            switch source {
            case .task:
                guard let row = try db.query("SELECT meeting_id, source, due_day FROM tasks WHERE id = ?", [.integer(sourceID)]).first else { throw ActionLedgerError.sourceMissing }
                meetingID = row.optionalInt(0)
                if trackDue { basis = DueBasis(task: row.optionalString(2).flatMap { DueDay($0) }, written: writtenDay).stored }
                if row.string(1) != "user" {
                    restore = row.string(1)
                    try run("UPDATE tasks SET source = 'user' WHERE id = ?", [.integer(sourceID)])
                }
            case .followUp:
                guard let row = try db.query("SELECT meeting_id FROM follow_ups WHERE id = ?", [.integer(sourceID)]).first else { throw ActionLedgerError.sourceMissing }
                meetingID = row.int(0)
            }
            let now = Self.now
            try run("""
                INSERT INTO created_actions(target, src_kind, src_id, meeting_id, container_id, title_hash, state, written_at, updated_at, due_basis)
                VALUES (?, ?, ?, ?, ?, ?, 'writing', ?, ?, ?)
                """, [.text(target.rawValue), .text(source.rawValue), .integer(sourceID), meetingID.map { .integer($0) },
                      containerID.map { .text($0) }, .text(titleHash), .real(now), .real(now), basis.map { .text($0) }])
            let id = db.lastInsertRowID
            guard let created = try action(id) else { throw ActionLedgerError.sourceMissing }
            return ActionIntent(action: created, restoreSource: restore)
        }
        try await commitEdit()
        return intent
    }

    /// Step (iii): the write was saved; the row gets its identifiers and becomes `created` (or `handed_off` for an `.ics`).
    public func completeAction(_ id: Int64, itemID: String?, externalID: String?, state: ActionState = .created) async throws {
        try transaction {
            let current = try db.query("SELECT state FROM created_actions WHERE id = ?", [.integer(id)]).first?.string(0)
            switch current {
            case ActionState.writing.rawValue:
                try run("UPDATE created_actions SET ek_id = ?, ek_external_id = ?, state = ?, updated_at = ? WHERE id = ? AND state = 'writing'",
                        [itemID.map { .text($0) }, externalID.map { .text($0) }, .text(state.rawValue), .real(Self.now), .integer(id)])
                // A follow-up meeting that now has an event (or a hand-off) is done in the same commit, so a crash cannot leave it `suggested`.
                if state != .writing {
                    try run("UPDATE follow_ups SET state = 'done' WHERE state = 'suggested' AND id = (SELECT src_id FROM created_actions WHERE id = ? AND src_kind = 'follow_up')", [.integer(id)])
                }
            case ActionState.orphaned.rawValue:
                // The task was deleted while the item was being saved: the item exists, so the row keeps its identifiers and stays an
                // orphan (it still counts against a duplicate, and nothing live points at a task that is gone).
                try run("UPDATE created_actions SET ek_id = ?, ek_external_id = ?, updated_at = ? WHERE id = ? AND state = 'orphaned'",
                        [itemID.map { .text($0) }, externalID.map { .text($0) }, .real(Self.now), .integer(id)])
            default:
                break
            }
        }
        try await commitEdit()
    }

    /// The write failed before saving (or was reconciled as not written): the row goes, and the task returns to what it was.
    public func abortAction(_ intent: ActionIntent) async throws {
        try transaction {
            try run("DELETE FROM created_actions WHERE id = ? AND state = 'writing'", [.integer(intent.action.id)])
            if let restore = intent.restoreSource, intent.action.source == .task {
                // Only when nothing else has made the task the person's meanwhile (another live row, or an edit that did it).
                try run("""
                    UPDATE tasks SET source = ?2 WHERE id = ?1 AND source = 'user'
                      AND NOT EXISTS (SELECT 1 FROM created_actions WHERE src_kind = 'task' AND src_id = ?1 AND state IN ('writing','created','linked','handed_off'))
                    """, [.integer(intent.action.sourceID), .text(restore)])
            }
        }
        try await commitEdit()
    }

    /// "Use This Reminder" / "Use This One": records an existing item as the task's, without writing anything to EventKit.
    @discardableResult
    public func recordLinked(target: ActionTarget, source: ActionSource, sourceID: Int64, containerID: String?, itemID: String?, externalID: String?,
                             titleHash: String) async throws -> CreatedAction {
        let intent = try await beginAction(target: target, source: source, sourceID: sourceID, containerID: containerID, titleHash: titleHash)
        try await completeAction(intent.action.id, itemID: itemID, externalID: externalID, state: .linked)
        return try action(intent.action.id) ?? intent.action
    }

    /// A claimed orphan: its identifiers move to a new `linked` row for the task that was added again, and the orphan row is dropped.
    @discardableResult
    public func claimOrphan(_ orphan: CreatedAction, for sourceID: Int64) async throws -> CreatedAction {
        let linked = try await recordLinked(target: orphan.target, source: .task, sourceID: sourceID, containerID: orphan.containerID,
                                            itemID: orphan.itemID, externalID: orphan.externalID, titleHash: orphan.titleHash)
        try run("DELETE FROM created_actions WHERE id = ? AND state = 'orphaned'", [.integer(orphan.id)])
        try await commitEdit()
        return linked
    }

    public func setActionState(_ id: Int64, _ state: ActionState) async throws {
        try run("UPDATE created_actions SET state = ?, updated_at = ? WHERE id = ?", [.text(state.rawValue), .real(Self.now), .integer(id)])
        try await commitEdit()
    }

    /// The item's identifiers changed (a sync re-identified it): the ledger follows.
    public func updateActionIdentifiers(_ id: Int64, itemID: String?, externalID: String?) async throws {
        try run("UPDATE created_actions SET ek_id = ?, ek_external_id = ?, updated_at = ? WHERE id = ?",
                [itemID.map { .text($0) }, externalID.map { .text($0) }, .real(Self.now), .integer(id)])
        try await commitEdit()
    }

    /// Forget: the row stops counting against a second write. Nothing is removed from Reminders or Calendar.
    public func forgetAction(_ id: Int64) async throws { try await setActionState(id, .removed) }

    // MARK: Time zone

    /// The zone the meeting was recorded in (the zone at import for an imported one); nil for meetings from before migration 28.
    public func meetingTimeZone(_ meetingID: Int64) throws -> TimeZone? {
        try db.query("SELECT time_zone FROM meetings WHERE id = ?", [.integer(meetingID)]).first?.optionalString(0).flatMap { TimeZone(identifier: $0) }
    }

    // MARK: Follow-up meetings

    public func followUps(_ meetingID: Int64) throws -> [FollowUp] {
        try db.query("""
            SELECT id, meeting_id, segment_id, t, title, day, day_inferred, minute_of_day, duration_min, source, state, recipe FROM follow_ups
            WHERE meeting_id = ? ORDER BY coalesce(day, '9999-99-99'), coalesce(minute_of_day, 0), id
            """, [.integer(meetingID)]).compactMap { r in
            guard let source = FollowUp.Source(rawValue: r.string(9)), let state = FollowUp.State(rawValue: r.string(10)) else { return nil }
            return FollowUp(id: r.int(0), meetingID: r.int(1), segmentID: r.optionalInt(2), t: r.optionalDouble(3), title: r.string(4),
                            day: r.optionalString(5).flatMap { DueDay($0) }, dayInferred: r.int(6) != 0, minuteOfDay: r.optionalInt(7).map(Int.init),
                            durationMinutes: r.optionalInt(8).map(Int.init), source: source, state: state, recipe: Int(r.int(11)))
        }
    }

    @discardableResult
    public func addFollowUp(_ meetingID: Int64, title: String, day: DueDay?, dayInferred: Bool = false, minuteOfDay: Int? = nil, durationMinutes: Int? = nil,
                            segmentID: Int64? = nil, t: Double? = nil, source: FollowUp.Source = .user,
                            recipe: Int = FollowUpDetector.recipe) async throws -> Int64 {
        let clean = Self.clean(title, max: 300)
        try run("""
            INSERT INTO follow_ups(meeting_id, segment_id, t, title, day, day_inferred, minute_of_day, duration_min, source, state, recipe, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'suggested', ?, ?)
            """, [.integer(meetingID), segmentID.map { .integer($0) }, t.map { .real($0) }, .text(clean), day.map { .text($0.string) },
                  .integer(dayInferred ? 1 : 0), minuteOfDay.map { .integer(Int64($0)) }, durationMinutes.map { .integer(Int64($0)) },
                  .text(source.rawValue), .integer(Int64(recipe)), .real(Self.now)])
        let id = db.lastInsertRowID
        try await commitEdit()
        return id
    }

    public func setFollowUpState(_ id: Int64, _ state: FollowUp.State) async throws {
        try run("UPDATE follow_ups SET state = ? WHERE id = ?", [.text(state.rawValue), .integer(id)])
        try await commitEdit()
    }

    public func deleteFollowUp(_ id: Int64) async throws {
        try run("DELETE FROM follow_ups WHERE id = ?", [.integer(id)])
        try await commitEdit()
    }

    /// Stores the detector's candidates for a meeting after the minutes succeed (or are rewritten). Detected rows that are still
    /// `suggested` are replaced; ones the person dismissed or acted on stay and are matched by cited segment and day, so a re-run
    /// never brings a dismissed candidate back. Rows the person added themselves are never touched.
    public func storeDetectedFollowUps(_ candidates: [FollowUpCandidate], meetingID: Int64, recipe: Int = FollowUpDetector.recipe) async throws {
        try transaction {
            // A suggestion that has a live event or hand-off is kept: deleting it would orphan the ledger row and let it come back as new.
            try run("""
                DELETE FROM follow_ups WHERE meeting_id = ? AND source = 'detected' AND state = 'suggested'
                  AND NOT EXISTS (SELECT 1 FROM created_actions WHERE src_kind = 'follow_up' AND src_id = follow_ups.id
                                  AND state IN ('writing','created','linked','handed_off'))
                """, [.integer(meetingID)])
            let kept = try followUps(meetingID).filter { $0.source == .detected }
            for c in candidates where !kept.contains(where: { $0.segmentID == c.segmentID && $0.day == c.day }) {
                try run("""
                    INSERT INTO follow_ups(meeting_id, segment_id, t, title, day, day_inferred, minute_of_day, duration_min, source, state, recipe, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'detected', 'suggested', ?, ?)
                    """, [.integer(meetingID), c.segmentID.map { .integer($0) }, c.t.map { .real($0) }, .text(Self.clean(c.title, max: 300)),
                          c.day.map { .text($0.string) }, .integer(c.dayInferred ? 1 : 0), c.minuteOfDay.map { .integer(Int64($0)) },
                          c.durationMinutes.map { .integer(Int64($0)) }, .integer(Int64(recipe)), .real(Self.now)])
            }
            try run("UPDATE meetings SET follow_ups_recipe = ? WHERE id = ?", [.integer(Int64(recipe)), .integer(meetingID)])
        }
        try await commitEdit()
    }
}

/// A next meeting found in a meeting or added by the person. `day` is a day in the meeting's time zone; nil when none was said.
public struct FollowUp: Sendable, Equatable, Identifiable {
    public enum Source: String, Sendable { case detected, user }
    public enum State: String, Sendable { case suggested, dismissed, done }

    public let id: Int64
    public let meetingID: Int64
    public let segmentID: Int64?
    public let t: Double?
    public var title: String
    public var day: DueDay?
    /// Resolved from "next Tuesday" or "next week", never said as a date: the editor says so.
    public var dayInferred: Bool
    public var minuteOfDay: Int?
    public var durationMinutes: Int?
    public let source: Source
    public var state: State
    public let recipe: Int

    public init(id: Int64, meetingID: Int64, segmentID: Int64? = nil, t: Double? = nil, title: String, day: DueDay? = nil, dayInferred: Bool = false,
                minuteOfDay: Int? = nil, durationMinutes: Int? = nil, source: Source = .user, state: State = .suggested, recipe: Int = FollowUpDetector.recipe) {
        self.id = id
        self.meetingID = meetingID
        self.segmentID = segmentID
        self.t = t
        self.title = title
        self.day = day
        self.dayInferred = dayInferred
        self.minuteOfDay = minuteOfDay
        self.durationMinutes = durationMinutes
        self.source = source
        self.state = state
        self.recipe = recipe
    }
}
