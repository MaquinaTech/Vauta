// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Splitting a segment where the speaker changes: by the user (`splitSegment`) or by the aligner at
/// finalization (`finalizeSpeakers(..., splits:)`, which calls `splitInTransaction`).
///
/// Ordering. The left part keeps the segment's ID, so everything that cites it stays valid; the
/// right part is a new row, so its ID is the largest. Order everywhere is by `(start, id)`, which a
/// split does not disturb. Citations (mentions, suggestions, decisions, tasks) move to the right
/// part when their surface occurs only in the right text, or, without a surface, when their time is
/// at or after the split; the rest stay on the left. Live notes keep their citations as written (they
/// are a recording-time draft). The full-text index is updated by hand for the left part (there is no
/// update trigger) and by trigger for the right part.
///
/// Translations. A split by the user deletes the segment's translations (they translate the unsplit
/// text; `SpeakerUndo` brings them back) and they are made again afterwards. The aligner splits at
/// finalization, BEFORE translations are refined, so it keeps what exists: each translation is cut
/// at the space nearest to the same proportion of its text, which is approximate and is replaced
/// when the segments are translated again.
///
/// Corrected lines. What the transcriber wrote (`original_text`) is cut at the same word as the correction
/// (`TranscriptCorrection.oldCut`), so each part can still be restored on its own.
extension MeetingStore {
    static let cannotSplit = StoreError(.cannotSplit)

    /// Splits a segment in two where the speaker changes, at a character boundary (`offset` characters
    /// stay on the left). `time` is where the right part starts; without it the time is interpolated
    /// from the offset. Both parts need text and a time strictly inside the segment. The right part
    /// gets `rightSpeaker` (default: the left part's speaker). Both parts are locked to their speaker:
    /// this is the user's decision. Refused while the meeting is being recorded. The aligner does not
    /// use this: its splits go through `finalizeSpeakers(meetingID:speakers:assignments:splits:)`,
    /// which does not lock, is atomic with the speakers and works on a meeting being recorded.
    @discardableResult
    public func splitSegment(_ segmentID: Int64, atCharacter offset: Int, time: Double? = nil,
                             rightSpeaker: Int64? = nil) async throws -> SegmentSplit {
        var removedVoices = false
        let result: SegmentSplit = try transaction {
            let leftSpeaker = try db.query("SELECT speaker_id FROM segments WHERE id = ?", [.integer(segmentID)]).first?.optionalInt(0)
            let (id, undo) = try splitInTransaction(segmentID, atCharacter: offset, time: time, rightSpeaker: rightSpeaker, byUser: true)
            // Part of a speaker's lines now belongs to someone else: the kept voice summary may hold two people.
            if let rightSpeaker, rightSpeaker != leftSpeaker { removedVoices = try dropKeptVoices(of: [leftSpeaker, rightSpeaker]) }
            return SegmentSplit(rightSegmentID: id, undo: undo)
        }
        vectorCache = nil
        try await commitEdit()
        if removedVoices { try await saveAfterVoiceDataRemoved() }
        return result
    }

    /// Splits a segment at a time (see `splitSegment(_:atCharacter:time:rightSpeaker:)`). The character
    /// boundary is interpolated from the time and moved to the nearest space.
    @discardableResult
    public func splitSegment(_ segmentID: Int64, atTime time: Double, rightSpeaker: Int64? = nil) async throws -> SegmentSplit {
        guard let seg = try db.query("SELECT start, end, text FROM segments WHERE id = ?", [.integer(segmentID)]).first else {
            throw Self.segmentGone
        }
        let (start, end) = (seg.double(0), seg.double(1))
        let characters = Array(seg.string(2))
        guard end > start, time > start, time < end, characters.count > 1 else { throw Self.cannotSplit }
        let guess = min(characters.count - 1, max(1, Int((Double(characters.count) * (time - start) / (end - start)).rounded())))
        let spaces = characters.indices.filter { characters[$0].isWhitespace && $0 > 0 && $0 < characters.count - 1 }
        let offset = spaces.min { abs($0 - guess) < abs($1 - guess) } ?? guess
        return try await splitSegment(segmentID, atCharacter: offset, time: time, rightSpeaker: rightSpeaker)
    }

