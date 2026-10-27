// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import Foundation

/// Invented voice-recognition states for the UI snapshot renderer. The "voices" are bytes with no meaning: nothing here
/// is, or was made from, a real voice.
extension SampleWorld {
    private var sampleVoice: Data { Data((0..<1024).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }) }

    /// Saves invented voices for the user and two people of the sample context. `monthsAgo` dates every voice (when it was
    /// saved, and when a suggestion from it was last accepted) that long ago, so the 12-month reminder and the list agree.
    public func seedSavedVoices(olderModel: Bool = false, monthsAgo: Int = 0) async throws {
        try await store.deleteAllVoiceProfiles()
        let age = monthsAgo > 0 ? Double(monthsAgo) * 30 * 86_400 : 0
        let consent = AppClock.now.addingTimeInterval(-40 * 86_400 - age)
        let me = try await store.selfEntity()
        for person in [peopleIDs[2], peopleIDs[3], me] {
            // `olderModel`: Priya's voice was made by another speaker model, which the app cannot use.
            let model = olderModel && person == peopleIDs[3] ? "older-speaker-model" : DiarizationModels.embeddingModelID
            let id = try await store.addVoiceProfile(entityID: person, modelID: model, embedding: sampleVoice, consentRecordedAt: consent)
            if person == peopleIDs[2] { try await store.markVoiceProfilesMatched([id], at: AppClock.now.addingTimeInterval(-3 * 86_400 - age)) }
        }
        _ = try await store.addVoiceProfile(entityID: peopleIDs[2], modelID: DiarizationModels.embeddingModelID, embedding: sampleVoice, consentRecordedAt: consent)
        if age > 0 { try await store.ageVoiceProfilesForSnapshots(by: age) }
    }

    /// The featured meeting as it reads with voice recognition on: the second of the others (who answers
    /// about the beta) is Daniel, whom the user accepted when a saved voice suggested him, the third (who has the onboarding
    /// screens) is only suggested (“Is this Priya?”), the first (who opens the meeting) is unknown, and
    /// every speaker's voice was kept so “Remember this voice” is offered.
    public func seedSuggestedSpeakers(thirdIsMe: Bool = false) async throws {
        try await resetSpeakerSamples()
        // `thirdIsMe`: the user's own saved voice is what resembles the third speaker (“Is this you?”). The featured sample is a live recording; the popover looks the same as in an imported one, which is the only place the product asks this.
        let thirdEntity = thirdIsMe ? try await store.selfEntity() : peopleIDs[3]
        let plan: [(ordinal: Int, confidence: Double, overlap: Bool)?] = [
            (1, 0.95, false), (2, 0.97, false), nil, (3, 0.93, false), (1, 0.70, true), nil, (2, 0.90, false), nil,
            (2, 0.45, false), (1, 0.88, false), (1, 0.91, false), nil, (2, 0.96, false), (1, 0.90, false),
        ]
        var assignments: [SegmentSpeakerAssignment] = []
        for (index, id) in featuredSegmentIDs.enumerated() where index < plan.count {
            if let line = plan[index] {
                assignments.append(SegmentSpeakerAssignment(segmentID: id, channel: .others, ordinal: line.ordinal, confidence: line.confidence, overlap: line.overlap))
            } else {
                assignments.append(SegmentSpeakerAssignment(segmentID: id, channel: .me, ordinal: 1, confidence: 0.99))
            }
        }
        try await store.finalizeSpeakers(meetingID: featuredMeetingID, speakers: [
            SpeakerDraft(channel: .me, ordinal: 1),
            SpeakerDraft(channel: .others, ordinal: 1),
            SpeakerDraft(channel: .others, ordinal: 2, entityID: peopleIDs[2], source: .suggested),
            SpeakerDraft(channel: .others, ordinal: 3, entityID: thirdEntity, source: .suggested),
        ], assignments: assignments, voices: (1...3).map {
            SpeakerVoiceDraft(channel: .others, ordinal: $0, modelID: DiarizationModels.embeddingModelID, embedding: sampleVoice)
        })
        // Daniel was suggested and the user answered Yes: an ordinary assignment, so he is named. The accept path sets
        // the person's last_matched_at to now, so the date `seedSavedVoices` gave the voice is put back afterwards.
        if let daniel = try await store.speakers(of: featuredMeetingID).first(where: { $0.channel == .others && $0.ordinal == 2 }) {
            let before = try await store.voiceProfiles().filter { $0.entityID == peopleIDs[2] }.map { ($0.id, $0.lastMatchedAt) }
            _ = try await store.assignSpeaker(daniel.id, toEntity: peopleIDs[2])
            try await store.restoreLastMatchedForSnapshots(before)
        }
    }
}

extension MeetingStore {
    /// Puts back the `last_matched_at` values of voices (a sample seeded with a deliberate date).
    func restoreLastMatchedForSnapshots(_ dates: [(Int64, Date?)]) async throws {
        for (id, date) in dates {
            try run("UPDATE voice_profiles SET last_matched_at = ? WHERE id = ?", [date.map { .real($0.timeIntervalSince1970) }, .integer(id)])
        }
        try await commitEdit()
    }

    /// Moves the creation time of every voice back, as if they had been saved that long ago.
    func ageVoiceProfilesForSnapshots(by seconds: Double) async throws {
        try run("UPDATE voice_profiles SET created_at = created_at - ?", [.real(seconds)])
        try await commitEdit()
    }
}
#endif
