// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

public struct LLMJob: Sendable, Identifiable, Hashable {
    /// Raw values are stored in `llm_jobs.kind`; "acta" is the earlier version's name for minutes and never changes.
    public enum Kind: String, Sendable { case minutes = "acta", embed }
    public enum State: String, Sendable { case queued, running, done, failed }
    public let id: Int64
    public let meetingID: Int64
    public let kind: Kind
    public let state: State
    public let attempts: Int
    /// Why the last attempt failed. nil for rows written before codes existed
    /// (see `lastError`).
    public let errorCode: JobErrorCode?
    /// Technical detail of the last failure (server message, status), not localized.
    public let errorDetail: String?
    /// Legacy free text written by the earlier version (`last_error` without a code).
    let legacyError: String?

    /// The last failure, ready to show: the code's text in the UI language,
    /// or an old row's stored text as it is.
    public var lastError: String? {
        guard let errorCode else { return legacyError }
        return errorCode.localizedDescription
    }
}

/// A segment with an ID to cite (what the model sees and what Swift validates).
public struct CitableSegment: Sendable, Hashable {
    public let id: Int64
    public let channel: Channel
    public let start: Double
    public let text: String
    /// Who said it; nil = no speaker data.
    public var speaker: SpeakerTag?
}

/// An entity offered to the model as a candidate (it may only choose these).
public struct CandidateEntity: Sendable, Hashable {
    public let id: Int64
    public let kind: EntityKind
    public let name: String
    public let aliases: [String]
}

/// Notes taken by the model while recording, as stored in `live_notes.json`.
/// The stored JSON keys are frozen (`puntos`, `decisiones`, `tareas`, `texto`,
/// `responsable`, `seg`); missing lists decode as empty.
public struct LiveNotesBatch: Sendable, Codable, Equatable {
    public struct Note: Sendable, Codable, Equatable {
        public var text: String
        public var segment: Int64?

        public init(text: String, segment: Int64?) {
            self.text = text
            self.segment = segment
        }

        private enum CodingKeys: String, CodingKey { case text = "texto", segment = "seg" }
    }

    public struct Task: Sendable, Codable, Equatable {
        public var text: String
        /// The owner as the model wrote it (a name, not an entity ID).
        public var owner: String?
        public var segment: Int64?

        public init(text: String, owner: String?, segment: Int64?) {
            self.text = text
            self.owner = owner
            self.segment = segment
        }

        private enum CodingKeys: String, CodingKey { case text = "texto", owner = "responsable", segment = "seg" }
    }

    /// Seconds from the start of the meeting when the notes were taken (not part of the JSON).
    public var t: Double = 0
    public var points: [Note] = []
    public var decisions: [Note] = []
    public var tasks: [Task] = []

    public init(t: Double = 0, points: [Note] = [], decisions: [Note] = [], tasks: [Task] = []) {
        self.t = t
        self.points = points
        self.decisions = decisions
        self.tasks = tasks
    }

    public var isEmpty: Bool { points.isEmpty && decisions.isEmpty && tasks.isEmpty }

    private enum CodingKeys: String, CodingKey { case points = "puntos", decisions = "decisiones", tasks = "tareas" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        points = try c.decodeIfPresent([Note].self, forKey: .points) ?? []
        decisions = try c.decodeIfPresent([Note].self, forKey: .decisions) ?? []
        tasks = try c.decodeIfPresent([Task].self, forKey: .tasks) ?? []
    }
}

extension MeetingStore {
    // MARK: Job queue (references, never text)

    /// Enqueues unless a job of the same kind is already pending for the meeting.
    public func enqueueJob(_ kind: LLMJob.Kind, meeting: Int64) async throws {
        try transaction {
            // An earlier failure must not hide the outcome of the new attempt.
            try run("DELETE FROM llm_jobs WHERE meeting_id = ? AND kind = ? AND state IN ('failed','done')", [.integer(meeting), .text(kind.rawValue)])
            try run("""
                INSERT OR IGNORE INTO llm_jobs(meeting_id, kind, state, created_at) VALUES (?, ?, 'queued', ?)
                """, [.integer(meeting), .text(kind.rawValue), .real(Date.now.timeIntervalSince1970)])
        }
        try await commitEdit()
    }

    /// Next ready job: embeddings first (fast), then minutes.
    public func nextJob(now: Date = .now) throws -> LLMJob? {
        try db.query("""
            SELECT \(Self.jobColumns) FROM llm_jobs
            WHERE state = 'queued' AND (not_before IS NULL OR not_before <= ?)
              AND meeting_id IS NOT ?
            ORDER BY CASE kind WHEN 'embed' THEN 0 ELSE 1 END, created_at LIMIT 1
            """, [.real(now.timeIntervalSince1970), activeMeetingID.map { .integer($0) }]).first.map(Self.job)
    }

