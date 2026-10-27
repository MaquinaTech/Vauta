// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import VautaCore

@Suite("Storage envelope")
struct StorageEnvelopeTests {
    private func image(_ text: String) throws -> Data {
        let db = try SQLiteDatabase(image: nil, size: 0)
        try db.execute("CREATE TABLE t(x TEXT)")
        try db.query("INSERT INTO t VALUES (?)", [.text(text)])
        return try db.withSerializedBytes { Data($0) }
    }

    private func openText(_ sealed: Data, key: SymmetricKey) throws -> String {
        let (buffer, size) = try SnapshotEnvelope.open(sealed, key: key)
        let db = try SQLiteDatabase(image: buffer, size: size)
        return try db.query("SELECT x FROM t")[0].string(0)
    }

    @Test func versionsAreNamedAndStable() {
        #expect(EnvelopeVersion.v1.rawValue == 1)
        #expect(EnvelopeVersion.v2.rawValue == 2)
        #expect(EnvelopeVersion.current == .v2)
        #expect(SnapshotEnvelope.header(.v2) == Data("ACTA".utf8) + [2])
    }

    @Test func v2RoundTripsCompressedAndStored() throws {
        let key = SymmetricKey(size: .bits256)
        let plain = try image("texto de prueba")
        let packed = try plain.withUnsafeBytes { try SnapshotEnvelope.pack($0) }
        #expect(packed.bytes[8] == 1, "an SQLite image compresses with LZ4")
        #expect(try openText(SnapshotEnvelope.seal(packed, key: key), key: key) == "texto de prueba")

        // Method 0 (stored) is still readable.
        let stored = SecretBuffer(capacity: 9 + plain.count)
        var size = UInt64(plain.count).littleEndian
        withUnsafeBytes(of: &size) { stored.base.copyMemory(from: $0.baseAddress!, byteCount: 8) }
        stored.base.storeBytes(of: 0, toByteOffset: 8, as: UInt8.self)
        plain.withUnsafeBytes { (stored.base + 9).copyMemory(from: $0.baseAddress!, byteCount: plain.count) }
        stored.count = 9 + plain.count
        #expect(try openText(SnapshotEnvelope.seal(stored, key: key), key: key) == "texto de prueba")
    }

    @Test func v1LZFSEIsReadable() throws {
        let key = SymmetricKey(size: .bits256)
        let packed = try (try image("formato antiguo") as NSData).compressed(using: .lzfse) as Data
        let header = SnapshotEnvelope.header(.v1)
        let sealed = try AES.GCM.seal(packed, using: key, authenticating: header)
        #expect(try openText(header + sealed.combined!, key: key) == "formato antiguo")
    }

    @Test func rejectsTamperingWrongKeysAndUnknownFormats() throws {
        let key = SymmetricKey(size: .bits256)
        let packed = try image("x").withUnsafeBytes { try SnapshotEnvelope.pack($0) }
        let sealed = try SnapshotEnvelope.seal(packed, key: key)

        var tampered = sealed
        tampered[tampered.count - 20] ^= 0x01
        #expect(throws: StoreError.self) { try SnapshotEnvelope.open(tampered, key: key) }
        #expect(throws: StoreError.self) { try SnapshotEnvelope.open(sealed, key: SymmetricKey(size: .bits256)) }

        // The version byte is authenticated: relabeling v2 as v1 does not decrypt.
        var relabeled = sealed
        relabeled[4] = 1
        #expect(throws: StoreError.self) { try SnapshotEnvelope.open(relabeled, key: key) }

        var unknown = sealed
        unknown[4] = 3
        do {
            _ = try SnapshotEnvelope.open(unknown, key: key)
            Issue.record("an unknown version must be rejected")
        } catch let error as StoreError {
            #expect(error.code == .unsupportedFormat)
        }
        do {
            _ = try SnapshotEnvelope.open(Data("SQLite format 3".utf8), key: key)
            Issue.record("a plaintext file must be rejected")
        } catch let error as StoreError {
            #expect(error.code == .unsupportedFormat)
        }
    }

    @Test func v1StoreIsReadAndRewrittenAsV2() async throws {
        let fx = StoreFixture()
        var store: MeetingStore? = try fx.open()
        let id = try await store!.startMeeting(at: .now)
        try await store!.append(segment(.me, 0, "texto de la v1"), to: id)
        try await store!.endMeeting(id, at: .now)
        try await store!.writeV1Snapshot()
        store = nil
        #expect(try Data(contentsOf: fx.snapshotURL).starts(with: SnapshotEnvelope.header(.v1)))
        store = try fx.open()
        #expect(try await store!.segments(of: id).count == 1)
        try await store!.setTitle("v2", of: id)
        try await store!.flush()
        #expect(try Data(contentsOf: fx.snapshotURL).starts(with: SnapshotEnvelope.header(.v2)))
    }

    @Test func tamperedStoreFileIsRejected() async throws {
        let fx = StoreFixture()
        var store: MeetingStore? = try fx.open()
        try await store!.flush()
        store = nil
        let good = try Data(contentsOf: fx.snapshotURL)
        var bad = good
        bad[bad.count - 20] ^= 0x01
        try bad.write(to: fx.snapshotURL)
        await expectStoreError(.unreadableStore) { try fx.open() }
        try good.write(to: fx.snapshotURL)
        #expect((try? fx.open()) != nil)
    }
}
