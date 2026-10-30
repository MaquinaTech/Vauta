// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Testing
@testable import VautaCore

/// In-memory database key store: tests never touch the user's Keychain.
/// One instance shared by several opens plays the role of the Keychain item.
final class MemoryKeyStore: DatabaseKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SymmetricKey?
    private var failCreation = false
    private var failReplace = false
    private var replacesBeforeFailing: Int?

    var key: SymmetricKey? { lock.withLock { stored } }

    /// Simulates a Keychain that refuses to create new items.
    func setCreationFails(_ fails: Bool) { lock.withLock { failCreation = fails } }

    /// Simulates a Keychain that refuses to update the key.
    func setReplaceFails(_ fails: Bool) { lock.withLock { failReplace = fails } }

    /// Simulates a Keychain that accepts `count` updates and then refuses them.
    func setReplaceFails(after count: Int) { lock.withLock { replacesBeforeFailing = count } }

    func replace(with key: SymmetricKey) throws {
        try lock.withLock {
            if failReplace { throw StoreError(.keychainFailure, detail: "simulated failure") }
            if let left = replacesBeforeFailing {
                guard left > 0 else { throw StoreError(.keychainFailure, detail: "simulated failure") }
                replacesBeforeFailing = left - 1
            }
            stored = key
        }
    }

    func existingKey() throws -> SymmetricKey? { lock.withLock { stored } }

    // MARK: Staged key (a second Keychain item, as in `KeychainDatabaseKeyStore`)

    private var staged: SymmetricKey?
    private var failStage = false

    var stagedValue: SymmetricKey? { lock.withLock { staged } }

    /// Simulates a Keychain that refuses to stage a key.
    func setStageFails(_ fails: Bool) { lock.withLock { failStage = fails } }

    /// Sets both items as a crash would have left them (nil deletes one).
    func setItems(current: SymmetricKey?, staged: SymmetricKey?) { lock.withLock { stored = current; self.staged = staged } }

    func stagedKey() throws -> SymmetricKey? { lock.withLock { staged } }

    func stage(_ key: SymmetricKey) throws {
        try lock.withLock {
            if failStage { throw StoreError(.keychainFailure, detail: "simulated failure") }
            staged = key
        }
    }

    func discardStaged() { lock.withLock { staged = nil } }

    func createKey() throws -> SymmetricKey {
        try lock.withLock {
            if failCreation { throw StoreError(.keychainFailure, detail: "simulated failure") }
            guard stored == nil else { throw StoreError(.keychainFailure, detail: "duplicate item") }
            let key = SymmetricKey(size: .bits256)
            stored = key
            return key
        }
    }

    func remove() throws { lock.withLock { stored = nil; staged = nil } }
}

/// A temporary store directory with its own key store, removed on deinit.
final class StoreFixture {
    let dir: URL
    let keys = MemoryKeyStore()

    init() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-tests-\(UUID().uuidString)", isDirectory: true)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    var snapshotURL: URL { dir.appendingPathComponent(MeetingStore.snapshotName) }
    var journalURL: URL { dir.appendingPathComponent(MeetingStore.journalName) }

