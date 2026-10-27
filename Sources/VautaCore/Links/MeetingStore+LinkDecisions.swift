// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What the person does with a link (confirm, dismiss, restore, undo) and how links are read back for the screens.
extension MeetingStore {
    private static let linkColumns = "id, kind, src_id, dst_id, rel, state, method, score, evidence, recipe, created_at, decided_at"

    private static func link(_ r: Row) -> StoredLink? {
        guard let kind = LinkKind(rawValue: r.string(1)), let rel = LinkRelation(rawValue: r.string(4)), let state = LinkState(rawValue: r.string(5)),
              let method = LinkMethod(rawValue: r.string(6)) else { return nil }
        return StoredLink(id: r.int(0), kind: kind, srcID: r.int(2), dstID: r.int(3), relation: rel, state: state, method: method, score: r.optionalDouble(7),
                          evidence: LinkEvidence(json: r.optionalString(8)), recipe: Int(r.int(9)), createdAt: Date(timeIntervalSince1970: r.double(10)),
                          decidedAt: r.optionalDouble(11).map(Date.init(timeIntervalSince1970:)))
    }

    public func itemLink(_ id: Int64) throws -> StoredLink? {
        try db.query("SELECT \(Self.linkColumns) FROM item_links WHERE id = ?", [.integer(id)]).compactMap(Self.link).first
    }

    /// How many suggestions wait under each task, by task id (at most one each, D17): the "1 suggestion" link on that task's row in Tasks mode.
    public func pendingTaskLinkCounts() throws -> [Int64: Int] {
        var out: [Int64: Int] = [:]
        for r in try db.query("""
            SELECT l.src_id, count(*) FROM item_links l JOIN tasks t ON t.id = l.src_id
            WHERE l.kind = 'task' AND l.state = 'suggested' AND t.meeting_id IS NOT NULL GROUP BY l.src_id
            """) { out[r.int(0)] = Int(r.int(1)) }
        return out
    }

    /// Every link row of the meeting's items as the newer end (suggested and confirmed; dismissed ones are listed apart).
    public func links(ofMeeting meetingID: Int64) throws -> [StoredLink] {
        try db.query("""
            SELECT \(Self.linkColumns) FROM item_links
            WHERE state IN ('suggested','confirmed') AND (
                (kind = 'task' AND src_id IN (SELECT id FROM tasks WHERE meeting_id = ?1)) OR
                (kind = 'decision' AND src_id IN (SELECT id FROM decisions WHERE meeting_id = ?1)))
            ORDER BY id
            """, [.integer(meetingID)]).compactMap(Self.link)
    }

    /// The suggestions and confirmed links of a meeting with the earlier item and its meeting, ready to show. An earlier item that is doubted
    /// carries its mark. Keyed by the newer item.
    public func linkRows(ofMeeting meetingID: Int64) throws -> [LinkRowKey: LinkRow] {
        var out: [LinkRowKey: LinkRow] = [:]
        for link in try links(ofMeeting: meetingID) {
            guard let row = try linkRow(for: link) else { continue }
            out[LinkRowKey(kind: link.kind, itemID: link.srcID)] = row
        }
        return out
    }

