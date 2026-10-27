// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import Foundation
import VautaCore

/// The reminder editor and the batch of the Follow-up sheet. Nothing is written until the person presses Add; each write goes through
/// `ActionService`, which checks the ledger and the target list first and takes the draft back to the person when something is there.
extension ActionsModel {
    // MARK: Choosing the list

    /// The list a reminder starts in: the one chosen in Settings, else the last one used, else the system's default list. A list chosen
    /// in Settings that is gone is named, so the editor can say so (Vauta never creates a list).
    func chooseList(among containers: [ActionContainer]) async -> (id: String?, unavailable: String?) {
        let ids = containers.map(\.id)
        var unavailable: String?
        if let chosen = preferences.reminderListID {
            if ids.contains(chosen) { return (chosen, nil) }
            unavailable = preferences.reminderListName ?? ""
        }
        if let last = preferences.lastReminderListID, ids.contains(last) { return (last, unavailable) }
        if let system = await writer.defaultContainerID(.reminder), ids.contains(system) { return (system, unavailable) }
        return (ids.first, unavailable)
    }

    // MARK: Opening

    /// "Add to Reminders…": the editor, in a sheet of the Meetings window. A draft already open for this task is reused.
    func openReminderEditor(_ task: TaskItem, fromFollowUp: Bool = false) async {
        returnsToFollowUp = fromFollowUp && sheet != nil
        if let existing = reminderEditor, existing.task.id == task.id {
            page = .reminder
            return
        }
        let meeting = await facts(meetingID: task.meetingID)
        let selfID = await selfEntityID()
        let access = await writer.access(.reminder)
        let containers = access == .full ? await writer.containers(.reminder) : []
        let (listID, unavailable) = await chooseList(among: containers)
        let alert = preferences.alertMinute
        var state = ReminderEditorState(
            task: task,
            draft: ReminderDraft.make(task: task, selfEntityID: selfID, containerID: listID ?? "", alertMinuteOfDay: alert, meetingTitle: meeting?.title,
                                      meetingDate: meeting?.start, meetingTimeZone: meeting?.zone ?? .current, includeMeetingName: preferences.includeMeetingName),
            meeting: meeting, selfEntityID: selfID, containers: containers, access: access, unavailableList: unavailable,
            includeMeetingName: preferences.includeMeetingName, alertMinute: alert ?? ReminderDraft.defaultAlertMinute)
        // Opening for a task that has no due day: no alert to offer.
        if task.dueDay == nil { state.draft.alertMinuteOfDay = nil }
        reminderEditor = state
        page = .reminder
        await recheck()
    }

    private func rebuildNotes() {
        guard var state = reminderEditor else { return }
        let fresh = ReminderDraft.make(task: state.task, selfEntityID: state.selfEntityID, containerID: state.draft.containerID,
                                       meetingTitle: state.meeting?.title, meetingDate: state.meeting?.start,
                                       meetingTimeZone: state.meeting?.zone ?? .current, includeMeetingName: state.includeMeetingName)
        state.draft.notes = fresh.notes
        reminderEditor = state
    }

    // MARK: Editing the draft

    func setIncludeMeetingName(_ on: Bool) {
        reminderEditor?.includeMeetingName = on
        rebuildNotes()
    }

    func setReminderDue(_ day: DueDay?) {
        guard var state = reminderEditor else { return }
        state.draft.dueDay = day
        state.draft.skippedDueDay = nil
        if day == nil { state.draft.alertMinuteOfDay = nil }
        reminderEditor = state
    }

    func setReminderAlert(_ on: Bool) {
        guard var state = reminderEditor, state.draft.dueDay != nil else { return }
        state.draft.alertMinuteOfDay = on ? state.alertMinute : nil
        reminderEditor = state
    }

    func setReminderAlertMinute(_ minute: Int) {
        guard var state = reminderEditor else { return }
        state.alertMinute = minute
        if state.draft.alertMinuteOfDay != nil { state.draft.alertMinuteOfDay = minute }
        reminderEditor = state
    }

