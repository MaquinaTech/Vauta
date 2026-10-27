// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Speakers in search and Ask: names in the chunk text, the re-embedding when they change, "what did Ana say"
/// ranking, the quotes on a person's card, and the schema 16 -> 17 step.
@Suite("Search and Ask with speakers")
struct SearchSpeakerTests {
    private func person(_ store: MeetingStore, _ name: String) async throws -> Int64 {
        try await store.saveEntity(EntityDraft(kind: .person, name: name))
    }

    // MARK: Chunk text

    @Test func chunkTextNamesWhoSpokeOnlyWhenTheNameIsSure() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        // Without speaker data: the channels, exactly as before.
        #expect(try await store.chunkPlan(m.meeting).first?.text.hasPrefix("Me: Good morning everyone\nOthers: Thanks") == true)
        try await m.finalize()
        let ana = try await person(store, "Ana")
        _ = try await store.assignSpeaker(try await m.speaker(.others, 1).id, toEntity: ana)
        let text = try #require(try await store.chunkPlan(m.meeting).first?.text).components(separatedBy: "\n")
        #expect(text[0] == "Me: Good morning everyone")
        #expect(text[1].hasPrefix("Ana: Thanks for joining"))
        #expect(text[2].hasPrefix("Others: Beta"), "a line said over somebody else gets no name")
        #expect(text[3].hasPrefix("Ana: Great"))
    }

    @Test func aGuessIsNeverEmbeddedUnderAName() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let id = try await store.startMeeting(at: .now)
        let a = try await store.append(segment(.others, 0, "We should move the launch"), to: id)
        let b = try await store.append(segment(.others, 3, "Agreed, next week"), to: id)
        try await store.endMeeting(id, at: .now + 60)
        try await store.finalizeSpeakers(meetingID: id, speakers: [SpeakerDraft(channel: .others, ordinal: 1)], assignments: [
            SegmentSpeakerAssignment(segmentID: a, channel: .others, ordinal: 1, confidence: 0.9),
            SegmentSpeakerAssignment(segmentID: b, channel: .others, ordinal: 1, confidence: 0.4)])
        let ana = try await person(store, "Ana")
        _ = try await store.assignSpeaker(try #require(try await store.speakers(of: id).first).id, toEntity: ana)
        let lines = try #require(try await store.chunkPlan(id).first?.text).components(separatedBy: "\n")
        #expect(lines == ["Ana: We should move the launch", "Others: Agreed, next week"])
    }

    @Test func aMeetingWithoutSpeakersNeverNeedsANewEmbedding() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        let plan = try await store.chunkPlan(m.meeting)
        // Chunks written before migration 17 have no key.
        try await store.replaceChunks(m.meeting, plan.map { ($0.start, $0.end, Data(repeating: 1, count: 4), 1, "") },
                                      space: EmbeddingSpace(model: "m", dimensions: 4))
        #expect(try await !store.chunksOutOfDate(m.meeting))
        // Speakers appear (a later separation) but nobody is named: the text is what it was.
        try await m.finalize()
        #expect(try await !store.chunksOutOfDate(m.meeting))
        try await store.replaceChunks(m.meeting, try await store.chunkPlan(m.meeting).map { ($0.start, $0.end, Data(repeating: 1, count: 4), 1, MeetingStore.textKey($0.text)) },
                                      space: EmbeddingSpace(model: "m", dimensions: 4))
        #expect(try await !store.chunksOutOfDate(m.meeting))
        // The user names a speaker: out of date again.
        _ = try await store.assignSpeaker(try await m.speaker(.others, 1).id, toEntity: try await person(store, "Ana"))
        #expect(try await store.chunksOutOfDate(m.meeting))
    }

    @Test func renamingASpeakerEmbedsTheMeetingAgain() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let space = EmbeddingSpace(model: "fake", dimensions: 6)
        let service = LLMService(store: store, providers: TestProviders(chat: nil, embedder: FakeEmbedder(space: space)))
        await service.start()
        #expect(await eventually {
            guard try await store.chunkSpaces()[m.meeting] == [space] else { return false }
            return try await !store.chunksOutOfDate(m.meeting)
        })

        let ana = try await person(store, "Ana")
        _ = try await store.assignSpeaker(try await m.speaker(.others, 1).id, toEntity: ana)
        #expect(try await store.chunksOutOfDate(m.meeting))
        await service.speakersChanged(meetingID: m.meeting)
        #expect(await eventually { try await !store.chunksOutOfDate(m.meeting) })
        #expect(try await store.chunkSpaces()[m.meeting] == [space])
        // Nothing to do the second time: no job is queued.
        #expect(await eventually { try await store.pendingJobCount() == 0 })
        await service.speakersChanged(meetingID: m.meeting)
        #expect(try await store.pendingJobCount() == 0)
    }

    @Test func aSpeakerEditedWhileTheMeetingIsBeingEmbeddedIsNotLost() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let space = EmbeddingSpace(model: "fake", dimensions: 6)
        let gate = EmbedGate()
        let providers = TestProviders(chat: nil, embedder: FakeEmbedder(space: space, gate: gate))
        let service = LLMService(store: store, providers: providers)
        await service.start()
        #expect(await eventually { try await store.chunkSpaces()[m.meeting] == [space] })

        // The first rename queues a job, which then waits for the slow embedding server.
        await gate.close()
        let speaker = try await m.speaker(.others, 1).id
        _ = try await store.assignSpeaker(speaker, toEntity: try await person(store, "Ana"))
        await service.speakersChanged(meetingID: m.meeting)
        #expect(await eventually { await gate.held > 0 })
        // The second arrives while that job is running: its own request to embed is ignored.
        _ = try await store.assignSpeaker(speaker, toEntity: try await person(store, "Ana García"))
        await service.speakersChanged(meetingID: m.meeting)
        await gate.release()
        #expect(await eventually {
            guard try await store.pendingJobCount() == 0 else { return false }
            return try await !store.chunksOutOfDate(m.meeting)
        })
        #expect(try await store.chunkPlan(m.meeting).first?.text.contains("Ana García: Thanks") == true)
    }

    @Test func renamingMergingOrDeletingAPersonEmbedsTheirMeetingsAgain() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let space = EmbeddingSpace(model: "fake", dimensions: 6)
        let service = LLMService(store: store, providers: TestProviders(chat: nil, embedder: FakeEmbedder(space: space)))
        // No handler set here: `start()` connects the service, as the app does.
        let ana = try await person(store, "Ana")
        _ = try await store.assignSpeaker(try await m.speaker(.others, 1).id, toEntity: ana)
        await service.start()
        #expect(await eventually {
            guard try await store.chunkSpaces()[m.meeting] == [space] else { return false }
            return try await !store.chunksOutOfDate(m.meeting)
        })
        _ = try await store.saveEntity(EntityDraft(id: ana, kind: .person, name: "Ana García"))
        #expect(await eventually {
            guard try await store.pendingJobCount() == 0 else { return false }
            return try await !store.chunksOutOfDate(m.meeting)
        })
        #expect(try await store.chunkPlan(m.meeting).first?.text.contains("Ana García: Thanks") == true)
        #expect(try await store.chunkSpaces()[m.meeting] == [space])
    }

    @Test func onlyAPersonNamedOnASpeakerTriggersTheCheck() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let calls = CallCounter()
        await store.setPeopleChangeHandler { calls.bump() }
        let ana = try await person(store, "Ana")
        let bruno = try await person(store, "Bruno")
        let project = try await store.saveEntity(EntityDraft(kind: .project, name: "Atlas"))
        _ = try await store.assignSpeaker(try await m.speaker(.others, 1).id, toEntity: ana)
        _ = try await store.saveEntity(EntityDraft(id: project, kind: .project, name: "Atlas 2"))
        _ = try await store.saveEntity(EntityDraft(id: bruno, kind: .person, name: "Bruno Ruiz"))
        try await store.deleteEntity(project)
        try await store.mergeEntity(bruno, into: try await person(store, "Carla"))
        #expect(calls.count == 0, "a project, and people nobody named on a speaker, change no chunk")
        _ = try await store.saveEntity(EntityDraft(id: ana, kind: .person, name: "Ana García"))
        #expect(calls.count == 1)
        try await store.mergeEntity(ana, into: try await person(store, "Carla"))
        #expect(calls.count == 2)
    }

    @Test func legacyChunksOfAnUnnamedSpeakerMeetingKeepTheirVectorsAndGetKeys() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let plan = try await store.chunkPlan(m.meeting)
        try await store.replaceChunks(m.meeting, plan.map { ($0.start, $0.end, Data(repeating: 1, count: 4), 1, "") },
                                      space: EmbeddingSpace(model: "m", dimensions: 4))
        #expect(try await !store.chunksOutOfDate(m.meeting), "the text is what it was: nothing to embed again")
        #expect(try await !store.chunksOutOfDate(m.meeting))
        // A name changes the text for real.
        _ = try await store.assignSpeaker(try await m.speaker(.others, 1).id, toEntity: try await person(store, "Ana"))
        #expect(try await store.chunksOutOfDate(m.meeting))
    }

    // MARK: Retrieval

    @Test func aQuestionAboutAPersonPrefersWhatTheirSpeakerSaid() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let id = try await store.startMeeting(at: .now)
        let bob = try await store.append(segment(.others, 0, "Budget"), to: id)
        let ana = try await store.append(segment(.others, 300, "We went through the whole plan and the budget came out fine in the end"), to: id)
        try await store.endMeeting(id, at: .now + 400)
        try await store.finalizeSpeakers(meetingID: id, speakers: [SpeakerDraft(channel: .others, ordinal: 1), SpeakerDraft(channel: .others, ordinal: 2)], assignments: [
            SegmentSpeakerAssignment(segmentID: bob, channel: .others, ordinal: 1, confidence: 0.9),
            SegmentSpeakerAssignment(segmentID: ana, channel: .others, ordinal: 2, confidence: 0.9)])
        let anaID = try await person(store, "Ana")
        let question = "What did Ana say about the budget?"
        let before = try await store.retrieve(question, queryVector: nil)
        #expect(before.first?.segments.first?.id == bob, "the shorter line ranks first by keywords alone")

        // A calendar-style suggestion is not a name: no boost.
        try await store.finalizeSpeakers(meetingID: id, speakers: [
            SpeakerDraft(channel: .others, ordinal: 1), SpeakerDraft(channel: .others, ordinal: 2, entityID: anaID, source: .suggested, confidence: 0.7)],
            assignments: [SegmentSpeakerAssignment(segmentID: bob, channel: .others, ordinal: 1, confidence: 0.9),
                          SegmentSpeakerAssignment(segmentID: ana, channel: .others, ordinal: 2, confidence: 0.9)])
        let suggested = try await store.retrieve(question, queryVector: nil)
        #expect(suggested.first?.segments.first?.id == bob, "a suggestion gives no boost")
        // The user confirms: now it is a name.
        let confirmed = try #require(try await store.speakers(of: id).first { $0.ordinal == 2 })
        _ = try await store.assignSpeaker(confirmed.id, toEntity: anaID)
        let after = try await store.retrieve(question, queryVector: nil)
        #expect(after.first?.segments.first?.id == ana)
        #expect(after.first?.speakers.first?.name == "Ana")
    }

    // MARK: A person's card

    @Test func quotesAreWhatTheNamedSpeakerSaidOnePerMeetingAndNeverAGuess() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let ana = try await person(store, "Ana")
        var ids: [Int64] = []
        for day in 0..<3 {
            let m = try await SpeakerMeeting.make(store, at: Date(timeIntervalSince1970: 1_800_000_000 + Double(day) * 86_400))
            try await m.finalize()
            _ = try await store.assignSpeaker(try await m.speaker(.others, 1).id, toEntity: ana)
            ids.append(m.meeting)
        }
        let quotes = try await store.spokenQuotes(ana)
        #expect(quotes.map(\.meeting.id) == ids.reversed(), "newest first, one per meeting")
        #expect(quotes.allSatisfy { $0.text == "Thanks for joining, shall we start with the launch plan" },
                "the longest line of the speaker; the one said over somebody else is not Ana's, the short one is skipped")
        #expect(try await store.spokenQuotes(ana, limit: 2).count == 2)
        // Another person, or somebody the user did not name: nothing.
        #expect(try await store.spokenQuotes(person(store, "Bea")).isEmpty)
    }

    @Test func aTalkativePersonDoesNotCrowdOutOlderMeetingsAndShortCJKLinesCount() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let ana = try await person(store, "Ana")
        // The oldest meeting has one Japanese line of 12 characters; the two newest have 400 long lines each.
        var meetings: [Int64] = []
        for day in 0..<3 {
            let id = try await store.startMeeting(at: Date(timeIntervalSince1970: 1_800_000_000 + Double(day) * 86_400))
            var assignments: [SegmentSpeakerAssignment] = []
            let lines = day == 0 ? 1 : 400
            for i in 0..<lines {
                let text = day == 0 ? "来週までに資料を送ります。" : "This is a long sentence number \(i) of a very talkative person"
                let seg = try await store.append(segment(.others, Double(i), text), to: id)
                assignments.append(SegmentSpeakerAssignment(segmentID: seg, channel: .others, ordinal: 1, confidence: 0.9))
            }
            try await store.endMeeting(id, at: Date(timeIntervalSince1970: 1_800_000_000 + Double(day) * 86_400 + 600))
            try await store.finalizeSpeakers(meetingID: id, speakers: [SpeakerDraft(channel: .others, ordinal: 1)], assignments: assignments)
            _ = try await store.assignSpeaker(try #require(try await store.speakers(of: id).first).id, toEntity: ana)
            meetings.append(id)
        }
        let quotes = try await store.spokenQuotes(ana)
        #expect(quotes.map(\.meeting.id) == meetings.reversed(), "all three meetings, newest first")
        #expect(quotes.last?.text == "来週までに資料を送ります。")
    }

    @Test func aSuggestedSpeakerIsNotQuotedUnderTheName() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        let ana = try await person(store, "Ana")
        try await store.finalizeSpeakers(meetingID: m.meeting, speakers: [
            SpeakerDraft(channel: .others, ordinal: 1, entityID: ana, source: .suggested, confidence: 0.7)], assignments: [
            SegmentSpeakerAssignment(segmentID: m.segments[1], channel: .others, ordinal: 1, confidence: 0.9)])
        #expect(try await m.speaker(.others, 1).source == .suggested)
        #expect(try await store.spokenQuotes(ana).isEmpty)
    }

    // MARK: Schema 17

    @Test func schema16StoreMigratesAndKeepsItsChunks() async throws {
        let fx = StoreFixture()
        try fx.writeLegacyStore(schema: 16) { db in
            try StoreFixture.legacyMeeting(db)
            try db.query("INSERT INTO chunks(meeting_id, start, end, model, dims, scale, emb) VALUES (1, 0, 5, 'm', 2, 1.0, ?)", [.blob(Data([1, 2]))])
        }
        let store = try fx.open()
        #expect(try await store.pragma("user_version") == Schema.currentVersion)
        #expect(try await store.columnNames("chunks").last == "text_key")
        #expect(try await store.chunkSpaces()[1] == [EmbeddingSpace(model: "m", dimensions: 2)])
        #expect(try await !store.chunksOutOfDate(1), "no speakers: the old chunk says what the transcript says")
    }
}


private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
