// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Live Translation: server translator")
struct TranslationServerTests {
    private func translator(model: String? = nil, answer: @escaping @Sendable (String) -> String = { _ in "Hola a todos." })
        -> (ServerTranslator, ScriptedChat) {
        let chat = ScriptedChat { _, _, _ in ScriptedChat.reply(answer("")) }
        return (ServerTranslator(chat: chat, source: english, target: spanish, model: model), chat)
    }

    @Test func theRequestIsAStrictInstructionWithoutThinkingAndABoundedAnswer() async throws {
        let (server, chat) = translator(model: "qwen3.5-9b")
        let result = try await server.refine("Hello everyone.", context: [])
        #expect(result == "Hola a todos.")
        let call = try #require(chat.calls.first)
        #expect(call.options.thinking == false)
        #expect(call.options.temperature == ServerTranslator.temperature && ServerTranslator.temperature <= 0.3)
        #expect(call.options.modelOverride == "qwen3.5-9b" && call.options.model == .fast)
        #expect(call.options.maxTokens >= 96 && call.options.maxTokens <= 768)
        #expect(call.messages.first?.role == "system")
        let system = call.messages[0].content
        #expect(system.contains("English") && system.contains("Spanish"))
        #expect(system.contains("translation only"))
        #expect(call.messages.last?.content.hasSuffix("Hello everyone.") == true)
    }

    @Test func requestsAreListedAsTranslationAndTheSettingsTestAsAConnectionTest() async throws {
        let (server, chat) = translator()
        _ = try await server.refine("Hello everyone.", context: [])
        #expect(chat.calls.first?.options.purpose == .translation)
        let testChat = ScriptedChat { _, _, _ in ScriptedChat.reply("Hola a todos.") }
        let test = ServerTranslator(chat: testChat, source: english, target: spanish, purpose: .connectionTest)
        _ = try await test.refine("Hello everyone.", context: [])
        #expect(testChat.calls.first?.options.purpose == .connectionTest)
    }

    @Test func noModelMeansTheFastModelOfTheServer() async throws {
        for model in [nil, "", "  "] as [String?] {
            let (server, chat) = translator(model: model)
            _ = try await server.refine("Hello.", context: [])
            #expect(chat.calls.first?.options.modelOverride == nil)
        }
    }

    @Test func aLongSentenceGetsMoreRoomButNeverMoreThanTheCap() {
        #expect(ServerTranslator.maxTokens(for: "Hi") == 96)
        #expect(ServerTranslator.maxTokens(for: String(repeating: "word ", count: 2000)) == 768)
    }

