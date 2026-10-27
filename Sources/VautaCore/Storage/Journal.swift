// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation

/// Encrypted journal `vauta.journal.enc`. Between two snapshots (`vauta.db.enc`)
/// only the new writes are appended, in records of a few KB, instead of
/// re-encrypting and rewriting the whole database every 10 s.
///
///     header:  "ACTJ" | 1 | generation (16 bytes)
///     record:  length (UInt32 LE) | AES-256-GCM( operations )
///              AAD = header | seq (UInt64 LE)
///
/// The generation is random and the snapshot stores it too (table
/// `store_meta`): a journal from another snapshot is never replayed. The `seq`
/// in the AAD prevents reordering, repeating or removing records in the middle;
/// a truncated final record (power cut mid-write) does not authenticate and
/// replay stops there. The key is derived by HKDF from the Keychain key with
/// its own label: the two files never share a key.
///
/// Each record is a list of SQL statements that already ran successfully, with
/// their parameters. Replaying them in order on the snapshot rebuilds the same
/// database (every table uses INTEGER PRIMARY KEY, so IDs match). The SQL text
/// is whatever the app version that wrote it generated: replay runs BEFORE
/// migrations, and `MeetingStore.legacySQL` rewrites constructs that no longer
/// exist (0.1.0's `carray()`).
///
/// Not detected (local threat model): dropping whole trailing records, or
/// replacing both files with an older pair sealed with the same key. Both
/// authenticate and amount to a rollback to an earlier state.
struct JournalOp: Equatable {
    let sql: String
    let params: [SQLiteValue?]
}

enum Journal {
    /// LEGACY FORMAT IDENTIFIER (from the earlier working name). Part of the file
    /// format and of every record's AAD: it must never change.
    static let magic = Data("ACTJ".utf8)
    static let version: UInt8 = 1
    static let headerSize = 4 + 1 + 16
    /// Upper bound for one record when reading (defends against absurd lengths).
    private static let maxRecord = 64 << 20

    /// LEGACY CRYPTOGRAPHIC LABEL (from the earlier working name). It is the HKDF
    /// `info` that derives the journal key: it must never change, or existing
    /// journals can no longer be decrypted.
    private static let hkdfInfo = Data("acta-journal-v1".utf8)

