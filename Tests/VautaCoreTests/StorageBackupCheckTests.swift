// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Verifying a backup (after saving it, and Verify Backup…) opens it as a restore would and keeps nothing.
@Suite("Backup: checking a backup without restoring it")
struct StorageBackupCheckTests {
    private static let password = StorageBackupTests.password
    /// Its folder lives as long as the test (a new suite value runs each test).
    private let fixture = StoreFixture()

    private func store(meetings: Int) async throws -> MeetingStore {
        let store = try fixture.open()
        for i in 0..<meetings {
            let id = try await store.startMeeting(at: .now)
            try await store.append(segment(.me, 0, "reunión \(i)"), to: id)
            try await store.endMeeting(id, at: .now)
        }
        return store
    }

    @Test func aCheckedBackupHoldsWhatTheStoreHas() async throws {
        let store = try await store(meetings: 3)
        let settings = BackupPreferences(values: ["copyProtection": .bool(true)])
        let file = try await store.createBackup(password: Self.password, appVersion: "0.9.0", preferences: settings)
        let contents = try await MeetingStore.checkBackup(file, password: Self.password)
        #expect(contents.meetings == 3)
        #expect(contents.meetings == (try await store.stats().meetings))
        #expect(contents.savedVoices == 0)
        #expect(contents.documentSources == 0)
        #expect(contents.hasSettings)
        // The same file still restores: checking it used nothing up.
        let backup = try await MeetingStore.openBackup(file, password: Self.password)
        #expect(backup.meetings == 3)
    }

    @Test func aBackupWithoutSettingsSaysSo() async throws {
        let file = try await store(meetings: 1).createBackup(password: Self.password, appVersion: "0.9.0")
        #expect(try await MeetingStore.checkBackup(file, password: Self.password).hasSettings == false)
    }

    @Test func aTruncatedOrChangedBackupFailsTheCheck() async throws {
        let file = try await store(meetings: 2).createBackup(password: Self.password, appVersion: "0.9.0")
        await #expect(throws: StoreError.self) { try await MeetingStore.checkBackup(file.prefix(file.count - 64), password: Self.password) }
        var changed = file
        changed[changed.count / 2] ^= 0x01
        await #expect(throws: StoreError.self) { try await MeetingStore.checkBackup(changed, password: Self.password) }
        await expectStoreError(.backupAuthentication) { try await MeetingStore.checkBackup(file, password: "not the password at all") }
    }
}
