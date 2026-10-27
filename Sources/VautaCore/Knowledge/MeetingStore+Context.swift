// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The user's context (people, projects, clients…) and hand-made relations.
/// Everything lives in the encrypted store; nothing in UserDefaults.
extension MeetingStore {
    // MARK: Entities

    private static let entityColumns = """
        SELECT e.id, e.kind, e.name, e.note, e.email, e.source, e.confirmed, e.last_seen,
               (SELECT group_concat(a.alias, char(31)) FROM aliases a WHERE a.entity_id = e.id),
               (SELECT COUNT(*) FROM mentions m WHERE m.entity_id = e.id),
               e.id IS (SELECT v FROM store_meta WHERE k = 'self_entity')
        """

    /// Live (not merged) entities, optionally of one kind, sorted for display.
    public func entities(_ kind: EntityKind? = nil) throws -> [Entity] {
        try db.query(Self.entityColumns + """
             FROM entities e
            WHERE e.merged_into IS NULL AND (?1 IS NULL OR e.kind = ?1)
            """, [kind.map { .text($0.rawValue) }]).map(Self.entity).sorted(by: Self.displayOrder)
    }

    public func entity(_ id: Int64) throws -> Entity? {
        try db.query(Self.entityColumns + " FROM entities e WHERE e.id = ?", [.integer(id)]).first.map(Self.entity)
    }

    static func entity(_ row: Row) -> Entity {
        let name = row.string(2)
        let nameNorm = TextKeys.norm(name)
        let aliases = (row.optionalString(8) ?? "").split(separator: "\u{1F}").map(String.init)
            .filter { TextKeys.norm($0) != nameNorm }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return Entity(id: row.int(0), kind: EntityKind(rawValue: row.string(1)) ?? .topic, name: name,
                      note: row.optionalString(3), email: row.optionalString(4), source: row.string(5),
                      confirmed: row.int(6) != 0, aliases: aliases,
                      lastSeen: row.optionalDouble(7).map(Date.init(timeIntervalSince1970:)), mentionCount: Int(row.int(9)),
                      isSelf: row.int(10) != 0)
    }

    /// Locale-aware order ("Álvaro" before "Zoe"), unlike SQLite's ASCII-only NOCASE.
    static func displayOrder(_ a: Entity, _ b: Entity) -> Bool {
        a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
    }

    /// Creates or updates an entity. The name is always an alias, except the
    /// self entity's pronoun ("Yo"/"Me" would match every sentence); a real
    /// name the user gives the self entity is an alias like any other.
    /// Aliases missing from the draft are removed; on rename the previous
    /// name stays as an alias so transcripts keep matching it. Saving a
    /// calendar entity confirms it.
    public func setPeopleChangeHandler(_ handler: (@Sendable () -> Void)?) { peopleChangeHandler = handler }

