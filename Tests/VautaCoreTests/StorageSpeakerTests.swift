// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// A meeting with three "Others" segments and one of "Me", the base of the speaker tests.
struct SpeakerMeeting {
    let store: MeetingStore
    let meeting: Int64
    /// Segment IDs in time order: me 0–1, others 2–3, others 4–5, others 6–7.
    let segments: [Int64]

    static func make(_ store: MeetingStore, at date: Date = .now) async throws -> SpeakerMeeting {
        let id = try await store.startMeeting(at: date)
        var ids: [Int64] = []
        for (channel, start, text) in [(Channel.me, 0.0, "Good morning everyone"), (.others, 2, "Thanks for joining, shall we start with the launch plan"),
                                       (.others, 4, "Beta is stable and ready"), (.others, 6, "Great, then we ship Thursday")] {
            ids.append(try await store.append(segment(channel, start, text), to: id))
        }
        try await store.endMeeting(id, at: date + 60)
        return SpeakerMeeting(store: store, meeting: id, segments: ids)
    }

    /// Me = speaker 1 of its channel; Others: speaker 1 (segments 1 and 3) and speaker 2 (segment 2).
    func finalize(extra: [SpeakerDraft] = []) async throws {
        try await store.finalizeSpeakers(meetingID: meeting, speakers: [
            SpeakerDraft(channel: .me, ordinal: 1), SpeakerDraft(channel: .others, ordinal: 1, confidence: 0.9),
            SpeakerDraft(channel: .others, ordinal: 2, confidence: 0.8),
        ] + extra, assignments: [
            SegmentSpeakerAssignment(segmentID: segments[0], channel: .me, ordinal: 1, confidence: 0.99),
            SegmentSpeakerAssignment(segmentID: segments[1], channel: .others, ordinal: 1, confidence: 0.9),
            SegmentSpeakerAssignment(segmentID: segments[2], channel: .others, ordinal: 2, confidence: 0.7, overlap: true),
            SegmentSpeakerAssignment(segmentID: segments[3], channel: .others, ordinal: 1, confidence: 0.85),
        ])
    }

    func speaker(_ channel: Channel, _ ordinal: Int) async throws -> MeetingSpeaker {
        try #require(try await store.speakers(of: meeting).first { $0.channel == channel && $0.ordinal == ordinal })
    }
}

@Suite("Storage: speakers")
struct StorageSpeakerTests {
    private func person(_ store: MeetingStore, _ name: String) async throws -> Int64 {
        try await store.saveEntity(EntityDraft(kind: .person, name: name))
    }

    // MARK: Schema 13 and meetings without speakers

    @Test func schema13StoreMigratesAndRendersIdentically() async throws {
        let fx = StoreFixture()
        try fx.writeLegacyStore(schema: 13) { db in
            try StoreFixture.legacyMeeting(db)
            try db.query("INSERT INTO segment_translations(segment_id, lang, text) VALUES (2, 'en', 'answer')")
        }
        let store = try fx.open()
        #expect(try await store.pragma("user_version") == Schema.currentVersion)
        #expect(try await store.columnNames("segments").suffix(4) == ["speaker_id", "speaker_confidence", "overlap", "speaker_locked"])
        let segments = try await store.segments(of: 1)
        #expect(segments.map(\.text) == ["texto heredado", "respuesta"])
        #expect(segments.map(\.channel) == [.me, .others])
        #expect(segments.allSatisfy { $0.speaker == nil })
        #expect(try await store.speakerCodes(1) == ["Yo", "Otros"], "the stored values are not rewritten")
        #expect(try await store.speakers(of: 1).isEmpty)
        #expect(try await store.search("heredado").map(\.segment.id) == [1])
        #expect(try await store.search("heredado").first?.segment.speaker == nil)
        #expect(try await store.translations(of: 1).map(\.text) == ["answer"])
        #expect(try await store.citableSegments(1).allSatisfy { $0.speaker == nil })
        let export = try #require(try await store.meetingExport(1))
        let json = try MeetingExportJSON.encode(export, options: ExportRendererTests.options)
        for key in ["\"speakers\"", "\"speakerId\"", "\"overlap\"", "\"confidence\""] { #expect(!json.contains(key)) }
        #expect(try await store.rowCount("voice_profiles") == 0)
    }

    @Test func meetingsWithoutSpeakerDataBehaveAsBefore() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let id = try await store.startMeeting(at: .now)
        let first = try await store.append(segment(.others, 0, "alpha bravo"), to: id)
        try await store.endMeeting(id, at: .now)
        #expect(try await store.speakers(of: id).isEmpty)
        #expect(try await store.segments(of: id).first?.speaker == nil)
        #expect(try await store.segmentsByIDs([first]).first?.speaker == nil)
        #expect(try await store.search("alpha").first?.segment.speaker == nil)
        let export = try #require(try await store.meetingExport(id))
        #expect(export.speakers.isEmpty && export.transcript.allSatisfy { $0.speaker == nil })
        let json = try MeetingExportJSON.encode(export, options: ExportRendererTests.options)
        #expect(!json.contains("speakers") && !json.contains("speakerId"))
    }

