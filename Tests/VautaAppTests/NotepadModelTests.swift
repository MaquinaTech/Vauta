// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

/// A database key kept in memory: these tests never touch the Keychain.
private final class MemoryKey: DatabaseKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    func existingKey() throws -> SymmetricKey? { lock.withLock { key } }
    func createKey() throws -> SymmetricKey { lock.withLock { let k = SymmetricKey(size: .bits256); key = k; return k } }
    func remove() throws { lock.withLock { key = nil } }
    func replace(with key: SymmetricKey) throws { lock.withLock { self.key = key } }
}

/// A real (temporary, in-memory-key) store with one meeting, and a notes model wired to it the way Meetings wires it.
@MainActor
private final class Pad {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-pad-\(UUID().uuidString)", isDirectory: true)
    let store: MeetingStore
    let meeting: Int64
    let model = NotepadModel()
    let undo = UndoManager()
    var problems: [String] = []

    init(notes: [String] = []) async throws {
        store = try MeetingStore(directory: dir, keyStore: MemoryKey())
        meeting = try await store.startMeeting(at: .now)
        try await store.append(Segment(channel: .others, start: 0, end: 8, text: "We will raise the Q3 budget by ten percent", isFinal: true), to: meeting)
        for (i, text) in notes.enumerated() { try await store.addNote(meeting, at: Double(10 + i * 10), text: text) }
        model.store = store
        model.meetingID = meeting
        model.addedAfter = true
        model.undoManager = undo
        model.offset = { 100 }
        model.report = { [weak self] title, _ in self?.problems.append(title) }
        model.bannerDuration = .milliseconds(40)
        await model.reload(markUpdates: false)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func texts() async throws -> [String] { try await store.notes(meeting).map(\.text) }

    /// ⌘Z / ⇧⌘Z and the steps they start.
    func undoStep() async { undo.undo(); await model.settled() }
    func redoStep() async { undo.redo(); await model.settled() }
}

@MainActor
@Suite("Notepad · notes model with a store")
struct NotepadModelTests {
    // MARK: Delete and undo

    @Test func undoOfADeleteStillWorksLongAfterTheBannerWentAwayAndIsNotATwoStepToggle() async throws {
        let pad = try await Pad(notes: ["first", "second"])
        let gone = try #require(pad.model.rows.first)
        let expansion = NoteExpansion.Sentence(text: "Written by the model.", cites: [.init(seg: 1, t: 2)], quote: "raise the Q3 budget")
        try await pad.store.saveExpansion(noteID: gone.id, pass: .closing, outcome: .sentences([expansion]), sourceKey: TextKeys.norm("first"))
        await pad.model.reload(markUpdates: false)

        await pad.model.delete(gone.id)
        #expect(try await pad.texts() == ["second"] && pad.model.deleted.count == 1)
        // The banner is gone (as after six seconds); the Edit menu still offers the undo.
        try await Task.sleep(for: .milliseconds(200))
        #expect(pad.model.deleted.isEmpty)
        #expect(pad.undo.canUndo)

        await pad.undoStep()
        #expect(try await pad.texts() == ["first", "second"], "⌘Z puts the note back after the banner is gone")
        #expect(pad.model.rows.first?.expansion?.sentences.first?.text == "Written by the model.", "with its expansion")
        #expect(!pad.undo.canUndo && pad.undo.canRedo, "the way back is the Redo, not a new Undo")

        await pad.redoStep()
        #expect(try await pad.texts() == ["second"], "⇧⌘Z deletes it again")
        #expect(!pad.undo.canRedo && pad.undo.canUndo)
    }

    @Test func twoDeletesAreUndoneInOrderAndTheBannerKeepsOneUndoPerNote() async throws {
        let pad = try await Pad(notes: ["A", "B", "C"])
        pad.model.bannerDuration = .seconds(30)
        let ids = pad.model.rows.map(\.id)
        await pad.model.delete(ids[0])
        await pad.model.delete(ids[1])
        #expect(pad.model.deleted.map(\.row.note.text) == ["A", "B"], "the second delete does not take away the first one's Undo")
        await pad.undoStep()
        #expect(try await pad.texts() == ["B", "C"])
        await pad.undoStep()
        #expect(try await pad.texts() == ["A", "B", "C"])

        // The banner's own Undo, then ⌘Z for the same note: nothing is restored twice.
        await pad.model.delete(ids[2])
        await pad.model.undoDelete(ids[2])
        #expect(try await pad.texts() == ["A", "B", "C"] && pad.model.deleted.isEmpty)
        await pad.undoStep()
        #expect(try await pad.texts() == ["A", "B", "C"], "already back: the undo step does not add a copy")
    }

