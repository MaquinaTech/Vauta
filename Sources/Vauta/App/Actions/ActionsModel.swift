// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import Foundation
import Observation
import SwiftUI
import VautaCore

/// Reminders, Calendar events and the follow-up email, as the Meetings window shows them. It holds the
/// drafts of the editors, so they survive the macOS permission prompt, the Follow-up sheet and the editors share one sheet, and every
/// write goes through `ActionService`: confirm per item, never twice, undo only what Vauta created. Nothing here talks to EventKit
/// directly; the one writer is `EventKitActionWriter` (and `FakeActionWriter` in the renderings).
@MainActor
@Observable
final class ActionsModel {
    /// What the one sheet shows: the Follow-up sheet, or an editor in its place (it returns to the Follow-up sheet when it came from it).
    enum Page: Equatable { case followUp, reminder, event }

    /// The 10-second bar after an Add: what was added, where, and how to take it back.
    struct UndoBar: Equatable, Identifiable {
        let id = UUID()
        var text: String
        var actionIDs: [Int64]
        var kind: ActionKind
        /// The item to open (the single one added), nil for a batch.
        var itemID: String?
    }

    /// "Remove from Reminders…" waiting for its confirmation.
    struct PendingRemoval: Equatable, Identifiable {
        var id: Int64 { preview.actionID }
        var preview: RemovalPreview
        var listName: String
    }

    // MARK: Collaborators

