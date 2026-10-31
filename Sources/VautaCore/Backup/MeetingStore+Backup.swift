// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation

/// A backup that was decrypted and checked, ready to replace the store. The
/// database lives in memory only; it is consumed by `MeetingStore.restore`.
public final class OpenedBackup: @unchecked Sendable {
    public let manifest: BackupManifest
    /// Meetings in the backup, counted in the database itself (not taken from the manifest).
    public let meetings: Int
    /// Saved voices (voice fingerprints) the backup would bring back, counted in the database itself. A backup is sealed
    /// with its password, not the store key, so it can hold voices that were deleted after it was made.
    public let savedVoices: Int
    /// Document sources (folders and files added as knowledge sources) the backup brings back, with their bookmarks. The index of
    /// their text is not in a backup: it is derived data and is built again after the restore.
    public let documentSources: Int
    /// The settings the backup carries; nil for a backup made before they were included (or one with none set).
    /// Applying them is up to the app (`BackupPreferences.apply(to:)`); the store does not hold settings.
    public let preferences: BackupPreferences?
    private let lock = NSLock()
    private var database: SQLiteDatabase?

    init(manifest: BackupManifest, meetings: Int, savedVoices: Int = 0, documentSources: Int = 0, preferences: BackupPreferences?, database: SQLiteDatabase) {
        self.manifest = manifest
        self.meetings = meetings
        self.savedVoices = savedVoices
        self.documentSources = documentSources
        self.preferences = preferences
        self.database = database
    }

    func take() -> SQLiteDatabase? {
        lock.withLock {
            defer { database = nil }
            return database
        }
    }
}

/// What a backup holds, counted in the backup itself, from a check that keeps nothing (`MeetingStore.checkBackup`).
public struct BackupContents: Sendable, Equatable {
    public let createdAt: Date
    public let meetings: Int
    public let savedVoices: Int
    public let documentSources: Int
    public let hasSettings: Bool
}

public struct RestoreSummary: Sendable, Equatable {
    /// Meetings the store had before the restore.
    public let replacedMeetings: Int
    public let restoredMeetings: Int
}

/// Encrypted backup and restore of the whole store, with the app's settings when the caller passes them.
extension MeetingStore {
    /// An encrypted copy of everything in the store, as the bytes of a backup
    /// file. The snapshot is taken on the actor in one step, so it is consistent
    /// (also while recording); the slow key derivation and encryption happen
    /// off the actor. No plaintext is written anywhere. `preferences` (see `BackupPreferences`) go inside the same
    /// encrypted payload; without them the file is a format 1 backup.
    public func createBackup(password: String, appVersion: String, preferences: BackupPreferences? = nil) async throws -> Data {
        guard BackupPassword.isAcceptable(password) else { throw StoreError("The backup password is too short.") }
        let packed = try db.withSerializedBytes { image in
            // A backup the restore would refuse is worse than none.
            guard image.count <= SnapshotEnvelope.maximumBackupImageSize else {
                throw StoreError(.backupInvalid, detail: "the store is larger than a backup can restore")
            }
            return try SnapshotEnvelope.pack(image)
        }
        let manifest = BackupManifest(format: 1, appVersion: appVersion, schemaVersion: try Schema.version(of: db),
                                      createdAt: .now, meetingCount: Int(try db.query("SELECT COUNT(*) FROM meetings")[0].int(0)))
        let encodedPreferences = preferences?.encoded()
        return try await Task.detached(priority: .userInitiated) {
            try BackupArchive.seal(packed: packed, manifest: manifest, preferences: encodedPreferences, password: password)
        }.value
    }

    /// How many context entries the store holds (people, projects and clients, glossary terms, recurring meetings):
    /// a restore replaces them too, even when there are no meetings.
    public func contextEntryCount() throws -> Int {
        let row = try db.query("""
            SELECT (SELECT COUNT(*) FROM entities WHERE merged_into IS NULL), (SELECT COUNT(*) FROM glossary), (SELECT COUNT(*) FROM series)
            """)[0]
        return Int(row.int(0) + row.int(1) + row.int(2))
    }

