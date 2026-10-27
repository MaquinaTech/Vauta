// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Where an alias came from.
public enum AliasOrigin: String, Sendable, Hashable {
    /// Typed by the user.
    case user
    /// From a calendar attendee.
    case calendar
    /// Proposed by the model.
    case llm
    /// Learned when the user resolved a transcription error.
    case learned
}

public struct EntityAlias: Sendable, Hashable {
    public let text: String
    public let origin: AliasOrigin

    public init(text: String, origin: AliasOrigin) {
        self.text = text
        self.origin = origin
    }
}

/// Everything in the store that hangs from one entity: what a merge moves
/// and what a delete removes or detaches. Read-only.
public struct EntityFootprint: Sendable, Equatable {
    /// Aliases besides the name, in locale-aware order.
    public var aliases: [EntityAlias] = []
    public var mentions = 0
    /// Meetings that mention the entity, list it as attendee or topic, or have a speaker named after it.
    public var meetings = 0
    /// Tasks it owns, in any state.
    public var tasks = 0
    public var openTasks = 0
    /// Edges that touch it (hand-made and from the meeting graph).
    public var relations = 0
    public var glossaryTerms = 0
    /// Recurring meetings that list it among their usual people.
    public var series = 0
    /// Earlier entries merged into this one (a delete removes them too).
    public var mergedEntries = 0
    /// Speakers of meetings named after it (a delete detaches them; a merge moves them).
    public var namedSpeakers = 0
    /// Voice profiles (biometric data): a delete removes them, a merge moves them.
    public var voiceProfiles = 0
    public var hasNote = false
    public var email: String?

    public init() {}
}

extension MeetingStore {
    /// The entity's footprint, or nil if it no longer exists.
    public func footprint(of id: Int64) throws -> EntityFootprint? {
        guard let row = try db.query("SELECT name, note, email FROM entities WHERE id = ?", [.integer(id)]).first else { return nil }
        let nameNorm = TextKeys.norm(row.string(0))
        var f = EntityFootprint()
        f.hasNote = !(row.optionalString(1) ?? "").isEmpty
        f.email = row.optionalString(2)
        f.aliases = try db.query("SELECT alias, alias_norm, source FROM aliases WHERE entity_id = ?", [.integer(id)])
            .filter { $0.string(1) != nameNorm }
            .map { EntityAlias(text: $0.string(0), origin: AliasOrigin(rawValue: $0.string(2)) ?? .user) }
            .sorted { $0.text.localizedStandardCompare($1.text) == .orderedAscending }
        let p: [SQLiteValue?] = [.integer(id)]
        func count(_ sql: String) throws -> Int { Int(try db.query(sql, p).first?.int(0) ?? 0) }
        f.mentions = try count("SELECT COUNT(*) FROM mentions WHERE entity_id = ?1")
        f.meetings = try count("""
            SELECT COUNT(*) FROM (SELECT meeting_id FROM mentions WHERE entity_id = ?1
                                  UNION SELECT meeting_id FROM meeting_entities WHERE entity_id = ?1
                                  UNION SELECT meeting_id FROM meeting_speakers WHERE entity_id = ?1 AND source = 'user')
            """)
        f.namedSpeakers = try count("SELECT COUNT(*) FROM meeting_speakers WHERE entity_id = ?1 AND source = 'user'")
        f.voiceProfiles = try count("SELECT COUNT(*) FROM voice_profiles WHERE entity_id = ?1")
        f.tasks = try count("SELECT COUNT(*) FROM tasks WHERE owner_id = ?1")
        f.openTasks = try count("SELECT COUNT(*) FROM tasks WHERE owner_id = ?1 AND status = 'open'")
        f.relations = try count("""
            SELECT COUNT(*) FROM relations WHERE (src_kind = 'entity' AND src_id = ?1) OR (dst_kind = 'entity' AND dst_id = ?1)
            """)
        f.glossaryTerms = try count("SELECT COUNT(*) FROM glossary WHERE entity_id = ?1")
        f.series = try count("SELECT COUNT(*) FROM series WHERE EXISTS (SELECT 1 FROM json_each(series.default_entities) WHERE value = ?1)")
        f.mergedEntries = try count("SELECT COUNT(*) FROM entities WHERE merged_into = ?1")
        return f
    }

    /// Number of meetings linked to each recurring series.
    public func meetingCountsBySeries() throws -> [Int64: Int] {
        Dictionary(uniqueKeysWithValues: try db.query("""
            SELECT series_id, COUNT(*) FROM meetings WHERE series_id IS NOT NULL GROUP BY series_id
            """).map { ($0.int(0), Int($0.int(1))) })
    }
}
