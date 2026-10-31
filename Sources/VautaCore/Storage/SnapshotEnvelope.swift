// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Compression
import CryptoKit
import Foundation
import SQLite3

/// Version byte of the `vauta.db.enc` file envelope. It describes how the file
/// is encrypted and compressed, and is unrelated to the database schema
/// version (`SchemaVersion`, kept in `PRAGMA user_version` inside the image).
enum EnvelopeVersion: UInt8, CaseIterable {
    /// `"ACTA" | 1 | AES-256-GCM( LZFSE( image ) )`. Read-only: rewritten as v2 on the next snapshot.
    case v1 = 1
    /// `"ACTA" | 2 | AES-256-GCM( size (UInt64 LE) | method (1 byte: 0 = stored, 1 = LZ4) | payload )`.
    case v2 = 2

    /// The version every snapshot is written with.
    static let current = EnvelopeVersion.v2
}

/// The encrypted snapshot file `vauta.db.enc`: an `sqlite3_serialize` image,
/// compressed and sealed with AES-256-GCM. The header (`"ACTA"` + version) is
/// authenticated as AAD, so a tampered file or a file of another version does
/// not decrypt. Plaintext intermediates that Vauta controls are zeroed.
///
/// Not detected (local threat model): replacing the file with an older
/// snapshot sealed with the same key. It authenticates and is a rollback.
/// "Erase everything" rotates the key, so copies older than an erase never open.
enum SnapshotEnvelope {
    /// LEGACY FORMAT IDENTIFIER (from the earlier working name). It is part of the
    /// file format and of the authenticated header (AAD): it must never change,
    /// or every existing store stops opening.
    static let magic = Data("ACTA".utf8)

    static func header(_ version: EnvelopeVersion) -> Data { magic + [version.rawValue] }

    /// v2 plaintext: size (8) | method (1) | data, LZ4-compressed directly from
    /// SQLite's memory (no intermediate plaintext copy). Falls back to stored
    /// bytes if compression does not help.
    static func pack(_ image: UnsafeRawBufferPointer) throws -> SecretBuffer {
        let n = image.count
        guard let src = image.baseAddress, n > 0 else { throw StoreError(.database, detail: "empty database image") }
        let out = SecretBuffer(capacity: 9 + n + n / 16 + 4096)
        var size = UInt64(n).littleEndian
        withUnsafeBytes(of: &size) { out.base.copyMemory(from: $0.baseAddress!, byteCount: 8) }
        let scratch = SecretBuffer(capacity: compression_encode_scratch_buffer_size(COMPRESSION_LZ4))
        let written = compression_encode_buffer((out.base + 9).assumingMemoryBound(to: UInt8.self), out.capacity - 9,
                                                src.assumingMemoryBound(to: UInt8.self), n, scratch.base, COMPRESSION_LZ4)
        if written > 0 {
            out.base.storeBytes(of: 1, toByteOffset: 8, as: UInt8.self)
            out.count = 9 + written
        } else {
            out.base.storeBytes(of: 0, toByteOffset: 8, as: UInt8.self)
            (out.base + 9).copyMemory(from: src, byteCount: n)
            out.count = 9 + n
        }
        return out
    }

    /// Encrypts a packed image as the current envelope version.
    static func seal(_ packed: SecretBuffer, key: SymmetricKey) throws -> Data {
        let header = header(.current)
        let sealed = try AES.GCM.seal(packed.bytes, using: key, authenticating: header)
        guard let combined = sealed.combined else { throw StoreError(.encryption, detail: "snapshot") }
        var out = Data(capacity: header.count + combined.count)
        out.append(header)
        out.append(combined)
        return out
    }

    /// Whether `data` is an envelope sealed with `key`. Only authenticates: the plaintext is wiped at once.
    static func isSealed(_ data: Data, with key: SymmetricKey) -> Bool {
        guard data.starts(with: magic), data.count > magic.count + 1,
              let version = EnvelopeVersion(rawValue: data[data.startIndex + magic.count]),
              let box = try? AES.GCM.SealedBox(combined: data.dropFirst(magic.count + 1)),
              var opened = try? AES.GCM.open(box, using: key, authenticating: header(version)) else { return false }
        wipe(&opened)
        return true
    }