    func linkRow(for link: StoredLink) throws -> LinkRow? {
        let sql: String
        switch link.kind {
        case .task:
            sql = """
                SELECT x.meeting_id, x.text, x.segment_id, x.t, m.title, m.started_at, e.name, x.due_day, x.status, x.unconfirmed, x.unconfirmed_reason,
                       x.owner_id IS (SELECT v FROM store_meta WHERE k = 'self_entity')
                FROM tasks x JOIN meetings m ON m.id = x.meeting_id LEFT JOIN entities e ON e.id = x.owner_id WHERE x.id = ?
                """
        case .decision:
            sql = """
                SELECT x.meeting_id, x.text, x.segment_id, x.t, m.title, m.started_at, NULL, NULL, NULL, x.unconfirmed, x.unconfirmed_reason, 0
                FROM decisions x JOIN meetings m ON m.id = x.meeting_id WHERE x.id = ?
                """
        }
        guard let r = try db.query(sql, [.integer(link.dstID)]).first else { return nil }
        let date = Date(timeIntervalSince1970: r.double(5))
        var newerDue: DueDay?
        if link.kind == .task {
            newerDue = try db.query("SELECT due_day FROM tasks WHERE id = ?", [.integer(link.srcID)]).first?.optionalString(0).flatMap { DueDay($0) }
        }
        var out = LinkRow(link: link, earlierText: r.string(1), earlierMeetingID: r.int(0), earlierMeetingTitle: Meeting.displayTitle(r.optionalString(4), startedAt: date),
                       earlierMeetingDate: date, earlierSegmentID: r.optionalInt(2), earlierT: r.optionalDouble(3),
                       earlierOwner: r.optionalString(6).map { Self.displayName($0, isSelf: r.int(11) != 0) },
                       earlierDueDay: r.optionalString(7).flatMap { DueDay($0) }, earlierStatus: r.optionalString(8).flatMap { TaskItem.Status(rawValue: $0) },
                       earlierUnconfirmed: r.int(9) != 0, earlierUnconfirmedReason: r.optionalString(10))
        out.newerDueDay = newerDue
        return out
    }

    // MARK: Deciding

    /// "Same task", "Same decision", "Yes, it changed": the link becomes a fact, and both items become the person's, so rewriting the minutes
    /// of either meeting keeps them. The items' own "Unconfirmed" marks stay: confirming a link is not checking an item. What the items were
    /// before (their source, text and mark) is kept on the link, so Undo gives it back.
    @discardableResult
    public func confirmLink(_ id: Int64) async throws -> Bool {
        try await confirmLinkOutcome(id) == .confirmed
    }

    /// `confirmLink` with the reason when nothing was confirmed: the row was already answered or replaced (`stale`), or confirming would put two
    /// items of one meeting in one chain, so the suggestion was withdrawn (`withdrawn`, D14).
    public func confirmLinkOutcome(_ id: Int64) async throws -> LinkConfirmOutcome {
        guard let link = try itemLink(id), link.state == .suggested else { return .stale }
        // Two items of one meeting never join a chain (D14): a suggestion that would make them one is withdrawn.
        if link.relation == .same,
           try sameGroups(link.kind, adding: (link.srcID, link.dstID)).contains(where: { $0.members.contains { $0.id == link.srcID } && Set($0.members.map(\.meeting)).count < $0.members.count }) {
            try run("DELETE FROM item_links WHERE id = ?", [.integer(id)])
            try await commitEdit()
            return .withdrawn
        }
        let table = link.kind == .task ? "tasks" : "decisions"
        let prior = try LinkPrior(src: itemState(table, link.srcID), dst: itemState(table, link.dstID))
        let priorJSON: SQLiteValue? = prior.json.map { .text($0) }
        try transaction {
            try run("UPDATE item_links SET state = 'confirmed', decided_at = ?, prior = ? WHERE id = ?",
                    [.real(Date.now.timeIntervalSince1970), priorJSON, .integer(id)])
            try run("UPDATE \(table) SET source = 'user' WHERE id IN (?, ?)", [.integer(link.srcID), .integer(link.dstID)])
        }
        try await commitEdit()
        return .confirmed
    }

    private func itemState(_ table: String, _ id: Int64) throws -> LinkPrior.ItemState? {
        try db.query("SELECT source, text, unconfirmed FROM \(table) WHERE id = ?", [.integer(id)]).first
            .map { LinkPrior.ItemState(source: $0.string(0), key: LinkText.key($0.string(1)), unconfirmed: $0.int(2) != 0) }
    }

    /// Gives an item back to the model when the confirmation was what made it the person's: nothing else changed it since (same text, same
    /// mark) and no other confirmed link holds it.
    private func restoreSource(_ table: String, kind: LinkKind, id: Int64, linkID: Int64, was: LinkPrior.ItemState?) throws {
        guard let was, was.source != "user", let now = try itemState(table, id), now.source == "user", now.key == was.key,
              now.unconfirmed == was.unconfirmed else { return }
        let others = try db.query("""
            SELECT count(*) FROM item_links WHERE kind = ? AND state = 'confirmed' AND id <> ? AND (src_id = ?3 OR dst_id = ?3)
            """, [.text(kind.rawValue), .integer(linkID), .integer(id)]).first?.int(0) ?? 0
        guard others == 0 else { return }
        try run("UPDATE \(table) SET source = ? WHERE id = ?", [.text(was.source), .integer(id)])
    }

