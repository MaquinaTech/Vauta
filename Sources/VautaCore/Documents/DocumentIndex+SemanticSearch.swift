// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Search of the person's documents when the search model ranks (`SemanticRanker.Mode.semantic`).
extension DocumentIndex {
    /// Passages, and how many have a vector in `space`.
    public func vectorCoverage(space: EmbeddingSpace) throws -> SemanticRanker.Coverage {
        let total = try db.query("SELECT COUNT(*) FROM passages")[0].int(0)
        let covered = try db.query("SELECT COUNT(*) FROM passage_vectors WHERE model = ? AND dims = ?",
                                   [.text(space.model), .integer(Int64(space.dimensions))])[0].int(0)
        let skipped = try db.query("SELECT COUNT(*) FROM passage_vectors WHERE model = ? AND dims = ? AND scale <= 0",
                                   [.text(space.model), .integer(Int64(space.dimensions))])[0].int(0)
        return SemanticRanker.Coverage(covered: Int(min(covered, total)), total: Int(total), skipped: Int(skipped))
    }

    /// Whether every passage of the filtered files has a vector in `space`.
    public func isCovered(_ filter: DocumentFilter, space: EmbeddingSpace) throws -> Bool {
        let files = try fileIDs(matching: filter)
        guard !files.isEmpty else { return true }
        return try db.query("""
            SELECT NOT EXISTS (
                SELECT 1 FROM passages p WHERE p.file_id IN (SELECT value FROM json_each(?1))
                  AND NOT EXISTS (SELECT 1 FROM passage_vectors v WHERE v.passage_id = p.id AND v.model = ?2 AND v.dims = ?3))
            """, [.ids(files), .text(space.model), .integer(Int64(space.dimensions))])[0].int(0) != 0
    }

    /// Passages that contain `item` as a phrase of its words (as the keyword index tokenises them), best keyword rank first.
    private func exactMatches(_ item: String, allowed: [Int64]?) throws -> [Int64]? {
        let words = TextKeys.norm(item)
        guard !words.isEmpty else { return nil }
        let phrase = "\"" + words.replacingOccurrences(of: "\"", with: "") + "\""
        let rows = try db.query("""
            SELECT p.id FROM passages_fts f JOIN passages p ON p.id = f.rowid
            WHERE passages_fts MATCH ?1 AND (?2 IS NULL OR p.file_id IN (SELECT value FROM json_each(?2))) ORDER BY rank LIMIT 400
            """, [.text(phrase), allowed.map { .ids($0) }])
        return rows.isEmpty ? nil : rows.map { $0.int(0) }
    }

