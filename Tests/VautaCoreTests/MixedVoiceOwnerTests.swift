// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// A speaker whose voice cluster spreads out probably holds two voices: its spread is stored with the speaker (schema 32), its lines
/// read as `mixesVoices`, and an owner one of them gives is kept but marked "not confirmed".
@Suite("Speakers: a cluster that holds two voices")
struct MixedVoiceOwnerTests {
    /// Two remote speakers (the first one loose) and the user.
    private func diarizedMeeting(_ f: KnowledgeFixture, spreads: [Float] = [0.52, 0.9]) async throws -> Int64 {
        let id = try await f.store.startMeeting(at: .now)
        try await f.store.append(Segment(channel: .others, start: 1, end: 8, text: "I'll send the contract to legal", isFinal: true), to: id)
        try await f.store.append(Segment(channel: .others, start: 11, end: 18, text: "I'll book the room for Thursday", isFinal: true), to: id)
        try await f.store.append(Segment(channel: .me, start: 21, end: 28, text: "Fine, thanks", isFinal: true), to: id)
        try await f.store.endMeeting(id, at: .now.addingTimeInterval(60))
        var random = TestRandom(seed: 3)
        let diarization = Diarization(turns: [SpeakerTurn(start: 0, end: 10, speaker: 0), SpeakerTurn(start: 10, end: 20, speaker: 1)],
                                      speakerCount: 2, mapping: [],
                                      centroids: spreads.indices.map { VoiceMatcherTests.centroid($0, random.unitVector(), spread: spreads[$0]) })
        #expect(try await f.store.applyDiarization(diarization, to: id) == 2)
        return id
    }

    @Test func theSpreadIsKeptWithTheSpeakerAndReadAsAFlag() async throws {
        let f = try KnowledgeFixture()
        let id = try await diarizedMeeting(f)
        var lines = try await f.store.segments(of: id)
        #expect(lines.map { $0.speaker?.mixesVoices } == [true, false, false])
        #expect(lines.map { $0.speaker?.mayBeAnotherVoice } == [true, false, false])
        try await f.reopen()
        lines = try await f.store.segments(of: id)
        #expect(lines.map { $0.speaker?.mixesVoices } == [true, false, false])
        // A line the user moved by hand is their word: still the loose speaker's, never "maybe another voice".
        let loose = try #require(lines[0].speaker?.id)
        try await f.store.reassignSegment(lines[0].id, toSpeaker: loose)
        let moved = try #require(try await f.store.segments(of: id).first?.speaker)
        #expect(moved.mixesVoices && !moved.mayBeAnotherVoice)
        // At the gate itself the cluster counts as one voice; a later diarization replaces the value.
        let tight = try await diarizedMeeting(f, spreads: [VoiceProfileThresholds.minimumSpread, 0.9])
        #expect(try await f.store.segments(of: tight).allSatisfy { $0.speaker?.mixesVoices == false })
    }

    @Test func undoingAMergeGivesTheSpeakerItsSpreadBack() async throws {
        let f = try KnowledgeFixture()
        let id = try await diarizedMeeting(f)
        let speakers = try await f.store.speakers(of: id).filter { $0.channel == .others }.sorted { $0.ordinal < $1.ordinal }
        let undo = try await f.store.mergeSpeaker(speakers[0].id, into: speakers[1].id)
        #expect(try await f.store.segments(of: id).allSatisfy { $0.speaker?.mixesVoices == false })
        try await f.store.undo(undo)
        #expect(try await f.store.segments(of: id).map { $0.speaker?.mixesVoices } == [true, false, false])
    }

    @Test func aSpeakerOfTwoVoicesKeepsTheOwnerItGivesButMarksIt() {
        let me: Int64 = 1, ana: Int64 = 5
        let people = [CandidateEntity(id: me, kind: .person, name: "Maya", aliases: []),
                      CandidateEntity(id: ana, kind: .person, name: "Ana Ruiz", aliases: ["Ana"])]
        let directory = SpeakerDirectory(speakers: [
            MeetingSpeaker(id: 100, meetingID: 1, channel: .me, ordinal: 1),
            MeetingSpeaker(id: 101, meetingID: 1, channel: .others, ordinal: 1, entityID: ana, entityName: "Ana Ruiz", source: .user),
        ], selfEntity: me)
        func line(confidence: Double? = 0.9, mixed: Bool) -> CitableSegment {
            CitableSegment(id: 1, channel: .others, start: 0, text: "I'll send the contract to legal",
                           speaker: SpeakerTag(id: 101, ordinal: 1, confidence: confidence, mixesVoices: mixed))
        }
        func resolve(_ proposed: Int64?, _ seg: CitableSegment) -> OwnerVerdict {
            OwnerResolver.resolve(proposed: proposed, segment: seg, directory: directory, selfEntity: me,
                                  byID: Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) }), meetingPeople: [ana])
        }
        func infer(_ seg: CitableSegment) -> OwnerInference.Result {
            OwnerInference.infer(text: "Send the contract to legal", quote: "send the contract to legal", segment: seg, order: SegmentOrder([seg]),
                                 directory: directory, selfEntity: me, people: people, meetingPeople: [ana], hint: .init(entity: ana), language: "en")
        }
        // One voice: the confident speaker's commitment is theirs, settled.
        #expect(resolve(ana, line(mixed: false)) == OwnerVerdict(owner: ana, uncertain: false, deterministic: true))
        #expect(resolve(nil, line(mixed: false)) == OwnerVerdict(owner: ana, uncertain: false, deterministic: true))
        #expect(infer(line(mixed: false)) == OwnerInference.Result(owner: ana, ownerSpeaker: nil, uncertain: false, rule: "self"))
        // Two voices: the same owner, marked, in both extractions.
        #expect(resolve(ana, line(mixed: true)) == OwnerVerdict(owner: ana, uncertain: true, deterministic: false))
        #expect(resolve(nil, line(mixed: true)) == OwnerVerdict(owner: ana, uncertain: true, deterministic: false))
        #expect(infer(line(mixed: true)) == OwnerInference.Result(owner: ana, ownerSpeaker: nil, uncertain: true, rule: "self"))
        // A doubtful label still gives nobody, and a line the user moved (no score) is theirs whatever the cluster.
        #expect(resolve(ana, line(confidence: 0.4, mixed: true)) == OwnerVerdict())
        #expect(resolve(ana, line(confidence: nil, mixed: true)) == OwnerVerdict(owner: ana, uncertain: false, deterministic: true))
    }
}
