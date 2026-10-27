// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Storage: speaker undo, pinned speakers, system splits and the per-meeting switch")
struct StorageSpeakerSafetyTests {
    private func person(_ store: MeetingStore, _ name: String) async throws -> Int64 {
        try await store.saveEntity(EntityDraft(kind: .person, name: name))
    }

    // MARK: Undo against reused IDs and moved-on data

    @Test func undoNeverTouchesAnotherMeetingsSpeakerWhoseIDWouldHaveBeenReused() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let a = try await SpeakerMeeting.make(store)
        try await a.finalize()
        let highest = try await a.speaker(.others, 2)
        let undo = try await store.mergeSpeaker(highest.id, into: try await a.speaker(.others, 1).id)
        let b = try await SpeakerMeeting.make(store)
        try await b.finalize()
        let before = try await store.speakers(of: b.meeting)
        #expect(before.allSatisfy { $0.id != highest.id }, "an ID is never reused")
        try await store.undo(undo)
        #expect(try await store.speakers(of: b.meeting).map(\.id) == before.map(\.id))
        let tags = try await store.segments(of: a.meeting).map { $0.speaker?.id }
        #expect(tags[2] == highest.id)
        let owners = Set(try await store.speakers(of: a.meeting).map(\.id))
        #expect(tags.compactMap { $0 }.allSatisfy { owners.contains($0) }, "every segment points at a speaker of its own meeting")
    }

    @Test func undoingASplitOutOfOrderIsRefusedAndChangesNothing() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let first = try await store.splitSegment(m.segments[1], atCharacter: 19)
        let second = try await store.splitSegment(first.rightSegmentID, atCharacter: 8)
        let texts = try await store.segments(of: m.meeting).map(\.text)
        await #expect(throws: StoreError.self) { try await store.undo(first.undo) }
        #expect(try await store.segments(of: m.meeting).map(\.text) == texts, "the transcript is not duplicated")
        // The other way round: the left part split again.
        let third = try await store.splitSegment(m.segments[1], atCharacter: 7)
        await #expect(throws: StoreError.self) { try await store.undo(first.undo) }
        try await store.undo(third.undo)
        try await store.undo(second.undo)
        try await store.undo(first.undo)
        #expect(try await store.segments(of: m.meeting).map(\.text).count == 4)
        #expect(try await store.search("joining").map(\.segment.id) == [m.segments[1]])
    }

    @Test func undoingASplitDropsTranslationsMadeAfterIt() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let split = try await store.splitSegment(m.segments[1], atCharacter: 19)
        try await store.saveTranslation("Gracias por venir", language: "es", of: m.segments[1])
        try await store.undo(split.undo)
        #expect(try await store.translations(of: m.meeting).isEmpty)
    }

    @Test func undoFollowsAMergedPersonAndDropsAThingThatIsNoLongerOne() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let ana = try await person(store, "Ana"), anita = try await person(store, "Anita")
        let one = try await m.speaker(.others, 1)
        try await store.assignSpeaker(one.id, toEntity: anita)
        let undo = try await store.assignSpeaker(one.id, toEntity: nil)
        try await store.mergeEntity(anita, into: ana)
        try await store.undo(undo)
        #expect(try await m.speaker(.others, 1).entityID == ana, "the person that remains")
        let undo2 = try await store.assignSpeaker(one.id, toEntity: nil)
        try await store.saveEntity(EntityDraft(id: ana, kind: .project, name: "Ana"))
        try await store.undo(undo2)
        let back = try await m.speaker(.others, 1)
        #expect(back.entityID == nil && back.source == .auto)
    }

    @Test func aClearedNameStaysTheUsersDecisionAcrossFinalization() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        let ana = try await person(store, "Ana")
        try await store.finalizeSpeakers(meetingID: m.meeting, speakers: [SpeakerDraft(channel: .others, ordinal: 1, entityID: ana, source: .suggested, confidence: 0.9)])
        let speaker = try await m.speaker(.others, 1)
        let clear = try await store.assignSpeaker(speaker.id, toEntity: nil)
        let cleared = try await m.speaker(.others, 1)
        #expect(cleared.entityID == nil && cleared.source == .user && cleared.name == nil)
        // A second pass finds the same voice again and matches it: the cleared speaker is not named.
        try await store.finalizeSpeakers(meetingID: m.meeting, speakers: [SpeakerDraft(channel: .others, ordinal: 1, entityID: ana, source: .suggested, confidence: 0.95)])
        let again = try await m.speaker(.others, 1)
        #expect(again.id == speaker.id && again.entityID == nil && again.source == .user && again.name == nil)
        try await store.undo(clear)
        let back = try await m.speaker(.others, 1)
        #expect(back.entityID == ana && back.source == .suggested)
    }

    @Test func undoingARenameRestoresTheProfileMatchAndRemovesTheNewPerson() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        let ana = try await person(store, "Ana")
        try await store.finalizeSpeakers(meetingID: m.meeting, speakers: [SpeakerDraft(channel: .others, ordinal: 1, entityID: ana, source: .suggested, confidence: 0.9)])
        let speaker = try await m.speaker(.others, 1)
        let rename = try await store.renameSpeaker(speaker.id, to: "Bea")
        #expect(try await store.entity(rename.entityID)?.name == "Bea")
        try await store.undo(rename.undo)
        let back = try await m.speaker(.others, 1)
        #expect(back.entityID == ana && back.source == .suggested && back.confidence == 0.9)
        #expect(try await store.entity(rename.entityID) == nil, "the person the rename created is gone")
        // A person that was already there stays.
        let again = try await store.renameSpeaker(speaker.id, to: "Ana")
        try await store.undo(again.undo)
        #expect(try await store.entity(ana)?.name == "Ana")
    }

    // MARK: Pinned speakers

    @Test func aSegmentMovedToAnUnnamedSpeakerSurvivesTheNewDiarizationDroppingThatSpeaker() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let two = try await m.speaker(.others, 2)
        try await store.reassignSegment(m.segments[1], toSpeaker: two.id)
        try await store.finalizeSpeakers(meetingID: m.meeting, speakers: [SpeakerDraft(channel: .me, ordinal: 1), SpeakerDraft(channel: .others, ordinal: 1)],
                                         assignments: [SegmentSpeakerAssignment(segmentID: m.segments[3], channel: .others, ordinal: 1)])
        let tag = try await store.segments(of: m.meeting)[1].speaker
        #expect(tag?.id == two.id, "the row the user chose was not deleted")
    }

    @Test func aHandMovedSegmentKeepsItsVoiceWhenTheNewDiarizationRenumbers() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let two = try await m.speaker(.others, 2)
        try await store.reassignSegment(m.segments[1], toSpeaker: two.id)   // segments 1 and 2 are speaker 2 now
        // The diarizer now calls the voice of segments 1 and 2 "1" and the other one "2".
        try await store.finalizeSpeakers(meetingID: m.meeting, speakers: [
            SpeakerDraft(channel: .me, ordinal: 1), SpeakerDraft(channel: .others, ordinal: 1), SpeakerDraft(channel: .others, ordinal: 2),
        ], assignments: [
            SegmentSpeakerAssignment(segmentID: m.segments[0], channel: .me, ordinal: 1),
            SegmentSpeakerAssignment(segmentID: m.segments[1], channel: .others, ordinal: 1),
            SegmentSpeakerAssignment(segmentID: m.segments[2], channel: .others, ordinal: 1),
            SegmentSpeakerAssignment(segmentID: m.segments[3], channel: .others, ordinal: 2),
        ])
        let tags = try await store.segments(of: m.meeting).map { $0.speaker }
        #expect(tags[1]?.id == two.id && tags[2]?.id == two.id, "the moved segment stays with the voice the user put it in")
        #expect(tags[3]?.id != two.id && tags[3] != nil)
    }

    @Test func aMergeTargetTheNewDiarizationNoLongerHasKeepsItsSegments() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let one = try await m.speaker(.others, 1)
        try await store.mergeSpeaker(try await m.speaker(.others, 2).id, into: one.id)
        try await store.finalizeSpeakers(meetingID: m.meeting, speakers: [SpeakerDraft(channel: .me, ordinal: 1)])
        #expect(try await store.segments(of: m.meeting)[2].speaker?.id == one.id)
        #expect(try await store.speaker(one.id) != nil)
    }

    @Test func aUserRowWithoutSegmentsStillTakesTheClusterWithItsOwnOrdinal() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let ana = try await person(store, "Ana")
        try await store.assignSpeaker(try await m.speaker(.others, 2).id, toEntity: ana)
        try await store.finalizeSpeakers(meetingID: m.meeting, speakers: [SpeakerDraft(channel: .others, ordinal: 1), SpeakerDraft(channel: .others, ordinal: 2, confidence: 0.4)])
        let others = try await store.speakers(of: m.meeting).filter { $0.channel == .others }
        #expect(others.map(\.ordinal) == [1, 2], "no extra empty speaker")
        #expect(others[1].name == "Ana" && others[1].confidence == 0.4)
    }

    // MARK: System splits

    @Test func theAlignersSplitsAreAtomicWithTheSpeakersAndDoNotLock() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await store.saveTranslation("Gracias por venir, empecemos con el plan", language: "es", of: m.segments[1])
        let drafts = [SpeakerDraft(channel: .me, ordinal: 1), SpeakerDraft(channel: .others, ordinal: 1), SpeakerDraft(channel: .others, ordinal: 2)]
        try await store.finalizeSpeakers(meetingID: m.meeting, speakers: drafts, assignments: [
            SegmentSpeakerAssignment(segmentID: m.segments[1], channel: .others, ordinal: 1),
            SegmentSpeakerAssignment(segmentID: m.segments[1], channel: .others, ordinal: 2, rightOfSplit: 0),
        ], splits: [SegmentSplitRequest(segmentID: m.segments[1], offset: 19)])
        let segments = try await store.segments(of: m.meeting)
        #expect(segments.count == 5 && segments[1].text == "Thanks for joining," && segments[2].text == "shall we start with the launch plan")
        #expect(segments[1].speaker?.ordinal == 1 && segments[2].speaker?.ordinal == 2)
        let translations = try await store.translations(of: m.meeting)
        #expect(translations.count == 2 && translations.allSatisfy { !$0.text.isEmpty }, "the translation was cut, not dropped")
        // Not locked: the next diarization owns both parts.
        try await store.finalizeSpeakers(meetingID: m.meeting, speakers: drafts, assignments: [
            SegmentSpeakerAssignment(segmentID: segments[1].id, channel: .others, ordinal: 2),
            SegmentSpeakerAssignment(segmentID: segments[2].id, channel: .others, ordinal: 2),
        ])
        #expect(try await store.segments(of: m.meeting)[1].speaker?.ordinal == 2)
        // A bad assignment rolls the split back.
        await #expect(throws: StoreError.self) {
            try await store.finalizeSpeakers(meetingID: m.meeting, speakers: drafts, assignments: [
                SegmentSpeakerAssignment(segmentID: m.segments[2], channel: .others, ordinal: 9),
            ], splits: [SegmentSplitRequest(segmentID: m.segments[2], offset: 8)])
        }
        #expect(try await store.segments(of: m.meeting).count == 5)
    }

    @Test func theAlignerSplitsOneSegmentIntoThreeTurnsInOneCall() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        // "Thanks for joining, | shall we start | with the launch plan"
        try await store.saveTranslation("Gracias por venir, empecemos ya con el plan de lanzamiento", language: "es", of: m.segments[1])
        let drafts = [SpeakerDraft(channel: .me, ordinal: 1), SpeakerDraft(channel: .others, ordinal: 1), SpeakerDraft(channel: .others, ordinal: 2)]
        let first = 19, second = 35
        try await store.finalizeSpeakers(meetingID: m.meeting, speakers: drafts, assignments: [
            SegmentSpeakerAssignment(segmentID: m.segments[1], channel: .others, ordinal: 1),
            SegmentSpeakerAssignment(segmentID: m.segments[1], channel: .others, ordinal: 2, rightOfSplit: 0),
            SegmentSpeakerAssignment(segmentID: m.segments[1], channel: .others, ordinal: 1, rightOfSplit: 1),
        ], splits: [SegmentSplitRequest(segmentID: m.segments[1], offset: first, time: 2.3),
                    SegmentSplitRequest(segmentID: m.segments[1], offset: second, time: 2.6)])
        let segments = try await store.segments(of: m.meeting)
        #expect(segments.count == 6)
        #expect(segments[1...3].map(\.text) == ["Thanks for joining,", "shall we start", "with the launch plan"])
        #expect(segments[1...3].map { $0.speaker?.ordinal } == [1, 2, 1])
        #expect(segments[1].id == m.segments[1] && segments[1].end == 2.3 && segments[2].end == 2.6 && segments[3].start == 2.6)
        #expect(try await store.search("launch").map(\.segment.id) == [segments[3].id])
        #expect(try await store.search("shall").map(\.segment.id) == [segments[2].id])
        let translations = try await store.translations(of: m.meeting)
        #expect(translations.count == 3 && translations.allSatisfy { !$0.text.isEmpty })
        let talk = try await store.speakers(of: m.meeting).filter { $0.channel == .others }.map(\.talkSeconds)
        #expect(abs(talk.reduce(0, +) - 1.0) < 0.001, "the cuts neither lose nor add talk time")
        // The same cut twice is not a valid request.
        await #expect(throws: StoreError.self) {
            try await store.finalizeSpeakers(meetingID: m.meeting, speakers: drafts, splits: [
                SegmentSplitRequest(segmentID: m.segments[2], offset: 8), SegmentSplitRequest(segmentID: m.segments[2], offset: 8)])
        }
    }

    @Test func theAlignerDoesNotSplitASegmentTheUserDecided() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let newSpeaker = try await store.addSpeaker(meetingID: m.meeting, channel: .others).speaker
        let split = try await store.splitSegment(m.segments[1], atCharacter: 19, rightSpeaker: newSpeaker.id)
        let before = try await store.segments(of: m.meeting).map(\.text)
        try await store.finalizeSpeakers(meetingID: m.meeting, speakers: [SpeakerDraft(channel: .me, ordinal: 1), SpeakerDraft(channel: .others, ordinal: 1)], assignments: [
            SegmentSpeakerAssignment(segmentID: m.segments[1], channel: .others, ordinal: 1),
            SegmentSpeakerAssignment(segmentID: m.segments[1], channel: .others, ordinal: 1, rightOfSplit: 0),
        ], splits: [SegmentSplitRequest(segmentID: m.segments[1], offset: 8, time: 2.1)])
        #expect(try await store.segments(of: m.meeting).map(\.text) == before, "text unchanged")
        try await store.undo(split.undo)
        #expect(try await store.segments(of: m.meeting).count == 4)
    }

    @Test func anAssignmentToAnOrdinalOnlyAPinnedRowHoldsAttachesToThatRow() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let ana = try await store.saveEntity(EntityDraft(kind: .person, name: "Ana"))
        try await store.assignSpeaker(try await m.speaker(.others, 2).id, toEntity: ana)
        // The only cluster is numbered 1 and matches the pinned row (ordinal 2); a stray assignment names 2.
        try await store.finalizeSpeakers(meetingID: m.meeting, speakers: [SpeakerDraft(channel: .others, ordinal: 1)], assignments: [
            SegmentSpeakerAssignment(segmentID: m.segments[2], channel: .others, ordinal: 1),
            SegmentSpeakerAssignment(segmentID: m.segments[1], channel: .others, ordinal: 2),
        ])
        let segments = try await store.segments(of: m.meeting)
        #expect(segments[1].speaker?.name == "Ana" && segments[2].speaker?.name == "Ana")
    }

    @Test func addingASpeakerToAFinalizedMeetingIsUndoable() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let (added, undo) = try await store.addSpeaker(meetingID: m.meeting, channel: .others)
        #expect(added.ordinal == 3 && added.channel == .others)
        let split = try await store.splitSegment(m.segments[1], atCharacter: 19, rightSpeaker: added.id)
        #expect(try await store.segments(of: m.meeting)[2].speaker?.ordinal == 3)
        // Still used: undoing the creation alone keeps the row.
        try await store.undo(undo)
        #expect(try await store.speakers(of: m.meeting).count == 4)
        try await store.undo(split.undo)
        try await store.undo(undo)
        #expect(try await store.speakers(of: m.meeting).count == 3)
        #expect(try await store.addSpeaker(meetingID: m.meeting, channel: .me).speaker.ordinal == 2)
    }

    @Test func speakerEditErrorsHaveTheirOwnCodes() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        _ = try await store.saveEntity(EntityDraft(kind: .person, name: "Ana Uno", aliases: ["Anita"]))
        _ = try await store.saveEntity(EntityDraft(kind: .person, name: "Ana Dos", aliases: ["Anita"]))
        let id = try await m.speaker(.others, 1).id
        await expectStoreError(.speakerNameAmbiguous) { try await store.renameSpeaker(id, to: "Anita") }
        await expectStoreError(.speakerGone) { try await store.assignSpeaker(9_999, toEntity: nil) }
        await expectStoreError(.segmentGone) { try await store.reassignSegment(9_999, toSpeaker: nil) }
        await expectStoreError(.cannotSplit) { try await store.splitSegment(m.segments[1], atCharacter: 0) }
        await expectStoreError(.speakerGone) { try await store.addSpeaker(meetingID: 9_999, channel: .others) }
        // A speaker of the other channel cannot take a segment, and two channels cannot merge.
        let mine = try await m.speaker(.me, 1).id
        await expectStoreError(.speakerMismatch) { try await store.reassignSegment(m.segments[1], toSpeaker: mine) }
        await expectStoreError(.speakerMismatch) { try await store.mergeSpeaker(mine, into: id) }
        try await store.setSpeakersOff(true, meetingID: m.meeting)
        await expectStoreError(.speakersOff) { try await store.addSpeaker(meetingID: m.meeting, channel: .others) }
    }

    @Test func noTwoSpeakersOfAMeetingShareADefaultLabel() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let second = try await store.addSpeaker(meetingID: m.meeting, channel: .me).speaker
        let others = try await m.speaker(.others, 2)
        #expect(second.ordinal == 2 && others.ordinal == 2)
        #expect(second.stableLabel == "Me 2" && others.stableLabel == "Speaker 2")
        #expect(second.displayName != others.displayName)
    }

    @Test func theAlignerCanSplitAMeetingBeingRecorded() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let id = try await store.startMeeting(at: .now)
        let seg = try await store.append(segment(.others, 0, "Hello there my friend how are you today"), to: id)
        try await store.finalizeSpeakers(meetingID: id, speakers: [SpeakerDraft(channel: .others, ordinal: 1), SpeakerDraft(channel: .others, ordinal: 2)],
                                         assignments: [SegmentSpeakerAssignment(segmentID: seg, channel: .others, ordinal: 1),
                                                       SegmentSpeakerAssignment(segmentID: seg, channel: .others, ordinal: 2, rightOfSplit: 0)],
                                         splits: [SegmentSplitRequest(segmentID: seg, offset: 20, time: 0.5)])
        #expect(try await store.segments(of: id).map { $0.speaker?.ordinal } == [1, 2])
        await #expect(throws: StoreError.self) { try await store.splitSegment(seg, atCharacter: 5) }
    }

    @Test func aLiveTranslationOfTheWholeTextIsRefusedAfterTheAlignerSplit() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let id = try await store.startMeeting(at: .now)
        let text = "Hello there my friend how are you today"
        let seg = try await store.append(segment(.others, 0, text), to: id)
        try await store.finalizeSpeakers(meetingID: id, speakers: [SpeakerDraft(channel: .others, ordinal: 1)],
                                         splits: [SegmentSplitRequest(segmentID: seg, offset: 20, time: 0.5)])
        try await store.saveTranslation("Hola amigo como estas hoy", language: "es", of: seg, source: text)
        #expect(try await store.translations(of: id).isEmpty, "the translation of the old text is not stored")
        let left = try #require(try await store.segments(of: id).first)
        try await store.saveTranslation("Hola amigo", language: "es", of: seg, source: left.text)
        #expect(try await store.translations(of: id).map(\.text) == ["Hola amigo"])
    }

    @Test func aTranslationWithoutSpacesIsCutNotDropped() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let id = try await store.startMeeting(at: .now)
        let seg = try await store.append(segment(.others, 0, "Hello there my friend how are you today"), to: id)
        try await store.saveTranslation("こんにちは友達今日はお元気ですか", language: "ja", of: seg)
        try await store.saveTranslation("你好朋友你今天好吗", language: "zh-Hans", of: seg)
        try await store.finalizeSpeakers(meetingID: id, speakers: [SpeakerDraft(channel: .others, ordinal: 1)],
                                         splits: [SegmentSplitRequest(segmentID: seg, offset: 20, time: 0.5)])
        let translations = try await store.translations(of: id)
        #expect(translations.count == 4 && translations.allSatisfy { !$0.text.isEmpty })
        #expect(Set(translations.filter { $0.language == "ja" }.map(\.text)).count == 2)
    }

    @Test func undoDoesNotRestoreSpeakersIntoAMeetingWhoseSpeakersAreOff() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let undo = try await store.clearSpeakers(meetingID: m.meeting)
        try await store.setSpeakersOff(true, meetingID: m.meeting)
        await #expect(throws: StoreError.self) { try await store.undo(undo) }
        #expect(try await store.speakers(of: m.meeting).isEmpty)
    }

    @Test func theSpeakerTriggerSurvivesInTheCurrentSchema() throws {
        let db = try SQLiteDatabase(image: nil, size: 0)
        try Schema.migrate(db)
        #expect(try db.query("SELECT 1 FROM sqlite_schema WHERE type = 'trigger' AND name = 'entities_speakers_bd'").count == 1)
    }

    // MARK: The per-meeting switch

    @Test func clearingASpeakerlessMeetingExportsLikeOneFromBeforeSpeakers() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        func export() async throws -> String {
            try MeetingExportJSON.encode(try #require(try await store.meetingExport(m.meeting)), options: ExportRendererTests.options)
        }
        let before = try await export()
        try await m.finalize()
        let ana = try await person(store, "Ana")
        try await store.assignSpeaker(try await m.speaker(.others, 1).id, toEntity: ana)
        #expect(try await export() != before)
        let undo = try await store.clearSpeakers(meetingID: m.meeting)
        #expect(try await export() == before)
        #expect(try await store.speakers(of: m.meeting).isEmpty)
        try await store.undo(undo)
        #expect(try await m.speaker(.others, 1).name == "Ana")
        #expect(try await store.segments(of: m.meeting)[1].speaker?.name == "Ana")
    }

    @Test func aMeetingWithSpeakersOffIsNotFinalized() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        #expect(try await store.speakersOff(meetingID: m.meeting) == false)
        try await store.setSpeakersOff(true, meetingID: m.meeting)
        try await m.finalize()
        #expect(try await store.speakers(of: m.meeting).isEmpty)
        try await store.setSpeakersOff(false, meetingID: m.meeting)
        try await m.finalize()
        #expect(try await store.speakers(of: m.meeting).count == 3)
    }

    // MARK: Voice profiles

    @Test func modelIDsAreTrimmedOnLookup() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let ana = try await person(store, "Ana")
        try await store.addVoiceProfile(entityID: ana, modelID: " m1 ", embedding: Data(repeating: 1, count: 16), consentRecordedAt: .now)
        #expect(try await store.voiceProfileEmbeddings(modelID: " m1\n").count == 1)
    }
}