    /// Returns the database image in `sqlite3_malloc64` memory (the caller,
    /// `SQLiteDatabase`, takes ownership). Plaintext intermediates are zeroed.
    static func open(_ data: Data, key: SymmetricKey) throws -> (UnsafeMutableRawPointer, Int) {
        guard data.starts(with: magic), data.count > magic.count + 1 else {
            throw StoreError(.unsupportedFormat, detail: "missing ACTA header")
        }
        let byte = data[data.startIndex + magic.count]
        guard let version = EnvelopeVersion(rawValue: byte) else {
            throw StoreError(.unsupportedFormat, detail: "envelope version \(byte)")
        }
        var opened: Data
        do {
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(magic.count + 1))
            opened = try AES.GCM.open(box, using: key, authenticating: header(version))
        } catch {
            throw StoreError(.unreadableStore, detail: "authentication failed")
        }
        defer { wipe(&opened) }
        switch version {
        case .v2:
            return try unpack(opened)
        case .v1:
            // LZFSE without a declared size.
            var plain: Data
            do {
                plain = try (opened as NSData).decompressed(using: .lzfse) as Data
            } catch {
                throw StoreError(.unreadableStore, detail: "LZFSE decompression failed")
            }
            defer { wipe(&plain) }
            guard !plain.isEmpty, let buffer = sqlite3_malloc64(UInt64(plain.count)) else {
                throw StoreError(.unreadableStore, detail: "empty v1 image")
            }
            plain.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: plain.count)
            return (buffer, plain.count)
        }
    }

    /// Largest image the user's own store may declare. It is authenticated with the store key (only Vauta wrote it), and
    /// `pack` accepts any size, so this stays generous: a store that was saved must always open again.
    static let maximumStoreImageSize = 1 << 36
    /// Largest image a backup may declare. A backup comes from outside and is untrusted: this stops a crafted file from
    /// forcing a multi-gigabyte allocation. `createBackup` refuses to write one above it, so no backup is unrestorable.
    static let maximumBackupImageSize = 1 << 30
    /// LZ4 cannot expand more than about 255 to 1; a declared size beyond that of its payload is false.
    static let maximumLZ4Ratio = 256

    static func unpack(_ plain: Data, maxSize: Int = maximumStoreImageSize) throws -> (UnsafeMutableRawPointer, Int) {
        try plain.withUnsafeBytes { raw in
            guard raw.count >= 9 else { throw StoreError(.unreadableStore, detail: "truncated v2 payload") }
            // A declared size beyond `Int` (a crafted backup) is refused, not trapped on.
            guard let size = Int(exactly: UInt64(littleEndian: raw.loadUnaligned(as: UInt64.self))) else {
                throw StoreError(.unreadableStore, detail: "invalid declared size")
            }
            let method = raw[8]
            let payload = UnsafeRawBufferPointer(rebasing: raw[9...])
            // Checked before anything is allocated: a stored image is exactly its payload, an LZ4 one cannot expand without bound.
            let plausible = size > 0 && size <= maxSize && (method == 0 || method == 1)
                && (method != 0 || payload.count == size)
                && (method != 1 || size / maximumLZ4Ratio <= payload.count)
            guard plausible, let src = payload.baseAddress, let buffer = sqlite3_malloc64(UInt64(size)) else {
                throw StoreError(.unreadableStore, detail: "invalid declared size \(size)")
            }
            let ok: Bool
            switch method {
            case 0:
                ok = payload.count == size
                if ok { buffer.copyMemory(from: src, byteCount: size) }
            case 1:
                let scratch = SecretBuffer(capacity: compression_decode_scratch_buffer_size(COMPRESSION_LZ4))
                ok = compression_decode_buffer(buffer.assumingMemoryBound(to: UInt8.self), size,
                                               src.assumingMemoryBound(to: UInt8.self), payload.count,
                                               scratch.base, COMPRESSION_LZ4) == size
            default:
                ok = false
            }
            guard ok else {
                memset_s(buffer, size, 0, size)
                sqlite3_free(buffer)
                throw StoreError(.unreadableStore, detail: "decompression failed (method \(method))")
            }
            return (buffer, size)
        }
    }
}
