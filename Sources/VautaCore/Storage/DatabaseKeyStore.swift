// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation

/// Where the store's AES-256 key lives. Production uses the Keychain; tests
/// inject an in-memory implementation so they never touch the user's keychain.
protocol DatabaseKeyStore: Sendable {
    /// The existing key, or nil if there is none. A locked keychain throws.
    func existingKey() throws -> SymmetricKey?
    /// Creates and stores a new random key. Never overwrites an existing one.
    func createKey() throws -> SymmetricKey
    /// Deletes the key and verifies it is gone (crypto-shred of the store).
    func remove() throws
    /// Replaces the key in place (or adds it if there is none). Never
    /// delete-then-add: on failure the previous key is still there. Used when
    /// restoring a backup, which re-keys the store.
    func replace(with key: SymmetricKey) throws
}

extension DatabaseKeyStore {
    /// Returns the key, creating it only if `createIfMissing`. If an encrypted
    /// store already exists and its key is missing, creating another would make
    /// the store unreadable, so callers pass `createIfMissing: false` then.
    /// A locked keychain or a cancelled prompt never leads to creating a key.
    func key(createIfMissing: Bool) throws -> SymmetricKey {
        if let key = try existingKey() { return key }
        guard createIfMissing else { throw StoreError(.missingKey, detail: String(describing: self)) }
        return try createKey()
    }

    /// A new random key for a store that has no file yet, created after deleting whatever item is there. With no
    /// store on disk an existing item encrypts nothing of Vauta's, and another process of this user may have planted
    /// it with an access list that lets it read the key: the new item gets Vauta's own access list instead. If the
    /// old item cannot be deleted, this throws and no store is created.
    func newKey() throws -> SymmetricKey {
        try remove()
        return try createKey()
    }
}

/// The database key in the login keychain (classic keychain, see `Keychain`).
/// Its ACL binds it to Vauta's code signature: another app triggers a macOS
/// prompt. Account `database-key-v1` is part of the persisted format.
struct KeychainDatabaseKeyStore: DatabaseKeyStore, CustomStringConvertible {
    static let defaultAccount = "database-key-v1"

    let service: String
    let account: String

    init(service: String = VautaIdentity.keychainService, account: String = Self.defaultAccount) {
        self.service = service
        self.account = account
    }

    var description: String { "\(service) / \(account)" }

    func existingKey() throws -> SymmetricKey? {
        guard let data = try Keychain.read(service: service, account: account) else { return nil }
        guard data.count == 32 else { throw StoreError(.keychainFailure, detail: "\(self): key has \(data.count) bytes") }
        return SymmetricKey(data: data)
    }

    func createKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        // A fixed English label: it is stored in the Keychain, so it must not depend on the language at creation time.
        let label = "Vauta database key"
        try Keychain.add(key.withUnsafeBytes { Data($0) }, service: service, account: account, label: label)
        return key
    }

    func replace(with key: SymmetricKey) throws {
        let label = "Vauta database key"
        try Keychain.upsert(key.withUnsafeBytes { Data($0) }, service: service, account: account, label: label)
    }

    func remove() throws {
        Keychain.delete(service: service, account: account)
        guard try Keychain.read(service: service, account: account) == nil else {
            throw StoreError(.keychainFailure, detail: "\(self): key still present after delete")
        }
    }
}
