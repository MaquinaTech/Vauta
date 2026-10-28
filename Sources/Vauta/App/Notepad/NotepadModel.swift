// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import Observation
import SwiftUI

/// The user's shorthand notes of one meeting and what the model wrote from them, for the three places that show them:
/// the menu-bar panel and the floating notepad while recording (`RecorderModel.notepad`), and the Notes tab of the
/// Meetings window (`MeetingsModel.notepad`). It never writes the user's words except to save what the user typed; the
/// expansions are the model's and live in their own rows (see `MeetingStore+Notepad`).
@MainActor
@Observable
final class NotepadModel {
    /// What a note shows under the user's words. Every state has a glyph and a sentence, never a colour alone.
    enum Status: Equatable {
        /// The model is writing it now.
        case working
        /// Waiting for more of the meeting (or for its turn).
        case waiting
        /// The meeting is over and the note has no expansion yet.
        case notExpanded
        /// The meeting is over and its minutes job, which writes the notes out first, is queued or running.
        case queued
        /// No model is set up: the note is saved and nothing else happens.
        case noModel
        /// There is no transcript to expand from.
        case noTranscript
        case done
        /// The user rewrote the expansion.
        case edited
        /// The note changed after the expansion was written.
        case stale
        case notFound
        case notAnswering
        case unsupportedLanguage
        case failed
        /// The user removed the expansion.
        case dismissed
    }

    /// A note removed a moment ago: its row is replaced by "Note deleted · Undo" for a few seconds.
    struct Deleted: Equatable, Identifiable {
        let row: NoteRow
        var id: Int64 { row.id }
    }

    /// One note that can leave and come back (a delete, or an added note taken back), shared by the undo and redo steps
    /// and by the "Undo" of the banner, so the note is never put back twice.
    @MainActor final class Presence {
        var row: NoteRow
        var present: Bool
        init(row: NoteRow, present: Bool) { self.row = row; self.present = present }
    }

    // Where the notes live and how to reach the model (set by the owner).
    @ObservationIgnored var store: MeetingStore?
    @ObservationIgnored var llm: LLMService?
    @ObservationIgnored var meetingID: Int64?
    /// Seconds into the meeting for a note typed now (the end of the meeting once it is over).
    @ObservationIgnored var offset: () -> Double = { 0 }
    /// The notes were typed after the recording stopped.
    @ObservationIgnored var addedAfter = false
    @ObservationIgnored weak var undoManager: UndoManager?
    /// Shows a problem (the owner decides how: a warning in the panel, an alert in Meetings).
    @ObservationIgnored var report: (String, Error) -> Void = { _, _ in }
    /// A new or changed note, so the live pass can look at it (the recorder).
    @ObservationIgnored var noteChanged: (Int64) -> Void = { _ in }
    @ObservationIgnored private var expansions: [Int64: Task<Void, Never>] = [:]
    /// Who set a note as "being written": a replaced request must not clear the spinner of the one that replaced it.
    @ObservationIgnored private var workTokens: [Int64: UUID] = [:]
    /// Asks the owner to confirm before a note is deleted by clearing its words (Meetings); nil deletes at once (the panel).
    @ObservationIgnored var confirmDelete: ((MeetingNote) -> Void)?
    /// The notes of the meeting changed (so a list kept elsewhere can be read again).
    @ObservationIgnored var notesChanged: () -> Void = {}
    /// The notes are those of a meeting being recorded (the final pass has not run yet).
    @ObservationIgnored var live = false
    /// Tests: replaces the write of a note's words (to make it fail).
    @ObservationIgnored var writeWords: ((Int64, String) async throws -> Void)?
    @ObservationIgnored private var deletedClear: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var presences: [Int64: Presence] = [:]
    @ObservationIgnored private var chain: Task<Void, Never>?
    @ObservationIgnored private var lastAnnouncement: ContinuousClock.Instant?