    /// "Not the same", "Not related": the pair is never suggested again, even after the minutes of either meeting are rewritten (the
    /// dismissal is kept by content as well as by id).
    @discardableResult
    public func dismissLink(_ id: Int64) async throws -> Bool {
        guard let link = try itemLink(id), link.state != .dismissed else { return false }
        let table = link.kind == .task ? "tasks" : "decisions"
        guard let src = try db.query("SELECT meeting_id, text FROM \(table) WHERE id = ?", [.integer(link.srcID)]).first,
              let dst = try db.query("SELECT meeting_id, text FROM \(table) WHERE id = ?", [.integer(link.dstID)]).first else { return false }
        let now = Date.now.timeIntervalSince1970
        try transaction {
            try run("UPDATE item_links SET state = 'dismissed', decided_at = ? WHERE id = ?", [.real(now), .integer(id)])
            try run("""
                INSERT OR REPLACE INTO item_link_dismissals(kind, src_meeting_id, src_key, dst_meeting_id, dst_key, decided_at) VALUES (?, ?, ?, ?, ?, ?)
                """, [.text(link.kind.rawValue), .integer(src.int(0)), .text(LinkText.key(src.string(1))), .integer(dst.int(0)),
                      .text(LinkText.key(dst.string(1))), .real(now)])
        }
        try await commitEdit()
        return true
    }

    /// "Restore" in the Suggestions tab (and Undo of a dismissal): the dismissal is forgotten and the pair is a suggestion again, at once. A
    /// restored suggestion stays until the person decides it: the next pass does not drop it, and it counts against the caps.
    public func restoreLink(_ id: Int64) async throws {
        guard let link = try itemLink(id), link.state == .dismissed, try !hasConfirmedLink(link) else { return }
        try transaction {
            try forgetDismissalKeys(of: link)
            try reinstate(link)
        }
        try await commitEdit()
    }

    /// Whether the newer item of `link` already has a confirmed link: it has one link at most (D17), so a dismissed one stays dismissed.
    private func hasConfirmedLink(_ link: StoredLink) throws -> Bool {
        try (db.query("SELECT count(*) FROM item_links WHERE kind = ? AND src_id = ? AND state = 'confirmed'",
                      [.text(link.kind.rawValue), .integer(link.srcID)]).first?.int(0) ?? 0) > 0
    }

    /// Makes a dismissed row a suggestion the passes keep (`decided_at` stays set). The item has one suggestion at most, and the meeting six: the
    /// pass's own suggestions give way.
    private func reinstate(_ link: StoredLink) throws {
        try run("UPDATE item_links SET state = 'suggested', decided_at = ? WHERE id = ?", [.real(Date.now.timeIntervalSince1970), .integer(link.id)])
        try run("DELETE FROM item_links WHERE kind = ? AND src_id = ? AND state = 'suggested' AND decided_at IS NULL", [.text(link.kind.rawValue), .integer(link.srcID)])
        let table = link.kind == .task ? "tasks" : "decisions"
        guard let meeting = try db.query("SELECT meeting_id FROM \(table) WHERE id = ?", [.integer(link.srcID)]).first?.optionalInt(0) else { return }
        let held = try db.query("""
            SELECT id, decided_at IS NOT NULL FROM item_links WHERE state = 'suggested' AND (
                (kind = 'task' AND src_id IN (SELECT id FROM tasks WHERE meeting_id = ?1)) OR
                (kind = 'decision' AND src_id IN (SELECT id FROM decisions WHERE meeting_id = ?1)))
            ORDER BY (method = 'vector'), coalesce(score, 0), id
            """, [.integer(meeting)])
        var excess = held.count - LinkPolicy().perMeeting
        for row in held where excess > 0 && row.int(1) == 0 {
            try run("DELETE FROM item_links WHERE id = ?", [.integer(row.int(0))])
            excess -= 1
        }
    }

