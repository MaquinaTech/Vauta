// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
internal import NaturalLanguage

/// The keyword terms a passage is searched by.
public enum DocumentTerms {
    /// Normalized words joined by spaces, segmented for the passage's language, so Japanese, Chinese and Thai passages
    /// are found by the words of a question just as English ones are.
    public static func terms(for text: String) -> String {
        let profile = LanguageProfile.detecting(text, fallback: LanguageProfile(locale: Locale(identifier: "en")))
        return TextKeys.tokens(text, profile: profile).map(\.norm).joined(separator: " ")
    }
}

/// Which files a search may look in: whole sources, or single files of a source (a meeting's materials).
public struct DocumentFilter: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var source: Int64
        /// nil = every file of the source.
        public var relPath: String?
        public init(source: Int64, relPath: String? = nil) {
            self.source = source
            self.relPath = relPath
        }
    }

    public var entries: [Entry]
    public init(_ entries: [Entry]) { self.entries = entries }
}

extension DocumentIndex {
    /// The ids of the files a filter names.
    func fileIDs(matching filter: DocumentFilter) throws -> [Int64] {
        var ids = Set<Int64>()
        for entry in filter.entries {
            if let path = entry.relPath {
                if let id = try db.query("SELECT id FROM files WHERE source_id = ? AND rel_path = ?", [.integer(entry.source), .text(path)]).first?.int(0) { ids.insert(id) }
            } else {
                for row in try db.query("SELECT id FROM files WHERE source_id = ?", [.integer(entry.source)]) { ids.insert(row.int(0)) }
            }
        }
        return Array(ids)
    }

    /// The FTS query for a question's terms, OR-ed prefix matches over the same normalization the passages were indexed with.
    static func matchExpression(_ terms: [String]) -> String? {
        var seen = Set<String>()
        let parts = terms.compactMap { term -> String? in
            let norm = TextKeys.norm(term).replacingOccurrences(of: "\"", with: "")
            guard !norm.isEmpty, seen.insert(norm).inserted else { return nil }
            return "\"\(norm)\"*"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " OR ")
    }

    /// Passages for a question: keywords (BM25 over the segmented terms) and, when the question was embedded in a space the
    /// passages have vectors for, meaning, fused with RRF (k = 60). Without vectors it is keywords alone.
    /// `entities`: the alias keys of each person or project the question names (one list per entity): a passage that names one of
    /// them ranks higher, as in the meetings' retrieval.
    /// `mode` (see `SemanticRanker`): `.rrf` is the fusion above (the default), `.keyword` ignores vectors, `.semantic` ranks by the
    /// search model's cosine and uses keywords only to boost exact codes and rare names.
    public func search(_ question: String, queryVector: [Float]? = nil, space: EmbeddingSpace? = nil, within filter: DocumentFilter? = nil,
                       limit: Int = 12, locale: Locale? = nil, entities: [[String]] = [],
                       mode: SemanticRanker.Mode = .rrf) throws -> [DocumentPassage] {
        if mode == .semantic, let queryVector, let space {
            return try searchSemantic(question, queryVector: queryVector, space: space, within: filter, limit: limit, locale: locale, entities: entities)
        }
        let queryVector = mode == .keyword ? nil : queryVector
        let profile = locale.map(LanguageProfile.init(locale:)) ?? LanguageProfile.detecting(question)
        let allowed = try filter.map { try fileIDs(matching: $0) }
        if let allowed, allowed.isEmpty { return [] }
        var score: [Int64: Double] = [:]
        func add(_ id: Int64, rank: Int) { score[id, default: 0] += 1 / Double(60 + rank) }

        if let match = Self.matchExpression(MeetingStore.queryTerms(question, profile: profile)) {
            let rows = try db.query("""
                SELECT p.id FROM passages_fts f JOIN passages p ON p.id = f.rowid
                WHERE passages_fts MATCH ?1 AND (?2 IS NULL OR p.file_id IN (SELECT value FROM json_each(?2))) ORDER BY rank LIMIT 80
                """, [.text(match), allowed.map { .ids($0) }])
            for (rank, row) in rows.enumerated() { add(row.int(0), rank: rank) }
        }
        if let queryVector, let space {
            let index = try vectorIndex(space: space)
            for (rank, hit) in try vectorCandidates(index, queryVector, k: 50, allowed: allowed).enumerated() { add(hit.id, rank: rank) }
        }
        func order(_ scores: [Int64: Double]) -> [(key: Int64, value: Double)] {
            scores.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        }
        guard !score.isEmpty else { return [] }
        let wanted = max(1, limit)
        let named = entities.filter { !$0.isEmpty }
        if named.isEmpty {
            let ranked = order(score).prefix(wanted)
            let found = Dictionary(uniqueKeysWithValues: try passages(ids: ranked.map(\.key)).map { ($0.id, $0) })
            return ranked.compactMap { id, s in found[id].map { var p = $0; p.score = s; return p } }
        }
        // The best candidates are read and the ones that name the question's people or projects move up (a name is a strong sign
        // that a passage is about them, and the on-device model only gets one or two documents).
        let candidates = order(score).prefix(max(wanted * 3, 30))
        let found = Dictionary(uniqueKeysWithValues: try passages(ids: candidates.map(\.key)).map { ($0.id, $0) })
        let matcherEntries = named.enumerated().flatMap { index, aliases in aliases.map { (norm: $0, value: index) } }
        let matcher = NameMatcher(matcherEntries, profile: profile)
        for (id, passage) in found {
            let tokens = TextKeys.tokens(passage.text, profile: profile)
            let count = Set(matcher.matches(in: passage.text, tokens: tokens, profile: profile).flatMap(\.values)).count
            if count > 0 { score[id, default: 0] += Double(count) / 60 }
        }
        return order(score).prefix(wanted).compactMap { id, s in found[id].map { var p = $0; p.score = s; return p } }
    }

