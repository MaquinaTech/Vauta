// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Backup: settings")
struct StorageBackupPreferencesTests {
    static let password = "correct horse battery staple"

    /// A throwaway UserDefaults suite, removed when the test is done.
    private func withDefaults<T>(_ body: (UserDefaults) async throws -> T) async rethrows -> T {
        let name = "vauta.tests.backup.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        return try await body(defaults)
    }

    private func fillSettings(_ defaults: UserDefaults) {
        defaults.set("es", forKey: "transcriptionLanguage")
        defaults.set("same", forKey: "outputLanguage")
        defaults.set(false, forKey: "copyProtection")
        defaults.set(true, forKey: "liveTranslationEnabled")
        defaults.set(15, forKey: "autoStopMinutes")
        defaults.set(Data(#"{"keyCode":15,"modifiers":6144}"#.utf8), forKey: "recordHotKey")
        defaults.set("server", forKey: "modelProviderChat")
        defaults.set("none", forKey: "modelProviderEmbeddings")
    }

    private func store(with texts: [String]) async throws -> (MeetingStore, StoreFixture) {
        let fixture = StoreFixture()
        let store = try fixture.open()
        for text in texts {
            let id = try await store.startMeeting(at: .now)
            try await store.append(segment(.me, 0, text), to: id)
            try await store.endMeeting(id, at: .now)
        }
        return (store, fixture)
    }

    @Test func settingsRoundTripThroughTheEncryptedBackup() async throws {
        try await withDefaults { source in
            fillSettings(source)
            let captured = BackupPreferences(from: source)
            #expect(captured.values.count == 8)
            let (store, fixture) = try await store(with: ["reunión"])
            defer { withExtendedLifetime(fixture) {} }
            let file = try await store.createBackup(password: Self.password, appVersion: "0.9.0", preferences: captured)

            // The settings are inside the ciphertext: nothing readable in the file.
            #expect(file.range(of: Data("transcriptionLanguage".utf8)) == nil)
            #expect(file.range(of: Data("modelProviderChat".utf8)) == nil)

            let backup = try await MeetingStore.openBackup(file, password: Self.password)
            #expect(backup.manifest.format == 2)
            #expect(backup.meetings == 1)
            #expect(backup.preferences == captured)

            try await withDefaults { target in
                #expect(backup.preferences?.apply(to: target) == 8)
                #expect(target.string(forKey: "transcriptionLanguage") == "es")
                #expect(target.object(forKey: "copyProtection") as? Bool == false)
                #expect(target.object(forKey: "liveTranslationEnabled") as? Bool == true)
                #expect(target.object(forKey: "autoStopMinutes") as? Int == 15)
                #expect(target.data(forKey: "recordHotKey") == source.data(forKey: "recordHotKey"))
                #expect(target.string(forKey: "modelProviderChat") == "server")
                #expect(BackupPreferences(from: target) == captured)
            }
        }
    }

    @Test func oldFormatBackupRestoresAndLeavesTheSettingsAlone() async throws {
        // A backup made before the settings were included: format 1, no settings part.
        let (source, sourceFixture) = try await store(with: ["antes de los ajustes"])
        defer { withExtendedLifetime(sourceFixture) {} }
        let file = try await source.createBackup(password: Self.password, appVersion: "0.9.0")
        let backup = try await MeetingStore.openBackup(file, password: Self.password)
        #expect(backup.manifest.format == 1)
        #expect(backup.manifest.preferencesLength == nil)
        #expect(backup.preferences == nil)

        // The same through the archive as the first release wrote it.
        let packed = try StoreFixture().legacyImage(schema: 7).withSerializedBytes(SnapshotEnvelope.pack)
        let manifest = BackupManifest(format: 1, appVersion: "0.1.0", schemaVersion: 7, createdAt: .now, meetingCount: 1)
        let legacy = try BackupArchive.seal(packed: packed, manifest: manifest, password: Self.password, iterations: BackupArchive.minimumIterations)
        let opened = try await MeetingStore.openBackup(legacy, password: Self.password)
        #expect(opened.preferences == nil)

        try await withDefaults { defaults in
            fillSettings(defaults)
            let before = BackupPreferences(from: defaults)
            let (target, fixture) = try await store(with: [])
            defer { withExtendedLifetime(fixture) {} }
            let summary = try await target.restore(backup)
            #expect(summary.restoredMeetings == 1)
            _ = try await target.restore(opened)
            // Nothing in a format 1 backup touches the settings (the app only applies `backup.preferences`).
            #expect(backup.preferences?.apply(to: defaults) ?? 0 == 0)
            #expect(BackupPreferences(from: defaults) == before)
        }
    }

    @Test func secretsAndMachineStateNeverEnterTheBackup() async throws {
        try await withDefaults { defaults in
            fillSettings(defaults)
            // Things that live in UserDefaults or could be put there by mistake, and must stay out.
            let excluded: [String: Any] = [
                "serverBearer": "sk-secret-token-123", "apiKey": "sk-secret-token-123", "llmServerConfig": Data("https://10.0.0.5/v1".utf8),
                "preferencesVersion": 2, "onboardingCompletedVersion": 1, "settingsPane": "models", "recordingMeetingID": 7,
                "captionFrames": ["main": [1.0, 2.0, 3.0, 4.0]], "captionLastScreen": "main", "calendarEnabled": true,
                "calendarIDs": ["abc"], "basicQualityHintDismissed": true, "exportFormat": "pdf",
                "NSWindow Frame SettingsWindow": "0 0 100 100",
                // A model of the server, which is not in the backup.
                "translationModel": "qwen3.5-9b",
            ]
            for (key, value) in excluded { defaults.set(value, forKey: key) }

            let captured = BackupPreferences(from: defaults)
            #expect(Set(captured.values.keys).isDisjoint(with: excluded.keys))
            let encoded = try #require(captured.encoded())
            for secret in ["sk-secret-token-123", "10.0.0.5", "serverBearer", "captionFrames", "settingsPane"] {
                #expect(encoded.range(of: Data(secret.utf8)) == nil, "\(secret) is in the payload")
            }

            // The allow-list itself names no credential.
            for key in BackupPreferences.allowed.keys.map({ $0.lowercased() }) {
                for word in ["bearer", "token", "secret", "password", "apikey", "certificate", "pin", "bookmark", "frame"] {
                    #expect(!key.contains(word), "\(key) looks like \(word)")
                }
            }

            // Not even in a payload that carries them: they are dropped when it is read.
            let forged = try PropertyListSerialization.data(
                fromPropertyList: ["version": 1, "values": ["serverBearer": "sk-secret-token-123", "settingsPane": "models", "copyProtection": true]],
                format: .binary, options: 0)
            #expect(BackupPreferences(decoding: forged).values == ["copyProtection": .bool(true)])
        }
    }

    @Test func badOrUnknownKeysAreSkippedAndTheRestIsKept() async throws {
        let payload: [String: Any] = [
            "copyProtection": true,                       // good
            "autoStopMinutes": 12,                        // good
            "transcriptionLanguage": "en",                // good
            "notifyProblems": 1,                          // a number, not a Bool
            "dictationMe": "yes",                         // a string, not a Bool
            "knowledgeRetentionDays": "90",               // a string, not an Int
            "liveTranslationEnabled": 0,                  // a number, not a Bool
            "captionTextSize": 3.5,                       // a number, not a string
            "recordHotKey": "not data",                   // a string, not Data
            "translationTarget": String(repeating: "x", count: 5000),  // too long
            "markHotKey": Data(count: 10_000),            // too large
            "someFutureSetting": true,                    // unknown
        ]
        let blob = try PropertyListSerialization.data(fromPropertyList: ["version": 1, "values": payload], format: .binary, options: 0)
        let read = BackupPreferences(decoding: blob)
        #expect(read.values == ["copyProtection": .bool(true), "autoStopMinutes": .int(12), "transcriptionLanguage": .string("en")])

        // Garbage, or a different shape, gives no settings and no error.
        #expect(BackupPreferences(decoding: Data("not a property list".utf8)).isEmpty)
        let wrongShape = try PropertyListSerialization.data(fromPropertyList: ["values": ["copyProtection"]], format: .binary, options: 0)
        #expect(BackupPreferences(decoding: wrongShape).isEmpty)

        // A fractional number is not an Int.
        let fractional = try PropertyListSerialization.data(fromPropertyList: ["values": ["autoStopMinutes": 2.5]], format: .binary, options: 0)
        #expect(BackupPreferences(decoding: fractional).isEmpty)
    }

    @Test func forgedOrTruncatedSettingsLengthsAreRefused() async throws {
        let packed = try StoreFixture().legacyImage(schema: 7).withSerializedBytes(SnapshotEnvelope.pack)
        func file(format: Int, length: Int?) throws -> Data {
            var manifest = BackupManifest(format: format, appVersion: "0.9.0", schemaVersion: 7, createdAt: .now, meetingCount: 1)
            manifest.preferencesLength = length
            // No settings passed: the manifest is sealed exactly as forged here.
            return try BackupArchive.seal(packed: packed, manifest: manifest, password: Self.password,
                                          iterations: BackupArchive.minimumIterations)
        }
        for length in [nil, -1, Int.max, BackupPreferences.maximumEncodedBytes + 1, packed.count, packed.count + 10] {
            let forged = try file(format: 2, length: length)
            #expect(throws: StoreError.self, "length \(String(describing: length))") {
                _ = try BackupArchive.open(forged, password: Self.password)
            }
            await #expect(throws: StoreError.self) { _ = try await MeetingStore.openBackup(forged, password: Self.password) }
        }

        // A length in a format 1 manifest is ignored: the whole rest is the database, as format 1 always read it.
        let format1 = try BackupArchive.open(try file(format: 1, length: 3), password: Self.password)
        #expect(format1.preferences == nil)
        #expect(format1.packed.count == packed.count)

        // A later format is refused as newer, not as damaged.
        do {
            _ = try await MeetingStore.openBackup(try file(format: 3, length: nil), password: Self.password)
            Issue.record("a format 3 backup was opened")
        } catch let error as StoreError {
            #expect(error.code == .backupUnsupported)
        }
    }

    @Test func unreadableSettingsDoNotStopTheRestore() async throws {
        // Settings bytes that are not a property list: the meetings still open and restore.
        let packed = try StoreFixture().legacyImage(schema: 7).withSerializedBytes(SnapshotEnvelope.pack)
        let manifest = BackupManifest(format: 1, appVersion: "0.1.0", schemaVersion: 7, createdAt: .now, meetingCount: 1)
        let file = try BackupArchive.seal(packed: packed, manifest: manifest, preferences: Data("garbage".utf8), password: Self.password,
                                          iterations: BackupArchive.minimumIterations)
        let backup = try await MeetingStore.openBackup(file, password: Self.password)
        #expect(backup.manifest.format == 2)
        #expect(backup.meetings == 1)
        #expect(backup.preferences == nil)
    }
}
