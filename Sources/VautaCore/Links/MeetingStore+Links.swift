// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What a link pass reads: the items of one meeting, the eligible items of the meetings before it, and what the person already decided.
struct LinkInputs: Sendable {
    var meetingID: Int64
    var sources: [LinkItem]
    var pool: [LinkItem]
    var exclusions: LinkExclusions
}

/// Reading the store for the link pass, the item vectors and the suggestions it writes. Nothing here calls a model.
extension MeetingStore {
    // MARK: Gathering

    /// The inputs of a pass over `meetingID`. nil when the meeting does not exist.
    func linkInputs(meetingID: Int64, policy: LinkPolicy) throws -> LinkInputs? {
        guard let start = try db.query("SELECT started_at FROM meetings WHERE id = ?", [.integer(meetingID)]).first?.double(0) else { return nil }
        let rows = try db.query("""
            SELECT \(Self.meetingColumns), series_id FROM meetings
            WHERE id = ?1 OR (started_at < ?2 AND started_at >= ?3)
            """, [.integer(meetingID), .real(start), .real(start - policy.window)])
        var meetings: [Int64: (meeting: Meeting, series: Int64?)] = [:]
        for row in rows {
            let meeting = Self.meeting(row, languageAt: 4)
            meetings[meeting.id] = (meeting, row.optionalInt(7))
        }
        let ids = Array(meetings.keys)
        let selfID = try selfEntityID()
        var people: [Int64: Set<Int64>] = [:]
        for row in try db.query("""
            SELECT meeting_id, entity_id FROM meeting_entities WHERE role = 'attendee' AND meeting_id IN (SELECT value FROM json_each(?1))
            UNION
            SELECT meeting_id, entity_id FROM meeting_speakers WHERE entity_id IS NOT NULL AND meeting_id IN (SELECT value FROM json_each(?1))
            """, [.ids(ids)]) where row.int(1) != selfID {
            people[row.int(0), default: []].insert(row.int(1))
        }
        var projects: [String: Set<Int64>] = [:]
        for row in try db.query("""
            SELECT r.src_kind, r.src_id, r.dst_id FROM relations r JOIN entities e ON e.id = r.dst_id AND e.kind IN ('project','client')
            WHERE r.rel = 'about' AND r.dst_kind = 'entity' AND r.src_kind IN ('task','decision') AND r.meeting_id IN (SELECT value FROM json_each(?))
            """, [.ids(ids)]) {
            projects["\(row.string(0))|\(row.int(1))", default: []].insert(row.int(2))
        }
        var languages: [String: String] = [:]
        func make(_ id: Int64, _ kind: LinkKind, _ meetingID: Int64, _ text: String, segment: Int64?, t: Double?, unconfirmed: Bool, reason: String?, source: String) -> LinkItem? {
            guard let entry = meetings[meetingID], policy.isEligible(unconfirmed: unconfirmed, reason: reason) else { return nil }
            let locale = entry.meeting.minutesLocale
            let language = languages[locale.identifier + "|" + text] ?? LinkText.language(of: text, fallback: locale)
            languages[locale.identifier + "|" + text] = language
            var item = LinkItem(id: id, kind: kind, meetingID: meetingID, startedAt: entry.meeting.startedAt, text: text, language: language, locale: locale.identifier)
            item.segmentID = segment
            item.t = t
            item.seriesID = entry.series
            item.people = people[meetingID] ?? []
            item.projects = projects["\(kind.rawValue)|\(id)"] ?? []
            item.unconfirmed = unconfirmed
            item.unconfirmedReason = reason
            item.source = source
            return item
        }
        var sources: [LinkItem] = [], pool: [LinkItem] = []
        func add(_ item: LinkItem?) {
            guard let item else { return }
            if item.meetingID == meetingID { sources.append(item) } else { pool.append(item) }
        }
        for r in try db.query("""
            SELECT id, meeting_id, segment_id, t, text, unconfirmed, unconfirmed_reason, source FROM decisions WHERE meeting_id IN (SELECT value FROM json_each(?))
            """, [.ids(ids)]) {
            add(make(r.int(0), .decision, r.int(1), r.string(4), segment: r.optionalInt(2), t: r.optionalDouble(3), unconfirmed: r.int(5) != 0,
                     reason: r.optionalString(6), source: r.string(7)))
        }
        for r in try db.query("""
            SELECT id, meeting_id, segment_id, t, text, owner_id, due_day, status, unconfirmed, unconfirmed_reason, source FROM tasks
            WHERE meeting_id IN (SELECT value FROM json_each(?))
            """, [.ids(ids)]) {
            var item = make(r.int(0), .task, r.int(1), r.string(4), segment: r.optionalInt(2), t: r.optionalDouble(3), unconfirmed: r.int(8) != 0,
                            reason: r.optionalString(9), source: r.string(10))
            item?.ownerID = r.optionalInt(5)
            item?.dueDay = r.optionalString(6).flatMap { DueDay($0) }
            item?.status = TaskItem.Status(rawValue: r.string(7)) ?? .open
            // Only an open task asks for a link; a done one can still be what a new task repeats.
            if item?.meetingID == meetingID, item?.status != .open { item = nil }
            add(item)
        }
        var exclusions = LinkExclusions()
        for r in try db.query("SELECT kind, src_id, dst_id, rel, state FROM item_links WHERE state IN ('confirmed','dismissed')") {
            guard let kind = LinkKind(rawValue: r.string(0)) else { continue }
            exclusions.decidedPairs.insert(LinkExclusions.pair(kind, r.int(1), r.int(2)))
            if r.string(4) == "confirmed" { exclusions.linkedSources.insert(LinkExclusions.item(kind, r.int(1))) }
        }
        for kind in LinkKind.allCases {
            for group in try sameGroups(kind) {
                let meetings = Set(group.members.map(\.meeting))
                for member in group.members { exclusions.chainMeetings[LinkExclusions.item(kind, member.id)] = meetings }
                // The earlier end of a confirmed link sits behind its newer end from that meeting on.
                for edge in group.edges {
                    guard let newer = group.members.first(where: { $0.id == edge.src }) else { continue }
                    let key = LinkExclusions.item(kind, edge.dst)
                    exclusions.superseded[key] = min(exclusions.superseded[key] ?? newer.start, newer.start)
                }
            }
        }
        for r in try db.query("SELECT kind, src_meeting_id, src_key, dst_meeting_id, dst_key FROM item_link_dismissals WHERE src_meeting_id = ?", [.integer(meetingID)]) {
            guard let kind = LinkKind(rawValue: r.string(0)) else { continue }
            exclusions.dismissedKeys.insert(LinkExclusions.dismissal(kind, srcMeeting: r.int(1), srcKey: r.string(2), dstMeeting: r.int(3), dstKey: r.string(4)))
        }
        return LinkInputs(meetingID: meetingID, sources: sources, pool: pool, exclusions: exclusions)
    }