    /// Passages by id (a citation, a viewer).
    public func passages(ids: [Int64]) throws -> [DocumentPassage] {
        try db.query("""
            SELECT p.id, p.key, p.file_id, f.source_id, f.rel_path, f.title, f.format, p.locator, p.text, p.ocr
            FROM passages p JOIN files f ON f.id = p.file_id WHERE p.id IN (SELECT value FROM json_each(?))
            """, [.ids(ids)]).compactMap(Self.passage)
    }

    public func passage(id: Int64) throws -> DocumentPassage? { try passages(ids: [id]).first }

    /// A passage by where it is: the file and its stable key (what a citation that outlives a request stores).
    public func passage(source: Int64, relPath: String, key: String) throws -> DocumentPassage? {
        try db.query("""
            SELECT p.id, p.key, p.file_id, f.source_id, f.rel_path, f.title, f.format, p.locator, p.text, p.ocr
            FROM passages p JOIN files f ON f.id = p.file_id WHERE f.source_id = ? AND f.rel_path = ? AND p.key = ?
            """, [.integer(source), .text(relPath), .text(key)]).first.flatMap(Self.passage)
    }

    /// The passages of a file in order (the changed-file fallback of the viewer and the quote search of a citation).
    public func passages(file: Int64) throws -> [DocumentPassage] {
        try db.query("""
            SELECT p.id, p.key, p.file_id, f.source_id, f.rel_path, f.title, f.format, p.locator, p.text, p.ocr
            FROM passages p JOIN files f ON f.id = p.file_id WHERE p.file_id = ? ORDER BY p.ordinal
            """, [.integer(file)]).compactMap(Self.passage)
    }

    private static func passage(_ r: Row) -> DocumentPassage? {
        guard let format = DocumentFormat(rawValue: r.string(6)), let locator = DocumentLocator(json: r.string(7)) else { return nil }
        let relPath = r.string(4)
        return DocumentPassage(id: r.int(0), key: r.string(1), fileID: r.int(2), sourceID: r.int(3), relPath: relPath,
                               fileName: (relPath as NSString).lastPathComponent, title: r.optionalString(5), format: format, locator: locator,
                               text: r.string(8), ocr: r.int(9) != 0, score: 0)
    }

    /// Matches of a text query, FTS only (the sidebar search).
    public func keywordHits(_ query: String, limit: Int = 5) throws -> [DocumentPassage] {
        try search(query, queryVector: nil, space: nil, within: nil, limit: limit)
    }

    // MARK: Vectors

    func vectorIndex(space: EmbeddingSpace) throws -> VectorIndex {
        if let cached = vectorCache, cached.space == space { return cached.index }
        let dims = space.dimensions
        let rows = try db.query("SELECT passage_id, scale, emb FROM passage_vectors WHERE model = ? AND dims = ? ORDER BY passage_id",
                                [.text(space.model), .integer(Int64(dims))])
        let buffer = SecretBuffer(capacity: max(1, rows.count * dims))
        var ids: [Int64] = [], scales: [Float] = []
        for r in rows {
            let emb = r.data(2)
            guard emb.count == dims, dims > 0, Float(r.double(1)) > VectorIndex.unembeddableScale else { continue }
            emb.withUnsafeBytes { (buffer.base + buffer.count).copyMemory(from: $0.baseAddress!, byteCount: dims) }
            buffer.count += dims
            ids.append(r.int(0))
            scales.append(Float(r.double(1)))
        }
        let index = VectorIndex(dims: dims, ids: ids, scales: scales, buffer: buffer)
        vectorCache = (space, index)
        return index
    }