    @Test func undoAfterAnAddedNoteRemovesItAndRedoBringsItBack() async throws {
        let pad = try await Pad(notes: ["first"])
        pad.model.draft = "typed during the call"
        pad.model.save()
        await pad.model.settled()
        #expect(try await pad.texts() == ["first", "typed during the call"])
        await pad.undoStep()
        #expect(try await pad.texts() == ["first"])
        await pad.redoStep()
        #expect(try await pad.texts() == ["first", "typed during the call"])
    }

    @Test func undoOfAnEditWalksBackThroughTheHistory() async throws {
        let pad = try await Pad(notes: ["draft one"])
        let id = try #require(pad.model.rows.first?.id)
        await pad.model.change(id, to: "draft two")
        await pad.model.change(id, to: "draft three")
        await pad.undoStep()
        #expect(try await pad.texts() == ["draft two"])
        await pad.undoStep()
        #expect(try await pad.texts() == ["draft one"])
        await pad.redoStep()
        #expect(try await pad.texts() == ["draft two"], "the first undo's redo is an edit, not another undo")
    }

    @Test func clearingTheWordsDeletesAtOnceWithUndoOrAsksWhereTheOwnerWantsAConfirmation() async throws {
        let pad = try await Pad(notes: ["first", "second"])
        let ids = pad.model.rows.map(\.id)
        var asked: [String] = []
        pad.model.confirmDelete = { asked.append($0.text) }
        await pad.model.change(ids[0], to: "   ")
        let kept = try await pad.texts()
        #expect(asked == ["first"] && kept == ["first", "second"], "Meetings: nothing is deleted before the user confirms")
        pad.model.confirmDelete = nil
        await pad.model.change(ids[1], to: "")
        let left = try await pad.texts()
        #expect(left == ["first"] && pad.model.deleted.count == 1, "the panel deletes and offers Undo")
    }

    // MARK: Failed saves

    @Test func aFailedAddPutsTheTextBackInFrontOfWhatWasTypedMeanwhile() async throws {
        let pad = try await Pad()
        pad.model.meetingID = 424_242   // no such meeting: the store refuses
        pad.model.draft = "important bullet"
        pad.model.save()
        pad.model.draft = "typed meanwhile"
        await pad.model.settled()
        #expect(pad.model.draft == "important bullet typed meanwhile")
        #expect(pad.problems == ["The note couldn’t be saved."])
    }

    @Test func aFailedEditGivesTheRewrittenWordsBackToTheField() async throws {
        let pad = try await Pad(notes: ["original"])
        let id = try #require(pad.model.rows.first?.id)
        pad.model.writeWords = { _, _ in throw CocoaError(.fileWriteUnknown) }
        pad.model.edit(id)
        pad.model.draft = "rewritten words"
        pad.model.save()
        await pad.model.settled()
        #expect(pad.model.draft == "rewritten words" && pad.model.editingID == id, "the edit is not lost")
        #expect(try await pad.texts() == ["original"] && !pad.problems.isEmpty)
    }

    // MARK: When the recording ends or the user leaves

    @Test func theNoteBeingTypedWhenTheRecordingEndsIsSavedAtThatMoment() async throws {
        let pad = try await Pad(notes: ["earlier"])
        pad.model.addedAfter = false
        pad.model.live = true
        pad.model.offset = { 321 }
        pad.model.draft = "last bullet as the call ends"
        #expect(await pad.model.flushPending())
        let notes = try await pad.store.notes(pad.meeting)
        #expect(notes.map(\.text) == ["earlier", "last bullet as the call ends"] && notes.last?.t == 321 && notes.last?.addedAfter == false)
        #expect(pad.model.draft.isEmpty)
    }

    @Test func anEditWithTheUpArrowIsAppliedWhenTheRecordingEnds() async throws {
        let pad = try await Pad(notes: ["Q3 budjet"])
        pad.model.live = true
        pad.model.editLast()
        pad.model.draft = "Q3 budget"
        #expect(await pad.model.flushPending())
        #expect(try await pad.texts() == ["Q3 budget"] && pad.model.editingID == nil && pad.model.draft.isEmpty)
    }

    @Test func ifTheLastNoteCannotBeSavedItStaysInTheField() async throws {
        let pad = try await Pad()
        pad.model.meetingID = 424_242
        pad.model.draft = "do not lose me"
        #expect(await pad.model.flushPending() == false)
        #expect(pad.model.draft == "do not lose me")
    }

    @Test func switchingMeetingsSavesTheEditAndTheUnsentNoteInTheMeetingTheyBelongTo() async throws {
        let pad = try await Pad(notes: ["teh note"])
        let row = try #require(pad.model.rows.first)
        pad.model.wordsDraft = "the note"
        pad.model.editingWordsID = row.id
        pad.model.draft = "added just before leaving"
        pad.model.commitPendingBeforeLeaving()
        #expect(pad.model.draft.isEmpty && pad.model.editingWordsID == nil)
        try await Task.sleep(for: .milliseconds(300))
        let notes = try await pad.store.notes(pad.meeting)
        #expect(notes.map(\.text).sorted() == ["added just before leaving", "the note"])
        #expect(notes.first { $0.text == "added just before leaving" }?.addedAfter == true)
    }

