// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The notepad's storage: the user's shorthand notes and the expansions the model wrote from them.
///
/// The one rule: `notes.text` is only ever written by the user's own edits (`addNote`, `updateNote`, `restoreNote`).
/// Everything a model produces goes to `note_expansions`, and a test fails if code under `LLM/` writes `notes`.
extension MeetingStore {
    /// How a pass ended for one note.
    public enum ExpansionOutcome: Sendable, Equatable {
        /// The verified sentences; none means the transcript does not discuss the note (`not_found`).
        case sentences([NoteExpansion.Sentence])
        /// Failed for good in this pass (stored as `failed` with its code).
        case failed(code: String)
        /// A failed attempt that will be tried again (stored as `pending` with its code).
        case retry(code: String)
    }

    public enum ExpansionWrite: Sendable, Equatable {
        case written
        /// Nothing changed: the user edited the expansion, or the existing one is as good.
        case kept
        case noteGone
    }

    static let expansionColumns = "note_id, meeting_id, state, pass, sentences, plain, source_key, upto_segment, user_edited, previous, error_code, updated_at"

    private static func decodeSentences(_ json: String?) -> [NoteExpansion.Sentence] {
        guard let json, let list = try? JSONDecoder().decode([NoteExpansion.Sentence].self, from: Data(json.utf8)) else { return [] }
        return list
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(value)) ?? Data("[]".utf8), as: UTF8.self)
    }

    static func expansion(_ r: Row) -> NoteExpansion {
        NoteExpansion(noteID: r.int(0), meetingID: r.int(1), state: NoteExpansion.State(rawValue: r.string(2)) ?? .failed,
                      pass: NoteExpansion.Pass(rawValue: r.string(3)) ?? .live, sentences: decodeSentences(r.optionalString(4)),
                      plain: r.string(5), sourceKey: r.string(6), uptoSegment: r.int(7), userEdited: r.int(8) != 0,
                      previous: r.optionalString(9).flatMap { try? JSONDecoder().decode(NoteExpansion.Previous.self, from: Data($0.utf8)) },
                      errorCode: r.optionalString(10), updatedAt: Date(timeIntervalSince1970: r.double(11)))
    }

    // MARK: Reading

    /// The notes of a meeting, each with its expansion, in the order they were taken.
    public func noteRows(_ meetingID: Int64) throws -> [NoteRow] {
        let found = try db.query("SELECT \(Self.expansionColumns) FROM note_expansions WHERE meeting_id = ?", [.integer(meetingID)])
            .map(Self.expansion)
        let expansions = Dictionary(found.map { ($0.noteID, $0) }, uniquingKeysWith: { a, _ in a })
        return try notes(meetingID).map { NoteRow(note: $0, expansion: expansions[$0.id]) }
    }

    public func expansion(of noteID: Int64) throws -> NoteExpansion? {
        try db.query("SELECT \(Self.expansionColumns) FROM note_expansions WHERE note_id = ?", [.integer(noteID)]).first.map(Self.expansion)
    }

    /// The notes a pass has to expand: no expansion yet, one that is waiting, failed or found nothing, one written from
    /// an older text of the note, and (at the end of the meeting) every provisional result of the live pass. Notes
    /// the user dismissed and expansions the user edited are never included.
    public func notesNeedingExpansion(_ meetingID: Int64, includingLive: Bool) throws -> [MeetingNote] {
        try noteRows(meetingID).filter { row in
            guard let e = row.expansion else { return true }
            if e.state == .dismissed || e.userEdited { return false }
            if e.state != .done || row.isStale { return true }
            return includingLive && e.pass == .live
        }.map(\.note)
    }

    /// The IDs that still exist in the transcript (retention may have purged the rest).
    public func existingSegmentIDs(_ ids: [Int64]) throws -> Set<Int64> {
        guard !ids.isEmpty else { return [] }
        return Set(try db.query("SELECT id FROM segments WHERE id IN (SELECT value FROM json_each(?))", [.ids(ids)]).map { $0.int(0) })
    }

    // MARK: Writing a pass

    /// Stores what a pass wrote for a note. `sourceKey` is the note text the pass read: if the user changed it
    /// meanwhile, the result shows as out of date. An expansion the user edited or removed is never replaced
    /// (unless `replacingEdited`, the user's own "Expand Again", which keeps the edit as the version to go back to). The old
    /// version is kept as `previous`. A failure never replaces a good expansion, and "not found" never replaces a
    /// current one.
    @discardableResult
    public func saveExpansion(noteID: Int64, pass: NoteExpansion.Pass, outcome: ExpansionOutcome, sourceKey: String,
                              uptoSegment: Int64 = 0, replacingEdited: Bool = false) async throws -> ExpansionWrite {
        var codeSaved = false
        let result: ExpansionWrite = try transaction {
            codeSaved = false
            guard let note = try db.query("SELECT meeting_id FROM notes WHERE id = ?", [.integer(noteID)]).first else { return .noteGone }
            let existing = try db.query("SELECT \(Self.expansionColumns) FROM note_expansions WHERE note_id = ?", [.integer(noteID)])
                .first.map(Self.expansion)
            let now = Date.now.timeIntervalSince1970
            if let existing, !replacingEdited, existing.userEdited || existing.state == .dismissed { return .kept }
            let hadText = existing.map { $0.state == .done && !$0.sentences.isEmpty } ?? false
            var state = NoteExpansion.State.failed
            var sentences: [NoteExpansion.Sentence] = []
            var code: String?
            switch outcome {
            case .sentences(let list):
                sentences = list
                state = list.isEmpty ? .notFound : .done
                if list.isEmpty, hadText, existing?.sourceKey == sourceKey { return .kept }
            case .failed(let c):
                state = .failed; code = c
            case .retry(let c):
                state = .pending; code = c
            }
            if state == .failed || state == .pending {
                // Nothing good is lost: the old expansion stays and only remembers the error.
                if hadText {
                    try run("UPDATE note_expansions SET error_code = ? WHERE note_id = ?", [code.map { .text($0) }, .integer(noteID)])
                    codeSaved = true
                    return .kept
                }
            }
            let previous: NoteExpansion.Previous? = hadText
                ? NoteExpansion.Previous(state: existing!.state.rawValue, sentences: existing!.sentences, userEdited: existing!.userEdited,
                                         sourceKey: existing!.sourceKey)
                : existing?.previous
            try run("""
                INSERT INTO note_expansions(note_id, meeting_id, state, pass, sentences, plain, source_key, upto_segment, user_edited,
                                            previous, error_code, updated_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 0, ?9, ?10, ?11)
                ON CONFLICT(note_id) DO UPDATE SET state = ?3, pass = ?4, sentences = ?5, plain = ?6, source_key = ?7,
                    upto_segment = ?8, user_edited = 0, previous = ?9, error_code = ?10, updated_at = ?11
                """,
                    [.integer(noteID), .integer(note.int(0)), .text(state.rawValue), .text(pass.rawValue),
                     .text(Self.encode(sentences)), .text(Self.plain(sentences)), .text(sourceKey), .integer(uptoSegment),
                     previous.map { .text(Self.encode($0)) }, code.map { .text($0) }, .real(now)])
            return .written
        }
        // The failure reason on a good expansion is stored too, so it reaches the journal right away.
        if result == .written || codeSaved { try await commitEdit() }
        return result
    }

    static func plain(_ sentences: [NoteExpansion.Sentence]) -> String { sentences.map(\.text).joined(separator: " ") }

    // MARK: The user's edits of an expansion (all undoable one level with `restorePreviousExpansion`)

    /// The user removed the expansion: nothing shows under the note and no pass writes it again.
    public func dismissExpansion(noteID: Int64) async throws {
        try transaction {
            guard let note = try db.query("SELECT meeting_id, text FROM notes WHERE id = ?", [.integer(noteID)]).first else { return }
            if let e = try expansion(of: noteID) {
                guard e.state != .dismissed else { return }
                let previous = Self.encode(NoteExpansion.Previous(state: e.state.rawValue, sentences: e.sentences,
                                                                  userEdited: e.userEdited, sourceKey: e.sourceKey))
                try run("UPDATE note_expansions SET state = 'dismissed', sentences = '[]', plain = '', previous = ?, user_edited = 0, updated_at = ? WHERE note_id = ?",
                        [.text(previous), .real(Date.now.timeIntervalSince1970), .integer(noteID)])
            } else {
                try run("""
                    INSERT INTO note_expansions(note_id, meeting_id, state, pass, sentences, plain, source_key, updated_at)
                    VALUES (?, ?, 'dismissed', 'manual', '[]', '', ?, ?)
                    """, [.integer(noteID), .integer(note.int(0)), .text(TextKeys.norm(note.string(1))), .real(Date.now.timeIntervalSince1970)])
            }
        }
        try await commitEdit()
    }

    /// The user rewrote the expansion (one sentence per line). A line that is the same as one of the model's keeps that
    /// sentence's citations; a line the user wrote or changed has none: nothing in the transcript was checked against
    /// it, so it must not carry a time that reads as a source. Nothing is marked and no pass replaces it. An empty text
    /// changes nothing (the caller removes the expansion instead).
    public func editExpansion(noteID: Int64, text: String) async throws {
        let lines = text.split(whereSeparator: \.isNewline).map { Self.clean(String($0), max: 600) }.filter { !$0.isEmpty }
        try transaction {
            guard let note = try db.query("SELECT meeting_id, text FROM notes WHERE id = ?", [.integer(noteID)]).first else { return }
            let existing = try expansion(of: noteID)
            var old = existing?.sentences ?? []
            let sentences: [NoteExpansion.Sentence] = lines.map { line in
                let key = TextKeys.norm(line)
                if let index = old.firstIndex(where: { TextKeys.norm($0.text) == key }) {
                    // The citations stay; the model's "Unconfirmed" mark does not: the user's version carries no marks.
                    var kept = old.remove(at: index)
                    kept.unconfirmed = false
                    return kept
                }
                return NoteExpansion.Sentence(text: line)
            }
            guard !sentences.isEmpty else { return }
            let previous = existing.map {
                Self.encode(NoteExpansion.Previous(state: $0.state.rawValue, sentences: $0.sentences, userEdited: $0.userEdited, sourceKey: $0.sourceKey))
            }
            try run("""
                INSERT INTO note_expansions(note_id, meeting_id, state, pass, sentences, plain, source_key, user_edited, previous, updated_at)
                VALUES (?1, ?2, 'done', 'manual', ?3, ?4, ?5, 1, ?6, ?7)
                ON CONFLICT(note_id) DO UPDATE SET state = 'done', sentences = ?3, plain = ?4, source_key = ?5, user_edited = 1,
                    previous = ?6, error_code = NULL, updated_at = ?7
                """, [.integer(noteID), .integer(note.int(0)), .text(Self.encode(sentences)), .text(Self.plain(sentences)),
                      .text(TextKeys.norm(note.string(1))), previous.map { .text($0) }, .real(Date.now.timeIntervalSince1970)])
        }
        try await commitEdit()
    }

    /// The user checked a sentence the transcript did not back and it is right: the mark goes. The text stays the
    /// model's (it is not an edit of the user's: a later pass may still write it again), and the version before is kept
    /// for Undo.
    public func markSentenceChecked(noteID: Int64, index: Int) async throws {
        try transaction {
            guard var e = try expansion(of: noteID), e.sentences.indices.contains(index), e.sentences[index].unconfirmed else { return }
            let previous = Self.encode(NoteExpansion.Previous(state: e.state.rawValue, sentences: e.sentences, userEdited: e.userEdited,
                                                              sourceKey: e.sourceKey))
            e.sentences[index].unconfirmed = false
            try run("UPDATE note_expansions SET sentences = ?, previous = ?, updated_at = ? WHERE note_id = ?",
                    [.text(Self.encode(e.sentences)), .text(previous), .real(Date.now.timeIntervalSince1970), .integer(noteID)])
        }
        try await commitEdit()
    }

    /// Goes back to the version before the last change (and forward again if called twice).
    public func restorePreviousExpansion(noteID: Int64) async throws {
        try transaction {
            guard let e = try expansion(of: noteID), let before = e.previous else { return }
            let current = NoteExpansion.Previous(state: e.state.rawValue, sentences: e.sentences, userEdited: e.userEdited, sourceKey: e.sourceKey)
            let state = NoteExpansion.State(rawValue: before.state) ?? .done
            try run("""
                UPDATE note_expansions SET state = ?, sentences = ?, plain = ?, user_edited = ?, source_key = ?, previous = ?, updated_at = ?
                WHERE note_id = ?
                """, [.text(state.rawValue), .text(Self.encode(before.sentences)), .text(Self.plain(before.sentences)),
                      .integer(before.userEdited ? 1 : 0), .text(before.sourceKey ?? e.sourceKey), .text(Self.encode(current)),
                      .real(Date.now.timeIntervalSince1970), .integer(noteID)])
        }
        try await commitEdit()
    }

    /// Puts the expansion row back exactly as `snapshot` was (nil: no row), for the undo and redo of one step. Whatever
    /// the row holds now is replaced, so each step restores precisely what it changed, however many came before.
    public func restoreExpansion(noteID: Int64, to snapshot: NoteExpansion?) async throws {
        try transaction {
            guard let note = try db.query("SELECT meeting_id FROM notes WHERE id = ?", [.integer(noteID)]).first else { return }
            guard let e = snapshot else {
                try run("DELETE FROM note_expansions WHERE note_id = ?", [.integer(noteID)])
                return
            }
            try run("""
                INSERT INTO note_expansions(note_id, meeting_id, state, pass, sentences, plain, source_key, upto_segment, user_edited,
                                            previous, error_code, updated_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
                ON CONFLICT(note_id) DO UPDATE SET state = ?3, pass = ?4, sentences = ?5, plain = ?6, source_key = ?7, upto_segment = ?8,
                    user_edited = ?9, previous = ?10, error_code = ?11, updated_at = ?12
                """, [.integer(noteID), .integer(note.int(0)), .text(e.state.rawValue), .text(e.pass.rawValue), .text(Self.encode(e.sentences)),
                      .text(Self.plain(e.sentences)), .text(e.sourceKey), .integer(e.uptoSegment), .integer(e.userEdited ? 1 : 0),
                      e.previous.map { .text(Self.encode($0)) }, e.errorCode.map { .text($0) }, .real(Date.now.timeIntervalSince1970)])
        }
        try await commitEdit()
    }

    // MARK: Undo of a delete

    /// Puts a deleted note back with its expansion (the same ID when it is free).
    @discardableResult
    public func restoreNote(_ row: NoteRow) async throws -> Int64 {
        let id: Int64 = try transaction {
            let n = row.note
            let free = try db.query("SELECT 1 FROM notes WHERE id = ?", [.integer(n.id)]).isEmpty
            try run("INSERT INTO notes(id, meeting_id, t, text, added_after, edited_at) VALUES (?, ?, ?, ?, ?, ?)",
                    [free ? .integer(n.id) : nil, .integer(n.meetingID), .real(n.t), .text(n.text), .integer(n.addedAfter ? 1 : 0),
                     n.editedAt.map { .real($0.timeIntervalSince1970) }])
            let id = db.lastInsertRowID
            if let e = row.expansion {
                try run("""
                    INSERT INTO note_expansions(note_id, meeting_id, state, pass, sentences, plain, source_key, upto_segment,
                                                user_edited, previous, error_code, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.integer(id), .integer(n.meetingID), .text(e.state.rawValue), .text(e.pass.rawValue),
                          .text(Self.encode(e.sentences)), .text(e.plain), .text(e.sourceKey), .integer(e.uptoSegment),
                          .integer(e.userEdited ? 1 : 0), e.previous.map { .text(Self.encode($0)) }, e.errorCode.map { .text($0) },
                          .real(e.updatedAt.timeIntervalSince1970)])
            }
            return id
        }
        try await commitEdit()
        return id
    }

    // MARK: Segment splits and Ask

    /// A split moved part of a segment to a new row: an expansion citation follows its stored quote (the part of the
    /// text that backs it), or its time when it has no quote. `toRight` false puts the citations back (undo of a split).
    func moveExpansionCitations(from left: Int64, to right: Int64, leftText: String, rightText: String, at: Double,
                                toRight: Bool = true, leftStart: Double = 0) throws {
        let source = toRight ? left : right
        let rows = try db.query("""
            SELECT note_id, sentences, previous FROM note_expansions WHERE EXISTS (
                SELECT 1 FROM json_each(note_expansions.sentences) s, json_each(s.value, '$.cites') c WHERE json_extract(c.value, '$.seg') = ?1)
                OR EXISTS (SELECT 1 FROM json_each(note_expansions.previous, '$.sentences') s, json_each(s.value, '$.cites') c
                           WHERE json_extract(c.value, '$.seg') = ?1)
            """, [.integer(source)])
        let (nl, nr) = (TextKeys.norm(leftText), TextKeys.norm(rightText))
        func moved(_ sentences: [NoteExpansion.Sentence]) -> [NoteExpansion.Sentence] {
            sentences.map { sentence in
                var s = sentence
                let key = TextKeys.norm(s.quote)
                s.cites = s.cites.map { cite in
                    guard cite.seg == source else { return cite }
                    var c = cite
                    if toRight {
                        let goes = key.isEmpty ? cite.t >= at : (!nl.contains(key) && nr.contains(key))
                        if goes { c.seg = right; c.t = at }
                    } else {
                        c.seg = left; c.t = leftStart
                    }
                    return c
                }
                return s
            }
        }
        for row in rows {
            let current = moved(Self.decodeSentences(row.optionalString(1)))
            var previous = row.optionalString(2).flatMap { try? JSONDecoder().decode(NoteExpansion.Previous.self, from: Data($0.utf8)) }
            if let before = previous?.sentences { previous?.sentences = moved(before) }
            try run("UPDATE note_expansions SET sentences = ?, previous = ? WHERE note_id = ?",
                    [.text(Self.encode(current)), previous.map { .text(Self.encode($0)) }, .integer(row.int(0))])
        }
    }

    /// The moments of a meeting that notes matching the words of a question cite. Ask ranks the passages around them
    /// higher, because the user flagged them. Only times and meetings come back, never the note text.
    func noteCitedMoments(terms: [String], scope: [Int64]?) throws -> [(meeting: Int64, t: Double)] {
        let spaced = terms.filter { !$0.contains(where: TextKeys.isNoSpaceScript) }
        let unspaced = terms.filter { $0.contains(where: TextKeys.isNoSpaceScript) }
        var noteIDs: [Int64] = []
        if !spaced.isEmpty {
            let match = spaced.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }.joined(separator: " OR ")
            // The meeting filter is part of the search: the limit then keeps the best matches of this meeting, not of the library.
            noteIDs += try db.query("""
                SELECT rowid FROM knowledge_fts WHERE knowledge_fts MATCH ?1 AND rowid % 8 IN (3, 6)
                AND (?2 IS NULL OR rowid / 8 IN (SELECT id FROM notes WHERE meeting_id IN (SELECT value FROM json_each(?2)))) ORDER BY rank LIMIT 40
                """, [.text(match), scope.map { .ids($0) }]).map { $0.int(0) / 8 }
        }
        if !unspaced.isEmpty {
            noteIDs += try db.query("""
                SELECT n.id FROM notes n LEFT JOIN note_expansions e ON e.note_id = n.id
                WHERE (?2 IS NULL OR n.meeting_id IN (SELECT value FROM json_each(?2)))
                AND EXISTS (SELECT 1 FROM json_each(?1) WHERE instr(n.text, value) > 0 OR instr(coalesce(e.plain, ''), value) > 0) LIMIT 40
                """, [.text(Self.json(strings: unspaced)), scope.map { .ids($0) }]).map { $0.int(0) }
        }
        guard !noteIDs.isEmpty else { return [] }
        var out: [(Int64, Double)] = []
        for row in try db.query("""
            SELECT meeting_id, sentences FROM note_expansions WHERE state = 'done' AND note_id IN (SELECT value FROM json_each(?1))
            AND (?2 IS NULL OR meeting_id IN (SELECT value FROM json_each(?2)))
            """, [.ids(noteIDs), scope.map { .ids($0) }]) {
            for sentence in Self.decodeSentences(row.optionalString(1)) { for cite in sentence.cites { out.append((row.int(0), cite.t)) } }
        }
        return out
    }
}
