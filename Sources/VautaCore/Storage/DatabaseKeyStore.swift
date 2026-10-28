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
    /// Deletes the key, and the staged one, and verifies they are gone (crypto-shred of the store).
    func remove() throws
    /// Makes `key` the store key, written as a new item with Vauta's own access list. A restore calls it only once
    /// the staged item holds the same key and the snapshot sealed with it is on disk, so a failure (or a crash)
    /// between deleting the old item and adding the new one loses nothing: the next open finds the staged key.
    func replace(with key: SymmetricKey) throws
    /// The key a restore staged before writing the snapshot sealed with it (see `MeetingStore.restore`), or nil.
    func stagedKey() throws -> SymmetricKey?
    /// Stores `key` as the staged key, as a new item: whatever was staged before is deleted first.
    func stage(_ key: SymmetricKey) throws
    /// Deletes the staged key, if there is one.
    func discardStaged()
}

/// Stores without a crash to survive (the in-memory ones of evaluations and tests) need no staged key.
extension DatabaseKeyStore {
    func stagedKey() throws -> SymmetricKey? { nil }
    func stage(_ key: SymmetricKey) throws {}
    func discardStaged() {}
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

    /// Deletes the key item and creates a new random one with Vauta's own access list, for Erase Everything. An item
    /// that appears between the two steps is never adopted: the add fails on the duplicate and this throws.
    func newKey() throws -> SymmetricKey {
        try remove()
        return try createKey()
    }
}

/// The database key in the login keychain (classic keychain, see `Keychain`).
/// Its ACL binds it to Vauta's code signature: another app triggers a macOS
/// prompt. Account `database-key-v1` is part of the persisted format, and so is
/// the staged key's account, the same name followed by `.staged` (it exists only
/// while a restore is being completed).
struct KeychainDatabaseKeyStore: DatabaseKeyStore, CustomStringConvertible {
    static let defaultAccount = "database-key-v1"
    static let stagedSuffix = ".staged"
    // A fixed English label: it is stored in the Keychain, so it must not depend on the language at creation time.
    private static let label = "Vauta database key"

    let service: String
    let account: String

    init(service: String = VautaIdentity.keychainService, account: String = Self.defaultAccount) {
        self.service = service
        self.account = account
    }

    var description: String { "\(service) / \(account)" }
    private var stagedAccount: String { account + Self.stagedSuffix }

    func existingKey() throws -> SymmetricKey? { try key(account: account) }

    func stagedKey() throws -> SymmetricKey? { try key(account: stagedAccount) }

    private func key(account: String) throws -> SymmetricKey? {
        guard let data = try Keychain.read(service: service, account: account) else { return nil }
        guard data.count == 32 else { throw StoreError(.keychainFailure, detail: "\(service) / \(account): key has \(data.count) bytes") }
        return SymmetricKey(data: data)
    }

    func createKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        try Keychain.add(key.withUnsafeBytes { Data($0) }, service: service, account: account, label: Self.label)
        return key
    }

    /// Delete, then add (`Keychain.recreate`): an item someone else planted under the account is never written into,
    /// so the key never lands under that item's access list.
    func replace(with key: SymmetricKey) throws {
        try Keychain.recreate(key.withUnsafeBytes { Data($0) }, service: service, account: account, label: Self.label)
    }

    /// Delete, then add; an item that appears in between makes the add fail, so it is never adopted.
    func stage(_ key: SymmetricKey) throws {
        discardStaged()
        try Keychain.add(key.withUnsafeBytes { Data($0) }, service: service, account: stagedAccount, label: Self.label)
    }

    func discardStaged() { Keychain.delete(service: service, account: stagedAccount) }

    func remove() throws {
        Keychain.delete(service: service, account: account)
        discardStaged()
        guard try Keychain.read(service: service, account: account) == nil,
              try Keychain.read(service: service, account: stagedAccount) == nil else {
            throw StoreError(.keychainFailure, detail: "\(self): key still present after delete")
        }
    }
}
