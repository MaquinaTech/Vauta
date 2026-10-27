// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation

/// Saving: journal appends, snapshots, the single writer, and journal replay.
extension MeetingStore {
    /// Saves if there are changes (call periodically while recording): appends
    /// what is new to the journal. If a write is already in flight it does not
    /// queue another one: the next call will.
    public func saveIfNeeded() async throws {
        guard dirty || retryCompaction, writesInFlight == 0 else { return }
        try await save()
    }

    /// Final save (hurried quit, sleep): skips nothing. While recording, to the
    /// journal (fastest); otherwise a full snapshot and no journal.
    public func flush() async throws {
        if !dirty, let w = writer, case .failure = await w.result { needsSnapshot = true }
        if activeMeetingID != nil {
            if dirty { try await save() }
        } else if dirty || retryCompaction || nextSeq > 0 {
            try await snapshot()
        }
    }

    /// A pending compaction that can be retried (nothing is recording).
    var retryCompaction: Bool { pendingCompaction && activeMeetingID == nil }

    /// The journal when possible; a snapshot if the journal cannot be used or grew too large.
    func save() async throws {
        if needsSnapshot || needsNewKey || journalBytes > Self.journalLimit || retryCompaction {
            try await snapshot()
        } else if !pendingOps.isEmpty {
            try await appendJournal()
        }
    }

    /// Appends the pending writes to the journal. Encrypted and written off the
    /// actor, in the same chain as snapshots (never ahead of one).
    private func appendJournal() async throws {
        let plain = Journal.encode(pendingOps)
        pendingOps = []
        let seq = nextSeq
        nextSeq += 1
        journalBytes += plain.count + 4 + 28
        let (generation, key, url, lock) = (generation, journalKey, journalFile, lock)
        try await enqueueWrite {
            let record = try Journal.seal(plain, seq: seq, generation: generation, key: key)
            try Journal.append(record, generation: generation, to: url)
            withExtendedLifetime(lock) {}
        }
    }

    /// Full snapshot with a new generation; once it is on disk, the journal is
    /// removed. On the actor the image is only compressed, straight from
    /// SQLite's memory (LZ4, no intermediate plaintext copy); encryption and
    /// I/O happen off the actor so appends and searches are not blocked.
    /// `compacting`: first retries a pending compaction if not recording (if it
    /// fails again it does not block the save; it stays pending).
    func snapshot(compacting: Bool = true) async throws {
        if needsNewKey { try rotateKey() }
        if compacting && retryCompaction { try? compactNow() }
        snapshotSoon?.cancel()
        snapshotSoon = nil
        let gen = Journal.newGeneration()
        try Self.setGeneration(gen, in: db)
        let packed = try db.withSerializedBytes(SnapshotEnvelope.pack)
        generation = gen
        pendingOps = []
        nextSeq = 0
        journalBytes = 0
        needsSnapshot = false
        let (key, file, journal, lock) = (key, file, journalFile, lock)
        try await enqueueWrite {
            try Self.writeSnapshot(packed, key: key, to: file)
            // The journal belonged to the previous snapshot: it is included now.
            // The snapshot's rename is durable (directory flushed) before this unlink.
            unlink(journal.path)
            withExtendedLifetime(lock) {}   // the lock is never released mid-write
        }
    }

    /// Encrypts and atomically replaces the snapshot file (durable on return).
    static func writeSnapshot(_ packed: SecretBuffer, key: SymmetricKey, to file: URL) throws {
        try AtomicFile.write(SnapshotEnvelope.seal(packed, key: key), to: file, tempPrefix: tempPrefix)
    }

    /// Single writer: each write waits for the previous one, so an old snapshot
    /// is never written over a newer one. If it fails, the next save is a full
    /// snapshot (the journal may be incomplete).
    private func enqueueWrite(_ work: @escaping @Sendable () throws -> Void) async throws {
        writesInFlight += 1
        defer { writesInFlight -= 1 }
        let previous = writer
        let task = Task.detached(priority: .utility) {
            _ = await previous?.result
            try work()
        }
        writer = task
        do {
            try await task.value
        } catch {
            needsSnapshot = true
            throw error
        }
    }

    /// Waits until no write is in flight (used before erasing).
    func drainWriter() async {
        while let w = writer {
            _ = await w.result
            if writer == w { break }
        }
    }

    // MARK: Generation and journal replay

    static func storedGeneration(_ db: SQLiteDatabase) throws -> Data? {
        guard try !db.query("SELECT 1 FROM sqlite_schema WHERE name = 'store_meta'").isEmpty else { return nil }
        let gen = try db.query("SELECT v FROM store_meta WHERE k = 'generation'").first?.data(0)
        return gen?.count == 16 ? gen : nil
    }

    /// Deliberately not journaled: each snapshot carries its own.
    static func setGeneration(_ gen: Data, in db: SQLiteDatabase) throws {
        try db.query("INSERT INTO store_meta(k, v) VALUES ('generation', ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v", [.blob(gen)])
    }

    /// Replays the valid records, each in its own transaction. If a statement
    /// fails (it should not), that record is rolled back and replay stops.
    static func apply(_ replay: Journal.Replay, to db: SQLiteDatabase) throws -> Int {
        var applied = 0
        for record in replay.ops {
            try db.execute("BEGIN")
            do {
                for op in record { try db.query(legacySQL(op.sql), op.params) }
                try db.execute("COMMIT")
                applied += 1
            } catch {
                try? db.execute("ROLLBACK")
                break
            }
        }
        return applied
    }

    /// Journals written by the earlier version use SQLite's `carray()` for ID lists, which
    /// only exists in macOS 27's SQLite. Rewrite it to the portable `json_each()`
    /// form that `SQLiteValue.ids` now binds.
    static func legacySQL(_ sql: String) -> String {
        guard sql.contains("carray(") else { return sql }
        var out = sql.replacingOccurrences(of: #"IN carray\((\?[0-9]*)\)"#, with: "IN (SELECT value FROM json_each($1))", options: .regularExpression)
        out = out.replacingOccurrences(of: #"FROM carray\((\?[0-9]*)\)"#, with: "FROM json_each($1)", options: .regularExpression)
        return out
    }
}
