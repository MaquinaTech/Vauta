// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Correcting the words of a transcript line (Meetings › Transcript). The line keeps its time, speaker, echo mark and every
/// citation; its text becomes the correction, so search, Ask, the names found in the meeting, the minutes written from then on
/// and the exports read it. What the transcriber wrote stays in `original_text` for Restore Original, and goes with the line
/// (retention, deleting the meeting, Erase). The line's stored translation is of the words that were transcribed: it is hidden
/// while the line is corrected and comes back with them.
///
/// Nothing the model wrote is rewritten. A decision or task it proposed from the line, which the correction may make say
/// something the line no longer says (`TranscriptCorrection.touches`), is marked not confirmed (`UnconfirmedReason.edited`) until
/// the user checks or edits it or the minutes are written again; the mark goes when the words it was written from come back. A
/// sentence of a note's expansion that cites the line follows its quote and is marked the same way, and a question detected in
/// the line follows the correction.
extension MeetingStore {
    /// What a correction changed, so Edit ▸ Undo puts it back exactly (`undoCorrection`). Kept in memory only.
    public struct TextCorrection: Sendable {
        public let segmentID: Int64
        public let meetingID: Int64
        /// The correction put back what the transcriber wrote (Restore Original).
        public let restored: Bool
        /// The line before: its text, what the transcriber wrote when it was corrected already, and since when.
        let before: String, original: String?, editedAt: Double?
        /// The line's text after, so an undo can tell that it moved on.
        let after: String
        let marks: [Mark]
        let expansions: [Change]
        let questions: [Change]

        /// A decision's or task's mark before and after.
        struct Mark: Sendable {
            let table: String, id: Int64
            let before: (unconfirmed: Bool, reason: String?), after: (unconfirmed: Bool, reason: String?)
        }

        /// A stored text (an expansion's sentences, a question) before and after.
        struct Change: Sendable { let id: Int64, before: String, after: String }
    }