    // MARK: Expansions

    @Test func onlyNotesTypedAfterTheMeetingWithNothingYetAreExpandedWhenAMeetingIsOpened() async throws {
        let pad = try await Pad(notes: ["from the meeting"])
        pad.model.draft = "typed afterwards"
        pad.model.save()
        await pad.model.settled()
        let afterwards = try #require(pad.model.rows.first { $0.note.text == "typed afterwards" })
        #expect(pad.model.missingExpansionIDs == [afterwards.id], "browsing never sends the notes of the recording")
        try await pad.store.saveExpansion(noteID: afterwards.id, pass: .manual, outcome: .failed(code: "network"), sourceKey: TextKeys.norm("typed afterwards"))
        await pad.model.reload(markUpdates: false)
        #expect(pad.model.missingExpansionIDs.isEmpty, "a failed note is retried by the user, not on every open")
    }

    @Test func checkingASentenceKeepsItTheModelsAndOffersUndo() async throws {
        let pad = try await Pad(notes: ["budget"])
        let id = try #require(pad.model.rows.first?.id)
        let shaky = NoteExpansion.Sentence(text: "Budget +15%.", cites: [.init(seg: 1, t: 2)], quote: "raise the Q3 budget", unconfirmed: true)
        try await pad.store.saveExpansion(noteID: id, pass: .closing, outcome: .sentences([shaky]), sourceKey: TextKeys.norm("budget"))
        await pad.model.reload(markUpdates: false)
        await pad.model.markChecked(id, sentence: 0)
        var e = try #require(try await pad.store.expansion(of: id))
        #expect(!e.sentences[0].unconfirmed && !e.userEdited, "still written by the model: only the mark is gone")
        #expect(pad.model.status(of: try #require(pad.model.rows.first)) == .done)
        await pad.undoStep()
        e = try #require(try await pad.store.expansion(of: id))
        #expect(e.sentences[0].unconfirmed)
    }

    // MARK: VoiceOver

    @Test func theExpansionAnnouncementIsLimitedToOneInTwentySecondsAndSilentWhileTyping() async throws {
        let model = NotepadModel()
        let start = ContinuousClock.now
        #expect(model.claimsAnnouncement(at: start))
        #expect(!model.claimsAnnouncement(at: start + .seconds(19)))
        #expect(model.claimsAnnouncement(at: start + .seconds(21)))
        model.fieldFocused = true
        model.draft = "typing…"
        #expect(!model.claimsAnnouncement(at: start + .seconds(60)), "never while the user is typing")
        model.draft = ""
        #expect(model.claimsAnnouncement(at: start + .seconds(60)))
    }

    @Test func aNoteIsFiledInTheMeetingOpenWhenReturnWasPressedEvenIfAnotherOneIsShownBeforeItRuns() async throws {
        let pad = try await Pad(notes: ["earlier"])
        try await pad.store.endMeeting(pad.meeting, at: .now)
        let other = try await pad.store.startMeeting(at: .now)
        pad.model.draft = "follow up with Ana re pricing"
        pad.model.save()
        // A new recording starts before the queued save runs.
        pad.model.meetingID = other
        pad.model.rows = []
        await pad.model.settled()
        #expect(try await pad.texts() == ["earlier", "follow up with Ana re pricing"], "saved in meeting A")
        #expect(try await pad.store.notes(other).isEmpty, "nothing leaks into meeting B")
        #expect(pad.model.rows.isEmpty && pad.model.draft.isEmpty, "B's pad is left alone")
    }

    @Test func aDraftTypedAfterTheStopIsSavedInTheEndedMeetingBeforeTheNextRecordingStarts() async throws {
        let pad = try await Pad(notes: ["from the call"])
        pad.model.live = false
        pad.model.addedAfter = true
        pad.model.draft = "follow up w/ Ana re pricing"
        #expect(pad.model.hasPendingWork)
        #expect(await pad.model.flushPending(), "start() waits for this and only then resets the pad")
        #expect(try await pad.texts() == ["from the call", "follow up w/ Ana re pricing"])
        #expect(try await pad.store.notes(pad.meeting).last?.addedAfter == true)
        await pad.model.settled()
        #expect(!pad.model.hasPendingWork)
    }

    @Test func whatCannotBeSavedWhenLeavingAMeetingComesBackWhenItIsShownAgain() async throws {
        let pad = try await Pad()
        pad.model.meetingID = 424_242   // no such meeting: the store refuses
        pad.model.draft = "do not drop me"
        await pad.model.commitPendingBeforeLeaving()?.value
        #expect(pad.model.draft.isEmpty && !pad.problems.isEmpty)
        pad.model.meetingID = 424_242
        await pad.model.reload(markUpdates: false)
        #expect(pad.model.draft == "do not drop me")
    }

