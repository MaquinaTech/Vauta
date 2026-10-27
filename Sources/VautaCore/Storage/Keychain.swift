// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Security

/// Generic-password items in the classic login keychain (login.keychain-db).
///
/// Items are never synchronizable. `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
/// is set but has no effect on the classic keychain (it needs the Data
/// Protection keychain, which requires a provisioning profile with a Team ID);
/// in practice items are readable while the login keychain is unlocked, which
/// by default is the whole session, including while the screen is locked.
/// Time Machine backups of ~/Library/Keychains include them, encrypted with the
/// login password.
enum Keychain {
    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Returns the item's data, or nil when it does not exist.
    /// A locked keychain or a cancelled prompt throws `.keychainUnavailable`.
    ///
    /// An item found only under `legacyService` (the service before the
    /// rename) is copied to `service` and deleted there once the copy reads
    /// back identical; until then it keeps being read from the old service.
    static func read(service: String, account: String,
                     legacyService: String? = nil) throws -> Data? {
        if let data = try readItem(service: service, account: account) { return data }
        guard let legacyService = legacyService ?? VautaIdentity.legacyService(for: service),
              let data = try readItem(service: legacyService, account: account) else { return nil }
        let oldLabel = (try? attribute(kSecAttrLabel, service: legacyService, account: account)) as? String ?? account
        let label = oldLabel.replacingOccurrences(of: "Acta", with: "Vauta")
        if (try? add(data, service: service, account: account, label: label)) != nil,
           (try? readItem(service: service, account: account)) == data {
            SecItemDelete(baseQuery(service: legacyService, account: account) as CFDictionary)
        }
        return data
    }

    private static func attribute(_ name: CFString, service: String, account: String) throws -> Any? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return (result as? [String: Any])?[name as String]
    }

    private static func readItem(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecItemNotFound:
            return nil
        case errSecSuccess:
            guard let data = result as? Data else { throw StoreError(.keychainFailure, detail: "unexpected item type") }
            return data
        default:
            throw error(status, operation: "read", account: account)
        }
    }

    /// Adds a new item. Fails with `errSecDuplicateItem` if it already exists:
    /// callers that must never overwrite (the database key) rely on that.
    static func add(_ data: Data, service: String, account: String, label: String) throws {
        var item = baseQuery(service: service, account: account)
        item[kSecAttrLabel as String] = label
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        item[kSecValueData as String] = data
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw error(status, operation: "add", account: account) }
    }

    /// Replaces the item's data in place, or adds it if it does not exist.
    ///
    /// Never delete-then-add: if the add failed (locked keychain, denied
    /// prompt) the previous value would already be gone.
    static func upsert(_ data: Data, service: String, account: String, label: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: label,
        ]
        let status = SecItemUpdate(baseQuery(service: service, account: account) as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            try add(data, service: service, account: account, label: label)
        default:
            throw error(status, operation: "update", account: account)
        }
    }

    /// Deletes the item, also under the service before the rename (an erase
    /// must shred both); a missing item is not an error.
    @discardableResult
    static func delete(service: String, account: String,
                       legacyService: String? = nil) -> OSStatus {
        if let legacyService = legacyService ?? VautaIdentity.legacyService(for: service) {
            SecItemDelete(baseQuery(service: legacyService, account: account) as CFDictionary)
        }
        return SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    }

    private static func error(_ status: OSStatus, operation: String, account: String) -> StoreError {
        let detail = "\(operation) \(account): OSStatus \(status)"
        switch status {
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return StoreError(.keychainUnavailable, detail: detail)
        default:
            return StoreError(.keychainFailure, detail: detail)
        }
    }
}

/// Text secrets in the Keychain (the model server configuration and its bearer
/// token). They are never logged or displayed; only written, read and deleted.
public enum KeychainSecret {
    public static func read(_ account: String) throws -> String? {
        try read(account, service: VautaIdentity.keychainService)
    }

    /// Updates the existing item in place (or adds it): a failed write never
    /// loses the previous value.
    public static func write(_ value: String, account: String, label: String) throws {
        try write(value, account: account, label: label, service: VautaIdentity.keychainService)
    }

    public static func delete(_ account: String) {
        delete(account, service: VautaIdentity.keychainService)
    }

    static func read(_ account: String, service: String) throws -> String? {
        try Keychain.read(service: service, account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func write(_ value: String, account: String, label: String, service: String) throws {
        try Keychain.upsert(Data(value.utf8), service: service, account: account, label: label)
    }

    static func delete(_ account: String, service: String) {
        Keychain.delete(service: service, account: account)
    }
}
