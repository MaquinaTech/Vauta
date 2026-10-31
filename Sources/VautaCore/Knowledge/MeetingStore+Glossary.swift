// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Glossary terms and recurring meeting series.
extension MeetingStore {
    // MARK: Glossary

    /// Pinned terms first, then in locale-aware order.
    public func glossary() throws -> [GlossaryTerm] {
        try db.query("SELECT id, term, expansion, note, entity_id, pinned FROM glossary").map {
            GlossaryTerm(id: $0.int(0), term: $0.string(1), expansion: $0.string(2), note: $0.string(3),
                         entityID: $0.optionalInt(4), pinned: $0.int(5) != 0)
        }.sorted { a, b in
            a.pinned != b.pinned ? a.pinned : a.term.localizedStandardCompare(b.term) == .orderedAscending
        }
    }

    @discardableResult
    public func saveGlossary(_ g: GlossaryTerm) async throws -> Int64 {
        let term = Self.clean(g.term, max: 200)
        guard !term.isEmpty else { throw KnowledgeError.emptyTerm }
        let params: [SQLiteValue?] = [.text(term), Self.optionalText(g.expansion, max: 400), Self.optionalText(g.note, max: 2000),
                                      g.entityID.map { .integer($0) }, .integer(g.pinned ? 1 : 0)]
        let id: Int64 = try transaction {
            if let id = g.id {
                try run("UPDATE glossary SET term = ?, expansion = ?, note = ?, entity_id = ?, pinned = ? WHERE id = ?", params + [.integer(id)])
                return id
            }
            try run("INSERT INTO glossary(term, expansion, note, entity_id, pinned) VALUES (?, ?, ?, ?, ?)", params)
            return db.lastInsertRowID
        }
        try await commitEdit()
        return id
    }

    /// Deletes the term. Open suggestions stop offering it as a candidate, and
    /// a suggestion left without candidates is removed.
    public func deleteGlossary(_ id: Int64) async throws {
        try transaction {
            try run("DELETE FROM glossary WHERE id = ?", [.integer(id)])
            try dropFromSuggestions(glossary: id)
        }
        pendingCompaction = true
        try await commitEdit()
    }

    private func dropFromSuggestions(glossary id: Int64) throws {
        for row in try db.query("""
            SELECT id, candidates FROM suggestions WHERE status = 'open'
               AND EXISTS (SELECT 1 FROM json_each(candidates, '$.c') WHERE json_extract(value, '$.glossaryID') = ?)
            """, [.integer(id)]) {
            guard var payload = try? JSONDecoder().decode(SuggestionPayload.self, from: Data(row.string(1).utf8)) else { continue }
            payload.c.removeAll { $0.glossaryID == id }
            if payload.c.isEmpty {
                try run("DELETE FROM suggestions WHERE id = ?", [.integer(row.int(0))])
            } else {
                try run("UPDATE suggestions SET candidates = ? WHERE id = ?", [.text(try payload.json()), .integer(row.int(0))])
            }
        }
    }

    // MARK: Terms from corrections

    /// A term `addCorrectedTerm` added, for Edit ▸ Undo. Kept in memory only.
    public struct CorrectedTerm: Sendable {
        public let id: Int64
        let term: String
    }

    /// Of `terms`, those neither in the glossary nor a name of an entry in Context (`TextKeys.norm`), each once.
    func unknownTerms(_ terms: [String]) throws -> [String] {
        guard !terms.isEmpty else { return [] }
        var known = Set(try db.query("SELECT term FROM glossary").map { TextKeys.norm($0.string(0)) })
        known.formUnion(try db.query("SELECT a.alias_norm FROM aliases a JOIN entities e ON e.id = a.entity_id WHERE e.merged_into IS NULL")
            .map { $0.string(0) })
        return terms.filter { known.insert(TextKeys.norm($0)).inserted }
    }

