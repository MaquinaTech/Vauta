// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import Vauta

/// The backup file is written whole or not at all: a backup it replaces is never truncated.
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
}