    private func forgetDismissalKeys(of link: StoredLink) throws {
        let table = link.kind == .task ? "tasks" : "decisions"
        guard let src = try db.query("SELECT meeting_id, text FROM \(table) WHERE id = ?", [.integer(link.srcID)]).first,
              let dst = try db.query("SELECT meeting_id, text FROM \(table) WHERE id = ?", [.integer(link.dstID)]).first else { return }
        try run("""
            DELETE FROM item_link_dismissals WHERE kind = ? AND src_meeting_id = ? AND src_key = ? AND dst_meeting_id = ? AND dst_key = ?
            """, [.text(link.kind.rawValue), .integer(src.int(0)), .text(LinkText.key(src.string(1))), .integer(dst.int(0)), .text(LinkText.key(dst.string(1)))])
    }

    /// Restore by content: a dismissed pair whose link row may have gone with a rewrite. Returns whether a suggestion is there now; when it is
    /// not, the caller runs the pass again for the newer item's meeting. A pair whose newer item already has a confirmed link stays dismissed
    /// (nothing to run again, so it also returns true).
    @discardableResult
    public func restoreDismissal(_ dismissal: DismissedLink) async throws -> Bool {
        var restored = false
        if let row = try db.query("SELECT \(Self.linkColumns) FROM item_links WHERE state = 'dismissed' AND kind = ? AND src_id = ? AND dst_id = ?",
                                  [.text(dismissal.kind.rawValue), .integer(dismissal.srcID), .integer(dismissal.dstID)]).compactMap(Self.link).first,
           try hasConfirmedLink(row) { return true }
        try transaction {
            try run("""
                DELETE FROM item_link_dismissals WHERE kind = ? AND src_meeting_id = ? AND src_key = ? AND dst_meeting_id = ? AND dst_key = ?
                """, [.text(dismissal.kind.rawValue), .integer(dismissal.srcMeetingID), .text(dismissal.srcKey), .integer(dismissal.dstMeetingID), .text(dismissal.dstKey)])
            if let row = try db.query("SELECT \(Self.linkColumns) FROM item_links WHERE state = 'dismissed' AND kind = ? AND src_id = ? AND dst_id = ?",
                                      [.text(dismissal.kind.rawValue), .integer(dismissal.srcID), .integer(dismissal.dstID)]).compactMap(Self.link).first {
                try reinstate(row)
                restored = true
            }
        }
        try await commitEdit()
        return restored
    }

    /// "Undo Link": a confirmed or dismissed link goes back to being a suggestion. Undoing a confirmation also gives the items back to the
    /// model when the confirmation was all that made them the person's.
    @discardableResult
    public func undoLink(_ id: Int64) async throws -> Bool {
        guard let link = try itemLink(id), link.state != .suggested else { return false }
        if link.state == .dismissed { try await restoreLink(id); return true }
        let prior = try db.query("SELECT prior FROM item_links WHERE id = ?", [.integer(id)]).first?.optionalString(0).flatMap { LinkPrior(json: $0) }
        let table = link.kind == .task ? "tasks" : "decisions"
        try transaction {
            try run("UPDATE item_links SET state = 'suggested', decided_at = NULL WHERE id = ?", [.integer(id)])
            try restoreSource(table, kind: link.kind, id: link.srcID, linkID: id, was: prior?.src)
            try restoreSource(table, kind: link.kind, id: link.dstID, linkID: id, was: prior?.dst)
            try run("UPDATE item_links SET prior = NULL WHERE id = ?", [.integer(id)])
        }
        try await commitEdit()
        return true
    }