    /// The vector candidates of a search, best first: the index's top `k`, or with `allowed` (file ids) the top `k` of those files'
    /// own passages, each scored (a top K of every source would leave them out when other files on the same topic fill it).
    func vectorCandidates(_ index: VectorIndex, _ query: [Float], k: Int, allowed: [Int64]?) throws -> [(id: Int64, score: Float)] {
        guard let allowed else { return index.search(query, k: k) }
        let ids = try db.query("SELECT id FROM passages WHERE file_id IN (SELECT value FROM json_each(?))", [.ids(allowed)]).map { $0.int(0) }
        return index.search(query, k: k, among: ids)
    }

    /// Passages that have no vector in `space`, to embed (the old vectors of another space are dropped by `dropVectors`).
    public func passagesNeedingVectors(space: EmbeddingSpace?, limit: Int) throws -> [(id: Int64, text: String)] {
        try db.query("""
            SELECT p.id, p.text FROM passages p
            LEFT JOIN passage_vectors v ON v.passage_id = p.id AND (?1 IS NULL OR (v.model = ?1 AND v.dims = ?2))
            WHERE v.passage_id IS NULL ORDER BY p.id LIMIT ?3
            """, [space.map { .text($0.model) }, .integer(Int64(space?.dimensions ?? 0)), .integer(Int64(limit))]).map { ($0.int(0), $0.string(1)) }
    }

    public func storeVectors(_ items: [(id: Int64, q: Data, scale: Float)], space: EmbeddingSpace) throws {
        try transaction {
            for item in items where item.q.count == space.dimensions {
                try db.query("INSERT OR REPLACE INTO passage_vectors(passage_id, model, dims, scale, emb) SELECT id, ?, ?, ?, ? FROM passages WHERE id = ?",
                             [.text(space.model), .integer(Int64(space.dimensions)), .real(Double(item.scale)), .blob(item.q), .integer(item.id)])
            }
        }
        vectorCache = nil
    }

    /// Passages with no vector of `model` (nil: with no vector at all).
    public func passagesNeedingVectors(model: String?, limit: Int) throws -> [(id: Int64, text: String)] {
        try db.query("""
            SELECT p.id, p.text FROM passages p
            LEFT JOIN passage_vectors v ON v.passage_id = p.id AND (?1 IS NULL OR v.model = ?1)
            WHERE v.passage_id IS NULL ORDER BY p.id LIMIT ?2
            """, [model.map { .text($0) }, .integer(Int64(limit))]).map { ($0.int(0), $0.string(1)) }
    }

    /// The next passages after `cursor` (by id) with no vector of `model`, so a passage that can't be embedded is walked past.
    public func passagesNeedingVectors(model: String?, after cursor: Int64, limit: Int) throws -> [(id: Int64, text: String)] {
        try db.query("""
            SELECT p.id, p.text FROM passages p
            LEFT JOIN passage_vectors v ON v.passage_id = p.id AND (?1 IS NULL OR v.model = ?1)
            WHERE v.passage_id IS NULL AND p.id > ?3 ORDER BY p.id LIMIT ?2
            """, [model.map { .text($0) }, .integer(Int64(limit)), .integer(cursor)]).map { ($0.int(0), $0.string(1)) }
    }

    /// Vectors of another model or size are dropped: spaces are never mixed.
    public func dropVectors(notIn space: EmbeddingSpace) throws {
        try transaction { try db.query("DELETE FROM passage_vectors WHERE model <> ? OR dims <> ?", [.text(space.model), .integer(Int64(space.dimensions))]) }
        vectorCache = nil
    }

    /// The same model at another vector size (a setting changed): its old vectors are dropped.
    public func dropVectors(ofModel space: EmbeddingSpace, otherThanDimensions: Bool = true) throws {
        try transaction { try db.query("DELETE FROM passage_vectors WHERE model = ? AND dims <> ?", [.text(space.model), .integer(Int64(space.dimensions))]) }
        vectorCache = nil
    }

    /// Every vector of the spaces whose model starts with `prefix` is dropped (the search model was removed).
    public func dropVectors(modelPrefix prefix: String) throws {
        try transaction { try db.query("DELETE FROM passage_vectors WHERE substr(model, 1, ?) = ?", [.integer(Int64(prefix.count)), .text(prefix)]) }
        vectorCache = nil
    }

    /// Every vector of a model other than `model` is dropped (the person chose another embedding model).
    public func dropVectors(otherThanModel model: String) throws {
        try transaction { try db.query("DELETE FROM passage_vectors WHERE model <> ?", [.text(model)]) }
        vectorCache = nil
    }

    public func vectorCount() throws -> Int { Int(try db.query("SELECT COUNT(*) FROM passage_vectors")[0].int(0)) }
}
