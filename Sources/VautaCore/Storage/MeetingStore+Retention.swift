// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Deleting meetings, retention and compaction.
///
/// Retention has two speeds. With `knowledgeRetentionDays` at most
/// `retentionDays` (90), whole meetings are deleted after 90 days. With more
/// (or 0 = no limit), after 90 days only the raw text is purged (segments, speakers,
/// chunks, live notes, suggestions) and the meeting's card, decisions, tasks,
/// notes, marks and graph stay until `knowledgeRetentionDays`. A meeting
/// without a card keeps its raw text `distillGraceDays` longer so the model
/// server can write its card first.
extension MeetingStore {
    static let expiredSQL = "DELETE FROM meetings WHERE started_at < ? AND id IS NOT ?"
    /// Grace days to distill (write the card) before purging the text of a
    /// meeting that has no card yet.
    static let distillGraceDays = 7

    /// Deletes the meeting and EVERY trace of its text: with an external-content
    /// FTS5 table, 'delete' only adds tombstones and the terms stay in the index
    /// until it is merged ('optimize'); secure_delete zeroes freed pages and
    /// VACUUM compacts. While recording, 'optimize' and VACUUM are deferred to
    /// the end of the recording (the table text is deleted now). Returns once
    /// the delete is on disk.
    public func deleteMeeting(_ id: Int64) async throws {
        guard id != activeMeetingID else { throw StoreError.meetingInProgress }
        let compaction = try removeMeetings("DELETE FROM meetings WHERE id = ?", [.integer(id)]).compaction
        do {
            try await snapshot(compacting: false)
        } catch {
            throw StoreError(.deleteNotSaved, underlying: error)
        }
        if let compaction {
            throw StoreError(.compactionFailed, underlying: compaction)
        }
    }

    /// Retention (never the meeting being recorded): deletes expired meetings
    /// like `deleteMeeting` and, with two speeds, only the raw text of those
    /// older than `retentionDays`. Also removes migration copies set aside more
    /// than `retentionDays` ago. Returns how many rows changed.
    @discardableResult
    public func purgeExpired(now: Date = .now) async throws -> Int {
        // Copies set aside by the migration from the earlier version expire like the meetings they hold.
        purgeExpiredSetAside(now: now)
        let (n, compaction) = try removeMeetings(Self.retentionStatements(now: now, knowledgeDays: knowledgeRetentionDays,
                                                                          active: activeMeetingID))
        if n > 0 { try await snapshot(compacting: false) }
        if let compaction { throw StoreError(.compactionFailed, underlying: compaction) }
        return n
    }

    /// 0 = no limit; `retentionDays` = everything is deleted after 90 days.
    public func setKnowledgeRetention(days: Int) {
        knowledgeRetentionDays = days == 0 ? 0 : max(Self.retentionDays, days)
    }

    static func retentionStatements(now: Date, knowledgeDays: Int, active: Int64?) -> [(String, [SQLiteValue?])] {
        let day = 86_400.0, t = now.timeIntervalSince1970
        let activeParam: SQLiteValue? = active.map { .integer($0) }
        let rawCut = t - Double(retentionDays) * day
        if knowledgeDays != 0 && knowledgeDays <= retentionDays {
            return [(expiredSQL, [.real(rawCut), activeParam])]
        }
        var out: [(String, [SQLiteValue?])] = []
        if knowledgeDays > 0 { out.append((expiredSQL, [.real(t - Double(knowledgeDays) * day), activeParam])) }
        // Raw text: after 90 days if there is a card; otherwise with a few
        // grace days so the model server can distill it first.
        let target = """
            SELECT id FROM meetings WHERE started_at < ?1 AND raw_purged_at IS NULL AND id IS NOT ?2
                AND (card IS NOT NULL OR started_at < ?3)
            """
        let params: [SQLiteValue?] = [.real(rawCut), activeParam, .real(rawCut - Double(distillGraceDays) * day)]
        for table in ["segments", "meeting_speakers", "diarization_windows", "chunks", "live_notes", "suggestions"] {
            out.append(("DELETE FROM \(table) WHERE meeting_id IN (\(target))", params))
        }
        // Questions heard in the meeting are raw text too: only the ones the person kept stay.
        out.append(("DELETE FROM detected_questions WHERE kept = 0 AND meeting_id IN (\(target))", params))
        // The exact wording used in the transcript becomes the entity's name.
        out.append(("UPDATE mentions SET surface = (SELECT name FROM entities WHERE id = mentions.entity_id) WHERE meeting_id IN (\(target))", params))
        out.append(("UPDATE meetings SET raw_purged_at = ?4 WHERE id IN (\(target))", params + [.real(t)]))
        return out
    }