    @ObservationIgnored weak var host: MeetingsModel?
    @ObservationIgnored let store: MeetingStore
    @ObservationIgnored var preferences = ActionsPreferences()
    @ObservationIgnored private var writerStorage: (any ActionWriter)?
    @ObservationIgnored private var serviceStorage: ActionService?
    /// Builds the writer on first use. No prompt is raised and no item is read until the person acts; opening a Tasks surface only checks
    /// the authorization status. A rendering installs a fake before.
    @ObservationIgnored var makeWriter: () -> any ActionWriter = {
        #if VAUTA_DIAGNOSTICS
        FakeActionWriter()
        #else
        EventKitActionWriter()
        #endif
    }
    @ObservationIgnored var undoManager: UndoManager?
    @ObservationIgnored var undoBarTask: Task<Void, Never>?
    /// Replaced by a test; otherwise the Apple apps open on the item (the brief's links: they only show it).
    @ObservationIgnored var openInReminders: ((String?) -> Void)?
    @ObservationIgnored var openInCalendar: ((String?) -> Void)?
    /// Where the `.ics` files are written (the app's caches); a test passes its own folder.
    @ObservationIgnored var caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    /// Opens a hand-off file with Calendar.
    @ObservationIgnored var openFile: (URL) -> Void = { file in
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { NSWorkspace.shared.open(file); return }
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
    /// Numbers the refreshes of the ledger (`refresh`), the newest serial that wrote each task, and the generation that `forgetEverything` ends.
    @ObservationIgnored private var refreshCounter = 0
    @ObservationIgnored private var appliedSerial: [Int64: Int] = [:]
    @ObservationIgnored private var refreshEpoch = 0
    /// A test runs something between a refresh's read of the ledger and its write.
    @ObservationIgnored var refreshProbe: (() async -> Void)?
    /// Brings Vauta to the front before the macOS permission prompt (a test does nothing).
    @ObservationIgnored var bringToFront: () -> Void = {
        #if !VAUTA_DIAGNOSTICS
        NSApp.activate()
        #endif
    }
    /// The model that writes the minutes, for the summary gate of the email ("integrated", "onDevice", "server", or "none").
    /// Which held parts are on (`ActionsRelease`); only a test or a scene of the held part turns one on.
    @ObservationIgnored var emailDraftAvailable = ActionsRelease.emailDraft
    @ObservationIgnored var followUpDetectionAvailable = ActionsRelease.followUpDetection
    @ObservationIgnored var backend: () -> String = { "none" }
    /// The Follow-up sheet of a meeting was opened (by any route): the panel's card for it is no longer pending.
    @ObservationIgnored var onFollowUpOpened: ((Int64) -> Void)?

    init(store: MeetingStore) { self.store = store }

    var writer: any ActionWriter {
        if let writerStorage { return writerStorage }
        let made = makeWriter()
        writerStorage = made
        return made
    }

    var service: ActionService {
        if let serviceStorage { return serviceStorage }
        let made = ActionService(store: store, writer: writer)
        serviceStorage = made
        return made
    }

    /// For tests and renderings: all writes go to `writer`.
    func use(writer: any ActionWriter) {
        writerStorage = writer
        serviceStorage = ActionService(store: store, writer: writer)
    }

    // MARK: Observable state

    /// What the sheet shows (nil: no sheet).
    var page: Page?
    /// The editor was opened from the Follow-up sheet and goes back to it.
    var returnsToFollowUp = false
    var reminderEditor: ReminderEditorState?
    var eventEditor: EventEditorState?
    var sheet: FollowUpSheetState?
    var undoBar: UndoBar?
    var pendingRemoval: PendingRemoval?

    /// The row state of the tasks the window has shown, by task id.
    var states: [Int64: TaskActionState] = [:]
    /// "Work · iCloud" by list or calendar identifier, once access lets Vauta read them.
    var containerNames: [String: String] = [:]
    var reminderAccess: ActionAccess = .notDetermined
    var eventAccess: ActionAccess = .notDetermined

    // MARK: Presentation helpers

    func state(of task: TaskItem) -> TaskActionState { states[task.id] ?? .none }

    /// "Work · iCloud" for a list or calendar, or nil when it cannot be read (no access or gone).
    func containerLabel(_ id: String?) -> String? { id.flatMap { containerNames[$0] } }

    static func label(_ container: ActionContainer) -> String {
        container.account.isEmpty ? container.title : "\(container.title) · \(container.account)"
    }

    var copyProtected: Bool { host?.copyProtected ?? true }

    // MARK: Meeting facts

    struct MeetingFacts: Equatable {
        var id: Int64
        var title: String
        var start: Date
        var end: Date?
        var zone: TimeZone
        var minutesLocale: Locale
        var duration: TimeInterval? { end.map { $0.timeIntervalSince(start) } }
    }

    func facts(meetingID: Int64?) async -> MeetingFacts? {
        guard let meetingID, let meeting = try? await store.meeting(meetingID) else { return nil }
        let zone = (try? await store.meetingTimeZone(meetingID)) ?? .current
        return MeetingFacts(id: meetingID, title: meeting.displayTitle, start: meeting.startedAt, end: meeting.endedAt, zone: zone, minutesLocale: meeting.minutesLocale)
    }

    func selfEntityID() async -> Int64? { try? await store.selfEntityID() }

    // MARK: Reading the ledger

    /// Reads the ledger rows of `tasks` (and, with `readBack`, what Reminders says about them: done there, gone, another due day). Read-back
    /// happens only when a surface that shows the status opens, only with full access, and only for the ledger's own identifiers.
    func refresh(tasks: [TaskItem], readBack: Bool = false) async {
        // Each refresh is numbered when it starts. A task's row is written only by the newest refresh that reached it: an older read
        // that finishes late (it read the ledger before an Add committed) can neither erase nor replace what a newer one wrote.
        refreshCounter += 1
        let serial = refreshCounter, epoch = refreshEpoch
        // A `writing` row left by a crash is settled first (adopted or dropped), so it never shows as nothing or blocks the editor.
        await service.reconcileWriting()
        // A task the person confirmed as the same as an earlier one shares that task's reminder: a task with no row of its own shows the row
        // of the member of its chain that has one (read back through that member).
        var source: [Int64: TaskItem] = [:]
        var rows: [Int64: CreatedAction] = [:]
        for task in tasks {
            if let row = try? await store.latestAction(target: .reminder, source: .task, sourceID: task.id) { rows[task.id] = row; source[task.id] = task }
            else if let (sibling, row) = await chainRow(of: task) { rows[task.id] = row; source[task.id] = sibling }
        }
        var back: [Int64: ActionStatus] = [:]
        let tracked = tasks.filter { rows[$0.id] != nil }
        if readBack, !tracked.isEmpty {
            let owners = Dictionary(source.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let read = await service.readBack(tasks: Array(owners.values))
            for task in tracked { if let id = source[task.id]?.id { back[task.id] = read[id] } }
            // A task that shows another member's reminder compares that reminder's day with its own: a different due day is a mismatch
            // ("In Reminders, due 10 Oct (here: 24 Oct)"); Vauta never changes the reminder.
            for task in tracked {
                guard let sibling = source[task.id], sibling.id != task.id, let status = back[task.id] else { continue }
                let reminderDay: DueDay?
                switch status {
                case .dueDiffers(let day, _): reminderDay = day
                case .inReminders: reminderDay = sibling.displayDay()
                default: continue
                }
                back[task.id] = reminderDay == task.displayDay() ? .inReminders : .dueDiffers(reminder: reminderDay, task: task.displayDay())
            }
        }
        // The ledger is read again after the awaits: an Add that finished meanwhile must not be erased by this older read.
        var fresh: [Int64: CreatedAction] = [:]
        var borrowed = Set<Int64>()
        for task in tasks {
            if let row = try? await store.latestAction(target: .reminder, source: .task, sourceID: task.id) { fresh[task.id] = row }
            else if let (_, row) = await chainRow(of: task) { fresh[task.id] = row; borrowed.insert(task.id) }
        }
        await refreshProbe?()
        guard epoch == refreshEpoch else { return }
        var next = states
        for task in tasks {
            guard (appliedSerial[task.id] ?? 0) <= serial else { continue }
            appliedSerial[task.id] = serial
            next[task.id] = nil
            guard let row = fresh[task.id] else { continue }
            let state = TaskActionState.make(row: row, readBack: back[task.id], borrowed: borrowed.contains(task.id))
            if state.kind != .none { next[task.id] = state }
        }
        states = next
        await refreshAccess(names: !rows.isEmpty)
    }

    /// The ledger row of another member of the task's chain (confirmed "same" links) and that member, when one has a reminder.
    private func chainRow(of task: TaskItem) async -> (TaskItem, CreatedAction)? {
        guard let others = try? await store.chainMembers(ofTask: task.id), !others.isEmpty else { return nil }
        for id in others {
            if let row = try? await store.latestAction(target: .reminder, source: .task, sourceID: id), row.state == .created || row.state == .linked,
               let sibling = (try? await store.tasks(ids: [id]))?.first { return (sibling, row) }
        }
        return nil
    }

    func refreshAccess(names: Bool = false) async {
        reminderAccess = await writer.access(.reminder)
        eventAccess = await writer.access(.event)
        guard names else { return }
        var out: [String: String] = [:]
        for kind in [ActionKind.reminder, .event] where (kind == .reminder ? reminderAccess : eventAccess) == .full {
            for container in await writer.containers(kind) { out[container.id] = Self.label(container) }
        }
        containerNames = out
    }

    // MARK: Closing

    func closeSheet() {
        page = nil
        returnsToFollowUp = false
        sheet = nil
    }

    /// Cancel in an editor: the draft is dropped; back to the Follow-up sheet if that is where it came from.
    func cancelEditor() {
        reminderEditor = nil
        eventEditor = nil
        if returnsToFollowUp, sheet != nil { page = .followUp } else { page = nil }
        returnsToFollowUp = false
    }

    /// An editor finished (added or linked).
    func finishEditor() {
        reminderEditor = nil
        eventEditor = nil
        if returnsToFollowUp, sheet != nil { page = .followUp } else { page = nil; sheet = nil }
        returnsToFollowUp = false
    }

    /// The window locked or closed: nothing typed or read stays in memory.
    func forgetEverything() {
        undoBarTask?.cancel()
        page = nil
        returnsToFollowUp = false
        reminderEditor = nil
        eventEditor = nil
        sheet = nil
        undoBar = nil
        pendingRemoval = nil
        states = [:]
        containerNames = [:]
        appliedSerial = [:]
        refreshEpoch += 1
    }

    // MARK: Undo bar

    func showUndoBar(text: String, rows: [CreatedAction], kind: ActionKind) {
        guard !rows.isEmpty else { return }
        let bar = UndoBar(text: text, actionIDs: rows.map(\.id), kind: kind, itemID: rows.count == 1 ? rows[0].itemID : nil)
        undoBar = bar
        AccessibilityNotification.Announcement(String(localized: "\(text). Undo available.", comment: "VoiceOver, after something was added to Reminders or Calendar; the argument is what was added and where")).post()
        let name = kind == .reminder ? String(localized: "Add to Reminders", comment: "Edit menu: the name of the action that Undo takes back")
                                     : String(localized: "Add to Calendar", comment: "Edit menu: the name of the action that Undo takes back")
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { _ = Task { await target.undo(bar) } }
        }
        undoManager?.setActionName(name)
        undoBarTask?.cancel()
        // With VoiceOver on the bar stays: a time-out would take it from someone who is still reading it.
        guard !NSWorkspace.shared.isVoiceOverEnabled else { return }
        undoBarTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, self?.undoBar?.id == bar.id else { return }
            self?.undoBar = nil
        }
    }