    /// Embedding jobs that were put back for a while because the Mac was busy, hot or on battery (no error recorded) become due
    /// now: the Mac's state changed.
    public func releaseDeferredEmbeddings() async throws {
        try run("UPDATE llm_jobs SET not_before = NULL WHERE kind = 'embed' AND state = 'queued' AND not_before IS NOT NULL AND last_error_code IS NULL")
        try await commitEdit()
    }

    /// Time of the next deferred job (to wake the queue without polling).
    public func nextJobTime() throws -> Date? {
        try db.query("SELECT MIN(coalesce(not_before, 0)) FROM llm_jobs WHERE state = 'queued'").first?
            .optionalDouble(0).map(Date.init(timeIntervalSince1970:))
    }

    public func jobs(for meetingID: Int64? = nil) throws -> [LLMJob] {
        try db.query("""
            SELECT \(Self.jobColumns) FROM llm_jobs
            WHERE (?1 IS NULL OR meeting_id = ?1) AND state != 'done' ORDER BY created_at
            """, [meetingID.map { .integer($0) }]).map(Self.job)
    }

    public func pendingJobCount() throws -> Int {
        Int(try db.query("SELECT COUNT(*) FROM llm_jobs WHERE state IN ('queued','running')")[0].int(0))
    }

    /// Records a job's new state. `code`/`detail` describe a failure (the
    /// detail is technical text, never shown as the message); an attempt is
    /// counted when a failure is recorded and `countAttempt` is true.
    public func markJob(_ id: Int64, _ state: LLMJob.State, code: JobErrorCode? = nil, detail: String? = nil,
                        retryAt: Date? = nil, countAttempt: Bool = true) async throws {
        try run("""
            UPDATE llm_jobs SET state = ?1, last_error_code = ?2, last_error = ?3, not_before = ?4, updated_at = ?5,
                attempts = attempts + CASE WHEN ?7 = 1 AND ?1 IN ('failed','queued') AND ?2 IS NOT NULL THEN 1 ELSE 0 END
            WHERE id = ?6
            """, [.text(state.rawValue), code.map { .text($0.rawValue) }, detail.map { .text(String($0.prefix(300))) },
                  retryAt.map { .real($0.timeIntervalSince1970) }, .real(Date.now.timeIntervalSince1970), .integer(id),
                  .integer(countAttempt ? 1 : 0)])
        try await commitEdit()
    }

    /// Removes a job that has not started (cancelled by the user). Returns
    /// whether there was one.
    @discardableResult
    public func removeQueuedJob(meetingID: Int64, kind: LLMJob.Kind) async throws -> Bool {
        let found = try !db.query("SELECT 1 FROM llm_jobs WHERE meeting_id = ? AND kind = ? AND state = 'queued'",
                                  [.integer(meetingID), .text(kind.rawValue)]).isEmpty
        guard found else { return false }
        try run("DELETE FROM llm_jobs WHERE meeting_id = ? AND kind = ? AND state = 'queued'", [.integer(meetingID), .text(kind.rawValue)])
        try await commitEdit()
        return true
    }

    /// Removes one job row (a running job the user cancelled).
    public func removeJob(_ id: Int64) async throws {
        try run("DELETE FROM llm_jobs WHERE id = ?", [.integer(id)])
        try await commitEdit()
    }

    /// Forgets jobs of `kind` that failed for good, so they can be queued
    /// again (after the user changes the model settings).
    public func forgetFailedJobs(_ kind: LLMJob.Kind) async throws {
        try run("DELETE FROM llm_jobs WHERE kind = ? AND state = 'failed'", [.text(kind.rawValue)])
        try await commitEdit()
    }

    /// At launch: jobs left running (abrupt quit) go back to the queue.
    public func requeueInterruptedJobs() async throws {
        try run("UPDATE llm_jobs SET state = 'queued' WHERE state = 'running'")
        try await commitEdit()
    }

    static let jobColumns = "id, meeting_id, kind, state, attempts, last_error, last_error_code"

    private static func job(_ r: Row) -> LLMJob {
        let code = r.optionalString(6)
        return LLMJob(id: r.int(0), meetingID: r.int(1), kind: LLMJob.Kind(rawValue: r.string(2)) ?? .minutes,
                      state: LLMJob.State(rawValue: r.string(3)) ?? .queued, attempts: Int(r.int(4)),
                      errorCode: code.map { JobErrorCode(rawValue: $0) ?? .unknown },
                      errorDetail: code == nil ? nil : r.optionalString(5),
                      legacyError: code == nil ? r.optionalString(5) : nil)
    }

