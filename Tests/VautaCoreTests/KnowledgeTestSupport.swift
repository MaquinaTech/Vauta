// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
@testable import VautaCore

/// A throwaway store in a temporary directory with an in-memory key store
/// (`StoreFixture`): never touches the user's store or Keychain.
final class KnowledgeFixture: @unchecked Sendable {
    private let storage = StoreFixture()
    private let knowledgeRetentionDays: Int
    private(set) var store: MeetingStore!

    init(knowledgeRetentionDays: Int = MeetingStore.retentionDays) throws {
        self.knowledgeRetentionDays = knowledgeRetentionDays
        store = try storage.open(knowledgeDays: knowledgeRetentionDays)
    }

    deinit { store = nil }

    /// Flushes, closes and reopens the store from disk.
    func reopen() async throws {
        try await store.flush()
        store = nil
        store = try storage.open(knowledgeDays: knowledgeRetentionDays)
    }

    /// Records an ended meeting with one segment per line (10 s apart),
    /// alternating "others" and "me". It is analyzed on end (legacy language).
    @discardableResult
    func meeting(_ lines: [String], at date: Date = .now) async throws -> Int64 {
        let id = try await store.startMeeting(at: date)
        for (i, line) in lines.enumerated() {
            try await store.append(Segment(channel: i % 2 == 0 ? .others : .me, start: Double(i * 10), end: Double(i * 10 + 8),
                                           text: line, isFinal: true), to: id)
        }
        try await store.endMeeting(id, at: date + 600)
        return id
    }
}

/// Test-only access to the in-memory database.
extension MeetingStore {
    func executeForTest(_ sql: String, _ params: [SQLiteValue?] = []) throws {
        try db.query(sql, params)
    }

    func stringsForTest(_ sql: String, _ params: [SQLiteValue?] = []) throws -> [String?] {
        try db.query(sql, params).map { $0.optionalString(0) }
    }

    func intsForTest(_ sql: String, _ params: [SQLiteValue?] = []) throws -> [Int64] {
        try db.query(sql, params).map { $0.int(0) }
    }

    /// Query plan of the open-tasks-by-owner query.
    func openTasksPlan() throws -> String {
        try db.query("EXPLAIN QUERY PLAN SELECT id FROM tasks WHERE status = 'open' AND owner_id = ?", [.integer(1)])
            .map { $0.string(3) }.joined(separator: " | ")
    }

    /// Synthetic graph (deterministic generator) to exercise `impact`.
    func bulkGraphForTest(entities: Int, edges: Int) throws -> Int64 {
        try db.execute("BEGIN")
        let first = (try db.query("SELECT coalesce(max(id), 0) FROM entities")[0].int(0)) + 1
        for i in 0..<entities {
            try db.query("INSERT INTO entities(id, kind, name, source, created_at) VALUES (?, 'topic', ?, 'llm', 0)",
                         [.integer(first + Int64(i)), .text("zzbulk\(i)")])
        }
        var x: UInt64 = 0x2545F4914F6CDD1D
        var made = 0
        while made < edges {
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            let a = first + Int64(x % UInt64(entities)), b = first + Int64((x >> 20) % UInt64(entities))
            guard a != b else { continue }
            try db.query("INSERT OR IGNORE INTO relations(src_kind, src_id, rel, dst_kind, dst_id, source) VALUES ('entity', ?, 'related_to', 'entity', ?, 'auto')",
                         [.integer(a), .integer(b)])
            made += 1
        }
        try db.execute("COMMIT")
        return first
    }

    /// Sets the meeting language (`meetings.locale`).
    func setMeetingLocaleForTest(_ meetingID: Int64, _ identifier: String?) throws {
        try db.query("UPDATE meetings SET locale = ? WHERE id = ?", [identifier.map { .text($0) }, .integer(meetingID)])
    }

    func recomputeAliasNormalizationForTest() throws {
        try db.execute("BEGIN")
        try Self.recomputeAliasNormalization(db)
        try db.execute("COMMIT")
    }
}
