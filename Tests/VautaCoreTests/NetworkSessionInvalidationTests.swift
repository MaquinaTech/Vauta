// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// A session that is invalidated while requests are on their way: starting a task on an invalidated URL session raises an
/// Objective-C exception that would end the app, so every request ends in a Swift error instead; and applying the configuration
/// the client already has (a status check does it before it asks) leaves the requests under way alone.
@Suite("Network: an invalidated session")
struct NetworkSessionInvalidationTests {
    typealias F = ModelsFixtures

    private static func configuration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubServer.self]
        return c
    }

    /// Polls until `condition` holds, for at most 600 s (a loaded test run is slow to deliver a stubbed request).
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(600)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    /// A client of a server that keeps each chat request until `hold` lets it go.
    private func heldClient(_ hold: Hold) -> (LLMClient, port: Int) {
        let port = HeldServer.register(hold)
        return (LLMClient(config: F.config(.local, "http://127.0.0.1:\(port)/v1"), bearer: { nil }, protocolClasses: [HeldServer.self]), port)
    }

    private func minutes(_ client: LLMClient) -> Task<String, Error> {
        Task { try await client.chat([.user("hi")], ChatOptions(model: .deep, maxTokens: 20, purpose: .minutes)).content }
    }

    @Test func everyKindOfRequestOnAnInvalidatedSessionIsCancelledAndNothingIsSent() async throws {
        let port = StubServer.register { _ in .json(["data": []]) }
        defer { StubServer.unregister(port) }
        let log = NetworkActivityLog()
        let session = AuditedSession(configuration: Self.configuration(), log: log)
        session.invalidateAndCancel()
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
        await #expect(throws: CancellationError.self) { _ = try await session.bytes(for: request, purpose: .statusCheck) }
        await #expect(throws: CancellationError.self) { _ = try await session.data(for: request, purpose: .statusCheck) }
        await #expect(throws: CancellationError.self) {
            _ = try await session.stream(request, purpose: .modelDownload, accept: { _ in true }, sink: { _ in })
        }
        #expect(StubServer.requests(port).isEmpty, "nothing was sent")
        let entries = await log.snapshot()
        #expect(!entries.isEmpty && entries.allSatisfy { $0.error == .cancelled && !$0.isInProgress })
    }

    @Test func aNewConfigurationBetweenPreparingARequestAndSendingItEndsInASwiftError() async throws {
        let port = StubServer.register { _ in .json(["data": [["id": "deep-model"]]]) }
        defer { StubServer.unregister(port) }
        let client = F.client(port: port)
        // What a request holds once it is prepared: the request, and the session it was prepared on.
        let request = try client.makeRequest(.models, body: nil)
        let session = client.connection.session
        var other = try #require(client.config)
        other.contextTokens = 16_384
        client.apply(other)
        await #expect(throws: CancellationError.self) {
            _ = try await client.perform { try await session.bytes(for: request, purpose: .statusCheck) }
        }
        #expect(StubServer.requests(port).isEmpty)
        // The next request goes out on a new session.
        #expect(try await client.models() == ["deep-model"])
    }

    @Test(.timeLimit(.minutes(10))) func theSameConfigurationAgainLeavesARequestUnderWayAlone() async throws {
        let hold = Hold()
        let (client, port) = heldClient(hold)
        defer { HeldServer.unregister(port) }
        let config = try #require(client.config)
        let running = minutes(client)
        try await waitUntil { hold.arrived }
        client.apply(config)
        hold.release()
        #expect(try await running.value == "minutes")
    }

    @Test(.timeLimit(.minutes(10))) func aNewConfigurationStillCancelsARequestUnderWayAndItsSessionStartsNothingMore() async throws {
        let hold = Hold()
        let (client, port) = heldClient(hold)
        defer { HeldServer.unregister(port) }
        var other = try #require(client.config)
        other.contextTokens = 16_384
        let running = minutes(client)
        try await waitUntil { hold.arrived }
        let old = client.connection.session
        // The request is still waiting for its answer inside URLSession: its task is cancelled now, the session closed after it.
        client.apply(other)
        // Its URL task was cancelled, not the Swift task: a network error, not a cancellation.
        await #expect(throws: LLMError.network(LLMClient.connectionRefused)) { _ = try await running.value }
        hold.release()
        let request = try client.makeRequest(.models, body: nil)
        await #expect(throws: CancellationError.self) { _ = try await old.bytes(for: request, purpose: .statusCheck) }
    }

    @Test func theSameConfigurationAgainKeepsTheSessionAndAfterARefusedPeerReplacesIt() throws {
        let client = LLMClient(config: F.config(.local, "http://127.0.0.1:47999/v1"), bearer: { nil }, protocolClasses: [StubServer.self])
        let config = try #require(client.config)
        let first = client.connection.session
        client.apply(config)
        #expect(client.connection.session === first, "the same configuration keeps the connections")
        // A refused peer is cleared only by applying the configuration again (SECURITY.md), which also probes on a new session.
        client.recordPeerViolation("8.8.8.8")
        client.apply(config)
        #expect(client.peerViolation == nil)
        #expect(client.connection.session !== first)
    }
}

/// Whether the held request has arrived, and whether the test has let it go.
private final class Hold: @unchecked Sendable {
    private let lock = NSLock()
    private var _arrived = false
    private var _released = false

    var arrived: Bool { lock.withLock { _arrived } }
    var released: Bool { lock.withLock { _released } }
    func arrive() { lock.withLock { _arrived = true } }
    func release() { lock.withLock { _released = true } }
}

/// A model server that answers a chat request once its `Hold` is released. Every stubbed request of the test run is loaded on
/// one thread, so the answer waits on a timer of that thread's run loop instead of blocking it (`StubServer` answers at once).
private final class HeldServer: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var holds: [Int: Hold] = [:]
    nonisolated(unsafe) private static var nextPort = 47_000
    /// Read and written on the loading thread only.
    private var timer: Timer?

    static func register(_ hold: Hold) -> Int {
        lock.withLock {
            nextPort += 1
            holds[nextPort] = hold
            return nextPort
        }
    }

    static func unregister(_ port: Int) { lock.withLock { holds[port] = nil } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, url.path().hasSuffix("/chat/completions"),
              let hold = Self.lock.withLock({ Self.holds[url.port ?? 80] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        hold.arrive()
        let timer = Timer(timeInterval: 0.005, repeats: true) { [weak self] timer in
            guard hold.released, let self else { return }
            timer.invalidate()
            let body = Data(ModelsFixtures.sse([ModelsFixtures.delta("minutes", finish: "stop"), ModelsFixtures.usage]).utf8)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        self.timer = timer
        RunLoop.current.add(timer, forMode: .common)
    }

    override func stopLoading() { timer?.invalidate() }
}