    /// Adds a name or term the person put in a transcript correction to the glossary, pinned: the custom vocabulary gives it to
    /// the speech recognizer, and a later meeting that seems to mishear it gets a suggestion. nil when Vauta knows it already.
    public func addCorrectedTerm(_ term: String) async throws -> CorrectedTerm? {
        let clean = Self.clean(term, max: 200)
        guard !clean.isEmpty else { throw KnowledgeError.emptyTerm }
        let added: CorrectedTerm? = try transaction {
            guard try !unknownTerms([clean]).isEmpty else { return nil }
            try run("INSERT INTO glossary(term, pinned) VALUES (?, 1)", [.text(clean)])
            return CorrectedTerm(id: db.lastInsertRowID, term: clean)
        }
        if added != nil { try await commitEdit() }
        return added
    }

    /// Takes the term out of the glossary again, unless the person renamed it since.
    public func undoAddCorrectedTerm(_ t: CorrectedTerm) async throws {
        try transaction {
            try run("DELETE FROM glossary WHERE id = ? AND term = ?", [.integer(t.id), .text(t.term)])
            if db.changes > 0 { try dropFromSuggestions(glossary: t.id) }
        }
        pendingCompaction = true
        try await commitEdit()
    }

    // MARK: Series

    public func series() throws -> [MeetingSeries] {
        try db.query("SELECT id, calendar_key, title_pattern, default_entities FROM series").map {
            MeetingSeries(id: $0.int(0), calendarKey: $0.optionalString(1), titlePattern: $0.string(2),
                          defaultEntities: Self.ids(fromJSON: $0.string(3)))
        }.sorted { $0.titlePattern.localizedStandardCompare($1.titlePattern) == .orderedAscending }
    }

    @discardableResult
    public func saveSeries(_ s: MeetingSeries) async throws -> Int64 {
        let title = Self.clean(s.titlePattern, max: 200)
        guard !title.isEmpty else { throw KnowledgeError.emptySeriesTitle }
        let json = Self.json(ids: s.defaultEntities)
        let id: Int64 = try transaction {
            if let id = s.id {
                try run("UPDATE series SET calendar_key = ?, title_pattern = ?, default_entities = ? WHERE id = ?",
                        [s.calendarKey.map { .text($0) }, .text(title), .text(json), .integer(id)])
                return id
            }
            try run("INSERT INTO series(calendar_key, title_pattern, default_entities) VALUES (?, ?, ?)",
                    [s.calendarKey.map { .text($0) }, .text(title), .text(json)])
            return db.lastInsertRowID
        }
        try await commitEdit()
        return id
    }

    public func deleteSeries(_ id: Int64) async throws {
        try run("DELETE FROM series WHERE id = ?", [.integer(id)])
        try await commitEdit()
    }

    public func setSeries(_ seriesID: Int64?, of meetingID: Int64) async throws {
        try run("UPDATE meetings SET series_id = ? WHERE id = ?", [seriesID.map { .integer($0) }, .integer(meetingID)])
        try await commitEdit()
    }

    /// The series whose title pattern appears in the meeting title as whole
    /// words (accent- and case-insensitive). The most specific (longest)
    /// pattern wins, so "Daily" does not capture "Daily payments" when that
    /// series exists, and "Sync" never matches "Async".
    public func seriesMatching(title: String) throws -> MeetingSeries? {
        let n = TextKeys.matchKey(TextKeys.norm(title))
        guard !n.isEmpty else { return nil }
        let padded = " \(n) "
        var best: (series: MeetingSeries, length: Int)?
        for s in try series() {
            let pattern = TextKeys.matchKey(TextKeys.norm(s.titlePattern))
            guard !pattern.isEmpty, padded.contains(" \(pattern) ") || Self.containsInNoSpaceScript(n, pattern) else { continue }
            // Longest pattern wins; on a tie, the oldest series.
            if let b = best, b.length > pattern.count || (b.length == pattern.count && (b.series.id ?? 0) < (s.id ?? 0)) { continue }
            best = (s, pattern.count)
        }
        return best?.series
    }

    /// Titles in Chinese, Japanese or Thai have no word boundaries to respect.
    private static func containsInNoSpaceScript(_ title: String, _ pattern: String) -> Bool {
        pattern.allSatisfy { $0 == " " || TextKeys.isNoSpaceScript($0) } && title.contains(pattern)
    }
}
