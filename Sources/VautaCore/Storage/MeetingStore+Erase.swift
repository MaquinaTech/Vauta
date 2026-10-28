// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation

/// "Erase everything": crypto-shred of the store.
extension MeetingStore {
    /// Erases all history irrecoverably (crypto-shred): deletes the snapshot and
    /// journal (under both the vauta.* and the old acta.* names) and the Keychain key, and starts over with a new key and an empty database.
    /// Old copies of the file (backups, disk remnants) become unreadable forever.
    ///
    /// Not erased: the model server configuration and its token in the
    /// Keychain, and the app's preferences.
    public func eraseEverything() async throws {
        guard activeMeetingID == nil else { throw StoreError.meetingInProgress }
        // No pending write may rewrite the old file afterwards.
        await drainWriter()
        guard activeMeetingID == nil else { throw StoreError.meetingInProgress }
        // No await from here on: nothing interleaves. If the Keychain does not
        // answer, abort before touching anything.
        // (After a restore whose key is still only staged, the key item may be missing: the erase shreds both.)
        if !needsNewKey && !keyPromotionPending { _ = try keyStore.key(createIfMissing: false) }
        let fresh = try SQLiteDatabase(image: nil, size: 0)
        try Schema.migrate(fresh)
        // Marker and file first; if the file cannot be deleted, nothing changes.
        try Data().write(to: eraseMarker)
        // The earlier version's folder goes before the live snapshot: once the snapshot is
        // gone, a crash would otherwise leave that folder as the only store, and the
        // next launch would move it in as the store to use.
        eraseOldFolder()
        // Both names of the snapshot first: if one cannot be deleted, the store stays as it is.
        for name in [StoreFiles.snapshot, StoreFiles.Legacy.snapshot] {
            if unlink(directory.appendingPathComponent(name).path) != 0 && errno != ENOENT {
                let code = errno
                try? FileManager.default.removeItem(at: eraseMarker)
                throw StoreError(.eraseFailed, detail: "unlink: errno \(code)")
            }
        }
        removeJournalsAndLeftovers()
        // The documents image is sealed with a key derived from the one being shredded, and holds text of the person's files:
        // it goes with everything else (the sources are in the database that was just replaced).
        for name in [DocumentIndex.fileName, StoreFiles.documentsMarker] { unlink(directory.appendingPathComponent(name).path) }
        db = fresh   // the old database zeroes its image when released
        vectorCache = nil
        pendingCompaction = false
        writer = nil
        snapshotSoon?.cancel()
        pendingOps = []
        nextSeq = 0
        journalBytes = 0
        needsSnapshot = true
        // From here nothing is ever written with the old key: save() and
        // startMeeting() retry the rotation or fail. If the process dies, the
        // marker completes it on the next open.
        needsNewKey = true
        try rotateKey()
        try await snapshot()
    }

    /// The store's directory.
    var directory: URL { file.deletingLastPathComponent() }

    /// Removes the journal under both names. After an erase also the files a
    /// migration set aside (`*.legacy-<time>`): they are encrypted with the key being shredded.
    func removeJournalsAndLeftovers(includingSetAside: Bool = true) {
        for name in [StoreFiles.journal, StoreFiles.Legacy.journal] { unlink(directory.appendingPathComponent(name).path) }
        unlink(journalFile.path)
        guard includingSetAside else { return }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where StoreFiles.isAside(name) {
            unlink(directory.appendingPathComponent(name).path)
        }
    }

    /// Completes the crypto-shred: removes the old key (and any staged one) from the Keychain and
    /// creates another (with one retry). Only once the new one exists does the
    /// store stop requiring it.
    func rotateKey() throws {
        do {
            try keyStore.remove()
            let newKey: SymmetricKey
            do { newKey = try keyStore.newKey() } catch { newKey = try keyStore.newKey() }
            key = newKey
            journalKey = Journal.key(from: newKey)
        } catch {
            throw StoreError(.newKeyPending, underlying: error)
        }
        needsNewKey = false
        // `remove` shredded a key a restore had left staged too.
        keyPromotionPending = false
        for marker in eraseMarkers { try? FileManager.default.removeItem(at: marker) }
    }
}
