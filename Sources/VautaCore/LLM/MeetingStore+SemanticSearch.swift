// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Ask's retrieval when the search model ranks (`SemanticRanker.Mode.semantic`).
extension MeetingStore {
    /// Meetings that could be embedded (ended, with a transcript) and how many have all their chunks in `space`; with `meetings`,
    /// only those (a filter of the meetings list).
    /// "Covered" does not check the chunk text against speaker names (that check is per meeting and the embedding job does it).
    public func vectorCoverage(space: EmbeddingSpace, meetings: [Int64]? = nil) throws -> SemanticRanker.Coverage {
        // A meeting whose embedding job ran out of attempts (`failed`) and has no vectors is left out of the count, like the chunks
        // the model cannot read: it would only fail again, and one such meeting must not keep Ask on keywords for good. Changing
        // the settings or regenerating forgets the failed job, so it counts (and is tried) again.
        let params: [SQLiteValue?] = [.text(space.model), .integer(Int64(space.dimensions)), meetings.map { .ids($0) }]
        let total = try db.query("""
            SELECT COUNT(*) FROM meetings WHERE ended_at IS NOT NULL AND raw_purged_at IS NULL
              AND (?3 IS NULL OR id IN (SELECT value FROM json_each(?3)))
              AND EXISTS (SELECT 1 FROM segments WHERE meeting_id = meetings.id)
              AND NOT (\(Self.embedFailedAndNotCovered))
            """, params)[0].int(0)
        let covered = try db.query("""
            SELECT COUNT(*) FROM meetings WHERE ended_at IS NOT NULL AND raw_purged_at IS NULL
              AND (?3 IS NULL OR id IN (SELECT value FROM json_each(?3)))
              AND EXISTS (SELECT 1 FROM segments WHERE meeting_id = meetings.id)
              AND EXISTS (SELECT 1 FROM chunks c WHERE c.meeting_id = meetings.id AND c.model = ?1 AND c.dims = ?2)
              AND NOT EXISTS (SELECT 1 FROM chunks c WHERE c.meeting_id = meetings.id AND (c.model <> ?1 OR c.dims <> ?2))
            """, params)[0].int(0)
        let skipped = try db.query("""
            SELECT COUNT(*) FROM chunks WHERE model = ?1 AND dims = ?2 AND scale <= 0
              AND (?3 IS NULL OR meeting_id IN (SELECT value FROM json_each(?3)))
            """, params)[0].int(0)
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

    /// Ranks by the cosine of the question to each passage (a stored int8 vector), then adds the boosts of `SemanticRanker`:
    /// +0.30 for a passage with every code of the question, +0.15 times the share of its rare names, and on the cosine scale the
    /// signals Ask already had (a named entity, a speaker the person named, a noted moment). The candidates are the vector top-K
    /// and the passages with an exact match, so a bare code is found even when the model does not put it in its top K.
    func retrieveSemantic(_ question: String, queryVector: [Float], scope: [Int64]?, excluding: Int64? = nil, space: EmbeddingSpace, limit: Int,
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
        let top = try vectorCandidates(index, queryVector, k: 50, scope: scope, space: space)
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
        let codeHits = try codes.compactMap { item in try ftsMatches(item, scope: scope, excluding: excluding, space: space).map { (item, $0) } }
        let names = SemanticRanker.nameCandidates(in: question, excluding: codes)
        // The size of the transcript says when a name is rare: it is counted only for a question with a name.
        let rows = names.isEmpty ? 0 : (try? db.query("SELECT COUNT(*) FROM segments")[0].int(0)).map(Int.init) ?? 0
        var nameHits: [(String, [Located])] = []
        for name in names {
            guard let phrase = SemanticRanker.phrase(name) else { continue }
            let df = try db.query("SELECT COUNT(*) FROM (SELECT 1 FROM segments_fts WHERE segments_fts MATCH ? LIMIT ?)",
                                  [.text(phrase), .integer(Int64(SemanticRanker.rareLimit(rows: rows) + 1))])[0].int(0)
            guard df >= 1, df <= SemanticRanker.rareLimit(rows: rows), let found = try ftsMatches(name, scope: scope, excluding: excluding, space: space) else { continue }
            nameHits.append((name, found))
        }
        // Where the transcript misheard a person or project of the question (`misheardMoments`).
        let entities = try entitiesNamed(in: question, locale: profile.locale)
        let misheard = try misheardMoments(of: entities, scope: scope, excluding: excluding)
        let holdingMisheard = try chunksHolding(misheard.map(\.segment), space: space)
        var misheardHits: [Located] = []
        var confirmedMisheard = Set<String>()
        for m in misheard {
            let found = holdingMisheard[m.segment]?.map { Located(chunk: $0, meeting: m.meeting) } ?? [Located(bucketOf: m.t, meeting: m.meeting)]
            for l in found {
                if m.confirmed { confirmedMisheard.insert(l.key) }
                if !misheardHits.contains(where: { $0.key == l.key }) { misheardHits.append(l) }
            }
        }
        func keys(_ located: [Located]) -> Set<String> { Set(located.map(\.key)) }
        let codeSets = codeHits.map { keys($0.1) }
        let nameSets = nameHits.map { keys($0.1) }
        // Candidates found by an exact match, or by a misheard name, join the vector ones, with their own cosine.
        var extraChunks: [Int64] = []
        var pseudoRank: [String: Int] = [:]
        for (_, located) in codeHits.map({ ($0.0, $0.1) }) + nameHits.map({ ($0.0, $0.1) }) + [("", misheardHits)] {
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
        if let behind = try keywordBuckets(terms, scope: scope, excluding: excluding, space: space) {
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
        // The context graph: passages that name the question's people or projects, and what a named speaker said. A misheard name
        // lifts its passage as the name does, half as much while the correction is open, and once with the name.
        if !entities.isEmpty {
            let signals = try graphSignals(ranges, entities: entities)
            for (key, signal) in signals {
                if signal.named > 0 { score[key, default: 0] += 0.08 }
                if signal.said { score[key, default: 0] += 0.08 }
            }
            for key in keys(misheardHits) where ranges[key] != nil && (signals[key]?.named ?? 0) == 0 {
                score[key, default: 0] += confirmedMisheard.contains(key) ? 0.08 : 0.04
            }
        }
        for moment in try noteCitedMoments(terms: terms, scope: scope).prefix(40) where moment.meeting != excluding {
            for l in try locate(moment.t, in: moment.meeting, space: space) where ranges[l.key] != nil { score[l.key, default: 0] += 0.04 }
        }
        // The minutes' items that match the question: a smaller lift than the person's own notes, on a passage already ranked by meaning.
        for moment in try itemCitedMoments(terms: terms, scope: scope) where moment.meeting != excluding {
            for l in try locate(moment.t, in: moment.meeting, space: space) where ranges[l.key] != nil { score[l.key, default: 0] += 0.04 * itemKeyWeight / 1.5 }
        }
        return try assemble(Array(score), ranges: ranges, limit: limit, maxChars: maxChars, cosine: cosine.filter { !placeholder.contains($0.key) })
    }

    /// The passages that contain an item as a phrase (at most 400 rows by keyword rank), nil when none does.
    private func ftsMatches(_ item: String, scope: [Int64]?, excluding: Int64?, space: EmbeddingSpace) throws -> [Located]? {
        guard let phrase = SemanticRanker.phrase(item) else { return nil }
        let rows = try db.query("""
            SELECT s.id, s.meeting_id, s.start FROM segments_fts f JOIN segments s ON s.id = f.rowid
            WHERE segments_fts MATCH ?1 AND (?2 IS NULL OR s.meeting_id IN (SELECT value FROM json_each(?2))) AND (?3 IS NULL OR s.meeting_id <> ?3) AND \(Self.notEcho) ORDER BY rank LIMIT 400
            """, [.text(phrase), scope.map { .ids($0) }, excluding.map { .integer($0) }])
        guard !rows.isEmpty else { return nil }
        let holding = try chunksHolding(rows.map { $0.int(0) }, space: space)
        var seen = Set<String>()
        var out: [Located] = []
        for r in rows {
            let m = r.int(1)
            let found = holding[r.int(0)]?.map { Located(chunk: $0, meeting: m) } ?? [Located(bucketOf: r.double(2), meeting: m)]
            for l in found where seen.insert(l.key).inserted { out.append(l) }
        }
        return out
    }

    /// The best keyword matches that fall where no chunk exists yet (a meeting not embedded yet), best first.
    private func keywordBuckets(_ terms: [String], scope: [Int64]?, excluding: Int64?, space: EmbeddingSpace) throws -> [Located]? {
        let spaced = terms.filter { !$0.contains(where: TextKeys.isNoSpaceScript) }
        guard !spaced.isEmpty else { return nil }
        let match = spaced.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }.joined(separator: " OR ")
        let rows = try db.query("""
            SELECT s.meeting_id, s.start FROM segments_fts f JOIN segments s ON s.id = f.rowid
            WHERE segments_fts MATCH ?1 AND (?2 IS NULL OR s.meeting_id IN (SELECT value FROM json_each(?2))) AND (?5 IS NULL OR s.meeting_id <> ?5) AND \(Self.notEcho)
              AND NOT EXISTS (SELECT 1 FROM chunks c WHERE c.meeting_id = s.meeting_id AND c.model = ?3 AND c.dims = ?4
                              AND c.start <= s.start AND c.end >= s.start)
            ORDER BY rank LIMIT 20
            """, [.text(match), scope.map { .ids($0) }, .text(space.model), .integer(Int64(space.dimensions)), excluding.map { .integer($0) }])
        // No chunk of the space holds these segments: each goes to its time bucket.
        var seen = Set<String>()
        var out: [Located] = []
        for r in rows {
            let l = Located(bucketOf: r.double(1), meeting: r.int(0))
            if seen.insert(l.key).inserted { out.append(l) }
        }
        return out.isEmpty ? nil : out
    }
}
