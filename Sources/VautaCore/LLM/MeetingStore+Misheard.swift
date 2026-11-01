// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Ask also finds the people and projects of a question where the transcript misheard them. The context graph's corrector found
/// those spellings ("Cobaltics" for Kobaltix: they sound or are spelled alike, `correctionTargets`) and offers each as a correction.
/// A correction the person accepted taught the spelling as a learned alias of the name: its lines, in every meeting a search may
/// use, count as much as the name's own. While a correction is open, the lines of its meeting with that spelling count half, for its
/// first candidate: the person has not said yet that it is that name. A correction turned down counts no more.
extension MeetingStore {
    /// A line where the transcript misheard a name; `confirmed` when the person accepted the correction.
    struct MisheardMoment {
        let segment: Int64
        let meeting: Int64
        let t: Double
        let confirmed: Bool
    }

    /// The lines that say a misheard name of `entities` (merged entities count as the one they were merged into), in the meetings
    /// a search may use: the confirmed spellings first, each line once.
    func misheardMoments(of entities: [Int64], scope: [Int64]?, excluding: Int64?) throws -> [MisheardMoment] {
        guard !entities.isEmpty, scope?.isEmpty != true else { return [] }
        var out: [MisheardMoment] = []
        let learned = try db.query("""
            SELECT DISTINCT a.alias FROM aliases a JOIN entities e ON e.id = a.entity_id
            WHERE a.source = 'learned' AND coalesce(e.merged_into, e.id) IN (SELECT value FROM json_each(?1)) ORDER BY a.alias LIMIT ?2
            """, [.ids(entities), .integer(Int64(Self.misheardSpellings))])
        for row in learned {
            guard let phrase = SemanticRanker.phrase(row.string(0)) else { continue }
            for hit in try db.query("""
                SELECT s.id, s.meeting_id, s.start FROM segments_fts f JOIN segments s ON s.id = f.rowid
                WHERE segments_fts MATCH ?1 AND (?2 IS NULL OR s.meeting_id IN (SELECT value FROM json_each(?2))) AND (?3 IS NULL OR s.meeting_id <> ?3)
                  AND \(Self.notEcho) ORDER BY rank LIMIT ?4
                """, [.text(phrase), scope.map { .ids($0) }, excluding.map { .integer($0) }, .integer(Int64(Self.confirmedLinesPerSpelling))]) {
                out.append(MisheardMoment(segment: hit.int(0), meeting: hit.int(1), t: hit.double(2), confirmed: true))
            }
        }
        let open = try db.query("""
            SELECT DISTINCT s.meeting_id, s.surface FROM suggestions s
            JOIN entities e ON e.id = json_extract(s.candidates, '$.c[0].entityID')
            WHERE s.kind = 'correction' AND s.status = 'open' AND coalesce(e.merged_into, e.id) IN (SELECT value FROM json_each(?1))
              AND (?2 IS NULL OR s.meeting_id IN (SELECT value FROM json_each(?2))) AND (?3 IS NULL OR s.meeting_id <> ?3)
            ORDER BY s.meeting_id DESC, s.surface LIMIT ?4
            """, [.ids(entities), scope.map { .ids($0) }, excluding.map { .integer($0) }, .integer(Int64(Self.misheardSpellings))])
        for row in open {
            guard let phrase = SemanticRanker.phrase(row.string(1)) else { continue }
            for hit in try db.query("""
                SELECT s.id, s.start FROM segments_fts f JOIN segments s ON s.id = f.rowid
                WHERE segments_fts MATCH ?1 AND s.meeting_id = ?2 AND \(Self.notEcho) ORDER BY s.start, s.id LIMIT ?3
                """, [.text(phrase), .integer(row.int(0)), .integer(Int64(Self.openLinesPerSpelling))]) {
                out.append(MisheardMoment(segment: hit.int(0), meeting: row.int(0), t: hit.double(1), confirmed: false))
            }
        }
        var seen = Set<Int64>()
        return out.filter { seen.insert($0.segment).inserted }
    }

    /// At most this many spellings of each kind, and lines of each, join a search: a name misheard all over the meetings does not
    /// crowd out the passages the question's words find.
    static let misheardSpellings = 20
    static let confirmedLinesPerSpelling = 40
    static let openLinesPerSpelling = 10
}
