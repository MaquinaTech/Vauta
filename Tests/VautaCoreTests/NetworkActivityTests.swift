// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The network audit: every kind of call is recorded, and only metadata is kept.
@Suite("Network activity")
struct NetworkActivityTests {
    typealias F = ModelsFixtures

    private func withServer<T>(_ handler: @escaping StubServer.Handler, _ body: (Int, NetworkActivityLog) async throws -> T) async throws -> T {
        let port = StubServer.register(handler)
        defer { StubServer.unregister(port) }
        return try await body(port, NetworkActivityLog())
    }

    private func streamReply() -> StubServer.Reply {
        .text(F.sse([F.delta("hello", finish: "stop"), F.usage]))
    }

    // MARK: Every call type is recorded

    @Test func chatIsRecordedWithItsPurpose() async throws {
        try await withServer({ _ in streamReply() }) { port, log in
            let client = F.client(port: port, log: log)
            _ = try await client.chat([.user("hi")], ChatOptions(model: .deep, maxTokens: 20, purpose: .minutes))
            _ = try await client.chat([.user("hi")], ChatOptions(model: .fast, maxTokens: 20, purpose: .liveNotes))
            _ = try await client.chat([.user("hi")], ChatOptions(model: .deep, maxTokens: 20, purpose: .ask))
            _ = try await client.chat([.user("hi")], ChatOptions(model: .fast, maxTokens: 20, purpose: .translation))
            let entries = await log.snapshot()
            #expect(entries.map(\.purpose) == [.minutes, .liveNotes, .ask, .translation])
            let first = try #require(entries.first)
            #expect(first.scheme == "http" && first.host == "127.0.0.1" && first.port == port)
            #expect(first.method == "POST" && first.path == "/v1/chat/completions")
            #expect(first.status == 200 && first.error == nil && first.isSuccess)
            #expect(first.bytesSent > 0 && first.bytesReceived > 0)
            #expect(first.duration != nil && !first.isInProgress)
            #expect(first.destination == "127.0.0.1:\(port)")
        }
    }

    @Test func chatWithoutPurposeIsOther() async throws {
        try await withServer({ _ in streamReply() }) { port, log in
            _ = try await F.client(port: port, log: log).chat([.user("hi")], ChatOptions(model: .deep, maxTokens: 20))
            #expect(await log.snapshot().map(\.purpose) == [.other])
        }
    }

    @Test func modelListsAreStatusChecks() async throws {
        try await withServer({ _ in .json(["data": [["id": "a"]]]) }) { port, log in
            let client = F.client(port: port, log: log)
            _ = try await client.allModels()
            _ = try await client.allModels(purpose: .connectionTest)
            let entries = await log.snapshot()
            #expect(entries.map(\.purpose) == [.statusCheck, .connectionTest])
            #expect(entries.allSatisfy { $0.method == "GET" && $0.path == "/v1/models" && $0.bytesSent == 0 && $0.bytesReceived > 0 })
        }
    }

    @Test func embeddingsAreRecorded() async throws {
        try await withServer({ _ in .json(["data": [["index": 0, "embedding": (0..<1024).map { Float($0) / 1024 }]]]) }) { port, log in
            _ = try await F.client(port: port, log: log).embed(["some private text"])
            let entry = try #require(await log.snapshot().first)
            #expect(entry.purpose == .embeddings && entry.path == "/v1/embeddings" && entry.method == "POST")
        }
    }

    @Test func connectionTestInspectsAreRecorded() async throws {
        try await withServer({ r in
            switch r.url.path() {
            case "/v1/models": .json(["data": [["id": "m"]]])
            case "/api/version": .json(["version": "0.12.0"])
            case "/api/tags": .json(["models": [["name": "m"]]])
            default: nil
            }
        }) { port, log in
            _ = try await F.client(port: port, log: log).inspect()
            let entries = await log.snapshot()
            #expect(entries.count >= 2)
            #expect(entries.allSatisfy { $0.purpose == .connectionTest })
            #expect(entries.contains { $0.path == "/api/version" })
        }
    }

    @Test func discoveryProbesAreRecorded() async throws {
        let port = StubServer.register { r in r.url.path() == "/v1/models" ? .json(["data": [["id": "m"]]]) : nil }
        defer { StubServer.unregister(port) }
        let log = NetworkActivityLog()
        let session = ServerDiscovery.loopbackSession(timeout: 1, protocolClasses: [StubServer.self], log: log)
        let root = URL(string: "http://127.0.0.1:\(port)/")!
        let found = await ServerDiscovery.identify(baseURL: root.appending(path: "v1/"), hints: [],
                                                   fetch: ServerDiscovery.loopbackFetch(session: session, root: root, timeout: 1))
        #expect(found != nil)
        let entries = await log.snapshot()
        #expect(!entries.isEmpty && entries.allSatisfy { $0.purpose == .discovery && $0.host == "127.0.0.1" })
        #expect(entries.contains { $0.status == 404 })
    }

    // MARK: Results