    var rows: [NoteRow] = []
    /// The text of the field: a new note, or the note being edited.
    var draft = ""
    var editingID: Int64?
    /// The notes the model is writing right now.
    var working: Set<Int64> = []
    /// The notes whose whole expansion is open (the panel shows its first sentence).
    var disclosed: Set<Int64> = []
    /// Notes whose expansion was just replaced by a pass: "Updated · Undo" until the next thing the user does.
    var updated: Set<Int64> = []
    /// Every note deleted in the last few seconds, oldest first (each keeps its own Undo).
    var deleted: [Deleted] = []
    /// Live notes that used all their tries and now wait for the final pass (the recorder sets it).
    var exhausted: Set<Int64> = []
    var modelConfigured = true
    /// The meeting has a transcript to expand notes from.
    var hasTranscript = true
    /// The segments the expansions cite that still exist (retention may have purged the rest).
    var existingSegments: Set<Int64> = []
    var fieldFocused = false
    /// Asks the field to take the keyboard (a note chosen for editing from its row).
    var focusRequest = 0
    /// The note whose words are being edited in the Notes tab, and the text in its editor.
    var editingWordsID: Int64?
    var wordsDraft = ""
    /// The note whose expansion is being rewritten by the user, and the text in its editor.
    var editingExpansionID: Int64?
    var expansionDraft = ""
    /// The model cannot write in this language (said once for the whole card).
    var languageProblem: Bool { rows.contains { status(of: $0) == .unsupportedLanguage } }

    // MARK: Reading

    func reload(markUpdates: Bool = true) async {
        guard let store, let id = meetingID else { rows = []; return }
        do {
            let fresh = try await store.noteRows(id)
            if markUpdates {
                for row in fresh {
                    guard let before = rows.first(where: { $0.id == row.id })?.expansion, let after = row.expansion,
                          before.state == .done, after.state == .done, !after.userEdited, after.previous != nil,
                          before.sentences != after.sentences else { continue }
                    updated.insert(row.id)
                }
            }
            rows = fresh
            let cited = Set(fresh.flatMap { $0.expansion?.sentences.flatMap { $0.cites.map(\.seg) } ?? [] })
            existingSegments = try await store.existingSegmentIDs(Array(cited))
            restoreRescued()
        } catch {
            report(String(localized: "Couldn’t load the notes", comment: "Alert title or warning: the user’s notes could not be read"), error)
        }
    }

    /// Whether the meeting's minutes job (its final pass writes the notes out) is queued or running (the owner knows).
    @ObservationIgnored var finalPassComing: () -> Bool = { false }

    /// What an unexpanded note says: it waits for more of the meeting while recording, is being expanded once the final
    /// pass is on its way, and is simply not expanded otherwise.
    private var waitingStatus: Status { live ? .waiting : (finalPassComing() ? .queued : .notExpanded) }

    /// Why the last try failed, in words (nil when it did not, or the code is not one the user can act on).
    func failureDetail(of row: NoteRow) -> String? {
        // "The model didn't answer" already says why; only a failure needs its reason.
        guard let code = row.expansion?.errorCode, status(of: row) == .failed else { return nil }
        return JobErrorCode(rawValue: code)?.localizedDescription
    }

    func status(of row: NoteRow) -> Status {
        if working.contains(row.id) { return .working }
        guard let e = row.expansion else { return !hasTranscript ? .noTranscript : (modelConfigured ? waitingStatus : .noModel) }
        switch e.state {
        case .dismissed: return .dismissed
        // Words the user wrote stay as they are, however the note changed after: no pass touches them, so "your note
        // changed" would stay for good.
        case .done: return e.userEdited ? .edited : (row.isStale ? .stale : .done)
        case .notFound: return row.isStale ? waitingStatus : .notFound
        case .failed, .pending:
            if row.isStale { return waitingStatus }
            guard let code = e.errorCode else { return modelConfigured ? waitingStatus : .noModel }
            if code == JobErrorCode.unsupportedLanguage.rawValue { return .unsupportedLanguage }
            // The live pass gave up on this note: it is not "waiting for more of the meeting", the final pass will try again.
            if live, e.state == .pending, exhausted.contains(row.id) { return .failed }
            let transient: Set<String> = [JobErrorCode.network, .busy, .keychainLocked, .server, .http].map(\.rawValue).reduce(into: []) { $0.insert($1) }
            // "Vauta will try again" is only true while recording, where the live pass tries again; after the meeting only
            // the final pass (when it is on its way) or the user does.
            if transient.contains(code) { return live ? .notAnswering : (finalPassComing() ? .queued : .failed) }
            return e.state == .failed ? .failed : waitingStatus
        }
    }

    func isCitationLive(_ cite: NoteExpansion.Cite) -> Bool { existingSegments.contains(cite.seg) }

    // MARK: The field