    @discardableResult
    public func saveEntity(_ draft: EntityDraft, source: String = "user") async throws -> Int64 {
        let name = Self.clean(draft.name, max: 200)
        guard !name.isEmpty else { throw KnowledgeError.emptyName }
        let email = Self.clean(draft.email, max: 320).lowercased()
        let note = Self.clean(draft.note, max: 4000)
        if !email.isEmpty, try !db.query("SELECT 1 FROM entities WHERE email = ? AND id IS NOT ?",
                                         [.text(email), draft.id.map { .integer($0) }]).isEmpty {
            throw KnowledgeError.emailInUse(email)
        }
        let isSelf = try draft.id != nil && draft.id == selfEntityID()
        var removedVoiceData = 0
        var namedOnSpeakers = false
        let id: Int64 = try transaction {
            let id: Int64
            var names = [name] + draft.aliases
            if let existing = draft.id {
                guard let old = try db.query("SELECT name FROM entities WHERE id = ?", [.integer(existing)]).first?.string(0) else {
                    throw KnowledgeError.entityGone
                }
                if TextKeys.norm(old) != TextKeys.norm(name) { names.append(old) }
                namedOnSpeakers = try db.query("SELECT 1 FROM meeting_speakers WHERE entity_id = ? LIMIT 1", [.integer(existing)]).first != nil
                // Also drops a "yo" alias left by 0.1.0 on the self entity.
                if isSelf { names.removeAll { Self.isSelfPronoun(TextKeys.norm(Self.clean($0, max: 200))) } }
                try run("UPDATE entities SET kind = ?, name = ?, note = ?, email = ?, confirmed = 1 WHERE id = ?",
                        [.text(draft.kind.rawValue), .text(name), note.isEmpty ? nil : .text(note),
                         email.isEmpty ? nil : .text(email), .integer(existing)])
                let keep = names.map { TextKeys.norm(Self.clean($0, max: 200)) }.filter { !$0.isEmpty }
                try run("DELETE FROM aliases WHERE entity_id = ? AND alias_norm NOT IN (SELECT value FROM json_each(?))",
                        [.integer(existing), .text(Self.json(strings: keep))])
                id = existing
                // Only a person has speakers and voice profiles.
                if draft.kind != .person { removedVoiceData = try dropPersonData(of: existing, unlessPerson: false) }
            } else {
                try run("""
                    INSERT INTO entities(kind, name, note, email, source, confirmed, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, [.text(draft.kind.rawValue), .text(name), note.isEmpty ? nil : .text(note),
                          email.isEmpty ? nil : .text(email), .text(source), .integer(source == "user" ? 1 : 0),
                          .real(Date.now.timeIntervalSince1970)])
                id = db.lastInsertRowID
            }
            var seen = Set<String>()
            for alias in names {
                let surface = Self.clean(alias, max: 200)
                let norm = TextKeys.norm(surface)
                guard !norm.isEmpty, seen.insert(norm).inserted else { continue }
                try addAlias(surface, norm: norm, to: id, source: source)
            }
            return id
        }
        try await commitEdit()
        if removedVoiceData > 0 { try await saveAfterVoiceDataRemoved() }
        // Only a person named on a speaker can change the text of a transcript's chunks or the marks on owners.
        if namedOnSpeakers { peopleChangeHandler?() }
        return id
    }

    /// Voice profiles and speaker names do not belong to an entity that is not a person: removes them
    /// (the speakers return to 'auto'). With `unlessPerson`, only when the entity is not a person.
    /// Returns how many profiles went.
    func dropPersonData(of entity: Int64, unlessPerson: Bool) throws -> Int {
        if unlessPerson, try db.query("SELECT 1 FROM entities WHERE id = ? AND kind = 'person'", [.integer(entity)]).first != nil { return 0 }
        let kept = try deleteKeptVoices(ofPerson: entity)
        try run("UPDATE meeting_speakers SET entity_id = NULL, source = 'auto' WHERE entity_id = ?", [.integer(entity)])
        try run("DELETE FROM voice_profiles WHERE entity_id = ?", [.integer(entity)])
        return db.changes + kept
    }

    /// New alias or, if the entity already has it, keeps it (never lowers its weight).
    func addAlias(_ surface: String, norm: String, to entity: Int64, source: String, weight: Double = 1) throws {
        try run("""
            INSERT INTO aliases(alias_norm, alias, entity_id, source, weight) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(alias_norm, entity_id) DO UPDATE SET weight = max(aliases.weight, excluded.weight)
            """, [.text(norm), .text(surface), .integer(entity), .text(source), .real(weight)])
    }

    /// Deletes the entity and, by cascade, its aliases, mentions and edges,
    /// plus the entities merged into it (they would come back without
    /// aliases otherwise). References kept in JSON (series defaults, the self
    /// entity, open suggestions) are removed too. The text leaves the indexes
    /// at the next compaction.
    public func deleteEntity(_ id: Int64) async throws {
        var namedOnSpeakers = false
        let profiles: Int64 = try transaction {
            let ids = try db.query("SELECT id FROM entities WHERE id = ?1 OR merged_into = ?1", [.integer(id)]).map { $0.int(0) }
            namedOnSpeakers = try db.query("SELECT 1 FROM meeting_speakers WHERE entity_id IN (SELECT value FROM json_each(?)) LIMIT 1",
                                           [.ids(ids)]).first != nil
            var profiles = try db.query("SELECT count(*) FROM voice_profiles WHERE entity_id IN (SELECT value FROM json_each(?))",
                                        [.ids(ids)])[0].int(0)
            // The voice summaries kept in meetings for the speakers named after this person go with them.
            profiles += Int64(try deleteKeptVoices(ofPerson: id))
            for old in ids { try rewriteEntityReferences(old, to: nil) }
            try run("DELETE FROM entities WHERE id = ?1 OR merged_into = ?1", [.integer(id)])
            return profiles
        }
        pendingCompaction = true
        try await commitEdit()
        if profiles > 0 { try await saveAfterVoiceDataRemoved() }
        if namedOnSpeakers { peopleChangeHandler?() }
    }

    /// Merges `source` into `target` (e.g. "Juanma" and "Juan Manuel" are the
    /// same person): aliases, mentions, attendance, tasks, glossary links,
    /// edges and JSON references move to `target` in one transaction;
    /// `source` stays as a redirect. Merging into an already merged entity
    /// merges into the entity it points to, so chains A → B → C never exist.
    public func mergeEntity(_ source: Int64, into target: Int64) async throws {
        var namedOnSpeakers = false
        let removed: Int = try transaction {
            guard let t = try db.query("SELECT coalesce(merged_into, id) FROM entities WHERE id = ?", [.integer(target)]).first?.int(0),
                  try !db.query("SELECT 1 FROM entities WHERE id = ?", [.integer(source)]).isEmpty
            else { throw KnowledgeError.entityGone }
            let s = source
            guard s != t else { return 0 }
            namedOnSpeakers = try db.query("SELECT 1 FROM meeting_speakers WHERE entity_id IN (?, ?) LIMIT 1", [.integer(s), .integer(t)]).first != nil
            try run("UPDATE OR IGNORE aliases SET entity_id = ? WHERE entity_id = ?", [.integer(t), .integer(s)])
            try run("DELETE FROM aliases WHERE entity_id = ?", [.integer(s)])
            try run("UPDATE mentions SET entity_id = ? WHERE entity_id = ?", [.integer(t), .integer(s)])
            try run("UPDATE OR IGNORE meeting_entities SET entity_id = ? WHERE entity_id = ?", [.integer(t), .integer(s)])
            try run("DELETE FROM meeting_entities WHERE entity_id = ?", [.integer(s)])
            try run("UPDATE tasks SET owner_id = ? WHERE owner_id = ?", [.integer(t), .integer(s)])
            // "Not Ana" rejections follow the person they were about.
            try run("UPDATE OR IGNORE speaker_suggestion_rejections SET entity_id = ? WHERE entity_id = ?", [.integer(t), .integer(s)])
            try run("DELETE FROM speaker_suggestion_rejections WHERE entity_id = ?", [.integer(s)])
            // Speakers named after the source, and its voice profiles (at most ten per person), follow it.
            try run("UPDATE meeting_speakers SET entity_id = ? WHERE entity_id = ?", [.integer(t), .integer(s)])
            try run("UPDATE voice_profiles SET entity_id = ? WHERE entity_id = ?", [.integer(t), .integer(s)])
            // The current model's profiles win the cap (the others are unusable anyway); a merge into a non-person keeps
            // no voice data.
            var removed = try trimVoiceProfiles(of: t, preferring: DiarizationModels.embeddingModelID)
            removed += try dropPersonData(of: t, unlessPerson: true)
            try run("UPDATE glossary SET entity_id = ? WHERE entity_id = ?", [.integer(t), .integer(s)])
            // OR IGNORE: duplicates, and edges that would become loops (CHECK), are dropped.
            try run("UPDATE OR IGNORE relations SET src_id = ? WHERE src_kind = 'entity' AND src_id = ?", [.integer(t), .integer(s)])
            try run("UPDATE OR IGNORE relations SET dst_id = ? WHERE dst_kind = 'entity' AND dst_id = ?", [.integer(t), .integer(s)])
            try run("DELETE FROM relations WHERE (src_kind = 'entity' AND src_id = ?1) OR (dst_kind = 'entity' AND dst_id = ?1)", [.integer(s)])
            try rewriteEntityReferences(s, to: t)
            try run("""
                UPDATE entities SET
                    first_seen = (SELECT min(first_seen) FROM entities WHERE id IN (?1, ?2)),
                    last_seen = (SELECT max(last_seen) FROM entities WHERE id IN (?1, ?2)),
                    confirmed = 1
                WHERE id = ?2
                """, [.integer(s), .integer(t)])
            // The email moves to the target (unique index), and earlier merges
            // into the source are redirected.
            let email = try db.query("SELECT email FROM entities WHERE id = ?", [.integer(s)]).first?.optionalString(0)
            try run("UPDATE entities SET merged_into = ?, note = NULL, email = NULL WHERE id = ?", [.integer(t), .integer(s)])
            if let email {
                try run("UPDATE entities SET email = coalesce(email, ?) WHERE id = ?", [.text(email), .integer(t)])
            }
            try run("UPDATE entities SET merged_into = ? WHERE merged_into = ?", [.integer(t), .integer(s)])
            return removed
        }
        pendingCompaction = true
        try await commitEdit()
        if removed > 0 { try await saveAfterVoiceDataRemoved() }
        if namedOnSpeakers { peopleChangeHandler?() }
    }

    /// Entity IDs stored inside JSON or key-value rows, which foreign keys
    /// cannot follow: series default entities, the self entity and the
    /// candidates of open suggestions. `new == nil` removes the reference.
    func rewriteEntityReferences(_ old: Int64, to new: Int64?) throws {
        try run("""
            UPDATE series SET default_entities = (
                SELECT json_group_array(v) FROM (
                    SELECT CASE WHEN value = ?1 THEN ?2 ELSE value END AS v, MIN(key) AS k
                    FROM json_each(series.default_entities) GROUP BY v HAVING v IS NOT NULL ORDER BY k))
            WHERE EXISTS (SELECT 1 FROM json_each(series.default_entities) WHERE value = ?1)
            """, [.integer(old), new.map { .integer($0) }])
        if let new {
            try run("UPDATE store_meta SET v = ? WHERE k = 'self_entity' AND v = ?", [.integer(new), .integer(old)])
        } else {
            try run("DELETE FROM store_meta WHERE k = 'self_entity' AND v = ?", [.integer(old)])
        }
        let newLabel = try new.flatMap { try db.query("SELECT name FROM entities WHERE id = ?", [.integer($0)]).first?.string(0) }
        for row in try db.query("""
            SELECT id, candidates FROM suggestions WHERE status = 'open'
               AND EXISTS (SELECT 1 FROM json_each(candidates, '$.c') WHERE json_extract(value, '$.entityID') = ?)
            """, [.integer(old)]) {
            guard var payload = try? JSONDecoder().decode(SuggestionPayload.self, from: Data(row.string(1).utf8)) else { continue }
            var out: [SuggestionCandidate] = []
            for var c in payload.c {
                if c.entityID == old {
                    guard new != nil || c.glossaryID != nil else { continue }
                    let label = new != nil && c.glossaryID == nil ? newLabel ?? c.label : c.label
                    c = SuggestionCandidate(entityID: new, glossaryID: c.glossaryID, label: label, score: c.score)
                }
                // Merging can turn two candidates into the same one: keep the best score.
                if let i = out.firstIndex(where: { $0.entityID == c.entityID && $0.glossaryID == c.glossaryID }) {
                    if out[i].score < c.score { out[i] = c }
                } else {
                    out.append(c)
                }
            }
            if out.isEmpty {
                try run("DELETE FROM suggestions WHERE id = ?", [.integer(row.int(0))])
            } else {
                payload.c = out
                try run("UPDATE suggestions SET candidates = ? WHERE id = ?", [.text(try payload.json()), .integer(row.int(0))])
            }
        }
    }

    // MARK: Entities of a meeting

    public enum MeetingRole: String, Sendable { case attendee, others, topic }

    public func meetingEntities(_ meetingID: Int64, role: MeetingRole? = nil) throws -> [Entity] {
        try db.query(Self.entityColumns + """
             FROM meeting_entities me JOIN entities e ON e.id = me.entity_id
            WHERE me.meeting_id = ?1 AND (?2 IS NULL OR me.role = ?2)
            GROUP BY e.id
            """, [.integer(meetingID), role.map { .text($0.rawValue) }]).map(Self.entity).sorted(by: Self.displayOrder)
    }

    /// Replaces the entities of one role in the meeting (attendees, who
    /// "Others" is, topics). They are context for resolving ambiguous names.
    public func setMeetingEntities(_ meetingID: Int64, role: MeetingRole, _ ids: [Int64]) async throws {
        try transaction {
            try run("DELETE FROM meeting_entities WHERE meeting_id = ? AND role = ?", [.integer(meetingID), .text(role.rawValue)])
            try run("INSERT OR IGNORE INTO meeting_entities(meeting_id, entity_id, role) SELECT ?, value, ? FROM json_each(?)",
                    [.integer(meetingID), .text(role.rawValue), .ids(Array(Set(ids)))])
        }
        try await commitEdit()
    }

    // MARK: Hand-made relations

    public func relations(of node: NodeRef) throws -> [RelationInfo] {
        let rows = try db.query("""
            SELECT id, src_kind, src_id, rel, dst_kind, dst_id FROM relations
            WHERE (src_kind = ?1 AND src_id = ?2) OR (dst_kind = ?1 AND dst_id = ?2)
            ORDER BY rel, id
            """, [.text(node.kind.rawValue), .integer(node.id)])
        let refs = rows.flatMap { [NodeRef(NodeKind(rawValue: $0.string(1)) ?? .entity, $0.int(2)),
                                   NodeRef(NodeKind(rawValue: $0.string(4)) ?? .entity, $0.int(5))] }
        let labels = try labels(for: Set(refs))
        return rows.map { row in
            let src = NodeRef(NodeKind(rawValue: row.string(1)) ?? .entity, row.int(2))
            let dst = NodeRef(NodeKind(rawValue: row.string(4)) ?? .entity, row.int(5))
            return RelationInfo(id: row.int(0), src: src, rel: row.string(3), dst: dst,
                                srcLabel: labels[src]?.0 ?? "—", dstLabel: labels[dst]?.0 ?? "—")
        }
    }

    public func addRelation(_ src: NodeRef, _ rel: RelationKind, _ dst: NodeRef, meetingID: Int64? = nil, source: String = "user") async throws {
        guard src != dst else { throw KnowledgeError.relationNeedsTwoNodes }
        try run("""
            INSERT OR IGNORE INTO relations(src_kind, src_id, rel, dst_kind, dst_id, meeting_id, source)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, [.text(src.kind.rawValue), .integer(src.id), .text(rel.rawValue), .text(dst.kind.rawValue), .integer(dst.id),
                  meetingID.map { .integer($0) }, .text(source)])
        try await commitEdit()
    }

    public func deleteRelation(_ id: Int64) async throws {
        try run("DELETE FROM relations WHERE id = ?", [.integer(id)])
        try await commitEdit()
    }

    // MARK: Name search

    /// Autocomplete: trigram search (≥ 3 letters, accent-insensitive, anywhere
    /// in the name) or alias prefix when shorter.
    public func searchNames(_ text: String, limit: Int = 12) throws -> [NameHit] {
        let n = TextKeys.norm(text)
        guard !n.isEmpty else { return [] }
        let selfID = try selfEntityID()
        var hits: [NameHit] = []
        var seen = Set<NameHit.Target>()
        func add(_ target: NameHit.Target, _ text: String, _ detail: String) {
            if seen.insert(target).inserted { hits.append(NameHit(target: target, text: text, detail: detail)) }
        }
        func entityName(_ id: Int64, _ name: String) -> String { Self.displayName(name, isSelf: id == selfID) }
        if n.count >= 3 {
            // A quoted phrase: user input is never parsed as FTS5 syntax.
            let match = "\"" + text.replacingOccurrences(of: "\"", with: " ").trimmingCharacters(in: .whitespaces) + "\""
            for row in try db.query("""
                SELECT f.rowid,
                       CASE f.rowid % 2 WHEN 0 THEN (SELECT e.name FROM aliases a JOIN entities e ON e.id = a.entity_id WHERE a.id = f.rowid / 2)
                                        ELSE (SELECT term FROM glossary WHERE id = f.rowid / 2) END,
                       CASE f.rowid % 2 WHEN 0 THEN (SELECT e.kind FROM aliases a JOIN entities e ON e.id = a.entity_id WHERE a.id = f.rowid / 2)
                                        ELSE 'glossary' END,
                       CASE f.rowid % 2 WHEN 0 THEN (SELECT coalesce(e.merged_into, e.id) FROM aliases a JOIN entities e ON e.id = a.entity_id WHERE a.id = f.rowid / 2)
                                        ELSE f.rowid / 2 END
                FROM names_fts f WHERE names_fts MATCH ? ORDER BY rank LIMIT ?
                """, [.text(match), .integer(Int64(limit * 2))]) {
                guard let label = row.optionalString(1) else { continue }
                let kind = row.string(2)
                if kind == "glossary" {
                    add(.glossary(row.int(3)), label, String(localized: "Glossary", comment: "Detail of a name search hit that is a glossary term"))
                } else {
                    add(.entity(row.int(3)), entityName(row.int(3), label), EntityKind(rawValue: kind)?.label ?? kind)
                }
            }
        } else {
            for row in try db.query("""
                SELECT DISTINCT coalesce(e.merged_into, e.id), e.name, e.kind FROM aliases a JOIN entities e ON e.id = a.entity_id
                WHERE a.alias_norm >= ?1 AND a.alias_norm < ?1 || char(1114111) LIMIT ?2
                """, [.text(n), .integer(Int64(limit))]) {
                add(.entity(row.int(0)), entityName(row.int(0), row.string(1)), EntityKind(rawValue: row.string(2))?.label ?? "")
            }
        }
        return Array(hits.prefix(limit))
    }

    // MARK: Utilities

    /// Label and localized detail of several nodes, one query per kind.
    func labels(for refs: Set<NodeRef>) throws -> [NodeRef: (String, String)] {
        var out: [NodeRef: (String, String)] = [:]
        let byKind = Dictionary(grouping: refs, by: \.kind).mapValues { $0.map(\.id) }
        if let ids = byKind[.entity] {
            let selfID = try selfEntityID()
            for r in try db.query("SELECT id, name, kind FROM entities WHERE id IN (SELECT value FROM json_each(?))", [.ids(ids)]) {
                out[NodeRef(.entity, r.int(0))] = (Self.displayName(r.string(1), isSelf: r.int(0) == selfID),
                                                    EntityKind(rawValue: r.string(2))?.label ?? "")
            }
        }
        if let ids = byKind[.decision] {
            for r in try db.query("SELECT id, text FROM decisions WHERE id IN (SELECT value FROM json_each(?))", [.ids(ids)]) {
                out[NodeRef(.decision, r.int(0))] = (r.string(1), String(localized: "Decision", comment: "Graph node detail: a meeting decision"))
            }
        }
        if let ids = byKind[.task] {
            for r in try db.query("SELECT id, text, status FROM tasks WHERE id IN (SELECT value FROM json_each(?))", [.ids(ids)]) {
                out[NodeRef(.task, r.int(0))] = (r.string(1), r.string(2) == "open"
                    ? String(localized: "Open task", comment: "Graph node detail: a task not done yet")
                    : String(localized: "Closed task", comment: "Graph node detail: a task done or dropped"))
            }
        }
        if let ids = byKind[.meeting] {
            for r in try db.query("SELECT \(Self.meetingColumns) FROM meetings WHERE id IN (SELECT value FROM json_each(?))", [.ids(ids)]) {
                let m = Self.meeting(r, languageAt: 4)
                out[NodeRef(.meeting, m.id)] = (m.displayTitle, m.startedAt.formatted(date: .abbreviated, time: .omitted))
            }
        }
        return out
    }

    /// User text, trimmed and capped, without control characters (Cc, except
    /// newline and tab) or bidi embeddings/overrides/isolates. Format
    /// characters that carry meaning (ZWJ, ZWNJ, LRM/RLM) are kept: they are
    /// part of Persian and Indic words and of emoji sequences.
    static func clean(_ text: String, max: Int) -> String {
        let scalars = text.unicodeScalars.filter { s in
            if s == "\n" || s == "\t" { return true }
            if s.properties.generalCategory == .control { return false }
            return !(0x202A...0x202E).contains(s.value) && !(0x2066...0x2069).contains(s.value)
        }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines).prefix(max).description
    }

    static func optionalText(_ text: String, max: Int) -> SQLiteValue? {
        let c = clean(text, max: max)
        return c.isEmpty ? nil : .text(c)
    }

    static func json(ids: [Int64]) -> String { "[" + ids.map(String.init).joined(separator: ",") + "]" }

    static func json(strings: [String]) -> String {
        String(decoding: (try? JSONEncoder().encode(strings)) ?? Data("[]".utf8), as: UTF8.self)
    }

    static func ids(fromJSON json: String) -> [Int64] {
        (try? JSONDecoder().decode([Int64].self, from: Data(json.utf8))) ?? []
    }
}
