// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Undo for the speaker edits (add, assign, rename, merge, reassign, split, clear) and the citation move of a split.
extension MeetingStore {
    static let cannotUndo = StoreError(.cannotUndo)

    func speakerRows(_ ids: [Int64]) throws -> [SpeakerUndo.SpeakerRow] {
        try db.query("""
            SELECT id, meeting_id, channel, ordinal, entity_id, source, confidence FROM meeting_speakers
            WHERE id IN (SELECT value FROM json_each(?))
            """, [.ids(ids)]).map {
            SpeakerUndo.SpeakerRow(id: $0.int(0), meetingID: $0.int(1), channel: $0.string(2), ordinal: $0.int(3),
                                   entityID: $0.optionalInt(4), source: $0.string(5), confidence: $0.optionalDouble(6))
        }
    }

    func segmentStates(_ condition: String, _ params: [SQLiteValue?]) throws -> [SpeakerUndo.SegmentState] {
        try db.query("SELECT id, meeting_id, speaker_id, speaker_confidence, overlap, speaker_locked FROM segments " + condition, params).map {
            SpeakerUndo.SegmentState(id: $0.int(0), meetingID: $0.int(1), speakerID: $0.optionalInt(2), confidence: $0.optionalDouble(3),
                                     overlap: $0.int(4), locked: $0.int(5))
        }
    }

    /// Moves the citations of the left part that belong to the right text to the right part: a mention
    /// or suggestion whose surface occurs only in the right text; anything else whose time is at or
    /// after the split. A citation of both stays left.
    func moveCitations(from left: Int64, to right: Int64, leftText: String, rightText: String, at: Double) throws {
        let (nl, nr) = (TextKeys.norm(leftText), TextKeys.norm(rightText))
        for (table, surface) in [("mentions", true), ("suggestions", true), ("decisions", false), ("tasks", false)] {
            let rows = try db.query("SELECT id, t, \(surface ? "surface" : "NULL") FROM \(table) WHERE segment_id = ?", [.integer(left)])
            var moving: [Int64] = []
            for row in rows {
                let key = TextKeys.norm(row.optionalString(2) ?? "")
                if !key.isEmpty {
                    if !nl.contains(key), nr.contains(key) { moving.append(row.int(0)) }
                } else if let t = row.optionalDouble(1), t >= at {
                    moving.append(row.int(0))
                }
            }
            try run("UPDATE \(table) SET segment_id = ? WHERE id IN (SELECT value FROM json_each(?))", [.integer(right), .ids(moving)])
        }
        // The notes' expansions cite segments too: by the quote that backs each sentence.
        try moveExpansionCitations(from: left, to: right, leftText: leftText, rightText: rightText, at: at)
    }

