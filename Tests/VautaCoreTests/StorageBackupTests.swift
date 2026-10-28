// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Testing
@testable import VautaCore

@Suite("Encrypted backup and restore")
struct StorageBackupTests {
    static let password = "correct horse battery staple"

    private func record(_ store: MeetingStore, _ text: String) async throws {
        let id = try await store.startMeeting(at: .now)
        try await store.append(segment(.me, 0, text), to: id)
        try await store.endMeeting(id, at: .now)
    }

    private func backupOf(_ texts: [String]) async throws -> Data {
        let source = StoreFixture()
        let store = try source.open()
        for text in texts { try await record(store, text) }
        return try await store.createBackup(password: Self.password, appVersion: "0.9.0")
    }

    @Test func roundTripRestoresEveryMeeting() async throws {
        let file = try await backupOf(["primera reunión", "second meeting"])
        #expect(file.starts(with: Data("ACTABK".utf8)))
        let backup = try await MeetingStore.openBackup(file, password: Self.password)
        #expect(backup.meetings == 2)
        #expect(backup.manifest.appVersion == "0.9.0")
        #expect(backup.manifest.schemaVersion == Schema.currentVersion)

        let target = StoreFixture()
        var store: MeetingStore? = try target.open()
        let summary = try await store!.restore(backup)
        #expect(summary == RestoreSummary(replacedMeetings: 0, restoredMeetings: 2))
        #expect(try await store!.meetings().count == 2)

        // It is on disk, readable with the current key after reopening.
        store = nil
        let reopened = try target.open()
        #expect(try await reopened.meetings().count == 2)
    }

    @Test func contextEntriesAreCountedWithoutMeetings() async throws {
        let fixture = StoreFixture()
        let store = try fixture.open()
        #expect(try await store.contextEntryCount() == 0)
        try await store.saveGlossary(GlossaryTerm(term: "OKR", expansion: "Objectives and key results"))
        #expect(try await store.contextEntryCount() == 1)
    }

    @Test func fileContainsNoPlaintext() async throws {
        let file = try await backupOf(["texto secreto unico"])
        #expect(file.range(of: Data("texto secreto unico".utf8)) == nil)
        #expect(file.range(of: Data("SQLite format".utf8)) == nil)
    }

    @Test func wrongPasswordIsRefused() async throws {
        let file = try await backupOf(["x"])
        await expectStoreError(.backupAuthentication) { try await MeetingStore.openBackup(file, password: "another long password") }
    }

    @Test func tamperedHeaderOrPayloadIsRefused() async throws {
        let file = try await backupOf(["x"])
        // Salt (header) and a ciphertext byte.
        for offset in [14, BackupArchive.headerLength + 20, file.count - 5] {
            var bad = file
            bad[offset] ^= 0x01
            await expectStoreError(.backupAuthentication) { try await MeetingStore.openBackup(bad, password: Self.password) }
        }
        // Lowering the iteration count is a header change too.
        var weaker = file
        weaker[10] = 0x0A   // 0x000F4240 (1,000,000) -> 0x000A4240 (672,320)
        await expectStoreError(.backupAuthentication) { try await MeetingStore.openBackup(weaker, password: Self.password) }
        // Out-of-range iteration counts are refused before any derivation.
        var absurd = file
        absurd[8] = 0xFF
        await expectStoreError(.backupInvalid) { try await MeetingStore.openBackup(absurd, password: Self.password) }
    }

    @Test func truncatedAndForeignFilesAreRefused() async throws {
        let file = try await backupOf(["x"])
        await expectStoreError(.backupInvalid) { try await MeetingStore.openBackup(file.prefix(10), password: Self.password) }
        await expectStoreError(.backupInvalid) { try await MeetingStore.openBackup(Data(), password: Self.password) }
        await expectStoreError(.backupInvalid) { try await MeetingStore.openBackup(Data("not a backup at all, just text".utf8), password: Self.password) }
        await expectStoreError(.backupAuthentication) { try await MeetingStore.openBackup(file.prefix(file.count - 40), password: Self.password) }
        await expectStoreError(.backupAuthentication) { try await MeetingStore.openBackup(file.prefix(BackupArchive.headerLength + 10), password: Self.password) }
        var future = file
        future[6] = 9
        await expectStoreError(.backupUnsupported) { try await MeetingStore.openBackup(future, password: Self.password) }
    }

