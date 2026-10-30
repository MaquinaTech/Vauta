// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Notepad: storage, expansions, search and splits")
struct NotepadStoreTests {
    private func sentence(_ text: String, seg: Int64 = 1, t: Double = 0, quote: String = "the quarterly budget") -> NoteExpansion.Sentence {
        NoteExpansion.Sentence(text: text, cites: [.init(seg: seg, t: t)], quote: quote)
    }

    private func ready() async throws -> (fx: KnowledgeFixture, meeting: Int64, note: Int64) {
        let fx = try KnowledgeFixture()
        let meeting = try await fx.meeting(["Ana said the quarterly budget goes up ten percent", "Luis agreed if hiring waits"])
        let note = try await fx.store.addNote(meeting, at: 12, text: "Q3 budget +10%")
        return (fx, meeting, note)
    }

    // MARK: Migration 22

    @Test func upgradingFrom21KeepsNotesWithoutExpansions() async throws {
        let fx = StoreFixture()
        try fx.writeLegacyStore(schema: 21) { db in
            try StoreFixture.legacyMeeting(db)
            try db.query("INSERT INTO notes(meeting_id, t, text) VALUES (1, 4, 'nota heredada')")
        }
        let store = try fx.open()
        #expect(try await store.pragma("user_version") == Schema.currentVersion)
        let rows = try await store.noteRows(1)
        #expect(rows.count == 1 && rows[0].note.text == "nota heredada" && rows[0].expansion == nil)
        #expect(rows[0].note.addedAfter == false && rows[0].note.editedAt == nil)
        #expect(try await store.columnNames("notes").suffix(2) == ["added_after", "edited_at"])
    }

    @Test func aJournalFromSchema21ReplaysAndMigrates() async throws {
        let fx = StoreFixture()
        try fx.writeLegacyStore(schema: 21)
        var store: MeetingStore? = try fx.open()
        let note = try await store!.addNote(1, at: 3, text: "after the upgrade", addedAfter: true)
        try await store!.saveExpansion(noteID: note, pass: .manual, outcome: .sentences([sentence("Written.")]), sourceKey: TextKeys.norm("after the upgrade"))
        store = nil
        store = try fx.open()
        let row = try #require(try await store!.noteRows(1).first)
        #expect(row.note.addedAfter && row.expansion?.state == .done && row.expansion?.sentences.first?.text == "Written.")
    }

    // MARK: The user's text

    @Test func updatingANoteRecordsWhenTheUserEditedIt() async throws {
        let (fx, meeting, note) = try await ready()
        try await fx.store.updateNote(note, text: "Q3 budget +10%")
        #expect(try await fx.store.notes(meeting)[0].editedAt == nil, "the same text is not an edit")
        try await fx.store.updateNote(note, text: "Q3 budget +12%")
        #expect(try await fx.store.notes(meeting)[0].editedAt != nil)
    }