    /// Decrypts and validates a backup without touching the store: refuses a
    /// wrong password, a changed or truncated file and a newer schema; older
    /// schemas are migrated in memory.
    public static func openBackup(_ file: Data, password: String) async throws -> OpenedBackup {
        try await Task.detached(priority: .userInitiated) {
            var (manifest, encodedPreferences, packed) = try BackupArchive.open(file, password: password)
            defer { wipe(&packed) }
            guard (1...2).contains(manifest.format) else { throw StoreError(.backupUnsupported, detail: "format \(manifest.format)") }
            guard manifest.schemaVersion <= Schema.currentVersion else {
                throw StoreError(.newerSchema, detail: "backup schema \(manifest.schemaVersion) > \(Schema.currentVersion)")
            }
            let (image, size) = try SnapshotEnvelope.unpack(packed, maxSize: SnapshotEnvelope.maximumBackupImageSize)
            let db = try SQLiteDatabase(image: image, size: size)
            // The image is untrusted: nothing in it runs until its schema is proven to be Vauta's own.
            try BackupSchemaGuard.validate(db)
            try rebuildFullTextIndexes(db)
            let integrity = try db.query("PRAGMA integrity_check")
            guard integrity.count == 1, integrity[0].string(0) == "ok" else {
                throw StoreError(.backupInvalid, detail: "integrity check failed")
            }
            try Schema.migrate(db)
            let meetings = Int(try db.query("SELECT COUNT(*) FROM meetings")[0].int(0))
            let savedVoices = Int(try db.query("SELECT COUNT(*) FROM voice_profiles")[0].int(0))
            let documentSources = Int(try db.query("SELECT COUNT(*) FROM doc_sources WHERE attached_meeting_id IS NULL")[0].int(0))
            // Settings that can't be read, or that hold nothing known, are left out: the meetings still restore.
            let preferences = encodedPreferences.map(BackupPreferences.init(decoding:)).flatMap { $0.isEmpty ? nil : $0 }
            return OpenedBackup(manifest: manifest, meetings: meetings, savedVoices: savedVoices, documentSources: documentSources, preferences: preferences, database: db)
        }.value
    }

    /// Opens a backup exactly as a restore would (`openBackup`: the password, every byte of the file, the schema, the
    /// indexes and the database's integrity, and the migrations of an older one) and keeps nothing: the database it decrypted
    /// is dropped, and its memory zeroed, before this returns. A backup that passes is one Restore can open.
    public static func checkBackup(_ file: Data, password: String) async throws -> BackupContents {
        let backup = try await openBackup(file, password: password)
        defer { _ = backup.take() }
        return BackupContents(createdAt: backup.manifest.createdAt, meetings: backup.meetings, savedVoices: backup.savedVoices,
                              documentSources: backup.documentSources, hasSettings: !(backup.preferences?.isEmpty ?? true))
    }

    /// The full-text indexes of the store, each a binary format of its own that SQLite parses whenever the table is read.
    static let fullTextIndexes = ["segments_fts", "names_fts", "knowledge_fts"]

    /// Builds the full-text indexes of an untrusted image again from their text, before anything reads them (the integrity
    /// check does): `rebuild` drops what an index holds without parsing it, then indexes the text again (`segments` for the
    /// transcripts, the table's own copy of the text for the others). A crafted index is never interpreted, and the rebuilt
    /// one matches its text by construction. An image older than an index doesn't have it yet; its migration creates it.
    ///
    /// The settings FTS5 keeps beside each index are read as plain rows first: Vauta only ever has the format version and
    /// `secure-delete` on, so anything else (another ranking, page size or merge setting, `secure-delete` off) is not one of
    /// its backups. `secure-delete` is then turned on for every index, as the store's own are.
    static func rebuildFullTextIndexes(_ db: SQLiteDatabase) throws {
        let present = Set(try db.query("SELECT name FROM sqlite_schema WHERE type = 'table'").map { $0.string(0) })
        let tables = fullTextIndexes.filter(present.contains)
        for table in tables {
            let foreign = try db.query("""
                SELECT COUNT(*) FROM "\(table)_config" WHERE NOT (typeof(v) = 'integer' AND (k = 'version' AND v IN (4, 5) OR k = 'secure-delete' AND v = 1))
                """)
            guard foreign.first?.int(0) == 0 else { throw StoreError(.backupInvalid, detail: "full-text index settings differ from Vauta's") }
        }
        do {
            for table in tables {
                try db.execute("INSERT INTO \(table)(\(table)) VALUES('rebuild')")
                try db.execute("INSERT INTO \(table)(\(table), rank) VALUES('secure-delete', 1)")
            }
        } catch {
            throw StoreError(.backupInvalid, detail: "full-text index rebuild failed")
        }
    }

