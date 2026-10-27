// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import VautaCore

@Suite("Backup restore treats the database image as untrusted")
struct StorageBackupHardeningTests {
    static let password = "correct horse battery staple"

    private func seal(_ db: SQLiteDatabase, schema: SchemaVersion) throws -> Data {
        let packed = try db.withSerializedBytes(SnapshotEnvelope.pack)
        let manifest = BackupManifest(format: 1, appVersion: "0.9.0", schemaVersion: schema, createdAt: .now, meetingCount: 1)
        return try BackupArchive.seal(packed: packed, manifest: manifest, password: Self.password,
                                      iterations: BackupArchive.minimumIterations)
    }

    private func image(schema: SchemaVersion = Schema.currentVersion) throws -> SQLiteDatabase {
        try StoreFixture().legacyImage(schema: schema)
    }

    @Test func aGenuineImageIsAccepted() async throws {
        let file = try seal(image(), schema: Schema.currentVersion)
        let backup = try await MeetingStore.openBackup(file, password: Self.password)
        #expect(backup.meetings == 1)
    }

    @Test func everyOlderSchemaPassesTheAllowList() throws {
        for version in 1...Schema.currentVersion {
            let db = try SQLiteDatabase(image: nil, size: 0)
            try Schema.migrate(db, upTo: version)
            try BackupSchemaGuard.validate(db)
        }
    }

    @Test(arguments: [
        "CREATE TRIGGER evil AFTER INSERT ON meetings BEGIN DELETE FROM segments; END",
        "CREATE VIEW evil AS SELECT 1",
        "CREATE TABLE evil (x)",
        "CREATE INDEX evil ON meetings(started_at)",
        "CREATE VIRTUAL TABLE evil USING fts5(x)",
        "CREATE VIRTUAL TABLE evil USING rtree(id, a, b)",
    ])
    func extraSchemaObjectsAreRefused(_ ddl: String) async throws {
        let db = try image()
        try db.execute(ddl)
        let file = try seal(db, schema: Schema.currentVersion)
        await expectStoreError(.backupInvalid) { try await MeetingStore.openBackup(file, password: Self.password) }
    }

    @Test func aChangedTriggerBodyIsRefused() throws {
        let db = try image()
        let row = try db.query("SELECT name FROM sqlite_schema WHERE type = 'trigger' LIMIT 1")
        let name = try #require(row.first?.string(0))
        try db.execute("DROP TRIGGER \"\(name)\"; CREATE TRIGGER \"\(name)\" AFTER DELETE ON meetings BEGIN SELECT 1; END")
        #expect(throws: StoreError.self) { try BackupSchemaGuard.validate(db) }
    }

    /// An image written by an older build or macOS may show SQLite's own rewriting of a statement (quotes, spacing); a real
    /// change is still a difference.
    @Test func theSchemaComparisonIgnoresQuotingAndSpacingOnly() {
        let plain = "CREATE TABLE t(a INTEGER NOT NULL DEFAULT 'x  y', b TEXT)"
        let rewritten = "CREATE TABLE \"t\"(\n    \"a\" INTEGER NOT NULL DEFAULT 'x  y',\n  [b] TEXT )"
        #expect(BackupSchemaGuard.normalized(plain) == BackupSchemaGuard.normalized(rewritten))
        #expect(BackupSchemaGuard.normalized(plain) != BackupSchemaGuard.normalized(plain.replacingOccurrences(of: "'x  y'", with: "'x y'")))
        #expect(BackupSchemaGuard.normalized(plain) != BackupSchemaGuard.normalized(plain.replacingOccurrences(of: "b TEXT", with: "b BLOB")))
    }

    @Test func connectionsDoNotTrustTheSchema() throws {
        let db = try SQLiteDatabase(image: nil, size: 0)
        #expect(try db.query("PRAGMA trusted_schema")[0].int(0) == 0)
        #expect(try db.query("PRAGMA cell_size_check")[0].int(0) == 1)
    }