    /// The dismissed pairs of a meeting (the newer end), whose two items still exist, newest decision first. A pair is listed by the link row
    /// the person dismissed and by its content (the second survives a rewrite of the minutes); a small edit of either text moves the content
    /// key but not the row.
    public func dismissedLinks(ofMeeting meetingID: Int64) throws -> [DismissedLink] {
        var out: [DismissedLink] = []
        var seen = Set<String>()
        func add(_ kind: LinkKind, _ srcID: Int64, _ dstID: Int64) throws {
            let table = kind == .task ? "tasks" : "decisions"
            guard let src = try db.query("SELECT meeting_id, text FROM \(table) WHERE id = ?", [.integer(srcID)]).first,
                  let dst = try db.query("SELECT meeting_id, text FROM \(table) WHERE id = ?", [.integer(dstID)]).first,
                  let meeting = try meeting(dst.int(0)), seen.insert("\(kind.rawValue)|\(srcID)|\(dstID)").inserted else { return }
            out.append(DismissedLink(kind: kind, srcMeetingID: src.int(0), srcKey: LinkText.key(src.string(1)), dstMeetingID: dst.int(0), dstKey: LinkText.key(dst.string(1)),
                                     srcID: srcID, dstID: dstID, newerText: src.string(1), earlierText: dst.string(1), earlierMeetingTitle: meeting.displayTitle,
                                     earlierMeetingDate: meeting.startedAt))
        }
        for row in try db.query("""
            SELECT kind, src_id, dst_id FROM item_links WHERE state = 'dismissed' AND (
                (kind = 'task' AND src_id IN (SELECT id FROM tasks WHERE meeting_id = ?1)) OR
                (kind = 'decision' AND src_id IN (SELECT id FROM decisions WHERE meeting_id = ?1)))
            ORDER BY decided_at DESC
            """, [.integer(meetingID)]) {
            guard let kind = LinkKind(rawValue: row.string(0)) else { continue }
            try add(kind, row.int(1), row.int(2))
        }
        for row in try db.query("""
            SELECT kind, src_meeting_id, src_key, dst_meeting_id, dst_key FROM item_link_dismissals WHERE src_meeting_id = ? ORDER BY decided_at DESC
            """, [.integer(meetingID)]) {
            guard let kind = LinkKind(rawValue: row.string(0)) else { continue }
            let table = kind == .task ? "tasks" : "decisions"
            func find(_ meeting: Int64, _ key: String) throws -> Int64? {
                try db.query("SELECT id, text FROM \(table) WHERE meeting_id = ?", [.integer(meeting)]).first { LinkText.key($0.string(1)) == key }.map { $0.int(0) }
            }
            if let src = try find(row.int(1), row.string(2)), let dst = try find(row.int(3), row.string(4)) { try add(kind, src, dst) }
        }
        return out
    }

    // MARK: Edits

    /// After the text of an item changed (`old` is the text before). A substantial change (content-word Jaccard under 0.5) lifts what the
    /// person decided about the item: confirmed links go back to suggestions ("needs review"), and a dismissal of the old words goes, so
    /// a different text can be suggested again. A small edit keeps all of it.
    func linkEdited(kind: LinkKind, id: Int64, old: String, new: String, meetingID: Int64) throws {
        guard old != new else { return }
        let locale = try meeting(meetingID)?.minutesLocale.identifier ?? Meeting.legacyLocaleIdentifier
        guard LinkText.isSubstantialEdit(from: old, to: new, locale: locale) else { return }
        // `decided_at` stays set (as for a restored dismissal): a link waiting for review is the person's, so no later pass drops it.
        try run("UPDATE item_links SET state = 'suggested', decided_at = ?3, prior = NULL WHERE kind = ?1 AND state = 'confirmed' AND (src_id = ?2 OR dst_id = ?2)",
                [.text(kind.rawValue), .integer(id), .real(Date.now.timeIntervalSince1970)])
        try run("DELETE FROM item_links WHERE kind = ?1 AND state = 'dismissed' AND (src_id = ?2 OR dst_id = ?2)", [.text(kind.rawValue), .integer(id)])
        let key = LinkText.key(old)
        try run("""
            DELETE FROM item_link_dismissals WHERE kind = ?1 AND ((src_meeting_id = ?2 AND src_key = ?3) OR (dst_meeting_id = ?2 AND dst_key = ?3))
            """, [.text(kind.rawValue), .integer(meetingID), .text(key)])
    }

