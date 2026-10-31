// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What is left of a meeting whose transcript retention deleted (`raw_purged_at`, after `MeetingStore.retentionDays`): its minutes. Ask
/// sends the minutes' decisions, tasks and summary that match a question as lines of a passage of their own, so an answer about an older
/// meeting can be found and checked: a claim's quote must be in the item it cites, word for word, as for a segment. Such a claim says
/// it comes from the minutes, which summarize what was said in the model's words; they are not the words said.
public enum MinutesEvidence {
    /// The kinds of item, numbered as in `knowledge_fts`.
    public enum Kind: Int64, Sendable { case decision = 1, task = 2, summary = 5 }

    /// The ids of these lines are far above any segment's (row ids: a billion would take thousands of years of meetings), so a citation
    /// tells which it is, and short enough for a small model to copy.
    static let base: Int64 = 1_000_000_000

    public static func isMinutes(_ id: Int64) -> Bool { id >= base }

    public static func kind(of id: Int64) -> Kind? { isMinutes(id) ? Kind(rawValue: (id - base) % 8) : nil }

    static func id(_ kind: Kind, ref: Int64) -> Int64 { base + ref * 8 + kind.rawValue }

    /// The heading's note of a passage made of minutes' lines (English, as the prompts are).
    static let headingNote = " — its transcript was deleted; these lines are from its minutes, a summary, not the words said"
}

extension MinutesEvidence.Kind {
    /// How the prompt names the item.
    var promptLabel: String {
        switch self {
        case .decision: "decision"
        case .task: "task"
        case .summary: "summary"
        }
    }
}

extension MeetingStore {
    /// The decisions, tasks and summary of the minutes of the meetings in `scope` (all when nil) whose transcript is gone, that match
    /// the words of `question`: one passage per meeting, best match first, at most `limit`, its items as lines (`MinutesEvidence` ids,
    /// at the time each was said; the summary at the start). `score` is 0: the caller places them after the transcripts' passages.
    public func minutesPassages(_ question: String, scope: [Int64]?, locale: Locale? = nil, limit: Int = 3) throws -> [RetrievedPassage] {
        let profile = locale.map(LanguageProfile.init(locale:)) ?? LanguageProfile.detecting(question)
        let terms = Self.queryTerms(question, profile: profile)
        let spaced = terms.filter { !$0.contains(where: TextKeys.isNoSpaceScript) }
        let unspaced = terms.filter { $0.contains(where: TextKeys.isNoSpaceScript) }
        let older = "SELECT id FROM meetings WHERE raw_purged_at IS NOT NULL AND (?2 IS NULL OR id IN (SELECT value FROM json_each(?2)))"
        let scoped = """
            ((rowid % 8 = 1 AND rowid / 8 IN (SELECT id FROM decisions WHERE meeting_id IN (\(older))))
             OR (rowid % 8 = 2 AND rowid / 8 IN (SELECT id FROM tasks WHERE meeting_id IN (\(older))))
             OR (rowid % 8 = 5 AND rowid / 8 IN (\(older))))
            """
        var keys: [Int64] = []
        if !spaced.isEmpty {
            let match = spaced.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }.joined(separator: " OR ")
            keys += try db.query("SELECT rowid FROM knowledge_fts WHERE knowledge_fts MATCH ?1 AND \(scoped) ORDER BY rank LIMIT 40",
                                 [.text(match), scope.map { .ids($0) }]).map { $0.int(0) }
        }
        if !unspaced.isEmpty {
            keys += try db.query("""
                SELECT rowid FROM knowledge_fts WHERE \(scoped) AND EXISTS (SELECT 1 FROM json_each(?1) WHERE instr(text, value) > 0) LIMIT 40
                """, [.text(Self.json(strings: unspaced)), scope.map { .ids($0) }]).map { $0.int(0) }
        }
        guard !keys.isEmpty else { return [] }
        var lines: [Int64: (meeting: Int64, line: CitableSegment)] = [:]
        for row in try db.query("""
            SELECT f.rowid, f.text,
                   CASE f.rowid % 8 WHEN 1 THEN (SELECT meeting_id FROM decisions WHERE id = f.rowid / 8)
                                    WHEN 2 THEN (SELECT meeting_id FROM tasks WHERE id = f.rowid / 8) ELSE f.rowid / 8 END,
                   CASE f.rowid % 8 WHEN 1 THEN (SELECT t FROM decisions WHERE id = f.rowid / 8)
                                    WHEN 2 THEN (SELECT t FROM tasks WHERE id = f.rowid / 8) ELSE 0 END
            FROM knowledge_fts f WHERE f.rowid IN (SELECT value FROM json_each(?1))
            """, [.ids(keys)]) {
            let key = row.int(0)
            guard let kind = MinutesEvidence.Kind(rawValue: key % 8) else { continue }
            let text = row.string(1)
            guard !text.isEmpty else { continue }
            lines[key] = (row.int(2), CitableSegment(id: MinutesEvidence.id(kind, ref: key / 8), channel: .others, start: row.optionalDouble(3) ?? 0, text: text))
        }
        // One passage per meeting, in the order of each meeting's best match; its lines in the order of the meeting.
        var order: [Int64] = [], byMeeting: [Int64: [CitableSegment]] = [:]
        for key in keys {
            guard let (meeting, line) = lines[key], byMeeting[meeting]?.contains(where: { $0.id == line.id }) != true else { continue }
            if byMeeting[meeting] == nil { order.append(meeting) }
            byMeeting[meeting, default: []].append(line)
        }
        return try order.prefix(limit).compactMap { id in
            guard let meeting = try self.meeting(id), let found = byMeeting[id]?.sorted(by: { ($0.start, $0.id) < ($1.start, $1.id) }) else { return nil }
            return RetrievedPassage(meeting: meeting, start: found.first?.start ?? 0, end: found.last?.start ?? 0, segments: found, score: 0)
        }
    }
}

extension VerifiedAnswer.Claim {
    /// The quote is in the minutes of a meeting whose transcript is gone (`MinutesEvidence`), not in what was said.
    public var isFromMinutes: Bool { !citations.isEmpty && citations.allSatisfy(MinutesEvidence.isMinutes) }
}