    @Test func onlyTheLastThreePreviousSentencesAreSentAsContext() async throws {
        let (server, chat) = translator()
        let context = (1...5).map { TranslationExample(source: "source \($0)", translation: "traducción \($0)") }
        _ = try await server.refine("Now this.", context: context)
        let user = try #require(chat.calls.first?.messages.last?.content)
        #expect(!user.contains("source 1") && !user.contains("source 2"))
        for n in 3...5 { #expect(user.contains("source \(n)") && user.contains("traducción \(n)")) }
        #expect(user.range(of: "source 3")!.lowerBound < user.range(of: "source 5")!.lowerBound)
        #expect(user.hasSuffix("Now this."))
    }

    @Test func withoutContextThereIsNoContextBlock() async throws {
        let (server, chat) = translator()
        _ = try await server.refine("Now this.", context: [])
        #expect(chat.calls.first?.messages.last?.content.contains("Earlier in this conversation") == false)
    }

    @Test(arguments: [
        ("Here's the translation: Hola a todos.", "Hola a todos."),
        ("Here is the translation:\nHola a todos.", "Hola a todos."),
        ("Sure! Here's the translation into Spanish:\n\nHola a todos.", "Hola a todos."),
        ("Translation: Hola a todos.", "Hola a todos."),
        ("Spanish: Hola a todos.", "Hola a todos."),
        ("Español: Hola a todos.", "Hola a todos."),
        ("[es] Hola a todos.", "Hola a todos."),
        ("\"Hola a todos.\"", "Hola a todos."),
        ("“Hola a todos.”", "Hola a todos."),
        ("«Hola a todos.»", "Hola a todos."),
        ("**Hola a todos.**", "Hola a todos."),
        ("```\nHola a todos.\n```", "Hola a todos."),
        ("<think>Let me think about this.</think>\nHola a todos.", "Hola a todos."),
        ("<think>\nreasoning\n</think>\n\nHola a todos.\n", "Hola a todos."),
        ("  Hola a todos.  \n", "Hola a todos."),
        ("English: Hello everyone.\nSpanish: Hola a todos.", "Hola a todos."),
    ])
    func leakedWrappersAreStripped(raw: String, expected: String) async throws {
        let chat = ScriptedChat { _, _, _ in ScriptedChat.reply(raw) }
        let server = ServerTranslator(chat: chat, source: english, target: spanish)
        #expect(try await server.refine("Hello everyone.", context: []) == expected)
    }

    @Test func realTranslationsAreLeftAlone() async throws {
        let cases: [(source: String, answer: String)] = [
            ("He said “yes” and left.", "Dijo “sí” y se fue."),
            ("\"Fine,\" she said, \"later\".", "«Bien», dijo ella, «luego»."),
            ("It works.", "It — funciona."),                // a label-like start that is part of the sentence
            ("Translation memory is full.", "La memoria de traducción está llena."),
            ("What does Spanish mean here?", "¿Qué significa Spanish aquí?"),
        ]
        for (source, answer) in cases {
            let chat = ScriptedChat { _, _, _ in ScriptedChat.reply(answer) }
            let server = ServerTranslator(chat: chat, source: english, target: spanish)
            #expect(try await server.refine(source, context: []) == answer)
        }
    }

    @Test func aQuotedSourceKeepsItsQuotes() async throws {
        let chat = ScriptedChat { _, _, _ in ScriptedChat.reply("“Hola”") }
        let server = ServerTranslator(chat: chat, source: english, target: spanish)
        #expect(try await server.refine("“Hello”", context: []) == "“Hola”")
    }

    @Test func anEmptyAnswerIsRefused() async {
        let chat = ScriptedChat { _, _, _ in ScriptedChat.reply("<think>never closed") }
        let server = ServerTranslator(chat: chat, source: english, target: spanish)
        await #expect(throws: RefinementError.empty) { try await server.refine("Hello.", context: []) }
    }

    @Test func aLoopingAnswerIsRefusedByTheGuard() async {
        let chat = ScriptedChat { _, _, _ in ScriptedChat.reply("Hola ¡¡¡¡¡¡¡¡¡¡¡¡¡¡¡¡") }
        let server = ServerTranslator(chat: chat, source: english, target: spanish)
        await #expect(throws: RefinementError.degenerate) { try await server.refine("Hello.", context: []) }
    }

    @Test func aFailingServerPropagatesTheError() async {
        let chat = ScriptedChat { _, _, _ in throw LLMError.network("503") }
        let server = ServerTranslator(chat: chat, source: english, target: spanish)
        await #expect(throws: LLMError.self) { try await server.refine("Hello.", context: []) }
    }

    @Test func theTestSamplePicksTheOwnersPairs() {
        let toSpanish = RefinementTest.Sample.make(source: english, target: spanish)
        #expect(toSpanish.source == english && toSpanish.target == spanish && toSpanish.text.hasPrefix("Can everyone"))
        let toEnglish = RefinementTest.Sample.make(source: spanish, target: english)
        #expect(toEnglish.source == spanish && toEnglish.target == english && toEnglish.text.hasPrefix("¿Podéis"))
        // Same language as the target: the other of the two is used.
        let same = RefinementTest.Sample.make(source: english, target: english)
        #expect(!same.target.isSameLanguage(as: same.source))
        let unknown = RefinementTest.Sample.make(source: nil, target: nil)
        #expect(unknown.source == english && unknown.target == spanish)
    }

    @Test func theTestReportsTheRealLatencyAndFailures() async {
        let ok = StubRefiner()
        ok.delay = .milliseconds(120)
        let sample = RefinementTest.Sample.make(source: english, target: spanish)
        // A generous timeout: a loaded runner can stall a 120 ms reply for far longer than the default 20 s.
        let good = await RefinementTest.run(sample, with: ok, timeout: .seconds(600))
        #expect(good.outcome == .translated("R(\(sample.text))") && good.seconds >= 0.1)

        let slow = StubRefiner()
        slow.delay = .untilCancelled
        let timedOut = await RefinementTest.run(sample, with: slow, timeout: .milliseconds(80))
        #expect(timedOut.outcome == .timedOut && !timedOut.withinBudget)

        let bad = StubRefiner()
        bad.failing = [sample.text]
        let failed = await RefinementTest.run(sample, with: bad)
        if case .failed = failed.outcome {} else { Issue.record("expected a failure") }
        #expect(RefinementTest(sample: sample, outcome: .translated("x"), seconds: 5).withinBudget == false)
    }
}

@Suite("Live Translation: priority over live notes")
struct TranslationPriorityTests {
    private static let lines = ["We reviewed the Kobaltix budget", "Fine, we keep it", "Ana will send the numbers"]

