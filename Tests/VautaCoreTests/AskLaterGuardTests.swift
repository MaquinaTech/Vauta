// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// A live question about something that has not happened yet: the three-way `found`, and the check of the quoted lines.
@Suite("Ask: the answer that comes later")
struct AskLaterGuardTests {
    static let lines = ["We reviewed the Kobaltix budget for the quarter", "Next week Ana will present the new budget proposal",
                        "Ana will send the numbers on Friday"]

    static func isRelationCall(_ messages: [ChatMessage]) -> Bool { messages.last?.content.contains("Do the quoted lines state") == true }

    static func rig(relation: @escaping @Sendable (Int) async throws -> ChatResult, answer: String, integrated: Bool = true) async throws -> (LLMService, ScriptedChat, Int64) {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(lines, locale: "en-US", outputLocale: "en-US")
        let segments = try await f.store.citableSegments(id)
        let target = segments[1].id
        let reply = answer.replacingOccurrences(of: "$ID", with: "\(target)")
        let chat = ScriptedChat { messages, _, call in
            if Self.isRelationCall(messages) { return try await relation(call) }
            return ScriptedChat.reply(reply)
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: integrated))
        await service.setAnswerGuards(.all)
        await service.setRecording(true, meetingID: id)
        return (service, chat, id)
    }

    static let verified = #"{"found": "yes", "answer": "Ana will present the proposal next week.", "claims": [{"text": "Ana presents the proposal", "citations": [$ID], "quote": "Ana will present the new budget proposal"}]}"#

    @Test func notYetIsItsOwnKindWithTheModelsTextAside() async throws {
        let (service, _, id) = try await Self.rig(relation: { _ in ScriptedChat.reply("{}") },
                                                  answer: #"{"found": "not_yet", "answer": "The vote is planned for later.", "claims": []}"#)
        let result = try await service.ask("What did the board vote?", meetingID: id)
        #expect(result.answer.kind == .notYet && result.answer.claims.isEmpty && result.answer.withheld == "The vote is planned for later." && result.answer.answer.isEmpty)
        #expect(!result.answer.isUnverified, "not yet is neither an answer nor an unverified one")
    }

    @Test func theLiveSchemaHasThreeWordsAndTheOthersKeepTheBoolean() async throws {
        let (service, chat, id) = try await Self.rig(relation: { _ in ScriptedChat.reply("{}") }, answer: Self.verified.replacingOccurrences(of: "\"yes\"", with: "\"no\""))
        _ = try await service.ask("What did Ana say?", meetingID: id)
        guard case .tagged(let key, let cases)? = chat.calls.first?.options.outputSchema else { Issue.record("not tagged"); return }
        #expect(key == "found" && cases.map(\.value) == ["\"yes\"", "\"not_yet\"", "\"no\""])
        #expect(cases[0].rest.contains { $0.name == "claims" } && cases.dropFirst().allSatisfy { c in
            if case .array(_, let lo, let hi)? = c.rest.first(where: { $0.name == "claims" })?.schema { lo == 0 && hi == 0 } else { false }
        })
        // After the meeting, or across the library: the boolean.
        for schema in [OutputSchemas.answer(.init(segments: [1]), live: false), OutputSchemas.answer(.init(segments: [1]), documents: true)] {
            guard case .tagged(_, let plain) = schema else { Issue.record("not tagged"); continue }
            #expect(plain.map(\.value) == ["true", "false"])
        }
        // The prompt describes the words, with no sentence to copy.
        let rules = chat.calls.first?.text ?? ""
        #expect(rules.contains("\"not_yet\" if the question is about something that has not happened yet"))
        #expect(!rules.contains("It has not been said yet"))
    }

    @Test func aQuestionAboutAFinishedMeetingNeverGetsTheLiveRulesOrTheThreeWords() async throws {
        let (service, chat, id) = try await Self.rig(relation: { _ in ScriptedChat.reply("{}") }, answer: Self.verified.replacingOccurrences(of: "\"yes\"", with: "true"))
        await service.setRecording(false, meetingID: id)
        let result = try await service.ask("What did Ana say?", meetingID: id)
        #expect(result.answer.kind == .verified)
        guard case .tagged(_, let cases)? = chat.calls.last?.options.outputSchema else { Issue.record("not tagged"); return }
        #expect(cases.map(\.value) == ["true", "false"], "after the recording the grammar is the boolean, kept prefix or not")
        let text = chat.calls.last?.text ?? ""
        #expect(!text.contains("Only what has been said up to now counts") && !text.contains("not_yet") && text.contains("The material is complete"))
    }

    @Test func theKeptPrefixIsTheSameWhileRecordingAndAfterwards() async throws {
        let (service, chat, id) = try await Self.rig(relation: { _ in ScriptedChat.reply("{}") }, answer: Self.verified)
        await service.setAnswerGuards([])
        _ = try await service.ask("What did Ana say?", meetingID: id)
        await service.setRecording(false, meetingID: id)
        _ = try await service.ask("What did Ana say?", meetingID: id)
        let calls = chat.calls.filter { $0.options.purpose == .ask }
        try #require(calls.count == 2)
        #expect(calls[0].messages.count == 4 && calls[1].messages.count == 4)
        #expect(calls[0].messages[..<3].map(\.content) == calls[1].messages[..<3].map(\.content), "system, people with rules, and transcript are identical live and finished")
        #expect(calls[0].messages[3].content.contains("Only what has been said up to now counts") && calls[1].messages[3].content.contains("The material is complete"))
    }

    @Test func parsingAcceptsTheWordsTheBooleanAndTheLegacyKey() throws {
        let sent: [Int64: CitableSegment] = [5: CitableSegment(id: 5, channel: .others, start: 1, text: "Ana will present the new budget proposal")]
        let claim = #"[{"text": "x", "citations": [5], "quote": "Ana will present the new budget"}]"#
        #expect(try VautaPrompts.verifyAnswer(#"{"found": "not_yet", "answer": "later", "claims": []}"#, sent: sent).kind == .notYet)
        #expect(try VautaPrompts.verifyAnswer(#"{"found": true, "answer": "a", "claims": \#(claim)}"#, sent: sent).kind == .verified)
        #expect(try VautaPrompts.verifyAnswer(#"{"found": "yes", "answer": "a", "claims": \#(claim)}"#, sent: sent).kind == .verified)
        #expect(try VautaPrompts.verifyAnswer(#"{"found": false, "answer": "no", "claims": []}"#, sent: sent).kind == .notFound)
        #expect(try VautaPrompts.verifyAnswer(#"{"found": "no", "answer": "no", "claims": []}"#, sent: sent).kind == .notFound)
        #expect(try VautaPrompts.verifyAnswer(#"{"encontrado": true, "respuesta": "a", "afirmaciones": [{"texto": "x", "citas": [5], "cita_literal": "Ana will present the new budget"}]}"#, sent: sent).kind == .verified)
    }

    @Test func anAnswerThatAnticipatesBecomesNotYetAndKeepsTheRelatedMoments() async throws {
        let (service, _, id) = try await Self.rig(relation: { _ in ScriptedChat.reply(#"{"relation": "anticipates"}"#) }, answer: Self.verified)
        let result = try await service.ask("What did Ana present?", meetingID: id)
        #expect(result.answer.kind == .notYet && result.answer.claims.count == 1 && result.answer.claims[0].verified)
        #expect(result.answer.withheld == "Ana will present the proposal next week.")
    }

    @Test func aRelatedAnswerSaysItOnlyTouchesTheTopicAndKeepsItsVerifiedQuotes() async throws {
        let (service, _, id) = try await Self.rig(relation: { _ in ScriptedChat.reply(#"{"relation": "related"}"#) }, answer: Self.verified)
        let result = try await service.ask("What did Ana present?", meetingID: id)
        #expect(result.answer.kind == .related && result.answer.claims.allSatisfy(\.verified) && result.answer.found && !result.answer.isUnverified,
                "the words are in the transcript: they are not reported as missing")
        let export = AnswerExport(question: "Q?", answer: result.answer, relatedNote: "These moments only touch the topic.", source: { _ in "0:10" })
        #expect(export.plainText().contains("Only related: ") && export.plainText().contains("These moments only touch the topic.") && !export.plainText().contains("Not verified"))
        #expect(export.markdown().contains("_These moments only touch the topic._"))
    }

    @Test func aPartlyVerifiedAnswerIsCopiedAsPartlyVerified() {
        let answer = VerifiedAnswer(answer: "It ships Thursday.", claims: [.init(id: "a", text: "ships", citations: [1], verified: true), .init(id: "b", text: "to all", citations: [], verified: false)], found: true)
        #expect(answer.kind == .partlyVerified)
        let export = AnswerExport(question: "Q?", answer: answer, partlyVerifiedNote: "Some points are unchecked.", source: { _ in "0:10" })
        #expect(export.plainText().hasPrefix("Q?\n\nPartly verified: It ships Thursday.") && export.plainText().contains("Some points are unchecked."))
    }

    @Test func aStatedAnswerStaysVerified() async throws {
        let (service, _, id) = try await Self.rig(relation: { _ in ScriptedChat.reply(#"{"relation": "states"}"#) }, answer: Self.verified)
        let result = try await service.ask("What did Ana present?", meetingID: id)
        #expect(result.answer.kind == .verified)
    }

    @Test func theCheckFailsOpenOnAnErrorAndOnTimeout() async throws {
        let (failing, _, id1) = try await Self.rig(relation: { _ in throw LLMError.network("offline") }, answer: Self.verified)
        #expect(try await failing.ask("What did Ana present?", meetingID: id1).answer.kind == .verified)
        let (slow, _, id2) = try await Self.rig(relation: { _ in try await Task.sleep(for: .seconds(3_600)); return ScriptedChat.reply(#"{"relation": "anticipates"}"#) }, answer: Self.verified)
        // The check never answers by itself: the question coming back verified is the proof that the cap held.
        #expect(try await slow.ask("What did Ana present?", meetingID: id2).answer.kind == .verified)
    }

    @Test func theCheckRunsOnlyForLiveVerifiedAnswersOnTheIntegratedModel() async throws {
        // Not live: the meeting is not being recorded.
        let f = try KnowledgeFixture()
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        let target = try await f.store.citableSegments(id)[1].id
        let reply = Self.verified.replacingOccurrences(of: "$ID", with: "\(target)").replacingOccurrences(of: "\"yes\"", with: "true")
        let chat = ScriptedChat { _, _, _ in ScriptedChat.reply(reply) }
        let after = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        _ = try await after.ask("What did Ana present?", meetingID: id)
        #expect(chat.calls.count == 1, "no check after the meeting")
        // Live, but found no or not_yet: nothing to check.
        for word in ["no", "not_yet"] {
            let (service, c, id) = try await Self.rig(relation: { _ in ScriptedChat.reply(#"{"relation": "states"}"#) },
                                                       answer: "{\"found\": \"\(word)\", \"answer\": \"x\", \"claims\": []}")
            _ = try await service.ask("What did Ana present?", meetingID: id)
            #expect(c.calls.filter { Self.isRelationCall($0.messages) }.isEmpty, "\(word)")
        }
        // Apple's model or a server: no check, and no three-way word.
        let (apple, appleChat, appleID) = try await Self.rig(relation: { _ in ScriptedChat.reply(#"{"relation": "anticipates"}"#) },
                                                             answer: Self.verified.replacingOccurrences(of: "\"yes\"", with: "true"), integrated: false)
        let r = try await apple.ask("What did Ana present?", meetingID: appleID)
        #expect(r.answer.kind == .verified && appleChat.calls.filter { Self.isRelationCall($0.messages) }.isEmpty)
    }

    @Test func theCheckSharesThePrefixOfTheAnswer() async throws {
        let (service, chat, id) = try await Self.rig(relation: { _ in ScriptedChat.reply(#"{"relation": "states"}"#) }, answer: Self.verified)
        _ = try await service.ask("What did Ana present?", meetingID: id)
        let calls = chat.calls
        try #require(calls.count == 2)
        let ask = calls[0], check = calls[1]
        #expect(Array(ask.messages.dropLast()).map(\.content) == Array(check.messages.dropLast()).map(\.content), "everything before the last message is the same")
        #expect(check.options.reusePrefix && check.options.slot == ask.options.slot && check.options.maxSeconds == 3)
        guard case .object(let props)? = check.options.outputSchema else { Issue.record("no schema"); return }
        #expect(props.map(\.name) == ["relation"])
    }

    @Test func relationsParse() {
        #expect(LLMService.parseRelation(#"{"relation":"anticipates"}"#) == .anticipates)
        #expect(LLMService.parseRelation(#"{"relation": "States"}"#) == .states)
        #expect(LLMService.parseRelation("nothing") == nil && LLMService.parseRelation(#"{"relation":"maybe"}"#) == nil)
    }
}
