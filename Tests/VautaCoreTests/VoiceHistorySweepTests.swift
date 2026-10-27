// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

extension MeetingStore {
    func execForTesting(_ statements: [(String, [SQLiteValue?])]) throws {
        try transaction { for (sql, params) in statements { try run(sql, params) } }
    }
}

/// The sweep keeps to the 14-day window by itself and never leaves two suggestions of one person in a meeting.
@Suite("Voice history sweep")
struct VoiceHistorySweepTests {
    @Test func aCentroidOlderThanTheWindowIsNotSearchedEvenIfThePurgeHasNotRun() async throws {
        let (m, ids, ana) = try await VoiceHistoryTests.world(earlier: 2)
        _ = try await m.save(m.a, for: ana)
        let old = Date.now.timeIntervalSince1970 - Double(VoiceProfileThresholds.keptSummaryDays + 1) * 86_400
        try await m.store.execForTesting([
            ("UPDATE speaker_centroids SET created_at = ? WHERE speaker_id IN (SELECT id FROM meeting_speakers WHERE meeting_id = ?)", [.real(old), .integer(ids[0])]),
            ("UPDATE speaker_voices SET created_at = ? WHERE speaker_id IN (SELECT id FROM meeting_speakers WHERE meeting_id = ?)", [.real(old), .integer(ids[0])]),
        ])
        let sweep = try await m.store.suggestVoiceInPastMeetings(of: ana, excludingMeeting: m.id, recognizing: true)
        #expect(sweep.matches.map(\.meetingID) == [ids[1]], "the aged meeting is out of the window")
        #expect(try await VoiceHistoryTests.speaker(m, ids[0], 1).source == .auto)
    }

    @Test func aNewFindReplacesAnOlderSuggestionOfTheSamePersonInThatMeeting() async throws {
        let (m, ids, ana) = try await VoiceHistoryTests.world(earlier: 1)
        _ = try await m.save(m.a, for: ana)
        let other = try await VoiceHistoryTests.speaker(m, ids[0], 2)
        try await m.store.execForTesting([("UPDATE meeting_speakers SET entity_id = ?, source = 'suggested' WHERE id = ?", [.integer(ana), .integer(other.id)])])
        let sweep = try await m.store.suggestVoiceInPastMeetings(of: ana, excludingMeeting: m.id, recognizing: true)
        #expect(sweep.matches.count == 1)
        let first = try await VoiceHistoryTests.speaker(m, ids[0], 1), second = try await VoiceHistoryTests.speaker(m, ids[0], 2)
        #expect(first.entityID == ana && first.source == .suggested)
        #expect(second.entityID == nil && second.source == .auto, "one suggestion of Ana per meeting")
        try await m.store.undo(sweep.undo)
        let back = try await VoiceHistoryTests.speaker(m, ids[0], 2)
        #expect(back.entityID == ana && back.source == .suggested, "undo restores the replaced suggestion too")
        #expect(try await VoiceHistoryTests.speaker(m, ids[0], 1).source == .auto)
    }

    @Test func aFindOnTheSpeakerAlreadySuggestedAsThisPersonIsNotCounted() async throws {
        let (m, ids, ana) = try await VoiceHistoryTests.world(earlier: 2)
        _ = try await m.save(m.a, for: ana)
        let first = try await m.store.suggestVoiceInPastMeetings(of: ana, excludingMeeting: m.id, recognizing: true)
        #expect(first.matches.count == 2)
        let again = try await m.store.suggestVoiceInPastMeetings(of: ana, excludingMeeting: m.id, recognizing: true)
        #expect(again.isEmpty, "nothing new: the same speakers are already suggested")
        for id in ids { #expect(try await VoiceHistoryTests.speaker(m, id, 1).source == .suggested) }
    }
}
