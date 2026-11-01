// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// A destructive action waiting for the user's confirmation.
enum PendingDeletion: Identifiable {
    case meeting(MeetingStore.Meeting, segments: Int, decisions: Int, tasks: Int, kept: (reminders: Int, events: Int) = (0, 0))
    case decision(Decision)
    case task(id: Int64, text: String)
    case note(MeetingNote)
    case mark(MeetingMark)
    case question(index: Int, text: String)
    /// The saved voices of a person (“Voice saved on this Mac · Delete”).
    case voice(entity: Int64, name: String, isSelf: Bool)
    /// A line of the transcript, taken out of the record (`MeetingStore.deleteSegment`).
    case line(MeetingStore.StoredSegment)
    /// Several meetings chosen in the list; `keepsCreated`: Vauta created reminders or events from some of them.
    case meetings([MeetingStore.Meeting], keepsCreated: Bool)

    var id: String {
        switch self {
        case .meeting(let m, _, _, _, _): "meeting-\(m.id)"
        case .decision(let d): "decision-\(d.id)"
        case .task(let id, _): "task-\(id)"
        case .note(let n): "note-\(n.id)"
        case .mark(let m): "mark-\(m.id)"
        case .question(let index, _): "question-\(index)"
        case .voice(let entity, _, _): "voice-\(entity)"
        case .line(let s): "line-\(s.id)"
        case .meetings(let list, _): "meetings-" + list.map { String($0.id) }.joined(separator: ",")
        }
    }

    static var ownVoiceTitle: String { String(localized: "Delete your saved voice?", comment: "Confirmation title when deleting the user’s own saved voice") }

    /// The message of deleting a saved voice: the user's own one changes what imports do; a person's one stops recognition.
    static func voiceMessage(isSelf: Bool) -> String {
        isSelf
            ? String(localized: "Your voice fingerprints are removed from the encrypted store, with the voice summaries kept in meetings. Imported recordings will no longer suggest which speaker is you. Meetings and the names already in them stay as they are.",
                     comment: "Confirmation message when deleting the user’s own saved voice")
            : String(localized: "The voice of this person is removed from the encrypted store, with the voice summaries kept in meetings, and Vauta will no longer suggest them. Meetings and the names already in them stay as they are.",
                     comment: "Confirmation message when deleting one person’s saved voice, from Settings or from the person’s card")
    }

    /// What deleting a meeting removes, and what it leaves in Reminders and Calendar: reminders and events Vauta created from it stay there.
    static func meetingMessage(segments: Int, decisions: Int, tasks: Int, kept: (reminders: Int, events: Int)) -> String {
        var text = String(localized: "The transcript (\(segments) passages), \(decisions) decisions, \(tasks) tasks and all notes and marks of this meeting are removed from the encrypted store. You can’t undo this.",
                          comment: "Confirmation message when deleting a meeting; the arguments are counts")
        if kept.reminders > 0 {
            text += "\n\n" + String(localized: "\(kept.reminders) reminders created from this meeting stay in Reminders.", comment: "Confirmation message when deleting a meeting that has reminders Vauta created; the argument is how many; deleting the meeting does not remove them")
        }
        if kept.events > 0 {
            text += (kept.reminders > 0 ? "\n" : "\n\n") + String(localized: "\(kept.events) events created from this meeting stay in Calendar.", comment: "Confirmation message when deleting a meeting that has events Vauta created; the argument is how many; deleting the meeting does not remove them")
        }
        return text
    }

    var title: String {
        switch self {
        case .meeting(let m, _, _, _, _):
            String(localized: "Delete “\(m.displayTitle)”?", comment: "Confirmation title; the argument is the meeting title")
        case .decision: String(localized: "Delete this decision?", comment: "Confirmation title")
        case .task: String(localized: "Delete this task?", comment: "Confirmation title")
        case .note: String(localized: "Delete this note?", comment: "Confirmation title")
        case .mark: String(localized: "Delete this mark?", comment: "Confirmation title")
        case .question: String(localized: "Delete this open question?", comment: "Confirmation title")
        case .voice(_, let name, let isSelf):
            isSelf ? Self.ownVoiceTitle : String(localized: "Delete the saved voice of \(name)?", comment: "Confirmation title; the argument is a person's name")
        case .line: String(localized: "Delete this line for good?", comment: "Confirmation title when deleting a line of a meeting’s transcript")
        case .meetings(let list, _):
            String(localized: "Delete \(list.count) meetings?", comment: "Confirmation title when deleting several meetings chosen in the list; the argument is how many (2 or more)")
        }
    }

