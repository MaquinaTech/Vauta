// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

public struct MeetingMark: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let meetingID: Int64
    public let t: Double
    public let label: String?

    public init(id: Int64, meetingID: Int64, t: Double, label: String? = nil) {
        self.id = id; self.meetingID = meetingID; self.t = t; self.label = label
    }
}

public struct MeetingNote: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let meetingID: Int64
    public let t: Double
    public let text: String
    /// Typed after the recording stopped (the whole meeting is its search space).
    public let addedAfter: Bool
    /// When the user last changed the text; nil if never.
    public let editedAt: Date?

    public init(id: Int64, meetingID: Int64, t: Double, text: String, addedAfter: Bool = false, editedAt: Date? = nil) {
        self.id = id; self.meetingID = meetingID; self.t = t; self.text = text
        self.addedAfter = addedAfter; self.editedAt = editedAt
    }
}

public struct Decision: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let meetingID: Int64
    public let segmentID: Int64?
    public let t: Double?
    public var text: String
    /// "user" or "llm". An LLM item the user edits becomes "user", so
    /// regenerating the minutes never replaces it.
    public let source: String
    /// The model proposed it and its figures or dates are not in the segment it cites (see `MinutesVerifier`).
    /// Never true for what the user wrote or edited.
    public var unconfirmed = false
    /// Why it is unconfirmed (`UnconfirmedReason`); nil for a row stored before the reason existed and when it is not unconfirmed.
    public var unconfirmedReason: String?
    /// Left out of the ranked list rather than doubted by a check on its words: the minutes show it in "Other possible items".
    public var isRankedOut: Bool { unconfirmed && UnconfirmedReason.isRankedOut(unconfirmedReason) }
}

/// The stored codes of `unconfirmed_reason` (never meeting text). Anything that is not ranked out (`rank` or `rank:<code>`) is a doubt from a check on the item's words.
public enum UnconfirmedReason {
    /// The item did not rank among the minutes' items. Only a question or unbacked figures keep their own reason instead.
    public static let rankedOut = "rank"

    /// The reason stored for an item that ranked out: `rank`, followed by the soft doubt the evidence check had put on it (`rank:noAgreement`),
    /// which the minutes do not show and the evaluation can still read.
    public static func rankedOut(after soft: String?) -> String { soft.map { "\(rankedOut):\($0)" } ?? rankedOut }

    public static func isRankedOut(_ reason: String?) -> Bool { reason == rankedOut || reason?.hasPrefix(rankedOut + ":") == true }

    /// The user corrected the line the item cites after the minutes were written, where the item relied on it
    /// (`MeetingStore.correctSegment`).
    public static let edited = "edited"
}

public struct TaskItem: Sendable, Identifiable, Hashable {
    public enum Status: String, Sendable, CaseIterable { case open, done, dropped }
    public let id: Int64
    public let meetingID: Int64?
    public let segmentID: Int64?
    public let t: Double?
    public var text: String
    public var ownerID: Int64?
    public var ownerName: String?
    public var due: Date?
    public var status: Status
    public let source: String
    public let createdAt: Date
    /// Title of the meeting the task comes from (for lists).
    public let meetingTitle: String?
    /// The model proposed it and its figures, date or owner name are not in the segment it cites.
    public var unconfirmed = false
    /// Why it is unconfirmed (`UnconfirmedReason`); nil for a row stored before the reason existed and when it is not unconfirmed.
    public var unconfirmedReason: String?
    /// Left out of the ranked list rather than doubted by a check on its words (see `Decision.isRankedOut`).
    public var isRankedOut: Bool { unconfirmed && UnconfirmedReason.isRankedOut(unconfirmedReason) }
    /// The owner was not backed by a confident speaker label or by their name in the cited words.
    public var ownerUncertain = false
    /// The owner is a speaker nobody has named (`ownerID` is nil and `ownerName` is the speaker's label).
    public var ownerSpeakerID: Int64?
    /// The owner shown (a person, or a speaker's label) is marked "not confirmed": the words do not back it.
    public var ownerMarked: Bool { (ownerID != nil || ownerSpeakerID != nil) && ownerUncertain }
    /// The calendar day the task is due (`tasks.due_day`): what reminders and emails use. nil for a task with no due date.
    public var dueDay: DueDay?

    /// The day the tables show and compare: `dueDay`, else the day of `due` in `zone` (a task stored before the day existed).
    public func displayDay(in zone: TimeZone = .current) -> DueDay? { dueDay ?? due.map { DueDay.containing($0, in: zone) } }
}

