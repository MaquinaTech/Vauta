// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// A file as the scanner sees it.
public struct ScannedDocumentFile: Sendable, Equatable {
    public var relPath: String
    public var size: Int64
    public var mtime: Double
    public var fileID: String?
    public var format: DocumentFormat?
    /// Known before reading: iCloud placeholders, formats to export, files over the size limit.
    public var skip: DocumentSkipReason?

    public init(relPath: String, size: Int64, mtime: Double, fileID: String? = nil, format: DocumentFormat?, skip: DocumentSkipReason? = nil) {
        self.relPath = relPath
        self.size = size
        self.mtime = mtime
        self.fileID = fileID
        self.format = format
        self.skip = skip
    }
}

/// A passage with the keyword terms it is searched by.
public struct IndexedPassage: Sendable {
    public let draft: PassageDraft
    public let terms: String
    public init(draft: PassageDraft, terms: String) {
        self.draft = draft
        self.terms = terms
    }
}

/// How an update of a file's passages went.
public struct PassageDiff: Sendable, Equatable {
    public var added = 0
    public var removed = 0
    public var kept = 0
}

extension DocumentIndex {
    static let fileColumns = "id, source_id, rel_path, file_id, size, mtime, content_hash, format, extractor_version, title, state, reason, pages, chars, ocr_pages, indexed_at"

    static func record(_ r: Row) -> DocumentFileRecord? {
        guard let format = DocumentFormat(rawValue: r.string(7)), let state = DocumentFileRecord.State(rawValue: r.string(10)) else { return nil }
        let pages = (try? JSONDecoder().decode([Int].self, from: Data(r.string(14).utf8))) ?? []
        return DocumentFileRecord(id: r.int(0), sourceID: r.int(1), relPath: r.string(2), fileID: r.optionalString(3), size: r.int(4), mtime: r.double(5),
                                  hash: r.optionalString(6), format: format, extractorVersion: Int(r.int(8)), title: r.optionalString(9), state: state,
                                  reason: r.optionalString(11).flatMap(DocumentSkipReason.init(rawValue:)), pages: r.optionalInt(12).map(Int.init),
                                  characters: Int(r.int(13)), ocrPages: pages, indexedAt: r.optionalDouble(15))
    }

    public func files(source: Int64) throws -> [DocumentFileRecord] {
        try db.query("SELECT \(Self.fileColumns) FROM files WHERE source_id = ? ORDER BY rel_path", [.integer(source)]).compactMap(Self.record)
    }

    public func file(id: Int64) throws -> DocumentFileRecord? {
        try db.query("SELECT \(Self.fileColumns) FROM files WHERE id = ?", [.integer(id)]).first.flatMap(Self.record)
    }

    public func file(source: Int64, relPath: String) throws -> DocumentFileRecord? {
        try db.query("SELECT \(Self.fileColumns) FROM files WHERE source_id = ? AND rel_path = ?", [.integer(source), .text(relPath)]).first.flatMap(Self.record)
    }

    public func allFileSourceIDs() throws -> Set<Int64> {
        Set(try db.query("SELECT DISTINCT source_id FROM files").map { $0.int(0) })
    }

    /// Creates the row of a file seen for the first time, or resets the one that changed, as `pending`.
    @discardableResult
    public func markPending(source: Int64, scanned: ScannedDocumentFile, format: DocumentFormat) throws -> Int64 {
        try transaction {
            try db.query("""
                INSERT INTO files(source_id, rel_path, file_id, size, mtime, format, extractor_version, state, ocr_pages)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'pending', '[]')
                ON CONFLICT(source_id, rel_path) DO UPDATE SET file_id = excluded.file_id, size = excluded.size, mtime = excluded.mtime,
                    format = excluded.format, extractor_version = excluded.extractor_version, state = 'pending', reason = NULL
                """, [.integer(source), .text(scanned.relPath), scanned.fileID.map { .text($0) }, .integer(scanned.size), .real(scanned.mtime),
                      .text(format.rawValue), .integer(Int64(format.extractorVersion))])
            return try db.query("SELECT id FROM files WHERE source_id = ? AND rel_path = ?", [.integer(source), .text(scanned.relPath)])[0].int(0)
        }
    }

    /// A file that is not read: the row says why. Its old passages (if any) are removed.
    public func markSkipped(source: Int64, scanned: ScannedDocumentFile, reason: DocumentSkipReason) throws {
        try transaction {
            try db.query("""
                INSERT INTO files(source_id, rel_path, file_id, size, mtime, format, extractor_version, state, reason, ocr_pages)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, 1, 'skipped', ?7, '[]')
                ON CONFLICT(source_id, rel_path) DO UPDATE SET file_id = excluded.file_id, size = excluded.size, mtime = excluded.mtime,
                    format = excluded.format, state = 'skipped', reason = excluded.reason, chars = 0, pages = NULL, ocr_pages = '[]'
                """, [.integer(source), .text(scanned.relPath), scanned.fileID.map { .text($0) }, .integer(scanned.size), .real(scanned.mtime),
                      .text((scanned.format ?? .text).rawValue), .text(reason.rawValue)])
            if let id = try db.query("SELECT id FROM files WHERE source_id = ? AND rel_path = ?", [.integer(source), .text(scanned.relPath)]).first?.int(0) {
                try removePassages(of: id)
            }
        }
        vectorCache = nil
    }

