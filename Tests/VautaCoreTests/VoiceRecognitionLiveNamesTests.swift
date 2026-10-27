// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Voice profiles: the user's live names beat voice matches, a corrected cluster is never remembered,
/// the own-voice split is cautious, and deleting a voice takes its suggestions with it.
extension VoiceRecognitionTests {
    private func liveSpans(_ ordinals: [(Int, Double)]) -> [LiveSpeakers.LiveSpan] {
        ordinals.map { LiveSpeakers.LiveSpan(ordinal: $0.0, start: $0.1, end: $0.1 + 4) }
    }

    // MARK: Live names are the user's word

    @Test func aNameTypedWhileRecordingBeatsASuggestionOnTheSameSpeaker() async throws {
        let m = try await Meeting()
        let bob = try await m.person("Bob"), carol = try await m.person("Carol")
        _ = try await m.save(VoiceMatcherTests.vector(cosine: 0.75, from: m.a), for: carol)
        #expect(await m.finalize() == .written(2))
        #expect(try await m.speaker(1).source == .suggested)
        try await m.store.carryOverLiveNames(meetingID: m.id, named: [1: bob], live: liveSpans([(1, 10), (2, 120)]))
        let first = try await m.speaker(1)
        #expect(first.source == .user && first.entityID == bob, "the user's live name replaced the suggestion")
    }

    @Test func aNameTypedWhileRecordingTakesThePersonFromASuggestionOnAnotherSpeaker() async throws {
        let m = try await Meeting()
        let bob = try await m.person("Bob")
        _ = try await m.save(m.a, for: bob)   // the voice suggests Bob for the FIRST speaker
        #expect(await m.finalize() == .written(2))
        #expect(try await m.speaker(1).source == .suggested)
        // ...but while recording the user named the voice heard at 120 s (the second speaker) Bob.
        try await m.store.carryOverLiveNames(meetingID: m.id, named: [2: bob], live: liveSpans([(1, 10), (2, 120)]))
        let first = try await m.speaker(1), second = try await m.speaker(2)
        #expect(second.source == .user && second.entityID == bob)
        #expect(first.entityID == nil && first.source == .auto, "the person is not on two speakers")
    }

    @Test func aLiveNameNeverReplacesANameTheUserGaveAfterwards() async throws {
        let m = try await Meeting()
        let bob = try await m.person("Bob"), ana = try await m.person("Ana")
        _ = await m.finalize()
        try await m.store.assignSpeaker(try await m.speaker(1).id, toEntity: ana)
        try await m.store.carryOverLiveNames(meetingID: m.id, named: [1: bob], live: liveSpans([(1, 10)]))
        #expect(try await m.speaker(1).entityID == ana)
    }

    // MARK: A corrected cluster is never remembered

    @Test func splittingALineOffASpeakerDropsItsKeptVoice() async throws {
        let m = try await Meeting()
        let ana = try await m.person("Ana")
        #expect(await m.finalize() == .written(2))
        let first = try await m.speaker(1), second = try await m.speaker(2)
        try await m.store.assignSpeaker(first.id, toEntity: ana)
        #expect(try await m.store.speakersWithKeptVoice(meetingID: m.id).contains(first.id))
        let line = try #require(try await m.store.segments(of: m.id).first { $0.speaker?.id == first.id })
        _ = try await m.store.splitSegment(line.id, atCharacter: 10, rightSpeaker: second.id)
        #expect(try await m.store.speakersWithKeptVoice(meetingID: m.id).isEmpty, "both summaries may now hold two people")
        await #expect(throws: StoreError.self) { try await m.store.rememberVoice(speakerID: first.id, consentRecordedAt: .now) }
        #expect(try await m.store.voiceProfiles().isEmpty)
    }

    @Test func movingALineToAnotherSpeakerDropsTheKeptVoices() async throws {
        let m = try await Meeting()
        let ana = try await m.person("Ana")
        _ = await m.finalize()
        let first = try await m.speaker(1), second = try await m.speaker(2)
        try await m.store.assignSpeaker(first.id, toEntity: ana)
        let line = try #require(try await m.store.segments(of: m.id).first { $0.speaker?.id == first.id })
        // moving a line to the speaker it already has changes nothing
        try await m.store.reassignSegment(line.id, toSpeaker: first.id)
        #expect(try await m.store.speakersWithKeptVoice(meetingID: m.id).count == 2)
        try await m.store.reassignSegment(line.id, toSpeaker: second.id)
        #expect(try await m.store.speakersWithKeptVoice(meetingID: m.id).isEmpty)
        await #expect(throws: StoreError.self) { try await m.store.rememberVoice(speakerID: first.id, consentRecordedAt: .now) }
    }

    @Test func theUsersOwnVoiceIsNotSavedFromARemoteSpeakerOfALiveRecording() async throws {
        let m = try await Meeting()
        _ = await m.finalize()
        let first = try await m.speaker(1)
        try await m.store.assignSpeaker(first.id, toEntity: try await m.store.selfEntity())
        await #expect(throws: StoreError.self) { try await m.store.rememberVoice(speakerID: first.id, consentRecordedAt: .now) }
        #expect(try await m.store.voiceProfiles().isEmpty)
    }

    // MARK: Use and suggestions

    @Test func aProfileWhoseNameLandedOnNobodyIsNotCountedAsUsed() async throws {
        let m = try await Meeting()
        let ana = try await m.person("Ana")
        let profile = try await m.save(m.a, for: ana)
        _ = await m.finalize(recognize: false)
        // The user cleared the name of the first speaker: that decision is theirs.
        try await m.store.assignSpeaker(try await m.speaker(1).id, toEntity: nil)
        _ = await m.finalize()
        let named = try await m.store.speakers(of: m.id).filter { $0.source == .suggested }
        #expect(named.isEmpty, "the user's cleared name was kept")
        #expect(try await m.store.voiceProfiles().first { $0.id == profile }?.lastMatchedAt == nil)
    }

