// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import SQLite3

/// What a file's row says about it.
public struct DocumentFileRecord: Sendable, Equatable, Identifiable {
    public enum State: String, Sendable {
        case pending, indexed, partial, skipped
        /// Its text is indexed (if it has any); its pages or pixels still wait for OCR.
        case ocrPending = "ocr_pending"
    }

    public let id: Int64
    public let sourceID: Int64
    public var relPath: String
    public var fileID: String?
    public var size: Int64
    public var mtime: Double
    public var hash: String?
    public var format: DocumentFormat
    public var extractorVersion: Int
    public var title: String?
    public var state: State
    public var reason: DocumentSkipReason?
    public var pages: Int?
    public var characters: Int
    /// Pages of a PDF that wait for OCR (an image has page 1).
    public var ocrPages: [Int]
    public var indexedAt: Double?

    public var name: String { (relPath as NSString).lastPathComponent }
}

/// A passage found by a search, with where it is.
public struct DocumentPassage: Sendable, Equatable, Identifiable, Hashable {
    public let id: Int64
    public let key: String
    public let fileID: Int64
    public let sourceID: Int64
    public let relPath: String
    public let fileName: String
    public let title: String?
    public let format: DocumentFormat
    public let locator: DocumentLocator
    public let text: String
    public let ocr: Bool
    public var score: Double
    /// The cosine of the question to this passage alone, without the keyword and entity boosts (nil unless the search model ranked it).
    public var cosine: Double?

    public init(id: Int64, key: String, fileID: Int64, sourceID: Int64, relPath: String, fileName: String, title: String? = nil, format: DocumentFormat,
                locator: DocumentLocator, text: String, ocr: Bool = false, score: Double = 0, cosine: Double? = nil) {
        self.id = id
        self.key = key
        self.fileID = fileID
        self.sourceID = sourceID
        self.relPath = relPath
        self.fileName = fileName
        self.title = title
        self.format = format
        self.locator = locator
        self.text = text
        self.ocr = ocr
        self.score = score
        self.cosine = cosine
    }
}

/// Counts of one source's files.
public struct DocumentSourceCounts: Sendable, Equatable {
    public var files = 0
    public var indexed = 0
    public var partial = 0
    public var skipped = 0
    public var pending = 0
    public var ocrPending = 0
    /// Skipped because they are Google Drive shortcuts.
    public var googleShortcuts = 0
    /// Skipped because a cloud service keeps them online only (iCloud or another File Provider).
    public var onlineOnly = 0
    /// Whole folders a cloud service keeps online only: nothing inside them was read or listed.
    public var onlineOnlyFolders = 0
    public init() {}

    /// Everything skipped because it is not on this Mac.
    public var notOnThisMac: Int { googleShortcuts + onlineOnly + onlineOnlyFolders }
}

