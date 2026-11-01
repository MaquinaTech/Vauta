// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit

/// During a recording: the user's shorthand notes, the floating notepad and the live pass that writes them out.
extension RecorderModel {
    /// Connects the notepad to the recording that just started.
    func prepareNotepad(meetingID id: Int64) {
        notepad.store = store
        notepad.llm = llm
        notepad.meetingID = id
        notepad.offset = { [weak self] in self?.currentOffset ?? 0 }
        notepad.addedAfter = false
        notepad.live = true
        notepad.hasTranscript = true
        notepad.modelConfigured = llmStatus.configured
        notepad.report = { [weak self] what, error in
            guard let self else { return }
            self.lastError = self.saveFailure(what, error)
        }
        notepad.noteChanged = { [weak self] id in
            self?.noteAttempts[id] = nil
            self?.notepad.exhausted.remove(id)
            self?.considerNoteExpansion()
        }
        // After the stop the notes wait for the minutes job: the final pass writes them out.
        notepad.finalPassComing = { [weak self] in
            guard let self, self.llmStatus.configured, let meeting = self.notepadSavedMeeting else { return false }
            return self.phase == .stopping || self.llmStatus.queued > 0 || self.llmStatus.activityMeeting == meeting
        }
        notepadSavedMeeting = nil
        if preferences.openNotepadOnStart {
            // With Vauta's windows hidden for presenting, it opens when they come back.
            if concealer.isOn { notepadComesBack = true } else { notepadWindow.show(model: self, takesKeyboard: false) }
        }
    }

    func resetNotepad() {
        noteExpansionTask?.cancel()
        noteExpansionTask = nil
        noteRecheck?.cancel()
        notepadClose?.cancel()
        noteAttempts = [:]
        notepad.exhausted = []
        notepadSavedMeeting = nil
        notepad.rows = []
        notepad.draft = ""
        notepad.editingID = nil
        notepad.working = []
        notepad.disclosed = []
        notepad.updated = []
        notepad.reverted = []
        notepad.clearBanners()
        notepad.live = false
        notepad.meetingID = nil
        notepad.fieldFocused = false
    }

    // MARK: Opening the notepad

    /// The "Take a Note" shortcut, from any app: opens the notepad with the keyboard in its field; pressed again, it
    /// closes it and the meeting app has the keyboard back.
    func toggleNotepadFromShortcut() {
        guard phase == .recording else { return }
        // Opened or closed on purpose while Vauta's windows are hidden: Show Vauta Windows leaves it as the person left it.
        notepadComesBack = false
        notepadWindow.toggle(model: self)
    }

    /// The panel's button.
    func openNotepad() {
        guard phase == .recording else { return }
        notepadComesBack = false
        notepadWindow.show(model: self, takesKeyboard: true)
    }

