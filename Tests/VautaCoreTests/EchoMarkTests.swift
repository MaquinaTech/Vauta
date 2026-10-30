// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// `segments.echo`: the speakers' echo is marked on the Me lines of a finished meeting, kept and shown, and left out of whatever
/// reads the transcript as what was said. The person's word on a line wins and is never overridden.
@Suite("Storage: the speakers' echo in the microphone")
struct EchoMarkTests {
    private static let said = "We should move the launch of Kobaltix to the second week of March"
    private static let reply = "I think that is too late for the supplier of the shell"

    /// A meeting in which the microphone heard the other side (line 2) and the user then answered (line 3).
    private func meeting(_ f: KnowledgeFixture) async throws -> (id: Int64, others: Int64, echo: Int64, reply: Int64) {
        let s = f.store!
        let id = try await s.startMeeting(at: .now, locale: Locale(identifier: "en-US"))
        let others = try await s.append(Segment(channel: .others, start: 10, end: 14, text: Self.said, isFinal: true), to: id)
        let echo = try await s.append(Segment(channel: .me, start: 10.3, end: 14.2, text: Self.said.lowercased(), isFinal: true), to: id)
        let reply = try await s.append(Segment(channel: .me, start: 15, end: 19, text: Self.reply, isFinal: true), to: id)
        try await s.endMeeting(id, at: .now + 60)
        return (id, others, echo, reply)
    }

    @Test func anEchoIsKeptButLeftOutOfWhatWasSaid() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let m = try await meeting(f)
        #expect(try await s.echoes(of: m.id) == [m.echo], "marked when the recording ended")

