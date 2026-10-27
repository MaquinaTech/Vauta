// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Encrypted copies kept by the Acta → Vauta migration must be visible, deletable and expire.
@Suite("Storage: old copies kept by the rename")
struct StorageLeftoversTests {
    private let day: TimeInterval = 86_400

    /// `<root>/Vauta` (the live store) with `<root>/Acta` beside it, as in Application Support.
    private final class Layout {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-leftovers-\(UUID().uuidString)", isDirectory: true)
        let keys = MemoryKeyStore()
        var live: URL { root.appendingPathComponent("Vauta", isDirectory: true) }
        var old: URL { root.appendingPathComponent("Acta", isDirectory: true) }

        init() { try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: root) }

        /// The live store, with one saved meeting (so its snapshot is on disk, as in a real install).
        func open() async throws -> MeetingStore {
            let store = try MeetingStore(directory: live, keyStore: keys)
            if !exists(live.appendingPathComponent(StoreFiles.snapshot)) {
                let id = try await store.startMeeting(at: .now)
                try await store.append(segment(.me, 0, "keep me"), to: id)
                try await store.endMeeting(id, at: .now)
            }
            return store
        }

        func aside(daysAgo: Double, name: String = StoreFiles.snapshot, bytes: Int = 1000, now: Date = .now) throws -> URL {
            let url = live.appendingPathComponent("\(name)\(StoreFiles.asideInfix)\(Int(now.timeIntervalSince1970 - daysAgo * 86_400))")
            try Data(count: bytes).write(to: url)
            return url
        }