    func setReminderList(_ id: String) async {
        reminderEditor?.draft.containerID = id
        reminderEditor?.finding = .none
        reminderEditor?.failed = false
        await recheck()
    }

    /// The checks before anything is written: the ledger, an orphan of the same task, then the target list.
    func recheck() async {
        guard let state = reminderEditor, state.access == .full, state.hasList else { return }
        let finding = await service.check(task: state.task, draft: state.draft)
        guard reminderEditor?.task.id == state.task.id, reminderEditor?.draft.containerID == state.draft.containerID else { return }
        reminderEditor?.finding = finding
    }

    // MARK: Permission

    /// "Allow Access…": from a button the person pressed. The sheet and its draft stay; after a grant the lists fill in.
    func allowReminderAccess() async {
        guard reminderEditor != nil || sheet != nil else { return }
        reminderEditor?.requestingAccess = true
        bringToFront()
        _ = await writer.requestAccess(.reminder)
        await applyReminderAccess()
    }

    /// After the answer to the macOS prompt: the sheet and its draft stay; the lists fill in and the checks run.
    func applyReminderAccess() async {
        reminderAccess = await writer.access(.reminder)
        let containers = reminderAccess == .full ? await writer.containers(.reminder) : []
        let (listID, unavailable) = await chooseList(among: containers)
        if reminderEditor != nil {
            reminderEditor?.requestingAccess = false
            reminderEditor?.access = reminderAccess
            reminderEditor?.containers = containers
            reminderEditor?.unavailableList = unavailable
            if let listID { reminderEditor?.draft.containerID = listID }
            await recheck()
        }
        if sheet != nil {
            sheet?.containers = containers
            sheet?.containerID = listID
            sheet?.unavailableList = unavailable
        }
        await refreshAccess(names: reminderAccess == .full)
    }

    // MARK: Adding

    /// Add to Reminders in the editor. A duplicate comes back to the editor; nothing is written for it.
    func addReminder(acceptingDuplicate: Bool = false) async {
        guard var state = reminderEditor, !state.busy, state.access == .full, !state.draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        state.busy = true
        state.failed = false
        reminderEditor = state
        let outcome = await service.addReminder(task: state.task, draft: state.draft, acceptingDuplicate: acceptingDuplicate)
        guard reminderEditor?.task.id == state.task.id else { return }
        reminderEditor?.busy = false
        switch outcome {
        case .added(let row):
            preferences.lastReminderListID = state.draft.containerID
            let list = containerNames[state.draft.containerID] ?? state.containers.first { $0.id == state.draft.containerID }.map(Self.label) ?? ""
            finishEditor()
            await afterChange(including: [state.task])
            showUndoBar(text: String(localized: "Added to Reminders · \(list)", comment: "Bar after adding a reminder; the argument is the list and its account, such as Work · iCloud"),
                        rows: [row], kind: .reminder)
        case .duplicate(let finding):
            reminderEditor?.finding = finding
        case .accessNeeded(let access):
            reminderEditor?.access = access
        case .noContainer:
            reminderEditor?.containers = await writer.containers(.reminder)
            reminderEditor?.unavailableList = containerName(of: state.draft.containerID)
            reminderEditor?.draft.containerID = ""
        case .failed, .handOff:
            reminderEditor?.failed = true
        }
    }

    private func containerName(of id: String) -> String { containerNames[id] ?? "" }

