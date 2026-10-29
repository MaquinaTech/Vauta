// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Bounded reasoning in a model server's Ask (`AskReasoningRelease`): off by default, and when on, only outside a recording, never for an
/// automatic answer or on a small window, with its room on top of the answer's budget and no schema over it.
@Suite("Ask: bounded reasoning on a model server")
struct AskServerReasoningTests {
    private static let question = "What did we decide about the Kobaltix budget?"

    private func ask(contextTokens: Int = 32_768, onDevice: Bool = false, reasoning: Bool?, recording: Bool = false) async throws -> ScriptedChat.Call {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(AskFoundTests.lines, locale: "en-US", outputLocale: "en-US")
        let chat = ScriptedChat { messages, _, _ in ScriptedChat.reply(AskFoundTests.found(messages)) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: contextTokens, onDevice: onDevice))
        await service.setServerAskReasoning(reasoning)
        if recording { await service.setRecording(true, meetingID: id) }
        let result = try await service.ask(Self.question, meetingID: id)
        #expect(result.answer.found)
        return try #require(chat.calls.last)
    }

    @Test func theReleaseKeepsItOff() async throws {
        #expect(!AskReasoningRelease.serverAfterMeeting)
        let call = try await ask(reasoning: nil)
        #expect(!call.options.thinking && call.options.reasoningEffort == nil)
    }

    @Test func onAQuestionAfterTheMeetingTheMainModelReasonsBriefly() async throws {
        let plain = try await ask(reasoning: false)
        let call = try await ask(reasoning: true)
        #expect(call.options.thinking && call.options.reasoningEffort == "low" && call.options.model == .deep)
        #expect(call.options.maxTokens == plain.options.maxTokens + AskReasoningRelease.tokens, "the reasoning has its own room")
        #expect(call.options.responseFormat == nil && plain.options.responseFormat != nil, "no grammar over the reasoning, as in the minutes")
    }

    /// Reasoning that ran past the limit is asked once more without it, at the same limit and with the schema it went without (twice the
    /// limit would only give the reasoning room to run on, as in the minutes).
    @Test func aCutReasoningIsAskedAgainWithoutIt() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(AskFoundTests.lines, locale: "en-US", outputLocale: "en-US")
        let chat = ScriptedChat { messages, options, _ in
            options.thinking ? ScriptedChat.reply("", finish: .length) : ScriptedChat.reply(AskFoundTests.found(messages))
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat))
        await service.setServerAskReasoning(true)
        let result = try await service.ask(Self.question, meetingID: id)
        #expect(result.answer.found)
        let calls = Array(chat.calls.suffix(2))
        #expect(calls.count == 2 && calls[0].options.thinking)
        #expect(!calls[1].options.thinking && calls[1].options.reasoningEffort == nil && calls[1].options.responseFormat != nil)
        #expect(calls[1].options.maxTokens == calls[0].options.maxTokens)
    }

    @Test func neverWhileRecordingOrOnASmallWindowOrOnThisMac() async throws {
        #expect(try await !ask(reasoning: true, recording: true).options.thinking)
        #expect(try await !ask(contextTokens: 8_192, reasoning: true).options.thinking)
        #expect(try await !ask(contextTokens: 4_096, onDevice: true, reasoning: true).options.thinking)
    }
}
