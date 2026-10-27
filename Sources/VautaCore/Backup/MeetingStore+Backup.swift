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
            let integrity = try db.query("PRAGMA integrity_check")
            guard integrity.count == 1, integrity[0].string(0) == "ok" else {
                throw StoreError(.backupInvalid, detail: "integrity check failed")
            }
            try Schema.migrate(db)
            // The full-text indexes are shadow tables the integrity check above does not compare with their content.
            do {
                for table in ["segments_fts", "names_fts", "knowledge_fts"] { try db.execute("INSERT INTO \(table)(\(table)) VALUES('integrity-check')") }
            } catch {
                throw StoreError(.backupInvalid, detail: "full-text index check failed")
            }
            let meetings = Int(try db.query("SELECT COUNT(*) FROM meetings")[0].int(0))
            let savedVoices = Int(try db.query("SELECT COUNT(*) FROM voice_profiles")[0].int(0))
            let documentSources = Int(try db.query("SELECT COUNT(*) FROM doc_sources WHERE attached_meeting_id IS NULL")[0].int(0))
            // Settings that can't be read, or that hold nothing known, are left out: the meetings still restore.
            let preferences = encodedPreferences.map(BackupPreferences.init(decoding:)).flatMap { $0.isEmpty ? nil : $0 }
            return OpenedBackup(manifest: manifest, meetings: meetings, savedVoices: savedVoices, documentSources: documentSources, preferences: preferences, database: db)
        }.value
    }

    /// Replaces the store with a backup. The old data is only dropped once the
    /// new store is on disk:
    ///
    /// 1. the database key is replaced in the Keychain (in place; if that fails nothing changed);
    /// 2. the backup is written as the new snapshot, sealed with the new key, atomically over the old one;
    ///    if this fails the previous key is put back and the old store is untouched;
    /// 3. the old key is gone, so every old copy of the store (backups, disk remnants) can no longer be read.
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
        // Sealed before the key changes, so the window between the Keychain
        // update and the rename is only the file write.
        let sealed = try SnapshotEnvelope.seal(restored.withSerializedBytes(SnapshotEnvelope.pack), key: newKey)
        // After "Erase everything" whose key rotation is still pending, the
        // Keychain holds the key being shredded: it is never put back.
        let oldKey = needsNewKey ? nil : key
        do {
            try keyStore.replace(with: newKey)
        } catch {
            throw StoreError(.restoreFailed, underlying: error)
        }
        do {
            try AtomicFile.write(sealed, to: file, tempPrefix: Self.tempPrefix)
        } catch {
            if let oldKey {
                // Put the previous key back so the old snapshot stays readable.
                do { try keyStore.replace(with: oldKey) } catch {
                    do { try keyStore.replace(with: oldKey) } catch {
                        // The Keychain keeps only the new key: re-save the current
                        // store with it right away, so it stays readable.
                        adoptKeyAfterFailedRollback(newKey)
                    }
                }
            }
            throw StoreError(.restoreFailed, underlying: error)
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

    /// Last resort when a restore could not write its snapshot nor put the old
    /// key back: the store switches to the key the Keychain has and rewrites
    /// the current data with it (new generation, no journal).
    private func adoptKeyAfterFailedRollback(_ newKey: SymmetricKey) {
        key = newKey
        journalKey = Journal.key(from: newKey)
        needsSnapshot = true
        let fresh = Journal.newGeneration()
        guard (try? Self.setGeneration(fresh, in: db)) != nil,
              let packed = try? db.withSerializedBytes(SnapshotEnvelope.pack),
              (try? Self.writeSnapshot(packed, key: newKey, to: file)) != nil else { return }
        removeJournalsAndLeftovers(includingSetAside: false)
        generation = fresh
        pendingOps = []
        nextSeq = 0
        journalBytes = 0
        needsSnapshot = false
    }
}