    @Test func newerSchemaIsRefusedWithTheRightError() async throws {
        let source = StoreFixture()
        let store = try source.open()
        try await store.setUserVersionForTests(Schema.currentVersion + 1)
        let file = try await store.createBackup(password: Self.password, appVersion: "9.9.9")
        await expectStoreError(.newerSchema) { try await MeetingStore.openBackup(file, password: Self.password) }
    }

    @Test func olderSchemaMigratesOnOpen() async throws {
        let source = StoreFixture()
        let image = try source.legacyImage(schema: 7)
        let packed = try image.withSerializedBytes(SnapshotEnvelope.pack)
        let manifest = BackupManifest(format: 1, appVersion: "0.1.0", schemaVersion: 7, createdAt: .now, meetingCount: 1)
        let file = try BackupArchive.seal(packed: packed, manifest: manifest, password: Self.password, iterations: BackupArchive.minimumIterations)
        let backup = try await MeetingStore.openBackup(file, password: Self.password)
        #expect(backup.meetings == 1)
        let target = StoreFixture()
        let store = try target.open()
        _ = try await store.restore(backup)
        #expect(try await store.pragma("user_version") == Schema.currentVersion)
        #expect(try await store.speakerCodes(1) == ["me", "others"])
    }

    @Test func restoreReplacesDataAndShredsTheOldKey() async throws {
        let file = try await backupOf(["del respaldo"])
        let target = StoreFixture()
        var store: MeetingStore? = try target.open()
        try await record(store!, "dato antiguo")
        try await record(store!, "otro antiguo")
        let oldKey = try #require(target.keys.key)
        let oldFile = try Data(contentsOf: target.snapshotURL)
        let backup = try await MeetingStore.openBackup(file, password: Self.password)

        let summary = try await store!.restore(backup)
        #expect(summary.replacedMeetings == 2)
        #expect(summary.restoredMeetings == 1)
        #expect(try await store!.imageContains("del respaldo"))
        #expect(try await !store!.imageContains("dato antiguo"))

        let newKey = try #require(target.keys.key)
        #expect(newKey.withUnsafeBytes { Data($0) } != oldKey.withUnsafeBytes { Data($0) })
        // The old copy of the store cannot be opened with the key that exists now.
        #expect(throws: StoreError.self) { try SnapshotEnvelope.open(oldFile, key: newKey) }
        #expect(!target.exists(target.journalURL))
        // The store keeps working with the new key.
        try await record(store!, "después de restaurar")
        try await store!.flush()
        store = nil
        let reopened = try target.open()
        #expect(try await reopened.meetings().count == 2)
    }

    @Test func restoreIsRefusedWhileRecordingAndBackupIsUsedOnce() async throws {
        let file = try await backupOf(["x"])
        let target = StoreFixture()
        let store = try target.open()
        let id = try await store.startMeeting(at: .now)
        let backup = try await MeetingStore.openBackup(file, password: Self.password)
        await expectStoreError(.meetingInProgress) { try await store.restore(backup) }
        try await store.endMeeting(id, at: .now)
        _ = try await store.restore(backup)
        await expectStoreError(.restoreFailed) { try await store.restore(backup) }
    }

    @Test func keychainFailureLeavesTheOriginalIntact() async throws {
        let file = try await backupOf(["del respaldo"])
        let target = StoreFixture()
        let store = try target.open()
        try await record(store, "original")
        try await store.flush()
        let keyBefore = try #require(target.keys.key).withUnsafeBytes { Data($0) }
        let fileBefore = try Data(contentsOf: target.snapshotURL)
        let backup = try await MeetingStore.openBackup(file, password: Self.password)

        target.keys.setReplaceFails(true)
        await expectStoreError(.restoreFailed) { try await store.restore(backup) }
        target.keys.setReplaceFails(false)

        #expect(try #require(target.keys.key).withUnsafeBytes { Data($0) } == keyBefore)
        #expect(try Data(contentsOf: target.snapshotURL) == fileBefore)
        #expect(try await store.imageContains("original"))
    }

