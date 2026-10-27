// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Recording a meeting: start, append segments, end, rename.
extension MeetingStore {
    /// Creates the meeting being recorded and makes it the active one.
    ///
    /// - Parameters:
    ///   - locale: transcription language, stored as BCP-47. nil stores NULL,
    ///     which readers treat as the legacy `es-ES`.
    ///   - outputLocale: language for minutes and answers; nil = same as `locale`.
    ///   - sourceApp: the captured app family identifier; nil = legacy capture.
    ///   - timeZone: the zone of the Mac now, kept with the meeting so a day said in it ("next Tuesday") is resolved there later.
    /// - Throws: `.meetingAlreadyActive` if another meeting is being recorded
    ///   (it would lose its protection from deletion and retention).
    public func startMeeting(at date: Date, locale: Locale? = nil, outputLocale: Locale? = nil,
                             sourceApp: String? = nil, timeZone: TimeZone = .current) throws -> Int64 {
        guard activeMeetingID == nil else { throw StoreError(.meetingAlreadyActive) }
        // Without a valid key nothing is recorded: nothing transcribed could be saved.
        if needsNewKey { try rotateKey() }
        try run("INSERT INTO meetings(started_at, locale, output_locale, source_app, time_zone) VALUES (?, ?, ?, ?, ?)",
                [.real(date.timeIntervalSince1970), locale.map { .text($0.identifier(.bcp47)) },
                 outputLocale.map { .text($0.identifier(.bcp47)) }, sourceApp.map { .text($0) }, .text(timeZone.identifier)])
        let id = db.lastInsertRowID
        activeMeetingID = id
        return id
    }

    /// Appends a final segment and returns its row ID (translations refer to it).
    @discardableResult
    public func append(_ segment: Segment, to meetingID: Int64) throws -> Int64 {
        try run("INSERT INTO segments(meeting_id, speaker, start, end, text) VALUES (?, ?, ?, ?, ?)",
                [.integer(meetingID), .text(segment.channel.storedCode), .real(segment.start), .real(segment.end), .text(segment.text)])
        return db.lastInsertRowID
    }

    /// Stores the translation of a segment into `language` (replaces an earlier one).
    /// A segment that no longer exists (purged meanwhile) stores nothing. With `source` (the text
    /// that was translated), nothing is stored when the segment's text is no longer that: the
    /// aligner may have split it meanwhile, and a translation of the whole text would repeat the
    /// part that now belongs to the right segment.
    public func saveTranslation(_ text: String, language: String, of segmentID: Int64, source: String? = nil) throws {
        var args: [SQLiteValue] = [.text(language), .text(text), .integer(segmentID)]
        if let source { args.append(.text(source)) }
        try run("""
            INSERT OR REPLACE INTO segment_translations(segment_id, lang, text)
            SELECT id, ?1, ?2 FROM segments WHERE id = ?3\(source == nil ? "" : " AND text = ?4")
            """, args)
    }

    /// Stores a translation that arrived after the recording ended. Only when the segment still
    /// exists, belongs to `meetingID` and still has the text that was translated: a meeting deleted,
    /// purged or erased meanwhile (whose row IDs may even have been reused) stores nothing.
    /// Returns whether it was stored.
    @discardableResult
    public func saveLateTranslation(_ text: String, language: String, of segmentID: Int64,
                                    inMeeting meetingID: Int64, source: String) async throws -> Bool {
        let rows = try db.query("SELECT 1 FROM segments WHERE id = ? AND meeting_id = ? AND text = ?",
                                [.integer(segmentID), .integer(meetingID), .text(source)])
        guard !rows.isEmpty else { return false }
        try saveTranslation(text, language: language, of: segmentID, source: source)
        try await commitEdit()
        return true
    }

    /// Closes the meeting (or removes it if nobody spoke and it has no notes or
    /// marks), writes it in a snapshot (the journal is removed) and then runs
    /// any pending compaction (and saves again): what was just recorded reaches
    /// the disk before the VACUUM. Even if the UPDATE fails, the meeting stops
    /// being the active one and whatever there is gets saved.
    /// Returns whether the meeting was kept (false: it was empty and has been removed).
    @discardableResult
    public func endMeeting(_ id: Int64, at date: Date) async throws -> Bool {
        if activeMeetingID == id { activeMeetingID = nil }
        var failure: Error?
        var kept = true
        do {
            try run("UPDATE meetings SET ended_at = ? WHERE id = ?", [.real(date.timeIntervalSince1970), .integer(id)])
            try run(Self.deleteEmptySQL + " AND id = ?", [.integer(id)])
            kept = db.changes == 0
        } catch {
            failure = error
        }
        // Context mentions (deterministic, local). If this fails the meeting is
        // saved anyway; it can be re-analyzed from the review screen.
        if failure == nil, db.changes == 0 { _ = try? transaction { try analyzeInTransaction(id) } }
        do { try await snapshot(compacting: false) } catch { failure = failure ?? error }
        if pendingCompaction && activeMeetingID == nil {
            do {
                try compactNow()
                try await snapshot(compacting: false)
            } catch {
                failure = failure ?? error
            }
        }
        if let failure { throw failure }
        return kept
    }

    /// nil or empty: back to the automatic title (see `Meeting.displayTitle`).
    public func setTitle(_ title: String?, of id: Int64) async throws {
        let clean = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try run("UPDATE meetings SET title = ? WHERE id = ?", [clean.isEmpty ? nil : .text(clean), .integer(id)])
        try await commitEdit()
    }
}