    // MARK: Chains of confirmed links

    /// A connected group of items joined by confirmed "same" links: its members with their meetings and the links between them.
    struct SameGroup {
        var members: [(id: Int64, meeting: Int64, start: Date)]
        var edges: [(src: Int64, dst: Int64)]
    }

    /// The groups of confirmed "same" links of one kind, optionally with one more link counted (a confirmation about to be made).
    func sameGroups(_ kind: LinkKind, adding extra: (src: Int64, dst: Int64)? = nil) throws -> [SameGroup] {
        var edges = try db.query("SELECT src_id, dst_id FROM item_links WHERE kind = ? AND state = 'confirmed' AND rel = 'same'", [.text(kind.rawValue)])
            .map { (src: $0.int(0), dst: $0.int(1)) }
        if let extra { edges.append(extra) }
        guard !edges.isEmpty else { return [] }
        let table = kind == .task ? "tasks" : "decisions"
        let ids = Array(Set(edges.flatMap { [$0.src, $0.dst] }))
        var info: [Int64: (meeting: Int64, start: Date)] = [:]
        for r in try db.query("""
            SELECT x.id, x.meeting_id, m.started_at FROM \(table) x JOIN meetings m ON m.id = x.meeting_id WHERE x.id IN (SELECT value FROM json_each(?))
            """, [.ids(ids)]) {
            info[r.int(0)] = (r.int(1), Date(timeIntervalSince1970: r.double(2)))
        }
        var parent: [Int64: Int64] = [:]
        func find(_ x: Int64) -> Int64 {
            var root = x
            while let p = parent[root], p != root { root = p }
            return root
        }
        let known = edges.filter { info[$0.src] != nil && info[$0.dst] != nil }
        for e in known {
            parent[e.src] = parent[e.src] ?? e.src
            parent[e.dst] = parent[e.dst] ?? e.dst
            let (a, b) = (find(e.src), find(e.dst))
            if a != b { parent[a] = b }
        }
        var groups: [Int64: SameGroup] = [:]
        for id in parent.keys.sorted() {
            guard let i = info[id] else { continue }
            groups[find(id), default: SameGroup(members: [], edges: [])].members.append((id, i.meeting, i.start))
        }
        for e in known { groups[find(e.src)]?.edges.append(e) }
        return Array(groups.values)
    }

