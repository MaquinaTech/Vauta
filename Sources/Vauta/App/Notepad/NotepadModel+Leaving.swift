// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import Observation
import SwiftUI

extension NotepadModel {
    /// What could not be saved when a meeting was left, kept for when it is shown again (never dropped).
    struct Rescue: Equatable {
        var draft: String?
        var words: (id: Int64, text: String)?
        var expansion: (id: Int64, text: String)?
        static func == (a: Rescue, b: Rescue) -> Bool { a.draft == b.draft && a.words?.id == b.words?.id && a.words?.text == b.words?.text
            && a.expansion?.id == b.expansion?.id && a.expansion?.text == b.expansion?.text }
    }

    /// Brings back what a failed save left for the meeting now shown (called after its notes are read).
    func restoreRescued() {
        guard let meeting = meetingID, let r = rescued.removeValue(forKey: meeting) else { return }
        if let text = r.draft, draft.isEmpty, editingID == nil { draft = text }
        if let (id, text) = r.words, rows.contains(where: { $0.id == id }), editingWordsID == nil { editingWordsID = id; wordsDraft = text }
        if let (id, text) = r.expansion, rows.contains(where: { $0.id == id }), editingExpansionID == nil { editingExpansionID = id; expansionDraft = text }
    }

    /// Another meeting is about to be shown (or the window closes, or the app quits): the words being edited, the
    /// expansion being rewritten and the note not yet added are saved in the meeting they belong to (captured now; the
    /// lists are about to be replaced). A rewrite to nothing is not a delete: nothing confirmed it, so the note stays as
    /// it was. What cannot be saved is kept in `rescued` and comes back when that meeting is shown again. The task
    /// finishes when the writes are done (quitting waits for it).
    @discardableResult
    func commitPendingBeforeLeaving() -> Task<Void, Never>? {
        guard let store, let meeting = meetingID else { return nil }
        let edit = editingWordsID.flatMap { id in rows.first(where: { $0.id == id }).map { (id, wordsDraft.trimmingCharacters(in: .whitespacesAndNewlines), $0.note.text) } }
        let rewrite = editingExpansionID.map { ($0, expansionDraft) }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = offset()
        let expander = (modelConfigured && hasTranscript) ? llm : nil
        editingWordsID = nil
        wordsDraft = ""
        editingExpansionID = nil
        expansionDraft = ""
        draft = ""
        editingID = nil
        guard edit != nil || rewrite != nil || !text.isEmpty else { return nil }
        let notify = notesChanged
        return Task { @MainActor [report, weak self] in
            var lost = Rescue()
            do {
                if let (id, words, before) = edit, !words.isEmpty, words != before {
                    do { try await store.updateNote(id, text: words) } catch { lost.words = (id, words); throw error }
                }
                if let (id, body) = rewrite, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do { try await store.editExpansion(noteID: id, text: body) } catch { lost.expansion = (id, body); throw error }
                }
                if !text.isEmpty {
                    do {
                        let id = try await store.addNote(meeting, at: t, text: text, addedAfter: true)
                        // Written out without waiting (quitting must not wait for a model): the note does not stay unexpanded
                        // until that meeting is opened again.
                        if let expander { Task { _ = try? await expander.expandNote(noteID: id) } }
                    } catch { lost.draft = text; throw error }
                }
                notify()
            } catch {
                if lost.draft == nil, !text.isEmpty, lost.words != nil || lost.expansion != nil { lost.draft = text }
                if lost != Rescue() { self?.rescued[meeting] = lost }
                report(String(localized: "The note couldn’t be saved.", comment: "Warning while recording"), error)
            }
        }
    }

    /// Saves everything pending and waits for it, for quitting and closing: nothing typed is lost.
    func commitAndSettle() async {
        await commitPendingBeforeLeaving()?.value
        await settled()
    }
}
