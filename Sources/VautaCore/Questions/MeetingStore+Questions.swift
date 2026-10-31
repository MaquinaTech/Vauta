// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The questions heard in a meeting (`detected_questions`, migration 26): stored with the meeting, encrypted with it, deleted with it.
extension MeetingStore {
    private static let questionColumns = "id, meeting_id, segment_id, t, channel, text, rewrite, outcome, answer, shown, dismissed, kept, created_at"

    private static func encode(_ content: AutoAnswerContent?) -> SQLiteValue? {
        guard let content else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(content)).map { .text(String(decoding: $0, as: UTF8.self)) }
    }

    private static func question(_ row: Row) -> DetectedQuestion {
        let content = row.optionalString(8).flatMap { try? JSONDecoder().decode(AutoAnswerContent.self, from: Data($0.utf8)) }
        return DetectedQuestion(id: row.int(0), meetingID: row.int(1), segmentID: row.optionalInt(2), t: row.double(3),
                                channel: Channel(storedSpeaker: row.string(4)), text: row.string(5), rewrite: row.string(6),
                                outcome: DetectedQuestion.Outcome(rawValue: row.string(7)) ?? .failed, answer: content,
                                shown: row.int(9) != 0, dismissed: row.int(10) != 0, kept: row.int(11) != 0,
                                createdAt: Date(timeIntervalSince1970: row.double(12)))
    }

    /// Stores a question the model confirmed. Returns its row id.
    @discardableResult
    public func addDetectedQuestion(_ q: DetectedQuestion) async throws -> Int64 {
        let now = Date.now.timeIntervalSince1970
        let params: [SQLiteValue?] = [
            .integer(q.meetingID),
            q.segmentID.map { SQLiteValue.integer($0) },
            .real(max(0, q.t)),
            .text(q.channel == .me ? "me" : "others"),
            .text(Self.clean(q.text, max: 1_000)),
            .text(Self.clean(q.rewrite, max: 1_000)),
            .text(q.outcome.rawValue),
            Self.encode(q.answer),
            .integer(q.shown ? 1 : 0),
            .integer(q.dismissed ? 1 : 0),
            .integer(q.kept ? 1 : 0),
            .real(now),
            .real(now),
        ]
        try run("""
            INSERT INTO detected_questions(meeting_id, segment_id, t, channel, text, rewrite, outcome, answer, shown, dismissed, kept, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, params)
        let id = try db.query("SELECT last_insert_rowid()")[0].int(0)
        try await commitEdit()
        return id
    }

    /// What became of a question: its outcome, its answer, and whether a card showed it.
    public func updateDetectedQuestion(_ id: Int64, outcome: DetectedQuestion.Outcome, answer: AutoAnswerContent?, shown: Bool) async throws {
        try run("UPDATE detected_questions SET outcome = ?, answer = ?, shown = ?, updated_at = ? WHERE id = ?",
                [.text(outcome.rawValue), Self.encode(answer), .integer(shown ? 1 : 0), .real(Date.now.timeIntervalSince1970), .integer(id)])
        try await commitEdit()
    }

    /// The person kept the question and its answer (it is searched and exported), or let it go.
    public func setQuestionKept(_ id: Int64, kept: Bool) async throws {
        try run("UPDATE detected_questions SET kept = ?, updated_at = ? WHERE id = ?", [.integer(kept ? 1 : 0), .real(Date.now.timeIntervalSince1970), .integer(id)])
        try await commitEdit()
    }

    public func setQuestionDismissed(_ id: Int64, dismissed: Bool) async throws {
        try run("UPDATE detected_questions SET dismissed = ?, updated_at = ? WHERE id = ?", [.integer(dismissed ? 1 : 0), .real(Date.now.timeIntervalSince1970), .integer(id)])
        try await commitEdit()
    }

    public func removeDetectedQuestion(_ id: Int64) async throws {
        try run("DELETE FROM detected_questions WHERE id = ?", [.integer(id)])
        try await commitEdit()
    }

    /// The meeting's questions that were not kept go (the setting "Keep detected questions with the meeting" is off).
    public func removeUnkeptQuestions(_ meetingID: Int64) async throws {
        try run("DELETE FROM detected_questions WHERE meeting_id = ? AND kept = 0", [.integer(meetingID)])
        try await commitEdit()
    }

    /// The questions that were not kept of these meetings go, except those of the meeting being recorded. Used at launch for recordings
    /// that ended without their own cleanup (`QuestionCleanupLedger`); meetings recorded with the setting on are never listed.
    public func removeUnkeptQuestions(ofMeetings ids: [Int64]) async throws {
        let ids = ids.filter { $0 != activeMeetingID }
        guard !ids.isEmpty else { return }
        try run("DELETE FROM detected_questions WHERE kept = 0 AND meeting_id IN (SELECT value FROM json_each(?))", [.ids(ids)])
        try await commitEdit()
    }

    /// The meeting's questions in the order they were asked. A citation of a meeting or a document that was deleted since is dropped
    /// from the answer, with the claims that rested on it, and the question says its source was removed (`sourceRemoved`). The stored
    /// answers are rewritten when the source goes (`purgeQuestionAnswers`); this check also covers a store opened after a recovery.
    public func detectedQuestions(_ meetingID: Int64, keptOnly: Bool = false) throws -> [DetectedQuestion] {
        let rows = try db.query("""
            SELECT \(Self.questionColumns) FROM detected_questions WHERE meeting_id = ?1 AND (?2 = 0 OR kept = 1) ORDER BY t, id
            """, [.integer(meetingID), .integer(keptOnly ? 1 : 0)])
        var out = rows.map(Self.question)
        let cited = out.flatMap { $0.answer?.sources ?? [] }
        let meetings = Set(cited.filter { $0.kind == .pastMeeting }.compactMap(\.meetingID))
        let sources = Set(cited.filter { $0.kind == .document }.compactMap(\.sourceID))
        let aliveMeetings = meetings.isEmpty ? [] : Set(try db.query("SELECT id FROM meetings WHERE id IN (SELECT value FROM json_each(?))", [.ids(Array(meetings))]).map { $0.int(0) })
        let aliveSources = sources.isEmpty ? [] : Set(try db.query("SELECT id FROM doc_sources WHERE id IN (SELECT value FROM json_each(?))", [.ids(Array(sources))]).map { $0.int(0) })
        for i in out.indices {
            guard let answer = out[i].answer else { continue }
            let gone: (AutoAnswerContent.Cite) -> Bool = { cite in
                switch cite.kind {
                case .pastMeeting: cite.meetingID.map { !aliveMeetings.contains($0) } ?? false
                case .document: cite.sourceID.map { !aliveSources.contains($0) } ?? false
                case .thisMeeting: false
                }
            }
            let current = answer.removing(where: gone) ?? answer
            if current.removedSources { out[i].sourceRemoved = true }
            out[i].answer = current.claims.isEmpty ? nil : current
        }
        return out
    }

    // MARK: Sources that go

    /// Rewrites the stored answers that cite something that no longer exists: a deleted meeting or a removed document source. The
    /// claims that rested on it and the prose are dropped (the text of a deleted meeting must not stay in another meeting's answer),
    /// and the search index of the kept ones is refreshed. Runs inside the deletion's transaction.
    func purgeDanglingQuestionCites() throws {
        try rewriteQuestionAnswers { cite in
            switch cite.kind {
            case .pastMeeting:
                guard let id = cite.meetingID else { return false }
                return try self.db.query("SELECT 1 FROM meetings WHERE id = ?", [.integer(id)]).isEmpty
            case .document:
                guard let id = cite.sourceID else { return false }
                return try self.db.query("SELECT 1 FROM doc_sources WHERE id = ?", [.integer(id)]).isEmpty
            case .thisMeeting:
                return false
            }
        }
    }

    /// A file of a document source left the index (deleted or gone): the answers that cited it lose those claims.
    public func purgeQuestionAnswers(documentSource source: Int64, relPath: String) async throws {
        let changed = try transaction {
            try rewriteQuestionAnswers { $0.kind == .document && $0.sourceID == source && $0.relPath == relPath }
        }
        if changed > 0 { try await commitEdit() }
    }

    @discardableResult
    func rewriteQuestionAnswers(dropping gone: (AutoAnswerContent.Cite) throws -> Bool) throws -> Int {
        let rows = try db.query("SELECT id, answer, kept FROM detected_questions WHERE answer IS NOT NULL")
        var changed = 0
        for row in rows {
            guard let content = row.optionalString(1).flatMap({ try? JSONDecoder().decode(AutoAnswerContent.self, from: Data($0.utf8)) }) else { continue }
            var failure: Error?
            let rewritten = content.removing { cite in
                do { return try gone(cite) } catch { failure = error; return false }
            }
            if let failure { throw failure }
            guard let rewritten else { continue }
            let id = row.int(0)
            try run("UPDATE detected_questions SET answer = ?, updated_at = ? WHERE id = ?", [Self.encode(rewritten), .real(Date.now.timeIntervalSince1970), .integer(id)])
            try run("DELETE FROM knowledge_fts WHERE rowid = ?", [.integer(id * 8 + 7)])
            if row.int(2) != 0 {
                try run("""
                    INSERT INTO knowledge_fts(rowid, text)
                        SELECT id * 8 + 7, text || ' ' || coalesce(json_extract(answer, '$.answer'), '') FROM detected_questions WHERE id = ?
                    """, [.integer(id)])
            }
            changed += 1
        }
        return changed
    }

    /// How many questions the meeting has (the meeting page shows the section only when there are some).
    public func detectedQuestionCount(_ meetingID: Int64) throws -> Int {
        Int(try db.query("SELECT COUNT(*) FROM detected_questions WHERE meeting_id = ?", [.integer(meetingID)])[0].int(0))
    }
}

extension AutoAnswerContent {
    /// The answer without the claims that rest on a citation `gone` says no longer exists, and with the prose rewritten from the
    /// claims that are left (what the removed source said must not stay in the prose). nil when nothing was removed. A content with
    /// no claims left has `removedSources` set, so the question can say its source was removed.
    func removing(where gone: (Cite) -> Bool) -> AutoAnswerContent? {
        if claims.isEmpty { return nil }
        let left = claims.filter { claim in !claim.cites.contains(where: gone) }
        guard left.count != claims.count else { return nil }
        var out = AutoAnswerContent(answer: ClaimProse.join(left.map(\.text)), claims: left, late: late)
        out.removedSources = true
        return out
    }
}
