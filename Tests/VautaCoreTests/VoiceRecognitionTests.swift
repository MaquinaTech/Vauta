// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

extension MeetingStore {
    /// A live meeting made to look like an imported one (the import path itself is covered by the import tests).
    func markImportedForTesting(_ id: Int64) throws {
        try transaction { try run("UPDATE meetings SET imported = 1 WHERE id = ?", [.integer(id)]) }
    }
}

/// Voice profiles end to end in the store: naming at finalization (three bands, the user's word wins, a model mismatch
/// is unusable), "Remember this voice", rejected suggestions, deletion, backup and imports.
@Suite("Voice recognition")
struct VoiceRecognitionTests {
    /// Speaker A talks in the first 45 windows, B in the next 45 (see SpeakerFinalizerTests).
    static func records() -> (records: [WindowRecord], a: [Float], b: [Float]) {
        var random = TestRandom(seed: 1)
        let centres = (0..<2).map { _ in random.unitVector() }
        let records = SyntheticRecords.records(plan: (0..<90).map { [$0 < 45 ? 0 : 1] }, centres: centres, noise: 0.03, seed: 3)
        let found = Reconstruction.diarize(records: records, totalSamples: 90 * 32_000 + 160_000).centroids
        return (records, found[0].vector, found[1].vector)
    }

    final class Meeting {
        let fx = StoreFixture()
        var store: MeetingStore!
        let id: Int64
        let run: DiarizationRun
        let a: [Float]
        let b: [Float]

        init() async throws {
            store = try fx.open()
            let (records, a, b) = VoiceRecognitionTests.records()
            self.a = a
            self.b = b
            run = DiarizationRun(records: records, totalSamples: 90 * 32_000 + 160_000)
            id = try await store.startMeeting(at: .now)
            for (channel, start, text) in [(Channel.others, 10.0, "we should start with the budget"), (.me, 30, "agreed"),
                                           (.others, 120, "and then the roadmap review")] {
                try await store.append(Segment(channel: channel, start: start, end: start + 4, text: text, isFinal: true), to: id)
            }
            try await store.endMeeting(id, at: .now.addingTimeInterval(200))
        }

        func finalize(recognize: Bool = true) async -> SpeakerFinalizer.Outcome {
            await SpeakerFinalizer.finalize(meetingID: id, in: store, run: run, recognizeVoices: recognize)
        }

        func person(_ name: String) async throws -> Int64 { try await store.saveEntity(EntityDraft(kind: .person, name: name)) }

        func save(_ vector: [Float], for entity: Int64, model: String = DiarizationModels.embeddingModelID) async throws -> Int64 {
            try await store.addVoiceProfile(entityID: entity, modelID: model, embedding: VoiceMatcher.encode(vector), consentRecordedAt: .now)
        }

        func markImported() async throws { try await store.markImportedForTesting(id) }

        func speaker(_ ordinal: Int) async throws -> MeetingSpeaker {
            try #require(try await store.speakers(of: id).first { $0.channel == .others && $0.ordinal == ordinal })
        }
    }

    // MARK: Schema

    @Test func aSchema17StoreMigratesToTheVoiceTables() async throws {
        let fx = StoreFixture()
        try fx.writeLegacyStore(schema: 17)
        let store = try fx.open()
        #expect(try await store.pragma("user_version") == Schema.currentVersion)
        let (kept, rejected) = (try await store.rowCount("speaker_voices"), try await store.rowCount("speaker_suggestion_rejections"))
        #expect(kept == 0 && rejected == 0)
        #expect(try await store.savedVoices().isEmpty)
        #expect(try await store.segments(of: 1).count == 2, "the meeting is untouched")
    }

