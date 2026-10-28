// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import Observation
import SwiftUI

extension NotepadModel {
    func removeExpansion(_ id: Int64) async {
        guard let store else { return }
        do {
            let before = try await store.expansion(of: id)
            try await store.dismissExpansion(noteID: id)
            updated = []
            await reload(markUpdates: false)
            registerExpansionChange(String(localized: "Remove Expansion", comment: "Undo menu item and menu command"),
                                    id, before: before, after: try await store.expansion(of: id))
        } catch {
            report(String(localized: "Couldn’t change the note", comment: "Alert title"), error)
        }
    }

    /// Brings back what the user removed (the previous version), or writes it again when there is none.
    func showExpansion(_ id: Int64) async {
        if let e = try? await store?.expansion(of: id), e.previous != nil { await revert(id) } else { await expandAgain(id) }
    }

    /// The user's own version of an expansion (one sentence per line). An empty editor removes the expansion.
    func saveExpansion(_ id: Int64, text: String) async {
        guard let store else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { await removeExpansion(id); return }
        do {
            let before = try await store.expansion(of: id)
            try await store.editExpansion(noteID: id, text: text)
            updated = []
            await reload(markUpdates: false)
            registerExpansionChange(String(localized: "Edit Expansion", comment: "Undo menu item and menu command"),
                                    id, before: before, after: try await store.expansion(of: id))
        } catch {
            report(String(localized: "Couldn’t change the note", comment: "Alert title"), error)
        }
    }

    /// The user checked a sentence the transcript did not back: the mark goes, the text stays the model's.
    func markChecked(_ id: Int64, sentence: Int) async {
        guard let store else { return }
        do {
            let before = try await store.expansion(of: id)
            try await store.markSentenceChecked(noteID: id, index: sentence)
            await reload(markUpdates: false)
            registerExpansionChange(String(localized: "Mark as Checked", comment: "Button on an item the model proposed and nobody has confirmed: the user has checked it"),
                                    id, before: before, after: try await store.expansion(of: id))
        } catch {
            report(String(localized: "Couldn’t change the note", comment: "Alert title"), error)
        }
    }

    /// "Updated · Undo": the version before the last change comes back. The live pass leaves the note alone from then on
    /// (it would only write the update again); the final pass has the last word.
    func revert(_ id: Int64) async {
        guard let store else { return }
        do {
            let before = try await store.expansion(of: id)
            try await store.restorePreviousExpansion(noteID: id)
            updated.remove(id)
            reverted.insert(id)
            await reload(markUpdates: false)
            registerExpansionChange(String(localized: "Undo", comment: "Undo menu item"), id, before: before, after: try await store.expansion(of: id))
        } catch {
            report(String(localized: "Couldn’t change the note", comment: "Alert title"), error)
        }
    }

    /// Whether two snapshots are the same expansion (the error code and the clock do not count).
    private func sameExpansion(_ a: NoteExpansion?, _ b: NoteExpansion?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.state == b.state && a.sentences == b.sentences && a.userEdited == b.userEdited && a.sourceKey == b.sourceKey
            && a.pass == b.pass && a.previous == b.previous
    }

    /// One undo step for one change: it holds the exact version before and after, so undoing it brings back precisely
    /// what it replaced, however many other changes came between.
    func registerExpansionChange(_ name: String, _ id: Int64, before: NoteExpansion?, after: NoteExpansion?) {
        guard !sameExpansion(before, after) else { return }
        registerUndo(name, undo: { await $0.putExpansion(id, before) }, redo: { await $0.putExpansion(id, after) })
    }

    private func putExpansion(_ id: Int64, _ snapshot: NoteExpansion?) async {
        guard let store else { return }
        do {
            try await store.restoreExpansion(noteID: id, to: snapshot)
            updated.remove(id)
            await reload(markUpdates: false)
        } catch {
            report(String(localized: "Couldn’t change the note", comment: "Alert title"), error)
        }
    }
}
