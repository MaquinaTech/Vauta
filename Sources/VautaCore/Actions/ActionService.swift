// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What the checks before a write found. The person decides what happens next; nothing is written for any case but `none`.
public enum DuplicateFinding: Sendable, Equatable {
    case none
    /// This task already has a live row in the ledger (added earlier, or being added): show its status.
    case alreadyAdded(CreatedAction)
    /// The person deleted the task here and its reminder is still in Reminders: Use This Reminder, or Add Anyway.
    case orphan(CreatedAction)
    /// An incomplete reminder with the same title (or nearly) is in the target list: Use This One, or Add Anyway.
    case existing(ActionItem)
    /// An event around the day that looks like this one: Open in Calendar (no Add button).
    case existingEvent(ActionItem)
    /// The person confirmed that this task is the same as an earlier one (a chain), and the earlier one has a live reminder: Use This Reminder.
    /// Nothing is written; the reminder is recorded as this task's too.
    case chainReminder(CreatedAction)
}

public enum AddOutcome: Sendable, Equatable {
    case added(CreatedAction)
    case duplicate(DuplicateFinding)
    /// Access is not granted: the editor explains and offers Allow Access… or Open System Settings. Nothing was written.
    case accessNeeded(ActionAccess)
    /// The chosen list or calendar is gone (or none can be written to). Nothing was written.
    case noContainer
    /// "Vauta couldn’t add the reminder. Nothing was added."
    case failed
    /// There is no Calendar access: the caller hands an `.ics` file to Calendar instead.
    case handOff
}

/// The facts the "Remove from Reminders…" confirmation shows.
public struct RemovalPreview: Sendable, Equatable {
    public let actionID: Int64
    public let kind: ActionKind
    public let title: String
    public let containerID: String
    /// The person changed the item in Reminders or Calendar after Vauta added it: the confirmation says so and Cancel is the default.
    public let edited: Bool
}

public enum RemoveOutcome: Sendable, Equatable {
    case removed
    /// The item changed in Reminders or Calendar after Vauta added it: ask again, with Cancel as the default.
    case editedElsewhere
    /// Nothing is removed for a `linked` or `handed_off` row, or for one that is not live.
    case notRemovable
    /// It was already gone: the row is marked `missing`.
    case missing
    case failed
}

/// What a surface that shows a task's reminder displays after reading it back.
public enum ActionStatus: Sendable, Equatable {
    /// The reminder exists and matches.
    case inReminders
    /// "Not in Reminders any more": Add Again… or Forget.
    case missing
    /// The reminder was completed in Reminders and the task is still open here: Mark Done Here (never automatic).
    case doneInReminders
    /// "In Reminders, due 10 Oct (here: 24 Oct)": shown with Open in Reminders; nothing is written.
    case dueDiffers(reminder: DueDay?, task: DueDay?)
}

