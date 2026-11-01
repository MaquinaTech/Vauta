// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Knowledge graph built with the techniques of a code indexer, applied to
/// meetings: the user's context is the "symbol table", every name in the
/// transcript is a "reference" resolved deterministically (or left as
/// ambiguous, never guessed), and every mention keeps meeting + time +
/// segment. No model and no network.
extension MeetingStore {
    /// Minimum score margin between the best and second candidate to resolve alone.
    static let resolutionMargin = 1.0

    private struct AliasTarget {
        let entity: Int64
        let weight: Double
    }

    private struct Occurrence {
        let segment: Int64
        let t: Double
        let surface: String
        let key: String
        let candidates: [AliasTarget]
    }

    private struct FuzzyKey {
        let norm: String
        let phonetic: String?
        let entity: Int64?
        let glossary: Int64?
        let label: String
    }

    private struct Correction {
        let segment: Int64
        let t: Double
        let surface: String
        let targets: [SuggestionCandidate]
        var count: Int
    }

    // MARK: Meeting language

    /// The meeting's transcription language: `meetings.locale` when set,
    /// otherwise the legacy `es-ES`.
    func meetingLocale(_ meetingID: Int64) throws -> Locale {
        let identifier = try db.query("SELECT locale FROM meetings WHERE id = ?", [.integer(meetingID)]).first?.optionalString(0)
        return Locale(identifier: identifier.flatMap { $0.isEmpty ? nil : $0 } ?? LanguageProfile.legacyLocaleIdentifier)
    }

    // MARK: Analysis of a meeting

    /// Scans the transcript for the names in the context and stores the
    /// mentions (meeting + time + segment). Ambiguous names and likely
    /// transcription errors become suggestions for the user. It can be
    /// repeated (e.g. after editing the context) and keeps what the user
    /// decided. A meeting whose raw text was purged is left untouched.
    /// `locale`: the transcript language; nil reads it from the meeting.
    @discardableResult
    public func analyze(_ meetingID: Int64, locale: Locale? = nil) async throws -> AnalysisSummary {
        let summary = try transaction { try analyzeInTransaction(meetingID, locale: locale) }
        if !summary.skipped { try await commitEdit() }
        return summary
    }

    /// Ended meetings that still have their transcript, newest first: the
    /// ones a full re-analysis should visit.
    public func analyzableMeetingIDs() throws -> [Int64] {
        try db.query("""
            SELECT id FROM meetings WHERE ended_at IS NOT NULL AND raw_purged_at IS NULL
              AND EXISTS (SELECT 1 FROM segments WHERE meeting_id = meetings.id) ORDER BY started_at DESC
            """).map { $0.int(0) }
    }