    @Test func noCodeUnderLLMWritesTheNotesTable() throws {
        let dir = NetworkAuditSourceScanTests.packageRoot().appending(path: "Sources/VautaCore/LLM")
        let walker = try #require(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
        var found = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            found += 1
            let code = NetworkAuditSourceScanTests.code(try String(contentsOf: url, encoding: .utf8)).lowercased()
            for pattern in ["update notes", "insert into notes", "insert or replace into notes", "delete from notes"] {
                #expect(!code.contains(pattern), "\(url.lastPathComponent) must not write notes (\(pattern))")
            }
        }
        #expect(found > 10)
    }

    // MARK: Expansions

    @Test func anExpansionIsSavedStaleWhenTheNoteChangesAndIndexedForSearch() async throws {
        let (fx, meeting, note) = try await ready()
        let key = TextKeys.norm("Q3 budget +10%")
        #expect(try await fx.store.saveExpansion(noteID: note, pass: .live, outcome: .sentences([sentence("Ana proposed raising the zzquartermaster budget.")]),
                                                  sourceKey: key, uptoSegment: 2) == .written)
        var row = try #require(try await fx.store.noteRows(meeting).first)
        #expect(row.expansion?.state == .done && !row.isStale && row.visibleSentences.count == 1)
        // Kind 6 of the knowledge index.
        let hits = try await fx.store.searchKnowledge("zzquartermaster")
        #expect(hits.map(\.kind) == [.noteExpansion] && hits[0].meetingID == meeting && hits[0].refID == note && hits[0].t == 12)
        try await fx.store.updateNote(note, text: "Q3 budget +12%")
        row = try #require(try await fx.store.noteRows(meeting).first)
        #expect(row.isStale, "the note changed after the expansion was written")
        #expect(row.note.text == "Q3 budget +12%", "the user's words are untouched")
    }

    @Test func aPassNeverReplacesWhatTheUserEditedAndKeepsOneLevelOfUndo() async throws {
        let (fx, _, note) = try await ready()
        let key = TextKeys.norm("Q3 budget +10%")
        try await fx.store.saveExpansion(noteID: note, pass: .live, outcome: .sentences([sentence("First version.")]), sourceKey: key)
        try await fx.store.saveExpansion(noteID: note, pass: .closing, outcome: .sentences([sentence("Second version.")]), sourceKey: key)
        var e = try #require(try await fx.store.expansion(of: note))
        #expect(e.sentences[0].text == "Second version." && e.pass == .closing && e.previous?.sentences[0].text == "First version.")
        try await fx.store.restorePreviousExpansion(noteID: note)
        e = try #require(try await fx.store.expansion(of: note))
        #expect(e.sentences[0].text == "First version." && e.previous?.sentences[0].text == "Second version.", "undo can be undone")

        try await fx.store.editExpansion(noteID: note, text: "My own wording.\nA second line.")
        e = try #require(try await fx.store.expansion(of: note))
        #expect(e.userEdited && e.sentences.map(\.text) == ["My own wording.", "A second line."])
        #expect(e.sentences.allSatisfy { $0.cites.isEmpty }, "words the user wrote carry no citation: nothing checked them")
        #expect(try await fx.store.saveExpansion(noteID: note, pass: .closing, outcome: .sentences([sentence("Model again.")]), sourceKey: key) == .kept)
        #expect(try await fx.store.notesNeedingExpansion(try #require(try await fx.store.noteRows(1).first?.note.meetingID), includingLive: true).isEmpty)
        #expect(try await fx.store.expansion(of: note)?.sentences[0].text == "My own wording.")
        // The user's own "Expand Again" may replace it, and the edit stays as the version to go back to.
        #expect(try await fx.store.saveExpansion(noteID: note, pass: .manual, outcome: .sentences([sentence("Fresh.")]), sourceKey: key, replacingEdited: true) == .written)
        try await fx.store.restorePreviousExpansion(noteID: note)
        #expect(try await fx.store.expansion(of: note)?.sentences[0].text == "My own wording.")
    }

    @Test func aFailureNeverReplacesAGoodExpansionAndNotFoundNeverReplacesACurrentOne() async throws {
        let (fx, _, note) = try await ready()
        let key = TextKeys.norm("Q3 budget +10%")
        try await fx.store.saveExpansion(noteID: note, pass: .live, outcome: .sentences([sentence("Good.")]), sourceKey: key)
        #expect(try await fx.store.saveExpansion(noteID: note, pass: .closing, outcome: .failed(code: "network"), sourceKey: key) == .kept)
        #expect(try await fx.store.saveExpansion(noteID: note, pass: .closing, outcome: .sentences([]), sourceKey: key) == .kept)
        let e = try #require(try await fx.store.expansion(of: note))
        #expect(e.state == .done && e.sentences[0].text == "Good." && e.errorCode == "network")
        // A different text of the note: nothing found there does replace it.
        #expect(try await fx.store.saveExpansion(noteID: note, pass: .manual, outcome: .sentences([]), sourceKey: "other") == .written)
        #expect(try await fx.store.expansion(of: note)?.state == .notFound)
    }

    @Test func whatNeedsAPassIsDecidedFromTheStoredState() async throws {
        let fx = try KnowledgeFixture()
        let meeting = try await fx.meeting(["something was said here"])
        let a = try await fx.store.addNote(meeting, at: 1, text: "no expansion")
        let b = try await fx.store.addNote(meeting, at: 2, text: "live result")
        let c = try await fx.store.addNote(meeting, at: 3, text: "final result")
        let d = try await fx.store.addNote(meeting, at: 4, text: "dismissed")
        let e = try await fx.store.addNote(meeting, at: 5, text: "not found")
        let ok: (Int64, String) -> String = { _, text in TextKeys.norm(text) }
        try await fx.store.saveExpansion(noteID: b, pass: .live, outcome: .sentences([sentence("x")]), sourceKey: ok(b, "live result"))
        try await fx.store.saveExpansion(noteID: c, pass: .closing, outcome: .sentences([sentence("y")]), sourceKey: ok(c, "final result"))
        try await fx.store.dismissExpansion(noteID: d)
        try await fx.store.saveExpansion(noteID: e, pass: .closing, outcome: .sentences([]), sourceKey: ok(e, "not found"))
        let atTheEnd = try await fx.store.notesNeedingExpansion(meeting, includingLive: true).map(\.id)
        #expect(atTheEnd == [a, b, e], "missing, provisional live and not found; not the final one or the dismissed")
        #expect(try await fx.store.notesNeedingExpansion(meeting, includingLive: false).map(\.id) == [a, e])
        try await fx.store.updateNote(c, text: "final result, changed")
        #expect(try await fx.store.notesNeedingExpansion(meeting, includingLive: false).map(\.id) == [a, c, e], "an edited note is stale")
    }

    // MARK: Deleting and restoring

    @Test func deletingANoteOrItsMeetingRemovesTheExpansionAndItsSearchEntry() async throws {
        let (fx, meeting, note) = try await ready()
        try await fx.store.saveExpansion(noteID: note, pass: .live, outcome: .sentences([sentence("zzgoneword here.")]), sourceKey: TextKeys.norm("Q3 budget +10%"))
        let row = try #require(try await fx.store.noteRows(meeting).first)
        try await fx.store.updateNote(note, text: "")
        #expect(try await fx.store.rowCount("note_expansions") == 0)
        #expect(try await fx.store.searchKnowledge("zzgoneword").isEmpty)
        // Undo: the note and its expansion come back.
        let restored = try await fx.store.restoreNote(row)
        let back = try #require(try await fx.store.noteRows(meeting).first)
        #expect(back.id == restored && back.note.text == "Q3 budget +10%" && back.expansion?.sentences.first?.text == "zzgoneword here.")
        #expect(try await fx.store.searchKnowledge("zzgoneword").count == 1)
        try await fx.store.deleteMeeting(meeting)
        #expect(try await fx.store.rowCount("note_expansions") == 0)
        #expect(try await fx.store.rowCount("notes") == 0)
        #expect(try await fx.store.searchKnowledge("zzgoneword").isEmpty)
        #expect(try await !fx.store.imageContains("zzgoneword"))
    }

    @Test func retentionKeepsExpansionsAndTheirCitationsLoseTheirLink() async throws {
        let fx = try KnowledgeFixture(knowledgeRetentionDays: 365)
        let old = Date.now - Double(MeetingStore.retentionDays + 10) * 86_400
        let meeting = try await fx.meeting(["Ana said the quarterly budget goes up"], at: old)
        let seg = try #require(try await fx.store.segments(of: meeting).first).id
        let note = try await fx.store.addNote(meeting, at: 0, text: "budget")
        try await fx.store.saveExpansion(noteID: note, pass: .closing, outcome: .sentences([sentence("Budget goes up.", seg: seg)]),
                                         sourceKey: TextKeys.norm("budget"))
        try await fx.store.executeForTest("UPDATE meetings SET card = '{}' WHERE id = ?", [.integer(meeting)])
        _ = try await fx.store.purgeExpired()
        #expect(try await fx.store.segments(of: meeting).isEmpty)
        let e = try #require(try await fx.store.expansion(of: note))
        #expect(e.state == .done && e.sentences.count == 1)
        #expect(try await fx.store.existingSegmentIDs([seg]).isEmpty, "the chip keeps its time but has nothing to open")
    }

    // MARK: Splits

    @Test func aSplitMovesACitationToThePartThatHoldsItsQuote() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await store.startMeeting(at: .now)
        let text = "Thanks for joining everyone, shall we start with the launch plan today"
        let seg = try await store.append(Segment(channel: .others, start: 0, end: 10, text: text, isFinal: true), to: m)
        try await store.endMeeting(m, at: .now)
        let note = try await store.addNote(m, at: 1, text: "launch")
        let sentences = [NoteExpansion.Sentence(text: "They greeted.", cites: [.init(seg: seg, t: 0)], quote: "Thanks for joining everyone"),
                         NoteExpansion.Sentence(text: "They started the plan.", cites: [.init(seg: seg, t: 0)], quote: "start with the launch plan"),
                         NoteExpansion.Sentence(text: "No quote, early.", cites: [.init(seg: seg, t: 0)], quote: ""),
                         NoteExpansion.Sentence(text: "No quote, late.", cites: [.init(seg: seg, t: 6)], quote: "")]
        try await store.saveExpansion(noteID: note, pass: .closing, outcome: .sentences(sentences), sourceKey: TextKeys.norm("launch"))
        let offset = text.distance(from: text.startIndex, to: text.range(of: " shall")!.lowerBound)
        let split = try await store.splitSegment(seg, atCharacter: offset, time: 4)
        var e = try #require(try await store.expansion(of: note))
        #expect(e.sentences.map { $0.cites[0].seg } == [seg, split.rightSegmentID, seg, split.rightSegmentID], "by quote; without one, by time")
        #expect(e.sentences[1].cites[0].t == 4)
        try await store.undo(split.undo)
        e = try #require(try await store.expansion(of: note))
        #expect(e.sentences.map { $0.cites[0].seg } == [seg, seg, seg, seg])
        #expect(e.sentences.map { $0.cites[0].t } == [0, 0, 0, 0])
    }

    // MARK: Ask

    @Test func askRanksTheMomentsCitedByAMatchingNoteHigher() async throws {
        let fx = try KnowledgeFixture()
        // Four moments mention the word; the user's note flags the third.
        let id = try await fx.meeting((0..<40).map { [3, 15, 25, 35].contains($0) ? "Line \($0) about the zzorchard shipment" : "Line \($0) about other things" })
        let segs = try await fx.store.segments(of: id)
        let plain = try await fx.store.retrieve("zzorchard", queryVector: nil, within: id, limit: 1, maxChars: 4_000)
        #expect(plain.first?.segments.contains { $0.id == segs[3].id } == true, "without a note the first match wins")
        let note = try await fx.store.addNote(id, at: 250, text: "zzorchard shipment")
        try await fx.store.saveExpansion(noteID: note, pass: .closing,
                                         outcome: .sentences([sentence("Shipment moves.", seg: segs[25].id, t: segs[25].start, quote: "about the zzorchard shipment")]),
                                         sourceKey: TextKeys.norm("zzorchard shipment"))
        #expect(try await fx.store.noteCitedMoments(terms: ["zzorchard"], scope: [id]).map(\.t) == [segs[25].start])
        #expect(try await fx.store.noteCitedMoments(terms: ["zzorchard"], scope: [id + 1]).isEmpty)
        let boosted = try await fx.store.retrieve("zzorchard", queryVector: nil, within: id, limit: 1, maxChars: 4_000)
        #expect(boosted.first?.segments.contains { $0.id == segs[25].id } == true, "the moment the user flagged ranks first")
    }

    @Test func aRemovedExpansionIsNotWrittenAgainByAPassOnlyByExpandAgain() async throws {
        let (fx, _, note) = try await ready()
        let key = TextKeys.norm("Q3 budget +10%")
        try await fx.store.saveExpansion(noteID: note, pass: .live, outcome: .sentences([sentence("Model.")]), sourceKey: key)
        try await fx.store.dismissExpansion(noteID: note)
        #expect(try await fx.store.saveExpansion(noteID: note, pass: .manual, outcome: .sentences([sentence("Back again.")]), sourceKey: key) == .kept)
        #expect(try await fx.store.expansion(of: note)?.state == .dismissed)
        #expect(try await fx.store.saveExpansion(noteID: note, pass: .manual, outcome: .sentences([sentence("Back again.")]), sourceKey: key, replacingEdited: true) == .written)
    }

    @Test func checkingASentenceClearsOnlyItsMarkAndHasAnUndo() async throws {
        let (fx, _, note) = try await ready()
        let key = TextKeys.norm("Q3 budget +10%")
        var shaky = sentence("Budget +15%.")
        shaky.unconfirmed = true
        try await fx.store.saveExpansion(noteID: note, pass: .closing, outcome: .sentences([shaky, sentence("Second.")]), sourceKey: key)
        try await fx.store.markSentenceChecked(noteID: note, index: 0)
        var e = try #require(try await fx.store.expansion(of: note))
        #expect(!e.sentences[0].unconfirmed && !e.userEdited, "the text is still the model's: a later pass may write it again")
        #expect(e.previous?.sentences[0].unconfirmed == true)
        try await fx.store.restorePreviousExpansion(noteID: note)
        e = try #require(try await fx.store.expansion(of: note))
        #expect(e.sentences[0].unconfirmed)
    }

    @Test func rewritingAnExpansionKeepsTheCitationsOnlyOfLinesTheModelWrote() async throws {
        let (fx, _, note) = try await ready()
        let key = TextKeys.norm("Q3 budget +10%")
        let first = sentence("Budget goes up.", seg: 1), second = sentence("Hiring waits.", seg: 2)
        try await fx.store.saveExpansion(noteID: note, pass: .closing, outcome: .sentences([first, second]), sourceKey: key)
        // Reordered, one kept as it was, one rewritten, one new.
        try await fx.store.editExpansion(noteID: note, text: "Hiring waits.\nBudget goes up a lot.\nMy own addition.")
        let e = try #require(try await fx.store.expansion(of: note))
        #expect(e.sentences.map(\.text) == ["Hiring waits.", "Budget goes up a lot.", "My own addition."])
        #expect(e.sentences[0].cites.first?.seg == 2, "the unchanged line keeps its own citation, not the one at its old position")
        #expect(e.sentences[1].cites.isEmpty && e.sentences[2].cites.isEmpty, "text the user wrote shows no transcript time")
    }
}