    // MARK: Item vectors

    /// The vectors of the items of `inputs` in the search model's space.
    func linkVectors(for inputs: LinkInputs, model: String) throws -> [String: LinkVector] {
        var out: [String: LinkVector] = [:]
        let meetingIDs = Array(Set((inputs.sources + inputs.pool).map(\.meetingID)))
        for kind in LinkKind.allCases {
            let table = kind == .task ? "tasks" : "decisions"
            for r in try db.query("""
                SELECT item_id, scale, emb FROM item_vectors WHERE kind = ?1 AND model = ?2 AND recipe = ?3
                  AND item_id IN (SELECT id FROM \(table) WHERE meeting_id IN (SELECT value FROM json_each(?4)))
                """, [.text(kind.rawValue), .text(model), .integer(Int64(LinkPolicy.vectorRecipe)), .ids(meetingIDs)]) {
                if let v = LinkVector(q: r.data(2), scale: Float(r.double(1))) { out[LinkExclusions.item(kind, r.int(0))] = v }
            }
        }
        return out
    }

    /// Eligible items that lack a vector in `model`'s space: the meeting's own, then up to `earlier` items of earlier meetings in the window
    /// (newest first). Ranked-out items and tasks with no meeting are not embedded.
    func itemsWithoutVectors(meetingID: Int64, model: String, earlier: Int = 300, policy: LinkPolicy = LinkPolicy()) throws -> [(kind: LinkKind, id: Int64, text: String)] {
        guard let inputs = try linkInputs(meetingID: meetingID, policy: policy) else { return [] }
        let have = try linkVectorKeys(model: model)
        func missing(_ items: [LinkItem]) -> [(kind: LinkKind, id: Int64, text: String)] {
            items.filter { !have.contains(LinkExclusions.item($0.kind, $0.id)) && $0.status != .dropped }.map { ($0.kind, $0.id, $0.text) }
        }
        let newest = inputs.pool.sorted { ($0.startedAt, $0.id) > ($1.startedAt, $1.id) }
        return missing(inputs.sources) + Array(missing(newest).prefix(earlier))
    }

    private func linkVectorKeys(model: String) throws -> Set<String> {
        Set(try db.query("SELECT kind, item_id FROM item_vectors WHERE model = ? AND recipe = ?", [.text(model), .integer(Int64(LinkPolicy.vectorRecipe))])
            .compactMap { r in LinkKind(rawValue: r.string(0)).map { LinkExclusions.item($0, r.int(1)) } })
    }