    @Test func aSpeakerOnceNamedByAVoiceBecomesASuggestionOnMigration() async throws {
        let fx = StoreFixture()
        try fx.writeLegacyStore(schema: 19) { db in
            try StoreFixture.legacyMeeting(db)
            for (id, name) in [(5, "Ana"), (6, "Bea"), (7, "Cy")] {
                try db.query("INSERT INTO entities(id, kind, name, created_at) VALUES (\(id), 'person', '\(name)', 0)", [])
            }
            // Only Ana and Bea still have a saved voice.
            for entity in [5, 6] {
                try db.query("INSERT INTO voice_profiles(entity_id, model_id, embedding, created_at, consent_recorded_at) VALUES (\(entity), 'm', x'01', 0, 0)", [])
            }
            for (ordinal, entity, source) in [(1, 5, "profile"), (2, 5, "user"), (3, 6, "profile"), (4, 7, "profile")] {
                try db.query("INSERT INTO meeting_speakers(meeting_id, channel, ordinal, entity_id, source) VALUES (1, 'others', \(ordinal), \(entity), '\(source)')", [])
            }
        }
        let store = try fx.open()
        let speakers = try await store.speakers(of: 1).filter { $0.channel == .others }.sorted { $0.ordinal < $1.ordinal }
        #expect(speakers.map(\.source) == [.auto, .user, .suggested, .auto],
                "the user's own word is kept; a voice's is only a question, and none when the person is already named or the voice is gone")
        #expect(speakers.map(\.entityID) == [nil, 5, 6, nil])
        #expect(speakers.map(\.name) == [nil, "Ana", nil, nil])
    }

    // MARK: Suggestions

    @Test func aPerfectMatchIsStillOnlyASuggestion() async throws {
        let m = try await Meeting()
        let ana = try await m.person("Ana")
        let profile = try await m.save(m.a, for: ana)
        #expect(await m.finalize() == .written(2))
        let first = try await m.speaker(1), second = try await m.speaker(2)
        #expect(first.source == .suggested && first.entityID == ana, "the candidate is kept")
        #expect(first.name == nil && first.displayName == "Speaker 1", "but a saved voice never names a speaker")
        #expect(second.source == .auto && second.name == nil && second.displayName == "Speaker 2", "an unknown voice stays Speaker k")
        let stored = try await m.store.segments(of: m.id)
        #expect(stored.allSatisfy { $0.speaker?.name == nil })
        #expect(try await m.store.voiceProfiles().first { $0.id == profile }?.lastMatchedAt == nil, "a suggestion alone is not a use")
    }

    @Test func noMatchNamesAnyoneWhateverItsStrength() async throws {
        let m = try await Meeting()
        let ana = try await m.person("Ana"), bea = try await m.person("Bea")
        _ = try await m.save(m.a, for: ana)
        _ = try await m.save(VoiceMatcherTests.vector(cosine: 0.85, from: m.b), for: bea)
        _ = await m.finalize()
        let roster = SpeakerRoster(speakers: try await m.store.speakers(of: m.id), segments: try await m.store.segments(of: m.id))
        let others = roster.entries.filter { $0.channel == .others }
        #expect(others.count == 2 && others.allSatisfy { $0.speaker.source == .suggested && $0.speaker.name == nil })
        #expect(others.map(\.displayName) == ["Speaker 1", "Speaker 2"])
        try await m.store.assignSpeaker(try await m.speaker(1).id, toEntity: ana)
        #expect(try await m.speaker(1).name == "Ana", "one click from the user makes it a name")
    }

    @Test func aVoiceBetweenTheThresholdsIsOnlyASuggestion() async throws {
        let m = try await Meeting()
        let ana = try await m.person("Ana")
        _ = try await m.save(VoiceMatcherTests.vector(cosine: 0.75, from: m.a), for: ana)
        #expect(await m.finalize() == .written(2))
        let first = try await m.speaker(1)
        #expect(first.source == .suggested && first.entityID == ana, "the candidate is kept")
        #expect(first.name == nil && first.displayName == "Speaker 1", "but never shown as a name")
        let stored = try await m.store.segments(of: m.id)
        #expect(stored.allSatisfy { $0.speaker?.name == nil })
        #expect(try await m.store.speakerMeetingCount(entityID: ana) == 0, "a suggestion is not 'said in a meeting'")
    }

    @Test func aVoiceBelowTheThresholdStaysSpeakerK() async throws {
        let m = try await Meeting()
        let ana = try await m.person("Ana")
        _ = try await m.save(VoiceMatcherTests.vector(cosine: 0.5, from: m.a), for: ana)
        _ = await m.finalize()
        let unnamed = try await m.speaker(1)
        #expect(unnamed.source == .auto && unnamed.entityID == nil)
    }

    @Test func recognitionOffMeansNoMatchingAndNothingKept() async throws {
        let m = try await Meeting()
        let ana = try await m.person("Ana")
        _ = try await m.save(m.a, for: ana)
        #expect(await m.finalize(recognize: false) == .written(2))
        #expect(try await m.speaker(1).source == .auto)
        #expect(try await m.store.keptSpeakerVoiceCount() == 0, "no voice summary is kept while the setting is off")
        #expect(try await m.store.voiceProfiles().first?.lastMatchedAt == nil)
    }

    @Test func aProfileOfAnotherModelIsUnusable() async throws {
        let m = try await Meeting()
        let ana = try await m.person("Ana")
        _ = try await m.save(m.a, for: ana, model: "wespeaker-resnet34-lm-someone-elses-v9")
        _ = await m.finalize()
        #expect(try await m.speaker(1).source == .auto)
        #expect(try await m.store.voiceProfiles(entityID: ana).count == 1, "it is still listed, so the user can delete it")
    }

    // MARK: The user wins

    @Test func aNameTheUserGaveIsNeverReplacedByAProfile() async throws {
        let m = try await Meeting()
        #expect(await m.finalize() == .written(2))
        let bea = try await m.person("Bea")
        try await m.store.assignSpeaker(try await m.speaker(1).id, toEntity: bea)
        let ana = try await m.person("Ana")
        _ = try await m.save(m.a, for: ana)
        #expect(await m.finalize() == .written(2), "finalizing again")
        let first = try await m.speaker(1)
        #expect(first.source == .user && first.entityID == bea && first.name == "Bea")
    }

    @Test func aClearedNameIsNotNamedAgain() async throws {
        let m = try await Meeting()
        let ana = try await m.person("Ana")
        _ = try await m.save(m.a, for: ana)
        _ = await m.finalize()
        try await m.store.assignSpeaker(try await m.speaker(1).id, toEntity: nil)
        _ = await m.finalize()
        let first = try await m.speaker(1)
        #expect(first.source == .user && first.entityID == nil && first.name == nil)
    }

    @Test func aPersonTheUserGaveToOneSpeakerDoesNotNameAnother() async throws {
        let m = try await Meeting()
        _ = await m.finalize()
        let ana = try await m.person("Ana")
        try await m.store.assignSpeaker(try await m.speaker(2).id, toEntity: ana)
        _ = try await m.save(m.a, for: ana)
        _ = await m.finalize()
        #expect(try await m.speaker(1).source == .auto, "the user said Ana is the other speaker")
        #expect(try await m.speaker(2).entityID == ana)
    }

    @Test func theUsersOwnVoiceNeverNamesARemoteSpeakerInARecording() async throws {
        let m = try await Meeting()
        let me = try await m.store.selfEntity()
        _ = try await m.save(m.a, for: me)
        _ = await m.finalize()
        #expect(try await m.speaker(1).source == .auto, "the Me channel is the user; Others is never the user")
    }

    // MARK: Rejecting a suggestion

    @Test func aRejectedSuggestionIsRememberedForThatMeetingAndCanBeUndone() async throws {
        let m = try await Meeting()
        let ana = try await m.person("Ana")
        _ = try await m.save(VoiceMatcherTests.vector(cosine: 0.75, from: m.a), for: ana)
        _ = await m.finalize()
        let suggested = try await m.speaker(1)
        let undo = try await m.store.rejectSuggestion(speakerID: suggested.id)
        let unnamed = try await m.speaker(1)
        #expect(unnamed.source == .auto && unnamed.entityID == nil)
        _ = await m.finalize()
        #expect(try await m.speaker(1).source == .auto, "not suggested again for this meeting")
        try await m.store.undo(undo)
        #expect(try await m.speaker(1).source == .suggested)
        _ = await m.finalize()
        #expect(try await m.speaker(1).source == .suggested, "undo makes the person suggestible again")
    }

    @Test func acceptingASuggestionIsTheUsersAssignment() async throws {
        let m = try await Meeting()
        let ana = try await m.person("Ana")
        _ = try await m.save(VoiceMatcherTests.vector(cosine: 0.75, from: m.a), for: ana)
        _ = await m.finalize()
        try await m.store.assignSpeaker(try await m.speaker(1).id, toEntity: ana)
        let first = try await m.speaker(1)
        #expect(first.source == .user && first.name == "Ana")
        #expect(try await m.store.speakerMeetingCount(entityID: ana) == 1)
    }

    // MARK: Remember this voice

    @Test func rememberingAVoiceNeedsANamedSpeakerAndAKeptVoice() async throws {
        let m = try await Meeting()
        _ = await m.finalize()
        let first = try await m.speaker(1)
        await #expect(throws: StoreError.self) { try await m.store.rememberVoice(speakerID: first.id, consentRecordedAt: .now) }
        let ana = try await m.person("Ana")
        try await m.store.assignSpeaker(first.id, toEntity: ana)
        #expect(try await m.store.speakersWithKeptVoice(meetingID: m.id).count == 2, "both talked long enough")
        let consent = Date(timeIntervalSince1970: 1_700_000_000)
        let result = try await m.store.rememberVoice(speakerID: first.id, consentRecordedAt: consent)
        #expect(result.entityID == ana)
        let profile = try #require(try await m.store.voiceProfiles(entityID: ana).first)
        #expect(profile.consentRecordedAt == consent && profile.sourceMeetingID == m.id && profile.modelID == DiarizationModels.embeddingModelID)
        #expect(try await m.store.voiceProfileEmbeddings(modelID: profile.modelID).map(\.embedding) == [VoiceMatcher.encode(m.a)])
        #expect(try await m.store.speakersWithKeptVoice(meetingID: m.id).count == 1, "the kept summary became the profile")
        await #expect(throws: StoreError.self) { try await m.store.rememberVoice(speakerID: first.id, consentRecordedAt: .now) }
    }

    @Test func aSuggestedSpeakerMustBeAcceptedBeforeItsVoiceIsRemembered() async throws {
        let m = try await Meeting()
        let ana = try await m.person("Ana")
        _ = try await m.save(m.a, for: ana)
        _ = await m.finalize()
        let recognized = try await m.speaker(1)
        #expect(recognized.source == .suggested)
        await #expect(throws: StoreError.self) { try await m.store.rememberVoice(speakerID: recognized.id, consentRecordedAt: .now) }
        #expect(try await m.store.voiceProfiles(entityID: ana).count == 1, "a possibly wrong suggestion added nothing to the profile")
        try await m.store.assignSpeaker(recognized.id, toEntity: ana)
        _ = try await m.store.rememberVoice(speakerID: recognized.id, consentRecordedAt: .now)
        #expect(try await m.store.voiceProfiles(entityID: ana).count == 2)
    }

    @Test func aSuggestionOnlyCountsAsUseWhenTheUserAcceptsIt() async throws {
        let m = try await Meeting()
        let ana = try await m.person("Ana")
        _ = try await m.save(VoiceMatcherTests.vector(cosine: 0.75, from: m.a), for: ana)
        _ = await m.finalize()
        #expect(try await m.store.voiceProfiles(entityID: ana).first?.lastMatchedAt == nil, "a suggestion alone is not a match")
        try await m.store.assignSpeaker(try await m.speaker(1).id, toEntity: ana)
        #expect(try await m.store.voiceProfiles(entityID: ana).first?.lastMatchedAt != nil)
    }

    @Test func keptSummariesFollowTheRuleWhateverTheViewDid() async throws {
        let m = try await Meeting()
        _ = await m.finalize()
        #expect(try await m.store.keptSpeakerVoiceCount() == 2)
        let soon = Date.now.addingTimeInterval(Double(VoiceProfileThresholds.keptSummaryDays - 1) * 86_400)
        let later = Date.now.addingTimeInterval(Double(VoiceProfileThresholds.keptSummaryDays + 1) * 86_400)
        #expect(try await m.store.enforceKeptVoicePolicy(recognizing: true, now: soon) == 0, "inside the time limit they stay")
        #expect(try await m.store.enforceKeptVoicePolicy(recognizing: true, now: later) == 2, "after the time limit they go")
        _ = try await m.store.addVoiceProfile(entityID: try await m.person("Ana"), modelID: DiarizationModels.embeddingModelID, embedding: VoiceMatcher.encode(m.a), consentRecordedAt: .now)
        _ = await m.finalize()
        #expect(try await m.store.keptSpeakerVoiceCount() == 2)
        #expect(try await m.store.enforceKeptVoicePolicy(recognizing: false) == 2, "with recognition off none is kept")
        #expect(try await m.store.voiceProfiles().count == 1, "saved voices are not summaries and stay")
    }

    @Test func aRestoredBackupLeavesNoSummariesWhenRecognitionIsOffHere() async throws {
        let m = try await Meeting()
        _ = await m.finalize()
        let file = try await m.store.createBackup(password: StorageBackupTests.password, appVersion: "0.9.0")
        let backup = try await MeetingStore.openBackup(file, password: StorageBackupTests.password)
        let target = StoreFixture()
        let restored = try target.open()
        _ = try await restored.restore(backup)
        #expect(try await restored.keptSpeakerVoiceCount() == 2, "the backup brings them back")
        _ = try await restored.enforceKeptVoicePolicy(recognizing: false)   // what the app does right after a restore on a Mac where it is off
        #expect(try await restored.keptSpeakerVoiceCount() == 0)
    }

    @Test func refinalizingAMeetingSavesTheSnapshotWithoutTheOldSummaries() async throws {
        let m = try await Meeting()
        _ = await m.finalize()
        #expect(try await m.store.keptSpeakerVoiceCount() == 2)
        _ = await m.finalize(recognize: false)
        #expect(try await m.store.keptSpeakerVoiceCount() == 0)
        m.store = nil
        #expect(try await m.fx.open().keptSpeakerVoiceCount() == 0)
    }

    @Test func mergingTwoPeopleKeepsTheNotAnaRejection() async throws {
        let m = try await Meeting()
        let ana = try await m.person("Ana"), full = try await m.person("Ana García")
        _ = try await m.save(VoiceMatcherTests.vector(cosine: 0.75, from: m.a), for: ana)
        _ = await m.finalize()
        try await m.store.rejectSuggestion(speakerID: try await m.speaker(1).id)
        try await m.store.mergeEntity(ana, into: full)
        #expect(try await m.store.rowCount("speaker_suggestion_rejections") == 1)
        _ = await m.finalize()
        #expect(try await m.speaker(1).entityID == nil, "the merged person is still not suggested for this meeting")
    }

    @Test func aSpeakerWhoTalkedTooLittleKeepsNoVoice() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let id = try await store.startMeeting(at: .now)
        try await store.append(Segment(channel: .others, start: 5, end: 9, text: "hello there my friends", isFinal: true), to: id)
        try await store.endMeeting(id, at: .now.addingTimeInterval(100))
        var random = TestRandom(seed: 2)
        let diarization = Diarization(turns: [SpeakerTurn(start: 0, end: 60, speaker: 0), SpeakerTurn(start: 60, end: 80, speaker: 1)], speakerCount: 2, mapping: [], centroids: [
            VoiceMatcherTests.centroid(0, random.unitVector(), seconds: 31), VoiceMatcherTests.centroid(1, random.unitVector(), seconds: 29)])
        let plan = try await store.planVoices(for: diarization, ordinals: [0: 1, 1: 2], meetingID: id, ownVoice: false)
        #expect(plan.voices.map(\.ordinal) == [1], "only the speaker with 30 s or more of clean speech is kept")
    }

    @Test func thisIsMyVoiceNamesTheSpeakerAsTheUserAndSavesTheVoice() async throws {
        let m = try await Meeting()
        _ = await m.finalize()
        let first = try await m.speaker(1)
        // a live recording: the user is the Me channel, so nobody else may be saved as the user
        await #expect(throws: StoreError.self) { try await m.store.rememberOwnVoice(speakerID: first.id) }
        #expect(try await m.speaker(1).entityID == nil)
        try await m.markImported()
        let result = try await m.store.rememberOwnVoice(speakerID: first.id)
        let me = try await m.store.selfEntity()
        #expect(result.entityID == me)
        #expect(try await m.store.voiceProfiles(entityID: me).count == 1)
        let after = try await m.speaker(1)
        #expect(after.entityID == me && after.source == .user)
        // and without a kept voice nothing is assigned
        let other = try await Meeting()
        try await other.markImported()
        _ = await other.finalize(recognize: false)
        let second = try await other.speaker(1)
        await #expect(throws: StoreError.self) { try await other.store.rememberOwnVoice(speakerID: second.id) }
        #expect(try await other.speaker(1).entityID == nil)
    }

    // MARK: Deleting

    @Test func deleteAllLeavesZeroRowsAndTheNextSnapshotHasNone() async throws {
        let m = try await Meeting()
        let ana = try await m.person("Ana")
        _ = try await m.save(m.a, for: ana)
        _ = try await m.save(m.b, for: ana)
        _ = await m.finalize()
        #expect(try await m.store.keptSpeakerVoiceCount() == 2)
        #expect(try await m.store.deleteAllVoiceProfiles() == 2)
        let (profiles, kept) = (try await m.store.rowCount("voice_profiles"), try await m.store.rowCount("speaker_voices"))
        #expect(profiles == 0 && kept == 0)
        // what is on disk now, opened from scratch (nothing is replayed from a journal that still holds them)
        m.store = nil
        let reopened = try m.fx.open()
        let (fromDisk, keptFromDisk) = (try await reopened.rowCount("voice_profiles"), try await reopened.rowCount("speaker_voices"))
        #expect(fromDisk == 0 && keptFromDisk == 0)
        #expect(try await reopened.savedVoices().isEmpty)
        let again = try await reopened.deleteAllVoiceProfiles()
        #expect(again == 0)
    }

    @Test func deletingAPersonDeletesTheirVoicesAndAMeetingDeletesItsKeptVoices() async throws {
        let m = try await Meeting()
        let ana = try await m.person("Ana")
        _ = try await m.save(m.a, for: ana)
        _ = await m.finalize()
        let named = try await m.speaker(1)
        #expect(named.source == .suggested && named.entityID == ana)
        #expect(try await m.store.rowCount("speaker_voices") == 2)
        try await m.store.deleteEntity(ana)
        #expect(try await m.store.rowCount("voice_profiles") == 0, "the profile dies with its person")
        #expect(try await m.store.rowCount("speaker_voices") == 1, "so does the summary of the speaker that was named after them; the other speaker keeps theirs")
        try await m.store.deleteMeeting(m.id)
        #expect(try await m.store.rowCount("speaker_voices") == 0, "kept voices die with their meeting")
    }

    @Test func deletingAPersonsVoiceDeletesTheKeptSummariesOfTheirSpeakersToo() async throws {
        let m = try await Meeting()
        let ana = try await m.person("Ana")
        _ = try await m.save(m.a, for: ana)
        _ = await m.finalize()
        try await m.store.assignSpeaker(try await m.speaker(1).id, toEntity: ana)
        #expect(try await m.store.speakersWithKeptVoice(meetingID: m.id).count == 2)
        #expect(try await m.store.deleteVoiceProfiles(entityID: ana) == 1)
        #expect(try await m.store.rowCount("voice_profiles") == 0)
        #expect(try await m.store.rowCount("speaker_voices") == 1, "the vector of the speaker named Ana is gone, so it cannot be re-enrolled")
        // the snapshot on disk has none of it either
        m.store = nil
        let reopened = try m.fx.open()
        #expect(try await reopened.rowCount("speaker_voices") == 1)
        #expect(try await reopened.speakers(of: m.id).first { $0.ordinal == 1 && $0.channel == .others }?.name == "Ana", "the name in the meeting stays")
    }

    @Test func turningRecognitionOffDeletesTheKeptVoicesButNotTheSavedOnes() async throws {
        let m = try await Meeting()
        let ana = try await m.person("Ana")
        _ = try await m.save(m.a, for: ana)
        _ = await m.finalize()
        #expect(try await m.store.deleteKeptSpeakerVoices() == 2)
        #expect(try await m.store.keptSpeakerVoiceCount() == 0)
        #expect(try await m.store.voiceProfiles(entityID: ana).count == 1, "saved voices stay until the user deletes them")
        #expect(try await m.store.speakersWithKeptVoice(meetingID: m.id).isEmpty)
    }

    @Test func eraseEverythingRemovesKeptVoicesToo() async throws {
        let m = try await Meeting()
        _ = await m.finalize()
        try await m.store.eraseEverything()
        for table in ["speaker_voices", "speaker_centroids", "speaker_suggestion_rejections", "voice_profiles"] { #expect(try await m.store.rowCount(table) == 0, "\(table)") }
    }

    // MARK: What the views show

    @Test func theEditMenuNamesTheRejection() {
        #expect(SpeakerEditKind.rejectSuggestion.actionName == "Reject Voice Suggestion")
    }

    // MARK: Never leaves the store

    @Test func noExportFormatCarriesASavedOrKeptVoice() async throws {
        let m = try await Meeting()
        let ana = try await m.person("Ana")
        _ = try await m.save(m.a, for: ana)
        _ = await m.finalize()
        #expect(try await m.store.keptSpeakerVoiceCount() == 2)
        let export = try #require(try await m.store.meetingExport(m.id))
        var outputs: [String] = []
        for format in MeetingExportFormat.allCases {
            for options in [MeetingExportOptions(speakerLabels: .channels), MeetingExportOptions()] {
                if let text = format.render(export, options: options) { outputs.append(text) }
            }
        }
        #expect(!outputs.isEmpty)
        let bytes = VoiceMatcher.encode(m.a)
        let needles = [bytes.base64EncodedString(), bytes.map { String(format: "%02x", $0) }.joined(), "\(m.a[0])", "\(m.a[1])",
                       DiarizationModels.embeddingModelID, "embedding", "cosine", "recognized"]
        for text in outputs { for needle in needles { #expect(!text.contains(needle), "\(needle.prefix(12))") } }
        #expect(!outputs.contains { $0.contains("Ana") }, "a suggestion from a saved voice is not in any export")
        try await m.store.assignSpeaker(try await m.speaker(1).id, toEntity: ana)
        let accepted = try #require(try await m.store.meetingExport(m.id))
        #expect(MeetingExportFormat.allCases.contains { format in format.render(accepted, options: MeetingExportOptions())?.contains("Ana") == true },
                "once the user accepts it, it is a name like any other")
    }

    @Test func voiceDataIsOnlyEverTouchedByTheStoreAndTheMatchingCode() throws {
        let allowed: Set<String> = [
            "Sources/VautaCore/Storage/Schema.swift", "Sources/VautaCore/Storage/MeetingStore+VoiceProfiles.swift",
            "Sources/VautaCore/Storage/MeetingStore+VoiceRecognition.swift", "Sources/VautaCore/Storage/MeetingStore+VoiceHistory.swift", "Sources/VautaCore/Storage/MeetingStore+Speakers.swift", "Sources/VautaCore/Storage/MeetingStore+SpeakerSwitch.swift",
            "Sources/VautaCore/Storage/MeetingStore+SpeakerUndo.swift", "Sources/VautaCore/Storage/MeetingStore+Retention.swift",
            "Sources/VautaCore/Storage/MeetingStore+Diarization.swift", "Sources/VautaCore/Storage/SpeakerModels.swift",
            "Sources/VautaCore/Knowledge/MeetingStore+Context.swift", "Sources/VautaCore/Knowledge/MeetingStore+Footprint.swift",
            "Sources/VautaCore/Backup/MeetingStore+Backup.swift", "Sources/VautaCore/Knowledge/VoiceProfiles.swift",
            "Sources/VautaCore/Diarization/DiarizationModels.swift", "Sources/VautaCore/Diarization/SpeakerCentroids.swift",
            "Sources/VautaCore/Diarization/Reconstruction.swift",   // the one caller of SpeakerCentroids.compute
            "Sources/VautaCore/Diagnostics/SampleVoices.swift",   // invented bytes for the UI renderer, compiled only in the diagnostics build
        ]
        let watched = #"voice_profiles|speaker_voices|speaker_centroids|VoiceProfileEmbedding|voiceProfileEmbeddings|SpeakerVoiceDraft|SpeakerCentroids\.compute"#
        var touching: Set<String> = []
        for file in try NetworkAuditSourceScanTests.sourceFiles() {
            let code = NetworkAuditSourceScanTests.code(file.text)
            if code.range(of: watched, options: .regularExpression) != nil { touching.insert(file.path) }
        }
        #expect(touching.isSubset(of: allowed), "\(touching.subtracting(allowed).sorted()): a new file touches voice data. Is it the store or the matcher? If not, it must not.")
        for path in touching where path.hasPrefix("Sources/Vauta/") { Issue.record("\(path) is app code and touches voice data") }
        // no log, print or export line names an embedding
        for file in try NetworkAuditSourceScanTests.sourceFiles() where file.path.contains("Voice") || file.path.contains("Centroid") {
            let code = NetworkAuditSourceScanTests.code(file.text)
            #expect(code.range(of: #"\b(print|NSLog|os_log)\s*\(|Logger\b|\.debug\(|\.info\("#, options: .regularExpression) == nil, "\(file.path) logs")
        }
    }

    // MARK: Backup

    @Test func aBackupCarriesSavedAndKeptVoicesOnlyInsideThePayload() async throws {
        let m = try await Meeting()
        let ana = try await m.person("Ana")
        _ = try await m.save(m.a, for: ana)
        _ = await m.finalize()
        let file = try await m.store.createBackup(password: StorageBackupTests.password, appVersion: "0.9.0")
        #expect(file.range(of: VoiceMatcher.encode(m.a)) == nil && file.range(of: VoiceMatcher.encode(m.b)) == nil)
        let backup = try await MeetingStore.openBackup(file, password: StorageBackupTests.password)
        #expect(backup.savedVoices == 1, "the restore sheet can say that voices come back")
        let target = StoreFixture()
        var restored: MeetingStore? = try target.open()
        _ = try await restored!.restore(backup)
        restored = nil
        let reopened = try target.open()
        #expect(try await reopened.voiceProfileEmbeddings(modelID: DiarizationModels.embeddingModelID).map(\.embedding) == [VoiceMatcher.encode(m.a)])
        #expect(try await reopened.speakersWithKeptVoice(meetingID: m.id).count == 2)
        #expect(try await reopened.speaker(try await reopened.speakers(of: m.id).first { $0.ordinal == 1 && $0.channel == .others }!.id)?.source == .suggested)
    }

    // MARK: Retention

    @Test func voicesNotUsedForAYearAreProposedNeverDeleted() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let ana = try await store.saveEntity(EntityDraft(kind: .person, name: "Ana"))
        let bea = try await store.saveEntity(EntityDraft(kind: .person, name: "Bea"))
        var random = TestRandom(seed: 3)
        let old = try await store.addVoiceProfile(entityID: ana, modelID: DiarizationModels.embeddingModelID, embedding: VoiceMatcher.encode(random.unitVector()), consentRecordedAt: .now)
        _ = try await store.addVoiceProfile(entityID: bea, modelID: DiarizationModels.embeddingModelID, embedding: VoiceMatcher.encode(random.unitVector()), consentRecordedAt: .now)
        let future = Date.now.addingTimeInterval(13 * 30 * 86_400)
        #expect(try await store.unusedSavedVoices(now: .now).isEmpty)
        #expect(try await store.unusedSavedVoices(now: future).map(\.entityID).sorted() == [ana, bea])
        try await store.markVoiceProfilesMatched([old], at: future.addingTimeInterval(-86_400))
        #expect(try await store.unusedSavedVoices(now: future).map(\.entityID) == [bea], "a recent match keeps a voice")
        #expect(try await store.voiceProfiles().count == 2, "nothing was deleted by asking")
    }

    // MARK: Imported recordings

    @Test func anImportedRecordingStaysOnOneChannelAndOnlySuggestsTheUser() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        var random = TestRandom(seed: 11)
        let mine = random.unitVector(), theirs = random.unitVector()
        let me = try await store.selfEntity()
        try await store.addVoiceProfile(entityID: me, modelID: DiarizationModels.embeddingModelID, embedding: VoiceMatcher.encode(mine), consentRecordedAt: .now)
        let turns = [SpeakerTurn(start: 0, end: 31, speaker: 0), SpeakerTurn(start: 31, end: 70, speaker: 1)]
        let diarization = Diarization(turns: turns, speakerCount: 2, mapping: [], centroids: [
            VoiceMatcherTests.centroid(0, VoiceMatcherTests.vector(cosine: 0.95, from: mine)), VoiceMatcherTests.centroid(1, theirs)])
        let segments = [Segment(channel: .others, start: 1, end: 30, text: "welcome to the weekly review", isFinal: true),
                        Segment(channel: .others, start: 32, end: 60, text: "thanks, the numbers look good", isFinal: true)]
        let plan = RecordingImportPlan(fileName: "call.m4a", recordedAt: .now.addingTimeInterval(-3_600), duration: 70)
        let id = try await store.importMeeting(plan, segments: segments, locale: nil, diarization: diarization, recognizeVoices: true)
        #expect(try await store.segments(of: id).allSatisfy { $0.channel == .others }, "no line moves to Me by itself")
        let speakers = try await store.speakers(of: id)
        #expect(speakers.map(\.channel) == [.others, .others] && speakers.map(\.displayName) == ["Speaker 1", "Speaker 2"])
        #expect(speakers[0].source == .suggested && speakers[0].entityID == me, "\"Is this you?\" is only a question")
        #expect(speakers[1].source == .auto)
        #expect(try await store.speakerMeetingCount(entityID: me) == 0)

        // the same file with recognition off suggests nothing
        let plain = try await store.importMeeting(plan, segments: segments, locale: nil, diarization: diarization, recognizeVoices: false)
        #expect(try await store.speakers(of: plain).allSatisfy { $0.source == .auto })
    }

    @Test func acceptingIsThisMeOnAnImportAssignsTheUserWithoutMovingLines() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        var random = TestRandom(seed: 17)
        let mine = random.unitVector(), theirs = random.unitVector()
        let me = try await store.selfEntity()
        try await store.addVoiceProfile(entityID: me, modelID: DiarizationModels.embeddingModelID, embedding: VoiceMatcher.encode(mine), consentRecordedAt: .now)
        let turns = [SpeakerTurn(start: 0, end: 31, speaker: 0), SpeakerTurn(start: 31, end: 70, speaker: 1)]
        let diarization = Diarization(turns: turns, speakerCount: 2, mapping: [], centroids: [
            VoiceMatcherTests.centroid(0, VoiceMatcherTests.vector(cosine: 0.95, from: mine)), VoiceMatcherTests.centroid(1, theirs)])
        let segments = [Segment(channel: .others, start: 1, end: 30, text: "welcome to the weekly review", isFinal: true),
                        Segment(channel: .others, start: 32, end: 60, text: "thanks, the numbers look good", isFinal: true)]
        let plan = RecordingImportPlan(fileName: "call.m4a", recordedAt: .now.addingTimeInterval(-3_600), duration: 70)
        let id = try await store.importMeeting(plan, segments: segments, locale: nil, diarization: diarization, recognizeVoices: true)
        let suggested = try #require(try await store.speakers(of: id).first)
        #expect(suggested.source == .suggested && suggested.entityID == me)
        #expect(try await store.voiceProfiles(entityID: me).first?.lastMatchedAt == nil)
        #expect(SpeakerDirectory(speakers: try await store.speakers(of: id), selfEntity: me).namedPeople.isEmpty, "a question names nobody")

        try await store.assignSpeaker(suggested.id, toEntity: me)
        let accepted = try #require(try await store.speakers(of: id).first)
        #expect(accepted.source == .user && accepted.entityID == me && accepted.channel == .others)
        #expect(try await store.segments(of: id).allSatisfy { $0.channel == .others }, "accepting never moves lines to Me")
        #expect(try await store.voiceProfiles(entityID: me).first?.lastMatchedAt != nil)
        #expect(SpeakerDirectory(speakers: try await store.speakers(of: id), selfEntity: me).namedPeople == [me])
        #expect(try await store.speakerMeetingCount(entityID: me) == 1)
    }

    @Test func aUserSplitIntoTwoClustersIsSuggestedOnlyForTheCloserOne() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        var random = TestRandom(seed: 13)
        let mine = random.unitVector(), theirs = random.unitVector()
        let me = try await store.selfEntity()
        try await store.addVoiceProfile(entityID: me, modelID: DiarizationModels.embeddingModelID, embedding: VoiceMatcher.encode(mine), consentRecordedAt: .now)
        let turns = [SpeakerTurn(start: 0, end: 31, speaker: 0), SpeakerTurn(start: 31, end: 62, speaker: 1), SpeakerTurn(start: 62, end: 100, speaker: 2)]
        let diarization = Diarization(turns: turns, speakerCount: 3, mapping: [], centroids: [
            VoiceMatcherTests.centroid(0, VoiceMatcherTests.vector(cosine: 0.95, from: mine)),
            VoiceMatcherTests.centroid(1, VoiceMatcherTests.vector(cosine: 0.88, from: mine)),
            VoiceMatcherTests.centroid(2, theirs)])
        let segments = [Segment(channel: .others, start: 1, end: 30, text: "welcome to the weekly review", isFinal: true),
                        Segment(channel: .others, start: 32, end: 60, text: "and the second part is mine too", isFinal: true),
                        Segment(channel: .others, start: 63, end: 90, text: "thanks, the numbers look good", isFinal: true)]
        let plan = RecordingImportPlan(fileName: "call.m4a", recordedAt: .now.addingTimeInterval(-3_600), duration: 100)
        let id = try await store.importMeeting(plan, segments: segments, locale: nil, diarization: diarization, recognizeVoices: true)
        #expect(try await store.segments(of: id).allSatisfy { $0.channel == .others })
        let speakers = try await store.speakers(of: id)
        #expect(speakers.map(\.source) == [.suggested, .auto, .auto], "a person is suggested for one speaker only (the closer)")
        #expect(speakers.allSatisfy { $0.name == nil })
        #expect(try await store.isImported(meetingID: id))
        #expect(speakers.map(\.entityID) == [me, nil, nil])
    }

    @Test func aSuggestionIsNotCountedInThePersonsFootprint() async throws {
        let m = try await Meeting()
        let ana = try await m.person("Ana")
        try await m.store.finalizeSpeakers(meetingID: m.id, speakers: [SpeakerDraft(channel: .others, ordinal: 1, entityID: ana, source: .suggested)])
        let suggested = try #require(try await m.store.footprint(of: ana))
        #expect(suggested.namedSpeakers == 0, "an \"Is this Ana?\" that nobody answered is not a name")
        try await m.store.finalizeSpeakers(meetingID: m.id, speakers: [SpeakerDraft(channel: .others, ordinal: 1, entityID: ana, source: .suggested)])
        try await m.store.assignSpeaker(try await m.speaker(1).id, toEntity: ana)
        #expect(try await m.store.footprint(of: ana)?.namedSpeakers == 1, "counted once the user answers yes")
    }

    @Test func anImportedFileSuggestsButDoesNotNameSavedPeople() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        var random = TestRandom(seed: 12)
        let ana = try await store.saveEntity(EntityDraft(kind: .person, name: "Ana"))
        let voice = random.unitVector()
        try await store.addVoiceProfile(entityID: ana, modelID: DiarizationModels.embeddingModelID, embedding: VoiceMatcher.encode(voice), consentRecordedAt: .now)
        let turns = [SpeakerTurn(start: 0, end: 40, speaker: 0)]
        let diarization = Diarization(turns: turns, speakerCount: 1, mapping: [], centroids: [VoiceMatcherTests.centroid(0, voice)])
        let segments = [Segment(channel: .others, start: 1, end: 30, text: "welcome to the weekly review", isFinal: true)]
        let id = try await store.importMeeting(RecordingImportPlan(fileName: "x.m4a", recordedAt: .now.addingTimeInterval(-600), duration: 40),
                                               segments: segments, locale: nil, diarization: diarization, recognizeVoices: true)
        #expect(try await store.segments(of: id).allSatisfy { $0.channel == .others })
        let named = try await store.speakers(of: id).first
        #expect(named?.source == .suggested && named?.entityID == ana && named?.name == nil, "an imported file only suggests the people it recognizes")
    }
}
