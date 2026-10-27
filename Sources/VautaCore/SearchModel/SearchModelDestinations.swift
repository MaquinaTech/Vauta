// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The only places the search model download may talk to. Fail closed: everything is an exact match.
enum SearchModelDestinations {
    static let host = "huggingface.co"
    /// The hosts a resolve redirect may point to, by exact name. Verified on 2026-10-12 from one network; before a release the
    /// two files are resolved from an EU and an APAC network and every host actually seen is added here by name (no
    /// wildcards: docs/RELEASING.md).
    static let allowedCDNHosts: Set<String> = ["us.aws.cdn.hf.co"]

    /// A request to Hugging Face: https, port 443, no user info, and exactly the path of one of the two files of `spec`.
    static func isAllowedResolve(_ url: URL, spec: SearchModelSpec) -> Bool {
        guard secure(url), url.host(percentEncoded: false)?.lowercased() == host else { return false }
        let path = url.path(percentEncoded: true)
        return path == spec.resolvePath(spec.sourceFile) || path == spec.resolvePath(spec.tokenizerFile)
    }

    /// Where a resolve may redirect to: https, port 443, no user info, a host of the allowlist. CDN paths are opaque.
    static func isAllowedCDN(_ url: URL) -> Bool {
        guard secure(url), let h = url.host(percentEncoded: false)?.lowercased(), allowedCDNHosts.contains(h) else { return false }
        return !url.path(percentEncoded: true).isEmpty
    }

    private static func secure(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }
}
