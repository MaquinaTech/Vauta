// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Security
import Testing
@testable import VautaCore

/// Uses the real login keychain with a unique service name per run, and
/// deletes every item it creates. Skipped when no keychain is usable (for
/// example a CI runner without a login keychain).
@Suite("Storage Keychain", .enabled(if: KeychainProbe.isUsable))
struct StorageKeychainTests {
    let service = "local.vauta.tests.\(UUID().uuidString)"

    @Test func writeReplacesTheItemAndKeepsASingleItem() throws {
        let account = "secret-\(UUID().uuidString)"
        defer { KeychainSecret.delete(account, service: service) }
        #expect(try KeychainSecret.read(account, service: service) == nil)

        try KeychainSecret.write("first", account: account, label: "Vauta test", service: service)
        try KeychainSecret.write("second", account: account, label: "Vauta test (renamed)", service: service)
        #expect(try KeychainSecret.read(account, service: service) == "second")

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let items = try #require(result as? [[String: Any]])
        #expect(items.count == 1, "a write never duplicates the item")
        #expect(items.first?[kSecAttrLabel as String] as? String == "Vauta test (renamed)")

        KeychainSecret.delete(account, service: service)
        #expect(try KeychainSecret.read(account, service: service) == nil)
    }

    @Test func itemsUnderTheServiceBeforeTheRenameMoveOnFirstRead() throws {
        let legacy = "local.acta.tests.\(UUID().uuidString)"
        let account = "secret-\(UUID().uuidString)"
        defer {
            Keychain.delete(service: service, account: account)
            Keychain.delete(service: legacy, account: account)
        }
        try Keychain.add(Data("old".utf8), service: legacy, account: account, label: "Acta test")
        #expect(try Keychain.read(service: service, account: account) == nil, "no fallback unless asked")
        #expect(try Keychain.read(service: service, account: account, legacyService: legacy) == Data("old".utf8))
        #expect(try Keychain.read(service: service, account: account) == Data("old".utf8), "copied to the new service")
        #expect(try Keychain.read(service: legacy, account: account) == nil, "removed from the old one after read-back")

        try Keychain.add(Data("again".utf8), service: legacy, account: account, label: "Acta test")
        Keychain.delete(service: service, account: account, legacyService: legacy)
        #expect(try Keychain.read(service: service, account: account, legacyService: legacy) == nil, "delete shreds both")
    }

    @Test func onlyTheUnbundledServiceHasALegacyName() {
        #expect(VautaIdentity.legacyService(for: "local.vauta.cli") == "local.acta.cli")
        #expect(VautaIdentity.legacyService(for: "local.acta.app") == nil)
        #expect(VautaIdentity.legacyService(for: "io.github.maquinatech.vauta") == nil)
    }

    @Test func databaseKeyIsCreatedOnlyWhenAllowedAndNeverOverwritten() throws {
        let store = KeychainDatabaseKeyStore(service: service, account: "database-key-\(UUID().uuidString)")
        defer { try? store.remove() }
        do {
            _ = try store.key(createIfMissing: false)
            Issue.record("a missing key must not be created")
        } catch let error as StoreError {
            #expect(error.code == .missingKey)
        }
        let key = try store.key(createIfMissing: true).withUnsafeBytes { Data($0) }
        #expect(key.count == 32)
        #expect(try store.key(createIfMissing: true).withUnsafeBytes { Data($0) } == key, "an existing key is returned, not replaced")
        #expect(throws: StoreError.self) { try store.createKey() }
        try store.remove()
        #expect(try store.existingKey() == nil)
    }
}

enum KeychainProbe {
    /// Whether this process can add and delete a generic password item.
    static let isUsable: Bool = {
        let service = "local.vauta.tests.probe.\(UUID().uuidString)"
        defer { KeychainSecret.delete("probe", service: service) }
        return (try? KeychainSecret.write("probe", account: "probe", label: "Vauta test probe", service: service)) != nil
    }()
}
