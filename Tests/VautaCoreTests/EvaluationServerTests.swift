// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// `llm-eval --providers server`: the minutes of a public transcript, and Ask's answers about it, on a model server, through the app's
/// own client (a stub server here: no socket is opened).
@Suite("Evaluation: the model server path")
struct EvaluationServerTests {
    typealias Reply = StubServer.Reply

    /// A server model whose client talks to the stub on `port`.
    private func serverModel(port: Int, contextTokens: Int = 32_768) -> EvaluationModel {
        var config = ModelsFixtures.config(.local, "http://127.0.0.1:\(port)/v1", embeddingModel: "")
        config.contextTokens = contextTokens
        let client = LLMClient(config: config, bearer: { nil }, protocolClasses: [StubServer.self])
        var model = EvaluationModel(name: "stub server", kind: "server") { (client, contextTokens, nil, nil) }
        model.server = (client, config)
        return model
    }

    private static func messages(_ received: StubServer.Received) -> [ChatMessage] {
        ((received.json?["messages"] as? [[String: Any]]) ?? []).map { ChatMessage($0["role"] as? String ?? "user", $0["content"] as? String ?? "") }
    }

    private static let transcript = MinutesEvaluation.Transcript(
        passages: (0..<6).map { MinutesEvaluation.Passage(id: Int64($0 + 1), text: "\(MinutesSmallWindowTests.sentence) item \($0)", start: Double($0 * 10), speaker: "Speaker \($0 % 2 + 1)") },
        meeting: "public", language: "en")

    @Test func withReleaseTheServerRunsWhatTheAppShipsForIt() {
        var o = LLMEvaluation.Options(sets: URL(fileURLWithPath: "/nonexistent"), out: URL(fileURLWithPath: "/nonexistent"))
        o.release = true
        let server = o.minutesChoices(provider: "server")
        #expect(server.extraction == .legacy && server.summary == .legacy && server.harness == .legacy && server.questions == .legacy)
        let apple = o.minutesChoices(provider: "apple")
        #expect(apple.extraction == MinutesRelease.extraction(integrated: false) && apple.questions == MinutesQuestionsRelease.questions(integrated: false))
        let integrated = o.minutesChoices(provider: "integrated")
        #expect(integrated.harness == MinutesHarnessRelease.harness(integrated: true))
        // Without `release`, every backend runs the choices given.
        o.release = false
        o.extraction = .legacy
        #expect(o.minutesChoices(provider: "server").extraction == .legacy && o.minutesChoices(provider: "apple").extraction == .legacy)
    }

    @Test func aServerModelIsAServerProviderAsInSettings() {
        let providers = EvaluationProviders(serverModel(port: 1, contextTokens: 16_384))
        #expect(providers.settings.chat == .server && providers.server != nil && providers.unavailable == nil)
        guard case .success(let chat) = providers.chat() else { Issue.record("no chat provider"); return }
        #expect(!chat.onDevice && !chat.integrated && chat.contextTokens == 16_384)
        #expect(!chat.releasedHarness, "a server keeps the minutes it had, as in the app")
    }

    @Test func aConfigurationTheAppWouldRefuseIsRefusedHereToo() async throws {
        // Local mode with an address that is not this Mac: the app's client refuses it, so the evaluation does.
        let config = ModelsFixtures.config(.local, "http://203.0.113.7:11434/v1", embeddingModel: "")
        let model = EvaluationModel.server(config, bearer: { nil })
        #expect(EvaluationProviders(model).unavailable != nil)
        await #expect(throws: MinutesEvaluation.Failure.self) { try await MinutesEvaluation.run(Self.transcript, model: model) }
    }