    public func markSkipped(fileID: Int64, reason: DocumentSkipReason) throws {
        try transaction {
            try db.query("UPDATE files SET state = 'skipped', reason = ?, chars = 0, pages = NULL, ocr_pages = '[]' WHERE id = ?", [.text(reason.rawValue), .integer(fileID)])
            try removePassages(of: fileID)
        }
        vectorCache = nil
    }

    /// The OCR pass of a file failed. What the text pass indexed stays (the file becomes `partial`, with the reason); a file with
    /// no text at all is skipped.
    public func ocrFailed(fileID: Int64, reason: DocumentSkipReason) throws {
        guard let record = try file(id: fileID) else { return }
        let hasText = try db.query("SELECT 1 FROM passages WHERE file_id = ? LIMIT 1", [.integer(fileID)]).first != nil
        guard hasText else { return try markSkipped(fileID: fileID, reason: reason) }
        try finish(fileID: fileID, state: .partial, title: record.title, pages: record.pages, characters: record.characters, ocrPages: [], reason: reason)
    }

    /// The file's text is indexed. `ocrPages` are the pages that still wait for OCR.
    public func finish(fileID: Int64, state: DocumentFileRecord.State, title: String?, pages: Int?, characters: Int, ocrPages: [Int],
                       reason: DocumentSkipReason? = nil, hash: String? = nil, extractorVersion: Int? = nil, now: Date = .now) throws {
        let json = String(decoding: (try? JSONEncoder().encode(ocrPages)) ?? Data("[]".utf8), as: UTF8.self)
        try transaction {
            try db.query("""
                UPDATE files SET state = ?, title = ?, pages = ?, chars = ?, ocr_pages = ?, reason = ?, content_hash = coalesce(?, content_hash), indexed_at = ?,
                    extractor_version = coalesce(?, extractor_version)
                WHERE id = ?
                """, [.text(state.rawValue), title.map { .text($0) }, pages.map { .integer(Int64($0)) }, .integer(Int64(characters)), .text(json),
                      reason.map { .text($0.rawValue) }, hash.map { .text($0) }, .real(now.timeIntervalSince1970),
                      extractorVersion.map { .integer(Int64($0)) }, .integer(fileID)])
        }
    }

    /// The same bytes under a new modification date: only the date is refreshed.
    public func refresh(fileID: Int64, size: Int64, mtime: Double, hash: String?) throws {
        try transaction {
            try db.query("UPDATE files SET size = ?, mtime = ?, content_hash = coalesce(?, content_hash) WHERE id = ?",
                         [.integer(size), .real(mtime), hash.map { .text($0) }, .integer(fileID)])
        }
    }

    /// A file that moved inside its source keeps its passages (and their keys). A file with no title of its own is named in the first
    /// line of each passage, so that line takes the new name: the prompt must not show `## New.pdf` over `[D1] Old`.
    public func rename(fileID: Int64, to relPath: String, mtime: Double, size: Int64) throws {
        try transaction {
            let before = try db.query("SELECT rel_path, title FROM files WHERE id = ?", [.integer(fileID)]).first
            try db.query("UPDATE files SET rel_path = ?, mtime = ?, size = ? WHERE id = ?", [.text(relPath), .real(mtime), .integer(size), .integer(fileID)])
            guard let before, before.optionalString(1) == nil else { return }
            func name(_ path: String) -> String { TextSanitizer.oneLine(((path as NSString).lastPathComponent as NSString).deletingPathExtension, limit: 100) }
            let (old, new) = (name(before.string(0)), name(relPath))
            guard old != new, !old.isEmpty else { return }
            for row in try db.query("SELECT id, text, locator FROM passages WHERE file_id = ?", [.integer(fileID)]) {
                let text = row.string(1)
                guard text.hasPrefix(old) else { continue }
                let renamed = new + text.dropFirst(old.count)
                // The keyword terms and the key follow the text, so the old name stops finding the file and the next edit keeps its keys.
                try db.query("UPDATE passages SET text = ?, key = ? WHERE id = ?",
                             [.text(renamed), .text(PassageChunker.key(locatorJSON: row.string(2), renamed)), .integer(row.int(0))])
                try db.query("DELETE FROM passages_fts WHERE rowid = ?", [.integer(row.int(0))])
                try db.query("INSERT INTO passages_fts(rowid, terms) VALUES (?, ?)", [.integer(row.int(0)), .text(DocumentTerms.terms(for: renamed))])
            }
        }
    }