/// Reminders and events from tasks and follow-up meetings, with the rules of design section 5: confirm per item, never twice, undo only
/// what Vauta created, read back what happened. The only way anything reaches an `ActionWriter`.
public actor ActionService {
    /// Reminders: an equal title, or at least this much alike by content words, is "already in your list".
    public static let reminderSimilarity = 0.8
    /// Events: a title at least this much alike around the day.
    public static let eventSimilarity = 0.6
    /// A reminder edited this long after Vauta saved it counts as changed by the person.
    static let editTolerance: TimeInterval = 10
    /// A save that returned late is still found: an item created more than this after the intent is not Vauta's (the person typed it).
    static let adoptionWindow: TimeInterval = 120

    let store: MeetingStore
    let writer: any ActionWriter
    /// Writes that are running, by source: a second press waits for the first and reports it, and the recovery of dead intents leaves
    /// their rows alone.
    private var pending: [String: Task<AddOutcome, Never>] = [:]
    /// `.ics` hand-offs that are being written (the same keys), so the recovery of dead intents leaves their rows alone.
    var handingOff: Set<String> = []
    /// A `writing` row of an `.ics` hand-off this much older is dead: a crash between the intent and the promotion.
    static let handOffGrace: TimeInterval = 10

    static func key(_ source: ActionSource, _ sourceID: Int64, _ target: ActionTarget) -> String { "\(source.rawValue)#\(sourceID)#\(target.rawValue)" }

    public init(store: MeetingStore, writer: any ActionWriter) {
        self.store = store
        self.writer = writer
    }

    // MARK: Before writing

    /// The checks in order: the ledger, an orphan of the same task, then the target list.
    public func check(task: TaskItem, draft: ReminderDraft) async -> DuplicateFinding {
        // A dead `writing` row (a crash between the intent and the promotion) is settled first, so it is never reported as "already added".
        await reconcileWriting(meetingID: task.meetingID)
        if let live = try? await store.liveAction(target: .reminder, source: .task, sourceID: task.id) { return .alreadyAdded(live) }
        // A confirmed chain shares its reminder: another member of the chain already has one.
        if let others = try? await store.chainMembers(ofTask: task.id) {
            for other in others {
                if let live = try? await store.liveAction(target: .reminder, source: .task, sourceID: other) { return .chainReminder(live) }
            }
        }
        for hash in draft.searchHashes {
            if let orphan = try? await store.orphanedAction(meetingID: task.meetingID, target: .reminder, titleHash: hash) { return .orphan(orphan) }
        }
        guard await writer.access(.reminder) == .full else { return .none }
        let titles = draft.searchTitles
        let existing = await writer.incompleteReminders(in: draft.containerID)
        if let match = existing.first(where: { item in titles.contains { ActionTitle.isSame(item.title, $0, threshold: Self.reminderSimilarity) } }) { return .existing(match) }
        return .none
    }

    /// Events around the candidate's day in the target calendar (full Calendar access only): "Already in your calendar".
    public func checkEvent(followUp: FollowUp, draft: EventDraft) async -> DuplicateFinding {
        await reconcileWriting(meetingID: followUp.meetingID)
        if let live = try? await store.liveAction(target: .event, source: .followUp, sourceID: followUp.id) { return .alreadyAdded(live) }
        guard await writer.access(.event) == .full else { return .none }
        let events = await writer.events(around: draft.day, in: draft.containerID, timeZone: draft.timeZone)
        if let match = events.first(where: { ActionTitle.isSame($0.title, draft.write().title, threshold: Self.eventSimilarity) }) { return .existingEvent(match) }
        return .none
    }

    // MARK: Adding a reminder

    /// Adds one reminder. `acceptingDuplicate` is the person's "Add Anyway" for an orphan or an equal reminder in the list; it never
    /// overrides the ledger (a task that is live is never written a second time).
    public func addReminder(task: TaskItem, draft: ReminderDraft, acceptingDuplicate: Bool = false) async -> AddOutcome {
        let access = await writer.access(.reminder)
        guard access == .full else { return .accessNeeded(access) }
        guard !draft.write().title.isEmpty else { return .failed }
        guard await writer.containers(.reminder).contains(where: { $0.id == draft.containerID }) else { return .noContainer }
        // A leftover intent of this task (a crash after the save, before the bookkeeping) is settled first.
        await reconcileWriting(meetingID: task.meetingID)
        if let live = try? await store.liveAction(target: .reminder, source: .task, sourceID: task.id) { return .duplicate(.alreadyAdded(live)) }
        if !acceptingDuplicate {
            let finding = await check(task: task, draft: draft)
            if finding != .none { return .duplicate(finding) }
        }
        return await write(source: .task, sourceID: task.id, containerID: draft.containerID, titleHash: draft.titleHash, kind: .reminder, writtenDay: .some(draft.dueDay)) {
            try await self.writer.addReminder(draft.write())
        }
    }

    /// Adds one event through EventKit. Without full Calendar access it returns `.handOff` (no prompt is ever raised for Calendar).
    public func addEvent(followUp: FollowUp, draft: EventDraft, acceptingDuplicate: Bool = false) async -> AddOutcome {
        let access = await writer.access(.event)
        guard access == .full else { return .handOff }
        guard await writer.containers(.event).contains(where: { $0.id == draft.containerID }) else { return .noContainer }
        await reconcileWriting(meetingID: followUp.meetingID)
        if let live = try? await store.liveAction(target: .event, source: .followUp, sourceID: followUp.id) { return .duplicate(.alreadyAdded(live)) }
        if !acceptingDuplicate {
            let finding = await checkEvent(followUp: followUp, draft: draft)
            // An event that looks like this one is never added on top: the person opens it in Calendar.
            if finding != .none { return .duplicate(finding) }
        }
        return await write(source: .followUp, sourceID: followUp.id, containerID: draft.containerID, titleHash: draft.titleHash, kind: .event, day: draft.day, timeZone: draft.timeZone) {
            try await self.writer.addEvent(draft.write())
        }
    }

    /// The three steps: intent committed, saved, promoted. A failed save takes the intent back; a save that threw after
    /// saving is found again by title and adopted, so it is neither lost nor repeated.
    private func write(source: ActionSource, sourceID: Int64, containerID: String, titleHash: String, kind: ActionKind, day: DueDay? = nil,
                       timeZone: TimeZone = .current, writtenDay: DueDay?? = nil, save: @escaping @Sendable () async throws -> ActionReceipt) async -> AddOutcome {
        let target: ActionTarget = kind == .reminder ? .reminder : .event
        let key = Self.key(source, sourceID, target)
        if let running = pending[key] {
            let outcome = await running.value
            if case .added(let row) = outcome { return .duplicate(.alreadyAdded(row)) }
            return outcome
        }
        let task = Task { await self.perform(source: source, sourceID: sourceID, containerID: containerID, titleHash: titleHash, kind: kind, target: target, day: day, timeZone: timeZone, writtenDay: writtenDay, save: save) }
        pending[key] = task
        let outcome = await task.value
        pending[key] = nil
        return outcome
    }

    private func perform(source: ActionSource, sourceID: Int64, containerID: String, titleHash: String, kind: ActionKind, target: ActionTarget, day: DueDay?,
                         timeZone: TimeZone, writtenDay: DueDay??, save: @escaping @Sendable () async throws -> ActionReceipt) async -> AddOutcome {
        let intent: ActionIntent
        do {
            intent = try await store.beginAction(target: target, source: source, sourceID: sourceID, containerID: containerID, titleHash: titleHash,
                                                  trackDue: writtenDay != nil, writtenDay: writtenDay ?? nil)
        } catch ActionLedgerError.alreadyLive(let live) {
            return .duplicate(.alreadyAdded(live))
        } catch {
            return .failed
        }
        do {
            let receipt = try await save()
            try await store.completeAction(intent.action.id, itemID: receipt.itemID, externalID: receipt.externalID)
        } catch {
            // Did the item reach the store anyway? Adopt it rather than leave it unrecorded.
            if let found = await find(kind: kind, containerID: containerID, after: intent.action.writtenAt, titleHash: titleHash, day: day, timeZone: timeZone) {
                try? await store.completeAction(intent.action.id, itemID: found.itemID, externalID: found.externalID)
            } else {
                try? await store.abortAction(intent)
                return .failed
            }
        }
        guard let row = try? await store.action(intent.action.id) else { return .failed }
        return .added(row)
    }

    // MARK: Crash recovery

    /// Settles every `writing` row of a meeting that no write in this process is working on: the item is searched in its container
    /// (reminders: the incomplete and the recently completed items of that list; events: around the day) created after the intent, with the same normalized title
    /// hash. Found: adopted as `created`. Not found: the row is deleted.
    public func reconcileWriting(meetingID: Int64? = nil) async {
        guard let rows = try? await store.writingActions(ofMeeting: meetingID) else { return }
        for row in rows where pending[Self.key(row.source, row.sourceID, row.target)] == nil {
            if row.target == .ics {
                // Nothing outside Vauta was touched before the file was written, so a dead hand-off is simply taken back; no access is needed.
                if !handingOff.contains(Self.key(row.source, row.sourceID, row.target)), Date.now.timeIntervalSince(row.writtenAt) > Self.handOffGrace {
                    try? await store.abortAction(ActionIntent(action: row, restoreSource: nil))
                }
                continue
            }
            let kind: ActionKind = row.target == .reminder ? .reminder : .event
            // Without full access the list cannot be searched: the row stays for when it can (nothing is concluded from not looking).
            guard await writer.access(kind) == .full else { continue }
            var found: ActionItem?
            if let container = row.containerID {
                var day: DueDay?
                var zone = TimeZone.current
                if row.source == .followUp, let meeting = row.meetingID {
                    day = (try? await store.followUps(meeting))?.first(where: { $0.id == row.sourceID })?.day
                    if let saved = try? await store.meetingTimeZone(meeting) { zone = saved }
                }
                found = await find(kind: kind, containerID: container, after: row.writtenAt, titleHash: row.titleHash, day: day, timeZone: zone)
            }
            if let found {
                try? await store.completeAction(row.id, itemID: found.itemID, externalID: found.externalID)
            } else {
                try? await store.abortAction(ActionIntent(action: row, restoreSource: nil))
            }
        }
    }

    private func find(kind: ActionKind, containerID: String, after: Date, titleHash: String, day: DueDay?, timeZone: TimeZone) async -> ActionItem? {
        guard await writer.access(kind) == .full else { return nil }
        let slack = after.addingTimeInterval(-1)
        let limit = after.addingTimeInterval(Self.adoptionWindow)
        let candidates: [ActionItem]
        switch kind {
        case .reminder:
            // A reminder that was saved and completed before the ledger heard of it is still Vauta's: it is not written a second time.
            candidates = await writer.incompleteReminders(in: containerID) + writer.completedReminders(in: containerID, since: slack)
        case .event:
            guard let day else { return nil }
            candidates = await writer.events(around: day, in: containerID, timeZone: timeZone)
        }
        return candidates.filter { let created = $0.creationDate ?? .distantPast; return created >= slack && created <= limit && ActionTitle.hash($0.title) == titleHash }
            .max { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
    }

    // MARK: Use an existing item, undo, forget

    /// "Use This One" / "Use This Reminder": records an item that is already there as the task's own. Nothing is written to EventKit.
    @discardableResult
    public func useExisting(task: TaskItem, finding: DuplicateFinding) async -> CreatedAction? {
        switch finding {
        case .existing(let item):
            return try? await store.recordLinked(target: .reminder, source: .task, sourceID: task.id, containerID: item.containerID, itemID: item.itemID,
                                                 externalID: item.externalID, titleHash: ActionTitle.hash(item.title))
        case .orphan(let orphan):
            return try? await store.claimOrphan(orphan, for: task.id)
        case .chainReminder(let row):
            // The same reminder, recorded for this member too: no write, and a `linked` row is never removed.
            return try? await store.recordLinked(target: .reminder, source: .task, sourceID: task.id, containerID: row.containerID, itemID: row.itemID,
                                                 externalID: row.externalID, titleHash: row.titleHash)
        default:
            return nil
        }
    }

    /// Undo and "Remove from Reminders…": removes only an item Vauta created (`created`), and asks first when the person changed it
    /// there. A `linked` or `handed_off` row is never removed.
    public func remove(actionID: Int64, confirmedEdited: Bool = false) async -> RemoveOutcome {
        guard let row = try? await store.action(actionID), row.state == .created, let itemID = row.itemID else { return .notRemovable }
        let kind: ActionKind = row.target == .reminder ? .reminder : .event
        guard row.target != .ics else { return .notRemovable }
        guard await writer.access(kind) == .full else { return .failed }
        guard let item = await writer.item(kind, itemID: itemID, externalID: row.externalID, containerID: row.containerID) else {
            try? await store.setActionState(row.id, .missing)
            return .missing
        }
        if !confirmedEdited, Self.editedElsewhere(item, row) { return .editedElsewhere }
        do {
            try await writer.remove(kind, itemID: item.itemID)
        } catch {
            return .failed
        }
        try? await store.setActionState(row.id, .removed)
        return .removed
    }

    /// What the confirmation of "Remove from Reminders…" says: the item's title as it is now, its list, and whether the person changed it
    /// there after Vauta added it. nil when the row cannot be removed (not created by Vauta, or gone).
    public func removalPreview(actionID: Int64) async -> RemovalPreview? {
        guard let row = try? await store.action(actionID), row.state == .created, let itemID = row.itemID, row.target != .ics else { return nil }
        let kind: ActionKind = row.target == .reminder ? .reminder : .event
        guard await writer.access(kind) == .full,
              let item = await writer.item(kind, itemID: itemID, externalID: row.externalID, containerID: row.containerID) else { return nil }
        let edited = Self.editedElsewhere(item, row)
        return RemovalPreview(actionID: actionID, kind: kind, title: item.title, containerID: item.containerID, edited: edited)
    }

    /// Changed there after Vauta saved it. The tolerance runs from the save, which is the item's creation date (the same clock as its
    /// modification date), not from the intent: on a busy Mac the save can end seconds after it, and the item looked edited. A creation
    /// date more than `adoptionWindow` after the intent is not that save (the item is not Vauta's own), and then it runs from the intent.
    static func editedElsewhere(_ item: ActionItem, _ row: CreatedAction) -> Bool {
        guard let modified = item.lastModified else { return false }
        var saved = row.writtenAt
        if let created = item.creationDate, created > saved, created <= saved.addingTimeInterval(adoptionWindow) { saved = created }
        return modified > saved.addingTimeInterval(editTolerance)
    }

    /// Undo of a batch: each row separately, in reverse order. Rows the person edited are reported, not removed.
    public func undo(actionIDs: [Int64]) async -> [Int64: RemoveOutcome] {
        var out: [Int64: RemoveOutcome] = [:]
        for id in actionIDs.reversed() { out[id] = await remove(actionID: id) }
        return out
    }

    /// "Forget" (a missing row, or an `.ics` hand-off) and "Unlink": the row stops counting; nothing is removed anywhere.
    public func forget(actionID: Int64) async { try? await store.forgetAction(actionID) }

    // MARK: Read back

    /// Reads the ledger's own items back when a surface that shows them opens (the Tasks tab, the Follow-up sheet, Tasks mode). Only
    /// the ledger's identifiers and containers are looked up. Needs full access; without it nothing is read. Returns the status of
    /// each task that has a live reminder. Follows an item that a sync re-identified, marks the ones that are gone `missing`, and
    /// never changes a task or a reminder.
    public func readBack(tasks: [TaskItem]) async -> [Int64: ActionStatus] {
        guard await writer.access(.reminder) == .full else { return [:] }
        var out: [Int64: ActionStatus] = [:]
        for task in tasks {
            guard let row = try? await store.latestAction(target: .reminder, source: .task, sourceID: task.id) else { continue }
            guard row.state == .created || row.state == .linked || row.state == .missing else { continue }
            // By identifier, then by the ledger's own external identifier in its list, then in any list (the reminder may have been moved).
            var found = await writer.item(.reminder, itemID: row.itemID, externalID: row.externalID, containerID: row.containerID)
            if found == nil, row.externalID != nil { found = await writer.item(.reminder, itemID: nil, externalID: row.externalID, containerID: nil) }
            guard let item = found else {
                if row.state != .missing { try? await store.setActionState(row.id, .missing) }
                out[task.id] = .missing
                continue
            }
            if row.state == .missing {
                // It is back (a sync finished, or it was only moved): created by Vauta if it was made after the intent, else the person's own.
                let mine = (item.creationDate ?? .distantPast) >= row.writtenAt.addingTimeInterval(-1)
                try? await store.setActionState(row.id, mine ? .created : .linked)
            }
            if item.itemID != row.itemID || (item.externalID != nil && item.externalID != row.externalID) {
                try? await store.updateActionIdentifiers(row.id, itemID: item.itemID, externalID: item.externalID ?? row.externalID)
            }
            if item.isCompleted, task.status == .open {
                out[task.id] = .doneInReminders
            } else if row.state == .created, let basis = row.dueBasis, basis.task == task.dueDay, basis.written == item.day {
                // Neither the task's day nor the reminder's has changed since Vauta wrote it: what the person chose in the editor is not a mismatch.
                out[task.id] = .inReminders
            } else if let taskDay = task.dueDay, let reminderDay = item.day, taskDay != reminderDay {
                out[task.id] = .dueDiffers(reminder: reminderDay, task: taskDay)
            } else if task.dueDay != nil, item.day == nil, row.state == .linked {
                out[task.id] = .dueDiffers(reminder: nil, task: task.dueDay)
            } else {
                out[task.id] = .inReminders
            }
        }
        return out
    }

    /// Reads back the events Vauta added for these follow-ups when the Follow-up sheet opens. One that is gone from Calendar (the person
    /// deleted it) is marked `missing`, so the follow-up is a suggestion again. Needs full Calendar access; only the ledger's own
    /// identifiers are looked up, and nothing is changed in Calendar.
    public func readBackEvents(followUpIDs: [Int64]) async {
        guard await writer.access(.event) == .full else { return }
        for id in followUpIDs {
            guard let row = try? await store.latestAction(target: .event, source: .followUp, sourceID: id), row.state == .created else { continue }
            var found = await writer.item(.event, itemID: row.itemID, externalID: row.externalID, containerID: row.containerID)
            if found == nil, row.externalID != nil { found = await writer.item(.event, itemID: nil, externalID: row.externalID, containerID: nil) }
            guard let item = found else {
                try? await store.setActionState(row.id, .missing)
                continue
            }
            if item.itemID != row.itemID || (item.externalID != nil && item.externalID != row.externalID) {
                try? await store.updateActionIdentifiers(row.id, itemID: item.itemID, externalID: item.externalID ?? row.externalID)
            }
        }
    }

    /// "Mark Done Here": the only place a task changes because of Reminders, and only when the person presses the button.
    public func markDoneHere(taskID: Int64) async {
        try? await store.setTaskStatus(taskID, .done)
    }
}
