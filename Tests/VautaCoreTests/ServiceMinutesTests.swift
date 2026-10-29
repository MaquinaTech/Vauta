// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Service: minutes (language, finish reason, map-reduce, live notes)")
struct ServiceMinutesTests {
    private func run(_ f: KnowledgeFixture, _ id: Int64, chat: ScriptedChat, context: Int = 32_768) async throws {
        let events = EventLog()
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: context))
        await service.setJobEventHandler { events.append($0) }
        await service.regenerateMinutes(id)
        #expect(await eventually { events.events.contains { $0.meetingID == id && $0.kind == .minutes } })
        #expect(events.events.last?.outcome == .succeeded)
        await service.waitUntilQueueIdle()
    }

    @Test func minutesAreWrittenInTheMeetingsOutputLanguage() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["予算を確認しました", "はい、そのままにします"], locale: "ja-JP")
        let english = try await f.meeting(["We checked the budget", "Fine"], locale: "ja-JP", outputLocale: "en-US")
        let chat = ScriptedChat { messages, _, _ in ScriptedChat.reply(ScriptedChat.minutesJSON(messages)) }
        try await run(f, id, chat: chat)
        #expect(chat.calls.last?.text.contains("Write everything in Japanese (ja-JP).") == true)
        try await run(f, english, chat: chat)
        #expect(chat.calls.last?.text.contains("Write everything in English (en-US).") == true)
        // A meeting from 0.1 (no language stored) keeps Spanish.
        let legacy = try await f.meeting(["Revisamos el presupuesto", "Vale"])
        try await run(f, legacy, chat: chat)
        #expect(chat.calls.last?.text.contains("Write everything in Spanish (es-ES).") == true)
    }

    @Test func aTruncatedAnswerIsAskedAgainWithMoreRoom() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["We reviewed the Kobaltix budget for the quarter", "Fine, we keep it"])
        let chat = ScriptedChat { messages, _, call in
            call == 1 ? ScriptedChat.reply(#"{"title": "Kob"#, finish: .length) : ScriptedChat.reply(ScriptedChat.minutesJSON(messages))
        }
        let events = EventLog()
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, onDevice: true))
        await service.setJobEventHandler { events.append($0) }
        await service.regenerateMinutes(id)
        #expect(await eventually { events.events.contains { $0.meetingID == id && $0.kind == .minutes } })
        #expect(events.events.last?.outcome == .succeeded)
        await service.waitUntilQueueIdle()
        #expect(chat.calls.count == 2)
        #expect(chat.calls[1].options.maxTokens > chat.calls[0].options.maxTokens)
        #expect(try await f.store.cardSource(id) == "llm")
    }

    /// A model server whose reasoning ran past the limit is asked once without reasoning, at the same limit: twice the limit would only
    /// give the reasoning room to run on (a 9B model on a server reasoned 10,000 tokens, and then 20,000 more, before the blocks).
    @Test func aServersCutReasoningIsAskedAgainWithoutReasoning() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["We reviewed the Kobaltix budget for the quarter", "Fine, we keep it"])
        let chat = ScriptedChat { messages, options, _ in
            options.thinking ? ScriptedChat.reply("", finish: .length) : ScriptedChat.reply(ScriptedChat.minutesJSON(messages))
        }
        try await run(f, id, chat: chat)
        #expect(chat.calls.count == 2)
        #expect(chat.calls[0].options.thinking && chat.calls[0].options.reasoningEffort != nil)
        #expect(!chat.calls[1].options.thinking && chat.calls[1].options.reasoningEffort == nil)
        #expect(chat.calls[1].options.maxTokens == chat.calls[0].options.maxTokens)
        #expect(chat.calls[1].messages.map(\.content) == chat.calls[0].messages.map(\.content))
        #expect(try await f.store.cardSource(id) == "llm")
    }

    @Test func aMeetingThatDoesNotFitIsSummarizedByBlocks() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["We reviewed the Kobaltix budget for the quarter", "Fine, we keep it", "Ana sends the numbers"])
        let chat = ScriptedChat { messages, _, call in
            if call == 1 { throw LLMError.contextLengthExceeded(message: "n_ctx") }
            let text = messages.map(\.content).joined()
            if text.contains("<<<BLOCK") {
                return ScriptedChat.reply(ScriptedChat.minutesJSON(messages).replacingOccurrences(of: #""title": "Budget review", "#, with: ""))
            }
            // Final reduce: the extracts carry the segment citations.
            #expect(text.contains("<<<EXTRACTS"))
            return ScriptedChat.reply(ScriptedChat.minutesJSON(messages))
        }
        try await run(f, id, chat: chat)
        #expect(chat.calls.contains { $0.text.contains("<<<BLOCK") })
        #expect(chat.calls.last?.text.contains("Combine them into a single set of minutes") == true)
    }

    @Test func aSmallWindowSplitsLongMeetingsIntoSmallBlocks() async throws {
        let f = try KnowledgeFixture()
        let sentence = "We went through the quarterly budget of the Kobaltix project line by line and agreed on next steps"
        let id = try await f.meeting((0..<200).map { "\(sentence) (\($0))" })
        let chat = ScriptedChat { messages, options, _ in
            // Every request fits the 4K window with its answer.
            #expect(PromptText.tokens(messages) + options.maxTokens <= 4_096)
            let json = ScriptedChat.minutesJSON(messages)
            return ScriptedChat.reply(messages.last?.content.contains("ONLY one block") == true || messages.last?.content.contains("ONE compact extract") == true
                                      ? #"{"summary": "Budget.", "decisions": []}"# : json)
        }
        try await run(f, id, chat: chat, context: 4_096)
        let blocks = chat.calls.filter { $0.text.contains("<<<BLOCK") }.count
        #expect(blocks >= 3)
    }

    @Test func liveNotesFeedTheMinutesAsHints() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["We reviewed the Kobaltix budget for the quarter", "Fine, we keep it"])
        try await f.store.addLiveNotes(id, at: 30, json: #"{"puntos":[{"texto":"Budget stays","seg":null}],"tareas":[{"texto":"Send numbers","responsable":"Ana","seg":null}]}"#)
        let chat = ScriptedChat { messages, _, _ in ScriptedChat.reply(ScriptedChat.minutesJSON(messages)) }
        try await run(f, id, chat: chat)
        let text = try #require(chat.calls.last?.text)
        #expect(text.contains("- Budget stays") && text.contains("- Task: Send numbers (owner: Ana)"))
    }

    @Test func regeneratingWithATemplateStoresIt() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["We reviewed the Kobaltix budget for the quarter", "Fine, we keep it"])
        #expect(try await f.store.minutesTemplate(id) == nil)   // older meetings: general
        let chat = ScriptedChat { messages, _, _ in ScriptedChat.reply(ScriptedChat.minutesJSON(messages)) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat))
        let events = EventLog()
        await service.setJobEventHandler { events.append($0) }
        await service.regenerateMinutes(id, template: .clientCall)
        #expect(await eventually { !events.events.isEmpty })
        #expect(try await f.store.minutesTemplate(id) == .clientCall)
        #expect(chat.calls.last?.text.contains(MinutesTemplate.clientCall.promptInstructions) == true)
    }

    @Test func theTemplateSurvivesAReopen() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["We reviewed the budget"])
        try await f.store.setMinutesTemplate(.interview, for: id)
        try await f.reopen()
        #expect(try await f.store.minutesTemplate(id) == .interview)
        try await f.store.setMinutesTemplate(nil, for: id)
        #expect(try await f.store.minutesTemplate(id) == nil)
        // A value from a newer version reads as "not chosen" (general).
        try await f.store.executeForTest("UPDATE meetings SET template = 'future' WHERE id = ?", [.integer(id)])
        #expect(try await f.store.minutesTemplate(id) == nil)
    }
}