    @Test func theMinutesOfAPublicTranscriptRunOnTheServer() async throws {
        let port = StubServer.register { received in
            guard received.url.path.hasSuffix("/chat/completions") else { return nil }
            let minutes = ScriptedChat.minutesJSON(Self.messages(received))
            return .text(ModelsFixtures.sse([ModelsFixtures.delta(minutes, finish: "stop")]))
        }
        defer { StubServer.unregister(port) }
        let result = try await MinutesEvaluation.run(Self.transcript, model: serverModel(port: port), extraction: .legacy, summary: .legacy, harness: .legacy, questions: .legacy)
        #expect(result.items.contains { $0.kind == "decision" }, "the server's decision is checked against the passage and kept")
        #expect(result.modelCalls >= 1 && result.contextTokens == 32_768)
        let chats = StubServer.requests(port).filter { $0.url.path.hasSuffix("/chat/completions") }
        let body = try #require(chats.first?.json)
        #expect(body["model"] as? String == "deep-model", "the minutes go to the main model")
        #expect(Self.messages(chats[0]).map(\.content).joined().contains("item 0"), "the transcript is in the request")
    }

    @Test func eachVariantRunsTheChoicesItNames() {
        var o = LLMEvaluation.Options(sets: URL(fileURLWithPath: "/nonexistent"), out: URL(fileURLWithPath: "/nonexistent"))
        o.providers = ["server", "integrated"]
        #expect(o.minutesLabels == ["server", "integrated"], "without variants the labels are the providers")
        o.variants = ["old", "new", "release"]
        #expect(o.minutesLabels == ["server.old", "server.new", "server.release", "integrated.old", "integrated.new", "integrated.release"])
        let old = o.minutesRun("server.old")
        #expect(old.provider == "server" && old.choices.extraction == .legacy && old.choices.summary == .legacy && old.choices.questions == .legacy)
        let new = o.minutesRun("server.new")
        #expect(new.choices.extraction == .ranked && new.choices.summary == .shipped && new.choices.questions == .shipped && new.choices.harness == .shipped)
        #expect(o.minutesRun("server.release").choices.extraction == .legacy, "a server's release is the old request")
        let integrated = o.minutesRun("integrated.release")
        #expect(integrated.provider == "integrated" && integrated.choices.extraction == MinutesRelease.extraction(integrated: true)
            && integrated.choices.harness == MinutesHarnessRelease.harness(integrated: true))
        for word in ["old", "new", "release", "shipped", "legacy"] { #expect(LLMEvaluation.Options.isMinutesVariant(word), "\(word)") }
        for word in ["integrated", "outcomes", "old,new", "", "fast"] { #expect(!LLMEvaluation.Options.isMinutesVariant(word), "\(word)") }
    }

    @Test func bothVariantsRunInOneRunWithOneServerCheck() async throws {
        let port = StubServer.register { received in
            if received.url.path.hasSuffix("/models") { return .json(["object": "list", "data": [["id": "fast-model"], ["id": "deep-model"]]]) }
            guard received.url.path.hasSuffix("/chat/completions") else { return nil }
            return .text(ModelsFixtures.sse([ModelsFixtures.delta(ScriptedChat.minutesJSON(Self.messages(received)), finish: "stop")]))
        }
        defer { StubServer.unregister(port) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-eval-variants-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sets = root.appendingPathComponent("sets", isDirectory: true)
        try FileManager.default.createDirectory(at: sets, withIntermediateDirectories: true)
        let passages = Self.transcript.passages.map { ["id": $0.id, "text": $0.text, "start": $0.start ?? 0, "speaker": $0.speaker ?? ""] as [String: Any] }
        for name in ["m1", "m2"] {
            try JSONSerialization.data(withJSONObject: ["passages": passages, "meeting": name, "language": "en"]).write(to: sets.appendingPathComponent("\(name).json"))
        }
        var o = LLMEvaluation.Options(sets: sets, out: root.appendingPathComponent("out", isDirectory: true))
        o.tasks = ["minutes"]
        o.providers = ["server"]
        o.variants = ["old", "new"]
        o.server = serverModel(port: port)
        let log = LogLines()
        try await LLMEvaluation.run(o, store: LanguageModelStore(applicationSupport: root), log: { log.append($0) })
        let lines = try String(contentsOf: o.out.appendingPathComponent("traces.jsonl"), encoding: .utf8).split(separator: "\n")
        let traces = try lines.map { try JSONDecoder().decode(LLMEvaluation.Trace.self, from: Data($0.utf8)) }
        #expect(traces.map(\.provider) == ["server.old", "server.new", "server.new", "server.old"], "interleaved per meeting, the order alternated")
        #expect(traces.allSatisfy { $0.error == nil })
        #expect(traces.first { $0.provider == "server.old" }?.detail["extraction"] == MinutesExtraction.legacy.names)
        #expect(traces.first { $0.provider == "server.new" }?.detail["extraction"] == MinutesExtraction.ranked.names)
        for file in ["m1.server.old.json", "m1.server.new.json", "m2.server.old.json", "m2.server.new.json"] {
            #expect(FileManager.default.fileExists(atPath: o.out.appendingPathComponent("minutes/\(file)").path), "\(file)")
        }
        #expect(log.all.filter { $0.hasPrefix("model server: ") }.count == 1, "the server is checked once for the whole run")
    }

    /// A meeting whose minutes fail leaves its calls and replies in `<meeting>.<provider>.failed.json` (public transcripts), so the answer
    /// that could not be used can be read; no result file is written for it.
    @Test func aFailedMeetingLeavesItsReplies() async throws {
        let unreadable = "The minutes, as asked: the decisions first."
        let port = StubServer.register { received in
            if received.url.path.hasSuffix("/models") { return .json(["object": "list", "data": [["id": "fast-model"], ["id": "deep-model"]]]) }
            guard received.url.path.hasSuffix("/chat/completions") else { return nil }
            return .text(ModelsFixtures.sse([ModelsFixtures.delta(unreadable, finish: "stop")]))
        }
        defer { StubServer.unregister(port) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-eval-failed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sets = root.appendingPathComponent("sets", isDirectory: true)
        try FileManager.default.createDirectory(at: sets, withIntermediateDirectories: true)
        let passages = Self.transcript.passages.map { ["id": $0.id, "text": $0.text, "start": $0.start ?? 0, "speaker": $0.speaker ?? ""] as [String: Any] }
        try JSONSerialization.data(withJSONObject: ["passages": passages, "meeting": "m1", "language": "en"]).write(to: sets.appendingPathComponent("m1.json"))
        var o = LLMEvaluation.Options(sets: sets, out: root.appendingPathComponent("out", isDirectory: true))
        o.tasks = ["minutes"]
        o.providers = ["server"]
        o.server = serverModel(port: port)
        try await LLMEvaluation.run(o, store: LanguageModelStore(applicationSupport: root), log: { _ in })
        let trace = try JSONDecoder().decode(LLMEvaluation.Trace.self, from: Data(contentsOf: o.out.appendingPathComponent("traces.jsonl")))
        let minutes = o.out.appendingPathComponent("minutes", isDirectory: true)
        #expect(trace.error != nil && !FileManager.default.fileExists(atPath: minutes.appendingPathComponent("m1.server.json").path))
        let failed = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: minutes.appendingPathComponent("m1.server.failed.json"))) as? [String: Any])
        let replies = try #require(failed["replies"] as? [String])
        #expect(!replies.isEmpty && replies.allSatisfy { $0 == unreadable })
        #expect((failed["calls"] as? [Any])?.count == trace.calls.count && failed["error"] as? String == trace.error)
    }

