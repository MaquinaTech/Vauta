// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The meeting card: summary, topics and open questions, written by the user
/// or proposed by the local model. Decisions and tasks live in their own tables.
///
/// Stored as JSON in `meetings.card`. The keys `resumen` and `temas` are
/// frozen: existing stores use them and the full-text trigger reads them.
/// New fields use English keys and are optional when decoding.
public struct MeetingCard: Sendable, Codable, Equatable {
    public var summary: String
    public var topics: [String]
    /// Questions or topics left open. `nil` = not provided: saving the card
    /// keeps the stored ones (the card editor does not show them).
    public var openQuestions: [String]?

    public init(summary: String = "", topics: [String] = [], openQuestions: [String]? = nil) {
        self.summary = summary
        self.topics = topics
        self.openQuestions = openQuestions
    }

    private enum CodingKeys: String, CodingKey {
        case summary = "resumen"
        case topics = "temas"
        case openQuestions = "open_questions"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        topics = try c.decodeIfPresent([String].self, forKey: .topics) ?? []
        openQuestions = try c.decodeIfPresent([String].self, forKey: .openQuestions)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(summary, forKey: .summary)
        try c.encode(topics, forKey: .topics)
        try c.encodeIfPresent(openQuestions, forKey: .openQuestions)
    }

    var isEmpty: Bool { summary.isEmpty && topics.isEmpty && (openQuestions ?? []).isEmpty }

    func json() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
}

public struct MeetingFilter: Sendable, Equatable {
    /// The meeting must name (or have as attendee) ALL of these entities.
    public var entities: [Int64] = []
    public var series: Int64?
    public var from: Date?
    public var to: Date?

    public init(entities: [Int64] = [], series: Int64? = nil, from: Date? = nil, to: Date? = nil) {
        self.entities = entities
        self.series = series
        self.from = from
        self.to = to
    }

    public var isEmpty: Bool { entities.isEmpty && series == nil && from == nil && to == nil }
}

extension MeetingStore {
    public func card(_ meetingID: Int64) throws -> MeetingCard? {
        guard let json = try db.query("SELECT card FROM meetings WHERE id = ?", [.integer(meetingID)]).first?.optionalString(0) else { return nil }
        return try? JSONDecoder().decode(MeetingCard.self, from: Data(json.utf8))
    }

    /// Saves the user's card (it is never replaced by a regenerated one).
    /// Open questions left `nil` keep the stored ones.
    public func saveCard(_ card: MeetingCard, of meetingID: Int64) async throws {
        var clean = MeetingCard(summary: Self.clean(card.summary, max: 20_000),
                                topics: card.topics.map { Self.clean($0, max: 120) }.filter { !$0.isEmpty }.prefix(30).map { $0 },
                                openQuestions: card.openQuestions.map { Self.cleanList($0, max: 300, count: 20) })
        if clean.openQuestions == nil { clean.openQuestions = try self.card(meetingID)?.openQuestions }
        let json = clean.isEmpty ? nil : try clean.json()
        try run("UPDATE meetings SET card = ?, card_version = card_version + 1, card_source = 'user' WHERE id = ?",
                [json.map { .text($0) }, .integer(meetingID)])
        // No compaction needed: knowledge_fts uses secure-delete.
        try await commitEdit()
    }

    static func cleanList(_ items: [String], max: Int, count: Int) -> [String] {
        Array(items.map { clean($0, max: max) }.filter { !$0.isEmpty }.prefix(count))
    }

    /// Meetings matching the filter (newest first). Entity IDs are bound as
    /// JSON for `IN (SELECT value FROM json_each(?))`: user data never builds SQL.
    public func meetingIDs(matching f: MeetingFilter) throws -> [Int64] {
        try db.query("""
            SELECT m.id FROM meetings m
            WHERE (?1 IS NULL OR m.series_id = ?1)
              AND (?2 IS NULL OR m.started_at >= ?2)
              AND (?3 IS NULL OR m.started_at < ?3)
              AND (?5 = 0 OR (SELECT COUNT(DISTINCT x.entity_id) FROM (
                        SELECT entity_id FROM mentions WHERE meeting_id = m.id AND entity_id IN (SELECT value FROM json_each(?4))
                        UNION SELECT entity_id FROM meeting_entities WHERE meeting_id = m.id AND entity_id IN (SELECT value FROM json_each(?4))) x) = ?5)
            ORDER BY m.started_at DESC
            """, [f.series.map { .integer($0) }, f.from.map { .real($0.timeIntervalSince1970) }, f.to.map { .real($0.timeIntervalSince1970) },
                  .ids(f.entities), .integer(Int64(Set(f.entities).count))]).map { $0.int(0) }
    }

    /// Series of each meeting that has one (for the meeting list).
    public func meetingSeriesIDs() throws -> [Int64: Int64] {
        Dictionary(uniqueKeysWithValues: try db.query("SELECT id, series_id FROM meetings WHERE series_id IS NOT NULL").map { ($0.int(0), $0.int(1)) })
    }
}
