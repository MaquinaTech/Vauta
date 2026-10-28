// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// A server given by name gets nothing with a body or the key before the address it connects to is known to be allowed.
/// The stub has no socket, so the addresses the metrics report are injected; the metrics callback itself is the real one.
@Suite("Models: peer check before the first request")
struct ModelsPeerCheckTests {
    typealias F = ModelsFixtures

    private static let chatReply = StubServer.Reply.text(F.sse([F.delta("ok", finish: "stop")]))

    private func nameServer() -> Int {
        StubServer.register { r in r.url.path().hasSuffix("/chat/completions") ? Self.chatReply : .json(["data": [["id": "deep-model"]]]) }
    }

    private func client(_ url: String, peers: [String], timeout: Duration = .seconds(10),
                        bearer: @escaping @Sendable () throws -> String? = { "sk-secret-key" }) -> LLMClient {
        LLMClient(config: F.config(.remote, url, pins: [F.serverPin]), bearer: bearer, protocolClasses: [StubServer.self],
                  peerAddresses: { _ in peers }, peerCheckTimeout: timeout)
    }

    private func ask(_ client: LLMClient) async throws -> String {
        try await client.chat([.user("confidential")], ChatOptions(model: .deep, maxTokens: 10)).content
    }

    @Test func aNameThatResolvesOutsideGetsOnlyAnEmptyProbe() async throws {
        let port = nameServer()
        defer { StubServer.unregister(port) }
        let client = client("https://gpu.local:\(port)/v1", peers: ["203.0.113.9"])
        await #expect(throws: LLMError.untrustedPeerAddress("203.0.113.9")) { try await ask(client) }
        let sent = StubServer.requests(port)
        #expect(sent.count == 1)
        let probe = try #require(sent.first)
        #expect(probe.method == "GET" && probe.url.path() == "/v1/models")
        #expect(probe.headers["Authorization"] == nil && (probe.body ?? Data()).isEmpty)
        // Later requests are refused before anything is sent.
        await #expect(throws: LLMError.untrustedPeerAddress("203.0.113.9")) { try await ask(client) }
        #expect(StubServer.requests(port).count == 1)
    }

    @Test func anAllowedPeerIsProbedOncePerSession() async throws {
        let port = nameServer()
        defer { StubServer.unregister(port) }
        let client = client("https://gpu.local:\(port)/v1", peers: ["10.0.0.7"])
        async let first = ask(client)
        async let second = ask(client)
        #expect(try await [first, second] == ["ok", "ok"])
        var sent = StubServer.requests(port)
        #expect(sent.map(\.method) == ["GET", "POST", "POST"])
        #expect(sent[0].headers["Authorization"] == nil)
        #expect(sent[1...].allSatisfy { $0.headers["Authorization"] == "Bearer sk-secret-key" })
        // A new session (after the key changes, for example) checks again.
        client.reset()
        _ = try await ask(client)
        sent = StubServer.requests(port)
        #expect(sent.map(\.method) == ["GET", "POST", "POST", "GET", "POST"])
    }

    @Test func noAddressInTheMetricsFailsClosed() async throws {
        let port = nameServer()
        defer { StubServer.unregister(port) }
        let client = client("https://gpu.local:\(port)/v1", peers: [])
        await #expect(throws: LLMError.self) { try await ask(client) }
        #expect(StubServer.requests(port).map(\.method) == ["GET"])
        // Not remembered as a violation: the next request probes again (and fails closed again).
        await #expect(throws: LLMError.self) { try await ask(client) }
        #expect(StubServer.requests(port).map(\.method) == ["GET", "GET"])
    }

    @Test func localModeNamesMustConnectToLoopback() async throws {
        let port = nameServer()
        defer { StubServer.unregister(port) }
        let config = F.config(.local, "http://localhost:\(port)/v1")
        let outside = LLMClient(config: config, bearer: { nil }, protocolClasses: [StubServer.self], peerAddresses: { _ in ["10.0.0.7"] })
        await #expect(throws: LLMError.untrustedPeerAddress("10.0.0.7")) { try await ask(outside) }
        #expect(StubServer.requests(port).map(\.method) == ["GET"])
        let loopback = LLMClient(config: config, bearer: { nil }, protocolClasses: [StubServer.self], peerAddresses: { _ in ["127.0.0.1"] })
        #expect(try await ask(loopback) == "ok")
    }

    @Test func ipLiteralsNeedNoProbe() async throws {
        let port = nameServer()
        defer { StubServer.unregister(port) }
        let client = LLMClient(config: F.config(.remote, "https://10.0.0.7:\(port)/v1"), bearer: { "sk-secret-key" },
                               protocolClasses: [StubServer.self], peerAddresses: { _ in [] })
        #expect(try await ask(client) == "ok")
        #expect(StubServer.requests(port).map(\.method) == ["POST"])
    }

    @Test func theWaitForMetricsHasATimeout() async {
        // No metrics ever come: the wait ends empty-handed (no wall-clock bound: a loaded test run delays the timer).
        let watch = PeerWatch(addresses: { _ in ["10.0.0.7"] })
        #expect(await watch.addresses(within: .milliseconds(50)) == nil)
    }
}
