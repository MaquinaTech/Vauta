// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// The words of a transcript line being corrected, as typed so far.
struct LineDraft: Equatable {
    let segmentID: Int64
    let meetingID: Int64
    var text: String
}

/// Correcting the words of a transcript line (`MeetingStore.correctSegment`): in place, with Restore Original and Edit ▸ Undo.
/// The meeting is read again afterwards, since a correction can change the names found in it, the marks on its minutes and what
/// search and Ask find.
extension MeetingsModel {
    /// A line of the meeting shown can be corrected: it has its transcript and is not the one being recorded.
    func canCorrect(_ segment: MeetingStore.StoredSegment) -> Bool {
        mode == .meetings && segment.meetingID == selectedID && !isActive
    }

    /// The highlighted passage can be corrected (Return, and the menu item for keyboard users).
    var canCorrectHighlight: Bool { tab == .transcript && highlightedSegment.map(canCorrect) == true }

    func correctHighlight() {
        guard canCorrectHighlight, let segment = highlightedSegment else { return }
        beginCorrecting(segment)
    }

    func beginCorrecting(_ segment: MeetingStore.StoredSegment) {
        guard canCorrect(segment) else { return }
        noteActivity()
        everywhereOffer = nil
        if let lineDraft, lineDraft.segmentID != segment.id { saveLineDraft() }
        highlighted = segment.id
        lineDraft = LineDraft(segmentID: segment.id, meetingID: segment.meetingID, text: segment.text)
    }

    func cancelCorrecting() { lineDraft = nil }

    /// Saves the line being corrected (Return, Save, leaving the meeting or closing the window).
    func saveLineDraft() {
        guard let draft = lineDraft else { return }
        lineDraft = nil
        Task { await correct(draft.segmentID, meetingID: draft.meetingID) { store in try await store.correctSegment(draft.segmentID, text: draft.text) } }
    }

    /// Puts back what the transcriber wrote.
    func restoreOriginal(_ segment: MeetingStore.StoredSegment) async {
        if lineDraft?.segmentID == segment.id { lineDraft = nil }
        await correct(segment.id, meetingID: segment.meetingID) { store in try await store.restoreOriginalText(segment.id) }
    }

    private func correct(_ segmentID: Int64, meetingID: Int64,
                         _ change: @Sendable (MeetingStore) async throws -> MeetingStore.TextCorrection?) async {
        noteActivity()
        let correction: MeetingStore.TextCorrection?
        do {
            correction = try await change(store)
        } catch {
            present(String(localized: "Couldn’t correct the line", comment: "Alert title: saving the corrected words of a transcript line failed"), error)
            return
        }
        guard let correction else { return }
        registerUndo(of: correction)
        // A misheard word is often misheard elsewhere too, and a new name is worth remembering: offered, never done without the
        // person.
        everywhereOffer = correction.restored ? nil : try? await store.correctEverywhereOffer(after: correction)
        if let everywhereOffer { AccessibilityNotification.Announcement(CorrectEverywhereNote.announcement(everywhereOffer)).post() }
        await reloadAfterCorrection(meetingID)
    }

    /// Adds a name or term from the offer to the glossary (the person asked), with Edit ▸ Undo.
    func addToGlossary(_ term: String) async {
        everywhereOffer = everywhereOffer?.adding(term)
        noteActivity()
        let added: MeetingStore.CorrectedTerm?
        do {
            added = try await store.addCorrectedTerm(term)
        } catch {
            present(String(localized: "Couldn’t save the term", comment: "Alert title: saving a glossary term failed"), error)
            return
        }
        guard let added else { return }
        onGlossaryChanged?()
        if let undoManager {
            undoManager.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated {
                    _ = Task {
                        do {
                            try await model.store.undoAddCorrectedTerm(added)
                        } catch {
                            model.present(String(localized: "Couldn’t delete the term", comment: "Alert title: deleting a glossary term failed"), error)
                        }
                        model.onGlossaryChanged?()
                    }
                }
            }
            undoManager.setActionName(CorrectEverywhereNote.addTitle(term))
        }
        show(MeetingsNotice(text: String(localized: "Added to the glossary", comment: "Confirmation after the person added a corrected name or term to the glossary")))
    }

    /// Corrects the offered words in the rest of the meeting (the person accepted), with Edit ▸ Undo. The terms for the glossary
    /// stay offered.
    func correctEverywhere() async {
        guard let offer = everywhereOffer, offer.isElsewhere else { return }
        everywhereOffer = offer.corrected()
        noteActivity()
        let undo: MeetingStore.CorrectEverywhereUndo?
        do {
            undo = try await store.correctEverywhere(offer)
        } catch {
            present(String(localized: "Couldn’t correct the line", comment: "Alert title: saving the corrected words of a transcript line failed"), error)
            return
        }
        if let undo, let undoManager, undo.meetingID == selectedID {
            undoManager.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated {
                    _ = Task {
                        do {
                            try await model.store.undoCorrectEverywhere(undo)
                        } catch {
                            model.present(String(localized: "Couldn’t undo the change", comment: "Alert title: taking back a speaker edit failed"), error)
                        }
                        await model.reloadAfterCorrection(undo.meetingID)
                    }
                }
            }
            undoManager.setActionName(CorrectEverywhereNote.title)
        }
        await reloadAfterCorrection(offer.meetingID)
        if undo != nil { show(MeetingsNotice(text: String(localized: "Corrected in the whole meeting", comment: "Confirmation after Correct Everywhere"))) }
    }

    /// Edit ▸ Undo. There is no Redo: the store restores, it does not replay.
    private func registerUndo(of correction: MeetingStore.TextCorrection) {
        guard let undoManager, correction.meetingID == selectedID else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                _ = Task {
                    do {
                        try await model.store.undoCorrection(correction)
                    } catch {
                        model.present(String(localized: "Couldn’t undo the change", comment: "Alert title: taking back a speaker edit failed"), error)
                    }
                    await model.reloadAfterCorrection(correction.meetingID)
                }
            }
        }
        undoManager.setActionName(correction.restored ? CorrectedNote.restoreTitle : CorrectLineButton.title)
    }

    /// The minutes' marks, the names, the translation shown, the questions and the follow-up meetings found in it may have changed
    /// with the line; search and Ask embed the meeting again when its text changed.
    private func reloadAfterCorrection(_ meetingID: Int64) async {
        if let llm { Task { await llm.speakersChanged(meetingID: meetingID) } }
        _ = try? await store.redetectFollowUps(meetingID)
        guard selectedID == meetingID else { return }
        await refreshDetail()
        translateCorrectedLines(meetingID)
        if !hits.isEmpty { await runSearch() }
    }
}