    @Test func noServerMeansNoTranslator() async throws {
        let f = try KnowledgeFixture()
        let service = LLMService(store: f.store, providers: TestProviders(chat: ScriptedChat { _, _, _ in ScriptedChat.reply("x") }))
        #expect(await service.refinementTranslator(source: english, target: spanish, model: nil) == nil)
        #expect(await service.status.serverConfigured == false)
    }

    @Test func liveNotesWaitWhileATranslationIsInFlight() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(Self.lines, locale: "en-US")
        let notes = ScriptedChat { messages, _, _ in
            guard let (seg, _) = ScriptedChat.firstSegment(messages) else { return ScriptedChat.reply("{}") }
            return ScriptedChat.reply(#"{"points": [{"text": "Budget stays", "seg": \#(seg)}], "decisions": [], "tasks": []}"#)
        }
        let gate = Gate()
        let server = ScriptedChat { _, _, _ in
            await gate.wait()
            return ScriptedChat.reply("Hola a todos.")
        }
        let providers = TestProviders(chat: notes)
        providers.refinementChat = server
        let service = LLMService(store: f.store, providers: providers)
        await service.setRecording(true, meetingID: id)
        let translator = try #require(await service.refinementTranslator(source: english, target: spanish, model: nil))

        let translation = Task { try await translator.refine("Hello everyone.", context: []) }
        #expect(await eventually { server.calls.count == 1 })
        let live = Task { try await service.liveNotes(meetingID: id, at: 10) }
        try await Task.sleep(for: .milliseconds(250))
        #expect(notes.calls.isEmpty, "live notes wait for the translation")
        await gate.release()
        #expect(try await translation.value == "Hola a todos.")
        _ = try await live.value
        #expect(notes.calls.count == 1)
        #expect(await service.activeRefinements == 0)
    }

    @Test func aFailedOrCancelledTranslationReleasesLiveNotes() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(Self.lines, locale: "en-US")
        let notes = ScriptedChat { messages, _, _ in
            guard let (seg, _) = ScriptedChat.firstSegment(messages) else { return ScriptedChat.reply("{}") }
            return ScriptedChat.reply(#"{"points": [{"text": "Budget stays", "seg": \#(seg)}], "decisions": [], "tasks": []}"#)
        }
        let failing = ScriptedChat { _, _, _ in throw LLMError.network("503") }
        let providers = TestProviders(chat: notes)
        providers.refinementChat = failing
        let service = LLMService(store: f.store, providers: providers)
        await service.setRecording(true, meetingID: id)
        let translator = try #require(await service.refinementTranslator(source: english, target: spanish, model: nil))
        _ = try? await translator.refine("Hello.", context: [])
        #expect(await service.activeRefinements == 0)

        let slow = ScriptedChat { _, _, _ in try await Task.sleep(for: .seconds(30)); return ScriptedChat.reply("x") }
        providers.refinementChat = slow
        let slowTranslator = try #require(await service.refinementTranslator(source: english, target: spanish, model: nil))
        let task = Task { try await slowTranslator.refine("Hello.", context: []) }
        #expect(await eventually { await service.activeRefinements == 1 })
        task.cancel()
        _ = try? await task.value
        #expect(await eventually { await service.activeRefinements == 0 })
        #expect(try await service.liveNotes(meetingID: id, at: 10) != nil)
    }

    @Test func requestsUseTheClientsRulesNotANewSession() async throws {
        // The translator is built on the provider's chat model (the audited LLMClient in the app).
        let f = try KnowledgeFixture()
        let server = ScriptedChat { _, _, _ in ScriptedChat.reply("Hola.") }
        let providers = TestProviders(chat: ScriptedChat { _, _, _ in ScriptedChat.reply("x") })
        providers.refinementChat = server
        let service = LLMService(store: f.store, providers: providers)
        let translator = try #require(await service.refinementTranslator(source: english, target: spanish, model: "m"))
        _ = try await translator.refine("Hello.", context: [])
        #expect(server.calls.count == 1 && server.calls[0].options.modelOverride == "m")
    }
}