    // MARK: Embedding spaces

    /// The embedding spaces each meeting's chunks are in (normally one).
    public func chunkSpaces() throws -> [Int64: Set<EmbeddingSpace>] {
        var out: [Int64: Set<EmbeddingSpace>] = [:]
        for r in try db.query("SELECT DISTINCT meeting_id, model, dims FROM chunks") {
            out[r.int(0), default: []].insert(EmbeddingSpace(model: r.string(1), dimensions: Int(r.int(2))))
        }
        return out
    }

    /// Ended meetings that still have their transcript and could be embedded:
    /// no embedding job pending, and none that failed for good (it would
    /// only fail again; the user can retry by regenerating).
    public func embeddableMeetings() throws -> [MeetingStore.Meeting] {
        try db.query("""
            SELECT \(Self.meetingColumns) FROM meetings
            WHERE ended_at IS NOT NULL AND raw_purged_at IS NULL
              AND EXISTS (SELECT 1 FROM segments WHERE meeting_id = meetings.id)
              AND NOT EXISTS (SELECT 1 FROM llm_jobs j WHERE j.meeting_id = meetings.id AND j.kind = 'embed'
                              AND j.state IN ('queued','running','failed'))
            ORDER BY started_at DESC
            """).map { Self.meeting($0, languageAt: 4) }
    }

    // MARK: Prompt material

    /// Citable segments: in arrival order (`id`) for live notes (the prompt
    /// only grows at the end, which keeps the server's cache) or by time.
    public func citableSegments(_ meetingID: Int64, afterID: Int64 = 0, byArrival: Bool = false) throws -> [CitableSegment] {
        try db.query("SELECT s.id, s.speaker, s.start, s.text, \(Self.speakerColumns) FROM segments s \(Self.speakerJoins) WHERE s.meeting_id = ? AND s.id > ? AND \(Self.notEcho) ORDER BY "
                     + (byArrival ? "s.id" : "s.start, s.id"), [.integer(meetingID), .integer(afterID)]).map(Self.citable)
    }

    public func segmentsByIDs(_ ids: [Int64]) throws -> [CitableSegment] {
        try db.query("SELECT s.id, s.speaker, s.start, s.text, \(Self.speakerColumns) FROM segments s \(Self.speakerJoins) WHERE s.id IN (SELECT value FROM json_each(?)) ORDER BY s.meeting_id, s.start, s.id",
                     [.ids(ids)]).map(Self.citable)
    }

    /// Maps `id, speaker, start, text` and the `speakerColumns` that follow.
    static func citable(_ row: Row) -> CitableSegment {
        CitableSegment(id: row.int(0), channel: Channel(storedSpeaker: row.string(1)), start: row.double(2), text: row.string(3),
                       speaker: speakerTag(row, at: 4))
    }

    /// Candidates for the model: attendees, people named on the meeting's speakers, "Others", topics, the user (so a
    /// task owner named by the user's real name resolves even in a small
    /// window), series and what was already mentioned, then confirmed people and other entities (at
    /// most `limit`). Aliases equal to the name (in any case or accent) are left out.
    public func candidateEntities(_ meetingID: Int64, limit: Int = 120) throws -> [CandidateEntity] {
        try db.query("""
            WITH picked(id, pri) AS (
                SELECT entity_id, 0 FROM meeting_entities WHERE meeting_id = ?1
                UNION ALL SELECT entity_id, 0 FROM meeting_speakers
                    WHERE meeting_id = ?1 AND entity_id IS NOT NULL AND source = 'user'
                UNION ALL SELECT v, 0 FROM store_meta WHERE k = 'self_entity'
                UNION ALL SELECT j.value, 1 FROM meetings m JOIN series s ON s.id = m.series_id, json_each(s.default_entities) j WHERE m.id = ?1
                UNION ALL SELECT entity_id, 2 FROM mentions WHERE meeting_id = ?1
                UNION ALL SELECT id, 3 FROM entities WHERE kind = 'person' AND merged_into IS NULL AND confirmed = 1
                UNION ALL SELECT id, 4 FROM entities WHERE kind != 'person' AND merged_into IS NULL AND confirmed = 1
            )
            SELECT e.id, e.kind, e.name, (SELECT group_concat(a.alias, char(31)) FROM aliases a WHERE a.entity_id = e.id)
            FROM (SELECT id, MIN(pri) AS pri FROM picked GROUP BY id) p JOIN entities e ON e.id = p.id
            WHERE e.merged_into IS NULL
            ORDER BY p.pri, e.last_seen DESC LIMIT ?2
            """, [.integer(meetingID), .integer(Int64(limit))]).map { r in
            let name = r.string(2)
            let nameNorm = TextKeys.norm(name)
            let aliases = (r.optionalString(3) ?? "").split(separator: "\u{1F}").map(String.init).filter { TextKeys.norm($0) != nameNorm }
            return CandidateEntity(id: r.int(0), kind: EntityKind(rawValue: r.string(1)) ?? .topic, name: name, aliases: aliases)
        }
    }

