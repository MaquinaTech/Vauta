// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import SQLite3
import Testing
@testable import VautaCore

/// A restored image's full-text indexes are FTS5's own binary format: they are built again from their text before anything
/// reads them, and their settings must be the ones Vauta sets (`MeetingStore.rebuildFullTextIndexes`).
@Suite("Backup restore builds the full-text indexes again")
struct StorageBackupFullTextTests {
    private static let password = StorageBackupHardeningTests.password

    private func seal(_ db: SQLiteDatabase, schema: SchemaVersion = Schema.currentVersion) throws -> Data {
        let packed = try db.withSerializedBytes(SnapshotEnvelope.pack)
        let manifest = BackupManifest(format: 1, appVersion: "0.9.0", schemaVersion: schema, createdAt: .now, meetingCount: 1)
        return try BackupArchive.seal(packed: packed, manifest: manifest, password: Self.password,
                                      iterations: BackupArchive.minimumIterations)
    }

    @Test func everyFullTextIndexOfTheSchemaIsRebuilt() throws {
        let db = try SQLiteDatabase(image: nil, size: 0)
        try Schema.migrate(db)
        let indexes = try db.query("SELECT name FROM sqlite_schema WHERE type = 'table' AND sql LIKE 'CREATE VIRTUAL TABLE%USING fts5%'")
            .map { $0.string(0) }
        #expect(Set(indexes) == Set(MeetingStore.fullTextIndexes))
    }

    /// SQLite keeps the index's own tables read-only to SQL, so a crafted index can only come from the bytes of an image.
    @Test func theIndexTablesCannotBeWrittenWithSQL() throws {
        let db = try StoreFixture().legacyImage(schema: Schema.currentVersion)
        #expect(throws: StoreError.self) { try db.execute("UPDATE segments_fts_data SET block = zeroblob(8) WHERE id > 10") }
    }

    /// The image with the index's copy of a word changed in its bytes, as a crafted backup could have it; the segment's own
    /// text is left as it is.
    private func imageWithDamagedIndex() throws -> SQLiteDatabase {
        var bytes = try StoreFixture().legacyImage(schema: Schema.currentVersion).withSerializedBytes { Data($0) }
        let word = Data("heredado".utf8), before = Data("texto ".utf8)
        var damaged = 0
        var from = bytes.startIndex
        while let range = bytes.range(of: word, in: from..<bytes.endIndex) {
            from = range.upperBound
            if range.lowerBound >= before.count, bytes[(range.lowerBound - before.count)..<range.lowerBound] == before { continue }
            bytes[range.upperBound - 1] = UInt8(ascii: "x")
            damaged += 1
        }
        #expect(damaged > 0, "the index holds the word")
        let buffer = try #require(sqlite3_malloc64(UInt64(bytes.count)))
        bytes.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: bytes.count)
        return try SQLiteDatabase(image: buffer, size: bytes.count)
    }

    @Test func aDamagedIndexIsReplacedNotRead() async throws {
        let db = try imageWithDamagedIndex()
        // SQLite's own check reads an external-content index without comparing it with the text: it passes this one.
        #expect(try db.query("SELECT rowid FROM segments_fts WHERE segments_fts MATCH 'heredado'").isEmpty, "the damaged index misses the word")
        let backup = try await MeetingStore.openBackup(seal(db), password: Self.password)
        let restored = try #require(backup.take())
        #expect(try restored.query("PRAGMA integrity_check").first?.string(0) == "ok")
        let found = try restored.query("SELECT rowid FROM segments_fts WHERE segments_fts MATCH 'heredado'")
        #expect(found.count == 1, "the rebuilt index finds the transcript's words")
        for table in MeetingStore.fullTextIndexes {
            let secure = try restored.query("SELECT v FROM \"\(table)_config\" WHERE k = 'secure-delete'")
            #expect(secure.first?.int(0) == 1, "\(table) still deletes for good")
        }
    }

    @Test(arguments: [
        "INSERT INTO segments_fts(segments_fts, rank) VALUES ('secure-delete', 0)",
        "INSERT INTO knowledge_fts(knowledge_fts, rank) VALUES ('pgsz', 64)",
        "INSERT INTO names_fts(names_fts, rank) VALUES ('rank', 'bm25(10.0)')",
        "INSERT INTO names_fts(names_fts, rank) VALUES ('automerge', 2)",
    ])
    func settingsVautaNeverSetsAreRefused(_ setting: String) async throws {
        let db = try StoreFixture().legacyImage(schema: Schema.currentVersion)
        try db.execute(setting)
        let file = try seal(db)
        await expectStoreError(.backupInvalid) { try await MeetingStore.openBackup(file, password: Self.password) }
    }

    /// Before migration 4 there are no names or knowledge indexes, and before 6 no `secure-delete`: the migrations add them.
    @Test(arguments: [1, 3, 5] as [SchemaVersion])
    func anOlderImageOpensWithTheIndexesItHas(_ schema: SchemaVersion) async throws {
        let db = try StoreFixture().legacyImage(schema: schema)
        let backup = try await MeetingStore.openBackup(seal(db, schema: schema), password: Self.password)
        #expect(backup.meetings == 1)
        let restored = try #require(backup.take())
        #expect(try restored.query("SELECT rowid FROM segments_fts WHERE segments_fts MATCH 'respuesta'").count == 1)
    }
}
