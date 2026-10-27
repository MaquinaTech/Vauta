// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Storage erase everything (crypto-shred)")
struct StorageEraseTests {
    private func recordOne(_ store: MeetingStore, _ text: String) async throws {
        let id = try await store.startMeeting(at: .now)
        try await store.append(segment(.me, 0, text), to: id)
        try await store.endMeeting(id, at: .now)
    }

    @Test func eraseIsRefusedWhileRecording() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let busy = try await store.startMeeting(at: .now)
        await expectStoreError(.meetingInProgress) { try await store.eraseEverything() }
        try await store.endMeeting(busy, at: .now)
    }

    @Test func eraseRotatesTheKeyAndOldCopiesNoLongerOpen() async throws {
        let fx = StoreFixture()
        var store: MeetingStore? = try fx.open()
        try await recordOne(store!, "antes de borrar")
        let oldKey = try #require(fx.keys.key).withUnsafeBytes { Data($0) }
        let beforeErase = try Data(contentsOf: fx.snapshotURL)
        try await store!.eraseEverything()
        #expect(try await store!.meetings().isEmpty)
        #expect(try Data(contentsOf: fx.snapshotURL).starts(with: SnapshotEnvelope.header(.current)))
        #expect(try #require(fx.keys.key).withUnsafeBytes { Data($0) } != oldKey)
        #expect(!fx.exists(fx.journalURL))
        #expect(!fx.exists(fx.dir.appendingPathComponent(MeetingStore.eraseMarkerName)))
        store = nil

        let afterErase = try Data(contentsOf: fx.snapshotURL)
        try beforeErase.write(to: fx.snapshotURL)
        await expectStoreError(.unreadableStore) { try fx.open() }
        try afterErase.write(to: fx.snapshotURL)
        store = try fx.open()
        #expect(try await store!.meetings().isEmpty)
    }

    @Test func failedKeyCreationBlocksEveryWriteUntilRetried() async throws {
        let fx = StoreFixture()
        var store: MeetingStore? = try fx.open()
        try await recordOne(store!, "antes del fallo")
        let beforeFailed = try Data(contentsOf: fx.snapshotURL)
        fx.keys.setCreationFails(true)
        await expectStoreError(.newKeyPending) { try await store!.eraseEverything() }
        await expectStoreError(.newKeyPending) { try await store!.startMeeting(at: .now) }
        await expectStoreError(.newKeyPending) { try await store!.flush() }
        #expect(!fx.exists(fx.snapshotURL), "nothing is written with the old key")
        #expect(fx.keys.key == nil)

        fx.keys.setCreationFails(false)
        try await store!.flush()
        store = nil
        store = try fx.open()
        #expect(try await store!.meetings().isEmpty)
        store = nil
        try beforeFailed.write(to: fx.snapshotURL)
        await expectStoreError(.unreadableStore) { try fx.open() }
    }

    @Test func interruptedEraseIsCompletedOnOpen() async throws {
        let fx = StoreFixture()
        var store: MeetingStore? = try fx.open()
        try await recordOne(store!, "antes del corte")
        store = nil
        let previous = try Data(contentsOf: fx.snapshotURL)
        // The process died after deleting the file, before rotating the key.
        try FileManager.default.removeItem(at: fx.snapshotURL)
        try Data().write(to: fx.dir.appendingPathComponent(MeetingStore.eraseMarkerName))
        store = try fx.open()
        #expect(!fx.exists(fx.dir.appendingPathComponent(MeetingStore.eraseMarkerName)))
        #expect(try await store!.meetings().isEmpty)
        try await store!.flush()
        store = nil
        try previous.write(to: fx.snapshotURL)
        await expectStoreError(.unreadableStore) { try fx.open() }
    }

    @Test func missingKeyRefusesToOpenAndNeverCreatesAnother() async throws {
        let fx = StoreFixture()
        var store: MeetingStore? = try fx.open()
        try await store!.flush()
        store = nil
        try fx.keys.remove()
        await expectStoreError(.missingKey) { try fx.open() }
        #expect(fx.keys.key == nil)
    }
}