    @Test func deletingAVoiceTakesItsSuggestionsButNotTheNamesTheUserGave() async throws {
        let m = try await Meeting()
        let ana = try await m.person("Ana"), bea = try await m.person("Bea")
        _ = try await m.save(VoiceMatcherTests.vector(cosine: 0.75, from: m.a), for: ana)
        _ = try await m.save(m.b, for: bea)
        _ = await m.finalize()
        #expect(try await m.speaker(1).source == .suggested && m.store != nil)
        #expect(try await m.speaker(2).source == .suggested)
        try await m.store.assignSpeaker(try await m.speaker(2).id, toEntity: bea)
        try await m.store.deleteVoiceProfiles(entityID: ana)
        let first = try await m.speaker(1)
        #expect(first.source == .auto && first.entityID == nil, "nothing asks \"Is this Ana?\" about a voice that no longer exists")
        try await m.store.deleteAllVoiceProfiles()
        #expect(try await m.speaker(2).source == .user, "a name the user accepted stays")
    }

    @Test func aSuggestionStaysWhileAnotherFingerprintOfThePersonRemains() async throws {
        let m = try await Meeting()
        let ana = try await m.person("Ana")
        let one = try await m.save(VoiceMatcherTests.vector(cosine: 0.75, from: m.a), for: ana)
        _ = try await m.save(VoiceMatcherTests.vector(cosine: 0.75, from: m.a), for: ana)
        _ = await m.finalize()
        try await m.store.deleteVoiceProfile(one)
        #expect(try await m.speaker(1).source == .suggested)
    }

    @Test func theUsersOwnSavedVoiceIsListedFirst() async throws {
        let m = try await Meeting()
        let ana = try await m.person("Ana")
        _ = try await m.save(m.b, for: try await m.store.selfEntity())
        _ = try await m.save(m.a, for: ana)
        #expect(try await m.store.savedVoices().map(\.isSelf) == [true, false])
    }

    @Test func mergingPeopleKeepsTheCurrentModelsFingerprintsWhateverIsNewest() async throws {
        let m = try await Meeting()
        let target = try await m.person("Ana"), source = try await m.person("Ana García")
        for _ in 0..<MeetingStore.maxVoiceProfilesPerPerson { _ = try await m.save(m.a, for: target) }
        _ = try await m.save(m.b, for: source, model: "older-speaker-model")
        try await m.store.mergeEntity(source, into: target)
        let kept = try await m.store.voiceProfiles(entityID: target)
        #expect(kept.count == MeetingStore.maxVoiceProfilesPerPerson)
        #expect(kept.allSatisfy { $0.modelID == DiarizationModels.embeddingModelID })
    }

    // MARK: The user's own voice on an import

    private func importOne(_ store: MeetingStore, _ centroid: [Float]) async throws -> (channels: [Channel], speakers: [MeetingSpeaker]) {
        let turns = [SpeakerTurn(start: 0, end: 40, speaker: 0)]
        let diarization = Diarization(turns: turns, speakerCount: 1, mapping: [], centroids: [VoiceMatcherTests.centroid(0, centroid)])
        let segments = [Segment(channel: .others, start: 1, end: 30, text: "welcome to the weekly review", isFinal: true)]
        let id = try await store.importMeeting(RecordingImportPlan(fileName: "x.m4a", recordedAt: .now.addingTimeInterval(-600), duration: 40),
                                               segments: segments, locale: nil, diarization: diarization, recognizeVoices: true)
        return (try await store.segments(of: id).map(\.channel), try await store.speakers(of: id))
    }

    @Test func theUsersVoiceNeverMovesALineToMeHoweverCloseItIs() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        var random = TestRandom(seed: 21)
        let mine = random.unitVector()
        let me = try await store.selfEntity()
        try await store.addVoiceProfile(entityID: me, modelID: DiarizationModels.embeddingModelID,
                                        embedding: VoiceMatcher.encode(mine), consentRecordedAt: .now)
        for cosine: Float in [0.99, 0.92, 0.75] {
            let result = try await importOne(store, VoiceMatcherTests.vector(cosine: cosine, from: mine))
            #expect(result.channels == [.others], "cosine \(cosine)")
            #expect(result.speakers.map(\.source) == [.suggested] && result.speakers[0].entityID == me && result.speakers[0].name == nil)
        }
        let far = try await importOne(store, VoiceMatcherTests.vector(cosine: 0.5, from: mine))
        #expect(far.channels == [.others] && far.speakers.map(\.source) == [.auto])
    }

    @Test func aColleaguesSimilarVoiceCanWinTheSuggestionOverTheUser() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        var random = TestRandom(seed: 22)
        let mine = random.unitVector()
        let me = try await store.selfEntity(), colleague = try await store.saveEntity(EntityDraft(kind: .person, name: "Dan"))
        let centroid = VoiceMatcherTests.vector(cosine: 0.92, from: mine)
        let theirVoice = VoiceMatcherTests.vector(cosine: 0.93, from: centroid, seed: 7)
        for (person, voice) in [(me, mine), (colleague, theirVoice)] {
            try await store.addVoiceProfile(entityID: person, modelID: DiarizationModels.embeddingModelID, embedding: VoiceMatcher.encode(voice), consentRecordedAt: .now)
        }
        let result = try await importOne(store, centroid)
        #expect(result.channels == [.others] && result.speakers.map(\.source) == [.suggested], "one question, the closest person, never a name")
        #expect(result.speakers[0].name == nil)
        #expect(result.speakers[0].entityID == colleague, "the closer voice (0.93 against 0.92) is the one asked about")
    }
}
