// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Testing
@testable import VautaCore

/// A restore stopped at each of its steps (a crash, a power cut or a refused Keychain): the store always opens on the
/// next launch, with the old data or the restored data, never with neither.
@Suite("Restore survives a crash at every step")
struct StorageRestoreCrashTests {
    static let password = "correct horse battery staple"

    private func record(_ store: MeetingStore, _ text: String) async throws {
        let id = try await store.startMeeting(at: .now)
        try await store.append(segment(.me, 0, text), to: id)
        try await store.endMeeting(id, at: .now)
    }

    private func backup(_ text: String) async throws -> OpenedBackup {
        let source = StoreFixture()
        let store = try source.open()
        try await record(store, text)
        let file = try await store.createBackup(password: Self.password, appVersion: "0.9.3")
        return try await MeetingStore.openBackup(file, password: Self.password)
    }

    /// A store holding one meeting, flushed and closed.
    private func original() async throws -> (StoreFixture, SymmetricKey) {
        let target = StoreFixture()
        let store = try target.open()
        try await record(store, "original")
        try await store.flush()
        return (target, try #require(target.keys.key))
    }

    /// The restore's last step was refused: the snapshot is the restored one, its key is only staged.
    private func restoredWithKeyOnlyStaged() async throws -> (StoreFixture, old: SymmetricKey, new: SymmetricKey) {
        let (target, old) = try await original()
        let store = try target.open()
        target.keys.setReplaceFails(true)
        let summary = try await store.restore(try await backup("del respaldo"))
        target.keys.setReplaceFails(false)
        #expect(summary.restoredMeetings == 1)
        #expect(try await store.imageContains("del respaldo"), "the restore succeeds in the running app")
        let new = try #require(target.keys.stagedValue)
        #expect(try #require(target.keys.key) == old)
        return (target, old, new)
    }

    @Test func crashAfterStagingKeepsTheOldStoreAndDropsTheStagedKey() async throws {
        let (target, old) = try await original()
        target.keys.setItems(current: old, staged: SymmetricKey(size: .bits256))
        let store = try target.open()
        #expect(try await store.imageContains("original"))
        #expect(target.keys.stagedValue == nil)
        #expect(try #require(target.keys.key) == old)
    }

    @Test func crashAfterTheSnapshotOpensTheRestoredStoreAndPromotesItsKey() async throws {
        let (target, _, new) = try await restoredWithKeyOnlyStaged()
        let store = try target.open()
        #expect(try await store.imageContains("del respaldo"))
        #expect(try await store.meetings().count == 1)
        #expect(try #require(target.keys.key) == new)
        #expect(target.keys.stagedValue == nil)
    }

    @Test func crashBetweenDeletingAndAddingTheKeyItem() async throws {
        let (target, _, new) = try await restoredWithKeyOnlyStaged()
        target.keys.setItems(current: nil, staged: new)
        let store = try target.open()
        #expect(try await store.imageContains("del respaldo"))
        #expect(try #require(target.keys.key) == new)
        #expect(target.keys.stagedValue == nil)
    }

    @Test func crashBeforeDiscardingTheStagedKey() async throws {
        let (target, _, new) = try await restoredWithKeyOnlyStaged()
        target.keys.setItems(current: new, staged: new)
        let store = try target.open()
        #expect(try await store.imageContains("del respaldo"))
        #expect(target.keys.stagedValue == nil)
    }

    @Test func promotionStillRefusedOnOpenKeepsTheStagedKeyForTheNextOpen() async throws {
        let (target, old, new) = try await restoredWithKeyOnlyStaged()
        target.keys.setReplaceFails(true)
        var store: MeetingStore! = try target.open()
        target.keys.setReplaceFails(false)
        #expect(try await store.imageContains("del respaldo"))
        #expect(try #require(target.keys.key) == old)
        #expect(target.keys.stagedValue == new)
        // Saving keeps working with the staged key.
        try await record(store, "después")
        try await store.flush()
        store = nil
        let reopened = try target.open()
        #expect(try await reopened.meetings().count == 2)
        #expect(try #require(target.keys.key) == new)
    }

    @Test func readOnlyOpenUsesTheStagedKeyWithoutChangingTheKeychain() async throws {
        let (target, old, new) = try await restoredWithKeyOnlyStaged()
        let store = try target.open(createIfMissing: false)
        #expect(try await store.imageContains("del respaldo"))
        #expect(try #require(target.keys.key) == old)
        #expect(target.keys.stagedValue == new)
    }

    @Test func aSecondRestorePromotesThePendingKeyFirst() async throws {
        let (target, old) = try await original()
        var store: MeetingStore! = try target.open()
        target.keys.setReplaceFails(true)
        _ = try await store.restore(try await backup("primero"))
        // Still refused: the second restore stops before staging anything, and the first one stays readable.
        await expectStoreError(.restoreFailed) { try await store.restore(try await backup("segundo")) }
        #expect(try #require(target.keys.key) == old)
        target.keys.setReplaceFails(false)
        _ = try await store.restore(try await backup("segundo"))
        #expect(target.keys.stagedValue == nil)
        store = nil
        let reopened = try target.open()
        #expect(try await reopened.imageContains("segundo"))
        #expect(!(try await reopened.imageContains("primero")))
    }

    @Test func eraseShredsAKeyLeftStaged() async throws {
        let (target, _, new) = try await restoredWithKeyOnlyStaged()
        // The open cannot promote it either: the key stays staged while the app runs.
        target.keys.setReplaceFails(true)
        let store = try target.open()
        #expect(target.keys.stagedValue == new)
        try await store.eraseEverything()
        #expect(target.keys.stagedValue == nil)
        #expect(try #require(target.keys.key) != new)
        #expect(try await store.meetings().isEmpty)
    }

    @Test func stagedKeyWithoutASnapshotIsDiscarded() throws {
        let target = StoreFixture()
        target.keys.setItems(current: nil, staged: SymmetricKey(size: .bits256))
        _ = try target.open()
        #expect(target.keys.stagedValue == nil)
    }

    @Test func authenticationCheckNeedsTheRightKey() throws {
        let key = SymmetricKey(size: .bits256)
        let db = try SQLiteDatabase(image: nil, size: 0)
        try Schema.migrate(db)
        let sealed = try SnapshotEnvelope.seal(db.withSerializedBytes(SnapshotEnvelope.pack), key: key)
        #expect(SnapshotEnvelope.isSealed(sealed, with: key))
        #expect(!SnapshotEnvelope.isSealed(sealed, with: SymmetricKey(size: .bits256)))
        #expect(!SnapshotEnvelope.isSealed(sealed.dropLast(), with: key))
        #expect(!SnapshotEnvelope.isSealed(Data("ACTA".utf8), with: key))
    }
}