    var message: String {
        switch self {
        case .meeting(_, let segments, let decisions, let tasks, let kept):
            Self.meetingMessage(segments: segments, decisions: decisions, tasks: tasks, kept: kept)
        case .decision(let d): d.text
        case .task(_, let text): text
        case .question(_, let text): text
        case .voice(_, _, let isSelf): Self.voiceMessage(isSelf: isSelf)
        case .note(let n):
            String(localized: "\(n.text)\n\nThe note and its expansion will be deleted.", comment: "Confirmation message when deleting a note; the argument is the note’s text; the second line says its expansion goes too")
        case .mark(let m):
            String(localized: "The mark at \(ElapsedTime.stamp(m.t)) is removed.", comment: "Confirmation message; the argument is a time in the meeting")
        case .line(let s):
            s.text + "\n\n" + String(localized: "Its words are erased from the transcript, search and Ask, with what was transcribed and its translation. What the minutes wrote from it is marked for you to check, and Rewrite Minutes writes them without it. You can’t undo this, and a backup made before keeps the line.",
                                      comment: "Confirmation message when deleting a transcript line, under the line’s words")
        case .meetings(_, let keepsCreated):
            String(localized: "Their transcripts, decisions, tasks, notes and marks are removed from the encrypted store. You can’t undo this.",
                   comment: "Confirmation message when deleting several meetings chosen in the list")
                + (keepsCreated ? "\n\n" + String(localized: "The reminders and events Vauta created from them stay in Reminders and Calendar.",
                                                    comment: "Confirmation message when deleting several meetings, some with reminders or events Vauta created; deleting the meetings does not remove them") : "")
        }
    }

    /// Verb and object, as in the menu item that opens the dialog (without its ellipsis).
    var confirmLabel: String {
        switch self {
        case .meeting: String(localized: "Delete Meeting", comment: "Button: confirm deleting a meeting")
        case .decision: String(localized: "Delete Decision", comment: "Button: confirm deleting a decision")
        case .task: String(localized: "Delete Task", comment: "Button: confirm deleting a task")
        case .note: String(localized: "Delete Note", comment: "Button: confirm deleting a note")
        case .mark: String(localized: "Delete Mark", comment: "Button: confirm deleting a mark")
        case .question: String(localized: "Delete Question", comment: "Button: confirm deleting an open question")
        case .voice: String(localized: "Delete Voice", comment: "Button: confirm deleting a saved voice")
        case .line: DeleteLineLabel.title
        case .meetings: String(localized: "Delete Meetings", comment: "Button: confirm deleting several meetings")
        }
    }
}

extension MeetingsModel {
    /// Asks to delete the selected meeting, with what it contains.
    func confirmDeleteSelected() {
        guard let meeting = shownMeeting, !isActive else { return }
        let counts = (segments: transcript.count, decisions: decisions.count, tasks: tasks.count)
        Task {
            // Reminders and events Vauta created stay where they are; the confirmation says how many.
            let kept = (try? await store.createdActionCounts(ofMeeting: meeting.id)) ?? (reminders: 0, events: 0)
            pendingDeletion = .meeting(meeting, segments: counts.segments, decisions: counts.decisions, tasks: counts.tasks, kept: kept)
        }
    }

    func confirmDeleteSelectedTask() {
        guard let draft = taskDraft else { return }
        pendingDeletion = .task(id: draft.taskID, text: draft.original.text)
    }

    func performDeletion(_ deletion: PendingDeletion) async {
        pendingDeletion = nil
        noteActivity()
        switch deletion {
        case .meeting(let m, _, _, _, _): await deleteMeeting(m.id)
        case .decision(let d):
            await perform(String(localized: "Couldn’t delete the decision", comment: "Alert title")) { try await store.deleteDecision(d.id) }
            await loadDetail()
        case .task(let id, _):
            await perform(String(localized: "Couldn’t delete the task", comment: "Alert title")) { try await store.deleteTask(id) }
            if taskSelection == id {
                taskDraft = nil
                taskSelection = nil
            }
            await refreshTasks()
        case .note(let n):
            // With its expansion; ⌘Z brings both back.
            await notepad.delete(n.id)
            await loadDetail()
        case .question(let index, _):
            await perform(String(localized: "Couldn’t delete the question", comment: "Alert title")) {
                guard let id = selectedID, var card = try await store.card(id), card.openQuestions?.indices.contains(index) == true else { return }
                card.openQuestions?.remove(at: index)
                try await store.saveCard(card, of: id)
            }
            await loadDetail()
        case .mark(let m):
            await perform(String(localized: "Couldn’t delete the mark", comment: "Alert title")) { try await store.deleteMark(m.id) }
            await loadDetail()
        case .voice(let entity, _, _):
            await perform(String(localized: "Couldn’t delete the saved voice", comment: "Alert title")) { _ = try await store.deleteVoiceProfiles(entityID: entity) }
            await loadEntity()
        case .line(let s): await deleteLine(s)
        case .meetings(let list, _): await deleteMeetings(list.map(\.id))
        }
    }

