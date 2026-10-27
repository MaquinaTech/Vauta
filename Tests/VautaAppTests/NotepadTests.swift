// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import Foundation
import Testing
import VautaCore
@testable import Vauta

/// The floating notepad and the notes model: what keeps the meeting app in front, the user's words first and the states.
@MainActor
@Suite("Notepad · window and model")
struct NotepadTests {
    // MARK: Window

    @Test func theNotepadNeverActivatesVautaAndStaysOutOfScreenSharing() {
        let panel = NotepadPanelController.makeBarePanel()
        #expect(panel.styleMask.contains(.nonactivatingPanel), "typing does not take the front from the meeting app")
        #expect(panel.canBecomeKey && !panel.canBecomeMain)
        #expect(panel.sharingType == .none)
        #expect(panel.level == .floating && panel.isFloatingPanel && !panel.hidesOnDeactivate)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.collectionBehavior.contains(.fullScreenAuxiliary))
        var closed = false
        panel.onEscape = { closed = true }
        panel.cancelOperation(nil)
        #expect(closed, "Esc closes it")
    }

    // MARK: Model

    private func row(_ id: Int64, _ text: String, t: Double = 10, state: NoteExpansion.State? = nil, code: String? = nil,
                     sentences: [NoteExpansion.Sentence] = [], edited: Bool = false, key: String? = nil) -> NoteRow {
        let note = MeetingNote(id: id, meetingID: 1, t: t, text: text)
        guard let state else { return NoteRow(note: note, expansion: nil) }
        return NoteRow(note: note, expansion: NoteExpansion(noteID: id, meetingID: 1, state: state, pass: .closing, sentences: sentences,
                                                            sourceKey: key ?? TextKeys.norm(text), userEdited: edited, errorCode: code))
    }

    @Test func upArrowInAnEmptyFieldEditsTheLastNoteAndEscCancels() {
        let model = NotepadModel()
        model.rows = [row(1, "first"), row(2, "second")]
        #expect(model.editLast() && model.editingID == 2 && model.draft == "second")
        model.cancelEdit()
        #expect(model.editingID == nil && model.draft.isEmpty)
        model.draft = "typing something"
        #expect(!model.editLast(), "only an empty field gives the last note back")
        #expect(model.draft == "typing something")
        model.draft = ""
        model.rows = []
        #expect(!model.editLast())
    }

    @Test func everyStateHasItsOwnStatusAndTheUsersWordsAreNeverTheExpansion() {
        let model = NotepadModel()
        let one = NoteExpansion.Sentence(text: "Model text.", cites: [.init(seg: 1, t: 3)], quote: "Model text")
        #expect(model.status(of: row(1, "a")) == .notExpanded, "a meeting that is over just has not been expanded yet")
        model.live = true
        #expect(model.status(of: row(1, "a")) == .waiting)
        model.modelConfigured = false
        #expect(model.status(of: row(1, "a")) == .noModel)
        model.modelConfigured = true
        model.hasTranscript = false
        #expect(model.status(of: row(1, "a")) == .noTranscript)
        model.hasTranscript = true
        #expect(model.status(of: row(1, "a", state: .done, sentences: [one])) == .done)
        #expect(model.status(of: row(1, "a", state: .done, sentences: [one], edited: true)) == .edited)
        #expect(model.status(of: row(1, "a changed", state: .done, sentences: [one], key: TextKeys.norm("a"))) == .stale)
        #expect(model.status(of: row(1, "a changed", state: .done, sentences: [one], edited: true, key: TextKeys.norm("a"))) == .edited,
                "an expansion the user rewrote is never out of date: no pass would write it again")
        #expect(model.status(of: row(1, "a", state: .notFound)) == .notFound)
        #expect(model.status(of: row(1, "a", state: .pending, code: "network")) == .notAnswering)
        #expect(model.status(of: row(1, "a", state: .pending, code: "unsupported_language")) == .unsupportedLanguage)
        #expect(model.status(of: row(1, "a", state: .failed, code: "invalid_response")) == .failed)
        #expect(model.status(of: row(1, "a", state: .dismissed)) == .dismissed)
        model.working = [1]
        #expect(model.status(of: row(1, "a", state: .done, sentences: [one])) == .working)
        let shown = row(1, "My words", state: .done, sentences: [one])
        #expect(shown.note.text == "My words" && shown.visibleSentences.map(\.text) == ["Model text."])
        #expect(row(1, "a", state: .dismissed).visibleSentences.isEmpty)
    }

    @Test func aLiveNoteThatUsedItsTriesIsFailedNotWaitingForMoreOfTheMeeting() {
        let model = NotepadModel()
        model.live = true
        let pending = row(1, "a", state: .pending, code: "invalid_response")
        #expect(model.status(of: pending) == .waiting, "while tries are left it is waiting")
        model.exhausted = [1]
        #expect(model.status(of: pending) == .failed && model.failureDetail(of: pending) != nil)
        model.exhausted = []
        #expect(model.failureDetail(of: row(1, "a", state: .pending, code: "network")) == nil, "the model not answering already says why")
    }

    @Test func aCitationWhosePassageWasPurgedHasNoLink() {
        let model = NotepadModel()
        model.existingSegments = [1]
        #expect(model.isCitationLive(.init(seg: 1, t: 5)) && !model.isCitationLive(.init(seg: 2, t: 6)))
    }

    @Test func theTextsOfTheStatesAreSpokenNotOnlyShownAsGlyphs() {
        for status in [NotepadModel.Status.working, .waiting, .notExpanded, .noTranscript, .edited, .stale, .notFound, .notAnswering, .unsupportedLanguage, .failed] {
            #expect(status.text?.isEmpty == false, "\(status) has words")
        }
        let one = NoteExpansion.Sentence(text: "Ana proposed it.", cites: [.init(seg: 1, t: 3), .init(seg: 2, t: 9)], unconfirmed: true)
        let spoken = NoteText.spokenExpansion(row(1, "a", state: .done, sentences: [one]))
        #expect(spoken.contains("Ana proposed it.") && spoken.contains("2") && spoken.contains("1"))
    }
}
