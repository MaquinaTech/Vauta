// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Ask through the service: an answer cut at the length limit keeps the claims it finished, and a wrong citation is moved.
@Suite("Service: Ask, cut answers and moved citations")
struct AskCutClaimsTests {
    static let lines = ["We reviewed the Kobaltix budget for the quarter", "Fine, we keep the budget as it is",
                        "Ana will send the numbers on Friday"]

    @Test func aCutAnswerKeepsItsCompleteClaims() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        let segments = try await f.store.citableSegments(id)
        let keep = segments[1].id
        let cut = #"{"found": true, "answer": "The budget stays and Ana sends numbers.", "claims": [{"text": "Budget kept", "citations": [\#(keep)], "quote": "we keep the budget as it is"}, {"text": "Ana sends the nu"#
        let chat = ScriptedChat { _, _, _ in ScriptedChat.reply(cut, finish: .length) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat))
        let result = try await service.ask("What happens to the budget?", meetingID: id)
        #expect(result.answer.found && result.answer.hasEvidence && result.answer.claims.count == 1)
        #expect(chat.calls.count == 1, "no second request: a verified claim was already there")
    }

    @Test func aCutAnswerWithNothingCompleteStillFails() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        let chat = ScriptedChat { _, _, _ in ScriptedChat.reply(#"{"found": true, "answer": "The bud"#, finish: .length) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat))
        await #expect(throws: LLMError.self) { _ = try await service.ask("What happens to the budget?", meetingID: id) }
    }

    @Test func aWrongSegmentNumberIsMovedToTheSegmentThatHoldsTheQuote() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        let segments = try await f.store.citableSegments(id)
        let wrong = segments[0].id, right = segments[1].id
        let reply = #"{"found": true, "answer": "The budget stays.", "claims": [{"text": "Budget kept", "citations": [\#(wrong)], "quote": "we keep the budget as it is"}]}"#
        let chat = ScriptedChat { _, _, _ in ScriptedChat.reply(reply) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat))
        let result = try await service.ask("What happens to the budget?", meetingID: id)
        #expect(result.answer.hasEvidence && result.answer.claims[0].citations == [right] && result.answer.claims[0].reanchoredFrom == wrong)
        #expect(result.sent[right] != nil, "the moved citation can be labelled and opened")
    }

    @Test func aLibraryQuestionMovesTheCitationToAnotherSegmentOfTheMeetingAndTheLabelResolves() async throws {
        let f = try KnowledgeFixture()
        var lines = ["We reviewed the Kobaltix budget for the quarter"]
        lines += (0..<40).map { "Filler line number \($0) about nothing in particular that we say here" }
        lines += ["Finally the board approved the new vendor contract on Tuesday"]
        let id = try await f.meeting(lines, locale: "en-US", outputLocale: "en-US")
        let segments = try await f.store.citableSegments(id)
        let wrong = segments[0].id, right = segments.last!.id
        let reply = #"{"found": true, "answer": "The board approved it.", "claims": [{"text": "Approved", "citations": [\#(wrong)], "quote": "the board approved the new vendor contract"}]}"#
        let chat = ScriptedChat { _, _, _ in ScriptedChat.reply(reply) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat))
        let result = try await service.ask("Kobaltix budget", meetingID: nil)
        #expect(result.answer.hasEvidence && result.answer.claims[0].citations == [right] && result.answer.claims[0].reanchoredFrom == wrong)
        #expect(result.sent[right] != nil, "the segment the citation moved to is part of what the card can label and open")
        #expect(result.anchoredMeetings[right] == id || result.passages.contains { $0.segments.contains { $0.id == right } })
    }
}
