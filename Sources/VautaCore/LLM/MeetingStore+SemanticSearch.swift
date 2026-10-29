// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Ask's retrieval when the search model ranks (`SemanticRanker.Mode.semantic`).
extension MeetingStore {
    /// Meetings that could be embedded (ended, with a transcript) and how many have all their chunks in `space`.
    /// "Covered" does not check the chunk text against speaker names (that check is per meeting and the embedding job does it).
    public func vectorCoverage(space: EmbeddingSpace) throws -> SemanticRanker.Coverage {
        // A meeting whose embedding job ran out of attempts (`failed`) and has no vectors is left out of the count, like the chunks
        // the model cannot read: it would only fail again, and one such meeting must not keep Ask on keywords for good. Changing
        // the settings or regenerating forgets the failed job, so it counts (and is tried) again.
        let total = try db.query("""
            SELECT COUNT(*) FROM meetings WHERE ended_at IS NOT NULL AND raw_purged_at IS NULL
              AND EXISTS (SELECT 1 FROM segments WHERE meeting_id = meetings.id)
              AND NOT (\(Self.embedFailedAndNotCovered))
            """, [.text(space.model), .integer(Int64(space.dimensions))])[0].int(0)
        let covered = try db.query("""
            SELECT COUNT(*) FROM meetings WHERE ended_at IS NOT NULL AND raw_purged_at IS NULL
              AND EXISTS (SELECT 1 FROM segments WHERE meeting_id = meetings.id)
              AND EXISTS (SELECT 1 FROM chunks c WHERE c.meeting_id = meetings.id AND c.model = ?1 AND c.dims = ?2)
              AND NOT EXISTS (SELECT 1 FROM chunks c WHERE c.meeting_id = meetings.id AND (c.model <> ?1 OR c.dims <> ?2))
            """, [.text(space.model), .integer(Int64(space.dimensions))])[0].int(0)
        let skipped = try db.query("SELECT COUNT(*) FROM chunks WHERE model = ? AND dims = ? AND scale <= 0",
                                   [.text(space.model), .integer(Int64(space.dimensions))])[0].int(0)
        return SemanticRanker.Coverage(covered: Int(covered), total: Int(total), skipped: Int(skipped))
    }

    /// SQL (parameters ?1 model, ?2 dimensions): the meeting has a failed embedding job and is not covered in the space, so it
    /// counts as neither covered nor missing.
    private static let embedFailedAndNotCovered = """
        EXISTS (SELECT 1 FROM llm_jobs j WHERE j.meeting_id = meetings.id AND j.kind = 'embed' AND j.state = 'failed')
        AND NOT (EXISTS (SELECT 1 FROM chunks c WHERE c.meeting_id = meetings.id AND c.model = ?1 AND c.dims = ?2)
                 AND NOT EXISTS (SELECT 1 FROM chunks c WHERE c.meeting_id = meetings.id AND (c.model <> ?1 OR c.dims <> ?2)))
        """

    /// Whether one meeting has its chunks in `space`.
    public func isCovered(_ meetingID: Int64, space: EmbeddingSpace) throws -> Bool {
        try db.query("""
            SELECT EXISTS (SELECT 1 FROM chunks c WHERE c.meeting_id = ?1 AND c.model = ?2 AND c.dims = ?3)
               AND NOT EXISTS (SELECT 1 FROM chunks c WHERE c.meeting_id = ?1 AND (c.model <> ?2 OR c.dims <> ?3))
            """, [.integer(meetingID), .text(space.model), .integer(Int64(space.dimensions))])[0].int(0) != 0
    }

