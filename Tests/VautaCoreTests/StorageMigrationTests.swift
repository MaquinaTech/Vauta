// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Testing
@testable import VautaCore

/// Stores written by Acta 0.1.x (`acta.*` names) must open in Vauta without losing anything.
@Suite("Storage migration from the Acta file names")
struct StorageMigrationTests {
    private let oldSnapshot = StoreFiles.Legacy.snapshot
    private let oldJournal = StoreFiles.Legacy.journal

    private func url(_ fx: StoreFixture, _ name: String) -> URL { fx.dir.appendingPathComponent(name) }

    private func names(_ fx: StoreFixture) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: fx.dir.path)) ?? [])
    }

    private func move(_ fx: StoreFixture, _ from: String, _ to: String) throws {
        try FileManager.default.moveItem(at: url(fx, from), to: url(fx, to))
    }

    /// A snapshot with `meetings` finished meetings, placed under `name`.
    private func seed(_ fx: StoreFixture, as name: String, meetings: Int, generation: Data? = nil) throws {
        try fx.writeLegacyStore(schema: 7, generation: generation) { db in
            for i in 0..<meetings {
                try db.query("INSERT INTO meetings(id, started_at, ended_at, title) VALUES (?, 0, 1, ?)",
                             [.integer(Int64(i + 1)), .text("meeting \(i + 1)")])
            }
        }
        if name != StoreFiles.snapshot { try move(fx, StoreFiles.snapshot, name) }
    }

    /// A journal record adding meeting number `id`, placed under `name`.
    private func seedJournal(_ fx: StoreFixture, as name: String, generation: Data, id: Int64) throws {
        let key = Journal.key(from: try #require(fx.keys.key))
        let op = JournalOp(sql: "INSERT INTO meetings(id, started_at, ended_at, title) VALUES (?, 0, 1, 'journaled')", params: [.integer(id)])
        let record = try Journal.seal(Journal.encode([op]), seq: 0, generation: generation, key: key)
        try Journal.append(record, generation: generation, to: url(fx, name))
    }

    private func rows(_ store: MeetingStore) async throws -> Int64 { try await store.rowCount("meetings") }

    // MARK: Plain paths

    @Test func onlyLegacyFilesAreRenamedAndOpen() async throws {
        let fx = StoreFixture()
        let generation = Journal.newGeneration()
        try seed(fx, as: oldSnapshot, meetings: 1, generation: generation)
        try seedJournal(fx, as: oldJournal, generation: generation, id: 2)
        let before = try Data(contentsOf: url(fx, oldSnapshot))

        let store = try fx.open()
        #expect(try await rows(store) == 2, "snapshot and journal both came along")
        #expect(names(fx).isSuperset(of: [StoreFiles.snapshot, StoreFiles.journal]))
        #expect(!names(fx).contains(oldSnapshot) && !names(fx).contains(oldJournal))
        #expect(try Data(contentsOf: url(fx, StoreFiles.snapshot)) == before, "renamed, not rewritten")
        #expect(store.migrationReport.renamed.count == 2 && store.migrationReport.setAside.isEmpty)
    }

    @Test func onlyNewFilesAreLeftAlone() async throws {
        let fx = StoreFixture()
        try seed(fx, as: StoreFiles.snapshot, meetings: 2)
        let store = try fx.open()
        #expect(try await rows(store) == 2)
        #expect(store.migrationReport.isEmpty)
        #expect(names(fx).filter { $0.hasPrefix("acta") }.isEmpty)
    }

    @Test func aFreshInstallUsesNewNamesOnly() async throws {
        let fx = StoreFixture()
        let store = try fx.open(recover: true)
        _ = store
        #expect(names(fx).contains(StoreFiles.snapshot) && names(fx).contains(StoreFiles.lock))
        #expect(names(fx).filter { $0.hasPrefix("acta") }.isEmpty)
    }

    @Test func migrationIsIdempotentAcrossOpens() async throws {
        let fx = StoreFixture()
        try seed(fx, as: oldSnapshot, meetings: 3)
        do { let store = try fx.open(); #expect(try await rows(store) == 3) }
        let second = try fx.open()
        #expect(try await rows(second) == 3)
        #expect(second.migrationReport.isEmpty)
    }

    // MARK: Both present

    @Test func bothSnapshotsKeepTheRicherAndSetTheOtherAside() async throws {
        let fx = StoreFixture()
        try seed(fx, as: oldSnapshot, meetings: 3)
        try seed(fx, as: StoreFiles.snapshot, meetings: 0)   // e.g. an old build started again after a migration
        let legacyBytes = try Data(contentsOf: url(fx, oldSnapshot))
        let store = try fx.open()
        #expect(try await rows(store) == 3)
        let report = store.migrationReport
        #expect(report.setAside.count == 1 && report.setAside[0].hasPrefix("\(StoreFiles.snapshot) -> \(StoreFiles.snapshot).legacy-"))
        #expect(names(fx).filter(StoreFiles.isAside).count == 1, "the other file was moved, not deleted")
        #expect(!names(fx).contains(oldSnapshot))
        #expect(try Data(contentsOf: url(fx, StoreFiles.snapshot)) == legacyBytes)
    }

    @Test func bothSnapshotsPreferTheNewOneWhenItHoldsMore() async throws {
        let fx = StoreFixture()
        try seed(fx, as: oldSnapshot, meetings: 1)
        try seed(fx, as: StoreFiles.snapshot, meetings: 4)
        let store = try fx.open()
        #expect(try await rows(store) == 4)
        #expect(!names(fx).contains(oldSnapshot))
        let aside = names(fx).filter(StoreFiles.isAside)
        #expect(aside.count == 1 && aside.first?.hasPrefix(oldSnapshot + StoreFiles.asideInfix) == true)
        // The set-aside file is still a valid snapshot with its data.
        let moved = try SnapshotEnvelope.open(Data(contentsOf: url(fx, try #require(aside.first))), key: try #require(fx.keys.key))
        _ = try SQLiteDatabase(image: moved.0, size: moved.1)
    }

    @Test func bothSnapshotsWithAnUnreadableOneKeepTheReadable() async throws {
        let fx = StoreFixture()
        try seed(fx, as: oldSnapshot, meetings: 2)
        try Data("garbage".utf8).write(to: url(fx, StoreFiles.snapshot))
        let store = try fx.open()
        #expect(try await rows(store) == 2)
        #expect(names(fx).filter(StoreFiles.isAside).count == 1, "the damaged file is kept aside, not deleted")
    }

    @Test func bothJournalsKeepTheOneOfTheSnapshotInPlace() async throws {
        let fx = StoreFixture()
        let generation = Journal.newGeneration()
        try seed(fx, as: StoreFiles.snapshot, meetings: 1, generation: generation)
        try seedJournal(fx, as: StoreFiles.journal, generation: generation, id: 2)
        try seedJournal(fx, as: oldJournal, generation: generation, id: 9)
        let store = try fx.open()
        #expect(try await rows(store) == 2)
        #expect(!names(fx).contains(oldJournal))
        #expect(names(fx).contains { $0.hasPrefix(oldJournal + StoreFiles.asideInfix) })
    }

    // MARK: Interrupted migrations

    @Test func interruptedAfterTheSnapshotRenameFinishesTheJournal() async throws {
        let fx = StoreFixture()
        let generation = Journal.newGeneration()
        try seed(fx, as: oldSnapshot, meetings: 1, generation: generation)
        try seedJournal(fx, as: oldJournal, generation: generation, id: 2)
        try move(fx, oldSnapshot, StoreFiles.snapshot)   // the crash happened here
        let store = try fx.open()
        #expect(try await rows(store) == 2, "the journal still pairs with the snapshot")
        #expect(names(fx).contains(StoreFiles.journal) && !names(fx).contains(oldJournal))
    }

    @Test func interruptedBeforeAnyRenameRunsFromScratch() async throws {
        // Crash before the first rename is the "only legacy" state; the verification left no trace.
        let fx = StoreFixture()
        try seed(fx, as: oldSnapshot, meetings: 1)
        _ = try? fx.open(createIfMissing: false)   // read-only look first
        #expect(names(fx).contains(oldSnapshot) && !names(fx).contains(StoreFiles.snapshot))
        let store = try fx.open()
        #expect(try await rows(store) == 1)
    }

    @Test func interruptedWhileSettingAsideTheNewPairRedecidesTheSame() async throws {
        // keepLegacy: new journal already set aside, new snapshot still in place.
        let fx = StoreFixture()
        let generation = Journal.newGeneration()
        try seed(fx, as: oldSnapshot, meetings: 3, generation: generation)
        try seedJournal(fx, as: oldJournal, generation: generation, id: 4)
        try seed(fx, as: StoreFiles.snapshot, meetings: 0)
        try Data("stray".utf8).write(to: url(fx, StoreFiles.journal + StoreFiles.asideInfix + "1"))
        let store = try fx.open()
        #expect(try await rows(store) == 4)
        #expect(names(fx).filter(StoreFiles.isAside).count == 2)
    }

    @Test func interruptedAfterTheNewPairWasSetAsideCompletes() async throws {
        // keepLegacy: both new files already aside, legacy pair untouched.
        let fx = StoreFixture()
        let generation = Journal.newGeneration()
        try seed(fx, as: oldSnapshot, meetings: 3, generation: generation)
        try seedJournal(fx, as: oldJournal, generation: generation, id: 4)
        try Data("x".utf8).write(to: url(fx, StoreFiles.snapshot + StoreFiles.asideInfix + "1"))
        let store = try fx.open()
        #expect(try await rows(store) == 4)
        #expect(names(fx).contains(StoreFiles.snapshot) && !names(fx).contains(oldSnapshot))
    }

    @Test func interruptedWhileKeepingTheNewPairCompletes() async throws {
        // keepCurrent: legacy journal already aside, legacy snapshot still in place.
        let fx = StoreFixture()
        try seed(fx, as: oldSnapshot, meetings: 1)
        try seed(fx, as: StoreFiles.snapshot, meetings: 5)
        try Data("x".utf8).write(to: url(fx, oldJournal + StoreFiles.asideInfix + "1"))
        let store = try fx.open()
        #expect(try await rows(store) == 5)
        #expect(!names(fx).contains(oldSnapshot))
    }

    // MARK: Failure keeps the legacy files

    @Test func missingKeyLeavesLegacyFilesUntouched() async throws {
        let fx = StoreFixture()
        try seed(fx, as: oldSnapshot, meetings: 1)
        try fx.keys.remove()
        let before = names(fx)
        await expectStoreError(.missingKey) { try fx.open(waitForLock: false) }
        #expect(names(fx).filter { !$0.hasSuffix(".lock") } == before.filter { !$0.hasSuffix(".lock") })
        #expect(names(fx).contains(oldSnapshot) && !names(fx).contains(StoreFiles.snapshot))
        #expect(fx.keys.key == nil, "no key was created for an existing store")
    }

    @Test func wrongKeyLeavesLegacyFilesUntouched() async throws {
        let fx = StoreFixture()
        try seed(fx, as: oldSnapshot, meetings: 1)
        let original = try Data(contentsOf: url(fx, oldSnapshot))
        try fx.keys.replace(with: SymmetricKey(size: .bits256))
        await expectStoreError(.unreadableStore) { try fx.open() }
        #expect(names(fx).contains(oldSnapshot) && !names(fx).contains(StoreFiles.snapshot))
        #expect(try Data(contentsOf: url(fx, oldSnapshot)) == original)
    }

    @Test func unreadableFileLeavesLegacyFilesUntouched() async throws {
        let fx = StoreFixture()
        try seed(fx, as: oldSnapshot, meetings: 1)
        let path = url(fx, oldSnapshot).path
        chmod(path, 0)
        defer { chmod(path, 0o600) }
        #expect(throws: (any Error).self) { try fx.open() }
        #expect(names(fx).contains(oldSnapshot) && !names(fx).contains(StoreFiles.snapshot))
    }

    @Test func aFailureAfterTheRenamesPutsTheOldNamesBack() async throws {
        let fx = StoreFixture()
        let generation = Journal.newGeneration()
        try fx.writeLegacyStore(schema: 7, userVersion: Schema.currentVersion + 1, generation: generation)
        try move(fx, StoreFiles.snapshot, oldSnapshot)
        try seedJournal(fx, as: oldJournal, generation: generation, id: 2)
        await expectStoreError(.newerSchema) { try fx.open() }
        #expect(names(fx).isSuperset(of: [oldSnapshot, oldJournal]))
        #expect(!names(fx).contains(StoreFiles.snapshot) && !names(fx).contains(StoreFiles.journal))
    }

    // MARK: Locks

    @Test func legacyLockIsHeldWhileTheStoreIsOpen() async throws {
        let fx = StoreFixture()
        try seed(fx, as: oldSnapshot, meetings: 1)
        try Data().write(to: url(fx, StoreFiles.Legacy.lock))
        let store = try fx.open()
        #expect(throws: StoreError.self) { try InstanceLock(url(fx, StoreFiles.Legacy.lock)) }
        #expect(throws: StoreError.self) { try InstanceLock(url(fx, StoreFiles.lock)) }
        _ = store
    }

    @Test func aRunningOldBuildBlocksOpening() async throws {
        let fx = StoreFixture()
        try seed(fx, as: oldSnapshot, meetings: 1)
        let oldBuild = try InstanceLock(url(fx, StoreFiles.Legacy.lock))
        await expectStoreError(.alreadyOpen) { try fx.open(waitForLock: false) }
        #expect(names(fx).contains(oldSnapshot) && !names(fx).contains(StoreFiles.snapshot), "nothing moved under another process")
        _ = oldBuild
    }

    // MARK: Read-only open

    @Test func readOnlyOpenOfALegacyStoreChangesNothing() async throws {
        let fx = StoreFixture()
        try seed(fx, as: oldSnapshot, meetings: 2)
        let before = names(fx)
        let store = try fx.open(createIfMissing: false)
        #expect(try await store.stats().meetings == 2)
        #expect(store.fileURL.lastPathComponent == oldSnapshot)
        #expect(names(fx).subtracting(before).subtracting([StoreFiles.Legacy.lock]).isEmpty, "no vauta.* file appears")
    }

    // MARK: Erase

    @Test func eraseEverythingRemovesBothNamesAndSetAsideFiles() async throws {
        let fx = StoreFixture()
        try seed(fx, as: StoreFiles.snapshot, meetings: 1)
        let store = try fx.open()
        for name in [oldSnapshot, oldJournal, StoreFiles.journal, oldSnapshot + StoreFiles.asideInfix + "5",
                     StoreFiles.journal + StoreFiles.asideInfix + "5"] {
            try Data("x".utf8).write(to: url(fx, name))
        }
        try await store.eraseEverything()
        let left = names(fx)
        #expect(!left.contains(oldSnapshot) && !left.contains(oldJournal) && !left.contains(StoreFiles.journal))
        #expect(left.filter(StoreFiles.isAside).isEmpty)
        #expect(left.contains(StoreFiles.snapshot), "a fresh empty store under the new name")
        #expect(try await rows(store) == 0)
    }

    @Test func aLegacyEraseMarkerCompletesTheCryptoShred() async throws {
        let fx = StoreFixture()
        _ = try fx.keys.key(createIfMissing: true)
        let oldKey = try #require(fx.keys.key).withUnsafeBytes { Data($0) }
        try FileManager.default.createDirectory(at: fx.dir, withIntermediateDirectories: true)
        try Data().write(to: url(fx, StoreFiles.Legacy.eraseMarker))
        _ = try fx.open(recover: true)
        #expect(try #require(fx.keys.key).withUnsafeBytes { Data($0) } != oldKey)
        #expect(!names(fx).contains(StoreFiles.Legacy.eraseMarker))
    }

    @Test func recoveryRemovesTemporariesOfBothNames() async throws {
        let fx = StoreFixture()
        try seed(fx, as: oldSnapshot, meetings: 1)
        try Data("x".utf8).write(to: url(fx, StoreFiles.Legacy.tempPrefix + "orphan"))
        try Data("x".utf8).write(to: url(fx, StoreFiles.tempPrefix + "orphan"))
        _ = try fx.open(recover: true)
        #expect(!names(fx).contains { StoreFiles.isTemporary($0) })
    }

    // MARK: Directory

    @Test func theAppSupportDirectoryIsRenamedOnce() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-dir-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("Acta"), new = base.appendingPathComponent("Vauta")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: old.appendingPathComponent(oldSnapshot))
        #expect(MeetingStore.locateDirectory(under: base).path == old.path, "looking never moves anything")
        #expect(FileManager.default.fileExists(atPath: old.path))
        #expect(try MeetingStore.moveDirectoryIfNeeded(under: base).url.path == new.path)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent(oldSnapshot).path))
        #expect(try MeetingStore.moveDirectoryIfNeeded(under: base).url.path == new.path)
    }

    @Test func anEmptyNewDirectoryDoesNotBlockTheMove() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-dir-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("Acta"), new = base.appendingPathComponent("Vauta")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: old.appendingPathComponent(oldSnapshot))
        #expect(try MeetingStore.moveDirectoryIfNeeded(under: base).url.path == new.path)
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent(oldSnapshot).path))
    }

    @Test func aNonEmptyNewDirectoryWithoutStoreFallsBackToTheOldOne() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-dir-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("Acta"), new = base.appendingPathComponent("Vauta")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: old.appendingPathComponent(oldSnapshot))
        try Data("y".utf8).write(to: new.appendingPathComponent("unrelated"))
        #expect(try MeetingStore.moveDirectoryIfNeeded(under: base).url.path == old.path)
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("unrelated").path))
    }

    @Test func aStoreInTheNewDirectoryWinsAndTheOldOneIsNeverTouched() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-dir-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("Acta"), new = base.appendingPathComponent("Vauta")
        for dir in [old, new] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data("x".utf8).write(to: old.appendingPathComponent(oldSnapshot))
        try Data("y".utf8).write(to: new.appendingPathComponent(StoreFiles.snapshot))
        #expect(try MeetingStore.moveDirectoryIfNeeded(under: base).url.path == new.path)
        #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent(oldSnapshot).path))
    }

    /// A legacy store with one meeting in `<base>/Acta`, keyed by `fx.keys`.
    private func legacyFolder(_ fx: StoreFixture) throws -> (base: URL, old: URL, new: URL) {
        try seed(fx, as: oldSnapshot, meetings: 1)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let old = base.appendingPathComponent("Acta"), new = base.appendingPathComponent("Vauta")
        try FileManager.default.moveItem(at: fx.dir, to: old)
        return (base, old, new)
    }

    @Test func theFolderIsNeverMovedFromUnderARunningBuild() throws {
        for lockName in [StoreFiles.Legacy.lock, StoreFiles.lock] {
            let fx = StoreFixture()
            let (base, old, new) = try legacyFolder(fx)
            defer { try? FileManager.default.removeItem(at: base) }
            let running = try InstanceLock(old.appendingPathComponent(lockName))
            #expect { try MeetingStore.moveDirectoryIfNeeded(under: base) } throws: { ($0 as? StoreError)?.code == .alreadyOpen }
            #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent(oldSnapshot).path))
            #expect(!FileManager.default.fileExists(atPath: new.path), "\(lockName): nothing moved")
            _ = running
        }
    }

    @Test func theFirstOpenMovesTheFolderAndKeepsItLocked() async throws {
        let fx = StoreFixture()
        let (base, old, new) = try legacyFolder(fx)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try MeetingStore(directory: nil, keyStore: fx.keys, applicationSupport: base)
        #expect(try await rows(store) == 1)
        #expect(store.fileURL.path == new.appendingPathComponent(StoreFiles.snapshot).path)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect { try InstanceLock(new.appendingPathComponent(StoreFiles.Legacy.lock)) } throws: { ($0 as? StoreError)?.code == .alreadyOpen }
        #expect { try InstanceLock(new.appendingPathComponent(StoreFiles.lock)) } throws: { ($0 as? StoreError)?.code == .alreadyOpen }
    }

    @Test func aFailedFirstOpenPutsTheFolderBack() async throws {
        let fx = StoreFixture()
        let (base, old, new) = try legacyFolder(fx)
        defer { try? FileManager.default.removeItem(at: base) }
        let key = try #require(fx.keys.key)
        try fx.keys.remove()   // a denied Keychain prompt looks the same: no key
        await expectStoreError(.missingKey) { try MeetingStore(directory: nil, keyStore: fx.keys, applicationSupport: base) }
        #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent(oldSnapshot).path), "old folder and names are back")
        #expect(!FileManager.default.fileExists(atPath: new.path))
        try fx.keys.replace(with: key)
        let store = try MeetingStore(directory: nil, keyStore: fx.keys, applicationSupport: base)
        #expect(try await rows(store) == 1)
        #expect(store.fileURL.path == new.appendingPathComponent(StoreFiles.snapshot).path)
    }

    @Test func anUnfinishedEraseInTheOldFolderStillShredsTheKey() throws {
        let fx = StoreFixture()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-dir-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("Acta")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data().write(to: old.appendingPathComponent(StoreFiles.Legacy.eraseMarker))
        let shredded = try fx.keys.key(createIfMissing: true).withUnsafeBytes { Data($0) }
        _ = try MeetingStore(directory: nil, keyStore: fx.keys, recoverOpenMeetings: true, applicationSupport: base)
        #expect(try #require(fx.keys.key).withUnsafeBytes { Data($0) } != shredded, "the key of the erased store is not reused")
    }

    @Test func nothingAnywhereMeansTheNewDirectory() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-dir-\(UUID().uuidString)")
        #expect(MeetingStore.locateDirectory(under: base).path == base.appendingPathComponent("Vauta").path)
    }

    // MARK: Frozen format identifiers and backups

    @Test func formatIdentifiersNeverChange() throws {
        #expect(SnapshotEnvelope.magic == Data("ACTA".utf8))
        #expect(Journal.magic == Data("ACTJ".utf8))
        #expect(BackupArchive.magic == Data("ACTABK".utf8))
        let database = SymmetricKey(size: .bits256)
        let expected = HKDF<SHA256>.deriveKey(inputKeyMaterial: database, info: Data("acta-journal-v1".utf8), outputByteCount: 32)
        #expect(Journal.key(from: database) == expected)
    }

    @Test func backupFileTypesAcceptBothExtensions() {
        #expect(BackupFileTypes.current == "vautabackup" && BackupFileTypes.legacy == "actabackup")
        #expect(BackupFileTypes.accepted == ["vautabackup", "actabackup"])
    }

    @Test func aBackupWithTheOldExtensionRestores() async throws {
        let source = StoreFixture()
        let store = try source.open()
        let id = try await store.startMeeting(at: .now)
        try await store.append(segment(.me, 0, "backup viejo"), to: id)
        try await store.endMeeting(id, at: .now)
        let data = try await store.createBackup(password: "correct horse battery staple", appVersion: "0.1.0")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("old-\(UUID().uuidString).\(BackupFileTypes.legacy)")
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file)

        // Restore never looks at the extension: it reads the content (magic "ACTABK").
        let backup = try await MeetingStore.openBackup(Data(contentsOf: file), password: "correct horse battery staple")
        let target = StoreFixture()
        let restored = try target.open()
        let summary = try await restored.restore(backup)
        #expect(summary.restoredMeetings == 1)
    }

    @Test func restoreOverALegacyNamedStoreLeavesOnlyNewNames() async throws {
        let source = StoreFixture()
        let from = try source.open()
        let id = try await from.startMeeting(at: .now)
        try await from.append(segment(.me, 0, "restaurada"), to: id)
        try await from.endMeeting(id, at: .now)
        let backup = try await MeetingStore.openBackup(from.createBackup(password: "correct horse battery staple", appVersion: "0.9.0"),
                                                       password: "correct horse battery staple")
        let fx = StoreFixture()
        try seed(fx, as: oldSnapshot, meetings: 2)
        let store = try fx.open()
        _ = try await store.restore(backup)
        #expect(!names(fx).contains(oldSnapshot) && !names(fx).contains(oldJournal))
        #expect(try await rows(store) == 1)
    }
}