    /// Replaces the store with a backup. The old data is only dropped once the
    /// new store is on disk, and the store opens after a crash at any step:
    ///
    /// 1. the new key is staged in the Keychain, next to the current one (if that fails nothing changed);
    /// 2. the backup is written as the new snapshot, sealed with the new key, atomically over the old one;
    ///    if this fails the staged key is deleted and the old store is untouched;
    /// 3. the new key becomes the store key, as a new item with Vauta's own access list, and the staged one is
    ///    deleted. If this fails, or the process dies before or during it, the staged key still opens the snapshot:
    ///    the next open (or the next restore) completes it (`settleStagedKey`);
    /// 4. the old key is gone, so every old copy of the store (backups, disk remnants) can no longer be read.
    ///
    /// Refused while a meeting is being recorded.
    public func restore(_ backup: OpenedBackup) async throws -> RestoreSummary {
        guard activeMeetingID == nil else { throw StoreError.meetingInProgress }
        snapshotSoon?.cancel()
        snapshotSoon = nil
        await drainWriter()
        guard activeMeetingID == nil else { throw StoreError.meetingInProgress }
        // No await from here on: nothing interleaves.
        guard let restored = backup.take() else { throw StoreError(.restoreFailed, detail: "backup already used") }
        let replaced = Int(try db.query("SELECT COUNT(*) FROM meetings")[0].int(0))
        // A backup taken while recording holds an unfinished meeting: close it. Its window embeddings are dropped (they
        // cannot be finalized without the recording's words; voice data is not kept for a meeting without speakers).
        try restored.query("DELETE FROM diarization_windows WHERE meeting_id IN (SELECT id FROM meetings WHERE ended_at IS NULL)")
        try restored.query("""
            UPDATE meetings SET ended_at = COALESCE(started_at + (SELECT MAX(end) FROM segments WHERE meeting_id = meetings.id), started_at)
            WHERE ended_at IS NULL
            """)
        let fresh = Journal.newGeneration()
        try Self.setGeneration(fresh, in: restored)
        let newKey = SymmetricKey(size: .bits256)
        let sealed = try SnapshotEnvelope.seal(restored.withSerializedBytes(SnapshotEnvelope.pack), key: newKey)
        do {
            // The staged key of an earlier restore whose last step failed is the one the snapshot on disk needs: it
            // becomes the store key before another is staged. After "Erase everything" whose key rotation is still
            // pending there is no snapshot, and the key being shredded is never put back.
            if keyPromotionPending && !needsNewKey {
                try keyStore.replace(with: key)
                keyStore.discardStaged()
            }
            keyPromotionPending = false
            try keyStore.stage(newKey)
        } catch {
            throw StoreError(.restoreFailed, underlying: error)
        }
        do {
            try AtomicFile.write(sealed, to: file, tempPrefix: Self.tempPrefix)
        } catch {
            // The rename may be done when the error comes (the directory flush failed): then the new snapshot is the store.
            guard let onDisk = try? Data(contentsOf: file), SnapshotEnvelope.isSealed(onDisk, with: newKey) else {
                keyStore.discardStaged()
                throw StoreError(.restoreFailed, underlying: error)
            }
        }
        do {
            try keyStore.replace(with: newKey)
            keyStore.discardStaged()
        } catch {
            keyPromotionPending = true
        }
        removeJournalsAndLeftovers(includingSetAside: false)
        // The documents image belonged to the data that was just replaced (and is sealed with the old key): the restored sources are
        // indexed again.
        for name in [DocumentIndex.fileName, StoreFiles.documentsMarker] { unlink(directory.appendingPathComponent(name).path) }
        db = restored
        key = newKey
        journalKey = Journal.key(from: newKey)
        generation = fresh
        vectorCache = nil
        pendingCompaction = false
        pendingOps = []
        nextSeq = 0
        journalBytes = 0
        needsSnapshot = false
        needsNewKey = false
        for marker in eraseMarkers { try? FileManager.default.removeItem(at: marker) }
        return RestoreSummary(replacedMeetings: replaced, restoredMeetings: Int(try db.query("SELECT COUNT(*) FROM meetings")[0].int(0)))
    }

    /// Completes a restore that stopped after writing its snapshot (see `restore`), on open. Returns the staged key
    /// when it is the one that opens `snapshot` and the store key does not; `promoted` is false when it could not become
    /// the store key (it is still staged, and the next open or restore tries again). A staged key that opens nothing
    /// needed (no snapshot, or the store key opens it: the restore never wrote its snapshot, or it finished) is
    /// deleted. A read-only open (`writable` false) changes nothing in the Keychain.
    static func settleStagedKey(_ keyStore: any DatabaseKeyStore, snapshot: URL,
                                writable: Bool) throws -> (key: SymmetricKey, promoted: Bool)? {
        guard let staged = try keyStore.stagedKey() else { return nil }
        let current = try keyStore.existingKey()
        guard let sealed = try? Data(contentsOf: snapshot) else {
            if writable { keyStore.discardStaged() }
            return nil
        }
        if let current, SnapshotEnvelope.isSealed(sealed, with: current) {
            if writable { keyStore.discardStaged() }
            return nil
        }
        // Neither key opens it: the file is damaged, and the open fails on it with the store key, as without a restore.
        guard SnapshotEnvelope.isSealed(sealed, with: staged) else { return nil }
        guard writable else { return (staged, false) }
        do {
            try keyStore.replace(with: staged)
        } catch {
            return (staged, false)
        }
        keyStore.discardStaged()
        return (staged, true)
    }
}