    /// Replaces the text of a line with the user's correction (line breaks become spaces; spaces at the ends go). Returns nil
    /// when that changes nothing; an empty correction changes nothing either (taking a passage out is not a correction).
    /// Refuses the meeting being recorded.
    @discardableResult
    public func correctSegment(_ segmentID: Int64, text: String, now: Date = .now) async throws -> TextCorrection? {
        let clean = SingleLineText.flatten(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        return try await commitCorrection { try correctInTransaction(segmentID, to: clean, now: now) }
    }

    /// Puts back what the transcriber wrote. nil when the line was never corrected.
    @discardableResult
    public func restoreOriginalText(_ segmentID: Int64, now: Date = .now) async throws -> TextCorrection? {
        try await commitCorrection {
            guard let original = try db.query("SELECT original_text FROM segments WHERE id = ?", [.integer(segmentID)]).first?.optionalString(0)
            else { return nil }
            return try correctInTransaction(segmentID, to: original, now: now)
        }
    }

    /// Takes a correction back: the line, its marks, quotes and questions return to what they were. Fails, changing nothing, when
    /// the line was corrected again, split or deleted since. A mark or text the user changed since is left as they made it.
    public func undoCorrection(_ c: TextCorrection) async throws {
        try transaction { try undoInTransaction(c) }
        try await commitEdit()
        if !c.marks.isEmpty { itemsEditedHandler?(c.meetingID) }
    }

    func undoInTransaction(_ c: TextCorrection, analyze: Bool = true) throws {
        guard let row = try db.query("SELECT meeting_id, text FROM segments WHERE id = ?", [.integer(c.segmentID)]).first,
              row.int(0) == c.meetingID, row.string(1) == c.after, c.meetingID != activeMeetingID
        else { throw Self.cannotUndo }
        try setText(c.segmentID, from: c.after, to: c.before, original: c.original, editedAt: c.editedAt)
        for m in c.marks {
            try run("""
                UPDATE \(m.table) SET unconfirmed = ?, unconfirmed_reason = ?
                WHERE id = ? AND source = 'llm' AND unconfirmed = ? AND unconfirmed_reason IS ?
                """, [.integer(m.before.unconfirmed ? 1 : 0), m.before.reason.map { .text($0) }, .integer(m.id),
                      .integer(m.after.unconfirmed ? 1 : 0), m.after.reason.map { .text($0) }])
        }
        for e in c.expansions {
            try run("UPDATE note_expansions SET sentences = ? WHERE note_id = ? AND sentences = ?", [.text(e.before), .integer(e.id), .text(e.after)])
        }
        for q in c.questions { try setQuestionText(q.id, to: q.before, ifStill: q.after) }
        if analyze { _ = try analyzeInTransaction(c.meetingID) }
    }

    private func commitCorrection(_ body: () throws -> TextCorrection?) async throws -> TextCorrection? {
        guard let correction = try transaction(body) else { return nil }
        try await commitEdit()
        if !correction.marks.isEmpty { itemsEditedHandler?(correction.meetingID) }
        return correction
    }

    /// `analyze` false leaves finding the names to the caller (one pass after several lines).
    func correctInTransaction(_ segmentID: Int64, to new: String, now: Date, analyze: Bool = true) throws -> TextCorrection? {
        guard let row = try db.query("SELECT meeting_id, text, original_text, edited_at FROM segments WHERE id = ?", [.integer(segmentID)]).first
        else { throw Self.segmentGone }
        let (meetingID, old, original, editedAt) = (row.int(0), row.string(1), row.optionalString(2), row.optionalDouble(3))
        guard meetingID != activeMeetingID else { throw StoreError(.meetingInProgress) }
        guard new != old else { return nil }
        // What the transcriber wrote, and whether the correction puts it back.
        let transcribed = original ?? old
        let restored = new == transcribed
        try setText(segmentID, from: old, to: new, original: restored ? nil : transcribed,
                    editedAt: restored ? nil : editedAt ?? now.timeIntervalSince1970)
        let profile = LanguageProfile(locale: try meetingLocale(meetingID))
        let step = TranscriptCorrection(from: old, to: new, profile: profile)
        let whole = TranscriptCorrection(from: transcribed, to: new, profile: profile)
        let marks = try remark(segmentID, step: step, whole: whole, firstEdit: editedAt)
        let expansions = try followExpansions(segmentID, step: step, restored: restored)
        var questions: [TextCorrection.Change] = []
        for q in try db.query("SELECT id, text FROM detected_questions WHERE segment_id = ?", [.integer(segmentID)]) {
            guard let text = step.corrected(quote: q.string(1)), text != q.string(1) else { continue }
            try setQuestionText(q.int(0), to: text, ifStill: q.string(1))
            questions.append(.init(id: q.int(0), before: q.string(1), after: text))
        }
        // The names in the line: a corrected name is found, a misheard one is no longer suggested.
        if analyze { _ = try analyzeInTransaction(meetingID) }
        return TextCorrection(segmentID: segmentID, meetingID: meetingID, restored: restored, before: old, original: original,
                              editedAt: editedAt, after: new, marks: marks, expansions: expansions, questions: questions)
    }

    /// External-content FTS5: the index is told what it held and what it holds now.
    private func setText(_ segmentID: Int64, from old: String, to new: String, original: String?, editedAt: Double?) throws {
        try run("INSERT INTO segments_fts(segments_fts, rowid, text) VALUES ('delete', ?, ?)", [.integer(segmentID), .text(old)])
        try run("UPDATE segments SET text = ?, original_text = ?, edited_at = ? WHERE id = ?",
                [.text(new), original.map { .text($0) }, editedAt.map { .real($0) }, .integer(segmentID)])
        try run("INSERT INTO segments_fts(rowid, text) VALUES (?, ?)", [.integer(segmentID), .text(new)])
    }

    /// The model's decisions and tasks that cite the line. One the correction may change is marked; one marked by an earlier
    /// correction, written from what the transcriber wrote, keeps its mark only while the line still differs where it relied on
    /// it. Marks of other kinds, and what the user wrote or checked, are left alone.
    private func remark(_ segmentID: Int64, step: TranscriptCorrection, whole: TranscriptCorrection, firstEdit: Double?) throws -> [TextCorrection.Mark] {
        var marks: [TextCorrection.Mark] = []
        for table in ["decisions", "tasks"] {
            let rows = try db.query("SELECT id, text, unconfirmed, unconfirmed_reason, created_at FROM \(table) WHERE segment_id = ? AND source = 'llm'",
                                    [.integer(segmentID)])
            for r in rows {
                let before = (unconfirmed: r.int(2) != 0, reason: r.optionalString(3))
                // Written before the line was first corrected: from what the transcriber wrote.
                let fromTranscribed = firstEdit.map { r.double(4) < $0 } ?? true
                var after = before
                if !before.unconfirmed {
                    if (fromTranscribed ? whole : step).touches(r.string(1)) { after = (true, UnconfirmedReason.edited) }
                } else if before.reason == UnconfirmedReason.edited, fromTranscribed, !whole.touches(r.string(1)) {
                    after = (false, nil)
                }
                guard after != before else { continue }
                try run("UPDATE \(table) SET unconfirmed = ?, unconfirmed_reason = ? WHERE id = ?",
                        [.integer(after.unconfirmed ? 1 : 0), after.reason.map { .text($0) }, .integer(r.int(0))])
                marks.append(.init(table: table, id: r.int(0), before: before, after: after))
            }
        }
        return marks
    }

    /// The expansions whose sentences cite the line: each quote follows the correction, a sentence the correction may change is
    /// marked, and the marks go when the line is restored.
    private func followExpansions(_ segmentID: Int64, step: TranscriptCorrection, restored: Bool) throws -> [TextCorrection.Change] {
        let rows = try db.query("""
            SELECT note_id, sentences FROM note_expansions WHERE EXISTS (
                SELECT 1 FROM json_each(note_expansions.sentences) s, json_each(s.value, '$.cites') c WHERE json_extract(c.value, '$.seg') = ?1)
            """, [.integer(segmentID)])
        var changes: [TextCorrection.Change] = []
        for row in rows {
            let sentences = Self.decodeSentences(row.optionalString(1)).map { sentence in
                guard sentence.cites.contains(where: { $0.seg == segmentID }) else { return sentence }
                var s = sentence
                if !s.quote.isEmpty, let quote = step.corrected(quote: s.quote) { s.quote = quote }
                if restored, s.edited {
                    s.unconfirmed = false
                    s.edited = false
                } else if !s.unconfirmed, step.touches(s.text) {
                    s.unconfirmed = true
                    s.edited = true
                }
                return s
            }
            let json = Self.encode(sentences)
            guard json != row.string(1) else { continue }
            try run("UPDATE note_expansions SET sentences = ? WHERE note_id = ?", [.text(json), .integer(row.int(0))])
            changes.append(.init(id: row.int(0), before: row.string(1), after: json))
        }
        return changes
    }

    /// A detected question's text, kept in search when the person kept it (the triggers only follow `kept`).
    private func setQuestionText(_ id: Int64, to text: String, ifStill current: String) throws {
        try run("UPDATE detected_questions SET text = ? WHERE id = ? AND text = ?", [.text(text), .integer(id), .text(current)])
        guard db.changes > 0 else { return }
        try run("DELETE FROM knowledge_fts WHERE rowid = ? * 8 + 7", [.integer(id)])
        try run("""
            INSERT INTO knowledge_fts(rowid, text)
            SELECT id * 8 + 7, text || ' ' || coalesce(json_extract(answer, '$.answer'), '') FROM detected_questions WHERE id = ? AND kept = 1
            """, [.integer(id)])
    }
}
