// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Notepad: review fixes (edited expansions, hints, budget, scoping, journal)")
struct NotepadReviewFixesTests {
    private func sentence(_ text: String, seg: Int64 = 1, t: Double = 0, quote: String = "the quarterly budget") -> NoteExpansion.Sentence {
        NoteExpansion.Sentence(text: text, cites: [.init(seg: seg, t: t)], quote: quote)
    }

    // MARK: A rewrite the user made is never stale

    @Test func anExpansionTheUserRewroteSurvivesAnEditOfTheNoteWordsInEveryExport() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["Ana said the budget goes up ten percent", "Fine"])
        let note = try await f.store.addNote(id, at: 5, text: "budgt")
        try await f.store.editExpansion(noteID: note, text: "My own summary of the budget.")
        try await f.store.updateNote(note, text: "budget")   // a typo fixed afterwards
        let row = try #require(try await f.store.noteRows(id).first)
        #expect(!row.isStale && row.expansion?.userEdited == true)
        let notes = try #require(try await f.store.meetingExport(id)).notes
        #expect(notes[0].text == "budget" && notes[0].editedByUser)
        #expect(notes[0].expansion.map(\.text) == ["My own summary of the budget."], "the user's text is in the export")
        let md = MeetingExportRenderer.markdown(try #require(try await f.store.meetingExport(id)), options: ExportRendererTests.options)
        #expect(md.contains("My own summary of the budget."))
    }

    @Test func aModelExpansionIsStillOutOfDateWhenTheWordsChange() {
        let note = MeetingNote(id: 1, meetingID: 1, t: 1, text: "changed")
        let model = NoteExpansion(noteID: 1, meetingID: 1, state: .done, pass: .closing, sentences: [sentence("S.")], sourceKey: TextKeys.norm("old"))
        #expect(NoteRow(note: note, expansion: model).isStale)
        var mine = model
        mine.userEdited = true
        #expect(!NoteRow(note: note, expansion: mine).isStale)
    }

    // MARK: Minutes

    @Test func theMinutesPromptOnlyCallsCurrentModelTextChecked() {
        func row(_ id: Int64, key: String, edited: Bool) -> NoteRow {
            let note = MeetingNote(id: id, meetingID: 1, t: Double(id) * 60, text: "note \(id)")
            let s = NoteExpansion.Sentence(text: "Text \(id).", cites: [.init(seg: 120 + id, t: 1)], quote: "x")
            return NoteRow(note: note, expansion: NoteExpansion(noteID: id, meetingID: 1, state: .done, pass: .closing, sentences: [s],
                                                                sourceKey: TextKeys.norm(key), userEdited: edited))
        }
        let hints = LLMService.priorityHints([row(1, key: "note 1", edited: false),
                                              row(2, key: "an older wording", edited: false),
                                              row(3, key: "note 3", edited: true)], budget: ContextBudget(contextTokens: 32_768))
        #expect(hints.map(\.expansion) == ["Text 1. [S121]", nil, nil],
                "an expansion of older words and one the user wrote are not sent as checked evidence")
    }

    // MARK: Verifier

    @Test func aSentenceDroppedForItsQuoteDoesNotBlockItsCorrectRepeat() throws {
        let segment = CitableSegment(id: 7, channel: .others, start: 310, text: "We will raise the Q3 budget by 10% if hiring waits", speaker: nil)
        let check = VautaPrompts.NoteCheck(sent: [7: segment], people: [], maxSentences: 3)
        let out = try VautaPrompts.validateNoteExpansion(#"""
            {"sentences": [
              {"text": "The budget goes up 10%.", "seg": [7], "quote": "this quote is not said anywhere"},
              {"text": "The budget goes up 10%.", "seg": [7], "quote": "raise the Q3 budget by 10%"}]}
            """#, check: check)
        #expect(out.map(\.text) == ["The budget goes up 10%."] && out[0].quote == "raise the Q3 budget by 10%")
    }

    // MARK: Budget

    @Test func theBudgetIncludesTheRealEarlierNotesInJapanese() {
        let long = String(repeating: "予算の見直しについて議論した内容", count: 20)   // clipped to 300 characters in the prompt
        let language = OutputLanguage(Locale(identifier: "ja-JP"))
        let with = PromptText.tokens([VautaPrompts.noteInstruction(["メモ"], earlier: [long, long], maxSentences: 3, language: language)])
        let without = PromptText.tokens([VautaPrompts.noteInstruction(["メモ"], maxSentences: 3, language: language)])
        #expect(with - without > 200, "two earlier notes cost far more than the 200 tokens once assumed")
    }

    // MARK: Ask is scoped to the meeting inside the search

    @Test func theNoteBoostOfAMeetingIsNotCrowdedOutByOtherMeetings() async throws {
        let fx = try KnowledgeFixture()
        let other = try await fx.meeting(["Plain line about zzorchard"])
        for i in 0..<60 { _ = try await fx.store.addNote(other, at: Double(i), text: "zzorchard note \(i) zzorchard zzorchard") }
        let mine = try await fx.meeting((0..<30).map { $0 == 20 ? "Line about the zzorchard shipment" : "Line \($0) about other things" })
        let segs = try await fx.store.segments(of: mine)
        let note = try await fx.store.addNote(mine, at: 250, text: "zzorchard")
        try await fx.store.saveExpansion(noteID: note, pass: .closing,
                                         outcome: .sentences([sentence("Shipment.", seg: segs[20].id, t: segs[20].start, quote: "about the zzorchard shipment")]),
                                         sourceKey: TextKeys.norm("zzorchard"))
        #expect(try await fx.store.noteCitedMoments(terms: ["zzorchard"], scope: [mine]).map(\.t) == [segs[20].start])
    }

    // MARK: Journal

    @Test func aFailureCodeOnAGoodExpansionIsKeptAndTheTextIsNotLost() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["Ana said the budget goes up ten percent"])
        let note = try await f.store.addNote(id, at: 5, text: "budget")
        let key = TextKeys.norm("budget")
        try await f.store.saveExpansion(noteID: note, pass: .live, outcome: .sentences([sentence("The budget rises.")]), sourceKey: key)
        let result = try await f.store.saveExpansion(noteID: note, pass: .manual, outcome: .failed(code: JobErrorCode.network.rawValue), sourceKey: key)
        #expect(result == .kept)
        let e = try #require(try await f.store.expansion(of: note))
        #expect(e.errorCode == JobErrorCode.network.rawValue && e.sentences.map(\.text) == ["The budget rises."])
    }
}
