// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// A model server that has stopped answering.
private struct ServerDown: Error {}

/// A server translator that fails with `ServerDown` from the `failFrom`-th request on.
private final class FailingRefiner: RefiningTranslator, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let failFrom: Int

    init(failFrom: Int) { self.failFrom = failFrom }

    func refine(_ text: String, context: [TranslationExample]) async throws -> String {
        let n = lock.withLock { count += 1; return count }
        if n >= failFrom { throw ServerDown() }
        return "R(\(text))"
    }
}

/// A server translator whose every answer is unusable for these texts (an empty or looping answer).
private final class UnusableRefiner: RefiningTranslator, @unchecked Sendable {
    let unusable: Set<String>
    init(_ unusable: Set<String>) { self.unusable = unusable }

    func refine(_ text: String, context: [TranslationExample]) async throws -> String {
        if unusable.contains(text) { throw RefinementError.degenerate }
        return "R(\(text))"
    }
}

@Suite("Translated transcripts")
struct TranscriptTranslationTests {
    private let english = Locale.Language(identifier: "en")

    /// A finished Spanish meeting with these lines, Me and Others in turn.
    private func meeting(_ store: MeetingStore, _ lines: [String]) async throws -> (meeting: Int64, segments: [Int64]) {
        let meeting = try await store.startMeeting(at: .now, locale: Locale(identifier: "es-ES"))
        var ids: [Int64] = []
        for (i, text) in lines.enumerated() {
            ids.append(try await store.append(segment(i % 2 == 0 ? .me : .others, Double(i * 2), text), to: meeting))
        }
        try await store.endMeeting(meeting, at: .now + 60)
        return (meeting, ids)
    }

    private func shown(_ store: MeetingStore, _ meeting: Int64) async throws -> [Int64: String] {
        TranslationDisplay.texts(from: try await store.translations(of: meeting), preferred: "en")
    }

    // MARK: Store