    func analyzeInTransaction(_ meetingID: Int64, locale: Locale? = nil) throws -> AnalysisSummary {
        var summary = AnalysisSummary()
        // Without a transcript (purged by retention) there is nothing to
        // re-derive: deleting the mentions would destroy the meeting's knowledge.
        let state = try db.query("""
            SELECT raw_purged_at IS NOT NULL, EXISTS (SELECT 1 FROM segments WHERE meeting_id = ?1) FROM meetings WHERE id = ?1
            """, [.integer(meetingID)]).first
        guard let state, state.int(0) == 0, state.int(1) != 0 else {
            summary.skipped = true
            return summary
        }
        let profile = LanguageProfile(locale: try locale ?? meetingLocale(meetingID))

        // Alias dictionary (normalized keys) → live entities; as written, for the sound keys.
        let aliases = try db.query("""
            SELECT a.alias_norm, a.entity_id, a.weight, a.alias FROM aliases a JOIN entities e ON e.id = a.entity_id
            WHERE e.merged_into IS NULL
            """).map { (norm: $0.string(0), value: AliasTarget(entity: $0.int(1), weight: $0.double(2)), written: $0.string(3)) }
        let entries = aliases.map { (norm: $0.norm, value: $0.value) }
        let matcher = NameMatcher(entries, profile: profile)
        let glossary = try db.query("SELECT id, term, entity_id FROM glossary").map { (id: $0.int(0), term: $0.string(1), entity: $0.optionalInt(2)) }
        try run("DELETE FROM mentions WHERE meeting_id = ? AND resolved_by NOT IN ('user', 'llm')", [.integer(meetingID)])
        try run("DELETE FROM suggestions WHERE meeting_id = ? AND status = 'open'", [.integer(meetingID)])
        guard !matcher.isEmpty || !glossary.isEmpty else { return summary }
        // Already decided by the user (never asked again for that name).
        let decided = Set(try db.query("SELECT DISTINCT surface FROM suggestions WHERE meeting_id = ? AND status != 'open'",
                                       [.integer(meetingID)]).map { TextKeys.matchKey(TextKeys.norm($0.string(0))) })
        let userMentions = Set(try db.query("SELECT segment_id, surface FROM mentions WHERE meeting_id = ? AND resolved_by IN ('user', 'llm')",
                                            [.integer(meetingID)]).map { "\($0.int(0))|\(TextKeys.matchKey(TextKeys.norm($0.string(1))))" })
        let names = Dictionary(try db.query("SELECT id, name FROM entities WHERE merged_into IS NULL").map { ($0.int(0), $0.string(1)) },
                               uniquingKeysWith: { a, _ in a })
        let fuzzy = profile.capitalizationMarksNames ? fuzzyKeys(aliases, glossary: glossary, names: names, matcher: matcher, profile: profile) : []

        var occurrences: [Occurrence] = []
        var corrections: [String: Correction] = [:]
        for seg in try db.query("SELECT id, start, text FROM segments WHERE meeting_id = ? AND echo <> 1 ORDER BY start, id", [.integer(meetingID)]) {
            let text = seg.string(2)
            let tokens = TextKeys.tokens(text, profile: profile)
            let matches = matcher.matches(in: text, tokens: tokens, profile: profile)
            for m in matches {
                occurrences.append(Occurrence(segment: seg.int(0), t: seg.double(1), surface: m.surface, key: m.key, candidates: m.values))
            }
            guard !fuzzy.isEmpty else { continue }
            // Corrector: only words that look like proper nouns, and it only suggests.
            for tok in tokens where profile.looksLikeName(tok) && tok.norm.count >= 4
                && !profile.noiseWords.contains(tok.norm) && !profile.stopwords.contains(tok.norm) && !decided.contains(tok.norm)
                && !matches.contains(where: { $0.range.overlaps(tok.range) }) {
                if corrections[tok.norm] != nil {
                    corrections[tok.norm]!.count += 1
                    continue
                }
                let targets = correctionTargets(tok.norm, written: tok.original, fuzzy: fuzzy, profile: profile)
                if !targets.isEmpty {
                    corrections[tok.norm] = Correction(segment: seg.int(0), t: seg.double(1), surface: tok.original, targets: targets, count: 1)
                }
            }
        }

        // Meeting context: attendees, "Others", topics and series entities.
        var context = Set(try db.query("""
            SELECT entity_id FROM meeting_entities WHERE meeting_id = ?1
            UNION SELECT j.value FROM meetings m JOIN series s ON s.id = m.series_id, json_each(s.default_entities) j WHERE m.id = ?1
            """, [.integer(meetingID)]).map { $0.int(0) })
        let attendees = context
        let now = Date.now.timeIntervalSince1970

        func mention(_ o: Occurrence, _ entity: Int64, confidence: Double, by: String) throws {
            guard !userMentions.contains("\(o.segment)|\(o.key)") else { return }
            try run("""
                INSERT INTO mentions(entity_id, meeting_id, segment_id, t, surface, confidence, resolved_by) VALUES (?, ?, ?, ?, ?, ?, ?)
                """, [.integer(entity), .integer(meetingID), .integer(o.segment), .real(o.t), .text(o.surface), .real(confidence), .text(by)])
            summary.mentions += 1
        }

        // Pass 1: names with a single candidate (they are context too).
        for o in occurrences where o.candidates.count == 1 {
            try mention(o, o.candidates[0].entity, confidence: 1, by: "exact")
            context.insert(o.candidates[0].entity)
        }
        // Pass 2: ambiguous names, scored by context; without a clear margin, the user decides.
        var ambiguous: [String: (o: Occurrence, scored: [SuggestionCandidate], count: Int)] = [:]
        for o in occurrences where o.candidates.count > 1 {
            if decided.contains(o.key) { continue }
            let scored = try o.candidates.map { c in
                SuggestionCandidate(entityID: c.entity, glossaryID: nil, label: names[c.entity] ?? o.surface,
                                    score: try score(c, attendees: attendees, context: context.subtracting([c.entity]), meetingID: meetingID, now: now))
            }.sorted { $0.score > $1.score }
            if scored[0].score - scored[1].score >= Self.resolutionMargin, let winner = scored[0].entityID {
                try mention(o, winner, confidence: min(1, 0.5 + (scored[0].score - scored[1].score) / 6), by: "context")
            } else if ambiguous[o.key] != nil {
                ambiguous[o.key]!.count += 1
            } else {
                ambiguous[o.key] = (o, scored, 1)
            }
        }
        for a in ambiguous.values.sorted(by: { $0.o.t < $1.o.t }) {
            try suggestion(meetingID, a.o.segment, a.o.t, .ambiguous, a.o.surface, a.scored, a.count)
            summary.ambiguous += 1
        }
        for c in corrections.values.sorted(by: { $0.t < $1.t }) {
            try suggestion(meetingID, c.segment, c.t, .correction, c.surface, c.targets, c.count)
            summary.corrections += 1
        }
        // First / last seen (for recency and the entity card).
        try run("""
            UPDATE entities SET
                first_seen = min(coalesce(first_seen, 1e18), (SELECT started_at FROM meetings WHERE id = ?1)),
                last_seen = max(coalesce(last_seen, 0), (SELECT started_at FROM meetings WHERE id = ?1))
            WHERE id IN (SELECT entity_id FROM mentions WHERE meeting_id = ?1)
            """, [.integer(meetingID)])
        return summary
    }