    /// Asks to delete a transcript line (the context menu, the VoiceOver action).
    func confirmDelete(_ segment: MeetingStore.StoredSegment) {
        guard canCorrect(segment) else { return }
        pendingDeletion = .line(segment)
    }

    /// ⌫ and Edit ▸ Delete on the highlighted line of the transcript.
    func confirmDeleteHighlight() {
        guard canCorrectHighlight, let segment = highlightedSegment else { return }
        confirmDelete(segment)
    }

    /// Deletes a transcript line for good. The undo steps recorded before are dropped: a correction or a speaker change of the
    /// meeting may need the line, and nothing brings it back.
    private func deleteLine(_ segment: MeetingStore.StoredSegment) async {
        if lineDraft?.segmentID == segment.id { lineDraft = nil }
        if everywhereOffer?.segmentID == segment.id { everywhereOffer = nil }
        var deletion: MeetingStore.LineDeletion?
        do {
            deletion = try await store.deleteSegment(segment.id)
        } catch {
            // A failure to compact or write comes after the line is gone: the meeting is read again either way.
            present(String(localized: "Couldn’t delete the line", comment: "Alert title: deleting a transcript line failed"), error)
        }
        undoManager?.removeAllActions(withTarget: self)
        if highlighted == segment.id { highlighted = nil }
        if let llm { Task { await llm.lineDeleted(meetingID: segment.meetingID) } }
        // A follow-up meeting the line set the day of goes with it; another line may still name one.
        _ = try? await store.redetectFollowUps(segment.meetingID)
        if selectedID == segment.meetingID {
            await refreshDetail()
            if !hits.isEmpty { await runSearch() }
        }
        guard let deletion else { return }
        show(MeetingsNotice(text: deletion.marked == 0
            ? String(localized: "Line deleted", comment: "Confirmation after deleting a transcript line")
            : String(localized: "Line deleted. What the minutes wrote from it is marked for you to check.",
                     comment: "Confirmation after deleting a transcript line that decisions, tasks or note expansions were written from")))
    }

    private func deleteMeeting(_ id: Int64) async {
        do {
            draft = nil   // nothing to autosave into a deleted meeting
            try await store.deleteMeeting(id)
            await llm?.forgetKeptTranscripts(meetingID: id)
            if selectedID == id { selectedID = nil }
        } catch let e as StoreError where e.kind == .meetingInProgress {
            alert = MeetingsAlert(title: String(localized: "This meeting is being recorded", comment: "Alert title"),
                                  message: String(localized: "Stop the recording before deleting this meeting.", comment: "Alert message"))
        } catch {
            present(String(localized: "Couldn’t delete the meeting", comment: "Alert title"), error)
        }
        await reload()
    }

    /// Erases the whole history (crypto-shred: new file and new key). Returns
    /// what to tell the user: nil when everything worked, otherwise an alert
    /// (`erased` says whether the history is gone despite the problem).
    /// Settings → Privacy & Security calls it too, after Touch ID.
    @discardableResult
    func eraseAll() async -> (alert: MeetingsAlert?, erased: Bool) {
        var result: (alert: MeetingsAlert?, erased: Bool) = (nil, false)
        let showing = isShowing
        // Pending edits would be written into the new, empty store; if the
        // erase is refused they are put back (nothing typed is lost).
        let pending = (draft, taskDraft)
        do {
            draft = nil
            taskDraft = nil
            try await store.eraseEverything()
            await llm?.forgetKeptTranscripts()
            erasedTranslations()
            purgeVisible()
            onErased?()
            result.erased = true
        } catch let e as StoreError where e.kind == .meetingInProgress {
            (draft, taskDraft) = pending
            result.alert = MeetingsAlert(title: String(localized: "A meeting is being recorded", comment: "Alert title"),
                                         message: String(localized: "Stop the recording before erasing all meetings.", comment: "Alert message"))
        } catch let e as StoreError where e.kind == .newKeyPending {
            // The history is gone, but without a new key nothing is recorded or saved.
            await llm?.forgetKeptTranscripts()
            erasedTranslations()
            purgeVisible()
            onErased?()
            result.erased = true
            result.alert = MeetingsAlert(title: String(localized: "All meetings were erased", comment: "Alert title"),
                                         message: String(localized: "But the new encryption key couldn’t be created in the Keychain, so Vauta can’t record until it has one. Unlock the Keychain and restart Vauta.",
                                                         comment: "Alert message after erasing when the Keychain refused the new key"))
        } catch {
            result.alert = MeetingsAlert(String(localized: "Couldn’t erase all meetings", comment: "Alert title"), error: error)
        }
        // Purging marks the window as closed; it stays open if it was.
        isShowing = showing
        if showing { await reload() }
        return result
    }
}