    @Test func aTranslationShowsOnlyWhileItsLineReadsWhatWasTranslated() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let (m, ids) = try await meeting(store, ["Hola a todos", "Empezamos"])
        try await store.saveTranslation("Hello everyone", language: "en", of: ids[0])
        #expect(try await shown(store, m) == [ids[0]: "Hello everyone"])
        _ = try await store.correctSegment(ids[0], text: "Hola a todas")
        #expect(try await shown(store, m).isEmpty, "a translation of the words before the correction")
        // Translated again, the corrected line shows it; Restore Original hides it, since it is of the correction.
        _ = try await store.saveLineTranslations([.init(segmentID: ids[0], source: "Hola a todas", text: "Hello all")], language: "en", inMeeting: m)
        #expect(try await shown(store, m) == [ids[0]: "Hello all"])
        _ = try await store.restoreOriginalText(ids[0])
        #expect(try await shown(store, m).isEmpty)
        let lines = try await store.translationLines(of: m, language: "en")
        #expect(lines.map(\.stale) == [true, false])
        #expect(lines.map(\.translation) == [nil, nil])
    }

    @Test func aTranslationStoredBeforeSourcesComesBackWithRestoreOriginal() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let (m, ids) = try await meeting(store, ["Hola a todos"])
        // As version 37 stored it: no source, of what the transcriber wrote.
        try await store.execForTests("INSERT INTO segment_translations(segment_id, lang, text) VALUES (?, 'en', 'Hello everyone')", [.integer(ids[0])])
        #expect(try await shown(store, m) == [ids[0]: "Hello everyone"])
        _ = try await store.correctSegment(ids[0], text: "Hola a todas")
        #expect(try await shown(store, m).isEmpty)
        #expect(try await store.translationLines(of: m, language: "en").map(\.stale) == [true])
        _ = try await store.restoreOriginalText(ids[0])
        #expect(try await shown(store, m) == [ids[0]: "Hello everyone"])
    }

    @Test func linesToTranslateLeaveOutEchoesAndEmptyLines() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let (m, ids) = try await meeting(store, ["Uno", " ", "Tres", "Cuatro"])
        try await store.setEcho(ids[2], true)
        #expect(try await store.translationLines(of: m, language: "en").map(\.segmentID) == [ids[0], ids[3]])
    }

    @Test func aSavedTranslationNeedsItsLineUnchangedAndInTheMeeting() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let (m, ids) = try await meeting(store, ["Uno", "Dos"])
        let other = try await meeting(store, ["Otra"])
        let stored = try await store.saveLineTranslations([
            .init(segmentID: ids[0], source: "Uno", text: "One"),
            .init(segmentID: ids[1], source: "Dos antes", text: "Two before"),   // corrected meanwhile
            .init(segmentID: other.segments[0], source: "Otra", text: "Other"),   // another meeting
            .init(segmentID: ids[1], source: "Dos", text: ""),                    // nothing to store
        ], language: "en", inMeeting: m)
        #expect(stored == 1)
        #expect(try await shown(store, m) == [ids[0]: "One"])
        #expect(try await store.translations(of: other.meeting).isEmpty)
    }

    @Test func theMeetingBeingRecordedIsNotTranslatedThisWay() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await store.startMeeting(at: .now)
        let id = try await store.append(segment(.others, 0, "Hola"), to: m)
        await expectStoreError(.meetingInProgress) { _ = try await store.translationLines(of: m, language: "en") }
        await expectStoreError(.meetingInProgress) {
            _ = try await store.saveLineTranslations([.init(segmentID: id, source: "Hola", text: "Hi")], language: "en", inMeeting: m)
        }
    }

    @Test func aTranslationThatReadsAsItsLineIsNotShownButCounts() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let (m, ids) = try await meeting(store, ["OK", "Vale"])
        _ = try await store.saveLineTranslations([.init(segmentID: ids[0], source: "OK", text: "OK"),
                                                  .init(segmentID: ids[1], source: "Vale", text: "Okay")], language: "en", inMeeting: m)
        #expect(try await shown(store, m) == [ids[1]: "Okay"])
        #expect(try await store.translationLines(of: m, language: "en").map(\.translation) == ["OK", "Okay"])
    }

    // MARK: Apple's translation

    @Test func appleTranslatesTheLinesWithoutATranslationInBatches() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let lines = (1...30).map { "Frase \($0)" }
        let (m, ids) = try await meeting(store, lines)
        try await store.saveTranslation("Live one", language: "en", of: ids[1])
        let apple = StubTranslator()
        let progress = ProgressLog()
        let outcome = try await TranscriptTranslator(onDevice: apple, server: nil)
            .translate(m, into: english, store: store) { progress.add($0) }
        #expect(outcome == .init(translated: 29))
        #expect(apple.batches.map(\.count) == [24, 5])
        #expect(!apple.calls.contains("Frase 2"), "the line translated live keeps its translation")
        let texts = try await shown(store, m)
        #expect(texts.count == 30)
        #expect(texts[ids[0]] == "«Frase 1»")
        #expect(texts[ids[1]] == "Live one")
        #expect(progress.items == [.init(done: 0, total: 29), .init(done: 24, total: 29), .init(done: 29, total: 29)])
    }

    @Test func translateAgainRedoesEveryLineAndChangedOnlyTheCorrectedOnes() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let (m, ids) = try await meeting(store, ["Uno", "Dos", "Tres"])
        let apple = StubTranslator()
        let translator = TranscriptTranslator(onDevice: apple, server: nil)
        _ = try await translator.translate(m, into: english, store: store)
        _ = try await store.correctSegment(ids[1], text: "Dos y medio")
        // Only the corrected line: a line that never had a translation stays without one.
        let (other, otherIDs) = try await meeting(store, ["Sin traducir", "Corregida"])
        try await store.saveTranslation("Fixed", language: "en", of: otherIDs[1])
        _ = try await store.correctSegment(otherIDs[1], text: "Corregida ya")
        let changed = try await translator.translate(other, into: english, store: store, scope: .changed)
        #expect(changed.translated == 1)
        #expect(try await shown(store, other) == [otherIDs[1]: "«Corregida ya»"])
        let again = try await translator.translate(m, into: english, store: store, scope: .all)
        #expect(again.translated == 3)
        #expect(apple.calls.filter { $0 == "Uno" }.count == 2)
        #expect(try await shown(store, m)[ids[1]] == "«Dos y medio»")
    }

    @Test func aBatchThatFailsIsTranslatedLineByLine() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let (m, ids) = try await meeting(store, ["Uno", "Dos", "Tres"])
        let apple = StubTranslator()
        apple.failing = ["Dos"]
        let outcome = try await TranscriptTranslator(onDevice: apple, server: nil).translate(m, into: english, store: store)
        #expect(outcome == .init(translated: 2, missing: 1))
        #expect(try await shown(store, m) == [ids[0]: "«Uno»", ids[2]: "«Tres»"])
    }

    @Test func aBatchWhoseEveryLineFailsReportsTheError() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let (m, _) = try await meeting(store, ["Uno", "Dos"])
        let apple = StubTranslator()
        apple.failing = ["Uno", "Dos"]
        await #expect(throws: StubTranslator.Failure.self) {
            _ = try await TranscriptTranslator(onDevice: apple, server: nil).translate(m, into: english, store: store)
        }
    }

    // MARK: The model server

    @Test func theServerTranslatesEachLineWithTheLinesBefore() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let (m, ids) = try await meeting(store, ["Uno", "Dos", "Tres", "Cuatro", "Cinco"])
        let server = StubRefiner()
        let apple = StubTranslator()
        let outcome = try await TranscriptTranslator(onDevice: apple, server: server).translate(m, into: english, store: store)
        #expect(outcome == .init(translated: 5))
        #expect(apple.calls.isEmpty)
        #expect(server.calls.map(\.text) == ["Uno", "Dos", "Tres", "Cuatro", "Cinco"])
        #expect(server.calls[0].context.isEmpty)
        #expect(server.calls[4].context == [.init(source: "Dos", translation: "R(Dos)"), .init(source: "Tres", translation: "R(Tres)"),
                                            .init(source: "Cuatro", translation: "R(Cuatro)")])
        #expect(try await shown(store, m)[ids[4]] == "R(Cinco)")
    }

    @Test func aLineTheServerCantTranslateTakesApples() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let (m, ids) = try await meeting(store, ["Uno", "Dos", "Tres"])
        let apple = StubTranslator()
        let outcome = try await TranscriptTranslator(onDevice: apple, server: UnusableRefiner(["Dos"])).translate(m, into: english, store: store)
        #expect(outcome == .init(translated: 3))
        #expect(try await shown(store, m) == [ids[0]: "R(Uno)", ids[1]: "«Dos»", ids[2]: "R(Tres)"])
        // Without Apple's languages the line stays without one.
        let (other, _) = try await meeting(store, ["Uno", "Dos"])
        let alone = try await TranscriptTranslator(onDevice: nil, server: UnusableRefiner(["Dos"])).translate(other, into: english, store: store)
        #expect(alone == .init(translated: 1, missing: 1))
    }

    @Test func whenTheServerStopsAnsweringApplesTranslationDoesTheRest() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let (m, ids) = try await meeting(store, ["Uno", "Dos", "Tres", "Cuatro"])
        let apple = StubTranslator()
        let outcome = try await TranscriptTranslator(onDevice: apple, server: FailingRefiner(failFrom: 3)).translate(m, into: english, store: store)
        #expect(outcome.translated == 4)
        #expect(outcome.serverFailure != nil)
        #expect(apple.batches == [["Tres", "Cuatro"]])
        #expect(try await shown(store, m) == [ids[0]: "R(Uno)", ids[1]: "R(Dos)", ids[2]: "«Tres»", ids[3]: "«Cuatro»"])
        // Without Apple's languages the rest has none.
        let (other, _) = try await meeting(store, ["Uno", "Dos", "Tres"])
        let alone = try await TranscriptTranslator(onDevice: nil, server: FailingRefiner(failFrom: 2)).translate(other, into: english, store: store)
        #expect(alone.translated == 1)
        #expect(alone.missing == 2)
        #expect(alone.serverFailure != nil)
    }

    // MARK: Recording, cancelling, deleting

    @Test func nothingIsTranslatedWhileAMeetingIsRecorded() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let (m, _) = try await meeting(store, ["Uno", "Dos"])
        let recording = try await store.startMeeting(at: .now)
        let apple = StubTranslator()
        let progress = ProgressLog()
        let work = Task {
            try await TranscriptTranslator(onDevice: apple, server: nil, recordingPoll: .milliseconds(10))
                .translate(m, into: english, store: store) { progress.add($0) }
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(apple.calls.isEmpty)
        #expect(progress.items == [.init(done: 0, total: 0, waitingForRecording: true)], "it says why it waits")
        try await store.endMeeting(recording, at: .now)
        let outcome = try await work.value
        #expect(outcome.translated == 2)
        #expect(progress.items.last == .init(done: 2, total: 2))
    }

    @Test func stoppingKeepsWhatWasStored() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let (m, ids) = try await meeting(store, ["Uno", "Dos", "Tres"])
        let server = StubRefiner()
        let hold = StubGate()
        server.holds = ["Dos": hold]
        let work = Task { try await TranscriptTranslator(onDevice: nil, server: server).translate(m, into: english, store: store) }
        #expect(await eventually { server.calls.count == 2 })
        work.cancel()
        await #expect(throws: CancellationError.self) { _ = try await work.value }
        #expect(try await shown(store, m) == [ids[0]: "R(Uno)"])
        #expect(!server.calls.map(\.text).contains("Tres"))
    }

    @Test func aMeetingDeletedMeanwhileStopsTheWork() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let (m, _) = try await meeting(store, ["Uno", "Dos", "Tres"])
        let server = StubRefiner()
        let hold = StubGate()
        server.holds = ["Dos": hold]
        let work = Task { try await TranscriptTranslator(onDevice: nil, server: server).translate(m, into: english, store: store) }
        #expect(await eventually { server.calls.count == 2 })
        try await store.deleteMeeting(m)
        hold.open()
        await #expect(throws: CancellationError.self) { _ = try await work.value }
        #expect(!server.calls.map(\.text).contains("Tres"))
    }

    // MARK: Splits and exports

    @Test func aSplitLineKeepsATranslationOfEachPart() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let (m, ids) = try await meeting(store, ["Hola a todos. Empezamos ya", "Vale"])
        _ = try await store.saveLineTranslations([.init(segmentID: ids[0], source: "Hola a todos. Empezamos ya", text: "Hello everyone. Let's start now"),
                                                  .init(segmentID: ids[1], source: "Vale", text: "Okay")], language: "en", inMeeting: m)
        // As the speaker analysis splits a line (not the person, whose split drops the translations).
        let split = try await store.splitForTests(ids[0], atCharacter: 13)
        let texts = try await shown(store, m)
        #expect(texts[ids[0]] == "Hello everyone.")
        #expect(texts[split.rightID] == "Let's start now")
        #expect(try await store.translationLines(of: m, language: "en").allSatisfy { $0.translation != nil && !$0.stale })
        try await store.undo(split.undo)
        #expect(try await shown(store, m) == [ids[0]: "Hello everyone. Let's start now", ids[1]: "Okay"])
        #expect(try await store.translationLines(of: m, language: "en").allSatisfy { !$0.stale })
    }

    @Test func anExportSaysWhichLanguageItsTranslationIsIn() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let (m, ids) = try await meeting(store, ["Hola", "Adiós"])
        _ = try await store.saveLineTranslations([.init(segmentID: ids[0], source: "Hola", text: "Hello")], language: "en", inMeeting: m)
        _ = try await store.saveLineTranslations([.init(segmentID: ids[0], source: "Hola", text: "Bonjour"),
                                                  .init(segmentID: ids[1], source: "Adiós", text: "Au revoir")], language: "fr", inMeeting: m)
        // The language the transcript shows wins over the one with the most lines.
        let export = try #require(try await store.meetingExport(m, shownTranslation: "en"))
        #expect(export.translationLanguage == "en")
        #expect(export.transcript.map(\.translation) == ["Hello", nil])
        let options = MeetingExportOptions(includeTranscript: true, includeTranslation: true)
        let json = try MeetingExportJSON.encode(export, options: options)
        #expect(json.contains("\"translationLanguage\" : \"en\""))
        #expect(MeetingExportRenderer.markdown(export, options: options).contains(try #require(MeetingExportRenderer.translationNote(export, options: options))))
        let without = MeetingExportOptions(includeTranscript: true, includeTranslation: false)
        #expect(try !MeetingExportJSON.encode(export, options: without).contains("translationLanguage"))
        #expect(MeetingExportRenderer.translationNote(export, options: without) == nil)
        let most = try #require(try await store.meetingExport(m))
        #expect(most.translationLanguage == "fr")
    }

    @Test func theLanguageChosenShowsEvenBeforeItsFirstLine() {
        let stored = [MeetingStore.StoredTranslation(segmentID: 1, language: "en", text: "Hello"),
                      MeetingStore.StoredTranslation(segmentID: 2, language: "en", text: "Bye"),
                      MeetingStore.StoredTranslation(segmentID: 1, language: "fr", text: "Bonjour")]
        #expect(TranslationDisplay.chooseLanguage(from: stored, preferred: "fr") == "en")
        #expect(TranslationDisplay.chooseLanguage(from: stored, preferred: nil, chosen: "de") == "de")
        #expect(TranslationDisplay.texts(from: stored, preferred: nil, chosen: "de").isEmpty)
        #expect(TranslationDisplay.languages(in: stored) == ["en", "fr"])
    }
}

extension MeetingStore {
    /// A split as the speaker analysis makes it: the translations are cut with the line.
    func splitForTests(_ segmentID: Int64, atCharacter offset: Int) throws -> (rightID: Int64, undo: SpeakerUndo) {
        try transaction { try splitInTransaction(segmentID, atCharacter: offset, time: nil, rightSpeaker: nil, byUser: false) }
    }
}

/// What a translation reported, in order.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [TranscriptTranslator.Progress] = []
    var items: [TranscriptTranslator.Progress] { lock.withLock { _items } }
    func add(_ progress: TranscriptTranslator.Progress) { lock.withLock { _items.append(progress) } }
}
