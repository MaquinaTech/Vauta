// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// A passage a person said, as the card of that person quotes it.
public struct SpokenQuote: Sendable, Identifiable, Hashable {
    public var id: Int64 { segmentID }
    public let meeting: MeetingStore.Meeting
    public let segmentID: Int64
    public let t: Double
    public let text: String
}

extension MeetingStore {
    /// What a person said: one passage per meeting, newest meetings first, from the lines of the speakers the user
    /// named as that person. A line the app is unsure about, one said over somebody else
    /// and a very short one are never quoted: a quote puts words in somebody's mouth. The longest line of a meeting
    /// is the one shown. Empty once the transcripts are gone.
    public func spokenQuotes(_ entityID: Int64, limit: Int = 5) throws -> [SpokenQuote] {
        // One row per meeting is chosen in SQL, so a person who speaks a lot in a few meetings cannot crowd out older
        // ones. In Chinese, Japanese and Korean a whole sentence is often shorter than 24 characters: a line with
        // kana, Han characters or hangul needs 8.
        let rows = try db.query("""
            WITH ranked AS (
                SELECT s.id AS sid, s.meeting_id AS mid, s.start AS st, s.text AS tx,
                       ROW_NUMBER() OVER (PARTITION BY s.meeting_id ORDER BY length(s.text) DESC, s.id) AS rn
                FROM segments s JOIN meeting_speakers sp ON sp.id = s.speaker_id
                WHERE sp.entity_id IN (SELECT id FROM entities WHERE id = ?1 OR merged_into = ?1)
                  AND sp.source = 'user' AND s.overlap = 0 AND \(Self.notEcho)
                  AND (s.speaker_confidence IS NULL OR s.speaker_confidence >= ?2)
                  AND (length(s.text) >= 24 OR (length(s.text) >= 8 AND s.text GLOB '*[\u{3040}-\u{30FF}\u{4E00}-\u{9FFF}\u{AC00}-\u{D7AF}]*'))
            )
            SELECT \(Self.meetingColumns(alias: "mt")), r.sid, r.st, r.tx
            FROM ranked r JOIN meetings mt ON mt.id = r.mid
            WHERE r.rn = 1
            ORDER BY mt.started_at DESC
            LIMIT ?3
            """, [.integer(entityID), .real(SpeakerTag.lowConfidenceBelow), .integer(Int64(limit))])
        return rows.map { SpokenQuote(meeting: Self.meeting($0, languageAt: 4), segmentID: $0.int(7), t: $0.double(8), text: $0.string(9)) }
    }
}