    static func key(from databaseKey: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: databaseKey, info: hkdfInfo, outputByteCount: 32)
    }

    static func header(_ generation: Data) -> Data {
        var h = magic
        h.append(version)
        h.append(generation)
        return h
    }

    static func newGeneration() -> Data {
        SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
    }

    // MARK: Writing

    /// Encrypts a record (off the actor). `plain` is zeroed when released.
    static func seal(_ plain: SecretBuffer, seq: UInt64, generation: Data, key: SymmetricKey) throws -> Data {
        var aad = header(generation)
        withUnsafeBytes(of: seq.littleEndian) { aad.append(contentsOf: $0) }
        let sealed = try AES.GCM.seal(plain.bytes, using: key, authenticating: aad)
        guard let combined = sealed.combined else { throw StoreError(.encryption, detail: "journal record") }
        var out = Data(capacity: 4 + combined.count)
        withUnsafeBytes(of: UInt32(combined.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(combined)
        return out
    }

    /// Appends a record. If the file does not exist it is created (0600) with
    /// the header in the same write. If it exists with another generation this
    /// fails, and the store falls back to a full snapshot.
    ///
    /// Durability: `F_BARRIERFSYNC`, not `F_FULLFSYNC`. Records are appended
    /// every few seconds while recording; a full cache flush each time costs
    /// battery and SSD wear for little gain. The barrier keeps records in order
    /// with respect to everything written later (including the next snapshot),
    /// so after a power cut the journal holds a prefix of its records and replay
    /// stops at the first one that does not authenticate: at most the last few
    /// seconds of transcript are lost, never earlier ones. Snapshots, which
    /// replace the journal, use `F_FULLFSYNC`.
    static func append(_ record: Data, generation: Data, to url: URL) throws {
        let fd = open(url.path, O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError(.fileSystem, detail: "open journal: errno \(errno)") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw StoreError(.fileSystem, detail: "stat journal: errno \(errno)") }
        var out = Data()
        if st.st_size == 0 {
            out.append(header(generation))
        } else {
            var existing = [UInt8](repeating: 0, count: headerSize)
            guard pread(fd, &existing, headerSize, 0) == headerSize, Data(existing) == header(generation) else {
                throw StoreError(.fileSystem, detail: "journal belongs to another snapshot")
            }
        }
        out.append(record)
        try AtomicFile.writeAll(fd, out)
        try AtomicFile.sync(fd, .barrier)
        // A new file also needs its directory entry ordered before later writes.
        if st.st_size == 0 { try AtomicFile.syncDirectory(url.deletingLastPathComponent(), .barrier) }
    }

    // MARK: Reading

    struct Replay {
        var ops: [[JournalOp]] = []
        /// Some bytes did not authenticate (truncated or tampered record):
        /// nothing more can be appended to this journal.
        var damagedTail = false
        /// The file belongs to another snapshot (or has no valid header).
        var foreign = false
    }

    /// Reads the valid, consecutive records of the given generation.
    static func read(_ url: URL, generation: Data, key: SymmetricKey) -> Replay {
        var replay = Replay()
        guard var data = try? Data(contentsOf: url), !data.isEmpty else { return replay }
        defer { data.resetBytes(in: 0..<data.count) }
        let head = header(generation)
        guard data.count >= headerSize, data.prefix(headerSize) == head else {
            replay.foreign = true
            return replay
        }
        var offset = headerSize
        var seq: UInt64 = 0
        while offset < data.count {
            guard offset + 4 <= data.count else { replay.damagedTail = true; break }
            let length = Int(data.subdata(in: offset..<offset + 4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
            let start = offset + 4
            guard length > 28, length <= maxRecord, start + length <= data.count else { replay.damagedTail = true; break }
            var aad = head
            withUnsafeBytes(of: seq.littleEndian) { aad.append(contentsOf: $0) }
            guard let box = try? AES.GCM.SealedBox(combined: data.subdata(in: start..<start + length)),
                  var plain = try? AES.GCM.open(box, using: key, authenticating: aad)
            else { replay.damagedTail = true; break }
            let ops = try? decode(plain)
            plain.resetBytes(in: 0..<plain.count)
            guard let ops else { replay.damagedTail = true; break }
            replay.ops.append(ops)
            offset = start + length
            seq += 1
        }
        return replay
    }

    // MARK: Binary encoding of operations

    static func encode(_ ops: [JournalOp]) -> SecretBuffer {
        var size = 4
        for op in ops {
            size += 4 + op.sql.utf8.count + 2
            for p in op.params {
                size += 1
                switch p {
                case nil: break
                case .integer, .real: size += 8
                case .text(let s): size += 4 + s.utf8.count
                case .blob(let d): size += 4 + d.count
                case .ids(let v): size += 4 + 8 * v.count
                }
            }
        }
        let out = SecretBuffer(capacity: size)
        func put<T: FixedWidthInteger>(_ v: T) {
            withUnsafeBytes(of: v.littleEndian) { (out.base + out.count).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            out.count += MemoryLayout<T>.size
        }
        func put(_ bytes: UnsafeRawBufferPointer) {
            put(UInt32(bytes.count))
            if let b = bytes.baseAddress, bytes.count > 0 { (out.base + out.count).copyMemory(from: b, byteCount: bytes.count) }
            out.count += bytes.count
        }
        put(UInt32(ops.count))
        for op in ops {
            var sql = op.sql
            sql.withUTF8 { put(UnsafeRawBufferPointer($0)) }
            put(UInt16(op.params.count))
            for p in op.params {
                switch p {
                case nil: put(UInt8(0))
                case .integer(let v): put(UInt8(1)); put(v)
                case .real(let v): put(UInt8(2)); put(v.bitPattern)
                case .text(var s): put(UInt8(3)); s.withUTF8 { put(UnsafeRawBufferPointer($0)) }
                case .blob(let d): put(UInt8(4)); d.withUnsafeBytes { put($0) }
                case .ids(let v):
                    put(UInt8(5)); put(UInt32(v.count))
                    for x in v { put(x) }
                }
            }
        }
        return out
    }

    static func decode(_ data: Data) throws -> [JournalOp] {
        try data.withUnsafeBytes { raw in
            var offset = 0
            func take<T: FixedWidthInteger>(_: T.Type) throws -> T {
                guard offset + MemoryLayout<T>.size <= raw.count else { throw StoreError(.unreadableStore, detail: "journal: short record") }
                defer { offset += MemoryLayout<T>.size }
                return T(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: T.self))
            }
            func bytes() throws -> UnsafeRawBufferPointer {
                let n = Int(try take(UInt32.self))
                guard n <= raw.count - offset else { throw StoreError(.unreadableStore, detail: "journal: invalid length") }
                defer { offset += n }
                return UnsafeRawBufferPointer(rebasing: raw[offset..<offset + n])
            }
            let count = Int(try take(UInt32.self))
            guard count <= raw.count else { throw StoreError(.unreadableStore, detail: "journal: invalid count") }
            var ops: [JournalOp] = []
            ops.reserveCapacity(count)
            for _ in 0..<count {
                guard let sql = String(validating: try bytes(), as: UTF8.self) else { throw StoreError(.unreadableStore, detail: "journal: invalid SQL text") }
                let n = Int(try take(UInt16.self))
                var params: [SQLiteValue?] = []
                for _ in 0..<n {
                    switch try take(UInt8.self) {
                    case 0: params.append(nil)
                    case 1: params.append(.integer(try take(Int64.self)))
                    case 2: params.append(.real(Double(bitPattern: try take(UInt64.self))))
                    case 3:
                        guard let s = String(validating: try bytes(), as: UTF8.self) else { throw StoreError(.unreadableStore, detail: "journal: invalid text") }
                        params.append(.text(s))
                    case 4: params.append(.blob(Data(try bytes())))
                    case 5:
                        let k = Int(try take(UInt32.self))
                        guard k <= (raw.count - offset) / 8 else { throw StoreError(.unreadableStore, detail: "journal: invalid ID list") }
                        var v: [Int64] = []
                        v.reserveCapacity(k)
                        for _ in 0..<k { v.append(try take(Int64.self)) }
                        params.append(.ids(v))
                    default: throw StoreError(.unreadableStore, detail: "journal: unknown parameter type")
                    }
                }
                ops.append(JournalOp(sql: sql, params: params))
            }
            guard offset == raw.count else { throw StoreError(.unreadableStore, detail: "journal: trailing bytes") }
            return ops
        }
    }
}