    @Test func serverErrorsKeepTheStatus() async throws {
        try await withServer({ _ in .json(["error": "busy"], status: 503) }) { port, log in
            await #expect(throws: (any Error).self) { try await F.client(port: port, log: log).allModels() }
            let entry = try #require(await log.snapshot().first)
            #expect(entry.status == 503 && !entry.isSuccess && !entry.isInProgress)
        }
    }

    @Test func connectionFailuresRecordAnErrorKind() async throws {
        let log = NetworkActivityLog()
        // No handler on this port: the stub fails the connection.
        let client = F.client(port: 39_999, log: log)
        await #expect(throws: (any Error).self) { try await client.allModels() }
        let entry = try #require(await log.snapshot().first)
        #expect(entry.error == .unreachable && entry.status == nil && !entry.isSuccess)
    }

    @Test func errorKindsMapURLErrors() {
        #expect(NetworkErrorKind(URLError(.timedOut)) == .timedOut)
        #expect(NetworkErrorKind(URLError(.cannotConnectToHost)) == .unreachable)
        #expect(NetworkErrorKind(URLError(.networkConnectionLost)) == .connectionLost)
        #expect(NetworkErrorKind(URLError(.serverCertificateUntrusted)) == .tls)
        #expect(NetworkErrorKind(URLError(.cancelled)) == .cancelled)
        #expect(NetworkErrorKind(CancellationError()) == .cancelled)
        #expect(NetworkErrorKind(URLError(.badURL)) == .other)
    }

    @Test func aConnectionRefusedByTheTrustCheckIsACertificateProblem() {
        // The delegate cancels the TLS challenge: URLSession reports `cancelled` although nobody cancelled.
        #expect(AuditedSession.kind(of: URLError(.cancelled), callerCancelled: false) == .tls)
        #expect(AuditedSession.kind(of: URLError(.cancelled), callerCancelled: true) == .cancelled)
        #expect(AuditedSession.kind(of: CancellationError(), callerCancelled: false) == .cancelled)
        #expect(AuditedSession.kind(of: URLError(.timedOut), callerCancelled: false) == .timedOut)
    }

    // MARK: Nothing sensitive is stored

    @Test func contentHeadersKeysAndQueriesAreNeverStored() async throws {
        let port = StubServer.register { _ in .json(["answer": "REPLY-SECRET"]) }
        defer { StubServer.unregister(port) }
        let log = NetworkActivityLog()
        let session = AuditedSession(configuration: stubConfiguration(), log: log)
        var request = URLRequest(url: URL(string: "http://user:PASSWORD-SECRET@127.0.0.1:\(port)/v1/models?api_key=QUERY-SECRET#FRAGMENT-SECRET")!)
        request.httpMethod = "POST"
        request.httpBody = Data("PROMPT-SECRET".utf8)
        request.setValue("Bearer KEY-SECRET", forHTTPHeaderField: "Authorization")
        _ = try await session.data(for: request, purpose: .ask)
        let entries = await log.snapshot()
        let entry = try #require(entries.first)
        #expect(entry.path == "/v1/models")
        #expect(entry.bytesSent == "PROMPT-SECRET".utf8.count)
        let exported = String(decoding: try await log.exportJSON(), as: UTF8.self)
        let dump = "\(entries)" + exported
        for secret in ["PROMPT-SECRET", "KEY-SECRET", "QUERY-SECRET", "FRAGMENT-SECRET", "PASSWORD-SECRET", "REPLY-SECRET", "Authorization", "api_key"] {
            #expect(!dump.contains(secret), "\(secret) must not be stored")
        }
    }