    /// The recording is over: the notepad (if it is open) says where to keep adding notes and closes by itself soon.
    /// `meetingID` is nil when no meeting exists (an empty recording, or it could not be saved): the notepad then says
    /// nothing about a saved meeting and offers nothing to open.
    func notepadRecordingEnded(meetingID: Int64?, endOffset: Double) {
        notepad.live = false
        notepad.working = []
        guard let meetingID, notepadWindow.isVisible else {
            notepad.meetingID = nil
            if !notepadWindow.isVisible { notepad.rows = [] }
            notepadSavedMeeting = nil
            return
        }
        // The pad stays usable: what is typed now goes to the saved meeting, after everything said (the manual pass
        // writes it out), exactly as in the Notes tab of Meetings.
        notepad.meetingID = meetingID
        notepad.addedAfter = true
        let lastNote = notepad.rows.map(\.note.t).max() ?? 0
        notepad.offset = { max(endOffset, lastNote) }
        notepadSavedMeeting = meetingID
        notepadClose?.cancel()
        notepadClose = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, !self.notepadWindow.hasInteraction else { return }
            self.notepadWindow.hide()
        }
    }

    func notepadWindowClosed() {
        notepadClose?.cancel()
        guard phase != .recording, phase != .stopping else { return }
        // Closing the pad after the meeting saves what was being typed in it.
        notepadSavedMeeting = nil
        Task {
            await notepad.flushPending()
            guard notepadSavedMeeting == nil, phase == .idle else { return }
            notepad.rows = []
            notepad.meetingID = nil
        }
    }

    /// "Open in Meetings" from the notepad's footer.
    func openNotesInMeetings() {
        guard let id = notepadSavedMeeting else { return }
        notepadWindow.hide()
        Task {
            guard await authorizeHistory() else { return }
            history?.open(meeting: id, at: nil, tab: .notes)
            showWindow("meetings")
        }
    }

    // MARK: Live pass

    /// What the policy needs about the transcript so far.
    private var noteTranscript: [(start: Double, characters: Int)] {
        segments.map { ($0.segment.start, $0.segment.text.count) }
    }

    /// The notes the live pass may still expand: no expansion yet, a failed try waiting for the next one, or words
    /// changed since. A note the model found nothing for, one it failed for good and one removed are left to the final pass.
    private var notePending: [NoteExpansionPolicy.Pending] {
        notepad.rows.compactMap { row in
            // A note whose update the user took back is left to the final pass: the live pass would write it again.
            if notepad.reverted.contains(row.id) { return nil }
            if let e = row.expansion {
                guard e.state == .pending || (row.isStale && !e.userEdited && e.state != .dismissed) else { return nil }
            }
            return .init(noteID: row.id, t: row.note.t, attempts: noteAttempts[row.id] ?? 0)
        }
    }

    /// The live notes wait while a note of the user is ready: what the user typed comes first.
    var liveNotesWaitForNotes: Bool {
        NoteExpansionPolicy.liveNotesShouldWait(pending: notePending, transcript: noteTranscript, now: currentOffset)
    }

    /// Called when a note is saved, when a segment arrives and every few seconds while a note waits.
    func considerNoteExpansion() {
        guard phase == .recording, noteExpansionTask == nil, let llm, let id = meetingID, llmStatus.configured else { return }
        let pending = notePending
        // A note that used its tries waits for the final pass: with none left that can become ready, nothing polls.
        guard pending.contains(where: { $0.attempts < NoteExpansionPolicy.maxLiveAttempts }) else { return }
        guard let next = NoteExpansionPolicy.next(pending: pending, transcript: noteTranscript, now: currentOffset, inFlight: false) else {
            scheduleNoteRecheck()
            return
        }
        let previousWrites = writes
        let token = UUID()
        noteExpansionToken = token
        noteExpansionTask = Task { [weak self] in
            await previousWrites?.value   // the citations are the segments' row IDs
            guard let self, !Task.isCancelled else { return }
            self.notepad.working.insert(next.noteID)
            do {
                let state = try await llm.expandNoteLive(meetingID: id, noteID: next.noteID)
                self.noteAttempts[next.noteID] = nil
                if state == .done, let text = self.notepad.rows.first(where: { $0.id == next.noteID })?.note.text {
                    self.notepad.announceExpanded(text)
                }
            } catch is CancellationError {
                // Stopped or superseded: the note is tried again by the next pass.
            } catch {
                self.noteAttempts[next.noteID, default: 0] += 1
                if self.noteAttempts[next.noteID, default: 0] >= NoteExpansionPolicy.maxLiveAttempts { self.notepad.exhausted.insert(next.noteID) }
            }
            self.notepad.working.remove(next.noteID)
            await self.notepad.reload()
            // A pass that was stopped (or replaced by a new recording) must not clear its successor.
            guard self.noteExpansionToken == token else { return }
            self.noteExpansionTask = nil
            self.noteExpansionToken = nil
            self.considerNoteExpansion()
        }
    }

    private func scheduleNoteRecheck() {
        guard noteRecheck == nil || noteRecheck?.isCancelled == true else { return }
        noteRecheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.noteRecheck = nil
            self.considerNoteExpansion()
        }
    }
}