    public func setExtractorVersion(fileID: Int64, _ version: Int) throws {
        try transaction { try db.query("UPDATE files SET extractor_version = ? WHERE id = ?", [.integer(Int64(version)), .integer(fileID)]) }
    }

    /// Puts files back in the queue (Index Again, or a better extractor). With `olderThan`, only the files of that format read by an
    /// older extractor are put back and the ones already waiting are left alone; reading a file records the new version
    /// (`finish`), so the next scan does not queue it again.
    public func requeue(source: Int64, onlyFormat: DocumentFormat? = nil, olderThan version: Int? = nil) throws {
        try transaction {
            try db.query("""
                UPDATE files SET state = 'pending' WHERE source_id = ?1 AND (?2 IS NULL OR format = ?2) AND state <> 'skipped'
                    AND (?3 IS NULL OR (extractor_version < ?3 AND state <> 'pending'))
                """, [.integer(source), onlyFormat.map { .text($0.rawValue) }, version.map { .integer(Int64($0)) }])
        }
    }

    // MARK: Passages

    func removePassages(of file: Int64) throws {
        try db.query("DELETE FROM passages_fts WHERE rowid IN (SELECT id FROM passages WHERE file_id = ?)", [.integer(file)])
        try db.query("DELETE FROM passages WHERE file_id = ?", [.integer(file)])
    }

    /// Makes the file's passages exactly `passages`. A passage whose key is already stored keeps its row (and its vector);
    /// only new keys are inserted and missing ones deleted, so an edit re-embeds only what changed.
    @discardableResult
    public func replacePassages(fileID: Int64, with passages: [IndexedPassage]) throws -> PassageDiff {
        var diff = PassageDiff()
        try transaction {
            let existing = Dictionary(uniqueKeysWithValues: try db.query("SELECT key, id FROM passages WHERE file_id = ?", [.integer(fileID)]).map { ($0.string(0), $0.int(1)) })
            let wanted = Set(passages.map(\.draft.key))
            for (key, id) in existing where !wanted.contains(key) {
                try db.query("DELETE FROM passages_fts WHERE rowid = ?", [.integer(id)])
                try db.query("DELETE FROM passages WHERE id = ?", [.integer(id)])
                diff.removed += 1
            }
            for passage in passages {
                let d = passage.draft
                if let id = existing[d.key] {
                    try db.query("UPDATE passages SET ordinal = ?, locator = ? WHERE id = ?", [.integer(Int64(d.ordinal)), .text(d.locator.json), .integer(id)])
                    diff.kept += 1
                } else {
                    try insert(passage, file: fileID)
                    diff.added += 1
                }
            }
        }
        vectorCache = nil
        return diff
    }

    /// Adds passages without touching the others (the second, OCR pass of a file).
    @discardableResult
    public func addPassages(fileID: Int64, _ passages: [IndexedPassage]) throws -> Int {
        var added = 0
        try transaction {
            let known = Set(try db.query("SELECT key FROM passages WHERE file_id = ?", [.integer(fileID)]).map { $0.string(0) })
            for passage in passages where !known.contains(passage.draft.key) {
                try insert(passage, file: fileID)
                added += 1
            }
        }
        vectorCache = nil
        return added
    }

    private func insert(_ passage: IndexedPassage, file: Int64) throws {
        let d = passage.draft
        try db.query("INSERT INTO passages(file_id, key, ordinal, locator, text, ocr) VALUES (?, ?, ?, ?, ?, ?)",
                     [.integer(file), .text(d.key), .integer(Int64(d.ordinal)), .text(d.locator.json), .text(d.text), .integer(d.ocr ? 1 : 0)])
        try db.query("INSERT INTO passages_fts(rowid, terms) VALUES (?, ?)", [.integer(db.lastInsertRowID), .text(passage.terms)])
    }

    // MARK: Removal

    public func deleteFile(id: Int64) throws {
        try transaction {
            try removePassages(of: id)
            try db.query("DELETE FROM files WHERE id = ?", [.integer(id)])
        }
        vectorCache = nil
    }

    /// Everything of one source: files, passages, vectors and keyword terms (securely deleted). Saved at once by the
    /// caller, so the removed text is gone from the disk at the next write.
    public func deleteSource(_ source: Int64) throws {
        try transaction {
            try db.query("DELETE FROM passages_fts WHERE rowid IN (SELECT p.id FROM passages p JOIN files f ON f.id = p.file_id WHERE f.source_id = ?)", [.integer(source)])
            try db.query("DELETE FROM files WHERE source_id = ?", [.integer(source)])
        }
        try compact()
        vectorCache = nil
    }

