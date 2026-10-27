// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The per-meeting "Don't separate speakers in this meeting" switch and the way back to a meeting
/// without speaker data, the one state that renders exactly like a meeting from before speakers.
extension MeetingStore {
    /// Whether the user turned off separating speakers for this meeting. While it is on,
    /// `finalizeSpeakers` writes nothing, so a re-finalization or a re-import keeps the meeting clean.
    public func speakersOff(meetingID: Int64) throws -> Bool {
        try db.query("SELECT speakers_off FROM meetings WHERE id = ?", [.integer(meetingID)]).first?.int(0) == 1
    }

    /// Turns the switch on or off. It does not touch the speakers a meeting already has: turning it on
    /// is usually followed by `clearSpeakers(meetingID:)`.
    public func setSpeakersOff(_ off: Bool, meetingID: Int64) async throws {
        try transaction {
            try run("UPDATE meetings SET speakers_off = ? WHERE id = ?", [.integer(off ? 1 : 0), .integer(meetingID)])
        }
        try await commitEdit()
    }

    /// Removes every speaker of the meeting, the user's included, and what the segments say about
    /// them (speaker, confidence, overlap, lock). Segments that were split stay split. Returns what
    /// undoes it.
    @discardableResult
    public func clearSpeakers(meetingID: Int64) async throws -> SpeakerUndo {
        var removedVoices = false
        let undo: SpeakerUndo = try transaction {
            guard try !db.query("SELECT 1 FROM meetings WHERE id = ?", [.integer(meetingID)]).isEmpty else { return SpeakerUndo() }
            let ids = try db.query("SELECT id FROM meeting_speakers WHERE meeting_id = ?", [.integer(meetingID)]).map { $0.int(0) }
            let undo = try SpeakerUndo(speakers: speakerRows(ids), segments: segmentStates("""
                WHERE meeting_id = ? AND (speaker_id IS NOT NULL OR speaker_confidence IS NOT NULL OR overlap <> 0 OR speaker_locked <> 0)
                """, [.integer(meetingID)]))
            try run("""
                UPDATE segments SET speaker_id = NULL, speaker_confidence = NULL, overlap = 0, speaker_locked = 0 WHERE meeting_id = ?
                """, [.integer(meetingID)])
            // The kept voice summaries go with the speakers (cascade): saved at once, like every removal of voice data.
            removedVoices = try hasVoiceData(speakersWhere: "meeting_id = ?", [.integer(meetingID)])
            try run("DELETE FROM meeting_speakers WHERE meeting_id = ?", [.integer(meetingID)])
            return undo
        }
        try await commitEdit()
        if removedVoices { try await saveAfterVoiceDataRemoved() }
        return undo
    }
}
