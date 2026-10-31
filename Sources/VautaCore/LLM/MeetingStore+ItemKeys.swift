// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The minutes' decisions and tasks, and the questions the person kept, as keys to find the moments Ask sends: a decision is often
/// worded as the question is ("the remote will have no teletext button") while the moment that decided it is not ("yeah, drop it").
/// A matching item brings the passage around the moment it cites in as a candidate, as the user's notes do. Only meetings and times
/// come back, never an item's text: what reaches the model is the transcript, and the answer's quotes are checked against it.
extension MeetingStore {
    /// How much a matching item weighs against a keyword hit of the same rank (a note weighs 1.5: the person flagged that moment).
    ///
    /// Off until it is shown to help: on the 205 harness dev questions with gold (`llm-eval --tasks ask-retrieval --after-meeting --items
    /// <archived server minutes>`), keyword retrieval as Apple's model gets it, weight 2 sent the gold of 1 more decision question of 29 and
    /// 2 more task questions of 13, and lost 3 of 62 fact questions and 1 of 23 across languages; asked only for questions about a decision,
    /// the facts stayed and 1 partial decision was lost. With the short windows it moved nothing (205 · 0.815 → 0.824). The plan's bar is
    /// +0.05 on decisions and tasks with no loss elsewhere.
    public static let defaultItemKeyWeight = 0.0

    /// `itemKeyWeight` (evaluation: 0 turns the keys off).
    public func setItemKeyWeight(_ weight: Double) { itemKeyWeight = max(0, weight) }

    /// The moments the matching items cite, best match first (at most 40), in `scope` when given.
    func itemCitedMoments(terms: [String], scope: [Int64]?) throws -> [(meeting: Int64, t: Double)] {
        guard itemKeyWeight > 0 else { return [] }
        let spaced = terms.filter { !$0.contains(where: TextKeys.isNoSpaceScript) }
        let unspaced = terms.filter { $0.contains(where: TextKeys.isNoSpaceScript) }
        // Encoded rowids of knowledge_fts: id * 8 + 1 a decision, + 2 a task, + 7 a kept question.
        var keys: [Int64] = []
        let scoped = """
            (?2 IS NULL OR (rowid % 8 = 1 AND rowid / 8 IN (SELECT id FROM decisions WHERE meeting_id IN (SELECT value FROM json_each(?2))))
             OR (rowid % 8 = 2 AND rowid / 8 IN (SELECT id FROM tasks WHERE meeting_id IN (SELECT value FROM json_each(?2))))
             OR (rowid % 8 = 7 AND rowid / 8 IN (SELECT id FROM detected_questions WHERE meeting_id IN (SELECT value FROM json_each(?2)))))
            """
        if !spaced.isEmpty {
            let match = spaced.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }.joined(separator: " OR ")
            keys += try db.query("""
                SELECT rowid FROM knowledge_fts WHERE knowledge_fts MATCH ?1 AND rowid % 8 IN (1, 2, 7) AND \(scoped) ORDER BY rank LIMIT 40
                """, [.text(match), scope.map { .ids($0) }]).map { $0.int(0) }
        }
        if !unspaced.isEmpty {
            // Han, kana and Thai are not segmented by the index: their words are found by substring.
            keys += try db.query("""
                SELECT rowid FROM knowledge_fts WHERE rowid % 8 IN (1, 2, 7) AND \(scoped)
                AND EXISTS (SELECT 1 FROM json_each(?1) WHERE instr(text, value) > 0) LIMIT 40
                """, [.text(Self.json(strings: unspaced)), scope.map { .ids($0) }]).map { $0.int(0) }
        }
        guard !keys.isEmpty else { return [] }
        var moment: [Int64: (Int64, Double)] = [:]
        for (kind, table) in [(Int64(1), "decisions"), (2, "tasks"), (7, "detected_questions")] {
            let ids = keys.filter { $0 % 8 == kind }.map { $0 / 8 }
            guard !ids.isEmpty else { continue }
            // A kept question is always placed (`t` NOT NULL); an item whose segment was deleted keeps its time.
            for row in try db.query("""
                SELECT id, meeting_id, coalesce(t, (SELECT start FROM segments WHERE id = \(table).segment_id)) FROM \(table)
                WHERE id IN (SELECT value FROM json_each(?1)) AND \(table == "detected_questions" ? "kept = 1" : "1")
                """, [.ids(ids)]) {
                guard let t = row.optionalDouble(2) else { continue }
                moment[row.int(0) * 8 + kind] = (row.int(1), t)
            }
        }
        var seen = Set<Int64>()
        return keys.compactMap { key in seen.insert(key).inserted ? moment[key].map { (meeting: $0.0, t: $0.1) } : nil }.prefix(40).map { $0 }
    }
}