    /// Fuzzy candidates: one-word aliases and glossary terms of 4+ characters.
    private func fuzzyKeys(_ entries: [(norm: String, value: AliasTarget, written: String)],
                           glossary: [(id: Int64, term: String, entity: Int64?)],
                           names: [Int64: String], matcher: NameMatcher<AliasTarget>, profile: LanguageProfile) -> [FuzzyKey] {
        var out: [FuzzyKey] = []
        for (norm, target, written) in entries where norm.count >= 4 && !norm.contains(" ") {
            out.append(FuzzyKey(norm: norm, phonetic: profile.phoneticKey(written), entity: target.entity, glossary: nil,
                                label: names[target.entity] ?? norm))
        }
        for g in glossary {
            let n = TextKeys.norm(g.term)
            if n.count >= 4, !n.contains(" "), matcher.values(for: n) == nil {
                out.append(FuzzyKey(norm: n, phonetic: profile.phoneticKey(g.term), entity: g.entity, glossary: g.id, label: g.term))
            }
        }
        return out
    }

    /// Context entries that sound or are spelled like `norm`, `written` as the transcript has it (best first, at most 4).
    private func correctionTargets(_ norm: String, written: String, fuzzy: [FuzzyKey], profile: LanguageProfile) -> [SuggestionCandidate] {
        let phonetic = profile.phoneticKey(written)
        let limit = norm.count >= 7 ? 2 : 1
        var targets: [SuggestionCandidate] = []
        for k in fuzzy where k.norm != norm {
            let samePhonetic = phonetic != nil && k.phonetic == phonetic
            let d = TextKeys.editDistance(norm, k.norm, limit: limit)
            guard samePhonetic || d <= limit else { continue }
            let score = samePhonetic ? 2.0 : 1.0 / Double(max(d, 1))
            if !targets.contains(where: { $0.entityID == k.entity && $0.glossaryID == k.glossary }) {
                targets.append(SuggestionCandidate(entityID: k.entity, glossaryID: k.glossary, label: k.label, score: score))
            }
        }
        return Array(targets.sorted { $0.score > $1.score }.prefix(4))
    }

    /// Candidate score: alias weight (grows with the user's choices) +
    /// attendance or series + graph proximity to what is already resolved
    /// (edges and shared meetings) + recency.
    private func score(_ c: AliasTarget, attendees: Set<Int64>, context: Set<Int64>, meetingID: Int64, now: Double) throws -> Double {
        var s = c.weight
        if attendees.contains(c.entity) { s += 3 }
        if !context.isEmpty {
            let ids = Array(context)
            let edges = try db.query("""
                SELECT COUNT(*) FROM relations
                WHERE (src_kind = 'entity' AND src_id = ?1 AND dst_kind = 'entity' AND dst_id IN (SELECT value FROM json_each(?2)))
                   OR (dst_kind = 'entity' AND dst_id = ?1 AND src_kind = 'entity' AND src_id IN (SELECT value FROM json_each(?3)))
                """, [.integer(c.entity), .ids(ids), .ids(ids)])[0].int(0)
            let shared = try db.query("""
                SELECT COUNT(DISTINCT a.meeting_id) FROM mentions a JOIN mentions b ON b.meeting_id = a.meeting_id
                WHERE a.entity_id = ?1 AND b.entity_id IN (SELECT value FROM json_each(?2)) AND a.meeting_id != ?3
                """, [.integer(c.entity), .ids(ids), .integer(meetingID)])[0].int(0)
            s += 1.5 * Double(min(edges, 2)) + 0.5 * Double(min(shared, 3))
        }
        if let last = try db.query("SELECT last_seen FROM entities WHERE id = ?", [.integer(c.entity)]).first?.optionalDouble(0) {
            let days = (now - last) / 86_400
            s += days < 30 ? 0.5 : days < 90 ? 0.25 : 0
        }
        return s
    }

