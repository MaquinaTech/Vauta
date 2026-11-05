// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Synchronization

/// The one place an update check may go: GitHub's API for the latest release of Vauta's repository. Fail closed: everything is an
/// exact match (https, port 443, no user info, this host and this path, no query).
public enum UpdateDestination {
    public static let host = "api.github.com"
    public static let path = "/repos/MaquinaTech/Vauta/releases/latest"
    public static let url = URL(string: "https://\(host)\(path)")!

    /// The release page, built from a version that was parsed (never from text the server sent).
    public static func releasePage(_ version: ReleaseVersion) -> URL {
        URL(string: "https://github.com/MaquinaTech/Vauta/releases/tag/\(version.tag)")!
    }

    public static func isAllowed(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              url.host(percentEncoded: false)?.lowercased() == host, url.query == nil, url.fragment == nil else { return false }
        return url.path(percentEncoded: true) == path
    }
}

/// What an update check found.
public struct UpdateCheckResult: Sendable, Equatable {
    /// The newest release on GitHub.
    public let latest: ReleaseVersion
    /// The version running.
    public let installed: ReleaseVersion

    public init(latest: ReleaseVersion, installed: ReleaseVersion) {
        self.latest = latest
        self.installed = installed
    }

    /// A newer release exists. Never true for an older or equal one: a stale or replayed answer can't offer a downgrade.
    public var isUpdateAvailable: Bool { latest > installed }
}

/// Why an update check gave no answer. Categories only: the server's text is never kept or shown.
public enum UpdateCheckError: Error, Equatable, Sendable {
    /// No connection to GitHub (offline, DNS, timeout, certificate).
    case unreachable
    /// GitHub limits unauthenticated requests per address (403 or 429): the next daily check will do.
    case rateLimited
    /// Any other status, or a redirect (never followed).
    case refused(status: Int)
    /// The answer was not the release object Vauta expects (not JSON, too large, no release tag, a draft or a pre-release).
    case invalidResponse
}

/// Checks GitHub for a newer release of Vauta.
///
/// Only the release's tag is read from the answer: its name, notes, links and assets are ignored, and nothing the server sent is
/// shown or opened. The request carries no information about this Mac or this install: no version, no identifier, no cookie,
/// `User-Agent: Vauta`. It is the one `NetworkPurpose.updateCheck` request, listed in Network Activity.
///
/// The check only says that a release exists. Installing it is `scripts/update.sh`, which verifies the release tag's signature
/// against the maintainer's key before anything is built, so a forged answer here can at most offer an update that is refused.
public struct UpdateChecker: Sendable {
    /// An answer longer than this is refused (the real one is a few kilobytes).
    public static let maxResponseBytes = 512 << 10

    private let protocolClasses: [AnyClass]?
    private let log: NetworkActivityLog

    public init(log: NetworkActivityLog = .shared) {
        self.init(protocolClasses: nil, log: log)
    }

    init(protocolClasses: [AnyClass]?, log: NetworkActivityLog = .shared) {
        self.protocolClasses = protocolClasses
        self.log = log
    }

    /// The request, exactly: GET, GitHub's JSON media type and API version, a fixed language, nothing else.
    static func request() -> URLRequest {
        var request = URLRequest(url: UpdateDestination.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // The same for every install: the system would otherwise send the person's preferred languages.
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        return request
    }

    /// A session for one check: ephemeral, no cache, cookies or credentials, TLS 1.2 or later with the system's trust, system proxies
    /// honoured (the destination is on the internet), and the same bare `User-Agent` as the model downloads.
    static func makeSession(protocolClasses: [AnyClass]?, log: NetworkActivityLog) -> AuditedSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpAdditionalHeaders = ["User-Agent": "Vauta"]
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCredentialStorage = nil
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 30
        c.tlsMinimumSupportedProtocolVersion = .TLSv12
        c.httpMaximumConnectionsPerHost = 1
        if let protocolClasses { c.protocolClasses = protocolClasses }
        return AuditedSession(configuration: c, log: log)
    }

    /// Asks GitHub for the latest release and compares it with `installed`.
    public func check(installed: ReleaseVersion) async throws -> UpdateCheckResult {
        let request = Self.request()
        let session = Self.makeSession(protocolClasses: protocolClasses, log: log)
        defer { session.invalidateAndCancel() }
        guard UpdateDestination.isAllowed(request.url) else {
            await session.refuse(request.url!, method: "GET", purpose: .updateCheck, reason: .destinationNotAllowed)
            throw UpdateCheckError.invalidResponse
        }
        let body = Body()
        do {
            _ = try await session.stream(request, purpose: .updateCheck, accept: { response in
                // A 200 from the exact address asked, as JSON; a redirect or any other answer is refused before its body is read.
                response.statusCode == 200 && UpdateDestination.isAllowed(response.url) && response.mimeType?.lowercased() == "application/json"
            }, sink: { try body.append($0) })
        } catch AuditedStreamError.refused(let response) {
            switch response.statusCode {
            case 403, 429: throw UpdateCheckError.rateLimited
            case 200: throw UpdateCheckError.invalidResponse
            default: throw UpdateCheckError.refused(status: response.statusCode)
            }
        } catch let error as UpdateCheckError {
            throw error
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw UpdateCheckError.unreachable
        }
        return UpdateCheckResult(latest: try Self.latest(from: body.data), installed: installed)
    }

    /// The release in GitHub's answer: its tag must be a release number (`v1.2.3`), and it must be neither a draft nor a pre-release.
    static func latest(from data: Data) throws -> ReleaseVersion {
        struct Release: Decodable {
            let tag_name: String
            let draft: Bool?
            let prerelease: Bool?
        }
        guard data.count <= maxResponseBytes, let release = try? JSONDecoder().decode(Release.self, from: data),
              release.draft != true, release.prerelease != true, let version = ReleaseVersion(tag: release.tag_name) else {
            throw UpdateCheckError.invalidResponse
        }
        return version
    }

    /// The answer as it arrives, refused past `maxResponseBytes`.
    private final class Body: Sendable {
        private let buffer = Mutex(Data())

        var data: Data { buffer.withLock { $0 } }

        func append(_ chunk: Data) throws {
            try buffer.withLock { data in
                guard data.count + chunk.count <= UpdateChecker.maxResponseBytes else { throw UpdateCheckError.invalidResponse }
                data.append(chunk)
            }
        }
    }
}
