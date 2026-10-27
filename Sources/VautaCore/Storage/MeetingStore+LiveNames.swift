// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

extension MeetingStore {
    /// After the speakers of a live recording are written: the names the user typed while recording go to the final
    /// speakers that hold the same voice (`LiveSpeakers.carryOver`). They are user assignments, so they win over a
    /// suggestion that came from a voice: a speaker that only holds a `suggested` person is
    /// handed to the user's choice, and a person the user named is taken away from any other speaker a voice
    /// suggested them for. A speaker the user already named is never changed.
    public func carryOverLiveNames(meetingID: Int64, named: [Int: Int64], live: [LiveSpeakers.LiveSpan]) async throws {
        guard !named.isEmpty else { return }
        let speakers = try speakers(of: meetingID)
        let userNamed = speakers.filter { $0.source == .user && $0.entityID != nil }
        let stored = try segments(of: meetingID).compactMap { line -> LiveSpeakers.StoredSpan? in
            guard line.channel == .others, let id = line.speaker?.id else { return nil }
            return LiveSpeakers.StoredSpan(speakerID: id, hasPerson: userNamed.contains { $0.id == id }, start: line.start, end: line.end)
        }
        let pairs = LiveSpeakers.carryOver(named: named, live: live, stored: stored, alreadyNamed: Set(userNamed.compactMap(\.entityID)))
        for pair in pairs {
            _ = try await assignSpeaker(pair.speakerID, toEntity: pair.entityID)
            try transaction {
                try run("""
                    UPDATE meeting_speakers SET entity_id = NULL, source = 'auto'
                    WHERE meeting_id = ?1 AND id <> ?2 AND source = 'suggested'
                      AND entity_id IN (SELECT id FROM entities WHERE id = ?3 OR merged_into = ?3)
                    """, [.integer(meetingID), .integer(pair.speakerID), .integer(pair.entityID)])
            }
            try await commitEdit()
        }
    }
}