    @Test func writeFailureRestoresThePreviousKey() async throws {
        let file = try await backupOf(["del respaldo"])
        let target = StoreFixture()
        var store: MeetingStore! = try target.open()
        try await record(store, "original")
        try await store.flush()
        let keyBefore = try #require(target.keys.key).withUnsafeBytes { Data($0) }
        let fileBefore = try Data(contentsOf: target.snapshotURL)
        let backup = try await MeetingStore.openBackup(file, password: Self.password)

        // A read-only directory: the new snapshot cannot be written.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: target.dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.dir.path) }
        await expectStoreError(.restoreFailed) { try await store.restore(backup) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.dir.path)

        #expect(try #require(target.keys.key).withUnsafeBytes { Data($0) } == keyBefore)
        #expect(try Data(contentsOf: target.snapshotURL) == fileBefore)
        #expect(try await store.imageContains("original"))
        try await store.flush()
        store = nil
        let reopened = try target.open()
        #expect(try await reopened.meetings().count == 1)
    }

    @Test func failedRollbackKeepsTheCurrentStoreReadable() async throws {
        let file = try await backupOf(["del respaldo"])
        let target = StoreFixture()
        var store: MeetingStore! = try target.open()
        try await record(store, "original")
        try await store.flush()
        let backup = try await MeetingStore.openBackup(file, password: Self.password)

        // The new key is stored, the snapshot write fails, and putting the old key back fails too.
        target.keys.setReplaceFails(after: 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: target.dir.path)
        await expectStoreError(.restoreFailed) { try await store.restore(backup) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.dir.path)

        #expect(try await store.imageContains("original"))
        try await store.flush()
        store = nil
        let reopened = try target.open()
        #expect(try await reopened.meetings().count == 1)
        #expect(try await reopened.imageContains("original"))
    }

    @Test func passwordRules() {
        #expect(BackupPassword.strength(of: "short") == .tooShort)
        #expect(BackupPassword.strength(of: "aaaaaaaaaaaaaaaa") == .weak)
        #expect(BackupPassword.strength(of: "correct horse battery staple") == .strong)
        #expect(!BackupPassword.isAcceptable("12345678"))
        // Long enough but trivially repetitive: weak, and refused.
        #expect(!BackupPassword.isAcceptable("aaaaaaaaaaaaaaaa"))
        #expect(!BackupPassword.isAcceptable("111111111111"))
        #expect(!BackupPassword.isAcceptable("abcabcabcabc"))
        #expect(BackupPassword.isAcceptable("abcdefabcdef"))
        #expect(BackupPassword.isAcceptable("correct horse battery staple"))
    }

    @Test func nfcAndNfdPasswordsDeriveTheSameKey() throws {
        let salt = Data(repeating: 7, count: 16)
        let a = try BackupArchive.deriveKey(password: "caf\u{e9} con leche 2026", salt: salt, iterations: 600_000)
        let b = try BackupArchive.deriveKey(password: "cafe\u{301} con leche 2026", salt: salt, iterations: 600_000)
        #expect(a.withUnsafeBytes { Data($0) } == b.withUnsafeBytes { Data($0) })
    }
}

extension MeetingStore {
    func setUserVersionForTests(_ version: SchemaVersion) throws { try db.execute("PRAGMA user_version = \(version)") }
}

extension StoreFixture {
    /// The database of `writeLegacyStore(schema:)` as an image, without migrating it.
    func legacyImage(schema: SchemaVersion) throws -> SQLiteDatabase {
        let db = try SQLiteDatabase(image: nil, size: 0)
        try Schema.migrate(db, upTo: schema)
        try StoreFixture.legacyMeeting(db)
        return db
    }
}