    // MARK: Live notes

    /// Stores one batch of live notes (`json` in the `LiveNotesBatch` format).
    public func addLiveNotes(_ meetingID: Int64, at t: Double, json: String) async throws {
        try run("INSERT INTO live_notes(meeting_id, t, json) VALUES (?, ?, ?)", [.integer(meetingID), .real(t), .text(json)])
        try await commitEdit()
    }

    /// Live notes taken during the meeting, oldest first (empty once the raw
    /// text was purged). Unreadable rows are skipped.
    public func liveNotes(_ meetingID: Int64) throws -> [LiveNotesBatch] {
        try db.query("SELECT t, json FROM live_notes WHERE meeting_id = ? ORDER BY t, id", [.integer(meetingID)]).compactMap { row in
            guard var batch = try? JSONDecoder().decode(LiveNotesBatch.self, from: Data(row.string(1).utf8)) else { return nil }
            batch.t = row.double(0)
            return batch
        }
    }

    // MARK: Minutes from the model (already validated)

    /// Writes validated minutes in one transaction. It replaces what the model
    /// proposed before, never what the user wrote or edited (edited items
    /// become source 'user'), and skips proposals the meeting already
    /// covers: an item with the same normalized text, or a kept item (the
    /// user's, or a closed task) citing the same segment.
    /// Title and card are only set if the user had not written them; open
    /// questions are always kept in the card.
    @discardableResult
    public func applyMinutes(_ minutes: ValidatedMinutes, to meetingID: Int64) async throws -> [Int64] {
        // Later meetings with a suggestion that points into an item this rewrite deletes: their pass runs again.
        let pointing = try meetingsPointingIntoRewrite(of: meetingID)
        try transaction {
            try run("DELETE FROM decisions WHERE meeting_id = ? AND source = 'llm'", [.integer(meetingID)])
            try run("DELETE FROM tasks WHERE meeting_id = ? AND source = 'llm' AND status = 'open'", [.integer(meetingID)])
            try run("DELETE FROM mentions WHERE meeting_id = ? AND resolved_by = 'llm'", [.integer(meetingID)])
            // Everything left is the user's or a closed task.
            let keptDecisions = try db.query("SELECT text, segment_id FROM decisions WHERE meeting_id = ?", [.integer(meetingID)])
            var decisionTexts = Set(keptDecisions.map { TextKeys.norm($0.string(0)) })
            let decisionSegments = Set(keptDecisions.compactMap { $0.optionalInt(1) })
            let keptTasks = try db.query("SELECT text, segment_id FROM tasks WHERE meeting_id = ?", [.integer(meetingID)])
            var taskTexts = Set(keptTasks.map { TextKeys.norm($0.string(0)) })
            let taskSegments = Set(keptTasks.compactMap { $0.optionalInt(1) })
            let now = Date.now.timeIntervalSince1970
            for d in minutes.decisions where !decisionSegments.contains(d.segment) && decisionTexts.insert(TextKeys.norm(d.text)).inserted {
                try run("INSERT INTO decisions(meeting_id, segment_id, t, text, source, created_at, unconfirmed, unconfirmed_reason) VALUES (?, ?, ?, ?, 'llm', ?, ?, ?)",
                        [.integer(meetingID), .integer(d.segment), .real(d.t), .text(d.text), .real(now), .integer(d.unconfirmed ? 1 : 0),
                         d.unconfirmed ? d.doubt.map { .text($0) } : nil])
                try linkAbout(NodeRef(.decision, db.lastInsertRowID), segmentID: d.segment, meetingID: meetingID)
            }
            for t in minutes.tasks where !taskSegments.contains(t.segment) && taskTexts.insert(TextKeys.norm(t.text)).inserted {
                var owner: SQLiteValue?, speaker: SQLiteValue?, due: SQLiteValue?
                if let o = t.owner { owner = .integer(o) } else if let s = t.ownerSpeaker { speaker = .integer(s) }
                if let d = t.due { due = .real(d.timeIntervalSince1970) }
                let hasOwner = t.owner != nil || t.ownerSpeaker != nil
                try run("""
                    INSERT INTO tasks(meeting_id, segment_id, t, text, owner_id, due, source, created_at, unconfirmed, owner_uncertain, owner_speaker_id, due_day, unconfirmed_reason)
                    VALUES (?, ?, ?, ?, ?, ?, 'llm', ?, ?, ?, ?, ?, ?)
                    """, [.integer(meetingID), .integer(t.segment), .real(t.t), .text(t.text), owner, due, .real(now),
                          .integer(t.unconfirmed ? 1 : 0), .integer(hasOwner && t.ownerUncertain ? 1 : 0), speaker,
                          t.due.map { .text((t.dueDay ?? DueDay.containing($0, in: .current)).string) },
                          t.unconfirmed ? t.doubt.map { .text($0) } : nil])
                let id = db.lastInsertRowID
                try syncOwnerEdge(id, t.owner)
                try linkAbout(NodeRef(.task, id), segmentID: t.segment, meetingID: meetingID)
            }
            for m in minutes.mentions {
                try run("""
                    INSERT INTO mentions(entity_id, meeting_id, segment_id, t, surface, confidence, resolved_by)
                    SELECT ?, ?, ?, ?, ?, 0.8, 'llm'
                    WHERE NOT EXISTS (SELECT 1 FROM mentions WHERE meeting_id = ?2 AND segment_id = ?3 AND entity_id = ?1)
                    """, [.integer(m.entity), .integer(meetingID), .integer(m.segment), .real(m.t), .text(m.surface)])
            }
            let row = try db.query("SELECT title, card, card_source FROM meetings WHERE id = ?", [.integer(meetingID)]).first
            if (row?.optionalString(0) ?? "").isEmpty, !minutes.title.isEmpty {
                try run("UPDATE meetings SET title = ? WHERE id = ?", [.text(minutes.title), .integer(meetingID)])
            }
            if row?.optionalString(2) == "user", let json = row?.optionalString(1) {
                // The user's summary and topics stay; only the open questions are
                // refreshed. A card that cannot be read is left exactly as it is.
                if var card = try? JSONDecoder().decode(MeetingCard.self, from: Data(json.utf8)) {
                    card.openQuestions = minutes.openQuestions
                    try run("UPDATE meetings SET card = ? WHERE id = ?", [.text(try card.json()), .integer(meetingID)])
                }
            } else {
                let card = MeetingCard(summary: minutes.summary, topics: minutes.topics, openQuestions: minutes.openQuestions)
                try run("UPDATE meetings SET card = ?, card_version = card_version + 1, card_source = 'llm' WHERE id = ?",
                        [.text(try card.json()), .integer(meetingID)])
            }
        }
        try await commitEdit()
        return pointing
    }