    func searchSemantic(_ question: String, queryVector: [Float], space: EmbeddingSpace, within filter: DocumentFilter?, limit: Int,
                        locale: Locale?, entities: [[String]]) throws -> [DocumentPassage] {
        let profile = locale.map(LanguageProfile.init(locale:)) ?? LanguageProfile.detecting(question)
        let allowed = try filter.map { try fileIDs(matching: $0) }
        if let allowed, allowed.isEmpty { return [] }
        let index = try vectorIndex(space: space)
        var cosine: [Int64: Double] = [:]
        var vectorScores: [Float] = []
        let top = index.search(queryVector, k: allowed == nil ? 50 : 400)
        var ids = top.map(\.id)
        if let allowed, !ids.isEmpty {
            let keep = Set(try db.query("SELECT id FROM passages WHERE id IN (SELECT value FROM json_each(?1)) AND file_id IN (SELECT value FROM json_each(?2))",
                                        [.ids(ids), .ids(allowed)]).map { $0.int(0) })
            ids = ids.filter(keep.contains)
        }
        let scoreOf = Dictionary(uniqueKeysWithValues: top.map { ($0.id, $0.score) })
        for id in ids.prefix(50) {
            cosine[id] = Double(scoreOf[id] ?? 0)
            vectorScores.append(scoreOf[id] ?? 0)
        }
        // Exact items.
        let codes = SemanticRanker.codes(in: question)
        let codeHits = try codes.compactMap { try exactMatches($0, allowed: allowed) }
        let total = (try? db.query("SELECT COUNT(*) FROM passages")[0].int(0)).map(Int.init) ?? 0
        var nameHits: [[Int64]] = []
        for name in SemanticRanker.nameCandidates(in: question, excluding: codes) {
            guard let found = try exactMatches(name, allowed: allowed), found.count <= SemanticRanker.rareLimit(rows: total) else { continue }
            nameHits.append(found)
        }
        var pseudoRank: [Int64: Int] = [:]
        var extra: [Int64] = []
        for list in codeHits + nameHits {
            for (rank, id) in list.prefix(SemanticRanker.candidatesPerItem).enumerated() where cosine[id] == nil {
                extra.append(id)
                pseudoRank[id] = rank
            }
        }
        let own = index.score(queryVector, ids: extra)
        // Passages that hold a placeholder score instead of a cosine of their own (no vector yet): they rank, but the gate never sees it.
        var placeholder: Set<Int64> = []
        for id in extra where cosine[id] == nil {
            if let c = own[id] { cosine[id] = Double(c) }
            else {
                cosine[id] = SemanticRanker.pseudoScore(rank: pseudoRank[id] ?? 0, vectorScores: vectorScores)
                placeholder.insert(id)
            }
        }
        // Passages without a vector yet (just added) join by their best keyword matches, with a rank-aligned score.
        if let match = Self.matchExpression(MeetingStore.queryTerms(question, profile: profile)) {
            let behind = try db.query("""
                SELECT p.id FROM passages_fts f JOIN passages p ON p.id = f.rowid
                WHERE passages_fts MATCH ?1 AND (?2 IS NULL OR p.file_id IN (SELECT value FROM json_each(?2)))
                  AND NOT EXISTS (SELECT 1 FROM passage_vectors v WHERE v.passage_id = p.id AND v.model = ?3 AND v.dims = ?4)
                ORDER BY rank LIMIT 20
                """, [.text(match), allowed.map { .ids($0) }, .text(space.model), .integer(Int64(space.dimensions))])
            for (rank, row) in behind.enumerated() where cosine[row.int(0)] == nil {
                cosine[row.int(0)] = SemanticRanker.pseudoScore(rank: rank, vectorScores: vectorScores)
                placeholder.insert(row.int(0))
            }
        }
        guard !cosine.isEmpty else { return [] }
        let codeSets = codeHits.map(Set.init), nameSets = nameHits.map(Set.init)
        var score: [Int64: Double] = [:]
        for (id, base) in cosine {
            score[id] = base + SemanticRanker.boost(codesMatched: codeSets.filter { $0.contains(id) }.count, codesTotal: codeSets.count,
                                                    namesMatched: nameSets.filter { $0.contains(id) }.count, namesTotal: nameSets.count)
        }
        let wanted = max(1, limit)
        let named = entities.filter { !$0.isEmpty }
        let candidates = SemanticRanker.order(score).prefix(named.isEmpty ? wanted : max(wanted * 3, 30))
        let found = Dictionary(uniqueKeysWithValues: try passages(ids: candidates.map(\.key)).map { ($0.id, $0) })
        if !named.isEmpty {
            // A passage that names the question's people or projects moves up (the entity match of the keyword path, on the cosine scale).
            let matcherEntries = named.enumerated().flatMap { index, aliases in aliases.map { (norm: $0, value: index) } }
            let matcher = NameMatcher(matcherEntries, profile: profile)
            for (id, passage) in found {
                let tokens = TextKeys.tokens(passage.text, profile: profile)
                let count = Set(matcher.matches(in: passage.text, tokens: tokens, profile: profile).flatMap(\.values)).count
                if count > 0 { score[id, default: 0] += min(0.08, 0.04 * Double(count)) }
            }
        }
        return SemanticRanker.order(score).prefix(wanted).compactMap { id, s in found[id].map { var p = $0; p.score = s; p.cosine = placeholder.contains(id) ? nil : cosine[id]; return p } }
    }
}