        // The transcript shows it, marked; the rest leaves it out.
        let all = try await s.segments(of: m.id, echoes: true)
        #expect(all.map(\.id) == [m.others, m.echo, m.reply] && all.map(\.isEcho) == [false, true, false])
        #expect(try await s.segments(of: m.id).map(\.id) == [m.others, m.reply])
        #expect(try await s.citableSegments(m.id).map(\.id) == [m.others, m.reply], "the minutes, notes and answers")
        #expect(try await s.search("launch").map(\.segment.id) == [m.others], "search finds the words once, where they were said")
        let export = try #require(try await s.meetingExport(m.id))
        #expect(export.transcript.count == 2 && export.transcript.allSatisfy { $0.channel == .others || $0.text == Self.reply })
        #expect(try await s.markEchoes(m.id) == 0, "marking again changes nothing")
    }

    @Test func thePersonsWordOnALineWins() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let m = try await meeting(f)
        try await s.setEcho(m.echo, false)
        #expect(try await s.echoes(of: m.id).isEmpty)
        #expect(try await s.citableSegments(m.id).map(\.id) == [m.others, m.echo, m.reply])
        #expect(try await s.markEchoes(m.id) == 0, "a line the person said is theirs is never marked again")
        try await s.setEcho(m.echo, true)
        #expect(try await s.echoes(of: m.id) == [m.echo])
        // Only a Me line can be an echo.
        try await s.setEcho(m.others, true)
        #expect(try await s.echoes(of: m.id) == [m.echo])
    }

    @Test func anEchoIsNotTheUserTalking() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let m = try await meeting(f)
        try await s.finalizeSpeakers(meetingID: m.id, speakers: [SpeakerDraft(channel: .me, ordinal: 1), SpeakerDraft(channel: .others, ordinal: 1)],
                                     assignments: [SegmentSpeakerAssignment(segmentID: m.echo, channel: .me, ordinal: 1),
                                                   SegmentSpeakerAssignment(segmentID: m.reply, channel: .me, ordinal: 1),
                                                   SegmentSpeakerAssignment(segmentID: m.others, channel: .others, ordinal: 1)])
        func myTalk() async throws -> Double { try #require(try await s.speakers(of: m.id).first { $0.channel == .me }).talkSeconds }
        #expect(abs(try await myTalk() - 4) < 0.01, "only the reply")
        try await s.setEcho(m.echo, false)
        #expect(abs(try await myTalk() - 7.9) < 0.01)
        try await s.setEcho(m.echo, true)
        #expect(abs(try await myTalk() - 4) < 0.01)
    }

    /// Over headphones the microphone was measured never to hear the others (`SpeakerEcho.neverHeard`): a line that says the same
    /// at the same time is the user's.
    @Test func overHeadphonesNothingIsMarked() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let id = try await s.startMeeting(at: .now, locale: Locale(identifier: "en-US"))
        try await s.append(Segment(channel: .others, start: 10, end: 14, text: Self.said, isFinal: true), to: id)
        try await s.append(Segment(channel: .me, start: 10.3, end: 14.2, text: Self.said.lowercased(), isFinal: true), to: id)
        try await s.endMeeting(id, at: .now + 60, marksEchoes: false)
        #expect(try await s.echoes(of: id).isEmpty)
    }

    /// The minutes never see an echo, so no task comes from one: a citation of the echo is dropped like a made-up line, and "Me"
    /// on the other side's own line is no owner. Both extractions.
    @Test func noTaskGoesToTheUserFromAnEcho() async throws {
        for extraction in [MinutesExtraction.legacy, .shipped] {
            let f = try KnowledgeFixture()
            let s = f.store!
            let id = try await s.startMeeting(at: .now, locale: Locale(identifier: "en-US"))
            let commitment = "I'll send the contract to legal on Friday"
            let others = try await s.append(Segment(channel: .others, start: 10, end: 14, text: commitment, isFinal: true), to: id)
            let echo = try await s.append(Segment(channel: .me, start: 10.3, end: 14.2, text: commitment.lowercased(), isFinal: true), to: id)
            try await s.append(Segment(channel: .me, start: 15, end: 19, text: Self.reply, isFinal: true), to: id)
            try await s.endMeeting(id, at: .now + 60)
            #expect(try await s.echoes(of: id) == [echo])
            let json = """
                {"title": "Contract", "summary": "The contract goes to legal.", "topics": [], "decisions": [], "entities": [], "open_questions": [],
                 "tasks": [{"text": "Send the contract to legal", "owner": "Me", "seg": \(echo), "quote": "send the contract to legal"},
                           {"text": "Get the contract to legal by Friday", "owner": "Me", "seg": \(others), "quote": "send the contract to legal on Friday"}]}
                """
            let chat = ScriptedChat { _, _, _ in ScriptedChat.reply(json) }
            let service = LLMService(store: s, providers: TestProviders(chat: chat))
            await service.setMinutesExtraction(extraction)
            let events = EventLog()
            await service.setJobEventHandler { events.append($0) }
            await service.regenerateMinutes(id)
            #expect(await eventually { events.events.contains { $0.meetingID == id && $0.kind == .minutes } })
            await service.waitUntilQueueIdle()
            #expect(!chat.calls.isEmpty && chat.calls.allSatisfy { !$0.text.contains(commitment.lowercased()) }, "the prompt never holds the echo")
            let tasks = try await s.tasks(id)
            let me = try await s.selfEntity()
            #expect(tasks.map(\.segmentID) == [others], "\(extraction): the task cited on the echo is dropped")
            #expect(tasks.allSatisfy { $0.ownerID != me }, "\(extraction): nobody's task goes to the user")
        }
    }

    @Test func aMeetingWithoutTheOtherChannelHasNoEchoes() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let id = try await s.startMeeting(at: .now, locale: Locale(identifier: "en-US"))
        try await s.append(Segment(channel: .me, start: 10, end: 14, text: Self.said, isFinal: true), to: id)
        try await s.endMeeting(id, at: .now + 60)
        #expect(try await s.markEchoes(id) == 0)
    }

    // MARK: Meetings recorded before

    /// Migration 33 lists the finished meetings of a store from before echoes were marked. Not a meeting still open (the crash
    /// recovery adds it), one whose transcript is gone, or one with a line already marked or said to be the person's.
    @Test func migration33ListsTheMeetingsRecordedBefore() throws {
        let db = try SQLiteDatabase(image: nil, size: 0)
        try Schema.migrate(db, upTo: 32)
        try db.query("INSERT INTO meetings(id, started_at, ended_at) VALUES (1, 0, 60), (2, 100, 160), (3, 200, NULL), (4, 300, 360), (5, 400, 460)")
        try db.query("UPDATE meetings SET raw_purged_at = 500 WHERE id = 4")
        try db.query("INSERT INTO segments(meeting_id, speaker, start, end, text, echo) VALUES (1, 'Yo', 0, 2, 'hola', 0), (2, 'Yo', 0, 2, 'hola', 2)")
        try Schema.migrate(db, upTo: 33)
        #expect(try db.query("SELECT meeting_id FROM echo_pending ORDER BY meeting_id").map { $0.int(0) } == [1, 5])
        #expect(throws: Never.self) { try BackupSchemaGuard.validate(db) }
        try db.query("DELETE FROM meetings WHERE id = 1")
        #expect(try db.query("SELECT meeting_id FROM echo_pending").map { $0.int(0) } == [5], "a deleted meeting leaves the list")
    }

    @Test func theMeetingsRecordedBeforeAreCheckedOnce() async throws {
        let fx = StoreFixture()
        try fx.writeLegacyStore(schema: 32) { db in
            // Recent: older meetings go with the retention when the store opens.
            let now = Date.now.timeIntervalSince1970
            try db.query("INSERT INTO meetings(id, started_at, ended_at, locale) VALUES (1, ?, ?, 'en-US')", [.real(now - 3600), .real(now)])
            try db.query("INSERT INTO segments(id, meeting_id, speaker, start, end, text) VALUES (1, 1, 'Otros', 10, 14, ?), (2, 1, 'Yo', 10.3, 14.2, ?), (3, 1, 'Yo', 15, 19, ?)",
                         [.text(Self.said), .text(Self.said.lowercased()), .text(Self.reply)])
        }
        var store: MeetingStore? = try fx.open(recover: true)
        #expect(try await store!.echoes(of: 1).isEmpty, "opening the store marks nothing yet")
        #expect(try await store!.markPendingEchoes() == 1)
        #expect(try await store!.echoes(of: 1) == [2])
        #expect(try await store!.markPendingEchoes() == 0, "once")
        try await store!.saveIfNeeded()
        store = nil
        store = try fx.open(recover: true)
        #expect(try await store!.echoes(of: 1) == [2])
        #expect(try await store!.rowCount("echo_pending") == 0)
    }

    /// A recording that crashed never reached `endMeeting`: its echoes are marked at the next launch with the earlier meetings'.
    @Test func aMeetingACrashLeftOpenIsCheckedAtTheNextLaunch() async throws {
        let fx = StoreFixture()
        var store: MeetingStore? = try fx.open()
        try await store!.flush()
        let id = try await store!.startMeeting(at: .now, locale: Locale(identifier: "en-US"))
        try await store!.append(Segment(channel: .others, start: 10, end: 14, text: Self.said, isFinal: true), to: id)
        let echo = try await store!.append(Segment(channel: .me, start: 10.3, end: 14.2, text: Self.said.lowercased(), isFinal: true), to: id)
        try await store!.saveIfNeeded()
        store = nil   // like kill -9: no endMeeting
        store = try fx.open(recover: true)
        #expect(try await store!.markPendingEchoes() == 1)
        #expect(try await store!.echoes(of: id) == [echo])
    }
}