    /// "Use This One" / "Use This Reminder": the task is linked to the reminder that is already there. Nothing is written to Reminders.
    func useExistingReminder() async {
        guard let state = reminderEditor, state.finding != .none else { return }
        guard let row = await service.useExisting(task: state.task, finding: state.finding) else { return }
        finishEditor()
        await afterChange(including: [state.task])
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { _ = Task { await target.unlink(rowID: row.id) } }
        }
        undoManager?.setActionName(String(localized: "Use This Reminder", comment: "Edit menu: the name of the action that Undo takes back"))
    }

    private func unlink(rowID: Int64) async {
        await service.forget(actionID: rowID)
        await afterChange()
    }

    // MARK: Batch (the Follow-up sheet)

    func toggleTick(_ task: TaskItem) {
        guard sheet != nil else { return }
        if sheet?.ticked.contains(task.id) == true { sheet?.ticked.remove(task.id) } else { sheet?.ticked.insert(task.id) }
        sheet?.notes[task.id] = nil
    }

    func setBatchList(_ id: String) {
        sheet?.containerID = id
        sheet?.notes = [:]
    }

    /// "Add 2 to Reminders · Work": the ticks are the per-item confirmation, so the ticked items are written one by one with no second
    /// list. An item that is already there, or that Reminders refuses, stays ticked with a note; one Undo covers what was added.
    func addTicked() async {
        guard var current = sheet, !current.busy, let listID = current.containerID, reminderAccess == .full else { return }
        let waiting = current.notes.filter { if case .duplicate = $0.value { true } else { false } }
        guard !current.addableTicked.isEmpty else { return }
        current.busy = true
        current.notes = waiting
        sheet = current
        let selfID = current.selfEntityID
        var added: [CreatedAction] = []
        for task in current.addableTicked {
            let draft = ReminderDraft.make(task: task, selfEntityID: selfID, containerID: listID, alertMinuteOfDay: preferences.alertMinute,
                                           meetingTitle: current.meeting.title, meetingDate: current.meeting.start, meetingTimeZone: current.meeting.zone,
                                           includeMeetingName: preferences.includeMeetingName)
            switch await service.addReminder(task: task, draft: draft) {
            case .added(let row):
                added.append(row)
                sheet?.ticked.remove(task.id)
            case .duplicate(let finding):
                if case .alreadyAdded = finding { sheet?.ticked.remove(task.id) } else { sheet?.notes[task.id] = .duplicate(finding) }
            default:
                sheet?.notes[task.id] = .failed
            }
        }
        sheet?.busy = false
        preferences.lastReminderListID = listID
        await afterChange()
        let list = containerNames[listID] ?? current.containers.first { $0.id == listID }.map(Self.label) ?? ""
        let text = added.count > 1
            ? String(localized: "Added \(added.count) to Reminders · \(list)", comment: "Bar after adding several reminders at once; the arguments are how many and the list with its account, such as Work · iCloud")
            : String(localized: "Added to Reminders · \(list)", comment: "Bar after adding a reminder; the argument is the list and its account, such as Work · iCloud")
        showUndoBar(text: text, rows: added, kind: .reminder)
    }

    /// "Use This One" / "Add Anyway" on a row of the Follow-up sheet whose reminder is already there.
    func resolveBatch(_ task: TaskItem, useExisting: Bool) async {
        guard case .duplicate(let finding)? = sheet?.notes[task.id], let current = sheet else { return }
        sheet?.notes[task.id] = nil
        if useExisting {
            if let row = await service.useExisting(task: task, finding: finding) { _ = row }
            sheet?.ticked.remove(task.id)
        } else if let listID = current.containerID {
            let draft = ReminderDraft.make(task: task, selfEntityID: current.selfEntityID, containerID: listID, alertMinuteOfDay: preferences.alertMinute,
                                           meetingTitle: current.meeting.title, meetingDate: current.meeting.start, meetingTimeZone: current.meeting.zone,
                                           includeMeetingName: preferences.includeMeetingName)
            if case .added(let row) = await service.addReminder(task: task, draft: draft, acceptingDuplicate: true) {
                sheet?.ticked.remove(task.id)
                let list = containerNames[listID] ?? ""
                showUndoBar(text: String(localized: "Added to Reminders · \(list)", comment: "Bar after adding a reminder; the argument is the list and its account, such as Work · iCloud"),
                            rows: [row], kind: .reminder)
            } else {
                sheet?.notes[task.id] = .failed
            }
        }
        await afterChange()
    }
}