    /// Puts back what an edit changed. The speakers it deleted come back with their IDs and
    /// ordinals, segments return to their speaker, confidence and lock, and a split is joined again
    /// (text, end, citations and translations). Fails, changing nothing, when the data has moved on
    /// so that it cannot be restored: a speaker's place taken (or its ID, which belongs to another
    /// meeting's speaker now), a speaker of a meeting whose speakers were turned off, a segment of another meeting under a recorded ID, or a split whose parts
    /// were edited, split again or reassigned since. Undoing `addSpeaker` is the exception: while a segment still
    /// points at the new speaker it deletes nothing and succeeds, since the row is in use.
    public func undo(_ record: SpeakerUndo) async throws {
        try transaction {
            var meetings = Set<Int64>()
            if let split = record.split {
                guard let l = try db.query("SELECT meeting_id, text, end, speaker_id FROM segments WHERE id = ?", [.integer(split.left)]).first,
                      let r = try db.query("SELECT meeting_id, text, start, end, speaker_id FROM segments WHERE id = ?", [.integer(split.right)]).first,
                      l.int(0) == r.int(0), l.string(1) == split.leftText, l.double(2) == split.at, l.optionalInt(3) == split.leftSpeaker,
                      r.string(1) == split.rightText, r.double(2) == split.at, r.double(3) == split.end, r.optionalInt(4) == split.rightSpeaker
                else { throw Self.cannotUndo }
                meetings.insert(l.int(0))
                try run("INSERT INTO segments_fts(segments_fts, rowid, text) VALUES ('delete', ?, ?)", [.integer(split.left), .text(split.leftText)])
                try run("UPDATE segments SET end = ?, text = ? WHERE id = ?", [.real(split.end), .text(split.text), .integer(split.left)])
                try run("INSERT INTO segments_fts(rowid, text) VALUES (?, ?)", [.integer(split.left), .text(split.text)])
                for table in ["mentions", "suggestions", "decisions", "tasks"] {
                    try run("UPDATE \(table) SET segment_id = ? WHERE segment_id = ?", [.integer(split.left), .integer(split.right)])
                }
                let leftStart = try db.query("SELECT start FROM segments WHERE id = ?", [.integer(split.left)]).first?.double(0) ?? 0
                try moveExpansionCitations(from: split.left, to: split.right, leftText: split.leftText, rightText: split.rightText,
                                           at: split.at, toRight: false, leftStart: leftStart)
                try run("DELETE FROM segments WHERE id = ?", [.integer(split.right)])
                // Translations made after the split translate only the left half.
                try run("DELETE FROM segment_translations WHERE segment_id = ?", [.integer(split.left)])
                for t in split.translations {
                    try run("INSERT INTO segment_translations(segment_id, lang, text) VALUES (?, ?, ?)",
                            [.integer(split.left), .text(t.language), .text(t.text)])
                }
            }
            for row in record.speakers {
                // A meeting whose speakers the user turned off stays without speaker data.
                guard try !db.query("SELECT 1 FROM meetings WHERE id = ? AND speakers_off = 0", [.integer(row.meetingID)]).isEmpty
                else { throw Self.cannotUndo }
                guard try db.query("SELECT 1 FROM meeting_speakers WHERE meeting_id = ? AND channel = ? AND ordinal = ? AND id <> ?",
                                   [.integer(row.meetingID), .text(row.channel), .integer(row.ordinal), .integer(row.id)]).isEmpty
                else { throw Self.cannotUndo }
                if let taken = try db.query("SELECT meeting_id, channel, ordinal FROM meeting_speakers WHERE id = ?", [.integer(row.id)]).first {
                    guard taken.int(0) == row.meetingID, taken.string(1) == row.channel, taken.int(2) == row.ordinal else { throw Self.cannotUndo }
                }
                meetings.insert(row.meetingID)
                // A person deleted since leaves the speaker unnamed; one merged since is followed; a
                // thing that is no longer a person is not restored. A row that never had a person keeps its
                // source (a cleared name stays the user's decision).
                let person = try row.entityID.flatMap { id in
                    try db.query("SELECT coalesce(merged_into, id) FROM entities WHERE id = ? AND kind = 'person'", [.integer(id)]).first?.int(0)
                }
                try run("""
                    INSERT INTO meeting_speakers(id, meeting_id, channel, ordinal, entity_id, source, confidence) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET entity_id = excluded.entity_id, source = excluded.source, confidence = excluded.confidence
                    """, [.integer(row.id), .integer(row.meetingID), .text(row.channel), .integer(row.ordinal), person.map { .integer($0) },
                          .text(person == nil && row.entityID != nil ? MeetingSpeaker.Source.auto.rawValue : row.source), row.confidence.map { .real($0) }])
            }
            for s in record.segments {
                // A deleted segment has nothing to restore; one that is another meeting's now cannot be touched.
                guard let seg = try db.query("SELECT meeting_id, speaker FROM segments WHERE id = ?", [.integer(s.id)]).first else { continue }
                guard seg.int(0) == s.meetingID else { throw Self.cannotUndo }
                meetings.insert(s.meetingID)
                if let speakerID = s.speakerID,
                   try db.query("SELECT 1 FROM meeting_speakers WHERE id = ? AND meeting_id = ? AND channel = ?",
                                [.integer(speakerID), .integer(s.meetingID), .text(Channel(storedSpeaker: seg.string(1)).storedCode)]).isEmpty,
                   try !db.query("SELECT 1 FROM meeting_speakers WHERE id = ?", [.integer(speakerID)]).isEmpty {
                    throw Self.cannotUndo
                }
                try run("""
                    UPDATE segments SET speaker_id = (SELECT id FROM meeting_speakers WHERE id = ?1), speaker_confidence = ?2,
                        overlap = ?3, speaker_locked = ?4 WHERE id = ?5
                    """, [s.speakerID.map { .integer($0) }, s.confidence.map { .real($0) }, .integer(s.overlap), .integer(s.locked), .integer(s.id)])
            }
            // Tasks that followed the speaker's name go back, unless the user changed their owner since.
            for move in record.ownerMoves.reversed() {
                guard try !db.query("SELECT 1 FROM tasks WHERE id = ? AND owner_id IS ?", [.integer(move.task), move.after.map { .integer($0) }]).isEmpty else { continue }
                try run("UPDATE tasks SET owner_id = ? WHERE id = ?", [move.before.map { .integer($0) }, .integer(move.task)])
                try syncOwnerEdge(move.task, move.before)
            }
            if let created = record.createdSpeaker {
                try run("DELETE FROM meeting_speakers WHERE id = ?1 AND NOT EXISTS (SELECT 1 FROM segments WHERE speaker_id = ?1)", [.integer(created)])
            }
            if let rejected = record.rejected {
                try run("DELETE FROM speaker_suggestion_rejections WHERE meeting_id = ? AND entity_id = ?", [.integer(rejected.meeting), .integer(rejected.entity)])
            }
            if let created = record.createdPerson { try removePersonIfUnused(created) }
            for m in meetings { try recomputeTalkTimeInTransaction(m) }
        }
        vectorCache = nil
        try await commitEdit()
    }

    /// Deletes a person a rename created, when nothing has come to use them since.
    private func removePersonIfUnused(_ id: Int64) throws {
        let used = try db.query("""
            SELECT 1 WHERE EXISTS (SELECT 1 FROM meeting_speakers WHERE entity_id = ?1)
                OR EXISTS (SELECT 1 FROM mentions WHERE entity_id = ?1)
                OR EXISTS (SELECT 1 FROM meeting_entities WHERE entity_id = ?1)
                OR EXISTS (SELECT 1 FROM tasks WHERE owner_id = ?1)
                OR EXISTS (SELECT 1 FROM glossary WHERE entity_id = ?1)
                OR EXISTS (SELECT 1 FROM voice_profiles WHERE entity_id = ?1)
                OR EXISTS (SELECT 1 FROM entities WHERE merged_into = ?1)
                OR (SELECT count(*) FROM aliases WHERE entity_id = ?1) > 1
            """, [.integer(id)])
        guard used.isEmpty else { return }
        try rewriteEntityReferences(id, to: nil)
        try run("DELETE FROM entities WHERE id = ?", [.integer(id)])
        pendingCompaction = true
    }
}