    @Test func declaredSizesAreBounded() {
        func envelope(size: UInt64, method: UInt8, payload: Int) -> Data {
            var data = Data()
            withUnsafeBytes(of: size.littleEndian) { data.append(contentsOf: $0) }
            data.append(method)
            data.append(Data(repeating: 0, count: payload))
            return data
        }
        #expect(throws: StoreError.self) { _ = try SnapshotEnvelope.unpack(envelope(size: 60 << 30, method: 1, payload: 16), maxSize: SnapshotEnvelope.maximumBackupImageSize) }
        #expect(throws: StoreError.self) { _ = try SnapshotEnvelope.unpack(envelope(size: 1 << 29, method: 1, payload: 16), maxSize: SnapshotEnvelope.maximumBackupImageSize) }
        #expect(throws: StoreError.self) { _ = try SnapshotEnvelope.unpack(envelope(size: (1 << 30) + 1, method: 0, payload: 16), maxSize: SnapshotEnvelope.maximumBackupImageSize) }
        // A stored image must be exactly its payload: a tiny payload cannot make Vauta allocate its declared size.
        #expect(throws: StoreError.self) { _ = try SnapshotEnvelope.unpack(envelope(size: 1 << 29, method: 0, payload: 16), maxSize: SnapshotEnvelope.maximumBackupImageSize) }
        // An unknown method is refused before any allocation, whatever size it declares.
        #expect(throws: StoreError.self) { _ = try SnapshotEnvelope.unpack(envelope(size: 1 << 29, method: 2, payload: 16), maxSize: SnapshotEnvelope.maximumBackupImageSize) }
    }

    /// The cap on a backup must not lock the user out of their own store: whatever `pack` writes, `open` reads.
    @Test func theUsersOwnStoreOpensAtAnySizePackWrites() throws {
        #expect(SnapshotEnvelope.maximumStoreImageSize > SnapshotEnvelope.maximumBackupImageSize)
        let image = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 7) })
        let packed = try image.withUnsafeBytes { try SnapshotEnvelope.pack($0) }
        let key = SymmetricKey(size: .bits256)
        let sealed = try SnapshotEnvelope.seal(packed, key: key)
        let (buffer, size) = try SnapshotEnvelope.open(sealed, key: key)
        defer { sqlite3_free(buffer) }
        #expect(size == image.count)
        // The backup path is stricter, and says no for a size the store path accepts.
        let plain = Data(packed.bytes)
        #expect(throws: StoreError.self) { _ = try SnapshotEnvelope.unpack(plain, maxSize: 1 << 20) }
    }

    @Test func iterationCeilingIsRefusedBeforeDerivation() throws {
        let db = try image()
        let file = try seal(db, schema: Schema.currentVersion)
        var tampered = file
        let offset = BackupArchive.magic.count + 2
        withUnsafeBytes(of: (BackupArchive.maximumIterations + 1).bigEndian) { tampered.replaceSubrange(offset..<offset + 4, with: $0) }
        #expect(throws: StoreError.self) { _ = try BackupArchive.open(tampered, password: Self.password) }
    }

    /// Seeded corruption of a genuine image: opening, validating and checking it must fail cleanly or pass, never crash.
    @Test func corruptedImagesNeverCrash() throws {
        let source = try image()
        let original = try source.withSerializedBytes { Data($0) }
        var state: UInt64 = 0x5EED_BAC0_0001
        func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        for _ in 0..<150 {
            var bytes = original
            for _ in 0..<(1 + Int(next() % 8)) {
                let at = Int(next()) % bytes.count
                bytes[at] = UInt8(truncatingIfNeeded: next())
            }
            guard let buffer = sqlite3_malloc64(UInt64(bytes.count)) else { continue }
            bytes.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: bytes.count)
            guard let db = try? SQLiteDatabase(image: buffer, size: bytes.count) else { continue }
            if (try? BackupSchemaGuard.validate(db)) != nil {
                _ = try? db.query("PRAGMA integrity_check")
                _ = try? db.query("SELECT COUNT(*) FROM meetings")
            }
        }
    }
}
