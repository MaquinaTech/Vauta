// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The optional bearer key of the model server, in the Keychain. Never logged
/// or shown; only written, read and deleted.
///
/// the earlier version stored it under `mlx-bearer-v1`. Reading migrates it to
/// `llm-bearer-v1` (read new; else read old, write new, delete old). The old
/// account is still read for as long as it exists.
public enum ServerCredentials {
    public static let bearerAccount = "llm-bearer-v1"
    public static let legacyBearerAccount = "mlx-bearer-v1"
    static let label = "Vauta model server key"

    /// The stored key, migrating a 0.1.x item on first read. nil = no key.
    /// Throws `LLMError.keychainUnavailable` when the Keychain is locked.
    public static func readBearer(service: String = VautaIdentity.keychainService) throws -> String? {
        if let token = try read(bearerAccount, service: service) { return token }
        guard let legacy = try read(legacyBearerAccount, service: service) else { return nil }
        // Delete the old item only once the new one is safely stored.
        if (try? write(legacy, account: bearerAccount, service: service)) != nil,
           (try? read(bearerAccount, service: service)) == legacy {
            delete(legacyBearerAccount, service: service)
        }
        return legacy
    }

    /// Saves the key; nil or empty deletes it (both accounts, so a stale 0.1.x
    /// item cannot come back through the migration).
    public static func saveBearer(_ token: String?, service: String = VautaIdentity.keychainService) throws {
        let clean = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !clean.isEmpty else {
            delete(bearerAccount, service: service)
            delete(legacyBearerAccount, service: service)
            return
        }
        guard LLMClient.isValidToken(clean) else { throw LLMError.invalidStoredToken }
        try write(clean, account: bearerAccount, service: service)
        delete(legacyBearerAccount, service: service)
    }

    // MARK: Keychain items

    // Stored through `KeychainSecret` (the one Keychain implementation). Any
    // Keychain failure (locked, interaction not allowed, access cancelled)
    // becomes the retryable `LLMError.keychainUnavailable` the model client expects.

    static func read(_ account: String, service: String) throws -> String? {
        try mapKeychainErrors { try KeychainSecret.read(account, service: service) }
    }

    static func write(_ value: String, account: String, service: String) throws {
        try mapKeychainErrors { try KeychainSecret.write(value, account: account, label: label, service: service) }
    }

    static func delete(_ account: String, service: String) {
        KeychainSecret.delete(account, service: service)
    }

    private static func mapKeychainErrors<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw LLMError.keychainUnavailable
        }
    }
}