    /// Merges the keyword index so the terms of deleted passages are gone from it (a contentless index keeps them until it is
    /// merged), then the freed pages are zeroed by `secure_delete`.
    public func compact() throws {
        try db.execute("INSERT INTO passages_fts(passages_fts) VALUES('optimize')")
        dirty = true
    }

    // MARK: Counts

    public func counts(source: Int64) throws -> DocumentSourceCounts {
        var counts = DocumentSourceCounts()
        for row in try db.query("SELECT state, COUNT(*) FROM files WHERE source_id = ? GROUP BY state", [.integer(source)]) {
            let n = Int(row.int(1))
            counts.files += n
            switch row.string(0) {
            case "indexed": counts.indexed += n
            case "partial": counts.indexed += n; counts.partial += n
            case "skipped": counts.skipped += n
            case "pending": counts.pending += n
            case "ocr_pending": counts.indexed += n; counts.ocrPending += n
            default: break
            }
        }
        if counts.skipped > 0 {
            for row in try db.query("SELECT reason, COUNT(*) FROM files WHERE source_id = ? AND state = 'skipped' AND reason IN (?, ?, ?) GROUP BY reason",
                                    [.integer(source), .text(DocumentSkipReason.googleDriveShortcut.rawValue), .text(DocumentSkipReason.iCloudNotDownloaded.rawValue),
                                     .text(DocumentSkipReason.cloudNotDownloaded.rawValue)]) {
                if row.string(0) == DocumentSkipReason.googleDriveShortcut.rawValue { counts.googleShortcuts += Int(row.int(1)) } else { counts.onlineOnly += Int(row.int(1)) }
            }
            // A folder kept online only is recorded under its path with a trailing slash: it is counted as a folder, not as a file.
            let folders = Int(try db.query("SELECT COUNT(*) FROM files WHERE source_id = ? AND state = 'skipped' AND reason = ? AND rel_path LIKE '%/'",
                                           [.integer(source), .text(DocumentSkipReason.cloudNotDownloaded.rawValue)])[0].int(0))
            counts.onlineOnlyFolders = folders
            counts.onlineOnly -= folders
        }
        return counts
    }

    public func totalCharacters() throws -> Int { Int(try db.query("SELECT COALESCE(SUM(chars), 0) FROM files")[0].int(0)) }

    public func totalFiles() throws -> Int { Int(try db.query("SELECT COUNT(*) FROM files WHERE state <> 'skipped'")[0].int(0)) }

    public func totalPassages() throws -> Int { Int(try db.query("SELECT COUNT(*) FROM passages")[0].int(0)) }

    /// The skipped files of a source with why, for the Skipped Files sheet. No content.
    public func skipped(source: Int64) throws -> [DocumentFileRecord] {
        try db.query("SELECT \(Self.fileColumns) FROM files WHERE source_id = ? AND (state = 'skipped' OR state = 'partial') ORDER BY rel_path", [.integer(source)]).compactMap(Self.record)
    }

    /// Files waiting to be read, in `sources` only (a paused or unreachable source is left out), small first (most value per
    /// second) with the large PDFs after them.
    public func queue(limit: Int, sources: [Int64]) throws -> [DocumentFileRecord] {
        try db.query("""
            SELECT \(Self.fileColumns) FROM files WHERE state = 'pending' AND source_id IN (SELECT value FROM json_each(?2))
            ORDER BY \(Self.outdatedOrder), CASE format WHEN 'pdf' THEN 1 ELSE 0 END, size LIMIT ?1
            """, [.integer(Int64(limit)), .ids(sources)]).compactMap(Self.record)
    }

    /// Files read by an older extractor wait behind the new and changed ones (1 = outdated, 0 = current).
    static var outdatedOrder: String {
        let cases = DocumentFormat.allCases.map { "WHEN '\($0.rawValue)' THEN \($0.extractorVersion)" }.joined(separator: " ")
        return "CASE WHEN extractor_version < CASE format \(cases) ELSE 1 END THEN 1 ELSE 0 END"
    }

    /// Files whose pages or pixels wait for OCR, small first.
    public func ocrQueue(limit: Int, sources: [Int64]) throws -> [DocumentFileRecord] {
        try db.query("""
            SELECT \(Self.fileColumns) FROM files WHERE state = 'ocr_pending' AND source_id IN (SELECT value FROM json_each(?2)) ORDER BY size LIMIT ?1
            """, [.integer(Int64(limit)), .ids(sources)]).compactMap(Self.record)
    }

    public func pendingCount(source: Int64) throws -> Int {
        Int(try db.query("SELECT COUNT(*) FROM files WHERE source_id = ? AND state = 'pending'", [.integer(source)])[0].int(0))
    }
}