    @Test func entryFieldsAreTheDocumentedOnes() throws {
        let entry = NetworkActivityEntry(id: 1, timestamp: Date(timeIntervalSince1970: 0), purpose: .ask,
                                         url: URL(string: "https://[fd00::1]/v1/chat?x=1")!, method: "post", bytesSent: 3)
        #expect(entry.host == "fd00::1" && entry.port == 443 && entry.scheme == "https" && entry.method == "POST")
        #expect(entry.destination == "[fd00::1]:443" && entry.path == "/v1/chat")
        let keys = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any]).keys
        #expect(Set(keys) == ["id", "time", "lastTime", "count", "purpose", "scheme", "host", "port", "method", "path", "bytesSent", "bytesReceived"])
    }

    // MARK: Buffer and export

    @Test func theBufferKeepsOnlyTheNewestEntries() async {
        let log = NetworkActivityLog(capacity: 5)
        let url = URL(string: "http://127.0.0.1:1/v1/models")!
        for _ in 0..<12 { _ = await log.begin(purpose: .other, url: url, method: "GET", bytesSent: 0) }
        let entries = await log.snapshot()
        #expect(entries.count == 5)
        #expect(entries.map(\.id) == [8, 9, 10, 11, 12])
    }

    @Test func theDefaultCapacityIsAThousand() async {
        let log = NetworkActivityLog()
        let url = URL(string: "http://127.0.0.1:1/v1/models")!
        for _ in 0..<1_050 { _ = await log.begin(purpose: .other, url: url, method: "GET", bytesSent: 0) }
        #expect(await log.snapshot().count == 1_000)
    }

    @Test func finishingAnEntryThatDroppedOutIsIgnored() async {
        let log = NetworkActivityLog(capacity: 1)
        let url = URL(string: "http://127.0.0.1:1/v1/models")!
        let old = await log.begin(purpose: .other, url: url, method: "GET", bytesSent: 0)
        _ = await log.begin(purpose: .other, url: url, method: "GET", bytesSent: 0)
        await log.finish(old, status: 200, error: nil, bytesReceived: 9, duration: 1)
        let entries = await log.snapshot()
        #expect(entries.count == 1 && entries[0].status == nil && entries[0].isInProgress)
    }

    @Test func clearEmptiesTheLog() async {
        let log = NetworkActivityLog()
        _ = await log.begin(purpose: .other, url: URL(string: "http://127.0.0.1:1/")!, method: "GET", bytesSent: 0)
        await log.clear()
        #expect(await log.snapshot().isEmpty)
    }

    @Test func observersAreToldAboutChanges() async {
        let log = NetworkActivityLog()
        var changes = await log.changes().makeAsyncIterator()
        _ = await log.begin(purpose: .other, url: URL(string: "http://127.0.0.1:1/")!, method: "GET", bytesSent: 0)
        #expect(await changes.next() != nil)
    }

    @Test func exportFormat() async throws {
        let log = NetworkActivityLog()
        let url = URL(string: "http://127.0.0.1:1234/v1/chat/completions")!
        let a = await log.begin(purpose: .minutes, url: url, method: "POST", bytesSent: 100)
        await log.finish(a, status: 200, error: nil, bytesReceived: 400, duration: 1.5)
        let b = await log.begin(purpose: .discovery, url: URL(string: "http://127.0.0.1:11434/api/version")!, method: "GET", bytesSent: 0)
        await log.finish(b, status: nil, error: .unreachable, bytesReceived: 0, duration: 0.1)
        let data = try await log.exportJSON(now: Date(timeIntervalSince1970: 1_000_000_000))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["format"] as? String == "vauta-network-activity")
        #expect(root["version"] as? Int == 1)
        #expect(root["exported"] as? String == "2001-09-09T01:46:40Z")
        #expect(root["note"] is String && root["scope"] is String)
        let entries = try #require(root["entries"] as? [[String: Any]])
        #expect(entries.count == 2)
        #expect(entries[0]["purpose"] as? String == "minutes" && entries[0]["status"] as? Int == 200)
        #expect(entries[0]["path"] as? String == "/v1/chat/completions" && entries[0]["bytesReceived"] as? Int == 400)
        #expect(entries[1]["error"] as? String == "unreachable" && entries[1]["status"] == nil)
        let destinations = try #require(root["destinations"] as? [[String: Any]])
        #expect(destinations.count == 2)
        #expect(destinations.allSatisfy { $0["scope"] as? String == "thisMac" })
    }

    // MARK: Summary

    @Test func destinationsAreGroupedAndClassified() {
        func entry(_ id: UInt64, _ url: String, status: Int? = 200) -> NetworkActivityEntry {
            var e = NetworkActivityEntry(id: id, timestamp: Date(), purpose: .other, url: URL(string: url)!, method: "GET", bytesSent: 10)
            e.status = status
            e.bytesReceived = 20
            e.duration = 0.1
            return e
        }
        let list = NetworkDestination.summarize([
            entry(1, "http://127.0.0.1:1234/v1/models"), entry(2, "http://127.0.0.1:1234/v1/models", status: 500),
            entry(3, "https://192.168.1.20:8443/v1/models"), entry(4, "https://studio.local/v1/models"),
            entry(5, "https://example.com/v1/models"),
        ])
        #expect(list.count == 4)
        let local = list[0]
        #expect(local.label == "127.0.0.1:1234" && local.requests == 2 && local.failures == 1)
        #expect(local.bytesSent == 20 && local.bytesReceived == 40 && local.scope == .thisMac)
        #expect(Dictionary(uniqueKeysWithValues: list.map { ($0.host, $0.scope) }) == [
            "127.0.0.1": .thisMac, "192.168.1.20": .localNetwork, "studio.local": .localNetwork, "example.com": .outside,
        ])
    }

    @Test func aDiscoveryProbeThatFindsNothingIsNotAFailure() {
        func probe(_ purpose: NetworkPurpose, _ error: NetworkErrorKind) -> NetworkActivityEntry {
            NetworkActivityEntry(id: 1, timestamp: Date(), purpose: purpose, url: URL(string: "http://127.0.0.1:11434/v1/models")!,
                                 method: "GET", bytesSent: 0, error: error, duration: 0.01, count: 38)
        }
        let miss = NetworkDestination.summarize([probe(.discovery, .unreachable)])
        #expect(miss[0].requests == 38 && miss[0].failures == 0)
        #expect(probe(.discovery, .unreachable).isExpectedProbeMiss)
        // The same error on a server the user set up is a real failure, and so is a probe that timed out.
        #expect(NetworkDestination.summarize([probe(.statusCheck, .unreachable)])[0].failures == 38)
        #expect(NetworkDestination.summarize([probe(.discovery, .timedOut)])[0].failures == 38)
    }

    private func stubConfiguration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubServer.self]
        return c
    }
}
