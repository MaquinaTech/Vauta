// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Security
import Testing
@testable import VautaCore

/// The model server session's rules, read back from what the code sets: TLS 1.3, no proxy, nothing kept, no redirect followed,
/// and no network fetch while a certificate is checked.
@Suite("Models: the session's rules")
struct ModelsSessionRulesTests {
    typealias F = ModelsFixtures

    @Test func theSessionIsTLS13WithoutProxiesOrState() throws {
        let c = LLMClient.sessionConfiguration()
        #expect(c.tlsMinimumSupportedProtocolVersion == .TLSv13)
        #expect(c.urlCache == nil && c.httpCookieStorage == nil && c.urlCredentialStorage == nil)
        #expect(!c.httpShouldSetCookies)
        #expect(c.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        let proxies = try #require(c.connectionProxyDictionary)
        for key in [kCFNetworkProxiesHTTPEnable, kCFNetworkProxiesHTTPSEnable, kCFNetworkProxiesProxyAutoConfigEnable,
                    kCFNetworkProxiesProxyAutoDiscoveryEnable, kCFNetworkProxiesSOCKSEnable] as [CFString] {
            #expect(proxies[key as String] as? Bool == false, Comment(rawValue: key as String))
        }
    }

    @Test func aRedirectIsNeverFollowed() async throws {
        let elsewhere = StubServer.register { _ in .json(["object": "list", "data": [["id": "fast"]]]) }
        let port = StubServer.register { _ in
            StubServer.Reply(status: 302, headers: ["Location": "http://127.0.0.1:\(elsewhere)/v1/models"], body: Data())
        }
        defer { StubServer.unregister(port); StubServer.unregister(elsewhere) }
        let client = F.client(port: port)
        await #expect(throws: (any Error).self) { try await client.allModels() }
        #expect(StubServer.requests(port).count >= 1, "the server was asked")
        #expect(StubServer.requests(elsewhere).isEmpty, "nothing went where the redirect pointed")
    }

    @Test func checkingACertificateFetchesNothing() throws {
        let config = F.config(.remote, "https://10.0.0.7:8443/v1", ca: F.testCA)
        let certs = LLMServerConfig.ders(fromPEM: F.testServer).compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        var trust: SecTrust?
        SecTrustCreateWithCertificates(certs as CFArray, SecPolicyCreateSSL(true, "10.0.0.7" as CFString), &trust)
        let built = try #require(trust)
        #expect(ServerTrust.evaluate(built, try config.validated(), at: Date(timeIntervalSince1970: 1_800_000_000)))
        var allowed: DarwinBoolean = true
        #expect(SecTrustGetNetworkFetchAllowed(built, &allowed) == errSecSuccess)
        #expect(!allowed.boolValue, "no missing intermediate, OCSP or CRL is fetched")
    }
}
