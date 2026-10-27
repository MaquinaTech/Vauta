// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Service name of Vauta's Keychain items: the bundle ID the app was built with
/// (each install chooses its own in scripts/build-app.sh). Outside a bundle
/// (the diagnostic CLI run from `.build`) a fixed fallback is used.
///
/// The service is part of the persisted format: changing the bundle ID makes
/// existing Keychain items (and the sandbox container) unreachable.
public enum VautaIdentity {
    /// The service outside a bundle.
    static let unbundledService = "local.vauta.cli"
    /// The same, before the rename (the earlier version). Its items are moved on first read, see `Keychain`.
    static let legacyUnbundledService = "local.acta.cli"

    public static let keychainService = Bundle.main.bundleIdentifier ?? unbundledService

    /// Where items of `service` were kept before the rename, if anywhere else.
    /// A bundled build keeps its bundle ID (the service), so only the
    /// unbundled fallback changed.
    static func legacyService(for service: String) -> String? {
        service == unbundledService ? legacyUnbundledService : nil
    }
}