    private func suggestion(_ meetingID: Int64, _ segment: Int64, _ t: Double, _ kind: Suggestion.Kind, _ surface: String,
                            _ candidates: [SuggestionCandidate], _ count: Int) throws {
        let json = try SuggestionPayload(c: candidates, n: count).json()
        try run("INSERT INTO suggestions(meeting_id, segment_id, t, kind, surface, candidates) VALUES (?, ?, ?, ?, ?, ?)",
                [.integer(meetingID), .integer(segment), .real(t), .text(kind.rawValue), .text(surface), .text(json)])
    }

    // MARK: Graph queries

    /// Where an entity is named: meeting + time + sentence (newest first).
    public func refs(_ entityID: Int64, limit: Int = 200) throws -> [MentionRef] {
        try db.query("""
            SELECT \(Self.meetingColumns(alias: "mt")), m.id, m.segment_id, m.t, m.surface, s.text, m.resolved_by, s.speaker, \(Self.speakerColumns)
            FROM mentions m JOIN meetings mt ON mt.id = m.meeting_id LEFT JOIN segments s ON s.id = m.segment_id \(Self.speakerJoins)
            WHERE m.entity_id = ? ORDER BY mt.started_at DESC, m.t LIMIT ?
            """, [.integer(entityID), .integer(Int64(limit))]).map { row in
            MentionRef(id: row.int(7), entityID: entityID, meeting: Self.meeting(row, languageAt: 4), segmentID: row.optionalInt(8),
                       t: row.double(9), surface: row.string(10), context: row.optionalString(11), resolvedBy: row.string(12),
                       channel: row.optionalString(13).map { Channel(storedSpeaker: $0) },
                       speaker: Self.speakerTag(row, at: 14))
        }
    }

    /// Meetings where it appears (named or as an attendee), with how many times.
    public func timeline(_ entityID: Int64) throws -> [TimelineEntry] {
        try db.query("""
            SELECT \(Self.meetingColumns(alias: "mt")),
                   (SELECT COUNT(*) FROM mentions m WHERE m.meeting_id = mt.id AND m.entity_id = ?1),
                   (SELECT MIN(t) FROM mentions m WHERE m.meeting_id = mt.id AND m.entity_id = ?1),
                   EXISTS (SELECT 1 FROM meeting_entities me WHERE me.meeting_id = mt.id AND me.entity_id = ?1),
                   mt.id IN (\(Self.spokeMeetings))
            FROM meetings mt
            WHERE mt.id IN (SELECT meeting_id FROM mentions WHERE entity_id = ?1
                            UNION SELECT meeting_id FROM meeting_entities WHERE entity_id = ?1
                            UNION \(Self.spokeMeetings))
            ORDER BY mt.started_at DESC
            """, [.integer(entityID)]).map { row in
            TimelineEntry(meeting: Self.meeting(row, languageAt: 4), mentions: Int(row.int(7)), firstT: row.optionalDouble(8),
                          attended: row.int(9) != 0, spoke: row.int(10) != 0)
        }
    }

    /// Everything connected to a node up to `depth` hops (≤ 3), both ways.
    /// Breadth-first with `WITH RECURSIVE` + UNION: each (node, level) is
    /// visited once, so an A↔B cycle does not loop; the minimum level is kept.
    public func impact(_ node: NodeRef, depth: Int = 2, limit: Int = 300) throws -> [GraphNode] {
        let d = Int64(max(1, min(depth, 3)))
        let rows = try db.query("""
            WITH RECURSIVE walk(kind, id, depth, rel) AS (
                SELECT ?1, ?2, 0, ''
                UNION
                SELECT r.dst_kind, r.dst_id, w.depth + 1, r.rel FROM walk w
                    JOIN relations r ON r.src_kind = w.kind AND r.src_id = w.id WHERE w.depth < ?3
                UNION
                SELECT r.src_kind, r.src_id, w.depth + 1, r.rel FROM walk w
                    JOIN relations r ON r.dst_kind = w.kind AND r.dst_id = w.id WHERE w.depth < ?3
            )
            SELECT kind, id, MIN(depth), rel FROM walk
            WHERE NOT (kind = ?1 AND id = ?2)
            GROUP BY kind, id ORDER BY 3, 1, 2 LIMIT ?4
            """, [.text(node.kind.rawValue), .integer(node.id), .integer(d), .integer(Int64(limit))])
        let refs = rows.map { NodeRef(NodeKind(rawValue: $0.string(0)) ?? .entity, $0.int(1)) }
        let labels = try labels(for: Set(refs))
        return zip(rows, refs).compactMap { row, ref in
            guard let (label, detail) = labels[ref] else { return nil }
            return GraphNode(ref: ref, label: label, detail: detail, depth: Int(row.int(2)),
                             rel: RelationKind(rawValue: row.string(3))?.label ?? row.string(3))
        }
    }
}
