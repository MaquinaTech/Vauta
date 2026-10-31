// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// `MeetingStore.correctSegment`: the user corrects the words of a line. Everything that reads the transcript reads the correction,
/// what the transcriber wrote stays for Restore Original, and nothing the model wrote is rewritten: what relied on the old words is
/// marked until they come back.
@Suite("Storage: correcting a transcript line")
struct TranscriptEditTests {
    private static let cluster = "The cubernetes cluster is ready"
    private static let report = "Ana will send the report to the client tomorrow"
    private static let before = Date(timeIntervalSince1970: 1_000)
    private static let first = Date(timeIntervalSince1970: 2_000)
    private static let later = Date(timeIntervalSince1970: 3_000)

    private func meeting(_ store: MeetingStore, _ texts: [String] = [cluster, report]) async throws -> (id: Int64, lines: [Int64]) {
        let id = try await store.startMeeting(at: .now, locale: Locale(identifier: "en-US"))
        var lines: [Int64] = []
        for (i, text) in texts.enumerated() {
            let start = Double(i * 10)
            lines.append(try await store.append(Segment(channel: .others, start: start, end: start + 8, text: text, isFinal: true), to: id))
        }
        _ = try await store.endMeeting(id, at: .now + 120)
        return (id, lines)
    }

    private func line(_ store: MeetingStore, _ id: Int64, _ meeting: Int64) async throws -> MeetingStore.StoredSegment {
        try #require(try await store.segments(of: meeting).first { $0.id == id })
    }

    /// A decision or task the model wrote from a line, before it was corrected.
    private func item(_ store: MeetingStore, _ table: String, _ meeting: Int64, _ segment: Int64, _ text: String,
                      source: String = "llm", reason: String? = nil, at: Date = before) async throws -> Int64 {
        try await store.execForTests("""
            INSERT INTO \(table)(meeting_id, segment_id, t, text, source, created_at, unconfirmed, unconfirmed_reason) VALUES (?, ?, 0, ?, ?, ?, ?, ?)
            """, [.integer(meeting), .integer(segment), .text(text), .text(source), .real(at.timeIntervalSince1970),
                  .integer(reason == nil ? 0 : 1), reason.map { .text($0) }])
        return try #require(try await store.intsForTests("SELECT max(id) FROM \(table)").first)
    }

    private func reason(_ store: MeetingStore, _ meeting: Int64, decision id: Int64) async throws -> String? {
        try #require(try await store.decisions(meeting).first { $0.id == id }).unconfirmedReason
    }

