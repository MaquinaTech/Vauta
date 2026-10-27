// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Apple's model answers within the same shape as the integrated one and a server. The schema is built without the model; the model
/// call itself needs Apple Intelligence and is not made here.
@Suite("Apple: guided answers and cut answers")
struct AppleGuidedAnswerTests {
    static let offered = OutputSchemas.Offered(segments: [3, 4, 5, 120], entities: nil, documents: [1, 2])

    @Test func theAnswerSchemaBuildsForEveryVariantAndNothingElseDoes() {
        for schema in [OutputSchemas.answer(Self.offered), OutputSchemas.answer(Self.offered, documents: true), OutputSchemas.answer(Self.offered, live: true),
                       OutputSchemas.answer(Self.offered, maxClaims: 3), OutputSchemas.answer(Self.offered, maxClaims: 6)] {
            #expect(AppleGuidedSchema.make(schema) != nil)
        }
        // A date or a nullable value is not part of an answer: those schemas stay with the prompt.
        #expect(AppleGuidedSchema.make(OutputSchemas.minutes(Self.offered)) == nil)
        #expect(AppleGuidedSchema.make(.object([.init("when", .date)])) == nil)
    }

    @Test func theShapeKeepsFoundFirstAndTheCitedClaimsUnderIt() {
        let names = AppleGuidedSchema.shape(OutputSchemas.answer(Self.offered))
        #expect(names.first == "found" && names.contains("answer") && names.contains("claims") && names.contains("citations") && names.contains("quote") && names.contains("text"))
        guard case .tagged(_, let cases) = OutputSchemas.answer(Self.offered, maxClaims: 3) else { Issue.record("not tagged"); return }
        guard case .array(_, let lo, let hi)? = cases[0].rest.first(where: { $0.name == "claims" })?.schema else { Issue.record("no claims"); return }
        #expect(lo == 1 && hi == 3, "at least one claim under found, at most three")
        guard case .array(_, let none, let zero)? = cases[1].rest.first(where: { $0.name == "claims" })?.schema else { Issue.record("no claims"); return }
        #expect(none == 0 && zero == 0, "none under not found")
    }

    @Test func appleIsNotGivenTheSchemaByDefault() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["We reviewed the Kobaltix budget for the quarter", "Fine, we keep the budget as it is"], locale: "en-US", outputLocale: "en-US")
        let chat = ScriptedChat { messages, _, _ in
            guard let (sid, text) = ScriptedChat.firstSegment(messages) else { return ScriptedChat.reply("{}") }
            return ScriptedChat.reply(#"{"found": true, "answer": "It stays.", "claims": [{"text": "Kept", "citations": [\#(sid)], "quote": "\#(text.prefix(30))"}]}"#)
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 4_096, onDevice: true))
        _ = try await service.ask("What about the Kobaltix budget?", meetingID: id)
        #expect(chat.calls.first?.options.outputSchema == nil, "guided generation for Ask is opt-in until its gate is run on Apple's model")
    }

    @Test func theServiceAsksAppleForTheSchemaAndSixClaimsAtMost() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["We reviewed the Kobaltix budget for the quarter", "Fine, we keep the budget as it is"], locale: "en-US", outputLocale: "en-US")
        let chat = ScriptedChat { messages, _, _ in
            guard let (sid, text) = ScriptedChat.firstSegment(messages) else { return ScriptedChat.reply("{}") }
            return ScriptedChat.reply(#"{"found": "true", "answer": "It stays.", "claims": [{"text": "Kept", "citations": [\#(sid)], "quote": "\#(text.prefix(30))"}]}"#)
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 4_096, onDevice: true))
        await service.setAppleGuidedAsk(true)   // opt-in (VAUTA_APPLE_GUIDED=1)
        let result = try await service.ask("What about the Kobaltix budget?", meetingID: id)
        guard case .tagged(_, let cases)? = chat.calls.first?.options.outputSchema, case .array(_, _, let hi)? = cases[0].rest.first(where: { $0.name == "claims" })?.schema else {
            Issue.record("Apple was not given the answer schema")
            return
        }
        #expect(hi == 6 && result.answer.hasEvidence, "a string \"true\" for found is read as true")
        #expect(chat.calls.first?.text.contains("Answer in at most 3 sentences and at most 3 claims.") == true, "the small window says it in words")
    }

    @Test func citationsAreAListOfTheSentNumbersAndAVeryLongListStaysWithThePrompt() {
        // Segment numbers are sparse: a range over 3...120 would offer 20, 21 and 25 that were never sent.
        #expect(AppleGuidedSchema.make(OutputSchemas.answer(.init(segments: [3, 4, 120]))) != nil)
        #expect(AppleGuidedSchema.make(OutputSchemas.answer(.init(segments: Set(1...(AppleGuidedSchema.maxListedIntegers + 1))))) == nil)
        #expect((try? VautaPrompts.verifyAnswer(#"{"found": "true", "answer": "A", "claims": [{"text": "x", "citations": ["4"], "quote": "Fine, we keep the budget"}]}"#,
                                                sent: [4: CitableSegment(id: 4, channel: .others, start: 1, text: "Fine, we keep the budget as it is")]))?.hasEvidence == true,
                "a number written as text is read as that number")
    }

    @Test func aFoundAnswerThatCitesUnsentNumbersIsAnchoredInTheVisibleLinesBeforeItIsRejected() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["We reviewed the Kobaltix budget for the quarter", "Fine, we keep the budget as it is"], locale: "en-US", outputLocale: "en-US")
        let chat = ScriptedChat { _, _, _ in
            ScriptedChat.reply(#"{"found": "true", "answer": "It stays.", "claims": [{"text": "Kept", "citations": [9999, 10000], "quote": "Fine, we keep the budget as it is"}]}"#)
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 4_096, onDevice: true))
        let result = try await service.ask("What about the budget?", meetingID: id)
        #expect(result.answer.hasEvidence && result.answer.kind == .verified)
        #expect(chat.calls.count == 1, "no second request was needed")
        let cited = result.answer.claims.flatMap(\.citations)
        #expect(cited.count == 1 && result.sent[cited[0]]?.text == "Fine, we keep the budget as it is")
    }
}