        func oldFolder(extra: [String] = []) throws {
            try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
            try Data(count: 2000).write(to: old.appendingPathComponent(StoreFiles.Legacy.snapshot))
            try Data(count: 500).write(to: old.appendingPathComponent(StoreFiles.Legacy.journal))
            for name in extra { try Data("mine".utf8).write(to: old.appendingPathComponent(name)) }
        }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    }

    @Test func aCleanStoreHasNoLeftovers() async throws {
        let layout = Layout()
        let store = try await layout.open()
        #expect(await store.leftovers().isEmpty)
        #expect(await store.deleteLeftovers() == 0)
    }

    @Test func setAsideFilesAreListedWithSizeAndDateFromTheirName() async throws {
        let layout = Layout()
        let store = try await layout.open()
        let now = Date.now
        let file = try layout.aside(daysAgo: 12, bytes: 4096, now: now)
        _ = try layout.aside(daysAgo: 3, name: StoreFiles.journal, bytes: 100, now: now)
        let found = await store.leftovers()
        #expect(found.items.count == 2 && found.setAsideCount == 2 && !found.hasOldFolder)
        #expect(found.totalBytes == 4196)
        let item = try #require(found.items.first { $0.url.lastPathComponent == file.lastPathComponent })
        #expect(item.kind == .setAside && item.bytes == 4096)
        #expect(abs(try #require(item.date).timeIntervalSince(now) + 12 * day) < 2)
        #expect(found.urls.count == 2)
    }

    @Test func aMigrationThatSetsFilesAsideLeavesThemVisible() async throws {
        let fx = StoreFixture()
        try fx.writeLegacyStore(schema: 7)
        try FileManager.default.copyItem(at: fx.snapshotURL, to: fx.dir.appendingPathComponent(StoreFiles.Legacy.snapshot))
        try fx.writeLegacyStore(schema: 7) { db in
            try db.query("INSERT INTO meetings(id, started_at, ended_at, title) VALUES (1, 0, 1, 'a'), (2, 0, 1, 'b')")
        }
        let store = try fx.open()
        #expect(store.migrationReport.setAside.count == 1)
        let found = await store.leftovers()
        #expect(found.setAsideCount == 1)
        #expect(await store.deleteLeftovers() == 1)
        #expect(await store.leftovers().isEmpty)
        #expect(try await store.meetings().count >= 1)
    }

    @Test func anOldFolderWithAStoreIsListedBesideTheLiveOne() async throws {
        let layout = Layout()
        let store = try await layout.open()
        try layout.oldFolder()
        let found = await store.leftovers()
        #expect(found.hasOldFolder && found.setAsideCount == 0)
        #expect(found.totalBytes == 2500)
        #expect(found.items.first?.url.lastPathComponent == "Acta")
    }

    @Test func anOldFolderIsOnlyLookedForBesideAFolderNamedVauta() async throws {
        let fx = StoreFixture()   // a temporary folder with another name
        let store = try fx.open()
        let sibling = fx.dir.deletingLastPathComponent().appendingPathComponent("Acta", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sibling) }
        try Data(count: 10).write(to: sibling.appendingPathComponent(StoreFiles.Legacy.snapshot))
        #expect(await store.leftovers().isEmpty)
    }

    @Test func deletingRemovesTheCopiesButNeverTheLiveStoreOrItsKey() async throws {
        let layout = Layout()
        var store: MeetingStore? = try await layout.open()
        let id = try #require(try await store!.meetings().first?.id)
        let aside = try layout.aside(daysAgo: 1)
        try layout.oldFolder()
        let keyBefore = layout.keys.key

        #expect(await store!.deleteLeftovers() == 2)
        #expect(!layout.exists(aside) && !layout.exists(layout.old), "the emptied old folder goes too")
        #expect(layout.exists(layout.live.appendingPathComponent(StoreFiles.snapshot)))
        #expect(layout.keys.key == keyBefore, "the key is untouched")
        #expect(await store!.leftovers().isEmpty)
        store = nil
        store = try await layout.open()
        #expect(try await store!.segments(of: id).first?.text == "keep me")
    }

    @Test func deletingLeavesWhatIsNotOursInTheOldFolder() async throws {
        let layout = Layout()
        let store = try await layout.open()
        try layout.oldFolder(extra: ["notes.txt"])
        #expect(await store.deleteLeftovers() == 1)
        #expect(layout.exists(layout.old.appendingPathComponent("notes.txt")))
        #expect(!layout.exists(layout.old.appendingPathComponent(StoreFiles.Legacy.snapshot)))
        #expect(await store.leftovers().isEmpty, "no store left there, nothing to show")
    }

    @Test func anOldFolderInUseByAnOldBuildIsNotDeleted() async throws {
        let layout = Layout()
        let store = try await layout.open()
        try layout.oldFolder()
        // An old-named build running on that folder holds its lock.
        let held = try InstanceLock(layout.old.appendingPathComponent(StoreFiles.Legacy.lock))
        #expect(await store.deleteLeftovers() == 0)
        #expect(layout.exists(layout.old.appendingPathComponent(StoreFiles.Legacy.snapshot)))
        withExtendedLifetime(held) {}
    }

    @Test func retentionDeletesSetAsideCopiesOlderThanTheRetentionPeriod() async throws {
        let layout = Layout()
        let store = try await layout.open()
        let expired = try layout.aside(daysAgo: Double(MeetingStore.retentionDays) + 2)
        let recent = try layout.aside(daysAgo: 10, name: StoreFiles.journal)
        try layout.oldFolder()
        _ = try await store.purgeExpired()
        #expect(!layout.exists(expired))
        #expect(layout.exists(recent), "a copy set aside recently is still the safety net")
        #expect(layout.exists(layout.old.appendingPathComponent(StoreFiles.Legacy.snapshot)), "an old folder is only deleted by the user")
        // Later, the recent one expires too.
        _ = try await store.purgeExpired(now: .now + 100 * day)
        #expect(!layout.exists(recent))
    }

    /// Settings → Status says set-aside copies are deleted automatically after `MeetingStore.retentionDays`
    /// (90) days; this is the behaviour that sentence promises.
    @Test func setAsideCopiesAreDeletedNinetyDaysAfterTheyWereSetAside() async throws {
        #expect(MeetingStore.retentionDays == 90)
        let layout = Layout()
        let store = try await layout.open()
        let now = Date.now
        let before = try layout.aside(daysAgo: 89, now: now)
        let after = try layout.aside(daysAgo: 91, name: StoreFiles.journal, now: now)
        _ = try await store.purgeExpired(now: now)
        #expect(layout.exists(before), "89 days: still kept")
        #expect(!layout.exists(after), "91 days: deleted")
    }

    @Test func retentionIgnoresFilesThatAreNotSetAsideCopies() async throws {
        let layout = Layout()
        let store = try await layout.open()
        let other = layout.live.appendingPathComponent("notes.legacy-1")
        try Data(count: 3).write(to: other)
        _ = try await store.purgeExpired(now: .now + 400 * day)
        #expect(layout.exists(other))
    }

    @Test func eraseEverythingRemovesSetAsideCopiesAndTheOldFolder() async throws {
        let layout = Layout()
        let store = try await layout.open()
        let aside = try layout.aside(daysAgo: 2)
        try layout.oldFolder()
        try await store.eraseEverything()
        #expect(!layout.exists(aside))
        #expect(!layout.exists(layout.old.appendingPathComponent(StoreFiles.Legacy.snapshot)))
        #expect(await store.leftovers().isEmpty)
    }
}
