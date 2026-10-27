// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CommonCrypto
import CryptoKit
import Foundation

/// What a backup says about itself. It is inside the encrypted payload, so the
/// file reveals nothing without the password.
public struct BackupManifest: Codable, Sendable, Equatable {
    public var format: Int
    public var appVersion: String
    public var schemaVersion: Int64
    public var createdAt: Date
    public var meetingCount: Int
    /// Format 2: the size of the settings (`BackupPreferences`) that follow the manifest. Nil in format 1.
    public var preferencesLength: Int? = nil
}

/// The encrypted backup file.
///
///     "ACTABK" | version (1) | KDF id (1) | iterations (UInt32 BE) | salt (16) | AES-256-GCM sealed box
///
/// The first 28 bytes are the header and are authenticated as AAD, so changing
/// the KDF parameters or the version makes decryption fail. The sealed box
/// (nonce | ciphertext | tag) holds:
///
///     manifest length (UInt32 BE) | manifest (JSON) | settings (manifest.preferencesLength bytes, format 2 only)
///         | database image (SnapshotEnvelope.pack format)
///
/// Format 1 (before the settings were added) has no settings part; it is still read. A reader that only knows
/// format 1 refuses a format 2 file by its manifest instead of misreading it.
///
/// The key comes from the password with PBKDF2-HMAC-SHA256 (CommonCrypto), 1,000,000
/// iterations by default, stored in the header so it can be raised later. Apple
/// frameworks offer no memory-hard KDF (scrypt, Argon2), so the password length is
/// what protects the file; the UI requires a long one.
enum BackupArchive {
    /// LEGACY FORMAT IDENTIFIER (from the earlier working name). It is part of the
    /// file format and of the authenticated header (AAD): it must never change,
    /// or every existing backup stops opening.
    static let magic = Data("ACTABK".utf8)
    static let version: UInt8 = 1
    static let kdfPBKDF2SHA256: UInt8 = 1
    static let saltLength = 16
    static let headerLength = 6 + 1 + 1 + 4 + saltLength
    static let defaultIterations: UInt32 = 1_000_000
    static let minimumIterations: UInt32 = 600_000
    /// A tampered header must not make opening spin for minutes before it fails.
    static let maximumIterations: UInt32 = 2_000_000

    static func header(iterations: UInt32, salt: Data) -> Data {
        var out = magic
        out.append(version)
        out.append(kdfPBKDF2SHA256)
        withUnsafeBytes(of: iterations.bigEndian) { out.append(contentsOf: $0) }
        out.append(salt)
        return out
    }

    static func deriveKey(password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        // NFC, so the same password typed on another system derives the same key.
        var secret = Data(password.precomposedStringWithCanonicalMapping.utf8)
        defer { wipe(&secret) }
        var derived = Data(count: 32)
        defer { wipe(&derived) }
        let status = secret.withUnsafeBytes { pw in
            salt.withUnsafeBytes { s in
                derived.withUnsafeMutableBytes { out in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         pw.baseAddress?.assumingMemoryBound(to: Int8.self), pw.count,
                                         s.baseAddress?.assumingMemoryBound(to: UInt8.self), s.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                         out.baseAddress?.assumingMemoryBound(to: UInt8.self), out.count)
                }
            }
        }
        guard status == kCCSuccess else { throw StoreError(.encryption, detail: "PBKDF2: \(status)") }
        return SymmetricKey(data: derived)
    }

    /// Encrypts a packed database image and its manifest, with the settings when there are any (the manifest then
    /// says format 2 and their length).
    static func seal(packed: SecretBuffer, manifest: BackupManifest, preferences: Data? = nil, password: String,
                     iterations: UInt32 = defaultIterations) throws -> Data {
        var salt = Data(count: saltLength)
        let ok = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, saltLength, $0.baseAddress!) }
        guard ok == errSecSuccess else { throw StoreError(.encryption, detail: "random salt") }
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        let header = header(iterations: iterations, salt: salt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var manifest = manifest
        if let preferences {
            manifest.format = 2
            manifest.preferencesLength = preferences.count
        }
        let meta = try encoder.encode(manifest)
        var plain = Data(capacity: 4 + meta.count + (preferences?.count ?? 0) + packed.count)
        defer { wipe(&plain) }
        withUnsafeBytes(of: UInt32(meta.count).bigEndian) { plain.append(contentsOf: $0) }
        plain.append(meta)
        if let preferences { plain.append(preferences) }
        plain.append(packed.bytes.bindMemory(to: UInt8.self))
        let box = try AES.GCM.seal(plain, using: key, authenticating: header)
        guard let combined = box.combined else { throw StoreError(.encryption, detail: "backup") }
        return header + combined
    }

    /// Decrypts a backup. Returns the manifest, the encoded settings (nil in format 1) and the packed image (a copy the
    /// caller wipes).
    static func open(_ file: Data, password: String) throws -> (manifest: BackupManifest, preferences: Data?, packed: Data) {
        let base = file.startIndex
        guard file.count > headerLength, file.starts(with: magic) else { throw StoreError(.backupInvalid, detail: "header") }
        guard file[base + 6] == version else { throw StoreError(.backupUnsupported, detail: "version \(file[base + 6])") }
        guard file[base + 7] == kdfPBKDF2SHA256 else { throw StoreError(.backupUnsupported, detail: "kdf \(file[base + 7])") }
        let iterations = file[(base + 8)..<(base + 12)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard (minimumIterations...maximumIterations).contains(iterations) else {
            throw StoreError(.backupInvalid, detail: "iterations \(iterations)")
        }
        let header = Data(file[base..<(base + headerLength)])
        let salt = header.suffix(saltLength)
        let key = try deriveKey(password: password, salt: Data(salt), iterations: iterations)
        var plain: Data
        do {
            let box = try AES.GCM.SealedBox(combined: file[(base + headerLength)...])
            plain = try AES.GCM.open(box, using: key, authenticating: header)
        } catch {
            // A wrong password, a changed header or payload and a cut-off file all end here.
            throw StoreError(.backupAuthentication, detail: "\(error)")
        }
        defer { wipe(&plain) }
        guard plain.count > 4 else { throw StoreError(.backupInvalid, detail: "payload") }
        let length = plain.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, plain.count > 4 + length else { throw StoreError(.backupInvalid, detail: "manifest length") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(BackupManifest.self, from: plain.subdata(in: 4..<(4 + length))) else {
            throw StoreError(.backupInvalid, detail: "manifest")
        }
        var start = 4 + length
        var preferences: Data?
        // Only format 2 has a settings part: a later format is refused by its number (`openBackup`), not misread here.
        if manifest.format == 2 {
            guard let size = manifest.preferencesLength, size >= 0, size <= BackupPreferences.maximumEncodedBytes,
                  plain.count > start + size else { throw StoreError(.backupInvalid, detail: "settings length") }
            preferences = plain.subdata(in: start..<(start + size))
            start += size
        }
        return (manifest, preferences, plain.subdata(in: start..<plain.count))
    }
}
