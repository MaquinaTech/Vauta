// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Storage files and errors")
struct StorageFileTests {
    @Test func atomicWriteReplacesTheFileAndLeavesNoTemporaries() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("data.bin")
        try Data("old".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        try AtomicFile.write(Data("new contents".utf8), to: file, tempPrefix: "data.bin.tmp-")
        #expect(try Data(contentsOf: file) == Data("new contents".utf8))
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["data.bin"])
    }

    @Test func failedAtomicWriteKeepsTheOriginal() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-missing-\(UUID().uuidString)/data.bin")
        do {
            try AtomicFile.write(Data("x".utf8), to: missing, tempPrefix: "data.bin.tmp-")
            Issue.record("writing into a missing directory must fail")
        } catch let error as StoreError {
            #expect(error.code == .fileSystem)
            #expect(error.detail?.contains("errno") == true)
        }
    }

    @Test func errorCodesAreStableAndDescribed() {
        #expect(StoreError.Code.meetingInProgress.rawValue == "meetingInProgress")
        #expect(StoreError.Code.alreadyOpen.rawValue == "alreadyOpen")
        #expect(StoreError.Code.newKeyPending.rawValue == "newKeyPending")
        for code in StoreError.Code.allCases {
            let error = StoreError(code, detail: "errno 5")
            #expect(error.errorDescription?.isEmpty == false, "\(code)")
            #expect(error.kind == code)
            #expect(error.description.contains("errno 5"))
            #expect(error.localizedDescription == error.errorDescription)
        }
        let custom = StoreError("The name cannot be empty.")
        #expect(custom.code == .general && custom.errorDescription == "The name cannot be empty.")
        #expect(StoreError(.keychainUnavailable).recoverySuggestion != nil)
    }
}