public struct KnowledgeHit: Sendable, Identifiable, Hashable {
    public enum Kind: Int, Sendable { case decision = 1, task = 2, note = 3, entityNote = 4, summary = 5, noteExpansion = 6
        /// A question heard in the meeting that the person kept (with its answer).
        case question = 7 }
    public var id: Int64 { rowid }
    public let rowid: Int64
    public let kind: Kind
    public let refID: Int64
    public let meetingID: Int64?
    public let t: Double?
    /// Text around the match; matched terms are wrapped in the
    /// `SearchHighlight` markers, like transcript search snippets.
    public let snippet: String

    /// Aliases of `SearchHighlight.start`/`end`.
    public static let highlightStart = SearchHighlight.start
    public static let highlightEnd = SearchHighlight.end
}

/// Marks, notes, decisions and tasks: what the user adds to a meeting (and
/// what the local model proposes and the user reviews).
extension MeetingStore {
    // MARK: Marks and notes (also while recording: they go to the journal)

    @discardableResult
    public func addMark(_ meetingID: Int64, at t: Double, label: String? = nil) async throws -> Int64 {
        try run("INSERT INTO marks(meeting_id, t, label) VALUES (?, ?, ?)",
                [.integer(meetingID), .real(max(0, t)), label.flatMap { Self.optionalText($0, max: 200) }])
        let id = db.lastInsertRowID
        try await commitEdit()
        return id
    }

    public func marks(_ meetingID: Int64) throws -> [MeetingMark] {
        try db.query("SELECT id, meeting_id, t, label FROM marks WHERE meeting_id = ? ORDER BY t", [.integer(meetingID)]).map {
            MeetingMark(id: $0.int(0), meetingID: $0.int(1), t: $0.double(2), label: $0.optionalString(3))
        }
    }

    public func deleteMark(_ id: Int64) async throws {
        try run("DELETE FROM marks WHERE id = ?", [.integer(id)])
        try await commitEdit()
    }

    @discardableResult
    public func addNote(_ meetingID: Int64, at t: Double, text: String, addedAfter: Bool = false) async throws -> Int64 {
        let clean = Self.clean(text, max: 8000)
        guard !clean.isEmpty else { throw KnowledgeError.emptyNote }
        try run("INSERT INTO notes(meeting_id, t, text, added_after) VALUES (?, ?, ?, ?)",
                [.integer(meetingID), .real(max(0, t)), .text(clean), .integer(addedAfter ? 1 : 0)])
        let id = db.lastInsertRowID
        try await commitEdit()
        return id
    }

    public func updateNote(_ id: Int64, text: String) async throws {
        let clean = Self.clean(text, max: 8000)
        if clean.isEmpty {
            try run("DELETE FROM notes WHERE id = ?", [.integer(id)])
        } else {
            try run("UPDATE notes SET edited_at = CASE WHEN text IS ?1 THEN edited_at ELSE ?3 END, text = ?1 WHERE id = ?2",
                    [.text(clean), .integer(id), .real(Date.now.timeIntervalSince1970)])
        }
        pendingCompaction = true
        try await commitEdit()
    }

    public func notes(_ meetingID: Int64) throws -> [MeetingNote] {
        try db.query("SELECT id, meeting_id, t, text, added_after, edited_at FROM notes WHERE meeting_id = ? ORDER BY t, id",
                     [.integer(meetingID)]).map(Self.note)
    }

    static func note(_ row: Row) -> MeetingNote {
        MeetingNote(id: row.int(0), meetingID: row.int(1), t: row.double(2), text: row.string(3), addedAfter: row.int(4) != 0,
                    editedAt: row.optionalDouble(5).map { Date(timeIntervalSince1970: $0) })
    }

    public func setItemsEditedHandler(_ handler: (@Sendable (Int64) -> Void)?) { itemsEditedHandler = handler }

    /// The meeting a task or decision belongs to (nil when it has none or does not exist).
    private func meetingOf(task id: Int64) throws -> Int64? { try db.query("SELECT meeting_id FROM tasks WHERE id = ?", [.integer(id)]).first?.optionalInt(0) }
    private func meetingOf(decision id: Int64) throws -> Int64? { try db.query("SELECT meeting_id FROM decisions WHERE id = ?", [.integer(id)]).first?.optionalInt(0) }

    // MARK: Decisions

