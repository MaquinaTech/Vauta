// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Storage: speaker edits, locks and undo")
struct StorageSpeakerEditTests {
    private func person(_ store: MeetingStore, _ name: String, source: String = "user") async throws -> Int64 {
        try await store.saveEntity(EntityDraft(kind: .person, name: name), source: source)
    }

    private let consent = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Orphan cleanup

    @Test func aCalendarPersonUsedByASpeakerOrAProfileSurvivesDeletingAnotherMeeting() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        let other = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let carla = try await person(store, "Carla", source: "calendar")
        let idle = try await person(store, "Idle Guest", source: "calendar")
        #expect(try await store.entity(carla)?.confirmed == false)
        try await store.assignSpeaker(try await m.speaker(.others, 1).id, toEntity: carla)
        try await store.addVoiceProfile(entityID: carla, modelID: "m1", embedding: Data(repeating: 5, count: 16), consentRecordedAt: consent)
        try await store.deleteMeeting(other.meeting)
        let speaker = try await m.speaker(.others, 1)
        #expect(speaker.entityID == carla && speaker.source == .user, "the user's assignment is kept")
        #expect(try await store.voiceProfiles(entityID: carla).count == 1, "the enrolled profile is kept")
        #expect(try await store.entity(idle) == nil, "a calendar person nobody uses still goes")
    }

    // MARK: Locks and re-finalization

    @Test func aSegmentTheUserMovedIsNotMovedBackByANewDiarization() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let two = try await m.speaker(.others, 2)
        try await store.reassignSegment(m.segments[1], toSpeaker: two.id)
        try await m.finalize()
        let tags = try await store.segments(of: m.meeting).map(\.speaker)
        #expect(tags[1]?.ordinal == 2 && tags[1]?.confidence == nil, "the user's word stays")
        #expect(tags[3]?.ordinal == 1 && tags[2]?.ordinal == 2, "the rest follows the diarizer")
    }

    @Test func aMergeSurvivesANewDiarization() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        try await store.mergeSpeaker(try await m.speaker(.others, 2).id, into: try await m.speaker(.others, 1).id)
        try await m.finalize()
        #expect(try await store.segments(of: m.meeting).map { $0.speaker?.ordinal } == [1, 1, 1, 1])
        #expect(try await m.speaker(.others, 2).talkSeconds == 0, "the re-created speaker has no segments")
    }

    @Test func userNamesFollowTheirVoiceWhenTheNewClustersAreRenumbered() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let ana = try await person(store, "Ana")
        let anaRow = try await m.speaker(.others, 2)   // owns "Beta is stable and ready"
        try await store.assignSpeaker(anaRow.id, toEntity: ana)
        // The diarizer numbers the same voices the other way round.
        try await store.finalizeSpeakers(meetingID: m.meeting, speakers: [
            SpeakerDraft(channel: .me, ordinal: 1), SpeakerDraft(channel: .others, ordinal: 1), SpeakerDraft(channel: .others, ordinal: 2),
        ], assignments: [
            SegmentSpeakerAssignment(segmentID: m.segments[0], channel: .me, ordinal: 1),
            SegmentSpeakerAssignment(segmentID: m.segments[1], channel: .others, ordinal: 2),
            SegmentSpeakerAssignment(segmentID: m.segments[2], channel: .others, ordinal: 1),
            SegmentSpeakerAssignment(segmentID: m.segments[3], channel: .others, ordinal: 2),
        ])
        let segments = try await store.segments(of: m.meeting)
        #expect(segments[2].speaker?.name == "Ana", "Ana's words are still Ana's")
        #expect(segments[1].speaker?.name == nil && segments[3].speaker?.name == nil)
        #expect(segments[2].speaker?.id == anaRow.id)
        #expect(Set(try await store.speakers(of: m.meeting).filter { $0.channel == .others }.map(\.ordinal)).count == 2)
    }

    @Test func aNewDiarizationClearsSegmentsItNoLongerMentions() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        try await store.finalizeSpeakers(meetingID: m.meeting, speakers: [SpeakerDraft(channel: .others, ordinal: 1)],
                                         assignments: [SegmentSpeakerAssignment(segmentID: m.segments[1], channel: .others, ordinal: 1)])
        #expect(try await store.segments(of: m.meeting).map { $0.speaker?.ordinal } == [nil, 1, nil, nil])
        #expect(try await m.speaker(.others, 1).talkSeconds == 1)
    }

    @Test func anAssignmentToAnUndeclaredSpeakerIsRefusedAndWritesNothing() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        await #expect(throws: StoreError.self) {
            try await store.finalizeSpeakers(meetingID: m.meeting, speakers: [SpeakerDraft(channel: .others, ordinal: 1)],
                                             assignments: [SegmentSpeakerAssignment(segmentID: m.segments[1], channel: .others, ordinal: 5, overlap: true)])
        }
        #expect(try await store.speakers(of: m.meeting).isEmpty)
    }

    @Test func storesFrom010AreFinalizedToo() async throws {
        let fx = StoreFixture()
        try fx.writeLegacyStore(schema: 13)
        let store = try fx.open()
        try await store.finalizeSpeakers(meetingID: 1, speakers: [SpeakerDraft(channel: .me, ordinal: 1), SpeakerDraft(channel: .others, ordinal: 1)],
                                         assignments: [SegmentSpeakerAssignment(segmentID: 1, channel: .me, ordinal: 1),
                                                       SegmentSpeakerAssignment(segmentID: 2, channel: .others, ordinal: 1)])
        #expect(try await store.segments(of: 1).map { $0.speaker?.ordinal } == [1, 1])
        #expect(try await store.speakerCodes(1) == ["Yo", "Otros"], "the stored values are not rewritten")
    }

    @Test func aMergedPersonIsFollowedWhenFinalizing() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        let ana = try await person(store, "Ana"), anita = try await person(store, "Anita")
        try await store.mergeEntity(anita, into: ana)
        try await store.finalizeSpeakers(meetingID: m.meeting, speakers: [SpeakerDraft(channel: .others, ordinal: 1, entityID: anita, source: .suggested)])
        #expect(try await m.speaker(.others, 1).entityID == ana)
    }

    // MARK: Citations of a split

    @Test func aSplitMovesTheCitationsOfTheRightTextToTheRightPart() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let target = m.segments[1]   // "Thanks for joining, shall we start with the launch plan", 2…3
        let ana = try await person(store, "Ana")
        for (surface, t) in [("joining", 2.0), ("launch", 2.0)] {
            try await store.execForTests("""
                INSERT INTO mentions(entity_id, meeting_id, segment_id, t, surface, confidence, resolved_by) VALUES (?, ?, ?, ?, ?, 1, 'user')
                """, [.integer(ana), .integer(m.meeting), .integer(target), .real(t), .text(surface)])
        }
        for t in [2.0, 2.9] {
            try await store.execForTests("INSERT INTO tasks(meeting_id, segment_id, t, text, created_at) VALUES (?, ?, ?, 'x', 0)",
                                     [.integer(m.meeting), .integer(target), .real(t)])
        }
        let text = "Thanks for joining, shall we start with the launch plan"
        let offset = text.distance(from: text.startIndex, to: text.range(of: " shall")!.lowerBound)
        let split = try await store.splitSegment(target, atCharacter: offset, time: 2.5)
        let owner = { (sql: String) async throws -> [Int64] in try await store.intsForTests(sql) }
        #expect(try await owner("SELECT segment_id FROM mentions WHERE surface = 'joining'") == [target])
        #expect(try await owner("SELECT segment_id FROM mentions WHERE surface = 'launch'") == [split.rightSegmentID])
        #expect(try await owner("SELECT segment_id FROM tasks ORDER BY t") == [target, split.rightSegmentID])
        try await store.undo(split.undo)
        #expect(try await owner("SELECT DISTINCT segment_id FROM mentions UNION SELECT segment_id FROM tasks") == [target])
    }

    @Test func aSegmentOfAMeetingBeingRecordedCannotBeSplit() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let id = try await store.startMeeting(at: .now)
        let a = try await store.append(segment(.others, 0, "still being said here"), to: id)
        await #expect(throws: StoreError.self) { try await store.splitSegment(a, atCharacter: 5) }
        #expect(try await store.segments(of: id).count == 1)
    }

    // MARK: Undo

    @Test func undoingAMergeBringsBackTheSpeakerItsSegmentsAndItsName() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let ana = try await person(store, "Ana")
        let two = try await m.speaker(.others, 2)
        try await store.assignSpeaker(two.id, toEntity: ana)
        let before = try await store.segments(of: m.meeting).map { $0.speaker?.id }
        let undo = try await store.mergeSpeaker(two.id, into: try await m.speaker(.others, 1).id)
        #expect(try await store.speaker(two.id) == nil)
        try await store.undo(undo)
        let back = try #require(try await store.speaker(two.id))
        #expect(back.ordinal == 2 && back.name == "Ana" && back.source == .user && back.talkSeconds == 1)
        #expect(try await store.segments(of: m.meeting).map { $0.speaker?.id } == before)
        try await m.finalize()
        #expect(try await store.segments(of: m.meeting)[2].speaker?.name == "Ana", "unlocked again: the diarizer's word and the name hold")
    }

    @Test func undoingAnAssignmentRestoresAProfileMatch() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        let ana = try await person(store, "Ana"), bea = try await person(store, "Bea")
        try await store.finalizeSpeakers(meetingID: m.meeting, speakers: [SpeakerDraft(channel: .others, ordinal: 1, entityID: ana, source: .suggested, confidence: 0.9)])
        let speaker = try await m.speaker(.others, 1)
        let undo = try await store.assignSpeaker(speaker.id, toEntity: bea)
        #expect(try await m.speaker(.others, 1).name == "Bea")
        try await store.undo(undo)
        let back = try await m.speaker(.others, 1)
        #expect(back.entityID == ana && back.source == .suggested && back.confidence == 0.9)
    }

    @Test func undoingAReassignmentRestoresTheDiarizersWord() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let undo = try await store.reassignSegment(m.segments[1], toSpeaker: try await m.speaker(.others, 2).id)
        try await store.undo(undo)
        let tag = try await store.segments(of: m.meeting)[1].speaker
        #expect(tag?.ordinal == 1 && tag?.confidence == 0.9)
        #expect(try await m.speaker(.others, 1).talkSeconds == 2)
        try await m.finalize()
        #expect(try await store.segments(of: m.meeting)[1].speaker?.ordinal == 1)
    }

    @Test func undoingASplitJoinsThePartsAndBringsBackTheTranslations() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let target = m.segments[1]
        try await store.saveTranslation("Gracias por venir", language: "es", of: target)
        let split = try await store.splitSegment(target, atCharacter: 19, rightSpeaker: try await m.speaker(.others, 2).id)
        try await store.undo(split.undo)
        let segments = try await store.segments(of: m.meeting)
        #expect(segments.count == 4 && segments[1].text == "Thanks for joining, shall we start with the launch plan")
        #expect(segments[1].end == 3 && segments[1].speaker?.ordinal == 1)
        #expect(try await store.translations(of: m.meeting).map(\.text) == ["Gracias por venir"])
        #expect(try await store.search("launch").map(\.segment.id) == [target])
        #expect(try await store.search("joining launch").map(\.segment.id) == [target])
        let (one, two) = (try await m.speaker(.others, 1), try await m.speaker(.others, 2))
        #expect(one.talkSeconds == 2 && two.talkSeconds == 1)
        await #expect(throws: StoreError.self) { try await store.undo(split.undo) }
    }

    @Test func undoRefusesWhenTheSpeakersPlaceWasTaken() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let undo = try await store.mergeSpeaker(try await m.speaker(.others, 2).id, into: try await m.speaker(.others, 1).id)
        // A new diarization creates "Speaker 2" again, under another ID.
        try await store.finalizeSpeakers(meetingID: m.meeting, speakers: [
            SpeakerDraft(channel: .me, ordinal: 1), SpeakerDraft(channel: .me, ordinal: 2),
            SpeakerDraft(channel: .others, ordinal: 1), SpeakerDraft(channel: .others, ordinal: 2),
        ])
        await #expect(throws: StoreError.self) { try await store.undo(undo) }
    }

    // MARK: Voice profiles

    @Test func matchingATimestampIsRecorded() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let ana = try await person(store, "Ana")
        let id = try await store.addVoiceProfile(entityID: ana, modelID: "m1", embedding: Data(repeating: 1, count: 8), consentRecordedAt: consent)
        #expect(try await store.voiceProfiles().first?.lastMatchedAt == nil)
        try await store.markVoiceProfilesMatched([id], at: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(try await store.voiceProfiles().first?.lastMatchedAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func removingAPersonSavesASnapshotAtOnceEvenWhileRecording() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let ana = try await person(store, "Ana"), luis = try await person(store, "Luis")
        _ = try await store.startMeeting(at: .now)
        for who in [ana, luis] {
            try await store.addVoiceProfile(entityID: who, modelID: "m1", embedding: Data(repeating: 6, count: 16), consentRecordedAt: consent)
        }
        try await store.saveIfNeeded()
        #expect(fx.exists(fx.journalURL), "recording keeps a journal")
        try await store.deleteEntity(ana)
        #expect(!fx.exists(fx.journalURL), "the snapshot without the profile replaced the journal")
        try await store.saveIfNeeded()
        try await store.mergeEntity(luis, into: try await person(store, "Luisa"))
        #expect(try await store.rowCount("voice_profiles") == 1, "the merged person's profile follows")
    }

    @Test func aPersonWhoBecomesSomethingElseKeepsNoVoiceData() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let ana = try await person(store, "Ana")
        try await store.assignSpeaker(try await m.speaker(.others, 1).id, toEntity: ana)
        try await store.addVoiceProfile(entityID: ana, modelID: "m1", embedding: Data(repeating: 2, count: 16), consentRecordedAt: consent)
        try await store.saveEntity(EntityDraft(id: ana, kind: .project, name: "Ana"))
        #expect(try await store.rowCount("voice_profiles") == 0)
        let speaker = try await m.speaker(.others, 1)
        #expect(speaker.entityID == nil && speaker.source == .auto)
    }

    @Test func mergingKeepsTheNewestModelsProfiles() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let ana = try await person(store, "Ana"), anita = try await person(store, "Anita")
        for i in 0..<10 { try await store.addVoiceProfile(entityID: ana, modelID: "v2", embedding: Data([UInt8(i + 1)]), consentRecordedAt: consent) }
        try await store.addVoiceProfile(entityID: anita, modelID: "v3", embedding: Data([99]), consentRecordedAt: consent)
        try await store.mergeEntity(anita, into: ana)
        let kept = try await store.voiceProfiles(entityID: ana)
        #expect(kept.count == 10 && kept.contains { $0.modelID == "v3" }, "the newest model's profile is not the one evicted")
    }
}
