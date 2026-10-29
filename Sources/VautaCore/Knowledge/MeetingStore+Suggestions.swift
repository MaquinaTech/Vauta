// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Persisted form of `suggestions.candidates`: {"c": [candidate], "n": occurrences}.
struct SuggestionPayload: Codable {
    var c: [SuggestionCandidate]
    var n: Int

    func json() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
}

/// Review suggestions: ambiguous names and likely transcription errors.
extension MeetingStore {
    public func suggestions(_ meetingID: Int64) throws -> [Suggestion] {
        try db.query("""
            SELECT id, meeting_id, segment_id, t, kind, surface, candidates FROM suggestions
            WHERE meeting_id = ? AND status = 'open' ORDER BY t
            """, [.integer(meetingID)]).map { row in
            let payload = try? JSONDecoder().decode(SuggestionPayload.self, from: Data(row.string(6).utf8))
            return Suggestion(id: row.int(0), meetingID: row.int(1), segmentID: row.optionalInt(2), t: row.double(3),
                              kind: Suggestion.Kind(rawValue: row.string(4)) ?? .ambiguous, surface: row.string(5),
                              candidates: payload?.c ?? [], occurrences: payload?.n ?? 1)
        }
    }

    /// Open suggestions per meeting (for the meeting list).
    public func openSuggestionCounts() throws -> [Int64: Int] {
        Dictionary(uniqueKeysWithValues: try db.query("SELECT meeting_id, COUNT(*) FROM suggestions WHERE status = 'open' GROUP BY meeting_id").map {
            ($0.int(0), Int($0.int(1)))
        })
    }

    /// Accepts a glossary term as the right spelling. A term linked to a person or project resolves like that
    /// entity; a plain term only closes the suggestion (and every other one with the same surface in the meeting).
    public func resolveSuggestion(_ id: Int64, glossary term: Int64) async throws {
        let linked = try db.query("SELECT entity_id FROM glossary WHERE id = ?", [.integer(term)]).first
        guard let linked else { throw KnowledgeError.suggestionGone }
        if let entity = linked.optionalInt(0) {
            try await resolveSuggestion(id, entity: entity)
            return
        }
        try transaction {
            guard let row = try db.query("SELECT meeting_id, surface FROM suggestions WHERE id = ? AND status = 'open'", [.integer(id)]).first else {
                throw KnowledgeError.suggestionGone
            }
            try run("UPDATE suggestions SET status = 'accepted' WHERE meeting_id = ? AND surface = ? AND status = 'open'",
                    [.integer(row.int(0)), .text(row.string(1))])
        }
        try await commitEdit()
    }

    /// Decides a suggestion: `entity` is the chosen one (nil = reject).
    /// Learning is explicit and local: an ambiguous name strengthens the
    /// chosen entity's alias; a transcription error becomes a learned alias,
    /// so the next meeting recognizes it as an exact match. Every occurrence
    /// of the name in this meeting becomes a user mention.
    public func resolveSuggestion(_ id: Int64, entity: Int64?) async throws {
        try transaction {
            guard let row = try db.query("SELECT meeting_id, kind, surface FROM suggestions WHERE id = ? AND status = 'open'", [.integer(id)]).first else {
                throw KnowledgeError.suggestionGone
            }
            let meetingID = row.int(0), kind = Suggestion.Kind(rawValue: row.string(1)) ?? .ambiguous, surface = row.string(2)
            // The candidate may have been merged since: follow it. A deleted one is an error, not a foreign-key failure.
            let chosen = try entity.map { e -> Int64 in
                guard let live = try db.query("SELECT coalesce(merged_into, id) FROM entities WHERE id = ?", [.integer(e)]).first?.int(0) else {
                    throw KnowledgeError.entityGone
                }
                return live
            }
            let norm = TextKeys.norm(surface)
            try run("UPDATE suggestions SET status = ? WHERE meeting_id = ? AND surface = ? AND status = 'open'",
                    [.text(chosen == nil ? "rejected" : "accepted"), .integer(meetingID), .text(surface)])
            guard let chosen else { return }
            if kind == .ambiguous {
                try run("UPDATE aliases SET weight = min(weight + 0.25, 3) WHERE alias_norm = ? AND entity_id = ?", [.text(norm), .integer(chosen)])
            } else {
                try addAlias(surface, norm: norm, to: chosen, source: "learned", weight: 1)
            }
            let profile = LanguageProfile(locale: try meetingLocale(meetingID))
            let matcher = NameMatcher([(norm: norm, value: chosen)], profile: profile, gated: false)
            for seg in try db.query("SELECT id, start, text FROM segments WHERE meeting_id = ? AND echo <> 1", [.integer(meetingID)]) {
                let text = seg.string(2)
                for m in matcher.matches(in: text, tokens: TextKeys.tokens(text, profile: profile), profile: profile) {
                    try run("""
                        INSERT INTO mentions(entity_id, meeting_id, segment_id, t, surface, confidence, resolved_by)
                        SELECT ?1, ?2, ?3, ?4, ?5, 1, 'user'
                        WHERE NOT EXISTS (SELECT 1 FROM mentions WHERE segment_id = ?3 AND entity_id = ?1)
                        """, [.integer(chosen), .integer(meetingID), .integer(seg.int(0)), .real(seg.double(1)), .text(m.surface)])
                }
            }
        }
        try await commitEdit()
    }
}