    /// The split itself, inside the caller's transaction. `byUser` locks both parts, refuses the meeting
    /// being recorded and drops the translations; otherwise the parts inherit the segment's lock and
    /// the translations are cut proportionally.
    func splitInTransaction(_ segmentID: Int64, atCharacter offset: Int, time: Double?, rightSpeaker: Int64?,
                            byUser: Bool) throws -> (rightID: Int64, undo: SpeakerUndo) {
        guard let seg = try db.query("""
            SELECT meeting_id, speaker, start, end, text, speaker_id, speaker_confidence, overlap, speaker_locked, original_text, edited_at
            FROM segments WHERE id = ?
            """, [.integer(segmentID)]).first else { throw Self.segmentGone }
        let (meeting, code, start, end, text) = (seg.int(0), seg.string(1), seg.double(2), seg.double(3), seg.string(4))
        if byUser { guard meeting != activeMeetingID else { throw StoreError.meetingInProgress } }
        let characters = Array(text)
        guard offset > 0, offset < characters.count else { throw Self.cannotSplit }
        let left = String(characters[..<offset]).trimmingCharacters(in: .whitespacesAndNewlines)
        let right = String(characters[offset...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let at = time ?? start + (end - start) * Double(offset) / Double(characters.count)
        guard !left.isEmpty, !right.isEmpty, at > start, at < end else { throw Self.cannotSplit }
        if let rightSpeaker {
            guard let target = try speaker(rightSpeaker), target.meetingID == meeting, target.channel == Channel(storedSpeaker: code) else {
                throw StoreError(.speakerMismatch)
            }
        }
        // A corrected line: what the transcriber wrote is cut at the same word, so each part keeps its own (none when it reads the same).
        var originals: (left: String?, right: String?) = (nil, nil)
        if let original = seg.optionalString(9) {
            let correction = TranscriptCorrection(from: original, to: text, profile: LanguageProfile(locale: try meetingLocale(meeting)))
            let cut = correction.oldCut(atNew: text.index(text.startIndex, offsetBy: offset))
            let (l, r) = (String(original[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines),
                          String(original[cut...]).trimmingCharacters(in: .whitespacesAndNewlines))
            originals = (l.isEmpty || l == left ? nil : l, r.isEmpty || r == right ? nil : r)
        }
        let editedAt = { (original: String?) in original == nil ? nil : seg.optionalDouble(10).map { SQLiteValue.real($0) } }
        var undo = SpeakerUndo(segments: try segmentStates("WHERE id = ?", [.integer(segmentID)]))
        let translations = try db.query("SELECT lang, text, source FROM segment_translations WHERE segment_id = ?", [.integer(segmentID)])
            .map { (language: $0.string(0), text: $0.string(1), source: $0.optionalString(2)) }
        // External-content FTS5: the index is told what it held and what it holds now.
        try run("INSERT INTO segments_fts(segments_fts, rowid, text) VALUES ('delete', ?, ?)", [.integer(segmentID), .text(text)])
        try run("UPDATE segments SET end = ?, text = ?, speaker_locked = ?, original_text = ?, edited_at = ? WHERE id = ?",
                [.real(at), .text(left), .integer(byUser ? 1 : seg.int(8)), originals.left.map { .text($0) }, editedAt(originals.left),
                 .integer(segmentID)])
        try run("INSERT INTO segments_fts(rowid, text) VALUES (?, ?)", [.integer(segmentID), .text(left)])
        try run("DELETE FROM segment_translations WHERE segment_id = ?", [.integer(segmentID)])
        let rightSpeakerID = rightSpeaker ?? seg.optionalInt(5)
        // Inserted last so the trigger indexes the right part.
        try run("""
            INSERT INTO segments(meeting_id, speaker, start, end, text, speaker_id, speaker_confidence, overlap, speaker_locked, original_text, edited_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.integer(meeting), .text(code), .real(at), .real(end), .text(right),
                  rightSpeakerID.map { .integer($0) }, seg.optionalDouble(6).map { .real($0) }, .integer(seg.int(7)),
                  .integer(byUser ? 1 : seg.int(8)), originals.right.map { .text($0) }, editedAt(originals.right)])
        let id = db.lastInsertRowID
        if !byUser {
            // A translation of the line as it reads is cut with it, and each part is one of its own words; one stored before
            // translations recorded their source stays without one. One of an earlier text of the line, shown by neither part, goes.
            for t in translations where t.source == nil || t.source == text {
                let sources: (left: SQLiteValue?, right: SQLiteValue?) = t.source == nil ? (nil, nil) : (.text(left), .text(right))
                guard let (l, r) = Self.cutTranslation(t.text, at: Double(offset) / Double(characters.count)) else {
                    try run("INSERT INTO segment_translations(segment_id, lang, text, source) VALUES (?, ?, ?, ?)",
                            [.integer(segmentID), .text(t.language), .text(t.text), sources.left])
                    continue
                }
                try run("INSERT INTO segment_translations(segment_id, lang, text, source) VALUES (?, ?, ?, ?), (?, ?, ?, ?)",
                        [.integer(segmentID), .text(t.language), .text(l), sources.left, .integer(id), .text(t.language), .text(r), sources.right])
            }
        }
        try moveCitations(from: segmentID, to: id, leftText: left, rightText: right, at: at)
        undo.split = .init(left: segmentID, right: id, text: text, end: end, leftText: left, rightText: right, at: at,
                           leftSpeaker: seg.optionalInt(5), rightSpeaker: rightSpeakerID,
                           translations: translations,
                           original: seg.optionalString(9), editedAt: seg.optionalDouble(10))
        try recomputeTalkTimeInTransaction(meeting)
        return (id, undo)
    }

    /// A translation cut at the space or sentence mark nearest to `ratio` of its length; without one
    /// (Japanese, Chinese), at `ratio` of its characters. nil only when it is too short to have two parts.
    private static func cutTranslation(_ text: String, at ratio: Double) -> (String, String)? {
        let characters = Array(text)
        guard characters.count > 1 else { return nil }
        let guess = Int((Double(characters.count) * ratio).rounded())
        let marks = Set("。、，．！？；：")
        var cuts = characters.indices.filter { $0 > 0 && $0 < characters.count - 1 && characters[$0].isWhitespace }
        cuts += characters.indices.filter { $0 < characters.count - 1 && marks.contains(characters[$0]) }.map { $0 + 1 }
        let cut = cuts.min(by: { abs($0 - guess) < abs($1 - guess) }) ?? min(characters.count - 1, max(1, guess))
        let (l, r) = (String(characters[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines),
                      String(characters[cut...]).trimmingCharacters(in: .whitespacesAndNewlines))
        return l.isEmpty || r.isEmpty ? nil : (l, r)
    }
}