    // MARK: Chains

    /// The chains of confirmed "same" links of one kind, newest member first. Tasks are never merged: each member keeps its meeting, its
    /// citation and its status.
    public func linkChains(_ kind: LinkKind) throws -> [LinkChain] {
        let table = kind == .task ? "tasks" : "decisions"
        let pairs = try db.query("SELECT src_id, dst_id FROM item_links WHERE kind = ? AND state = 'confirmed' AND rel = 'same'", [.text(kind.rawValue)])
            .map { (newer: $0.int(0), earlier: $0.int(1)) }
        guard !pairs.isEmpty else { return [] }
        let ids = Array(Set(pairs.flatMap { [$0.newer, $0.earlier] }))
        var dates: [Int64: Date] = [:]
        for r in try db.query("""
            SELECT x.id, m.started_at FROM \(table) x JOIN meetings m ON m.id = x.meeting_id WHERE x.id IN (SELECT value FROM json_each(?))
            """, [.ids(ids)]) {
            dates[r.int(0)] = Date(timeIntervalSince1970: r.double(1))
        }
        return LinkChain.chains(links: pairs, dates: dates)
    }

    /// The other tasks of the chain that holds `id` (confirmed "same" links, either direction, transitively).
    public func chainMembers(ofTask id: Int64) throws -> [Int64] {
        let rows = try db.query("SELECT src_id, dst_id FROM item_links WHERE kind = 'task' AND state = 'confirmed' AND rel = 'same'")
        guard !rows.isEmpty else { return [] }
        var neighbors: [Int64: Set<Int64>] = [:]
        for r in rows {
            neighbors[r.int(0), default: []].insert(r.int(1))
            neighbors[r.int(1), default: []].insert(r.int(0))
        }
        var seen: Set<Int64> = [id]
        var queue = [id]
        while let next = queue.popLast() {
            for n in neighbors[next] ?? [] where seen.insert(n).inserted { queue.append(n) }
        }
        seen.remove(id)
        return seen.sorted()
    }

    /// The earliest member of the chain that holds `id` and its date: "first decided on…". nil when the item is in no chain or is the first.
    public func firstOfChain(kind: LinkKind, id: Int64) throws -> (id: Int64, date: Date)? {
        guard let chain = try linkChains(kind).first(where: { $0.members.contains { $0.id == id } }), let first = chain.members.last, first.id != id else { return nil }
        return (first.id, first.date)
    }
}

/// What `confirmLinkOutcome` did.
public enum LinkConfirmOutcome: Sendable, Equatable {
    case confirmed
    /// The row was answered, replaced or removed already.
    case stale
    /// Confirming would have put two items of one meeting in one chain: the suggestion was removed.
    case withdrawn
}

/// What the two items of a link were before its confirmation (`item_links.prior`).
struct LinkPrior: Codable, Equatable {
    struct ItemState: Codable, Equatable {
        var source: String
        var key: String
        var unconfirmed: Bool
    }
    var src: ItemState?
    var dst: ItemState?

    init(src: ItemState?, dst: ItemState?) { self.src = src; self.dst = dst }

    var json: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    init?(json: String) {
        guard let value = try? JSONDecoder().decode(LinkPrior.self, from: Data(json.utf8)) else { return nil }
        self = value
    }
}

/// Where a link row is shown: the newer item.
public struct LinkRowKey: Hashable, Sendable {
    public let kind: LinkKind
    public let itemID: Int64
    public init(kind: LinkKind, itemID: Int64) { self.kind = kind; self.itemID = itemID }
}

/// A pair the person said is not the same, as the Suggestions tab lists it.
public struct DismissedLink: Sendable, Identifiable, Hashable {
    public var id: String { "\(kind.rawValue)|\(srcID)|\(dstID)" }
    public let kind: LinkKind
    public let srcMeetingID: Int64
    public let srcKey: String
    public let dstMeetingID: Int64
    public let dstKey: String
    public let srcID: Int64
    public let dstID: Int64
    public let newerText: String
    public let earlierText: String
    public let earlierMeetingTitle: String
    public let earlierMeetingDate: Date
}