    /// Return in the field: a new note, or the edit of the one in the field.
    func save() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = editingID {
            draft = ""
            editingID = nil
            enqueue { [self] in
                if await change(id, to: text) { return }
                // The words are never lost: they go back to the field unless the user already started something else.
                if draft.isEmpty && editingID == nil { draft = text; editingID = id }
            }
            return
        }
        guard !text.isEmpty, store != nil, let meeting = meetingID else { return }
        // The meeting is the one open when Return is pressed, however long the save waits in the queue.
        let t = offset()
        let after = addedAfter
        draft = ""
        enqueue { [self] in
            if await add(text, in: meeting, at: t, addedAfter: after) { return }
            // What was typed meanwhile is never overwritten: the failed note goes in front of it (when that meeting is
            // still the one shown).
            guard meetingID == meeting else { return }
            draft = draft.isEmpty ? text : text + " " + draft
        }
    }

    /// Saves a new note and offers to take it back. False when it could not be saved (the caller keeps the text).
    @discardableResult
    private func add(_ text: String, in meeting: Int64, at t: Double, addedAfter after: Bool, announce: Bool = true) async -> Bool {
        guard let store else { return false }
        do {
            let id = try await store.addNote(meeting, at: t, text: text, addedAfter: after)
            // Another meeting may be shown by now (a new recording): the note is filed in its own, and this list is left alone.
            guard meetingID == meeting else { return true }
            await reload(markUpdates: false)
            updated = []
            notesChanged()
            if announce {
                AccessibilityNotification.Announcement(
                    after ? String(localized: "Note added.", comment: "VoiceOver announcement after a note was added to a saved meeting")
                          : String(localized: "Note saved at \(ElapsedTime.stamp(Int(t))).", comment: "VoiceOver announcement; the argument is the time in the meeting")).post()
            }
            if let row = rows.first(where: { $0.id == id }) {
                let presence = Presence(row: row, present: true)
                registerUndo(String(localized: "Add Note", comment: "Undo menu item"),
                             undo: { await $0.remove(presence) }, redo: { await $0.bringBack(presence) })
            }
            noteChanged(id)
            if after { expand(id) }
            return true
        } catch {
            report(String(localized: "The note couldn’t be saved.", comment: "Warning while recording"), error)
            NSSound(named: "Basso")?.play()
            AccessibilityNotification.Announcement(String(localized: "The note couldn’t be saved.", comment: "Warning while recording")).post()
            return false
        }
    }

    /// Something typed is not saved yet, or a save is still queued.
    var hasPendingWork: Bool {
        chain != nil || editingID != nil || editingWordsID != nil || editingExpansionID != nil
            || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The recording is ending (or the notepad is closing): what is in the field is saved as a note, or as the edit it was.
    /// If that fails the text stays in the field (and the failure is reported). True when nothing is left unsaved.
    @discardableResult
    func flushPending() async -> Bool {
        await settled()
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = editingID {
            guard await change(id, to: text) else { return false }
            draft = ""
            editingID = nil
            return true
        }
        guard !text.isEmpty else { draft = ""; return true }
        guard let meeting = meetingID, await add(text, in: meeting, at: offset(), addedAfter: addedAfter, announce: false) else { return false }
        draft = ""
        return true
    }

    /// ↑ in an empty field: the last note comes back to be edited.
    @discardableResult
    func editLast() -> Bool {
        guard draft.isEmpty, editingID == nil, let last = rows.last else { return false }
        edit(last.id)
        return true
    }

    func edit(_ id: Int64) {
        guard let row = rows.first(where: { $0.id == id }) else { return }
        editingID = id
        draft = row.note.text
        updated = []
        focusRequest += 1
    }

    func cancelEdit() {
        guard editingID != nil else { return }
        editingID = nil
        draft = ""
    }

    /// The new words of a note. The user's text is saved as typed; the expansion becomes out of date and is written again
    /// after a pause (unless the user removed or rewrote it, or the meeting is still being recorded: the live pass looks
    /// at the note then). Empty words delete the note: at once with "Note deleted · Undo", or after the owner's
    /// confirmation (Meetings). False when the store refused (the caller keeps what the user typed).
    @discardableResult
    func change(_ id: Int64, to text: String) async -> Bool {
        guard let row = rows.first(where: { $0.id == id }) else { return true }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            if let confirmDelete { confirmDelete(row.note) } else { await delete(id) }
            return true
        }
        guard clean != row.note.text else { return true }
        let before = row.note.text
        guard await setText(id, clean) else { return false }
        registerUndo(String(localized: "Edit Note", comment: "Undo menu item"),
                     undo: { _ = await $0.setText(id, before) }, redo: { _ = await $0.setText(id, clean) })
        return true
    }

    /// Writes the words of a note (no undo step of its own).
    private func setText(_ id: Int64, _ text: String) async -> Bool {
        guard let store, let row = rows.first(where: { $0.id == id }) else { return true }
        do {
            if let writeWords { try await writeWords(id, text) } else { try await store.updateNote(id, text: text) }
            updated = []
            reverted.remove(id)
            await reload(markUpdates: false)
            notesChanged()
            noteChanged(id)
            let expansion = row.expansion
            if !live, expansion?.state != .dismissed, expansion?.userEdited != true { expand(id, after: .seconds(1.5)) }
            return true
        } catch {
            report(String(localized: "The note couldn’t be saved.", comment: "Warning while recording"), error)
            return false
        }
    }

    // MARK: Deleting

    /// Removes a note with its expansion; "Note deleted · Undo" for a few seconds (and ⌘Z in Meetings) puts both back.
    /// Every deleted note keeps its own Undo, and ⌘Z walks back through them in order.
    func delete(_ id: Int64) async {
        guard let presence = await remove(id, banner: true) else { return }
        registerUndo(String(localized: "Delete Note", comment: "Undo menu item"),
                     undo: { await $0.bringBack(presence) }, redo: { await $0.remove(presence) })
    }

    /// Takes the note out of the store; nil when it is already gone or the store refused (reported).
    private func remove(_ id: Int64, banner: Bool) async -> Presence? {
        guard let store, let row = rows.first(where: { $0.id == id }) else { return nil }
        do {
            expansions[id]?.cancel()
            try await store.updateNote(id, text: "")
            rows.removeAll { $0.id == id }
            disclosed.remove(id)
            updated = []
            notesChanged()
            let presence = Presence(row: row, present: false)
            if banner { showDeleted(presence) }
            noteChanged(id)
            return presence
        } catch {
            report(String(localized: "Couldn’t delete the note", comment: "Alert title"), error)
            return nil
        }
    }

    private func remove(_ presence: Presence) async {
        guard presence.present else { return }
        if await remove(presence.row.id, banner: false) != nil { presence.present = false }
    }

    private func showDeleted(_ presence: Presence) {
        let id = presence.row.id
        presences[id] = presence
        deleted.removeAll { $0.id == id }
        deleted.append(Deleted(row: presence.row))
        AccessibilityNotification.Announcement(String(localized: "Note deleted", comment: "VoiceOver announcement after a note was deleted; Undo is offered")).post()
        deletedClear[id]?.cancel()
        deletedClear[id] = Task { [weak self] in
            try? await Task.sleep(for: self?.bannerDuration ?? .seconds(6))
            guard !Task.isCancelled else { return }
            self?.clearBanner(id)
        }
    }

    /// How long "Note deleted · Undo" stays (the undo of the Edit menu does not depend on it).
    @ObservationIgnored var bannerDuration: Duration = .seconds(6)

    private func clearBanner(_ id: Int64) {
        deletedClear[id]?.cancel()
        deletedClear[id] = nil
        presences[id] = nil
        deleted.removeAll { $0.id == id }
    }

    func clearBanners() {
        for id in Array(deletedClear.keys) { clearBanner(id) }
        deleted = []
    }

    /// Puts the note back with its expansion; nothing happens when it is back already.
    private func bringBack(_ presence: Presence) async {
        guard let store, !presence.present else { return }
        let original = presence.row.id
        do {
            let restored = try await store.restoreNote(presence.row)
            presence.present = true
            clearBanner(original)
            await reload(markUpdates: false)
            if let row = rows.first(where: { $0.id == restored }) { presence.row = row }
            notesChanged()
            noteChanged(restored)
        } catch {
            report(String(localized: "Couldn’t restore the note", comment: "Alert title"), error)
        }
    }

    /// The "Undo" of "Note deleted · Undo".
    func undoDelete(_ id: Int64) async {
        guard let presence = presences[id] else { return }
        await bringBack(presence)
    }

    // MARK: The model's part

    private func startWork(_ id: Int64) -> UUID {
        let token = UUID()
        workTokens[id] = token
        working.insert(id)
        return token
    }

    private func endWork(_ id: Int64, _ token: UUID) {
        guard workTokens[id] == token else { return }
        workTokens[id] = nil
        working.remove(id)
    }

    /// Writes the expansion (after a pause for an edit); nothing without a model.
    func expand(_ id: Int64, after delay: Duration = .zero, replacingEdited: Bool = false) {
        guard let llm, modelConfigured, hasTranscript else { return }
        expansions[id]?.cancel()
        expansions[id] = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            let token = self.startWork(id)
            _ = try? await llm.expandNote(noteID: id, replacingEdited: replacingEdited)
            self.endWork(id, token)
            await self.reload()
        }
    }

    /// The notes `expandMissing` writes.
    var missingExpansionIDs: [Int64] { rows.filter { $0.note.addedAfter && $0.expansion == nil }.map(\.id) }

    /// Notes typed after the meeting that have no expansion yet (no model was set up then, or Vauta closed first), one
    /// after the other. Nothing else: notes of the recording and old notes are the final pass's, a failed one is tried
    /// again only by the user ("Expand Again"), and browsing a meeting never sends anything for a note it already has.
    func expandMissing() async {
        let todo = missingExpansionIDs
        guard let llm, modelConfigured, hasTranscript, !todo.isEmpty else { return }
        for id in todo {
            guard !Task.isCancelled, !working.contains(id) else { continue }
            let token = startWork(id)
            _ = try? await llm.expandNote(noteID: id)
            endWork(id, token)
            await reload()
        }
    }

    func expandAgain(_ id: Int64) async {
        guard let store else { return }
        updated = []
        guard let llm, modelConfigured else { return }
        let before = try? await store.expansion(of: id)
        expansions[id]?.cancel()
        expansions[id] = nil
        let token = startWork(id)
        _ = try? await llm.expandNote(noteID: id, replacingEdited: true)
        endWork(id, token)
        await reload(markUpdates: false)
        // An undo step only when the note really changed (a "not found" or a failed try keeps the version it had).
        registerExpansionChange(String(localized: "Expand Again", comment: "Undo menu item and menu command: the model writes the note out again"),
                                id, before: before, after: try? await store.expansion(of: id))
    }

    /// Notes whose update the user took back during this recording.
    @ObservationIgnored var reverted: Set<Int64> = []

    func toggle(_ id: Int64) {
        if disclosed.contains(id) { disclosed.remove(id) } else { disclosed.insert(id) }
    }

    @ObservationIgnored var rescued: [Int64: Rescue] = [:]

    // MARK: VoiceOver

    /// "Note expanded: Q3 budget." at most once in 20 seconds, and never while the user is typing in the field.
    func announceExpanded(_ note: String) {
        guard claimsAnnouncement() else { return }
        let headline = String(note.prefix(60))
        AccessibilityNotification.Announcement(String(localized: "Note expanded: \(headline)", comment: "VoiceOver announcement while recording; the argument is the start of the user’s note")).post()
    }

    /// True when an announcement may be made now (and counts as made): not while the user is typing, and not within 20
    /// seconds of the last one.
    func claimsAnnouncement(at now: ContinuousClock.Instant = .now) -> Bool {
        if fieldFocused && !draft.isEmpty { return false }
        if let last = lastAnnouncement, now - last < .seconds(20) { return false }
        lastAnnouncement = now
        return true
    }

    // MARK: Undo (Meetings)

    typealias Step = @MainActor @Sendable (NotepadModel) async -> Void

    /// Registers the way back with the window's undo manager, and the way forward: the handler files the opposite step
    /// before it returns (the manager makes it the Redo while undoing and the Undo while redoing) and then runs this one.
    /// Steps run one after the other, so an undo that follows a slow one sees its result.
    func registerUndo(_ name: String, undo: @escaping Step, redo: @escaping Step) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.registerUndo(name, undo: redo, redo: undo)
                model.enqueue { await undo(model) }
            }
        }
        undoManager.setActionName(name)
    }

    /// Runs `operation` after every earlier one.
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    /// Waits for the saves and undo steps in flight.
    func settled() async {
        while let current = chain {
            await current.value
            if chain == current { chain = nil }
        }
    }

    func forgetUndo() {
        undoManager?.removeAllActions(withTarget: self)
    }
}