    func dismissUndoBar() {
        undoBarTask?.cancel()
        undoBar = nil
    }

    /// Undo (the bar's button and Edit ▸ Undo): removes only what Vauta just created. An item the person changed in the meantime is kept.
    func undo(_ bar: UndoBar) async {
        if undoBar?.id == bar.id { dismissUndoBar() }
        let outcomes = await service.undo(actionIDs: bar.actionIDs)
        let gone = Set(outcomes.filter { $0.value == .removed || $0.value == .missing }.keys)
        states = states.filter { !($0.value.rowID.map(gone.contains) ?? false) }
        let kept = outcomes.values.filter { $0 == .editedElsewhere }.count
        await afterChange()
        if kept > 0 {
            host?.show(MeetingsNotice(text: bar.kind == .reminder
                                      ? String(localized: "Kept in Reminders: you changed it there.", comment: "Notice after Undo when the reminder was edited in Reminders")
                                      : String(localized: "Kept in Calendar: you changed it there.", comment: "Notice after Undo when the event was edited in Calendar"),
                                      symbol: "info.circle"))
        }
    }

    /// What every change leaves to do: the task rows, the sheet and the window's lists read the ledger again.
    func afterChange(including extra: [TaskItem] = []) async {
        let tasks = (host?.tasks ?? []) + (host?.openTasks ?? [])
        await host?.refreshTasks()
        await refresh(tasks: tasks + (sheet?.tasks ?? []) + extra, readBack: true)
        await reloadSheet()
    }

