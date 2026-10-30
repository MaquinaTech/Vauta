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

    /// The key for this run of the app: read from the Keychain once, then kept in memory and never written anywhere else.
    /// While an item's access list doesn't name this build (an ad-hoc build after an update), each read asks macOS for
    /// access, and "Allow", unlike "Always Allow", asks again on the next one: reading the key for every request put up a
    /// dialog per request, several at a time. A read that fails (locked Keychain, access refused) is not kept, so the next
    /// request asks again. `saveBearer` replaces what is kept; a key deleted in Keychain Access is sent until Vauta quits.
    public static func sessionBearer(service: String = VautaIdentity.keychainService) throws -> String? {
        try session.key(for: service) { try readBearer(service: $0) }
    }

    static let session = SessionKeys()

    /// Saves the key; nil or empty deletes it (both accounts, so a stale 0.1.x
    /// item cannot come back through the migration).
    public static func saveBearer(_ token: String?, service: String = VautaIdentity.keychainService) throws {
        let clean = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !clean.isEmpty else {
            delete(bearerAccount, service: service)
            delete(legacyBearerAccount, service: service)
            // Even if a delete failed: a key the person removed is not sent again.
            session.replace(nil, for: service)
            return
        }
        guard LLMClient.isValidToken(clean) else { throw LLMError.invalidStoredToken }
        do {
            try write(clean, account: bearerAccount, service: service)
        } catch {
            // The Keychain holds the old key or the new one: the next request reads it again.
            session.forget(service)
            throw error
        }
        delete(legacyBearerAccount, service: service)
        session.replace(clean, for: service)
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

/// The keys read in this run, by Keychain service (nil = no key). Requests that ask while the first read is under way
/// wait for it instead of reading again: each read could put up its own dialog. An NSLock, not an unfair lock, because
/// it is held while macOS waits for the person to answer.
final class SessionKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String?] = [:]

    func key(for service: String, read: (String) throws -> String?) rethrows -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let kept = keys[service] { return kept }
        let key = try read(service)
        keys.updateValue(key, forKey: service)
        return key
    }

    func replace(_ key: String?, for service: String) {
        lock.withLock { _ = keys.updateValue(key, forKey: service) }
    }

    func forget(_ service: String) {
        lock.withLock { _ = keys.removeValue(forKey: service) }
    }
}