    /// Embedded meetings only (for the cosine of related meetings): the best cosine of each other meeting's chunks to a query.
    public func relatedMeetings(queryVector: [Float], space: EmbeddingSpace, excluding meetingID: Int64, limit: Int = 3,
                                minimumScore: Float = SemanticRanker.relatedFloor) throws -> [(meeting: Meeting, score: Float)] {
        let index = try vectorIndex(space: space)
        // The query is this meeting's own topics and decisions, so its own chunks are the nearest neighbours: the search takes as
        // many more as the meeting has, and the other meetings still get their 80.
        let own = try db.query("SELECT COUNT(*) FROM chunks WHERE meeting_id = ?", [.integer(meetingID)])[0].int(0)
        let top = index.search(queryVector, k: 80 + Int(own))
        guard !top.isEmpty else { return [] }
        let rows = try db.query("SELECT id, meeting_id FROM chunks WHERE id IN (SELECT value FROM json_each(?))", [.ids(top.map(\.id))])
        let owner = Dictionary(uniqueKeysWithValues: rows.map { ($0.int(0), $0.int(1)) })
        var best: [Int64: Float] = [:]
        for hit in top {
            guard let m = owner[hit.id], m != meetingID, hit.score >= minimumScore else { continue }
            best[m] = max(best[m] ?? 0, hit.score)
        }
        var out: [(Meeting, Float)] = []
        for (m, s) in best.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }).prefix(limit) {
            if let meeting = try self.meeting(m) { out.append((meeting, s)) }
        }
        return out
    }

    private struct Located {
        let key: String
        let meeting: Int64
        let start: Double
        let end: Double
        let chunkID: Int64?
    }

    /// Every chunk of `space` that holds a moment (chunks overlap by a segment, so a moment can belong to two), in order; else the
    /// time bucket a keyword hit falls in when the meeting has no chunk of that space there yet.
    private func locateAll(_ meeting: Int64, _ t: Double, space: EmbeddingSpace) throws -> [Located] {
        let chunks = try db.query("SELECT id, start, end FROM chunks WHERE meeting_id = ? AND model = ? AND dims = ? AND start <= ? AND end >= ? ORDER BY start, id",
                                  [.integer(meeting), .text(space.model), .integer(Int64(space.dimensions)), .real(t), .real(t)])
        if !chunks.isEmpty {
            return chunks.map { Located(key: "c\($0.int(0))", meeting: meeting, start: $0.double(1), end: $0.double(2), chunkID: $0.int(0)) }
        }
        let bucket = (t / Self.chunkTarget).rounded(.down) * Self.chunkTarget
        return [Located(key: "m\(meeting)@\(Int(bucket))", meeting: meeting, start: bucket, end: bucket + Self.chunkMax, chunkID: nil)]
    }

    /// Ranks by the cosine of the question to each passage (a stored int8 vector), then adds the boosts of `SemanticRanker`:
    /// +0.30 for a passage with every code of the question, +0.15 times the share of its rare names, and on the cosine scale the
    /// signals Ask already had (a named entity, a speaker the person named, a noted moment). The candidates are the vector top-K
    /// and the passages with an exact match, so a bare code is found even when the model does not put it in its top K.
    func retrieveSemantic(_ question: String, queryVector: [Float], within: Int64?, excluding: Int64? = nil, space: EmbeddingSpace, limit: Int,
                          maxChars: Int, locale: Locale?) throws -> [RetrievedPassage] {
        let profile = locale.map(LanguageProfile.init(locale:)) ?? LanguageProfile.detecting(question)
        let index = try vectorIndex(space: space)
        var ranges: [String: (meeting: Int64, start: Double, end: Double)] = [:]
        var cosine: [String: Double] = [:]
        // Candidates that hold a placeholder score instead of a cosine of their own (no vector yet): they rank, but are never reported
        // as a cosine to the evidence gate.
        var placeholder: Set<String> = []
        // Vector candidates, best first.
        var vectorScores: [Float] = []
        let top = try vectorCandidates(index, queryVector, k: 50, within: within, space: space)
        if !top.isEmpty {
            let rows = try db.query("SELECT id, meeting_id, start, end FROM chunks WHERE id IN (SELECT value FROM json_each(?))", [.ids(top.map(\.id))])
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.int(0), ($0.int(1), $0.double(2), $0.double(3))) })
            for hit in top.filter({ h in excluding == nil || byID[h.id]?.0 != excluding }) {
                guard let (m, s, e) = byID[hit.id] else { continue }
                let key = "c\(hit.id)"
                ranges[key] = (m, s, e)
                cosine[key] = Double(hit.score)
                vectorScores.append(hit.score)
            }
        }
        // Exact items.
        let codes = SemanticRanker.codes(in: question)
        let codeHits = try codes.compactMap { item in try ftsMatches(item, within: within, excluding: excluding, space: space).map { (item, $0) } }
        let rows = (try? db.query("SELECT COUNT(*) FROM segments")[0].int(0)).map(Int.init) ?? 0
        var nameHits: [(String, [Located])] = []
        for name in SemanticRanker.nameCandidates(in: question, excluding: codes) {
            guard let phrase = SemanticRanker.phrase(name) else { continue }
            let df = try db.query("SELECT COUNT(*) FROM (SELECT 1 FROM segments_fts WHERE segments_fts MATCH ? LIMIT ?)",
                                  [.text(phrase), .integer(Int64(SemanticRanker.rareLimit(rows: rows) + 1))])[0].int(0)
            guard df >= 1, df <= SemanticRanker.rareLimit(rows: rows), let found = try ftsMatches(name, within: within, excluding: excluding, space: space) else { continue }
            nameHits.append((name, found))
        }
        func keys(_ located: [Located]) -> Set<String> { Set(located.map(\.key)) }
        let codeSets = codeHits.map { keys($0.1) }
        let nameSets = nameHits.map { keys($0.1) }
        // Candidates found by an exact match join the vector ones, with their own cosine.
        var extraChunks: [Int64] = []
        var pseudoRank: [String: Int] = [:]
        for (_, located) in codeHits.map({ ($0.0, $0.1) }) + nameHits.map({ ($0.0, $0.1) }) {
            for (rank, l) in located.prefix(SemanticRanker.candidatesPerItem).enumerated() where ranges[l.key] == nil {
                ranges[l.key] = (l.meeting, l.start, l.end)
                // Every extra candidate keeps its rank: a chunk that has no vector in this space yet (it waits to be embedded again)
                // gets a rank-aligned score, not the best cosine of the top.
                pseudoRank[l.key] = rank
                if let id = l.chunkID { extraChunks.append(id) }
            }
        }
        let own = index.score(queryVector, ids: extraChunks)
        for key in ranges.keys where cosine[key] == nil {
            if key.hasPrefix("c"), let id = Int64(key.dropFirst()), let c = own[id] { cosine[key] = Double(c) }
            else {
                cosine[key] = SemanticRanker.pseudoScore(rank: pseudoRank[key] ?? 0, vectorScores: vectorScores)
                placeholder.insert(key)
            }
        }
        // Meetings recorded minutes ago have no vector yet: their best keyword matches join with a rank-aligned score.
        let terms = Self.queryTerms(question, profile: profile)
        if let behind = try keywordBuckets(terms, within: within, excluding: excluding, space: space) {
            for (rank, l) in behind.enumerated() where ranges[l.key] == nil {
                ranges[l.key] = (l.meeting, l.start, l.end)
                cosine[l.key] = SemanticRanker.pseudoScore(rank: rank, vectorScores: vectorScores)
                placeholder.insert(l.key)
            }
        }
        // Scores.
        var score: [String: Double] = [:]
        for (key, base) in cosine {
            let codeMatched = codeSets.filter { $0.contains(key) }.count
            let nameMatched = nameSets.filter { $0.contains(key) }.count
            score[key] = base + SemanticRanker.boost(codesMatched: codeMatched, codesTotal: codeSets.count, namesMatched: nameMatched, namesTotal: nameSets.count)
        }
        // The context graph: passages that name the question's people or projects, and what a named speaker said.
        let entities = try entitiesNamed(in: question, locale: profile.locale)
        if !entities.isEmpty {
            for (key, r) in ranges {
                let named = try db.query("SELECT COUNT(DISTINCT entity_id) FROM mentions WHERE meeting_id = ? AND t BETWEEN ? AND ? AND entity_id IN (SELECT value FROM json_each(?))",
                                         [.integer(r.meeting), .real(r.start), .real(r.end), .ids(entities)])[0].int(0)
                if named > 0 { score[key, default: 0] += 0.08 }
                let said = try db.query("""
                    SELECT COUNT(*) FROM segments s JOIN meeting_speakers sp ON sp.id = s.speaker_id
                    WHERE s.meeting_id = ?1 AND s.start BETWEEN ?2 AND ?3 AND sp.source = 'user'
                      AND sp.entity_id IN (SELECT id FROM entities WHERE id IN (SELECT value FROM json_each(?4)) OR merged_into IN (SELECT value FROM json_each(?4)))
                      AND (s.speaker_confidence IS NULL OR s.speaker_confidence >= ?5) AND s.overlap = 0
                    """, [.integer(r.meeting), .real(r.start), .real(r.end), .ids(entities), .real(SpeakerTag.lowConfidenceBelow)])[0].int(0)
                if said > 0 { score[key, default: 0] += 0.08 }
            }
        }
        for moment in try noteCitedMoments(terms: terms, within: within).prefix(40) where moment.meeting != excluding {
            for l in try locateAll(moment.meeting, moment.t, space: space) where ranges[l.key] != nil { score[l.key, default: 0] += 0.04 }
        }
        return try assemble(Array(score), ranges: ranges, limit: limit, maxChars: maxChars, cosine: cosine.filter { !placeholder.contains($0.key) })
    }

    /// The passages that contain an item as a phrase (at most 400 rows by keyword rank), nil when none does.
    private func ftsMatches(_ item: String, within: Int64?, excluding: Int64?, space: EmbeddingSpace) throws -> [Located]? {
        guard let phrase = SemanticRanker.phrase(item) else { return nil }
        let rows = try db.query("""
            SELECT s.meeting_id, s.start FROM segments_fts f JOIN segments s ON s.id = f.rowid
            WHERE segments_fts MATCH ?1 AND (?2 IS NULL OR s.meeting_id = ?2) AND (?3 IS NULL OR s.meeting_id <> ?3) ORDER BY rank LIMIT 400
            """, [.text(phrase), within.map { .integer($0) }, excluding.map { .integer($0) }])
        guard !rows.isEmpty else { return nil }
        var seen = Set<String>()
        var out: [Located] = []
        for r in rows {
            for l in try locateAll(r.int(0), r.double(1), space: space) where seen.insert(l.key).inserted { out.append(l) }
        }
        return out
    }

    /// The best keyword matches that fall where no chunk exists yet (a meeting not embedded yet), best first.
    private func keywordBuckets(_ terms: [String], within: Int64?, excluding: Int64?, space: EmbeddingSpace) throws -> [Located]? {
        let spaced = terms.filter { !$0.contains(where: TextKeys.isNoSpaceScript) }
        guard !spaced.isEmpty else { return nil }
        let match = spaced.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }.joined(separator: " OR ")
        let rows = try db.query("""
            SELECT s.meeting_id, s.start FROM segments_fts f JOIN segments s ON s.id = f.rowid
            WHERE segments_fts MATCH ?1 AND (?2 IS NULL OR s.meeting_id = ?2) AND (?5 IS NULL OR s.meeting_id <> ?5)
              AND NOT EXISTS (SELECT 1 FROM chunks c WHERE c.meeting_id = s.meeting_id AND c.model = ?3 AND c.dims = ?4
                              AND c.start <= s.start AND c.end >= s.start)
            ORDER BY rank LIMIT 20
            """, [.text(match), within.map { .integer($0) }, .text(space.model), .integer(Int64(space.dimensions)), excluding.map { .integer($0) }])
        var seen = Set<String>()
        var out: [Located] = []
        for r in rows {
            for l in try locateAll(r.int(0), r.double(1), space: space) where seen.insert(l.key).inserted { out.append(l) }
        }
        return out.isEmpty ? nil : out
    }
}