    // MARK: Finalization

    @Test func finalizationStoresSpeakersAndTagsSegments() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let speakers = try await store.speakers(of: m.meeting)
        #expect(speakers.map(\.channel) == [.me, .others, .others])
        #expect(speakers.map(\.ordinal) == [1, 1, 2])
        #expect(speakers.map(\.talkSeconds) == [1, 2, 1])
        #expect(speakers.allSatisfy { $0.source == .auto && $0.name == nil })
        #expect(speakers.map(\.displayName).prefix(1) == [Channel.me.displayName])
        let tags = try await store.segments(of: m.meeting).map(\.speaker)
        #expect(tags.map { $0?.ordinal } == [1, 1, 2, 1])
        #expect(tags[2]?.overlap == true && tags[2]?.confidence == 0.7)
        #expect(tags[1]?.id == speakers[1].id)
        #expect(try await store.search("beta").first?.segment.speaker?.ordinal == 2)
        #expect(try await store.citableSegments(m.meeting)[2].speaker?.ordinal == 2)
        #expect(try await store.speakerCodes(m.meeting) == ["me", "others", "others", "others"], "the stored channel code is untouched")
    }

    @Test func userAssignmentsSurviveReFinalization() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        let ana = try await person(store, "Ana")
        let luis = try await person(store, "Luis")
        try await m.finalize()
        try await store.assignSpeaker(try await m.speaker(.others, 1).id, toEntity: ana)
        // The diarizer runs again and (wrongly) thinks Luis's profile matches speaker 1; speaker 2 is dropped.
        try await store.finalizeSpeakers(meetingID: m.meeting, speakers: [
            SpeakerDraft(channel: .others, ordinal: 1, entityID: luis, source: .suggested, confidence: 0.5),
            SpeakerDraft(channel: .others, ordinal: 3, entityID: luis, source: .suggested, confidence: 0.95),
        ], assignments: [SegmentSpeakerAssignment(segmentID: m.segments[1], channel: .others, ordinal: 1, confidence: 0.5)])
        let speakers = try await store.speakers(of: m.meeting)
        let one = try #require(speakers.first { $0.channel == .others && $0.ordinal == 1 })
        #expect(one.entityID == ana && one.source == .user && one.name == "Ana", "the user's choice is ground truth")
        #expect(one.confidence == 0.5, "only the score is refreshed")
        let three = try #require(speakers.first { $0.ordinal == 3 })
        #expect(three.name == nil && three.source == .suggested && three.entityID == luis, "a voice suggestion is a candidate, never a name")
        #expect(!speakers.contains { $0.channel == .others && $0.ordinal == 2 }, "unnamed rows that are no longer there are replaced")
        #expect(!speakers.contains { $0.channel == .me }, "an unnamed row missing from the new set goes too")
    }

    @Test func aUserRowAbsentFromTheNewSetStaysAsItIs() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        let ana = try await person(store, "Ana")
        try await m.finalize()
        try await store.assignSpeaker(try await m.speaker(.others, 2).id, toEntity: ana)
        try await store.finalizeSpeakers(meetingID: m.meeting, speakers: [SpeakerDraft(channel: .others, ordinal: 1)])
        let kept = try await store.speakers(of: m.meeting)
        #expect(kept.map(\.ordinal) == [1, 2])
        #expect(kept[1].name == "Ana")
    }

    @Test func draftsCannotClaimUserSourceOrRepeatASpeaker() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        await #expect(throws: StoreError.self) {
            try await store.finalizeSpeakers(meetingID: m.meeting, speakers: [SpeakerDraft(channel: .me, ordinal: 1, source: .user)])
        }
        await #expect(throws: StoreError.self) {
            try await store.finalizeSpeakers(meetingID: m.meeting, speakers: [SpeakerDraft(channel: .me, ordinal: 1), SpeakerDraft(channel: .me, ordinal: 1)])
        }
        #expect(try await store.speakers(of: m.meeting).isEmpty, "a refused set writes nothing")
    }

    @Test func aProfileMatchOfADeletedPersonIsStoredUnnamed() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await store.finalizeSpeakers(meetingID: m.meeting, speakers: [SpeakerDraft(channel: .others, ordinal: 1, entityID: 9_999, source: .suggested)])
        let only = try await store.speakers(of: m.meeting)
        #expect(only.map(\.source) == [.auto] && only[0].entityID == nil)
    }

    @Test func suggestionsAreNotShownAsNames() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        let ana = try await person(store, "Ana")
        try await store.finalizeSpeakers(meetingID: m.meeting, speakers: [SpeakerDraft(channel: .others, ordinal: 1, entityID: ana, source: .suggested, confidence: 0.6)],
                                         assignments: [SegmentSpeakerAssignment(segmentID: m.segments[1], channel: .others, ordinal: 1)])
        let speaker = try await m.speaker(.others, 1)
        #expect(speaker.entityID == ana && speaker.name == nil)
        #expect(speaker.displayName.contains("1"))
        #expect(try await store.segments(of: m.meeting)[1].speaker?.name == nil)
    }

    // MARK: Naming

    @Test func assignAndUnassignAPerson() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let ana = try await person(store, "Ana")
        let speaker = try await m.speaker(.others, 1)
        try await store.assignSpeaker(speaker.id, toEntity: ana)
        #expect(try await m.speaker(.others, 1).displayName == "Ana")
        #expect(try await store.segments(of: m.meeting)[1].speaker?.name == "Ana")
        try await store.assignSpeaker(speaker.id, toEntity: nil)
        let cleared = try await m.speaker(.others, 1)
        #expect(cleared.entityID == nil && cleared.source == .user)
        let project = try await store.saveEntity(EntityDraft(kind: .project, name: "Atlas"))
        await #expect(throws: KnowledgeError.entityGone) { try await store.assignSpeaker(speaker.id, toEntity: project) }
        await #expect(throws: StoreError.self) { try await store.assignSpeaker(99_999, toEntity: ana) }
    }

    @Test func renamingAssignsThePersonCalledThatAndNeverRenamesOne() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let speaker = try await m.speaker(.others, 1)
        // Unnamed: a new person is created and assigned by the user.
        let id = try await store.renameSpeaker(speaker.id, to: "  Marta  ").entityID
        let created = try #require(try await store.entity(id))
        #expect(created.name == "Marta" && created.kind == .person)
        #expect(try await m.speaker(.others, 1).source == .user)
        // Named: correcting the assignment picks (or creates) another person; Marta is left alone.
        let other = try await store.renameSpeaker(speaker.id, to: "Marta Ruiz").entityID
        #expect(other != id)
        #expect(try await store.entity(id)?.name == "Marta")
        #expect(try await m.speaker(.others, 1).entityID == other)
        // Another speaker given an existing name reuses that person.
        let second = try await m.speaker(.others, 2)
        #expect(try await store.renameSpeaker(second.id, to: "marta ruiz").entityID == other)
        #expect(try await store.entities(.person).filter { $0.name == "Marta Ruiz" }.count == 1)
        await #expect(throws: KnowledgeError.emptyName) { try await store.renameSpeaker(second.id, to: "  ") }
    }

    @Test func renamingASpeakerAcceptedFromASuggestionKeepsTheMatchedPersonAndTheirProfiles() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        let ana = try await person(store, "Ana")
        try await store.addVoiceProfile(entityID: ana, modelID: "m1", embedding: Data(repeating: 4, count: 16), consentRecordedAt: .now)
        try await store.finalizeSpeakers(meetingID: m.meeting, speakers: [SpeakerDraft(channel: .others, ordinal: 1, entityID: ana, source: .suggested, confidence: 0.95)],
                                         assignments: [SegmentSpeakerAssignment(segmentID: m.segments[1], channel: .others, ordinal: 1)])
        let suggested = try await m.speaker(.others, 1)
        #expect(suggested.name == nil && suggested.source == .suggested)
        try await store.assignSpeaker(suggested.id, toEntity: ana)
        let speaker = try await m.speaker(.others, 1)
        #expect(speaker.name == "Ana")
        let bea = try await store.renameSpeaker(speaker.id, to: "Bea").entityID
        let renamed = try await m.speaker(.others, 1)
        #expect(bea != ana && renamed.name == "Bea")
        #expect(try await store.entity(ana)?.name == "Ana")
        let (anas, beas) = (try await store.voiceProfiles(entityID: ana), try await store.voiceProfiles(entityID: bea))
        #expect(anas.count == 1 && beas.isEmpty)
    }

    @Test func aNameSharedByTwoPeopleIsAmbiguous() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let a = try await person(store, "Ana García"), b = try await person(store, "Ana Pérez")
        for id in [a, b] { try await store.saveEntity(EntityDraft(id: id, kind: .person, name: id == a ? "Ana García" : "Ana Pérez", aliases: ["Ana"])) }
        let before = try await store.rowCount("entities")
        await #expect(throws: StoreError.self) { try await store.renameSpeaker(try await m.speaker(.others, 1).id, to: "Ana") }
        #expect(try await store.rowCount("entities") == before, "no third person is created")
    }

    // MARK: Merge, reassign, split

    @Test func mergingMovesSegmentsAndKeepsTheStrongerName() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let ana = try await person(store, "Ana")
        let one = try await m.speaker(.others, 1), two = try await m.speaker(.others, 2)
        try await store.assignSpeaker(two.id, toEntity: ana)
        try await store.mergeSpeaker(two.id, into: one.id)
        let speakers = try await store.speakers(of: m.meeting)
        #expect(speakers.map(\.ordinal) == [1, 1] && !speakers.contains { $0.id == two.id })
        let merged = try await m.speaker(.others, 1)
        #expect(merged.name == "Ana" && merged.source == .user, "the user's name from the merged speaker wins over none")
        #expect(merged.talkSeconds == 3)
        #expect(try await store.segments(of: m.meeting).compactMap { $0.speaker?.id }.filter { $0 == one.id }.count == 3)
        await #expect(throws: StoreError.self) { try await store.mergeSpeaker(one.id, into: try await m.speaker(.me, 1).id) }
    }

    @Test func mergingKeepsTheTargetsOwnUserName() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let ana = try await person(store, "Ana"), luis = try await person(store, "Luis")
        let one = try await m.speaker(.others, 1), two = try await m.speaker(.others, 2)
        try await store.assignSpeaker(one.id, toEntity: ana)
        try await store.assignSpeaker(two.id, toEntity: luis)
        try await store.mergeSpeaker(two.id, into: one.id)
        #expect(try await m.speaker(.others, 1).name == "Ana")
    }

    @Test func reassigningASegmentMovesTalkTime() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let two = try await m.speaker(.others, 2)
        try await store.reassignSegment(m.segments[1], toSpeaker: two.id)
        #expect(try await m.speaker(.others, 1).talkSeconds == 1)
        #expect(try await m.speaker(.others, 2).talkSeconds == 2)
        let moved = try await store.segments(of: m.meeting)[1].speaker
        #expect(moved?.ordinal == 2 && moved?.confidence == nil)
        try await store.reassignSegment(m.segments[1], toSpeaker: nil)
        #expect(try await store.segments(of: m.meeting)[1].speaker == nil)
        // A speaker of the other channel is refused: `segments.speaker` stays frozen.
        await #expect(throws: StoreError.self) { try await store.reassignSegment(m.segments[1], toSpeaker: try await m.speaker(.me, 1).id) }
        await #expect(throws: StoreError.self) { try await store.reassignSegment(99_999, toSpeaker: nil) }
    }

    @Test func splittingKeepsSearchAndTranslationsConsistent() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let target = m.segments[1]   // "Thanks for joining, shall we start with the launch plan", 2…3
        try await store.saveTranslation("Gracias por venir", language: "es", of: target)
        try await store.saveTranslation("Gracias", language: "es", of: m.segments[2])
        let two = try await m.speaker(.others, 2)
        let text = "Thanks for joining, shall we start with the launch plan"
        let offset = text.distance(from: text.startIndex, to: text.range(of: " shall")!.lowerBound)
        let right = try await store.splitSegment(target, atCharacter: offset, rightSpeaker: two.id).rightSegmentID

        let segments = try await store.segments(of: m.meeting)
        #expect(segments.count == 5)
        #expect(segments.map(\.text)[1...2] == ["Thanks for joining,", "shall we start with the launch plan"])
        let (l, r) = (segments[1], segments[2])
        #expect(l.id == target && r.id == right && right > m.segments.max()!, "the left part keeps the ID")
        #expect(l.start == 2 && l.end == r.start && r.end == 3 && l.end > 2 && l.end < 3)
        #expect(l.speaker?.ordinal == 1 && r.speaker?.ordinal == 2 && r.speaker?.confidence == 0.9)
        // Full-text index: old words resolve to the right part, nothing stale remains.
        #expect(try await store.search("joining").map(\.segment.id) == [target])
        #expect(try await store.search("launch").map(\.segment.id) == [right])
        #expect(try await store.search("joining launch").isEmpty)
        // The old translation described the unsplit text: gone. Other segments keep theirs.
        #expect(try await store.translations(of: m.meeting).map(\.segmentID) == [m.segments[2]])
        let talk = try await store.speakers(of: m.meeting).filter { $0.channel == .others }.map(\.talkSeconds)
        #expect(talk.reduce(0, +) == 3, "the two parts add up to the original length")
        // The right part is a normal segment: it can be translated, and deleting the meeting removes it from the index.
        try await store.saveTranslation("el plan", language: "es", of: right)
        #expect(try await store.translations(of: m.meeting).count == 2)
        try await store.deleteMeeting(m.meeting)
        #expect(try await store.search("launch").isEmpty)
        #expect(try await store.rowCount("segment_translations") == 0)
    }

    @Test func splittingByTimeUsesTheNearestSpace() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        let right = try await store.splitSegment(m.segments[3], atTime: 6.5).rightSegmentID   // "Great, then we ship Thursday"
        let parts = try await store.segments(of: m.meeting).suffix(2)
        #expect(parts.map(\.text).joined(separator: " ") == "Great, then we ship Thursday")
        #expect(parts.last?.id == right && parts.last?.start == 6.5)
    }

    @Test func invalidSplitsChangeNothing() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        let id = m.segments[1]
        for offset in [0, 1_000, -3] { await #expect(throws: StoreError.self) { try await store.splitSegment(id, atCharacter: offset) } }
        await #expect(throws: StoreError.self) { try await store.splitSegment(id, atCharacter: 5, time: 9) }
        await #expect(throws: StoreError.self) { try await store.splitSegment(id, atCharacter: 5, rightSpeaker: 424_242) }
        await #expect(throws: StoreError.self) { try await store.splitSegment(77_777, atCharacter: 5) }
        #expect(try await store.segments(of: m.meeting).count == 4)
        #expect(try await store.search("joining").count == 1)
    }

    // MARK: Deletion and cascades

    @Test func foreignKeysAreEnforcedAndDeletingAMeetingRemovesItsSpeakers() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        #expect(try await store.pragma("foreign_keys") == 1)
        let m = try await SpeakerMeeting.make(store)
        let other = try await SpeakerMeeting.make(store)
        try await m.finalize()
        try await other.finalize()
        #expect(try await store.rowCount("meeting_speakers") == 6)
        try await store.deleteMeeting(m.meeting)
        #expect(try await store.rowCount("meeting_speakers") == 3)
        #expect(try await store.speakers(of: m.meeting).isEmpty)
        #expect(try await store.speakers(of: other.meeting).count == 3)
    }

    @Test func deletingAPersonClearsTheSpeakerAndKeepsTheSpeakerDeclaredByNobody() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let ana = try await person(store, "Ana")
        try await store.assignSpeaker(try await m.speaker(.others, 1).id, toEntity: ana)
        try await store.addVoiceProfile(entityID: ana, modelID: "m1", embedding: Data(repeating: 7, count: 32), consentRecordedAt: .now, sourceMeetingID: m.meeting)
        try await store.deleteEntity(ana)
        let speaker = try await m.speaker(.others, 1)
        #expect(speaker.entityID == nil && speaker.source == .auto && speaker.displayName.contains("1"))
        #expect(try await store.rowCount("voice_profiles") == 0, "the profiles cascade with their person")
        #expect(try await store.segments(of: m.meeting)[1].speaker?.id == speaker.id)
    }

    @Test func mergingPeopleMovesSpeakersAndProfiles() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let ana = try await person(store, "Ana"), anita = try await person(store, "Anita")
        try await store.assignSpeaker(try await m.speaker(.others, 1).id, toEntity: anita)
        for i in 0..<6 { try await store.addVoiceProfile(entityID: ana, modelID: "m1", embedding: Data([UInt8(i + 1)]), consentRecordedAt: .now) }
        for i in 0..<6 { try await store.addVoiceProfile(entityID: anita, modelID: "m1", embedding: Data([UInt8(i + 50)]), consentRecordedAt: .now) }
        try await store.mergeEntity(anita, into: ana)
        #expect(try await m.speaker(.others, 1).entityID == ana)
        let profiles = try await store.voiceProfiles(entityID: ana)
        #expect(profiles.count == MeetingStore.maxVoiceProfilesPerPerson, "the cap holds after a merge")
        #expect(try await store.rowCount("voice_profiles") == 10)
    }

    @Test func rawTextPurgeAlsoRemovesTheSpeakers() async throws {
        let fx = StoreFixture()
        let store = try fx.open(knowledgeDays: 365)
        let m = try await SpeakerMeeting.make(store, at: Date.now.addingTimeInterval(-100 * 86_400))
        try await m.finalize()
        try await store.purgeExpired()
        #expect(try await store.meeting(m.meeting) != nil)
        #expect(try await store.segments(of: m.meeting).isEmpty)
        #expect(try await store.speakers(of: m.meeting).isEmpty)
    }

    // MARK: Crash safety, backup, erase

    @Test func speakersSurviveACrashThroughTheJournal() async throws {
        let fx = StoreFixture()
        var store: MeetingStore? = try fx.open()
        _ = try await SpeakerMeeting.make(store!)
        // A third meeting is being recorded (journal mode) when the app dies after speakers were edited.
        let id = try await store!.startMeeting(at: .now)
        let a = try await store!.append(segment(.others, 0, "journaled words"), to: id)
        let b = try await store!.append(segment(.others, 2, "more words here"), to: id)
        try await store!.endMeeting(id, at: .now)
        _ = try await store!.startMeeting(at: .now)
        try await store!.saveIfNeeded()
        let ana = try await person(store!, "Ana")
        try await store!.finalizeSpeakers(meetingID: id, speakers: [SpeakerDraft(channel: .others, ordinal: 1), SpeakerDraft(channel: .others, ordinal: 2)],
                                          assignments: [SegmentSpeakerAssignment(segmentID: a, channel: .others, ordinal: 1, confidence: 0.9),
                                                        SegmentSpeakerAssignment(segmentID: b, channel: .others, ordinal: 2)])
        try await store!.assignSpeaker(try #require(try await store!.speakers(of: id).first).id, toEntity: ana)
        try await store!.splitSegment(b, atCharacter: 5)
        try await store!.addVoiceProfile(entityID: ana, modelID: "m1", embedding: Data(repeating: 3, count: 16), consentRecordedAt: .now)
        try await store!.saveIfNeeded()
        #expect(fx.exists(fx.journalURL))
        store = nil
        let reopened = try fx.open(recover: true)
        let speakers = try await reopened.speakers(of: id)
        #expect(speakers.count == 2 && speakers[0].name == "Ana" && speakers[0].source == .user)
        let segments = try await reopened.segments(of: id)
        #expect(segments.map(\.text) == ["journaled words", "more", "words here"])
        #expect(segments.map { $0.speaker?.ordinal } == [1, 2, 2])
        #expect(try await reopened.search("here").count == 1)
        #expect(try await reopened.voiceProfiles(entityID: ana).count == 1)
    }

    @Test func backupRoundTripsSpeakersAndVoiceProfiles() async throws {
        let source = StoreFixture()
        let store = try source.open()
        let m = try await SpeakerMeeting.make(store)
        let ana = try await person(store, "Ana")
        try await m.finalize()
        try await store.assignSpeaker(try await m.speaker(.others, 1).id, toEntity: ana)
        let print = Data((0..<64).map { UInt8(($0 * 7 + 1) % 251) })
        try await store.addVoiceProfile(entityID: ana, modelID: "m1", embedding: print, consentRecordedAt: Date(timeIntervalSince1970: 1_700_000_000), sourceMeetingID: m.meeting)
        let file = try await store.createBackup(password: StorageBackupTests.password, appVersion: "0.9.0")
        #expect(file.range(of: print) == nil, "profiles are only ever inside the encrypted payload")

        let backup = try await MeetingStore.openBackup(file, password: StorageBackupTests.password)
        let target = StoreFixture()
        var restored: MeetingStore? = try target.open()
        _ = try await restored!.restore(backup)
        restored = nil
        let reopened = try target.open()
        let speakers = try await reopened.speakers(of: m.meeting)
        #expect(speakers.map(\.ordinal) == [1, 1, 2] && speakers[1].name == "Ana")
        #expect(try await reopened.segments(of: m.meeting).map { $0.speaker?.ordinal } == [1, 1, 2, 1])
        let profile = try #require(try await reopened.voiceProfiles().first)
        #expect(profile.consentRecordedAt == Date(timeIntervalSince1970: 1_700_000_000) && profile.sourceMeetingID == m.meeting)
        #expect(try await reopened.voiceProfileEmbeddings(modelID: "m1").map(\.embedding) == [print])
    }

    @Test func aBackupOfSchema13RestoresIntoTheCurrentSchema() async throws {
        // A real schema-13 image: no meeting_speakers, voice_profiles or speaker columns.
        let source = StoreFixture()
        let image = try source.legacyImage(schema: 13)
        let packed = try image.withSerializedBytes(SnapshotEnvelope.pack)
        let manifest = BackupManifest(format: 1, appVersion: "0.9.0", schemaVersion: 13, createdAt: .now, meetingCount: 1)
        let file = try BackupArchive.seal(packed: packed, manifest: manifest, password: StorageBackupTests.password,
                                          iterations: BackupArchive.minimumIterations)
        let backup = try await MeetingStore.openBackup(file, password: StorageBackupTests.password)
        #expect(backup.manifest.schemaVersion == 13 && backup.meetings == 1)
        let target = StoreFixture()
        let store = try target.open()
        _ = try await store.restore(backup)
        #expect(try await store.pragma("user_version") == Schema.currentVersion)
        #expect(try await store.segments(of: 1).count == 2)
        #expect(try await store.speakers(of: 1).isEmpty)
        #expect(try await store.rowCount("voice_profiles") == 0)
    }

    @Test func eraseEverythingRemovesSpeakersAndProfiles() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        let ana = try await person(store, "Ana")
        try await m.finalize()
        try await store.addVoiceProfile(entityID: ana, modelID: "m1", embedding: Data(repeating: 9, count: 32), consentRecordedAt: .now)
        try await store.eraseEverything()
        for table in ["meeting_speakers", "voice_profiles", "segments", "entities"] { #expect(try await store.rowCount(table) == 0, "\(table)") }
        #expect(try await store.voiceProfileEmbeddings(modelID: "m1").isEmpty)
        #expect(try await store.speakers(of: m.meeting).isEmpty)
    }
}
