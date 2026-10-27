// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The network audit: translation refinements, coalesced probes, blocked requests and the counts.
@Suite("Network activity: refinements, repeats and blocked requests")
struct NetworkActivityAuditTests {
    typealias F = ModelsFixtures
    private let probe = URL(string: "http://127.0.0.1:11434/api/version")!
    private let models = URL(string: "http://127.0.0.1:1234/v1/models")!

    private func probeOnce(_ log: NetworkActivityLog, _ url: URL, purpose: NetworkPurpose = .discovery,
                           status: Int? = nil, error: NetworkErrorKind? = .unreachable, bytes: Int = 0) async {
        let id = await log.begin(purpose: purpose, url: url, method: "GET", bytesSent: 0)
        await log.finish(id, status: status, error: error, bytesReceived: bytes, duration: 0.01)
    }

    // MARK: Translation refinements

    @Test func aRefinementRequestIsListedAsTranslationEndToEnd() async throws {
        let port = StubServer.register { _ in .text(F.sse([F.delta("Hola a todos.", finish: "stop"), F.usage])) }
        defer { StubServer.unregister(port) }
        let log = NetworkActivityLog()
        let server = ServerTranslator(chat: F.client(port: port, log: log), source: english, target: spanish)
        // Through the live translator, the way a recording uses it.
        let recorder = CaptionRecorder()
        let backend = StubBackend()
        let live = LiveTranslator(backend: backend, tuning: .refining, refiner: { _ in server }) { recorder.addFinal($0) }
        await live.configure(source: english, target: spanish)
        live.submit(spoken("Hello everyone.", final: true), key: 1)
        await eventually("the refined translation") { recorder.finals.contains { $0.isRefined } }
        await live.stop()
        let entries = await log.snapshot()
        let entry = try #require(entries.first)
        #expect(entries.count == 1 && entry.purpose == .translation)
        #expect(entry.method == "POST" && entry.path == "/v1/chat/completions" && entry.isSuccess)
        let exported = try await log.exportJSON()
        let dump = "\(entries)" + String(decoding: exported, as: UTF8.self)
        #expect(!dump.contains("Hello everyone") && !dump.contains("Hola a todos"), "no content in the audit")
    }

    // MARK: Repeated probes

    @Test func repeatedDiscoveryProbesAreOneRowWithACountAndTheLastTime() async throws {
        let log = NetworkActivityLog()
        for _ in 0..<40 { await probeOnce(log, probe) }
        let entries = await log.snapshot()
        let row = try #require(entries.first)
        #expect(entries.count == 1 && row.count == 40)
        #expect(row.lastTimestamp >= row.timestamp && !row.isInProgress && row.error == .unreachable)
        #expect(entries.requestCount == 40)
        let destination = try #require(NetworkDestination.summarize(entries).first)
        // Nothing answering a discovery probe is the normal case, not a failure.
        #expect(destination.requests == 40 && destination.failures == 0 && row.isExpectedProbeMiss)
    }

    @Test func pollingCannotFloodTheBuffer() async {
        let log = NetworkActivityLog()
        await probeOnce(log, URL(string: "http://127.0.0.1:1234/v1/models")!, purpose: .minutes, status: 200, error: nil)
        for round in 0..<3_000 {
            await probeOnce(log, probe)
            await probeOnce(log, models, status: round.isMultiple(of: 2) ? 200 : 404, error: nil, bytes: 10)
        }
        let entries = await log.snapshot()
        #expect(entries.count <= 4, "the guided setup's polling is a few rows")
        #expect(entries.contains { $0.purpose == .minutes }, "real requests are not pushed out")
        #expect(entries.requestCount == 6_001)
    }

