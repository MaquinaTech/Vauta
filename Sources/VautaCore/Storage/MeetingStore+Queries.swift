// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Reading meetings and transcripts.
extension MeetingStore {
    /// All meetings, newest first (no limit: retention bounds how many there are).
    public func meetings() throws -> [Meeting] {
        try db.query("SELECT \(Self.meetingColumns) FROM meetings ORDER BY started_at DESC").map { Self.meeting($0, languageAt: 4) }
    }

    public func meeting(_ id: Int64) throws -> Meeting? {
        try db.query("SELECT \(Self.meetingColumns) FROM meetings WHERE id = ?", [.integer(id)]).first.map { Self.meeting($0, languageAt: 4) }
    }

    /// The transcript of a meeting, by time. `echoes`: also the Me lines marked as the speakers' echo (`isEcho`), for the
    /// transcript itself and the speaker tools; whatever reads it as what was said leaves them out.
    public func segments(of meetingID: Int64, echoes: Bool = false) throws -> [StoredSegment] {
        try db.query("""
            SELECT s.id, s.meeting_id, s.speaker, s.start, s.end, s.text, \(Self.speakerColumns), s.echo, s.original_text
            FROM segments s \(Self.speakerJoins) WHERE s.meeting_id = ?\(echoes ? "" : " AND \(Self.notEcho)") ORDER BY s.start, s.id
            """, [.integer(meetingID)]).map { row in
            var segment = Self.segment(row, speakerAt: 6)
            segment.isEcho = row.int(6 + Self.speakerColumnCount) == 1
            segment.originalText = row.optionalString(7 + Self.speakerColumnCount)
            return segment
        }
    }

    /// The stored translations of a meeting's segments, in segment order. Each shows only while its line reads as it did when it
    /// was translated (`translationIsCurrent`): a line corrected since has none until it is translated again. A translation that
    /// reads exactly as its line (a line already in that language) is left out.
    public func translations(of meetingID: Int64) throws -> [StoredTranslation] {
        try db.query("""
            SELECT t.segment_id, t.lang, t.text FROM segment_translations t
            JOIN segments s ON s.id = t.segment_id WHERE s.meeting_id = ? AND \(Self.translationIsCurrent) AND t.text <> s.text
            ORDER BY s.start, s.id, t.lang
            """, [.integer(meetingID)]).map { StoredTranslation(segmentID: $0.int(0), language: $0.string(1), text: $0.string(2)) }
    }

    /// Whether translation `t` was made from what line `s` reads now. One stored before translations recorded their source
    /// (version 38) is of what the transcriber wrote: it holds while the line is not corrected, and comes back with Restore Original.
    static let translationIsCurrent = "(t.source = s.text OR (t.source IS NULL AND s.original_text IS NULL))"

    /// For diagnostics: size of the encrypted files and row counts.
    public func stats() throws -> (fileBytes: Int, journalBytes: Int, meetings: Int, segments: Int) {
        func size(_ url: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 }
        let counts = try db.query("SELECT (SELECT COUNT(*) FROM meetings), (SELECT COUNT(*) FROM segments)")[0]
        return (size(file), size(journalFile), Int(counts.int(0)), Int(counts.int(1)))
    }

    /// How many chunks the search model looked at and could not embed (markers, see `VectorIndex.unembeddableMarker`): a count only.
    public func unembeddableChunkCount() throws -> Int {
        Int(try db.query("SELECT COUNT(*) FROM chunks WHERE scale <= 0")[0].int(0))
    }

    public nonisolated var fileURL: URL { file }
}