    public func cardSource(_ meetingID: Int64) throws -> String? {
        try db.query("SELECT card_source FROM meetings WHERE id = ?", [.integer(meetingID)]).first?.optionalString(0)
    }

    /// Ended meetings with a transcript and no card from the model (queued when a model server is set up).
    public func meetingsWithoutMinutes() throws -> [Int64] {
        try db.query("""
            SELECT id FROM meetings WHERE ended_at IS NOT NULL AND raw_purged_at IS NULL AND (card_source IS NULL)
              AND EXISTS (SELECT 1 FROM segments WHERE meeting_id = meetings.id) ORDER BY started_at DESC
            """).map { $0.int(0) }
    }

    /// Ended meetings whose notes went through the notepad's passes (some note has an expansion row) and that still have a
    /// note with none, or one that is waiting or failed (never one the user edited or removed, nor one the transcript
    /// does not discuss). Meetings from before the notepad, whose notes have no rows at all, are left to "Regenerate".
    public func meetingsWithUnexpandedNotes() throws -> [Int64] {
        try db.query("""
            SELECT DISTINCT m.id FROM meetings m JOIN notes n ON n.meeting_id = m.id LEFT JOIN note_expansions e ON e.note_id = n.id
            WHERE m.ended_at IS NOT NULL AND m.raw_purged_at IS NULL AND EXISTS (SELECT 1 FROM segments WHERE meeting_id = m.id)
              AND EXISTS (SELECT 1 FROM note_expansions x WHERE x.meeting_id = m.id)
              AND (e.note_id IS NULL OR (e.state IN ('pending', 'failed') AND e.user_edited = 0))
            ORDER BY m.started_at DESC
            """).map { $0.int(0) }
    }
}
