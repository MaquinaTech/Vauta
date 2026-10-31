// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import CryptoKit
import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

private final class CorrectionKey: DatabaseKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    func existingKey() throws -> SymmetricKey? { lock.withLock { key } }
    func createKey() throws -> SymmetricKey { lock.withLock { let k = SymmetricKey(size: .bits256); key = k; return k } }
    func remove() throws { lock.withLock { key = nil } }
    func replace(with key: SymmetricKey) throws { lock.withLock { self.key = key } }
}

/// Correcting a transcript line in the Meetings window: Return on the highlighted line, saved when leaving the meeting, Restore
/// Original and Edit ▸ Undo.
@Suite("Meetings: correcting a transcript line")
@MainActor
struct TranscriptCorrectionModelTests {
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    private func meeting(_ store: MeetingStore, _ texts: [String]) async throws -> Int64 {
        let start = Date() - 86_400
        let id = try await store.startMeeting(at: start, locale: Locale(identifier: "en-US"))
        for (i, text) in texts.enumerated() {
            try await store.append(Segment(channel: .others, start: Double(i * 5), end: Double(i * 5 + 4), text: text, isFinal: true), to: id)
        }
        _ = try await store.endMeeting(id, at: start + 600)
        return id
    }

    @Test func aLineIsCorrectedRestoredAndTheCorrectionUndone() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-correct-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MeetingStore(directory: dir, keyStore: CorrectionKey())
        let id = try await meeting(store, ["The cubernetes cluster is ready", "Ana will deploy it"])
        let other = try await meeting(store, ["Another meeting"])

        let model = MeetingsModel(store: store)
        let undo = UndoManager()
        model.undoManager = undo
        await model.reload()
        model.selectedID = id
        try await until { model.transcript.count == 2 }
        model.tab = .transcript
        #expect(!model.canCorrectHighlight, "nothing highlighted")
        model.moveHighlight(by: 1)
        #expect(model.canCorrectHighlight)
        model.correctHighlight()
        #expect(model.lineDraft?.text == "The cubernetes cluster is ready")
        model.lineDraft?.text = "The Kubernetes cluster is ready"
        model.saveLineDraft()
        try await until { model.transcript.first?.originalText != nil }
        #expect(model.transcript.first?.text == "The Kubernetes cluster is ready")
        #expect(model.transcript.first?.originalText == "The cubernetes cluster is ready")
        #expect(undo.canUndo && undo.undoActionName == CorrectLineButton.title)

        undo.undo()
        try await until { model.transcript.first?.originalText == nil }
        #expect(model.transcript.first?.text == "The cubernetes cluster is ready")

        // A line being corrected is saved when the person leaves the meeting.
        let second = try #require(model.transcript.last)
        model.beginCorrecting(second)
        model.lineDraft?.text = "Anna will deploy it"
        model.selectedID = other
        #expect(model.lineDraft == nil)
        for _ in 0..<250 where (try await store.segments(of: id).last?.originalText) == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(try await store.segments(of: id).last?.text == "Anna will deploy it")

        model.selectedID = id
        try await until { model.transcript.count == 2 && model.transcript.last?.originalText != nil }
        await model.restoreOriginal(try #require(model.transcript.last))
        #expect(model.transcript.last?.text == "Ana will deploy it" && model.transcript.last?.originalText == nil)
        #expect(undo.undoActionName == CorrectedNote.restoreTitle)
    }

    @Test func theSameWordsAreCorrectedEverywhereWhenThePersonAccepts() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-correct-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MeetingStore(directory: dir, keyStore: CorrectionKey())
        let id = try await meeting(store, ["Ana will deploy it", "Ana agreed", "The end"])
        let model = MeetingsModel(store: store)
        let undo = UndoManager()
        model.undoManager = undo
        await model.reload()
        model.selectedID = id
        try await until { model.transcript.count == 3 }
        model.tab = .transcript
        model.beginCorrecting(model.transcript[0])
        model.lineDraft?.text = "Anna will deploy it"
        model.saveLineDraft()
        try await until { model.everywhereOffer != nil }
        let offer = try #require(model.everywhereOffer)
        #expect(offer.segmentID == model.transcript[0].id && offer.lines == 1)
        #expect(CorrectEverywhereNote.text(offer) == "Also elsewhere in this meeting: Ana → Anna")
        #expect(model.transcript[1].text == "Ana agreed", "nothing changes before the person accepts")

        await model.correctEverywhere()
        #expect(model.everywhereOffer?.isElsewhere != true, "at most the glossary is still offered")
        #expect(model.transcript.map(\.text) == ["Anna will deploy it", "Anna agreed", "The end"])
        #expect(undo.undoActionName == CorrectEverywhereNote.title)
        undo.undo()
        try await until { model.transcript[1].text == "Ana agreed" }
        #expect(model.transcript[0].text == "Anna will deploy it", "the line the person corrected stays")
    }

    @Test func aNewTermIsAddedToTheGlossaryWhenThePersonAccepts() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-correct-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MeetingStore(directory: dir, keyStore: CorrectionKey())
        let id = try await meeting(store, ["we deploy on cubernetes", "cubernetes is down"])
        let model = MeetingsModel(store: store)
        let undo = UndoManager()
        model.undoManager = undo
        var glossaryChanges = 0
        model.onGlossaryChanged = { glossaryChanges += 1 }
        await model.reload()
        model.selectedID = id
        try await until { model.transcript.count == 2 }
        model.tab = .transcript
        model.beginCorrecting(model.transcript[0])
        model.lineDraft?.text = "we deploy on Kubernetes"
        model.saveLineDraft()
        try await until { model.everywhereOffer != nil }
        #expect(model.everywhereOffer?.newTerms == ["Kubernetes"])
        #expect(CorrectEverywhereNote.announcement(try #require(model.everywhereOffer))
                == "Also elsewhere in this meeting: cubernetes → Kubernetes. Add “Kubernetes” to Glossary")

        await model.correctEverywhere()
        #expect(model.everywhereOffer?.isElsewhere == false && model.everywhereOffer?.newTerms == ["Kubernetes"], "the term stays offered")
        await model.addToGlossary("Kubernetes")
        #expect(model.everywhereOffer == nil)
        #expect(try await store.glossary().map(\.term) == ["Kubernetes"])
        #expect(glossaryChanges == 1 && undo.undoActionName == CorrectEverywhereNote.addTitle("Kubernetes"))
        undo.undo()
        for _ in 0..<250 where (try await store.glossary()).isEmpty == false { try await Task.sleep(for: .milliseconds(20)) }
        #expect(try await store.glossary().isEmpty)
        #expect(model.transcript.map(\.text) == ["we deploy on Kubernetes", "Kubernetes is down"], "only the term is taken back")
    }

    @Test func theMeetingBeingRecordedIsNotCorrected() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-correct-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MeetingStore(directory: dir, keyStore: CorrectionKey())
        let id = try await store.startMeeting(at: .now, locale: Locale(identifier: "en-US"))
        try await store.append(Segment(channel: .others, start: 0, end: 4, text: "Live words", isFinal: true), to: id)
        let model = MeetingsModel(store: store)
        await model.reload()
        model.activeMeetingID = id
        model.selectedID = id
        try await until { model.transcript.count == 1 }
        let line = try #require(model.transcript.first)
        #expect(!model.canCorrect(line))
        model.beginCorrecting(line)
        #expect(model.lineDraft == nil)
    }
}
