// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// `deleteSegment`: a line taken out of the record leaves no trace in the store, in memory or on disk, and what the model wrote
/// from it is marked, not rewritten.
@Suite("Storage: deleting a transcript line for good")
struct DeleteLineTests {
    private func meeting(_ store: MeetingStore, _ texts: [String]) async throws -> (id: Int64, lines: [Int64]) {
        let id = try await store.startMeeting(at: .now, locale: Locale(identifier: "en-US"))
        var lines: [Int64] = []
        for (i, text) in texts.enumerated() {
            let start = Double(i * 10)
            lines.append(try await store.append(Segment(channel: .others, start: start, end: start + 8, text: text, isFinal: true), to: id))
        }
        _ = try await store.endMeeting(id, at: .now + 120)
        return (id, lines)
    }

    private func item(_ store: MeetingStore, _ table: String, _ meeting: Int64, _ segment: Int64, _ text: String,
                      source: String = "llm") async throws -> Int64 {
        try await store.execForTests("INSERT INTO \(table)(meeting_id, segment_id, t, text, source, created_at) VALUES (?, ?, 0, ?, ?, 1000)",
                                     [.integer(meeting), .integer(segment), .text(text), .text(source)])
        return try #require(try await store.intsForTests("SELECT max(id) FROM \(table)").first)
    }

    @Test func aDeletedLineLeavesNoTraceAndItsMinutesAreMarked() async throws {
        let fx = StoreFixture()
        var store: MeetingStore! = try fx.open()
        let m = try await meeting(store, ["The zzcodexq is zzfalconxq for the launch", "We agreed on the budget"])
        let (gone, kept) = (m.lines[0], m.lines[1])
        try await store.correctSegment(gone, text: "The zzcodexq is zzeaglexq for the launch")
        try await store.saveTranslation("El zzcodigoxq es águila", language: "es", of: gone)
        try await store.execForTests("""
            INSERT INTO detected_questions(meeting_id, segment_id, t, channel, text, outcome, kept, created_at, updated_at)
            VALUES (?, ?, 0, 'others', 'Is the zzcodexq ready?', 'no_answer', 1, 0, 0)
            """, [.integer(m.id), .integer(gone)])
        try await store.execForTests("""
            INSERT INTO follow_ups(meeting_id, segment_id, t, title, source, recipe, created_at) VALUES (?, ?, 0, 'zzcodexq review', 'detected', 1, 0)
            """, [.integer(m.id), .integer(gone)])
        let decision = try await item(store, "decisions", m.id, gone, "Launch with the eagle code")
        let other = try await item(store, "decisions", m.id, kept, "The budget is agreed")
        let mine = try await item(store, "decisions", m.id, gone, "Keep the code secret", source: "user")
        let task = try await item(store, "tasks", m.id, gone, "Share the code")
        try await store.execForTests("INSERT INTO notes(meeting_id, t, text) VALUES (?, 1, 'code')", [.integer(m.id)])
        let note = try #require(try await store.intsForTests("SELECT max(id) FROM notes").first)
        let sentences = [NoteExpansion.Sentence(text: "The code is set", cites: [.init(seg: gone, t: 0), .init(seg: kept, t: 10)], quote: "zzcodexq is zzeaglexq"),
                         NoteExpansion.Sentence(text: "The budget is agreed", cites: [.init(seg: kept, t: 10)])]
        try await store.execForTests("""
            INSERT INTO note_expansions(note_id, meeting_id, state, pass, sentences, plain, source_key, updated_at) VALUES (?, ?, 'done', 'final', ?, 'x', 'code', 0)
            """, [.integer(note), .integer(m.id), .text(MeetingStore.encode(sentences))])
        try await store.execForTests("INSERT INTO chunks(meeting_id, start, end, model, dims, scale, emb) VALUES (?, 0, 18, 'm', 1, 1, x'01')", [.integer(m.id)])
        #expect(try await store.imageContains("zzfalconxq"))
        #expect(try await store.imageContains("zzeaglexq"))

        let deletion = try await store.deleteSegment(gone)
        #expect(deletion == .init(meetingID: m.id, marked: 3), "the model's decision and task, and one sentence")
        #expect(try await store.segments(of: m.id).map(\.id) == [kept])
        #expect(try await store.search("zzcodexq").isEmpty)
        for word in ["zzcodexq", "zzfalconxq", "zzeaglexq", "zzcodigoxq"] {
            #expect(try await !store.imageContains(word), "\(word): no trace in the tables, the indexes or free pages")
        }
        #expect(try await store.intsForTests("SELECT count(*) FROM chunks") == [0], "the meeting is embedded again from what is left")

        let decisions = try await store.decisions(m.id)
        #expect(decisions.first { $0.id == decision }?.unconfirmedReason == UnconfirmedReason.deleted)
        #expect(decisions.first { $0.id == other }?.unconfirmed == false && decisions.first { $0.id == mine }?.unconfirmed == false)
        #expect(try await store.tasks(m.id).first { $0.id == task }?.unconfirmedReason == UnconfirmedReason.deleted)
        let expansion = try #require(try await store.expansion(of: note))
        #expect(expansion.sentences[0].cites.map(\.seg) == [kept] && expansion.sentences[0].quote.isEmpty && expansion.sentences[0].unconfirmed)
        #expect(!expansion.sentences[1].unconfirmed)

        store = nil
        store = try fx.open()
        for word in ["zzcodexq", "zzfalconxq", "zzeaglexq", "zzcodigoxq"] {
            #expect(try await !store.imageContains(word), "\(word): nothing on disk either")
        }
    }

    @Test func storedAnswersDropWhatTheLineSaid() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await meeting(store, ["The deadline is Friday", "The budget is set"])
        let cite = AutoAnswerContent.Cite(kind: .thisMeeting, segmentID: m.lines[0], meetingID: m.id, t: 0)
        let answer = AutoAnswerContent(answer: "Friday.", claims: [.init(text: "The deadline is Friday", cites: [cite])])
        try await store.execForTests("""
            INSERT INTO detected_questions(meeting_id, segment_id, t, channel, text, outcome, answer, kept, created_at, updated_at)
            VALUES (?, ?, 20, 'me', 'When is the deadline?', 'answered', ?, 1, 0, 0)
            """, [.integer(m.id), .integer(m.lines[1]), .text(String(decoding: try JSONEncoder().encode(answer), as: UTF8.self))])
        try await store.deleteSegment(m.lines[0])
        let question = try #require(try await store.detectedQuestions(m.id).first)
        #expect(question.answer?.claims.isEmpty != false, "the claim that rested on the line is gone")
        #expect(try await !store.imageContains("deadline is Friday"))
    }

    @Test func theMeetingBeingRecordedIsRefused() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let id = try await store.startMeeting(at: .now)
        let line = try await store.append(Segment(channel: .me, start: 0, end: 2, text: "Live words", isFinal: true), to: id)
        await #expect(throws: StoreError.self) { try await store.deleteSegment(line) }
        #expect(try await store.segments(of: id).count == 1)
    }
}
