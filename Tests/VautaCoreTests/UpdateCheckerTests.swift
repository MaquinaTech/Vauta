// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Synchronization
import Testing
@testable import VautaCore

/// GitHub behind `URLProtocol`: no socket is opened. One reply at a time (the suite is serialized).
final class ReleaseStub: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var headers = ["Content-Type": "application/json; charset=utf-8"]
        var body = Data()
        var chunks = 1
    }

    static let state = Mutex<(reply: Reply, requests: [URLRequest])>((Reply(), []))

    static func reply(_ reply: Reply) { state.withLock { $0 = (reply, []) } }
    static var requests: [URLRequest] { state.withLock { $0.requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = Self.state.withLock { state in
            state.requests.append(request)
            return state.reply
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        // A redirect is offered to the session as a server's would be: its delegate decides whether the new request is made.
        if (300..<400).contains(reply.status), let location = reply.headers["Location"], let next = URL(string: location) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: next), redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let size = max(1, reply.body.count / reply.chunks)
        var offset = 0
        while offset < reply.body.count {
            client?.urlProtocol(self, didLoad: reply.body.subdata(in: offset..<min(reply.body.count, offset + size)))
            offset += size
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Updates: the release check", .serialized)
struct UpdateCheckerTests {
    private static let installed = ReleaseVersion("0.10.0")!

    private func release(_ tag: String, draft: Bool = false, prerelease: Bool = false, extra: [String: Any] = [:]) -> Data {
        var object: [String: Any] = ["tag_name": tag, "draft": draft, "prerelease": prerelease, "name": "Vauta \(tag)",
                                     "body": "Ignore this text", "html_url": "https://evil.example/x"]
        object.merge(extra) { $1 }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func check(_ reply: ReleaseStub.Reply, log: NetworkActivityLog = NetworkActivityLog()) async throws -> UpdateCheckResult {
        ReleaseStub.reply(reply)
        return try await UpdateChecker(protocolClasses: [ReleaseStub.self], log: log).check(installed: Self.installed)
    }

    @Test func versionsParseStrictly() {
        #expect(ReleaseVersion("0.10.0") == ReleaseVersion(major: 0, minor: 10, patch: 0))
        #expect(ReleaseVersion(tag: "v1.2.3")?.description == "1.2.3" && ReleaseVersion(tag: "v1.2.3")?.tag == "v1.2.3")
        for bad in ["0.10", "0.10.0.1", "0.10.0-rc1", "0.10.0+b", " 0.10.0", "0.10.0\n", "+1.0.0", "-1.0.0", "1..0", "٣.0.0", "1.0.10000",
                    "", "a.b.c", "0x1.0.0"] {
            #expect(ReleaseVersion(bad) == nil, "\(bad)")
        }
        for bad in ["0.10.0", "V0.10.0", "vv0.10.0", "v0.10.0-rc1", "latest", "v99999.0.0"] {
            #expect(ReleaseVersion(tag: bad) == nil, "\(bad)")
        }
        #expect(ReleaseVersion("0.10.0")! > ReleaseVersion("0.9.3")!)
        #expect(ReleaseVersion("1.0.0")! > ReleaseVersion("0.99.99")!)
        #expect(ReleaseVersion("0.10.1")! > ReleaseVersion("0.10.0")!)
    }

    @Test func onlyTheExactAddressIsAllowed() {
        #expect(UpdateDestination.isAllowed(UpdateDestination.url))
        #expect(UpdateDestination.isAllowed(URL(string: "https://API.GITHUB.COM/repos/MaquinaTech/Vauta/releases/latest")))
        for bad in ["http://api.github.com/repos/MaquinaTech/Vauta/releases/latest",
                    "https://api.github.com:8443/repos/MaquinaTech/Vauta/releases/latest",
                    "https://user@api.github.com/repos/MaquinaTech/Vauta/releases/latest",
                    "https://api.github.com/repos/MaquinaTech/Vauta/releases/latest?x=1",
                    "https://api.github.com/repos/MaquinaTech/Vauta/releases/latest#x",
                    "https://api.github.com/repos/Someone/Vauta/releases/latest",
                    "https://api.github.com/repos/MaquinaTech/Vauta/releases",
                    "https://api.github.com.example.com/repos/MaquinaTech/Vauta/releases/latest",
                    "https://github.com/repos/MaquinaTech/Vauta/releases/latest"] {
            #expect(!UpdateDestination.isAllowed(URL(string: bad)), "\(bad)")
        }
        #expect(!UpdateDestination.isAllowed(nil))
        #expect(UpdateDestination.releasePage(ReleaseVersion("0.11.0")!).absoluteString == "https://github.com/MaquinaTech/Vauta/releases/tag/v0.11.0")
    }

    @Test func onlyAReleaseTagIsRead() throws {
        #expect(try UpdateChecker.latest(from: release("v0.11.0")) == ReleaseVersion("0.11.0"))
        #expect(try UpdateChecker.latest(from: Data(#"{"tag_name":"v0.11.0"}"#.utf8)) == ReleaseVersion("0.11.0"))
        for bad in [release("v0.11.0", draft: true), release("v0.11.0", prerelease: true), release("v0.11.0-rc1"), release("latest"),
                    Data(#"{"name":"v0.11.0"}"#.utf8), Data(#"[{"tag_name":"v0.11.0"}]"#.utf8), Data("<html>".utf8), Data(),
                    Data(#"{"tag_name":11}"#.utf8)] {
            #expect(throws: UpdateCheckError.invalidResponse) { try UpdateChecker.latest(from: bad) }
        }
        let padded = release("v0.11.0", extra: ["body": String(repeating: "x", count: UpdateChecker.maxResponseBytes)])
        #expect(throws: UpdateCheckError.invalidResponse) { try UpdateChecker.latest(from: padded) }
    }

    @Test func aNewerReleaseIsOfferedAndTheRequestCarriesNothingAboutTheInstall() async throws {
        let log = NetworkActivityLog()
        let result = try await check(.init(body: release("v0.11.0"), chunks: 3), log: log)
        #expect(result == UpdateCheckResult(latest: ReleaseVersion("0.11.0")!, installed: Self.installed) && result.isUpdateAvailable)

        let request = try #require(ReleaseStub.requests.first)
        #expect(ReleaseStub.requests.count == 1)
        #expect(request.httpMethod == "GET" && request.url == UpdateDestination.url && request.httpBody == nil)
        let headers = request.allHTTPHeaderFields ?? [:]
        #expect(headers["Accept"] == "application/vnd.github+json" && headers["X-GitHub-Api-Version"] == "2022-11-28")
        #expect(headers["Accept-Language"] == "en", "not the person's languages")
        #expect(headers["Cookie"] == nil && headers["Authorization"] == nil)
        // The session's bare User-Agent: no version, no build, no system.
        #expect(headers["User-Agent"] == "Vauta")
        #expect(Set(headers.keys).isSubset(of: ["Accept", "X-GitHub-Api-Version", "User-Agent", "Accept-Encoding", "Accept-Language"]), "\(headers.keys)")
        let entry = try #require(await log.snapshot().first)
        #expect(entry.purpose == .updateCheck && entry.host == "api.github.com" && entry.scope == .updateCheck && entry.isSuccess)
        #expect(NetworkDestination.summarize(await log.snapshot()).map(\.scope) == [.updateCheck])
    }

    @Test func theSameOrAnOlderReleaseIsNeverOffered() async throws {
        #expect(try await !check(.init(body: release("v0.10.0"))).isUpdateAvailable)
        #expect(try await !check(.init(body: release("v0.9.3"))).isUpdateAvailable, "a stale or replayed answer can't offer a downgrade")
    }

    @Test func anythingButAJSONReleaseFromTheExactAddressIsRefused() async throws {
        await #expect(throws: UpdateCheckError.rateLimited) { try await check(.init(status: 403)) }
        await #expect(throws: UpdateCheckError.rateLimited) { try await check(.init(status: 429)) }
        await #expect(throws: UpdateCheckError.refused(status: 500)) { try await check(.init(status: 500)) }
        // A redirect is never followed, wherever it points.
        await #expect(throws: UpdateCheckError.refused(status: 302)) {
            try await check(.init(status: 302, headers: ["Location": "https://evil.example/releases/latest"]))
        }
        #expect(ReleaseStub.requests.map(\.url) == [UpdateDestination.url])
        await #expect(throws: UpdateCheckError.invalidResponse) {
            try await check(.init(headers: ["Content-Type": "text/html"], body: Data("<html>v9.9.9</html>".utf8)))
        }
        await #expect(throws: UpdateCheckError.invalidResponse) { try await check(.init(body: release("v0.11.0", prerelease: true))) }
        // Too long, as it streams in: refused before it is all in memory.
        let huge = release("v0.11.0", extra: ["body": String(repeating: "x", count: 2 * UpdateChecker.maxResponseBytes)])
        await #expect(throws: UpdateCheckError.invalidResponse) { try await check(.init(body: huge, chunks: 64)) }
    }

    @Test func theUpdateCheckIsItsOwnPurposeAndScope() async {
        #expect(NetworkPurpose.updateCheck.rawValue == "updateCheck" && !NetworkPurpose.updateCheck.isModelDownload)
        #expect(NetworkDestination.Scope.updateCheck.rawValue == "updateCheck" && NetworkDestination.Scope.updateCheck.isAllowedInternet)
        let log = NetworkActivityLog()
        // Another host, or another purpose to GitHub, is outside: only the exact pair is the update check.
        for (purpose, url) in [(NetworkPurpose.updateCheck, "https://example.com/x"), (.ask, "https://api.github.com/x")] {
            let id = await log.begin(purpose: purpose, url: URL(string: url)!, method: "GET", bytesSent: 0)
            await log.finish(id, status: 200, error: nil, bytesReceived: 1, duration: 0.1)
        }
        #expect(await log.snapshot().map(\.scope) == [.outside, .outside])
    }

    @Test func theNotificationCarriesOnlyTheVersion() {
        let n = AppNotification.updateAvailable(ReleaseVersion("0.11.0")!)
        #expect(n.kind == .updateAvailable && n.title.contains("0.11.0") && n.meetingID == nil)
        #expect(n.kind.actions == [.showUpdate] && n.kind.defaultAction == .showUpdate)
        #expect(AppNotification.isAllowed(.updateAvailable, notifyMinutesReady: false, notifyProblems: false))
    }
}