/// The index of the person's documents: files, passages, keyword terms and vectors, in its own encrypted image
/// (`vauta.docs.enc`).
///
/// The meeting store keeps one image in memory and rewrites all of it on every save. Documents can be tens of megabytes,
/// so they would be re-encrypted by every meeting edit, flood the journal during a recording and bloat backups. The index
/// is therefore a second image, sealed like the first (LZ4 and AES-256-GCM, `SnapshotEnvelope`) with a key derived from
/// the store's key, so erasing everything (which rotates that key) also destroys it. It is derived data: it is never
/// journaled, it is saved after each batch of files, and if it cannot be opened it is thrown away and rebuilt from the
/// sources, which live in the meeting store. A separate connection also means indexing never queues behind a meeting's
/// save or an Ask.
public actor DocumentIndex {
    public static let fileName = "vauta.docs.enc"
    static let tempPrefix = "vauta.docs.enc.tmp-"
    /// The label the documents key is derived with. It never changes: a different one would make every index unreadable.
    static let keyLabel = "vauta.documents.v1"
    static let schemaVersion: Int64 = 1

    let db: SQLiteDatabase
    let url: URL
    var key: SymmetricKey
    var dirty = false
    var writer: Task<Void, Error>?
    /// The index could not be opened and was started again: the sources are indexed from scratch.
    public nonisolated let wasRebuilt: Bool
    var vectorCache: (space: EmbeddingSpace, index: VectorIndex)?
    /// The size of the image at the last save (before sealing): the indexer saves less often as it grows.
    public private(set) var lastImageBytes = 0

    /// The key of the documents image, derived from the store's key.
    public static func derivedKey(from storeKey: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: storeKey, salt: Data(), info: Data(keyLabel.utf8), outputByteCount: 32)
    }

    /// Opens `directory/vauta.docs.enc`, or starts an empty index when it is missing or unreadable. `key` is the documents key
    /// (`MeetingStore.documentsKey()`).
    public init(directory: URL, key: SymmetricKey) throws {
        url = directory.appendingPathComponent(Self.fileName)
        self.key = key
        var opened: SQLiteDatabase?
        var rebuilt = false
        if let data = try? Data(contentsOf: url) {
            do {
                let (image, size) = try SnapshotEnvelope.open(data, key: key)
                let database = try SQLiteDatabase(image: image, size: size)
                if try Self.version(database) > Self.schemaVersion { throw StoreError(.newerSchema, detail: "documents") }
                opened = database
            } catch {
                // A damaged file, a key that changed, a newer version: it is only an index, so it starts again.
                rebuilt = true
                unlink(url.path)
            }
        }
        let database = try opened ?? SQLiteDatabase(image: nil, size: 0)
        try Self.migrate(database)
        let droppedRetired = try Self.dropRetiredVectors(database)
        db = database
        wasRebuilt = rebuilt
        // Leftovers of an interrupted write: ciphertext only, removed by their own prefix.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasPrefix(Self.tempPrefix) {
            unlink(directory.appendingPathComponent(name).path)
        }
        dirty = opened == nil || droppedRetired
    }

    /// Apple's on-device embeddings ("apple-nl:*") were removed: their passage vectors are dropped once (a `meta` flag), without
    /// a schema change, so the documents are not read again. Returns whether anything was written.
    private static func dropRetiredVectors(_ db: SQLiteDatabase) throws -> Bool {
        guard try db.query("SELECT v FROM meta WHERE k = 'apple_nl_dropped'").isEmpty else { return false }
        try db.query("DELETE FROM passage_vectors WHERE model LIKE 'apple-nl:%'")
        try db.query("INSERT INTO meta(k, v) VALUES ('apple_nl_dropped', '1')")
        return true
    }

    private static func version(_ db: SQLiteDatabase) throws -> Int64 { try db.query("PRAGMA user_version")[0].int(0) }

    private static func migrate(_ db: SQLiteDatabase) throws {
        guard try version(db) < schemaVersion else { return }
        try db.execute("BEGIN")
        do {
            try db.execute("""
                CREATE TABLE files(
                    id INTEGER PRIMARY KEY,
                    source_id INTEGER NOT NULL,
                    rel_path TEXT NOT NULL,
                    file_id TEXT,
                    size INTEGER NOT NULL,
                    mtime REAL NOT NULL,
                    content_hash TEXT,
                    format TEXT NOT NULL,
                    extractor_version INTEGER NOT NULL DEFAULT 1,
                    title TEXT,
                    state TEXT NOT NULL CHECK(state IN ('pending','indexed','partial','skipped','ocr_pending')),
                    reason TEXT,
                    pages INTEGER,
                    chars INTEGER NOT NULL DEFAULT 0,
                    ocr_pages TEXT NOT NULL DEFAULT '[]',
                    indexed_at REAL,
                    UNIQUE(source_id, rel_path)
                );
                CREATE INDEX files_by_source ON files(source_id, state);
                CREATE TABLE passages(
                    id INTEGER PRIMARY KEY,
                    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                    key TEXT NOT NULL,
                    ordinal INTEGER NOT NULL,
                    locator TEXT NOT NULL CHECK(json_valid(locator)),
                    text TEXT NOT NULL,
                    ocr INTEGER NOT NULL DEFAULT 0,
                    UNIQUE(file_id, key)
                );
                CREATE INDEX passages_by_file ON passages(file_id, ordinal);
                -- Contentless: the text is not stored twice. Its terms are segmented when indexed (Japanese, Chinese,
                -- Thai), the same way a question is.
                CREATE VIRTUAL TABLE passages_fts USING fts5(terms, content='', contentless_delete=1,
                                                             tokenize='unicode61 remove_diacritics 2');
                INSERT INTO passages_fts(passages_fts, rank) VALUES('secure-delete', 1);
                CREATE TABLE passage_vectors(
                    passage_id INTEGER PRIMARY KEY REFERENCES passages(id) ON DELETE CASCADE,
                    model TEXT NOT NULL,
                    dims INTEGER NOT NULL,
                    scale REAL NOT NULL,
                    emb BLOB NOT NULL
                );
                CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT NOT NULL);
                PRAGMA user_version = 1;
                """)
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    // MARK: Saving

    /// Writes the image if it changed. Compressed on the actor straight from SQLite's memory; sealed and written off it,
    /// one write at a time, so an older image never lands over a newer one.
    public func save() async throws {
        // Nothing new to write, but an earlier write may still be on its way: "saved" means it reached the disk.
        guard dirty else {
            await drain()
            return
        }
        let packed = try db.withSerializedBytes(SnapshotEnvelope.pack)
        dirty = false
        lastImageBytes = packed.count
        let (key, url) = (key, url)
        let previous = writer
        let task = Task.detached(priority: .utility) {
            _ = await previous?.result
            try AtomicFile.write(SnapshotEnvelope.seal(packed, key: key), to: url, tempPrefix: DocumentIndex.tempPrefix)
        }
        writer = task
        do { try await task.value } catch { dirty = true; throw error }
    }

    /// Waits for the write in flight.
    func drain() async {
        if let writer { _ = await writer.result }
    }

    /// Deletes the file and empties the index (Erase Everything). Nothing is written again until the next change.
    public func eraseAll() async throws {
        await drain()
        try db.execute("""
            DELETE FROM passage_vectors; DELETE FROM passages_fts; DELETE FROM passages; DELETE FROM files; DELETE FROM meta;
            """)
        vectorCache = nil
        unlink(url.path)
        dirty = false
    }

    /// Takes the new key after Erase Everything rotated the store's.
    public func rekey(_ key: SymmetricKey) {
        self.key = key
        dirty = true
    }

    @discardableResult
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try db.execute("BEGIN")
        do {
            let value = try body()
            try db.execute("COMMIT")
            dirty = true
            return value
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    // MARK: Meta

    func meta(_ key: String) -> String? {
        (try? db.query("SELECT v FROM meta WHERE k = ?", [.text(key)]))?.first?.string(0)
    }

    func setMeta(_ key: String, _ value: String) throws {
        try db.query("INSERT INTO meta(k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v", [.text(key), .text(value)])
        dirty = true
    }

    /// Pages read with OCR today (a power guard: the rest wait for tomorrow).
    public func ocrPagesToday(now: Date = .now) -> Int {
        let day = Self.dayKey(now)
        guard let value = meta("ocr_day"), value.hasPrefix(day + ":"), let n = Int(value.dropFirst(day.count + 1)) else { return 0 }
        return n
    }

    public func recordOCR(pages: Int, now: Date = .now) throws {
        try setMeta("ocr_day", Self.dayKey(now) + ":" + String(ocrPagesToday(now: now) + pages))
    }

    private static func dayKey(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
}
