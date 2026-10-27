// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import FoundationModels
import Testing
@testable import VautaCore

@Suite("Models: providers")
struct ModelsProvidersTests {
    @Test func providersShareTheProtocols() {
        let client: any ChatModel = LLMClient(config: nil, bearer: { nil })
        let embeddings: any EmbeddingModel = LLMClient(config: nil, bearer: { nil })
        #expect(client is LLMClient && embeddings is LLMClient)
        let apple: any ChatModel = AppleChatModel()
        #expect(apple is AppleChatModel)
    }

    @Test func unconfiguredClientFailsClearly() async {
        let client = LLMClient(config: nil, bearer: { nil })
        await #expect(throws: LLMError.notConfigured) { try await client.chat([.user("x")], ChatOptions(model: .fast, maxTokens: 1)) }
        await #expect(throws: LLMError.notConfigured) { try await client.embed(["x"], purpose: .query) }
    }

    /// Reads availability only; never generates. Only invariants that hold on any machine and in any
    /// state (busy, downloading, not eligible) are asserted; the rest is skipped with a recorded message.
    @Test func appleModelReportsAvailability() {
        let model = AppleChatModel()
        let availability = model.availability
        guard availability == .available else {
            Issue.record("Apple on-device model not available here (\(availability)); skipping the checks that need it.",
                         severity: .warning)
            return
        }
        #expect(model.contextSize > 0)
        #expect(!model.supportedLanguages.isEmpty)
    }

    @Test func appleModelRendersMessages() {
        let (instructions, prompt) = AppleChatModel.render([
            .system("Rules"), .user("Transcript"), ChatMessage("assistant", "{bad"), .user("Repeat the JSON"),
        ])
        #expect(instructions == "Rules")
        #expect(prompt == "Transcript\n\nYour previous answer:\n{bad\n\nRepeat the JSON")
    }

    @Test func appleErrorsMapToLLMErrors() {
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "test")
        #expect(AppleChatModel.map(LanguageModelSession.GenerationError.exceededContextWindowSize(context)) as? LLMError
                == .contextLengthExceeded(message: nil))
        #expect(AppleChatModel.map(LanguageModelSession.GenerationError.unsupportedLanguageOrLocale(context)) as? LLMError == .unsupportedLanguage)
        #expect(AppleChatModel.map(LanguageModelSession.GenerationError.rateLimited(context)) as? LLMError == .busy(retryAfter: 10))
        #expect(AppleChatModel.map(CancellationError()) is CancellationError)
    }
}