    @Test func anExpansionBeingRewrittenIsSavedWhenLeavingOrQuitting() async throws {
        let pad = try await Pad(notes: ["budget"])
        let id = try #require(pad.model.rows.first?.id)
        let model = NoteExpansion.Sentence(text: "Written by the model.", cites: [.init(seg: 1, t: 2)], quote: "raise the Q3 budget")
        try await pad.store.saveExpansion(noteID: id, pass: .closing, outcome: .sentences([model]), sourceKey: TextKeys.norm("budget"))
        await pad.model.reload(markUpdates: false)
        pad.model.editingExpansionID = id
        pad.model.expansionDraft = "My own wording."
        await pad.model.commitAndSettle()
        let saved = try #require(try await pad.store.expansion(of: id))
        #expect(saved.userEdited && saved.sentences.map(\.text) == ["My own wording."] && pad.model.editingExpansionID == nil)
    }

    // MARK: Undo of changes to an expansion

    @Test func eachExpansionStepRestoresExactlyWhatItReplacedOverSeveralSteps() async throws {
        let pad = try await Pad(notes: ["budget"])
        let id = try #require(pad.model.rows.first?.id)
        let first = NoteExpansion.Sentence(text: "B: the model wrote this.", cites: [.init(seg: 1, t: 2)], quote: "raise the Q3 budget")
        try await pad.store.saveExpansion(noteID: id, pass: .closing, outcome: .sentences([first]), sourceKey: TextKeys.norm("budget"))
        await pad.model.reload(markUpdates: false)

        await pad.model.saveExpansion(id, text: "C: my own words")   // B → C
        await pad.model.removeExpansion(id)                          // C → removed
        func shown() async throws -> (String?, NoteExpansion.State?) {
            let e = try await pad.store.expansion(of: id)
            return (e?.sentences.first?.text, e?.state)
        }
        #expect(try await shown().1 == .dismissed)
        await pad.undoStep()
        #expect(try await shown().0 == "C: my own words", "the first ⌘Z brings back the user's rewrite")
        await pad.undoStep()
        let original = try #require(try await pad.store.expansion(of: id))
        #expect(original.sentences.map(\.text) == [first.text] && !original.userEdited, "the second ⌘Z brings back the model's version")
        await pad.redoStep()
        #expect(try await shown().0 == "C: my own words")
        await pad.redoStep()
        #expect(try await shown().1 == .dismissed)
    }

    @Test func aChangeThatChangesNothingRegistersNoUndoStep() async throws {
        let pad = try await Pad(notes: ["budget"])
        let id = try #require(pad.model.rows.first?.id)
        let sure = NoteExpansion.Sentence(text: "Backed.", cites: [.init(seg: 1, t: 2)], quote: "raise the Q3 budget")
        try await pad.store.saveExpansion(noteID: id, pass: .closing, outcome: .sentences([sure]), sourceKey: TextKeys.norm("budget"))
        await pad.model.reload(markUpdates: false)
        pad.undo.removeAllActions()
        await pad.model.markChecked(id, sentence: 0)   // nothing was unconfirmed
        #expect(!pad.undo.canUndo)
    }

    // MARK: Shortcut

    @Test func theInMeetingShortcutsAreTakenOnlyWhileRecordingAndNeverSharedWithAnotherVautaShortcut() {
        #expect(RecorderModel.takesInMeetingKeys(recording: true) && !RecorderModel.takesInMeetingKeys(recording: false))
        let note = Preferences.defaultNoteHotKey, mark = Preferences.defaultMarkHotKey
        #expect(RecorderModel.mayRegister(note, besides: [mark], suspended: false))
        #expect(!RecorderModel.mayRegister(note, besides: [mark, note], suspended: false), "a conflict is reported, not registered")
        #expect(!RecorderModel.mayRegister(note, besides: [], suspended: true), "not while a shortcut field is listening")
    }

    // MARK: Search

    @Test func aSearchHitOnAnExpansionOpensTheNotesTabWithThatNoteInView() async throws {
        let pad = try await Pad(notes: ["budget"])
        let meetings = MeetingsModel(store: pad.store)
        let note = try #require(pad.model.rows.first?.id)
        for kind in [KnowledgeHit.Kind.noteExpansion, .note] {
            meetings.tab = .summary
            meetings.highlightedNote = nil
            meetings.open(KnowledgeHit(rowid: 1, kind: kind, refID: note, meetingID: pad.meeting, t: 12, snippet: "budget"))
            #expect(meetings.tab == .notes && meetings.highlightedNote == note)
        }
    }
}
