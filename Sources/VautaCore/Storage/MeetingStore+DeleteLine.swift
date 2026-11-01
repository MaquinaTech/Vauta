// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Taking a line out of the record (Meetings › Transcript › Delete Line…), or a highlighted stretch of lines at once (Delete N
/// Lines…): each line's words are erased for good, not hidden. The line goes with what was transcribed and its translation; the
/// questions heard in it and the follow-ups detected in it go too; the stored answers drop the claims that cite it; the meeting's
/// search vectors are deleted (Vauta embeds what is left again); and the indexes are merged, the store compacted and written out,
/// as when a meeting is deleted, so no index, free page or journal keeps the words.
///
/// What the model wrote from the line is not rewritten. Its decisions and tasks, and the sentences of a note's expansion that
/// cite it, are marked not confirmed (`UnconfirmedReason.deleted`) for the person to check or delete, and a quote taken from the
/// line is dropped; Rewrite Minutes writes them without the line. There is no undo, and a backup made before keeps the line.
extension MeetingStore {
    /// What deleting a line changed.
    public struct LineDeletion: Sendable, Equatable {
        public let meetingID: Int64
        /// The model's decisions and tasks, and the sentences of note expansions, now marked for the person to check.
        public let marked: Int
    }

    /// Deletes a line of a meeting's transcript for good. Refuses the meeting being recorded. Returns once the deletion is on disk.
    @discardableResult
    public func deleteSegment(_ segmentID: Int64) async throws -> LineDeletion {
        try await deleteSegments([segmentID])
    }

    /// Deletes lines of one meeting's transcript for good, together (a stretch taken off the record): one transaction, then one
    /// compaction and write, so every line goes or none does. Refuses lines of more than one meeting, a line that is already gone
    /// and the meeting being recorded. Returns once the deletion is on disk.
    @discardableResult
    public func deleteSegments(_ segmentIDs: [Int64]) async throws -> LineDeletion {
        let ids = Set(segmentIDs)
        // The lines as one JSON array, read with json_each: a stretch can be longer than SQLite's limit on bound parameters.
        let list = SQLiteValue.text("[" + ids.map(String.init).joined(separator: ",") + "]")
        let deletion: LineDeletion = try transaction {
            let rows = try db.query("SELECT id, meeting_id, text, original_text FROM segments WHERE id IN (SELECT value FROM json_each(?))", [list])
            guard let meetingID = rows.first?.int(1), rows.count == ids.count else { throw Self.segmentGone }
            guard rows.allSatisfy({ $0.int(1) == meetingID }) else { throw StoreError(.general) }
            guard meetingID != activeMeetingID else { throw StoreError(.meetingInProgress) }
            var marked = 0
            for table in ["decisions", "tasks"] {
                try run("""
                    UPDATE \(table) SET unconfirmed = 1, unconfirmed_reason = ?
                     WHERE segment_id IN (SELECT value FROM json_each(?)) AND source = 'llm' AND unconfirmed = 0
                    """, [.text(UnconfirmedReason.deleted), list])
                marked += db.changes
            }
            let words = Dictionary(uniqueKeysWithValues: rows.map { ($0.int(0), [$0.string(2), $0.optionalString(3)].compactMap { $0 }) })
            marked += try forgetInExpansions(words, list: list)
            try run("DELETE FROM detected_questions WHERE segment_id IN (SELECT value FROM json_each(?))", [list])
            // As `storeDetectedFollowUps` does, one with a live event or hand-off stays: its ledger row needs it.
            try run("""
                DELETE FROM follow_ups WHERE segment_id IN (SELECT value FROM json_each(?)) AND source = 'detected' AND state = 'suggested'
                  AND NOT EXISTS (SELECT 1 FROM created_actions WHERE src_kind = 'follow_up' AND src_id = follow_ups.id
                                  AND state IN ('writing','created','linked','handed_off'))
                """, [list])
            try rewriteQuestionAnswers { cite in cite.segmentID.map { ids.contains($0) } == true }
            try run("DELETE FROM chunks WHERE meeting_id = ?", [.integer(meetingID)])
            try run("DELETE FROM segments WHERE id IN (SELECT value FROM json_each(?))", [list])
            _ = try analyzeInTransaction(meetingID)
            return LineDeletion(meetingID: meetingID, marked: marked)
        }
        editRevision &+= 1
        vectorCache = nil
        pendingCompaction = true
        var compaction: Error?
        if activeMeetingID == nil {
            do { try compactNow() } catch { compaction = error }
        }
        do {
            try await snapshot(compacting: false)
        } catch {
            throw StoreError(.deleteNotSaved, underlying: error)
        }
        if let compaction { throw StoreError(.compactionFailed, underlying: compaction) }
        if deletion.marked > 0 { itemsEditedHandler?(deletion.meetingID) }
        return deletion
    }

    /// The sentences of note expansions (and the one level of undo they keep) that cite the lines: those citations go, a quote taken
    /// from a cited line goes, and a sentence that was confirmed is marked. `words`: each line's text, with what was transcribed
    /// before a correction; `list`: the lines' ids as a JSON array. Returns how many sentences were marked.
    private func forgetInExpansions(_ words: [Int64: [String]], list: SQLiteValue) throws -> Int {
        let rows = try db.query("""
            SELECT note_id, sentences, previous FROM note_expansions WHERE EXISTS (
                SELECT 1 FROM json_each(note_expansions.sentences) s, json_each(s.value, '$.cites') c
                 WHERE json_extract(c.value, '$.seg') IN (SELECT value FROM json_each(?1)))
               OR EXISTS (
                SELECT 1 FROM json_each(note_expansions.previous) s, json_each(s.value, '$.cites') c
                 WHERE json_extract(c.value, '$.seg') IN (SELECT value FROM json_each(?1)))
            """, [list])
        var marked = 0
        func forget(_ json: String?, counting: Bool) -> String? {
            guard let json else { return nil }
            return Self.encode(Self.decodeSentences(json).map { sentence in
                guard sentence.cites.contains(where: { words[$0.seg] != nil }) else { return sentence }
                let cited = sentence.cites.compactMap { words[$0.seg] }.flatMap { $0 }
                var s = sentence
                s.cites.removeAll { words[$0.seg] != nil }
                if !s.quote.isEmpty, cited.contains(where: { $0.contains(s.quote) }) { s.quote = "" }
                if !s.unconfirmed {
                    s.unconfirmed = true
                    if counting { marked += 1 }
                }
                return s
            })
        }
        for row in rows {
            try run("UPDATE note_expansions SET sentences = ?, previous = ? WHERE note_id = ?",
                    [forget(row.optionalString(1), counting: true).map { .text($0) }, forget(row.optionalString(2), counting: false).map { .text($0) },
                     .integer(row.int(0))])
        }
        return marked
    }
}