    /// Meetings about to lose their text (85–90 days) without a card: they need distilling.
    public func meetingsNeedingDistill(now: Date = .now) throws -> [Int64] {
        guard knowledgeRetentionDays == 0 || knowledgeRetentionDays > Self.retentionDays else { return [] }
        let t = now.timeIntervalSince1970
        return try db.query("""
            SELECT id FROM meetings WHERE raw_purged_at IS NULL AND card IS NULL AND ended_at IS NOT NULL
                AND started_at < ? AND EXISTS (SELECT 1 FROM segments WHERE meeting_id = meetings.id)
            """, [.real(t - Double(Self.retentionDays - 5) * 86_400)]).map { $0.int(0) }
    }

    /// Meetings with nothing to keep (no text, notes or marks). Meetings whose
    /// text was already purged (two-speed retention) are kept.
    static let deleteEmptySQL = """
        DELETE FROM meetings WHERE raw_purged_at IS NULL AND NOT EXISTS (SELECT 1 FROM segments WHERE meeting_id = meetings.id)
            AND NOT EXISTS (SELECT 1 FROM notes WHERE meeting_id = meetings.id)
            AND NOT EXISTS (SELECT 1 FROM marks WHERE meeting_id = meetings.id)
        """

    /// Deletes meetings (their segments cascade; the trigger marks the FTS) and
    /// compacts, or leaves it pending while recording. If compaction fails the
    /// delete is already done: the error is returned and compaction stays
    /// pending (every save retries it).
    func removeMeetings(_ sql: String, _ params: [SQLiteValue?]) throws -> (count: Int, compaction: Error?) {
        try removeMeetings([(sql, params)])
    }

    func removeMeetings(_ statements: [(String, [SQLiteValue?])]) throws -> (count: Int, compaction: Error?) {
        let n = try transaction {
            var n = 0
            for (sql, params) in statements {
                try run(sql, params)
                n += db.changes
            }
            if n > 0 {
                for cleanup in Self.orphanCleanupSQL { try run(cleanup) }
                // What a deleted meeting said must not stay in another meeting's stored answers.
                try purgeDanglingQuestionCites()
            }
            return n
        }
        guard n > 0 else { return (0, nil) }
        // Anything built from the store (the pre-meeting brief's cache) keys on this revision: it must not keep a deleted meeting's text.
        editRevision &+= 1
        meetingsDeletedHandler?()
        vectorCache = nil
        pendingCompaction = true
        guard activeMeetingID == nil else { return (n, nil) }
        do { try compactNow() } catch { return (n, error) }
        return (n, nil)
    }

    func compactNow() throws {
        try Self.compact(db)
        pendingCompaction = false
    }

    /// What came from the Calendar only for meetings that are now deleted:
    /// unconfirmed people who appear in no meeting and that no speaker or voice profile uses, and series without meetings.
    static let orphanCleanupSQL = [
        """
        DELETE FROM entities WHERE source = 'calendar' AND confirmed = 0
            AND NOT EXISTS (SELECT 1 FROM meeting_entities WHERE entity_id = entities.id)
            AND NOT EXISTS (SELECT 1 FROM mentions WHERE entity_id = entities.id)
            AND NOT EXISTS (SELECT 1 FROM meeting_speakers WHERE entity_id = entities.id)
            AND NOT EXISTS (SELECT 1 FROM voice_profiles WHERE entity_id = entities.id)
        """,
        "DELETE FROM series WHERE calendar_key IS NOT NULL AND NOT EXISTS (SELECT 1 FROM meetings WHERE series_id = series.id)",
    ]

    /// Unjournaled variant for `init` (recovery): the snapshot written right after includes it.
    static func removeMeetings(_ db: SQLiteDatabase, _ statements: [(String, [SQLiteValue?])]) throws -> Int {
        try db.execute("BEGIN")
        do {
            var n = 0
            for (sql, params) in statements {
                try db.query(sql, params)
                n += db.changes
            }
            if n > 0 { for cleanup in orphanCleanupSQL { try db.query(cleanup) } }
            try db.execute("COMMIT")
            return n
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    /// Merges ALL FTS5 indexes (drops deleted terms) and compacts.
    static func compact(_ db: SQLiteDatabase) throws {
        let fts = try db.query("SELECT name FROM sqlite_schema WHERE type = 'table' AND sql LIKE 'CREATE VIRTUAL TABLE%USING fts5%' ORDER BY name")
        for row in fts {
            let name = row.string(0)
            // A name from sqlite_schema (not from the user); still, only [a-z_].
            guard name.allSatisfy({ $0 == "_" || ("a"..."z").contains($0) }) else { continue }
            try db.execute("INSERT INTO \(name)(\(name)) VALUES('optimize')")
        }
        try db.execute("VACUUM")
    }
}
