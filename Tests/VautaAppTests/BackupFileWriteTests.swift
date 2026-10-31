// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Testing
@testable import VautaCore
@testable import Vauta

private final class MemoryKey: DatabaseKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    func existingKey() throws -> SymmetricKey? { lock.withLock { key } }
    func createKey() throws -> SymmetricKey { lock.withLock { let k = SymmetricKey(size: .bits256); key = k; return k } }
    func remove() throws { lock.withLock { key = nil } }
    func replace(with key: SymmetricKey) throws { lock.withLock { self.key = key } }
}

/// The backup file is written whole or not at all: a backup it replaces is never truncated. Once written, it is read back
/// from the disk and opened as a restore would (`BackupModel.check`).
@Suite("Backup file write")
struct BackupFileWriteTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-backup-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func replacesAnExistingBackupWhole() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.vautabackup")
        try Data(repeating: 1, count: 4096).write(to: url)
        try BackupModel.write(Data(repeating: 2, count: 10), to: url)
        #expect(try Data(contentsOf: url) == Data(repeating: 2, count: 10))
    }

    @Test func aRefusedWriteLeavesTheExistingBackupIntact() throws {
        let dir = try folder()
        let url = dir.appendingPathComponent("a.vautabackup")
        let old = Data(repeating: 1, count: 4096)
        try old.write(to: url)
        // A folder where no file can be created: the atomic write is refused, the file itself is still writable.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        #expect(throws: (any Error).self) { try BackupModel.write(Data(repeating: 2, count: 10), to: url) }
        #expect(try Data(contentsOf: url) == old)
    }

    @Test func writesANewFile() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("new.vautabackup")
        try BackupModel.write(Data("x".utf8), to: url)
        #expect(try Data(contentsOf: url) == Data("x".utf8))
    }

    private static let password = "correct horse battery staple"

    /// A backup of an empty store, written as the backup sheet writes it.
    private func writtenBackup(in dir: URL) async throws -> URL {
        let store = try MeetingStore(directory: dir.appendingPathComponent("store"), keyStore: MemoryKey())
        let data = try await store.createBackup(password: Self.password, appVersion: "0.9.0")
        let url = dir.appendingPathComponent("checked.vautabackup")
        try BackupModel.write(data, to: url)
        return url
    }

    @Test func theSavedFileIsReadBackAndOpened() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try await writtenBackup(in: dir)
        let contents = try await BackupModel.check(url, password: Self.password)
        #expect(contents.meetings == 0)
    }

    @Test func aFileDamagedOnTheDiskFailsTheCheck() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try await writtenBackup(in: dir)
        var bytes = try Data(contentsOf: url)
        bytes[bytes.count - 1] ^= 0x01
        try bytes.write(to: url)
        await #expect(throws: (any Error).self) { try await BackupModel.check(url, password: Self.password) }
        await #expect(throws: (any Error).self) { try await BackupModel.check(dir.appendingPathComponent("missing.vautabackup"), password: Self.password) }
    }

    /// Only a file on this Mac is read: any other address is refused before anything is fetched.
    @Test func onlyAFileIsRead() async throws {
        let remote = try #require(URL(string: "https://example.invalid/backup.vautabackup"))
        await #expect(throws: CocoaError.self) { try await BackupModel.read(remote) }
    }
}
