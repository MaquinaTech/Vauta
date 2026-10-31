// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation

/// The meeting store. Its data is in two encrypted files:
///
/// - `vauta.db.enc`, the full snapshot (see `SnapshotEnvelope`). It is written
///   atomically when a meeting ends, after deletes, when opening after a crash
///   and a few seconds after each edit.
/// - `vauta.journal.enc` (see `Journal`), with only what was written since the
///   last snapshot: while recording, a few KB are appended every 10 s instead
///   of rewriting the whole database. It is replayed and removed on open.
///
/// The folder also holds `vauta.docs.enc`, the documents index (encrypted, derived data, see `DocumentIndex`), and
/// plaintext files with no meeting content: the lock, the erase marker, and `vauta.docs.extracting` while a document
/// is read (it names the file only by a keyed hash of its path). Atomic writes leave a temporary while they run, and a
/// migration may set encrypted files aside (`StoreFiles`).
///
/// Stores written under the old name (`acta.*`, the earlier version) are renamed in
/// place on open, see `StoreMigration`.
///
/// The database lives in memory while the app is open. The key is in the
/// Keychain (see `DatabaseKeyStore`).
///
/// Memory: plaintext intermediate buffers that Vauta controls are zeroed.
/// Internal copies made by CryptoKit, Foundation or SQLite reallocs cannot be
/// wiped; the database is in plaintext in the process's memory while the app
/// is open (protected by the sandbox, the hardened runtime and macOS's
/// encrypted swap).
///
/// The store is split by responsibility across `MeetingStore+*.swift`:
/// recording, queries, text search, persistence, retention and erase.
public actor MeetingStore {
    /// Meetings are deleted automatically after 90 days (at open and daily).
    public static let retentionDays = 90

    static let snapshotName = StoreFiles.snapshot
    static let journalName = StoreFiles.journal
    /// Temporaries of the store's own atomic writes: the only files recovery removes.
    static let tempPrefix = StoreFiles.tempPrefix
    static let lockName = StoreFiles.lock
    /// Marker of an "erase everything" in progress: if the process dies before
    /// rotating the key, the next open completes the crypto-shred.
    static let eraseMarkerName = StoreFiles.eraseMarker
    /// Above this journal size a snapshot is taken even while recording.
    static let journalLimit = 8 << 20
    /// Delay after an edit (outside a recording) before rewriting the snapshot.
    static let snapshotDelay: Duration = .seconds(5)

    var db: SQLiteDatabase
    let file: URL
    let journalFile: URL
    let eraseMarker: URL
    /// Every marker name (current and legacy) in this directory.
    let eraseMarkers: [URL]
    /// What the open changed on disk from an older layout (empty almost always).
    public nonisolated let migrationReport: StoreMigrationReport
    let keyStore: any DatabaseKeyStore
    /// Single-instance lock: lives as long as the store.
    let lock: InstanceLock
    /// The old `acta.lock`, held too when it exists so an old build still excludes this one.
    let legacyLock: InstanceLock?
    var key: SymmetricKey
    var journalKey: SymmetricKey
    /// Generation of the snapshot on disk: only a journal of the same generation is replayed.
    var generation = Data()
    /// Writes already applied in memory that are not in the journal yet.
    var pendingOps: [JournalOp] = []
    var nextSeq: UInt64 = 0
    var journalBytes = 0
    /// The journal cannot be used (no or failed snapshot, damaged journal,
    /// migration): the next save is a full snapshot.
    var needsSnapshot = false
    /// Deferred snapshot after an edit outside a recording.
    var snapshotSoon: Task<Void, Never>?
    /// In-memory chunk vectors (invalidated on change or delete).
    var vectorCache: (model: String, index: VectorIndex)?
    /// Delete done during a recording: FTS5 'optimize' and VACUUM wait until
    /// it ends (they would block the recording actor).
    var pendingCompaction = false
    /// Told when a person is renamed, merged or deleted (the names inside search chunks may have changed).
    var peopleChangeHandler: (@Sendable () -> Void)?
    /// Told when the person added, edited, checked or deleted a task or decision of a meeting (the link pass runs again shortly after).
    var itemsEditedHandler: (@Sendable (Int64) -> Void)?
    /// Told when meetings were deleted (retention, the person, the knowledge window): their attached materials went with them.
    var meetingsDeletedHandler: (@Sendable () -> Void)?
    /// "Erase everything" removed the file but the new key does not exist yet:
    /// nothing is written (with the old key the file would outlive its key)
    /// until the key is rotated.
    var needsNewKey = false
    /// A restore wrote its snapshot but its key is still only the staged one in the Keychain (see `restore`).
    var keyPromotionPending = false
    /// Counts the edits committed since the store was opened (the brief's cache key: any edit may change what a brief shows).
    public internal(set) var editRevision: UInt64 = 0
    /// The meeting being recorded: it cannot be deleted.
    public internal(set) var activeMeetingID: Int64?
    /// Single writer: each write waits for the previous one, so an old
    /// snapshot is never written over a newer one.
    var writer: Task<Void, Error>?
    var writesInFlight = 0
    /// Second speed of retention, see `init`.
    public internal(set) var knowledgeRetentionDays: Int
    /// How much the minutes' items weigh as keys of Ask's retrieval (`itemCitedMoments`); 0 turns them off (the evaluation compares both).
    public internal(set) var itemKeyWeight = MeetingStore.defaultItemKeyWeight

    var dirty: Bool { needsSnapshot || !pendingOps.isEmpty }

    /// Opens (or creates) the store in the app container's Application Support.
    ///
    /// Before reading anything it takes an exclusive lock: if another instance
    /// holds it, this fails with `.alreadyOpen` without touching the store.
    ///
    /// - Parameters:
    ///   - keyAccount: Keychain account of the database key.
    ///   - recoverOpenMeetings: app only. Closes meetings left open by a crash,
    ///     removes empty ones, deletes the store's own orphaned temporaries and
    ///     applies retention.
    ///   - knowledgeRetentionDays: with `retentionDays` (90, the default)
    ///     everything is deleted after 90 days; with more (or 0 = no limit),
    ///     only the raw text is deleted after 90 days and the card, decisions,
    ///     tasks and graph last that long.
    ///   - createIfMissing: false for read-only diagnostics: if no store exists,
    ///     throws `.storeNotFound` without creating a directory, file or key.
    public init(directory: URL? = nil, keyAccount: String = "database-key-v1",
                recoverOpenMeetings: Bool = false, knowledgeRetentionDays: Int = MeetingStore.retentionDays,
                createIfMissing: Bool = true) throws {
        try self.init(directory: directory, keyStore: KeychainDatabaseKeyStore(account: keyAccount),
                      recoverOpenMeetings: recoverOpenMeetings, knowledgeRetentionDays: knowledgeRetentionDays,
                      createIfMissing: createIfMissing)
    }

    /// - Parameter applicationSupport: tests only, the folder that stands in for
    ///   Application Support when `directory` is nil.
    init(directory: URL?, keyStore: any DatabaseKeyStore, recoverOpenMeetings: Bool = false,
         knowledgeRetentionDays: Int = MeetingStore.retentionDays, createIfMissing: Bool = true,
         applicationSupport: URL? = nil) throws {
        self.knowledgeRetentionDays = knowledgeRetentionDays
        self.keyStore = keyStore
        let fm = FileManager.default
        // The earlier version's folder is moved (under its locks) only for a writable
        // open of the default location; a failed open below moves it back.
        let choice: DirectoryChoice
        if let directory {
            choice = DirectoryChoice(url: directory)
        } else if createIfMissing {
            choice = try applicationSupport.map(Self.moveDirectoryIfNeeded(under:)) ?? Self.defaultDirectory()
        } else {
            choice = try DirectoryChoice(url: applicationSupport.map(Self.locateDirectory(under:)) ?? Self.locateDefaultDirectory())
        }
        var opened = false
        defer { if !opened { Self.undoDirectoryMove(choice) } }
        let dir = choice.url
        func at(_ name: String) -> URL { dir.appendingPathComponent(name) }
        // A read-only open of a store that still has the old names reads it
        // where it is: no rename, no new lock file, no trace.
        let readLegacy = !createIfMissing && !fm.fileExists(atPath: at(StoreFiles.snapshot).path)
            && fm.fileExists(atPath: at(StoreFiles.Legacy.snapshot).path)
        // Locals, not `self.file`: an autoclosure (`||`) capturing self would
        // end the initializer's isolation.
        let file = at(readLegacy ? StoreFiles.Legacy.snapshot : StoreFiles.snapshot)
        let journalFile = at(readLegacy ? StoreFiles.Legacy.journal : StoreFiles.journal)
        let eraseMarkers = [at(StoreFiles.eraseMarker), at(StoreFiles.Legacy.eraseMarker)]
        self.file = file
        self.journalFile = journalFile
        self.eraseMarker = eraseMarkers[0]
        self.eraseMarkers = eraseMarkers
        // Checked before creating anything, so a read-only open leaves no trace.
        guard createIfMissing || StoreFiles.hasStore(in: dir) else {
            throw StoreError(.storeNotFound, detail: dir.path)
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // vauta.lock is the lock. An existing acta.lock is held as well: a
        // build of the old name running on this directory then still excludes us.
        if let locks = choice.locks {
            lock = locks.main
            legacyLock = locks.legacy
        } else if readLegacy {
            lock = try InstanceLock(at(StoreFiles.Legacy.lock))
            legacyLock = nil
        } else {
            lock = try InstanceLock(at(StoreFiles.lock))
            legacyLock = fm.fileExists(atPath: at(StoreFiles.Legacy.lock).path) ? try InstanceLock(at(StoreFiles.Legacy.lock)) : nil
        }
        // Checked again under the lock: another instance may have written or
        // erased the file in between. Deciding "new store" from a stale answer
        // would overwrite an existing store with an empty one.
        let exists = StoreFiles.hasStore(in: dir)
        guard createIfMissing || exists else {
            throw StoreError(.storeNotFound, detail: dir.path)
        }
        // `attributes:` only applies on creation: always enforce it (repairs inherited permissions).
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        // Out of Time Machine. Set on the directory, not the file: the atomic
        // write replaces the file and would drop the attribute.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dirURL = dir
        try? dirURL.setResourceValues(values)

        if eraseMarkers.contains(where: { fm.fileExists(atPath: $0.path) }) {
            // Interrupted "erase everything". Without a file, whatever key is
            // left is the old one (or an unused new one): delete it to complete
            // the crypto-shred. With a file, the erase never happened.
            if !exists {
                try keyStore.remove()
                unlink(at(StoreFiles.journal).path)
                unlink(at(StoreFiles.Legacy.journal).path)
            }
            for marker in eraseMarkers { try? fm.removeItem(at: marker) }
        }
        // A restore interrupted after writing its snapshot: its key is still the staged one.
        let staged = try Self.settleStagedKey(keyStore, snapshot: at(StoreFiles.snapshot), writable: createIfMissing)
        keyPromotionPending = staged.map { !$0.promoted && createIfMissing } ?? false
        // Old names to the new ones, verified with the key first. If anything
        // below fails, the renames are undone so the old files stay as they were.
        var migration = StoreMigration.Outcome()
        if exists && !readLegacy { migration = try StoreMigration.run(in: dir, keyStore: keyStore) }
        migrationReport = migration.report
        defer { if !opened { migration.rollback() } }
        if exists { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        key = try staged?.key ?? keyStore.key(createIfMissing: !exists)
        journalKey = Journal.key(from: key)
        var replayed = 0
        var gen = Data()
        var journalUnusable = false
        if exists {
            let (image, size) = try SnapshotEnvelope.open(Data(contentsOf: file), key: key)
            db = try SQLiteDatabase(image: image, size: size)
            // Before migrating: the journal was written with this snapshot's schema.
            if let stored = try Self.storedGeneration(db) {
                gen = stored
                let replay = Journal.read(journalFile, generation: stored, key: journalKey)
                replayed = try Self.apply(replay, to: db)
                journalUnusable = replay.damagedTail || replay.foreign || replayed < replay.ops.count
            }
        } else {
            db = try SQLiteDatabase(image: nil, size: 0)
        }
        let migrated = try Schema.migrate(db)
        // Without a snapshot on disk that has a generation, the journal is not usable yet.
        generation = gen
        nextSeq = UInt64(replayed)
        let journalLeftover = replayed == 0 && fm.fileExists(atPath: journalFile.path)
        let snapshotNeeded = journalUnusable || !exists || migrated || gen.isEmpty || journalLeftover
        needsSnapshot = snapshotNeeded

        if recoverOpenMeetings {
            // Orphaned temporaries of an interrupted write (ciphertext only).
            // Only the store's own pattern: never other files.
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where StoreFiles.isTemporary(name) {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
            // A meeting left open never reached `endMeeting`: its echoes are marked later, with the earlier meetings'.
            try db.query("INSERT OR IGNORE INTO echo_pending (meeting_id) SELECT id FROM meetings WHERE ended_at IS NULL")
            try db.query("""
                UPDATE meetings SET ended_at = COALESCE(started_at + (SELECT MAX(end) FROM segments WHERE meeting_id = meetings.id), started_at)
                WHERE ended_at IS NULL
                """)
            // After a crash a delete may have left its compaction pending.
            let crashed = db.changes > 0 || replayed > 0
            try db.query(Self.deleteEmptySQL)
            let emptied = db.changes > 0
            let expired = try Self.removeMeetings(db, Self.retentionStatements(now: .now, knowledgeDays: knowledgeRetentionDays, active: nil))
            if crashed || emptied || expired > 0 { try Self.compact(db) }
            // Everything into a fresh snapshot without a journal: the next open
            // does not depend on replaying anything.
            if crashed || emptied || expired > 0 || snapshotNeeded {
                let fresh = Journal.newGeneration()
                try Self.setGeneration(fresh, in: db)
                try Self.writeSnapshot(db.withSerializedBytes(SnapshotEnvelope.pack), key: key, to: file)
                unlink(journalFile.path)
                generation = fresh
                nextSeq = 0
                needsSnapshot = false
            }
        }
        opened = true
    }

    /// An encrypted store already exists in the default location (used to tell
    /// upgrades from new installs). Never opens or creates anything.
    public static var existsAtDefaultLocation: Bool {
        guard let dir = try? locateDefaultDirectory() else { return false }
        return StoreFiles.hasStore(in: dir)
    }

    // MARK: Journaled writes

    /// Runs a write and records it for the journal. Only successful writes are
    /// recorded; inside `transaction` they are dropped if it rolls back.
    func run(_ sql: String, _ params: [SQLiteValue?] = []) throws {
        try db.query(sql, params)
        pendingOps.append(JournalOp(sql: sql, params: params))
    }

    /// A transaction with no `await` inside: it applies (and is recorded)
    /// completely or not at all.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        let mark = pendingOps.count
        try db.execute("BEGIN")
        do {
            let value = try body()
            try db.execute("COMMIT")
            return value
        } catch {
            try? db.execute("ROLLBACK")
            pendingOps.removeSubrange(mark...)
            throw error
        }
    }

    /// After a user edit: to the journal now (cheap and durable) and, when not
    /// recording, a full snapshot a few seconds later (groups edits and takes
    /// the pre-edit text off the disk).
    func commitEdit() async throws {
        editRevision &+= 1
        try await save()
        guard activeMeetingID == nil else { return }
        snapshotSoon?.cancel()
        snapshotSoon = Task { [weak self] in
            do { try await Task.sleep(for: Self.snapshotDelay) } catch { return }
            try? await self?.snapshotIfIdle()
        }
    }

    private func snapshotIfIdle() async throws {
        guard activeMeetingID == nil, dirty || nextSeq > 0 || retryCompaction else { return }
        try await snapshot()
    }
}
