// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// `deleteSegments`: a highlighted stretch of lines goes together, in one transaction and one write, and leaves no trace; lines of
/// two meetings, a line already gone and the meeting being recorded are refused, and then no line goes.
@Suite("Storage: deleting a stretch of transcript lines")
struct DeleteStretchTests {
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

    private func decision(_ store: MeetingStore, _ meeting: Int64, _ segment: Int64, _ text: String) async throws -> Int64 {
        try await store.execForTests("INSERT INTO decisions(meeting_id, segment_id, t, text, source, created_at) VALUES (?, ?, 0, ?, 'llm', 1000)",
                                     [.integer(meeting), .integer(segment), .text(text)])
        return try #require(try await store.intsForTests("SELECT max(id) FROM decisions").first)
    }

    @Test func aStretchGoesTogetherAndLeavesNoTrace() async throws {
        let fx = StoreFixture()
        var store: MeetingStore! = try fx.open()
        let m = try await meeting(store, ["We start with the agenda", "The zzcodexq is zzfalconxq", "Its zzpricexq is zzsecretxq", "Back to the budget"])
        let (first, gone, kept) = (m.lines[0], [m.lines[1], m.lines[2]], m.lines[3])
        try await store.correctSegment(gone[1], text: "Its zzpricexq is zzhiddenxq")
        try await store.saveTranslation("El zzcodigoxq es halcón", language: "es", of: gone[0])
        try await store.execForTests("""
            INSERT INTO detected_questions(meeting_id, segment_id, t, channel, text, outcome, kept, created_at, updated_at)
            VALUES (?, ?, 0, 'others', 'Is the zzpricexq final?', 'no_answer', 1, 0, 0)
            """, [.integer(m.id), .integer(gone[1])])
        let fromStretch = try await decision(store, m.id, gone[0], "Use the code")
        let fromKept = try await decision(store, m.id, kept, "The budget is agreed")
        try await store.execForTests("INSERT INTO notes(meeting_id, t, text) VALUES (?, 1, 'code')", [.integer(m.id)])
        let note = try #require(try await store.intsForTests("SELECT max(id) FROM notes").first)
        // One sentence cites both lines of the stretch and one line that stays; its quote comes from the stretch.
        let sentences = [NoteExpansion.Sentence(text: "The price is set", cites: [.init(seg: gone[0], t: 10), .init(seg: gone[1], t: 20), .init(seg: kept, t: 30)],
                                                quote: "zzpricexq is zzhiddenxq"),
                         NoteExpansion.Sentence(text: "The agenda comes first", cites: [.init(seg: first, t: 0)])]
        try await store.execForTests("""
            INSERT INTO note_expansions(note_id, meeting_id, state, pass, sentences, plain, source_key, updated_at) VALUES (?, ?, 'done', 'final', ?, 'x', 'code', 0)
            """, [.integer(note), .integer(m.id), .text(MeetingStore.encode(sentences))])
        try await store.execForTests("INSERT INTO chunks(meeting_id, start, end, model, dims, scale, emb) VALUES (?, 0, 38, 'm', 1, 1, x'01')", [.integer(m.id)])
        #expect(try await store.imageContains("zzfalconxq"))
        #expect(try await store.imageContains("zzsecretxq"))

        // In any order: the stretch is a set of lines.
        let deletion = try await store.deleteSegments(gone.reversed())
        #expect(deletion == .init(meetingID: m.id, marked: 2), "the model's decision and one sentence")
        #expect(try await store.segments(of: m.id).map(\.id) == [first, kept])
        #expect(try await store.search("zzpricexq").isEmpty)
        #expect(try await store.detectedQuestions(m.id).isEmpty, "the question heard in the stretch goes with it")
        let words = ["zzcodexq", "zzfalconxq", "zzpricexq", "zzsecretxq", "zzhiddenxq", "zzcodigoxq"]
        for word in words {
            #expect(try await !store.imageContains(word), "\(word): no trace in the tables, the indexes or free pages")
        }
        #expect(try await store.intsForTests("SELECT count(*) FROM chunks") == [0], "the meeting is embedded again from what is left")
        let decisions = try await store.decisions(m.id)
        #expect(decisions.first { $0.id == fromStretch }?.unconfirmedReason == UnconfirmedReason.deleted)
        #expect(decisions.first { $0.id == fromKept }?.unconfirmed == false)
        let expansion = try #require(try await store.expansion(of: note))
        #expect(expansion.sentences[0].cites.map(\.seg) == [kept] && expansion.sentences[0].quote.isEmpty && expansion.sentences[0].unconfirmed)
        #expect(!expansion.sentences[1].unconfirmed)

        store = nil
        store = try fx.open()
        for word in words {
            #expect(try await !store.imageContains(word), "\(word): nothing on disk either")
        }
    }

    @Test func aLongStretchGoesInOneStep() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await meeting(store, (0..<400).map { "Line number \($0) of the long meeting" })
        try await store.deleteSegments(Array(m.lines.dropFirst().dropLast()))
        #expect(try await store.segments(of: m.id).map(\.id) == [m.lines[0], m.lines[399]])
    }

    @Test func linesOfTwoMeetingsAreRefusedAndNoneGoes() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let a = try await meeting(store, ["One", "Two"])
        let b = try await meeting(store, ["Three"])
        await expectStoreError(.general) { _ = try await store.deleteSegments([a.lines[1], b.lines[0]]) }
        #expect(try await store.segments(of: a.id).count == 2)
        #expect(try await store.segments(of: b.id).count == 1)
    }

    @Test func aLineAlreadyGoneRefusesTheStretch() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await meeting(store, ["One", "Two", "Three"])
        try await store.deleteSegment(m.lines[1])
        await expectStoreError(.segmentGone) { _ = try await store.deleteSegments(m.lines) }
        await expectStoreError(.segmentGone) { _ = try await store.deleteSegments([]) }
        #expect(try await store.segments(of: m.id).map(\.id) == [m.lines[0], m.lines[2]], "the lines still there stay")
    }

    @Test func theMeetingBeingRecordedIsRefused() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let id = try await store.startMeeting(at: .now)
        var lines: [Int64] = []
        for i in 0..<3 {
            lines.append(try await store.append(Segment(channel: .me, start: Double(i), end: Double(i) + 1, text: "Live words \(i)", isFinal: true), to: id))
        }
        await expectStoreError(.meetingInProgress) { _ = try await store.deleteSegments(lines) }
        #expect(try await store.segments(of: id).count == 3)
    }
}