    func storeItemVectors(_ rows: [(kind: LinkKind, id: Int64, q: Data, scale: Float)], model: String) async throws {
        guard !rows.isEmpty else { return }
        try transaction {
            for r in rows {
                try run("""
                    INSERT OR REPLACE INTO item_vectors(kind, item_id, model, dims, scale, recipe, emb) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, [.text(r.kind.rawValue), .integer(r.id), .text(model), .integer(Int64(r.q.count)), .real(Double(r.scale)),
                          .integer(Int64(LinkPolicy.vectorRecipe)), .blob(r.q)])
            }
        }
        try await commitEdit()
    }

    /// The search model was removed: its vectors go, the links stay.
    func dropItemVectors(modelPrefix: String) async throws {
        try run("DELETE FROM item_vectors WHERE model LIKE ? || '%'", [.text(modelPrefix)])
        try await commitEdit()
    }

    // MARK: Writing the pass

    /// Replaces the meeting's `suggested` rows with `proposals`, never a row the person decided. A suggestion the new pass makes again keeps its
    /// row (and its id: a click on the screen still finds it); a suggestion the person restored stays, and counts against the caps. Records the
    /// recipe that ran.
    func replaceSuggestions(meetingID: Int64, proposals: [LinkProposal], recipe: Int = LinkPolicy.recipe, markRecipe: Bool = true,
                            perMeeting: Int = LinkPolicy().perMeeting) async throws {
        let now = Date.now.timeIntervalSince1970
        try transaction {
            let existing = try db.query("""
                SELECT id, kind, src_id, dst_id, decided_at IS NOT NULL FROM item_links WHERE state = 'suggested' AND (
                    (kind = 'task' AND src_id IN (SELECT id FROM tasks WHERE meeting_id = ?1)) OR
                    (kind = 'decision' AND src_id IN (SELECT id FROM decisions WHERE meeting_id = ?1)))
                """, [.integer(meetingID)])
            let restored = existing.filter { $0.int(4) != 0 }
            let restoredSources = Set(restored.map { "\($0.string(1))|\($0.int(2))" })
            var keep = Set(restored.map { $0.int(0) })
            var room = perMeeting - restored.count
            for p in proposals where room > 0 && !restoredSources.contains("\(p.kind.rawValue)|\(p.srcID)") {
                room -= 1
                let evidence: SQLiteValue? = p.evidence?.json.map { .text($0) }
                if let row = existing.first(where: { $0.int(4) == 0 && $0.string(1) == p.kind.rawValue && $0.int(2) == p.srcID && $0.int(3) == p.dstID }) {
                    try run("UPDATE item_links SET rel = ?, method = ?, score = ?, evidence = ?, recipe = ? WHERE id = ?",
                            [.text(p.relation.rawValue), .text(p.method.rawValue), .real(p.score), evidence, .integer(Int64(recipe)), .integer(row.int(0))])
                    keep.insert(row.int(0))
                } else {
                    try run("""
                        INSERT OR IGNORE INTO item_links(kind, src_id, dst_id, rel, state, method, score, evidence, recipe, created_at)
                        VALUES (?, ?, ?, ?, 'suggested', ?, ?, ?, ?, ?)
                        """, [.text(p.kind.rawValue), .integer(p.srcID), .integer(p.dstID), .text(p.relation.rawValue), .text(p.method.rawValue),
                              .real(p.score), evidence, .integer(Int64(recipe)), .real(now)])
                }
            }
            for row in existing where !keep.contains(row.int(0)) { try run("DELETE FROM item_links WHERE id = ?", [.integer(row.int(0))]) }
            if markRecipe { try run("UPDATE meetings SET links_recipe = ? WHERE id = ?", [.integer(Int64(recipe)), .integer(meetingID)]) }
        }
        try await commitEdit()
    }

    /// Meetings of the last `days` whose pass ran with an older recipe (a recipe bump runs them again).
    func meetingsNeedingLinks(recipe: Int = LinkPolicy.recipe, days: Int = 180, now: Date = .now) throws -> [Int64] {
        try db.query("""
            SELECT id FROM meetings WHERE ended_at IS NOT NULL AND links_recipe < ? AND started_at >= ? ORDER BY started_at
            """, [.integer(Int64(recipe)), .real(now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970)]).map { $0.int(0) }
    }

    /// Whether the meeting's minutes were written (its card exists): a meeting with minutes and no items has been through its pass.
    func minutesWritten(_ meetingID: Int64) throws -> Bool {
        try db.query("SELECT card IS NOT NULL FROM meetings WHERE id = ?", [.integer(meetingID)]).first?.int(0) == 1
    }

    func linksRecipe(_ meetingID: Int64) throws -> Int {
        Int(try db.query("SELECT links_recipe FROM meetings WHERE id = ?", [.integer(meetingID)]).first?.int(0) ?? 0)
    }

    /// Meetings after `meetingID`, within the window, that have a suggestion pointing into an item of `meetingID` that the minutes' rewrite
    /// is about to delete (the model's items, and its open tasks). Called before the rewrite; the passes of these meetings run again after.
    func meetingsPointingIntoRewrite(of meetingID: Int64) throws -> [Int64] {
        Array(Set(try db.query("""
            SELECT DISTINCT d.meeting_id FROM item_links l JOIN decisions d ON l.kind = 'decision' AND d.id = l.src_id
             WHERE l.state = 'suggested' AND l.dst_id IN (SELECT id FROM decisions WHERE meeting_id = ?1 AND source = 'llm')
            UNION
            SELECT DISTINCT t.meeting_id FROM item_links l JOIN tasks t ON l.kind = 'task' AND t.id = l.src_id
             WHERE l.state = 'suggested' AND l.dst_id IN (SELECT id FROM tasks WHERE meeting_id = ?1 AND source = 'llm' AND status = 'open')
            """, [.integer(meetingID)]).compactMap { $0.optionalInt(0) }))
    }
}