    /// Opens the store. A store that was just dropped (`store = nil`) may keep the instance lock for a moment:
    /// a background write holds it until its task is torn down, which on a busy machine is not immediate. So
    /// `.alreadyOpen` is retried for up to 600 s, unless `waitForLock` is false (tests of the lock itself).
    func open(recover: Bool = false, knowledgeDays: Int = MeetingStore.retentionDays,
              createIfMissing: Bool = true, waitForLock: Bool = true) throws -> MeetingStore {
        let deadline = ContinuousClock.now + .seconds(600)
        while true {
            do {
                return try MeetingStore(directory: dir, keyStore: keys, recoverOpenMeetings: recover,
                                        knowledgeRetentionDays: knowledgeDays, createIfMissing: createIfMissing)
            } catch let error as StoreError where error.code == .alreadyOpen && waitForLock && ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    func permissions(_ url: URL) -> Int? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Writes a store as an older Vauta would have: migrations up to `schema`
    /// with the frozen SQL of the registry, then `populate`, sealed with this
    /// fixture's key. `userVersion` overrides `PRAGMA user_version` (to fake a
    /// newer store); `generation` stores a snapshot generation for journal tests.
    func writeLegacyStore(schema: SchemaVersion, userVersion: SchemaVersion? = nil, generation: Data? = nil,
                          populate: (SQLiteDatabase) throws -> Void = StoreFixture.legacyMeeting) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = try keys.key(createIfMissing: true)
        let db = try SQLiteDatabase(image: nil, size: 0)
        try Schema.migrate(db, upTo: schema)
        try populate(db)
        if let generation { try MeetingStore.setGeneration(generation, in: db) }
        if let userVersion { try db.execute("PRAGMA user_version = \(userVersion)") }
        try MeetingStore.writeSnapshot(db.withSerializedBytes(SnapshotEnvelope.pack), key: key, to: snapshotURL)
    }

    /// One finished meeting with the 0.1.0 speaker labels.
    static func legacyMeeting(_ db: SQLiteDatabase) throws {
        let now = Date.now.timeIntervalSince1970
        try db.query("INSERT INTO meetings(id, started_at, ended_at, title) VALUES (1, ?, ?, 'Reunión heredada')",
                     [.real(now - 3600), .real(now)])
        try db.query("INSERT INTO segments(meeting_id, speaker, start, end, text) VALUES (1, 'Yo', 0, 2, 'texto heredado'), (1, 'Otros', 3, 5, 'respuesta')")
    }
}

extension MeetingStore {
    /// A copy of the plaintext database image.
    func plainImage() throws -> Data { try db.withSerializedBytes { Data($0) } }

    func imageContains(_ word: String) throws -> Bool { try plainImage().range(of: Data(word.utf8)) != nil }

    func compactionPendingForTests() -> Bool { pendingCompaction }

    func forceCompactionPendingForTests() { pendingCompaction = true }

    func pragma(_ name: String) throws -> Int64 { try db.query("PRAGMA \(name)")[0].int(0) }

    /// Raw `segments.speaker` values of a meeting, in time order.
    func speakerCodes(_ meetingID: Int64) throws -> [String] {
        try db.query("SELECT speaker FROM segments WHERE meeting_id = ? ORDER BY start, id", [.integer(meetingID)]).map { $0.string(0) }
    }

    /// Runs raw SQL (test setup).
    func execForTests(_ sql: String, _ params: [SQLiteValue?] = []) throws { try db.query(sql, params) }

    /// The first column of a raw query, as integers.
    func intsForTests(_ sql: String) throws -> [Int64] { try db.query(sql).map { $0.int(0) } }

    func rowCount(_ table: String) throws -> Int64 {
        try db.query("SELECT count(*) FROM \(table)")[0].int(0)
    }

    func columnNames(_ table: String) throws -> [String] {
        try db.query("SELECT name FROM pragma_table_info(?)", [.text(table)]).map { $0.string(0) }
    }

    /// Rewrites the snapshot in the legacy v1 envelope (LZFSE).
    func writeV1Snapshot() throws {
        var plain = try db.withSerializedBytes { Data($0) }
        defer { wipe(&plain) }
        let packed = try (plain as NSData).compressed(using: .lzfse) as Data
        let header = SnapshotEnvelope.header(.v1)
        let sealed = try AES.GCM.seal(packed, using: key, authenticating: header)
        try (header + sealed.combined!).write(to: file, options: .atomic)
    }
}

func segment(_ channel: Channel, _ start: Double, _ text: String) -> Segment {
    Segment(channel: channel, start: start, end: start + 1, text: text, isFinal: true)
}

/// Expects `body` to throw a `StoreError` with `code`.
func expectStoreError<T>(_ code: StoreError.Code, sourceLocation: SourceLocation = #_sourceLocation,
                         _ body: () async throws -> T) async {
    do {
        _ = try await body()
        Issue.record("expected StoreError.\(code.rawValue), nothing was thrown", sourceLocation: sourceLocation)
    } catch let error as StoreError {
        #expect(error.code == code, "\(error)", sourceLocation: sourceLocation)
    } catch {
        Issue.record("expected StoreError.\(code.rawValue), got \(error)", sourceLocation: sourceLocation)
    }
}