    // MARK: Row actions

    /// "Open in Reminders": shows the item; when its identifier is unknown the app opens instead.
    func openReminders(_ itemID: String?) {
        if let openInReminders { openInReminders(itemID) } else { host?.brief?.openReminders(id: itemID) }
    }

    func openCalendar(_ itemID: String?) {
        if let openInCalendar { openInCalendar(itemID) } else { host?.brief?.openCalendar(eventIdentifier: itemID) }
    }

    /// "Mark Done Here": the one place a task changes because of Reminders, and only by this button.
    func markDoneHere(_ task: TaskItem) async {
        await service.markDoneHere(taskID: task.id)
        await afterChange()
    }

    /// "Forget" (a reminder that is gone) and "Unlink" (a reminder the person already had): the row stops counting. Nothing is removed.
    func forget(_ state: TaskActionState) async {
        guard let id = state.rowID else { return }
        await service.forget(actionID: id)
        states = states.filter { $0.value.rowID != id }
        await afterChange()
    }

    /// "Remove from Reminders…": asks first, naming the item and its list, and says so when the person changed it there.
    func requestRemoval(rowID: Int64) async {
        guard let preview = await service.removalPreview(actionID: rowID) else {
            await afterChange()
            return
        }
        // The names are read only when rows made them necessary; an event-only meeting has none yet.
        if containerLabel(preview.containerID) == nil { await refreshAccess(names: true) }
        pendingRemoval = PendingRemoval(preview: preview, listName: containerLabel(preview.containerID) ?? "")
    }

    func confirmRemoval() async {
        guard let pending = pendingRemoval else { return }
        pendingRemoval = nil
        let outcome = await service.remove(actionID: pending.preview.actionID, confirmedEdited: pending.preview.edited)
        if outcome == .removed || outcome == .missing { states = states.filter { $0.value.rowID != pending.preview.actionID } }
        if outcome == .failed {
            host?.show(MeetingsNotice(text: String(localized: "Vauta couldn’t remove it. Nothing was changed.", comment: "Notice when removing a reminder or event Vauta added failed"), symbol: "exclamationmark.triangle"))
        }
        await afterChange()
    }
}

extension ActionsModel {
    /// "Open" on the bar after an Add.
    func openAddedItem(_ bar: UndoBar) {
        switch bar.kind {
        case .reminder: openReminders(bar.itemID)
        case .event: openCalendar(bar.itemID)
        }
    }
}