    @Test func onlyIdenticalLoopbackDiscoveryProbesMerge() async {
        let log = NetworkActivityLog()
        await probeOnce(log, probe)
        await probeOnce(log, probe, status: 200, error: nil)                                       // another result
        await probeOnce(log, URL(string: "http://127.0.0.1:11434/api/tags")!)                      // another path
        await probeOnce(log, URL(string: "http://127.0.0.1:11435/api/version")!)                   // another destination
        await probeOnce(log, probe, purpose: .statusCheck)                                         // another purpose
        await probeOnce(log, probe, purpose: .statusCheck)                                         // only discovery merges
        await probeOnce(log, URL(string: "http://192.168.1.5:1234/v1/models")!)                    // not this Mac
        await probeOnce(log, URL(string: "http://192.168.1.5:1234/v1/models")!)
        #expect(await log.snapshot().count == 8)
        await probeOnce(log, probe)
        let entries = await log.snapshot()
        #expect(entries.count == 8, "the repeat of the first row merged into it")
        #expect(entries.last?.count == 2 && entries.last?.path == "/api/version" && entries.last?.error == .unreachable,
                "the merged row is the newest")
    }

    @Test func probesFarApartAreSeparateRows() async throws {
        let log = NetworkActivityLog(coalesceWindow: 0.01)
        await probeOnce(log, probe)
        try await Task.sleep(for: .milliseconds(60))
        await probeOnce(log, probe)
        #expect(await log.snapshot().count == 2)
    }

    @Test func theGuidedSetupPollingCoalescesThroughTheRealProbe() async throws {
        let port = StubServer.register { _ in nil }
        defer { StubServer.unregister(port) }
        let log = NetworkActivityLog()
        // A generous timeout: a probe that timed out on a loaded machine would be a different result, so a separate row.
        let session = ServerDiscovery.loopbackSession(timeout: 30, protocolClasses: [StubServer.self], log: log)
        let root = URL(string: "http://127.0.0.1:\(port)/")!
        for _ in 0..<5 {
            _ = await ServerDiscovery.identify(baseURL: root.appending(path: "v1/"), hints: [],
                                               fetch: ServerDiscovery.loopbackFetch(session: session, root: root, timeout: 30))
        }
        let entries = await log.snapshot()
        #expect(entries.count == 1, "five rounds of the same failing probe")
        #expect(entries.first?.count == 5 && entries.first?.purpose == .discovery)
    }

    // MARK: Blocked

    @Test func aProbeToAnotherMachineIsListedAsBlockedWithoutSendingAnything() async throws {
        let log = NetworkActivityLog()
        let session = ServerDiscovery.loopbackSession(timeout: 1, protocolClasses: [StubServer.self], log: log)
        let root = URL(string: "https://example.com:8443/")!
        let fetch = ServerDiscovery.loopbackFetch(session: session, root: root, timeout: 1)
        let answer = await fetch(.openAI("models"), Data("SECRET-PROMPT".utf8))
        #expect(answer == nil)
        let entries = await log.snapshot()
        let entry = try #require(entries.first)
        #expect(entries.count == 1 && entry.blocked == .destinationNotAllowed && entry.purpose == .discovery)
        #expect(entry.bytesSent == 0 && entry.status == nil && entry.error == nil && !entry.isInProgress && !entry.isSuccess)
        #expect(entry.host == "example.com" && entry.method == "POST" && entry.path == "/v1/models")
        let exported = try await log.exportJSON()
        let dump = "\(entries)" + String(decoding: exported, as: UTF8.self)
        #expect(dump.contains("\"blocked\" : \"destinationNotAllowed\"") && !dump.contains("SECRET-PROMPT"))
        // It never reached the destination: not a connection in the totals.
        #expect(NetworkDestination.summarize(entries).isEmpty)
    }

    @Test func aNativePathTheServerTypeDoesNotUseIsBlockedAndListed() async throws {
        let log = NetworkActivityLog()
        let client = F.client(port: 39_998, log: log)
        await #expect(throws: LLMError.self) { _ = try await client.native("api/unknown", purpose: .connectionTest) }
        let entry = try #require(await log.snapshot().first)
        #expect(entry.blocked == .pathNotAllowed && entry.purpose == .connectionTest && entry.path.hasSuffix("api/unknown"))
    }

    @Test func destinationRulesMapToBlockCategories() {
        #expect(LLMClient.blockReason(of: LLMError.untrustedPeerAddress("10.0.0.1")) == .untrustedAddress)
        #expect(LLMClient.blockReason(of: LLMError.network(LLMClient.destinationNotAllowed)) == .destinationNotAllowed)
        #expect(LLMClient.blockReason(of: LLMError.network("timed out")) == nil)
        #expect(LLMClient.blockReason(of: LLMError.notConfigured) == nil)
        #expect(NetworkBlockReason.allCases.count == 3)
    }

    // MARK: Counts

    @Test func theCountReadsNOfMWithAPurposeFilter() async {
        let log = NetworkActivityLog()
        for _ in 0..<7 { await probeOnce(log, probe) }
        await probeOnce(log, models, purpose: .minutes, status: 200, error: nil)
        await probeOnce(log, models, purpose: .ask, status: 200, error: nil)
        let all = await log.snapshot()
        #expect(all.requestCount == 9)
        #expect(all.filtered(by: nil).requestCount == 9)
        #expect(all.filtered(by: .discovery).requestCount == 7)
        #expect(all.filtered(by: .minutes).requestCount == 1)
        #expect(all.filtered(by: .translation).isEmpty)
    }

    @Test func theExportCarriesTheCountAndTheBlockedReason() async throws {
        let log = NetworkActivityLog()
        await probeOnce(log, probe)
        await probeOnce(log, probe)
        await log.recordBlocked(purpose: .ask, url: URL(string: "https://studio.local/v1/chat/completions?q=SECRET")!,
                                method: "POST", reason: .untrustedAddress)
        let data = try await log.exportJSON()
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(root["entries"] as? [[String: Any]])
        #expect(entries.count == 2)
        #expect(entries[0]["count"] as? Int == 2 && entries[0]["lastTime"] is String && entries[0]["blocked"] == nil)
        #expect(entries[1]["blocked"] as? String == "untrustedAddress" && entries[1]["count"] as? Int == 1)
        #expect(entries[1]["path"] as? String == "/v1/chat/completions")
        #expect(!String(decoding: data, as: UTF8.self).contains("SECRET"))
    }
}