    @Test func eachAskReasoningValueIsARunOfTheServer() {
        var o = LLMEvaluation.Options(sets: URL(fileURLWithPath: "/nonexistent"), out: URL(fileURLWithPath: "/nonexistent"))
        o.providers = ["server", "apple"]
        #expect(o.answerRuns.map(\.label) == ["server", "apple"] && o.answerRuns.allSatisfy { $0.reasoning == nil }, "without it, the release choice")
        o.askReasoning = [false]
        #expect(o.answerRuns.map(\.label) == ["server", "apple"] && o.answerRuns[0].reasoning == false && o.answerRuns[1].reasoning == nil)
        o.askReasoning = [true, false]
        #expect(o.answerRuns.map(\.label) == ["server.reasoning", "server.plain", "apple"])
        #expect(o.answerRuns.map(\.kind) == ["server", "server", "apple"] && o.answerRuns.map(\.reasoning) == [true, false, nil])
    }

    @Test func askAfterTheMeetingRunsWithAndWithoutReasoningInOneRun() async throws {
        let port = StubServer.register { received in
            if received.url.path.hasSuffix("/models") { return .json(["object": "list", "data": [["id": "fast-model"], ["id": "deep-model"]]]) }
            guard received.url.path.hasSuffix("/chat/completions") else { return nil }
            return .text(ModelsFixtures.sse([ModelsFixtures.delta(AskFoundTests.found(Self.messages(received)), finish: "stop")]))
        }
        defer { StubServer.unregister(port) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-eval-ask-reasoning-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sets = root.appendingPathComponent("sets", isDirectory: true)
        try FileManager.default.createDirectory(at: sets, withIntermediateDirectories: true)
        let passages = Self.transcript.passages.map { ["id": $0.id, "text": $0.text, "start": $0.start ?? 0, "speaker": $0.speaker ?? ""] as [String: Any] }
        try JSONSerialization.data(withJSONObject: ["passages": passages, "meeting": "m1", "language": "en"]).write(to: sets.appendingPathComponent("m1.json"))
        let questions = root.appendingPathComponent("questions.jsonl")
        try Data(#"{"qid": "q1", "meeting": "m1", "t_seg": 6, "question": "What happened with item 2?"}"#.utf8).write(to: questions)
        var o = LLMEvaluation.Options(sets: sets, out: root.appendingPathComponent("out", isDirectory: true))
        o.tasks = ["live-answer"]
        o.providers = ["server"]
        o.questions = questions
        o.afterMeeting = true
        o.askReasoning = [true, false]
        o.server = serverModel(port: port)
        try await LLMEvaluation.run(o, store: LanguageModelStore(applicationSupport: root), log: { _ in })
        let lines = try String(contentsOf: o.out.appendingPathComponent("traces.jsonl"), encoding: .utf8).split(separator: "\n")
        let traces = try lines.map { try JSONDecoder().decode(LLMEvaluation.Trace.self, from: Data($0.utf8)) }
        #expect(traces.map(\.provider) == ["server.reasoning", "server.plain"])
        #expect(traces.map { $0.detail["askReasoning"] } == ["on", "off"] && traces.allSatisfy { $0.error == nil })
        let chats = StubServer.requests(port).compactMap { $0.url.path.hasSuffix("/chat/completions") ? $0.json : nil }
        #expect(chats.filter { $0["enable_thinking"] as? Bool == true && $0["reasoning_effort"] as? String == "low" }.count == 1)
        #expect(chats.filter { $0["enable_thinking"] as? Bool == false }.count == 1)
    }

    @Test func theServerIsCheckedBeforeTheFirstRun() async throws {
        let listed = StubServer.register { received in
            received.url.path.hasSuffix("/models") ? .json(["object": "list", "data": [["id": "fast-model"], ["id": "deep-model"]]]) : nil
        }
        let partial = StubServer.register { received in
            received.url.path.hasSuffix("/models") ? .json(["object": "list", "data": [["id": "fast-model"]]]) : nil
        }
        defer { StubServer.unregister(listed); StubServer.unregister(partial) }
        let lines = LogLines()
        try await LLMEvaluation.checkServer(serverModel(port: listed)) { lines.append($0) }
        #expect(lines.all.contains { $0.hasPrefix("model server: ") })
        await #expect(throws: MinutesEvaluation.Failure.self) { try await LLMEvaluation.checkServer(serverModel(port: partial)) { _ in } }
        await #expect(throws: MinutesEvaluation.Failure.self) { try await LLMEvaluation.checkServer(nil) { _ in } }
    }
}

private final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