    /// A decision citing a segment gets "about" edges to the entities named in it.
    @discardableResult
    public func addDecision(_ meetingID: Int64, text: String, segmentID: Int64? = nil, t: Double? = nil, source: String = "user") async throws -> Int64 {
        let clean = Self.clean(text, max: 2000)
        guard !clean.isEmpty else { throw KnowledgeError.emptyDecision }
        let id: Int64 = try transaction {
            try run("INSERT INTO decisions(meeting_id, segment_id, t, text, source, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                    [.integer(meetingID), segmentID.map { .integer($0) }, t.map { .real($0) }, .text(clean), .text(source),
                     .real(Date.now.timeIntervalSince1970)])
            let id = db.lastInsertRowID
            try linkAbout(NodeRef(.decision, id), segmentID: segmentID, meetingID: meetingID)
            return id
        }
        try await commitEdit()
        itemsEditedHandler?(meetingID)
        return id
    }

    /// Edits a decision (empty text deletes it). Changing the text of a
    /// model-proposed decision makes it the user's.
    public func updateDecision(_ id: Int64, text: String) async throws {
        let clean = Self.clean(text, max: 2000)
        let meeting = try meetingOf(decision: id)
        defer { if let meeting { itemsEditedHandler?(meeting) } }
        if clean.isEmpty {
            try run("DELETE FROM decisions WHERE id = ?", [.integer(id)])
        } else {
            try transaction {
                let before = try db.query("SELECT meeting_id, text FROM decisions WHERE id = ?", [.integer(id)]).first
                try run("""
                    UPDATE decisions SET text = ?1, source = CASE WHEN text IS ?1 THEN source ELSE 'user' END,
                        unconfirmed = CASE WHEN text IS ?1 THEN unconfirmed ELSE 0 END,
                        unconfirmed_reason = CASE WHEN text IS ?1 THEN unconfirmed_reason ELSE NULL END WHERE id = ?2
                    """,
                        [.text(clean), .integer(id)])
                // A substantial edit returns the decision's confirmed links to suggestions.
                if let before { try linkEdited(kind: .decision, id: id, old: before.string(1), new: clean, meetingID: before.int(0)) }
            }
        }
        pendingCompaction = true
        try await commitEdit()
    }

    public func deleteDecision(_ id: Int64) async throws { try await updateDecision(id, text: "") }

    /// The user checked a decision the transcript did not back and it is right: the mark goes, and the decision is
    /// the user's from then on (as when they edit it).
    public func markDecisionChecked(_ id: Int64) async throws {
        defer { if let meeting = try? meetingOf(decision: id) { itemsEditedHandler?(meeting) } }
        try run("UPDATE decisions SET unconfirmed = 0, unconfirmed_reason = NULL, source = 'user' WHERE id = ?", [.integer(id)])
        try await commitEdit()
    }

    /// The same for a task: neither its text, due date nor owner is marked any more, and later changes of speakers
    /// do not mark the owner again (the user's own tasks are left alone).
    public func markTaskChecked(_ id: Int64) async throws {
        defer { if let meeting = try? meetingOf(task: id) { itemsEditedHandler?(meeting) } }
        try run("UPDATE tasks SET unconfirmed = 0, unconfirmed_reason = NULL, owner_uncertain = 0, source = 'user' WHERE id = ?", [.integer(id)])
        try await commitEdit()
    }

    public func decisions(_ meetingID: Int64) throws -> [Decision] {
        try db.query("SELECT id, meeting_id, segment_id, t, text, source, unconfirmed, unconfirmed_reason FROM decisions WHERE meeting_id = ? ORDER BY coalesce(t, 1e18), id",
                     [.integer(meetingID)]).map {
            Decision(id: $0.int(0), meetingID: $0.int(1), segmentID: $0.optionalInt(2), t: $0.optionalDouble(3), text: $0.string(4),
                     source: $0.string(5), unconfirmed: $0.int(6) != 0, unconfirmedReason: $0.optionalString(7))
        }
    }

    // MARK: Tasks

    @discardableResult
    public func addTask(_ meetingID: Int64?, text: String, ownerID: Int64? = nil, due: Date? = nil, dueDay: DueDay? = nil,
                        segmentID: Int64? = nil, t: Double? = nil, source: String = "user") async throws -> Int64 {
        let clean = Self.clean(text, max: 2000)
        guard !clean.isEmpty else { throw KnowledgeError.emptyTask }
        let id: Int64 = try transaction {
            try run("""
                INSERT INTO tasks(meeting_id, segment_id, t, text, owner_id, due, source, created_at, due_day) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [meetingID.map { .integer($0) }, segmentID.map { .integer($0) }, t.map { .real($0) }, .text(clean),
                      ownerID.map { .integer($0) }, due.map { .real($0.timeIntervalSince1970) }, .text(source),
                      .real(Date.now.timeIntervalSince1970),
                      (due == nil ? nil : (dueDay ?? due.map { DueDay.containing($0, in: .current) })).map { .text($0.string) }])
            let id = db.lastInsertRowID
            try syncOwnerEdge(id, ownerID)
            if let meetingID { try linkAbout(NodeRef(.task, id), segmentID: segmentID, meetingID: meetingID) }
            return id
        }
        try await commitEdit()
        if let meetingID { itemsEditedHandler?(meetingID) }
        return id
    }

    /// Saves an edited task (empty text deletes it). Changing the text, owner
    /// or due date of a model-proposed task makes it the user's; a status
    /// change alone does not.
    public func updateTask(_ task: TaskItem) async throws {
        let clean = Self.clean(task.text, max: 2000)
        guard !clean.isEmpty else { return try await deleteTask(task.id) }
        defer { if let meeting = try? meetingOf(task: task.id) { itemsEditedHandler?(meeting) } }
        try transaction {
            let before = try db.query("SELECT meeting_id, text FROM tasks WHERE id = ?", [.integer(task.id)]).first
            try run("""
                UPDATE tasks SET text = ?1, owner_id = ?2, due = ?3, status = ?4,
                    done_at = CASE WHEN ?4 = 'open' THEN NULL ELSE coalesce(done_at, ?5) END,
                    source = CASE WHEN text IS ?1 AND owner_id IS ?2 AND due IS ?3 THEN source ELSE 'user' END,
                    unconfirmed = CASE WHEN text IS ?1 AND owner_id IS ?2 AND due IS ?3 THEN unconfirmed ELSE 0 END,
                    unconfirmed_reason = CASE WHEN text IS ?1 AND owner_id IS ?2 AND due IS ?3 THEN unconfirmed_reason ELSE NULL END,
                    owner_uncertain = CASE WHEN owner_id IS ?2 THEN owner_uncertain ELSE 0 END,
                    owner_speaker_id = CASE WHEN owner_id IS ?2 THEN owner_speaker_id ELSE NULL END,
                    due_day = CASE WHEN due IS ?3 THEN due_day ELSE ?7 END
                WHERE id = ?6
                """, [.text(clean), task.ownerID.map { .integer($0) }, task.due.map { .real($0.timeIntervalSince1970) },
                      .text(task.status.rawValue), .real(Date.now.timeIntervalSince1970), .integer(task.id),
                      task.due.map { .text(DueDay.containing($0, in: .current).string) }])
            try syncOwnerEdge(task.id, task.ownerID)
            if let before, let meeting = before.optionalInt(0) { try linkEdited(kind: .task, id: task.id, old: before.string(1), new: clean, meetingID: meeting) }
        }
        pendingCompaction = true
        try await commitEdit()
    }

    public func setTaskStatus(_ id: Int64, _ status: TaskItem.Status) async throws {
        try run("UPDATE tasks SET status = ?1, done_at = CASE WHEN ?1 = 'open' THEN NULL ELSE ?2 END WHERE id = ?3",
                [.text(status.rawValue), .real(Date.now.timeIntervalSince1970), .integer(id)])
        try await commitEdit()
    }

    /// A task's status before a change, so Undo can put it back.
    public struct TaskStatusChange: Sendable, Equatable {
        public let id: Int64
        public let status: TaskItem.Status
    }

    /// Sets the status of several tasks at once (a chain marked done) and returns what each had before, in the order given. One transaction: all
    /// change or none.
    @discardableResult
    public func setTaskStatuses(_ ids: [Int64], _ status: TaskItem.Status) async throws -> [TaskStatusChange] {
        var before: [TaskStatusChange] = []
        let now = Date.now.timeIntervalSince1970
        try transaction {
            for id in ids {
                guard let current = try db.query("SELECT status FROM tasks WHERE id = ?", [.integer(id)]).first.flatMap({ TaskItem.Status(rawValue: $0.string(0)) }) else { continue }
                before.append(TaskStatusChange(id: id, status: current))
                try run("UPDATE tasks SET status = ?1, done_at = CASE WHEN ?1 = 'open' THEN NULL ELSE ?2 END WHERE id = ?3",
                        [.text(status.rawValue), .real(now), .integer(id)])
            }
        }
        try await commitEdit()
        return before
    }

    /// Puts statuses back as `setTaskStatuses` returned them (Edit › Undo of marking a chain done).
    public func restoreTaskStatuses(_ changes: [TaskStatusChange]) async throws {
        let now = Date.now.timeIntervalSince1970
        try transaction {
            for change in changes {
                try run("UPDATE tasks SET status = ?1, done_at = CASE WHEN ?1 = 'open' THEN NULL ELSE ?2 END WHERE id = ?3",
                        [.text(change.status.rawValue), .real(now), .integer(change.id)])
            }
        }
        try await commitEdit()
    }

    public func deleteTask(_ id: Int64) async throws {
        let meeting = try meetingOf(task: id)
        defer { if let meeting { itemsEditedHandler?(meeting) } }
        try run("DELETE FROM tasks WHERE id = ?", [.integer(id)])
        pendingCompaction = true
        try await commitEdit()
    }

    private static let taskColumns = """
        SELECT t.id, t.meeting_id, t.segment_id, t.t, t.text, t.owner_id, e.name, t.due, t.status, t.source, t.created_at, mt.title, mt.started_at,
               t.owner_id IS (SELECT v FROM store_meta WHERE k = 'self_entity'), t.unconfirmed, t.owner_uncertain,
               CASE WHEN t.owner_id IS NULL THEN t.owner_speaker_id END, ms.channel, ms.ordinal, t.due_day, t.unconfirmed_reason
        FROM tasks t LEFT JOIN entities e ON e.id = t.owner_id LEFT JOIN meetings mt ON mt.id = t.meeting_id
        LEFT JOIN meeting_speakers ms ON ms.id = t.owner_speaker_id AND t.owner_id IS NULL
        """

    public func tasks(_ meetingID: Int64) throws -> [TaskItem] {
        try db.query(Self.taskColumns + " WHERE t.meeting_id = ? ORDER BY coalesce(t.t, 1e18), t.id", [.integer(meetingID)]).map(Self.task)
    }

    /// The tasks with these ids, in any order (the members of a chain).
    public func tasks(ids: [Int64]) throws -> [TaskItem] {
        guard !ids.isEmpty else { return [] }
        return try db.query(Self.taskColumns + " WHERE t.id IN (SELECT value FROM json_each(?))", [.ids(ids)]).map(Self.task)
    }

    /// Open tasks (optionally of one person), by due date. Uses the partial
    /// index `tasks_open`.
    public func openTasks(owner: Int64? = nil) throws -> [TaskItem] {
        let sql = owner == nil
            ? Self.taskColumns + " WHERE t.status = 'open' ORDER BY t.due IS NULL, t.due, t.created_at"
            : Self.taskColumns + " WHERE t.status = 'open' AND t.owner_id = ? ORDER BY t.due IS NULL, t.due, t.created_at"
        return try db.query(sql, owner.map { [.integer($0)] } ?? []).map(Self.task)
    }

    private static func task(_ r: Row) -> TaskItem {
        let title: String? = r.optionalDouble(12).map { started in
            Meeting.displayTitle(r.optionalString(11), startedAt: Date(timeIntervalSince1970: started))
        }
        // An owner who is a speaker nobody named is shown by the speaker's label ("Speaker 2"); naming the speaker later shows the name.
        let speakerLabel: String? = r.optionalString(17).flatMap { channel in
            r.optionalInt(18).map { MeetingSpeaker.defaultLabel(channel: Channel(storedSpeaker: channel), ordinal: Int($0)) }
        }
        return TaskItem(id: r.int(0), meetingID: r.optionalInt(1), segmentID: r.optionalInt(2), t: r.optionalDouble(3), text: r.string(4),
                        ownerID: r.optionalInt(5), ownerName: r.optionalString(6).map { Self.displayName($0, isSelf: r.int(13) != 0) } ?? speakerLabel,
                        due: r.optionalDouble(7).map(Date.init(timeIntervalSince1970:)),
                        status: TaskItem.Status(rawValue: r.string(8)) ?? .open, source: r.string(9),
                        createdAt: Date(timeIntervalSince1970: r.double(10)), meetingTitle: title,
                        unconfirmed: r.int(14) != 0, unconfirmedReason: r.optionalString(20), ownerUncertain: r.int(15) != 0, ownerSpeakerID: r.optionalInt(16),
                        dueDay: r.optionalString(19).flatMap { DueDay($0) })
    }

    /// Owner edge (task → person), always equal to `owner_id`.
    func syncOwnerEdge(_ taskID: Int64, _ ownerID: Int64?) throws {
        try run("DELETE FROM relations WHERE src_kind = 'task' AND src_id = ? AND rel = 'owner'", [.integer(taskID)])
        if let ownerID {
            try run("INSERT OR IGNORE INTO relations(src_kind, src_id, rel, dst_kind, dst_id, source) VALUES ('task', ?, 'owner', 'entity', ?, 'auto')",
                    [.integer(taskID), .integer(ownerID)])
        }
    }

    /// "About" edges from a decision or task to what its segment names.
    func linkAbout(_ node: NodeRef, segmentID: Int64?, meetingID: Int64) throws {
        guard let segmentID else { return }
        try run("""
            INSERT OR IGNORE INTO relations(src_kind, src_id, rel, dst_kind, dst_id, meeting_id, source)
            SELECT ?, ?, 'about', 'entity', entity_id, ?, 'auto' FROM mentions WHERE segment_id = ? GROUP BY entity_id
            """, [.text(node.kind.rawValue), .integer(node.id), .integer(meetingID), .integer(segmentID)])
    }

    // MARK: Knowledge search

    /// Decisions, tasks, notes, entity notes and meeting summaries
    /// (accent-insensitive, by prefix). As in `search`, input is never parsed
    /// as FTS5 syntax, and a query in a script written without spaces is matched
    /// by substring (`SearchWords`), newest meetings first. `meetings` limits the
    /// search to those meetings (in SQL, so a scoped search returns up to `limit` hits of its own).
    public func searchKnowledge(_ text: String, in meetings: [Int64]? = nil, limit: Int = 50) throws -> [KnowledgeHit] {
        guard let query = SearchWords(text) else { return [] }
        let substring = query.bySubstring
        return try db.query("""
            SELECT rowid, snip, meeting, t FROM (
                SELECT f.rowid AS rowid, \(substring ? "0" : "f.rank") AS rank,
                       \(substring ? "f.text" : SearchHighlight.snippetSQL("knowledge_fts")) AS snip,
                       CASE f.rowid % 8 WHEN 1 THEN (SELECT meeting_id FROM decisions WHERE id = f.rowid / 8)
                                        WHEN 2 THEN (SELECT meeting_id FROM tasks WHERE id = f.rowid / 8)
                                        WHEN 3 THEN (SELECT meeting_id FROM notes WHERE id = f.rowid / 8)
                                        WHEN 6 THEN (SELECT meeting_id FROM note_expansions WHERE note_id = f.rowid / 8)
                                        WHEN 7 THEN (SELECT meeting_id FROM detected_questions WHERE id = f.rowid / 8)
                                        WHEN 5 THEN f.rowid / 8 END AS meeting,
                       CASE f.rowid % 8 WHEN 1 THEN (SELECT t FROM decisions WHERE id = f.rowid / 8)
                                        WHEN 2 THEN (SELECT t FROM tasks WHERE id = f.rowid / 8)
                                        WHEN 3 THEN (SELECT t FROM notes WHERE id = f.rowid / 8)
                                        WHEN 6 THEN (SELECT t FROM notes WHERE id = f.rowid / 8)
                                        WHEN 7 THEN (SELECT t FROM detected_questions WHERE id = f.rowid / 8) END AS t
                FROM knowledge_fts f WHERE \(substring ? SearchWords.containsAll("f.text", param: 1) : "knowledge_fts MATCH ?1"))
            WHERE ?3 IS NULL OR meeting IN (SELECT value FROM json_each(?3))
            ORDER BY \(substring ? "meeting DESC, t" : "rank") LIMIT ?2
            """, [.text(substring ? query.json : query.match), .integer(Int64(limit)), meetings.map { .ids($0) }]).compactMap { row in
            guard let kind = KnowledgeHit.Kind(rawValue: Int(row.int(0) % 8)) else { return nil }
            let snippet = substring ? SearchHighlight.snippet(row.string(1), marking: query.words) : row.string(1)
            return KnowledgeHit(rowid: row.int(0), kind: kind, refID: row.int(0) / 8, meetingID: row.optionalInt(2),
                                t: row.optionalDouble(3), snippet: snippet)
        }
    }
}