    @Test func aCorrectionIsWhatTheMeetingSaysFromThenOn() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await meeting(store)
        let c = try #require(try await store.correctSegment(m.lines[0], text: "The Kubernetes cluster is ready\n"))
        #expect(!c.restored)
        var corrected = try await line(store, m.lines[0], m.id)
        #expect(corrected.text == "The Kubernetes cluster is ready" && corrected.originalText == Self.cluster)
        #expect(try await store.search("Kubernetes").map(\.segment.id) == [m.lines[0]], "search finds the correction")
        #expect(try await store.search("cubernetes").isEmpty, "and no longer the misheard word")
        try await store.correctSegment(m.lines[0], text: "The Kubernetes cluster is fully ready")
        corrected = try await line(store, m.lines[0], m.id)
        #expect(corrected.originalText == Self.cluster, "the original stays what the transcriber wrote")
        let restored = try #require(try await store.restoreOriginalText(m.lines[0]))
        #expect(restored.restored)
        corrected = try await line(store, m.lines[0], m.id)
        #expect(corrected.text == Self.cluster && corrected.originalText == nil)
        #expect(try await store.search("cubernetes").map(\.segment.id) == [m.lines[0]])
        #expect(try await store.restoreOriginalText(m.lines[0]) == nil, "nothing to restore")
    }

    @Test func nothingIsCorrectedWithoutAChange() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await meeting(store)
        #expect(try await store.correctSegment(m.lines[0], text: Self.cluster) == nil)
        #expect(try await store.correctSegment(m.lines[0], text: "  \(Self.cluster)  ") == nil)
        #expect(try await store.correctSegment(m.lines[0], text: " \n ") == nil, "taking a passage out is not a correction")
        #expect(try await line(store, m.lines[0], m.id).originalText == nil)
    }

    @Test func theMeetingBeingRecordedIsNotCorrected() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let id = try await store.startMeeting(at: .now, locale: Locale(identifier: "en-US"))
        let line = try await store.append(Segment(channel: .others, start: 0, end: 4, text: Self.cluster, isFinal: true), to: id)
        await #expect(throws: StoreError.self) { try await store.correctSegment(line, text: "The Kubernetes cluster is ready") }
    }

    @Test func whatTheModelWroteFromTheOldWordsIsMarkedUntilTheyComeBack() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await meeting(store)
        let line = m.lines[1]
        let named = try await item(store, "decisions", m.id, line, "Ana sends the report")
        let far = try await item(store, "decisions", m.id, line, "The client gets the report tomorrow")
        let mine = try await item(store, "decisions", m.id, line, "Ana owns the report", source: "user")
        let doubted = try await item(store, "decisions", m.id, line, "Ana sends three reports", reason: "figures")
        let task = try await item(store, "tasks", m.id, line, "Send the report to the client")
        let c = try #require(try await store.correctSegment(line, text: "Anna will send the report to the client tomorrow", now: Self.first))
        #expect(try await reason(store, m.id, decision: named) == UnconfirmedReason.edited)
        #expect(try await reason(store, m.id, decision: far) == nil, "the words it relies on did not change")
        #expect(try await reason(store, m.id, decision: mine) == nil, "what the user wrote is theirs")
        #expect(try await reason(store, m.id, decision: doubted) == "figures", "an earlier doubt keeps its reason")
        #expect(try await store.tasks(m.id).first { $0.id == task }?.unconfirmed == true, "the name is next to what the task says")
        #expect(c.marks.count == 2)
        // Another word changes later: the name still differs, so the mark stays.
        try await store.correctSegment(line, text: "Anna will send the report to the client tomorrow morning", now: Self.later)
        #expect(try await reason(store, m.id, decision: named) == UnconfirmedReason.edited)
        try await store.restoreOriginalText(line)
        #expect(try await reason(store, m.id, decision: named) == nil, "the words it was written from are back")
        #expect(try await store.tasks(m.id).first { $0.id == task }?.unconfirmed == false)
    }

    @Test func anItemWrittenAfterTheCorrectionIsJudgedByTheWordsItWasWrittenFrom() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await meeting(store)
        try await store.correctSegment(m.lines[1], text: "Anna will send the report to the client tomorrow", now: Self.first)
        // The minutes are written again, from the correction.
        let rewritten = try await item(store, "decisions", m.id, m.lines[1], "Anna sends the report", at: Self.later)
        try await store.restoreOriginalText(m.lines[1])
        #expect(try await reason(store, m.id, decision: rewritten) == UnconfirmedReason.edited, "it says Anna; the line says Ana again")
    }

    @Test func undoPutsTheLineAndItsMarksBack() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await meeting(store)
        let named = try await item(store, "decisions", m.id, m.lines[1], "Ana sends the report")
        try await store.saveTranslation("Ana enviará el informe al cliente mañana", language: "es", of: m.lines[1])
        let c = try #require(try await store.correctSegment(m.lines[1], text: "Anna will send the report to the client tomorrow"))
        #expect(try await store.translations(of: m.id).isEmpty, "the translation is of the words that were transcribed")
        try await store.undoCorrection(c)
        let line = try await line(store, m.lines[1], m.id)
        #expect(line.text == Self.report && line.originalText == nil)
        #expect(try await reason(store, m.id, decision: named) == nil)
        #expect(try await store.translations(of: m.id).count == 1)
        await #expect(throws: StoreError.self) { try await store.undoCorrection(c) }
        // A correction the line moved on from cannot be undone.
        let one = try #require(try await store.correctSegment(m.lines[1], text: "Anna will send the report"))
        try await store.correctSegment(m.lines[1], text: "Anna will send the final report")
        await #expect(throws: StoreError.self) { try await store.undoCorrection(one) }
        #expect(try await store.correctSegment(m.lines[1], text: "Anna will send the final report") == nil)
    }

    @Test func aCorrectedNameIsFoundInTheMeeting() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let project = try await store.saveEntity(EntityDraft(kind: .project, name: "Kobaltix"), source: "user")
        let m = try await meeting(store, ["We should move Cobaltix to the second week of March"])
        try await store.analyze(m.id)
        #expect(try await store.refs(project).isEmpty)
        try await store.correctSegment(m.lines[0], text: "We should move Kobaltix to the second week of March")
        #expect(try await store.refs(project).map(\.segmentID) == [m.lines[0]])
        #expect(try await store.suggestions(m.id).allSatisfy { $0.surface != "Cobaltix" }, "the misheard name is no longer offered")
    }

    @Test func quotesAndDetectedQuestionsFollowTheCorrection() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await meeting(store, ["Can Ana send the report to the client tomorrow?"])
        let line = m.lines[0]
        try await store.execForTests("INSERT INTO notes(meeting_id, t, text) VALUES (?, 1, 'report')", [.integer(m.id)])
        let note = try #require(try await store.intsForTests("SELECT max(id) FROM notes").first)
        let sentences = [NoteExpansion.Sentence(text: "Ana sends the report", cites: [.init(seg: line, t: 0)], quote: "Ana send the report"),
                         NoteExpansion.Sentence(text: "The client gets it tomorrow", cites: [.init(seg: line, t: 0)])]
        try await store.execForTests("""
            INSERT INTO note_expansions(note_id, meeting_id, state, pass, sentences, plain, source_key, updated_at) VALUES (?, ?, 'done', 'final', ?, 'x', 'report', 0)
            """, [.integer(note), .integer(m.id), .text(MeetingStore.encode(sentences))])
        try await store.execForTests("""
            INSERT INTO detected_questions(meeting_id, segment_id, t, channel, text, outcome, kept, created_at, updated_at)
            VALUES (?, ?, 0, 'others', 'Can Ana send the report to the client tomorrow?', 'no_answer', 1, 0, 0)
            """, [.integer(m.id), .integer(line)])
        try await store.correctSegment(line, text: "Can Anna send the report to the client tomorrow?")
        let expansion = try #require(try await store.expansion(of: note))
        #expect(expansion.sentences[0].quote == "Anna send the report")
        #expect(expansion.sentences[0].unconfirmed && expansion.sentences[0].edited)
        #expect(!expansion.sentences[1].unconfirmed, "a sentence the correction does not reach")
        #expect(try await store.detectedQuestions(m.id).map(\.text) == ["Can Anna send the report to the client tomorrow?"])
        try await store.restoreOriginalText(line)
        let back = try #require(try await store.expansion(of: note))
        #expect(back.sentences[0].quote == "Ana send the report" && !back.sentences[0].unconfirmed && !back.sentences[0].edited)
    }

    @Test func aSplitOfACorrectedLineKeepsEachPartsOriginal() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let transcribed = "so the cubernetes cluster is ready and Ana will deploy"
        let corrected = "so the Kubernetes cluster is ready and Anna will deploy"
        let m = try await meeting(store, [transcribed])
        try await store.correctSegment(m.lines[0], text: corrected)
        let split = try await store.splitSegment(m.lines[0], atCharacter: Array(corrected).firstIndex(of: "y")! + 2)
        var lines = try await store.segments(of: m.id)
        #expect(lines.map(\.text) == ["so the Kubernetes cluster is ready", "and Anna will deploy"])
        #expect(lines.map(\.originalText) == ["so the cubernetes cluster is ready", "and Ana will deploy"])
        try await store.restoreOriginalText(split.rightSegmentID)
        lines = try await store.segments(of: m.id)
        #expect(lines.map(\.text) == ["so the Kubernetes cluster is ready", "and Ana will deploy"])
        try await store.correctSegment(split.rightSegmentID, text: "and Anna will deploy")
        try await store.undo(split.undo)
        let joined = try await line(store, m.lines[0], m.id)
        #expect(joined.text == corrected && joined.originalText == transcribed, "undoing the split puts the whole line back")
    }

    @Test func aPartThatReadsAsTranscribedHasNoOriginal() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await meeting(store, ["the cluster is ready and Ana will deploy"])
        let corrected = "the cluster is ready and Anna will deploy"
        try await store.correctSegment(m.lines[0], text: corrected)
        try await store.splitSegment(m.lines[0], atCharacter: Array(corrected).firstIndex(of: "y")! + 2)
        #expect(try await store.segments(of: m.id).map(\.originalText) == [nil, "and Ana will deploy"])
    }
}
