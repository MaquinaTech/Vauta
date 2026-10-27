// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Live answers: no network of their own, and the replay")
struct QuestionNetworkAndReplayTests {
    // MARK: Network

    @Test func theW10FilesNeverReachTheNetworkThemselves() throws {
        let root = NetworkAuditSourceScanTests.packageRoot()
        var files = try FileManager.default.contentsOfDirectory(at: root.appending(path: "Sources/VautaCore/Questions"), includingPropertiesForKeys: nil)
        files += ["LLM/LLMService+AutoAsk.swift", "LLM/LLMService+Questions.swift", "Diagnostics/QuestionReplay.swift"].map { root.appending(path: "Sources/VautaCore/\($0)") }
        #expect(files.count >= 10)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(NetworkAuditSourceScanTests.violations(in: text).isEmpty, "\(file.lastPathComponent)")
        }
    }

    @Test func withAServerOnlyTheConfiguredHostIsContactedAndTheActivityNamesLiveAnswers() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(AutoAnswerTests.withQuestion, locale: "en-US", outputLocale: "en-US")
        let segments = try await f.store.citableSegments(id)
        let port = StubServer.register { request in
            let content = request.json.flatMap { ($0["messages"] as? [[String: Any]])?.last?["content"] as? String } ?? ""
            let reply = content.contains("ask for a fact")
                ? #"{"kind": "information", "question": "Did we keep the budget?", "answered_aloud": false}"#
                : AutoAnswerTests.reply([("Budget kept", segments[1].id, "we keep the budget as it is")])
            return .json(["choices": [["index": 0, "message": ["role": "assistant", "content": reply], "finish_reason": "stop"]],
                          "usage": ["prompt_tokens": 100, "completion_tokens": 10]])
        }
        defer { StubServer.unregister(port) }
        let log = NetworkActivityLog()
        let client = ModelsFixtures.client(port: port, log: log)
        let service = LLMService(store: f.store, providers: TestProviders(chat: client, contextTokens: 65_536))
        await service.setLiveCheckSeconds(200)
        await service.setRecording(true, meetingID: id)
        let check = await service.checkQuestion(QuestionCheckTests.settled("Did we keep the budget?"), meetingID: id)
        guard case .checked(let c) = check else { Issue.record("not checked: \(check)"); return }
        #expect(c.kind == .information)
        let outcome = try await service.autoAnswer(c.question, meetingID: id, request: AutoAskRequest(segmentID: segments[2].id, sources: .all))
        guard case .answered = outcome else { Issue.record("not answered: \(outcome)"); return }
        let received = StubServer.requests(port)
        #expect(received.count == 2 && received.allSatisfy { $0.url.host == "127.0.0.1" && $0.url.port == port && $0.method == "POST" && $0.url.path.hasSuffix("/chat/completions") })
        let entries = await log.snapshot().filter { $0.port == port }
        #expect(entries.requestCount == 2 && entries.allSatisfy { $0.purpose == NetworkPurpose.liveAnswers })
    }

    @Test func withAppleOrTheIntegratedModelNothingIsSentAnywhere() async throws {
        let port = StubServer.register { _ in .json(["error": "must not be called"], status: 500) }
        defer { StubServer.unregister(port) }
        for integrated in [false, true] {
            let r = try await AutoAnswerTests.rig(integrated: integrated) { _, options, _ in
                options.purpose == .liveAnswers && options.maxTokens == 96
                    ? ScriptedChat.reply(#"{"kind": "information", "question": "Did we keep the budget?", "answered_aloud": false}"#)
                    : ScriptedChat.reply(#"{"found": false, "answer": "", "claims": []}"#)
            }
            _ = await r.service.checkQuestion(QuestionCheckTests.settled(), meetingID: r.meeting)
            _ = try await r.service.autoAnswer("Did we keep the budget?", meetingID: r.meeting, request: AutoAskRequest(segmentID: r.segments[1].id, sources: .all))
        }
        #expect(StubServer.requests(port).isEmpty)
    }

    /// Counts the texts it is asked to embed.
    final class CountingEmbedder: EmbeddingModel, @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> EmbeddingBatch {
            if purpose == .query { lock.withLock { _count += texts.count } }
            return try await FakeEmbedder(space: EmbeddingSpace(model: "test-server-embedder", dimensions: 8)).embed(texts, purpose: purpose)
        }
    }

    @Test func aQuestionHeardIsNeverEmbeddedByAServerOnTheAnswerPath() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let filler = (0..<90).map { "Item \($0) of the long agenda covers procurement, staffing and the quarterly plan in some detail for everyone present" }
        let id = try await f.meeting(filler + ["Fine, we keep the budget as it is", "Did we keep it?"], locale: "en-US", outputLocale: "en-US")
        let embedder = CountingEmbedder()
        let chat = ScriptedChat { _, _, _ in ScriptedChat.reply(#"{"found": false, "answer": "", "claims": []}"#) }
        let providers = TestProviders(chat: chat, contextTokens: 4_096, embedder: embedder)
        providers.embeddingChoice = .server
        let service = LLMService(store: f.store, providers: providers)
        await service.setRecording(true, meetingID: id)
        let segments = try await f.store.citableSegments(id)
        _ = try await service.autoAnswer("Did we keep the budget?", meetingID: id, request: AutoAskRequest(segmentID: segments.last!.id, sources: .all))
        #expect(!AutoAnswerTests.autoCalls(chat).isEmpty, "the passages path ran")
        #expect(embedder.count == 0, "the heard question's text is not sent to an embeddings server")
    }

    // MARK: Replay

    static func lines() -> [QuestionReplay.Line] {
        [QuestionReplay.Line(id: 1, start: 0, end: 4, text: "We reviewed the Kobaltix budget for the quarter."),
         QuestionReplay.Line(id: 2, start: 5, end: 9, text: "Fine, we keep the budget as it is."),
         QuestionReplay.Line(id: 3, start: 10, end: 14, text: "Did we keep the budget as it is?"),
         QuestionReplay.Line(id: 4, start: 15, end: 19, text: "Yes we did."),
         QuestionReplay.Line(id: 5, start: 60, end: 64, text: "Ana will send the numbers on Friday")]
    }

    @Test func theReplayRunsTheWholePipelineOnASimulatedClock() async throws {
        let backend = FakeAnswerBackend()
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let meeting = try await f.store.startMeeting(at: .now, locale: Locale(identifier: "en-US"), outputLocale: Locale(identifier: "en-US"))
        var options = QuestionReplay.Options()
        options.settings.hideWhenAnsweredAloud = false
        let records = try await QuestionReplay.run(lines: Self.lines(), meetingID: meeting, options: options, backend: backend,
                                                   appendLine: { l in try await f.store.append(Segment(channel: l.channel, start: l.start, end: l.end, text: l.stored, isFinal: true), to: meeting) })
        #expect(records.count == 1)
        let r = try #require(records.first)
        #expect(r.outcome == "answered" && r.shown && r.text == "Did we keep the budget as it is?" && r.checkKind == "information")
        #expect(r.latencySeconds != nil && r.latencySeconds! >= 4, "the question ended at 14 s and settles on the next line at 19 s of simulated time")
        #expect(backend.answers.first?.1.segmentID != nil)
    }

    @Test func theReplayWithoutTheCheckGoesStraightToTheAnswerWithTheOriginalWords() async throws {
        let backend = FakeAnswerBackend()
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let meeting = try await f.store.startMeeting(at: .now, locale: Locale(identifier: "en-US"), outputLocale: Locale(identifier: "en-US"))
        var options = QuestionReplay.Options()
        options.skipCheck = true
        let records = try await QuestionReplay.run(lines: Self.lines(), meetingID: meeting, options: options, backend: backend,
                                                   appendLine: { l in try await f.store.append(Segment(channel: l.channel, start: l.start, end: l.end, text: l.stored, isFinal: true), to: meeting) })
        #expect(records.first?.outcome == "answered" && records.first?.checkKind == nil)
        #expect(backend.checkTimes.isEmpty && backend.answers.first?.0 == "Did we keep the budget as it is?")
    }

    @Test func theReplayWithTheEvidenceGateOnlyCallsNoModel() async throws {
        let backend = FakeAnswerBackend()
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let meeting = try await f.store.startMeeting(at: .now, locale: Locale(identifier: "en-US"), outputLocale: Locale(identifier: "en-US"))
        var options = QuestionReplay.Options()
        options.detectOnly = true
        let records = try await QuestionReplay.run(lines: Self.lines(), meetingID: meeting, options: options, backend: backend,
                                                   appendLine: { l in try await f.store.append(Segment(channel: l.channel, start: l.start, end: l.end, text: l.stored, isFinal: true), to: meeting) })
        #expect(records.map(\.outcome) == ["evidence"] && backend.checkTimes.isEmpty && backend.answers.isEmpty)
    }

    @Test func theReplayWithDetectionOffStoresAndReadsTheLinesButDetectsNothingAndRunsTheClosingProbe() async throws {
        let backend = FakeAnswerBackend()
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let meeting = try await f.store.startMeeting(at: .now, locale: Locale(identifier: "en-US"), outputLocale: Locale(identifier: "en-US"))
        let reads = Locked(0)
        let probes = Locked(0)
        var options = QuestionReplay.Options()
        options.detection = false
        options.warmRead = { reads.withLock { $0 += 1 } }
        options.closingProbe = { probes.withLock { $0 += 1 } }
        let records = try await QuestionReplay.run(lines: Self.lines(), meetingID: meeting, options: options, backend: backend,
                                                   appendLine: { l in try await f.store.append(Segment(channel: l.channel, start: l.start, end: l.end, text: l.stored, isFinal: true), to: meeting) })
        #expect(records.isEmpty && backend.evidenceCalls == 0 && backend.checkTimes.isEmpty && backend.answers.isEmpty)
        #expect(try await f.store.citableSegments(meeting).count == 5, "the lines are stored")
        #expect(probes.withLock { $0 } == 1)
        #expect(reads.withLock { $0 } == 0, "under 600 characters nothing is read yet")
    }

    @Test func theReplayNeverReadsALineBeforeItExists() async throws {
        let backend = FakeAnswerBackend()
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let meeting = try await f.store.startMeeting(at: .now, locale: Locale(identifier: "en-US"), outputLocale: Locale(identifier: "en-US"))
        _ = try await QuestionReplay.run(lines: Self.lines(), meetingID: meeting, options: QuestionReplay.Options(), backend: backend,
                                         appendLine: { l in try await f.store.append(Segment(channel: l.channel, start: l.start, end: l.end, text: l.stored, isFinal: true), to: meeting) })
        // The question ended at 14 s and settles at 18 s, before "Yes we did." (15 to 19 s) is over: the check cannot have read it.
        #expect(try #require(backend.checked.first).after.isEmpty)
    }

    @Test func seriesNamesGroupTheMeetingsOfAnAmiSeriesAndTheCouncilSessions() {
        #expect(LLMEvaluation.series(of: "ES2004c")?.key == "ES2004" && LLMEvaluation.series(of: "ES2004c")?.part == "c")
        #expect(LLMEvaluation.series(of: "cdm191218_b")?.key == "cdm191218" && LLMEvaluation.series(of: "cdm191218_b")?.part == "b")
        #expect(LLMEvaluation.series(of: "IB4002") == nil)
    }
}
