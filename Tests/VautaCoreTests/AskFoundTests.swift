// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Ask answers with a leading `found`: found=true needs a verifiable claim, found=false is an explicit refusal; what the prompts say
/// about time and about proposals; what is stripped from the text; and the shape each backend is held to.
@Suite("Ask: found, claims, text and the three backends")
struct AskFoundTests {
    static let lines = ["We reviewed the Kobaltix budget for the quarter", "Fine, we keep the budget as it is",
                        "Ana will send the numbers on Friday"]
    static let sent: [Int64: CitableSegment] = [
        12: CitableSegment(id: 12, channel: .others, start: 5, text: "We keep the budget as it is for this quarter"),
        13: CitableSegment(id: 13, channel: .me, start: 20, text: "Ana will send the numbers on Friday"),
    ]

    // MARK: Verification

    @Test func foundWithAVerifiedClaimHasEvidence() throws {
        let json = #"{"found": true, "answer": "The budget stays.", "claims": [{"text": "Budget kept", "citations": [12], "quote": "keep the budget as it is"}]}"#
        let a = try VautaPrompts.verifyAnswer(json, sent: Self.sent)
        #expect(a.found && a.hasEvidence && !a.isUnverified && a.claims.count == 1)
    }

    @Test func foundWhoseClaimsAllFailIsUnverifiedNotARefusal() throws {
        let wrongQuote = #"{"found": true, "answer": "The budget doubles.", "claims": [{"text": "Budget doubled", "citations": [12], "quote": "we double the budget this year"}]}"#
        let a = try VautaPrompts.verifyAnswer(wrongQuote, sent: Self.sent)
        #expect(a.found, "the model said it found it")
        #expect(a.isUnverified && !a.hasEvidence, "nothing could be checked: shown as unverified")
        #expect(a.claims.count == 1 && !a.claims[0].verified && a.answer == "The budget doubles.")
    }

    @Test func foundNeedsAClaimThatCitesWhatWasSent() throws {
        // Found with no claim at all (a backend with no grammar): the shape is broken, so it is rejected (and asked again), never shown.
        let none = #"{"found": true, "answer": "The budget stays.", "claims": []}"#
        // A citation to a segment that was never sent is no citation.
        let unknown = #"{"found": true, "answer": "Ana sends it.", "claims": [{"text": "Ana sends", "citations": [99], "quote": "Ana will send the numbers"}]}"#
        // A claim with no citation at all, or with no text, or with no quote (what the grammar writes to close a cut-off claim).
        let uncited = #"{"found": true, "answer": "Ana sends it.", "claims": [{"text": "Ana sends", "citations": [], "quote": "Ana will send the numbers"}]}"#
        let noText = #"{"found": true, "answer": "Ana sends it.", "claims": [{"text": "", "citations": [13], "quote": "Ana will send the numbers"}]}"#
        let noQuote = #"{"found": true, "answer": "Ana sen", "claims": [{"text": "Ana sends", "citations": [12], "quote": ""}]}"#
        let emptyEverything = #"{"found": true, "answer": "", "claims": []}"#
        for reply in [none, unknown, uncited, noText, noQuote, emptyEverything] {
            #expect(throws: LLMError.self, "\(reply)") { try VautaPrompts.verifyAnswer(reply, sent: Self.sent) }
        }
        // One good claim among bad ones is enough, and the bad ones are not shown as claims.
        let mixed = #"{"found": true, "answer": "Ana sends it.", "claims": [{"text": "x", "citations": [99], "quote": "y"}, {"text": "Ana sends", "citations": [13], "quote": "Ana will send the numbers"}]}"#
        let a = try VautaPrompts.verifyAnswer(mixed, sent: Self.sent)
        #expect(a.found && a.hasEvidence && a.claims.count == 2)
    }

    @Test func foundFalseIsAnExplicitRefusalWithoutClaims() throws {
        let json = #"{"found": false, "answer": "I cannot find that in your meetings.", "claims": []}"#
        let a = try VautaPrompts.verifyAnswer(json, sent: Self.sent)
        #expect(!a.found && !a.isUnverified && !a.hasEvidence && a.claims.isEmpty && a.answer.isEmpty, "the app writes the refusal")
        // A backend that contradicts itself: the model's word on found decides, claims of a refusal are not shown.
        let contradiction = #"{"found": false, "answer": "Not there.", "claims": [{"text": "x", "citations": [12], "quote": "keep the budget as it is"}]}"#
        let b = try VautaPrompts.verifyAnswer(contradiction, sent: Self.sent)
        #expect(!b.found && b.claims.isEmpty)
    }

    @Test func aRefusalNeverShowsTheModelsOwnUncitedText() throws {
        let json = #"{"found": false, "answer": "The Kobaltix budget is 5k euros and it was approved by the board last week.", "claims": []}"#
        let a = try VautaPrompts.verifyAnswer(json, sent: Self.sent)
        #expect(!a.found && a.answer.isEmpty && a.claims.isEmpty, "the service writes the refusal in the app's own words")
        #expect(a.withheldAnAnswer && a.withheld.contains("5k"), "kept apart so an evaluation can count it as its own kind")
        // A plain refusal sentence is not an answer written under found=false.
        let plain = try VautaPrompts.verifyAnswer(#"{"found": false, "answer": "I cannot find that in your meetings.", "claims": []}"#, sent: Self.sent)
        #expect(!plain.withheldAnAnswer)
        // One with a figure and some length is; a short one is a refusal even with a number in it.
        #expect(try VautaPrompts.verifyAnswer(#"{"found": false, "answer": "It is 5k euros for the second quarter plan", "claims": []}"#, sent: Self.sent).withheldAnAnswer)
        #expect(try !VautaPrompts.verifyAnswer(#"{"found": false, "answer": "It is 5k", "claims": []}"#, sent: Self.sent).withheldAnAnswer)
    }

    @Test func aCutOffLiveAnswerIsKeptAsUnverifiedOnlyWhenAskedTo() throws {
        // What the grammar writes when the cap fires inside the first claim: the sentence is whole, the claim is filler.
        let cut = #"{"found": true, "answer": "The budget stays as it is.", "claims": [{"text": "Budget...", "citations": [12], "quote": "........"}]}"#
        let kept = try VautaPrompts.verifyAnswer(cut, sent: Self.sent, keepCutAnswer: true)
        #expect(kept.found && kept.isUnverified && kept.cutShort && kept.claims.isEmpty && kept.answer == "The budget stays as it is.")
        #expect(throws: LLMError.self) { try VautaPrompts.verifyAnswer(cut, sent: Self.sent) }
        // Found with no claims at all is still rejected, cut or not.
        #expect(throws: LLMError.self) { try VautaPrompts.verifyAnswer(#"{"found": true, "answer": "Stays.", "claims": []}"#, sent: Self.sent, keepCutAnswer: true) }
    }

    @Test func aReplyWithoutFoundIsReadTheOldWay() throws {
        let withClaim = #"{"answer": "It stays.", "claims": [{"text": "Budget kept", "citations": [12], "quote": "keep the budget as it is"}]}"#
        #expect(try VautaPrompts.verifyAnswer(withClaim, sent: Self.sent).found)
        // No `found` and no claim cannot be told from an uncited answer: it is rejected (and asked again), not read as a refusal.
        let withoutClaims = #"{"answer": "The budget is 5k", "claims": []}"#
        #expect(throws: LLMError.self) { try VautaPrompts.verifyAnswer(withoutClaims, sent: Self.sent) }
        // `found` as a string or in Spanish.
        #expect(try !VautaPrompts.verifyAnswer(#"{"found": "false", "answer": "No.", "claims": []}"#, sent: Self.sent).found)
        #expect(try VautaPrompts.verifyAnswer(#"{"encontrado": true, "answer": "Sí.", "claims": [{"text": "Se mantiene", "citations": [12], "quote": "keep the budget as it is"}]}"#, sent: Self.sent).found)
    }

    // MARK: Text

    @Test func segmentTagsAndTimestampsAreStrippedFromTheText() throws {
        let cases: [(String, String)] = [
            ("The budget stays [S12].", "The budget stays."),
            ("The budget stays [S5 · 01:18 · Others] for the quarter.", "The budget stays for the quarter."),
            ("Ana sends the numbers (S20:39) on Friday.", "Ana sends the numbers on Friday."),
            ("Decided [S3][S4] and approved [D2].", "Decided and approved."),
            ("At [01:18] they agreed (12:34) to wait.", "At they agreed to wait."),
            ("See [S12, S13] for details", "See for details"),
            ("A 5% rise in section S12 of the plan", "A 5% rise in section S12 of the plan"),
            ("The ratio [1:2] holds", "The ratio [1:2] holds"),
            ("We keep it in an (S3 bucket).", "We keep it in an (S3 bucket)."),
            ("The [D1 visa] is required and (s3 of them) too", "The [D1 visa] is required and (s3 of them) too"),
            ("Ana (S3, 00:20) agreed [S12: 01:18] and [D4 · p. 2].", "Ana agreed and."),
        ]
        for (raw, expected) in cases { #expect(AnswerText.clean(raw) == expected, "\(raw)") }
        let json = #"{"found": true, "answer": "Stays [S12 · 00:05 · Others].", "claims": [{"text": "Kept (S12:5)", "citations": [12], "quote": "keep the budget as it is"}]}"#
        let a = try VautaPrompts.verifyAnswer(json, sent: Self.sent)
        #expect(a.answer == "Stays." && a.claims[0].text == "Kept" && a.claims[0].verified)
    }

    @Test func aBracketedCodeIsStrippedOnlyWhenItIsOneThatWasSent() {
        let codes: Set<String> = ["S12", "D2"]
        #expect(AnswerText.clean("Stays [S12] and (D2).", codes: codes) == "Stays and.")
        #expect(AnswerText.clean("Vitamin (D3) and the Audi (S3) stay", codes: codes) == "Vitamin (D3) and the Audi (S3) stay")
        #expect(AnswerText.clean("Vitamin (D3) and [S12 · 00:05 · Others]", codes: codes) == "Vitamin (D3) and")
    }

    @Test func promptPlaceholdersAreNeverShownAsAnAnswer() throws {
        for echo in ["a short answer", "<say you cannot find it in the user's meetings>", "A Short Answer", "answer"] {
            let json = #"{"found": false, "answer": "\#(echo)", "claims": []}"#
            #expect(try VautaPrompts.verifyAnswer(json, sent: Self.sent).answer.isEmpty, "\(echo)")
        }
        // Found, with the answer echoed: the claims are the answer.
        let found = #"{"found": true, "answer": "a short answer", "claims": [{"text": "Budget kept", "citations": [12], "quote": "keep the budget as it is"}]}"#
        #expect(try VautaPrompts.verifyAnswer(found, sent: Self.sent).answer == "Budget kept")
    }

    // MARK: The prompts

    @Test(arguments: ["en-US", "es-ES", "fr-FR", "de-DE", "it-IT", "pt-BR", "ja-JP", "ko-KR", "zh-Hans"], [false, true])
    func theAskPromptHasNoPlaceholderToEchoInAnyLanguageOrVariant(identifier: String, documents: Bool) {
        let text = VautaPrompts.askInstruction("What was decided?", language: OutputLanguage(Locale(identifier: identifier)), documents: documents).content
        for placeholder in ["a short answer", "<say you cannot", "say you cannot find it in", "each concrete fact in the answer", "words copied verbatim from one of the cited"] {
            #expect(!text.contains(placeholder), "\(identifier) documents \(documents): \(placeholder)")
        }
        // The only samples are empty strings and empty lists.
        let sample = try? #require(text.components(separatedBy: "Shape: ").last?.components(separatedBy: "\n").first)
        #expect(sample?.contains("\"answer\": \"\"") == true && sample?.contains("\"text\": \"\"") == true && sample?.contains("\"quote\": \"\"") == true)
        #expect(text.contains("\"found\"") && text.contains(OutputLanguage(Locale(identifier: identifier)).instruction))
        #expect(sample?.contains("\"citations\": []") == true, "no sample ids to copy")
    }

    @Test func theAskPromptTellsTheModelThatOnlyWhatWasSaidSoFarCounts() {
        let text = VautaPrompts.askInstruction("What did the designer propose?", language: OutputLanguage(Locale(identifier: "en-US")), live: true).content
        #expect(text.contains("Only what has been said up to now counts"))
        #expect(text.contains("If the answer may come later") && text.contains("do not answer with earlier material: found is false"))
        // The refusal for a later answer is the same refusal as for a missing one, and no sentence is handed to the model to repeat:
        // Apple's model wrote "It has not been said yet." as the answer to nearly every question when the prompt showed it.
        #expect(text.contains("or the answer comes later in the meeting"))
        #expect(!text.contains("has not been said yet") && !text.contains("not been said yet"))
        // The same rule in the prompt of a question over documents.
        #expect(VautaPrompts.askInstruction("q", language: OutputLanguage(Locale(identifier: "es-ES")), documents: true, live: true).content.contains("Only what has been said up to now counts"))
        // Not for a finished meeting or the library: there the material is complete.
        let finished = VautaPrompts.askInstruction("What will be presented to the board?", language: OutputLanguage(Locale(identifier: "en-US"))).content
        #expect(!finished.contains("Only what has been said up to now counts") && !finished.contains("may come later") && finished.contains("The material is complete"))
    }

    @Test func theQuoteRuleAsksForOnePhraseOfOneSegmentAsWritten() {
        let text = VautaPrompts.askInstruction("q", language: OutputLanguage(Locale(identifier: "en-US"))).content
        #expect(text.contains("a phrase of 4 to 15 words copied word for word from ONE cited segment"))
        #expect(text.contains("do not join two segments or correct the wording"))
        let minutes = VautaPrompts.minutesInstruction(.init(meetingDate: .now, language: OutputLanguage(Locale(identifier: "en-US")))).content
        #expect(minutes.contains("A \"quote\" comes from ONE segment, exactly as written there") && minutes.contains("do not join the end of one segment with the start of the next"))
        #expect(VautaPrompts.blockInstruction(OutputLanguage(Locale(identifier: "en-US"))).content.contains("comes from ONE segment"))
    }

    @Test func theAskPromptSeparatesAProposalFromACommitteeReferralFromADecision() {
        let text = VautaPrompts.askInstruction("¿Se aprobó el proyecto?", language: OutputLanguage(Locale(identifier: "es-AR"))).content
        #expect(text.contains("A proposal, a motion sent to a committee and a decision are different things"))
        #expect(text.contains("decided, approved or agreed only if the material says it was"))
        #expect(text.contains("otherwise say it was proposed or sent on"))
        #expect(text.contains("Never put segment numbers, [S…] tags or times inside"))
    }

    // MARK: The three backends

    static func asks(_ chat: ScriptedChat) -> [ScriptedChat.Call] { chat.calls }
    static func found(_ messages: [ChatMessage], found: Bool = true) -> String {
        guard found, let (id, text) = ScriptedChat.firstSegment(messages) else { return #"{"found": false, "answer": "Not there.", "claims": []}"# }
        return #"{"found": true, "answer": "It stays.", "claims": [{"text": "Budget kept", "citations": [\#(id)], "quote": "\#(text.prefix(30))"}]}"#
    }

    /// The bounds of the `true` branch of an integrated answer's schema: (claims at most, answer bytes at most).
    static func bounds(_ schema: OutputSchema?) throws -> (claims: Int, answerBytes: Int) {
        guard case .tagged(let key, let cases)? = schema, key == "found", cases.map(\.value) == ["true", "false"] else {
            Issue.record("not a tagged schema")
            return (0, 0)
        }
        let rest = Dictionary(uniqueKeysWithValues: cases[0].rest.map { ($0.name, $0.schema) })
        guard case .array(_, let lo, let hi)? = rest["claims"], case .string(let bytes)? = rest["answer"] else { Issue.record("no claims"); return (0, 0) }
        #expect(lo == 1)
        return (hi, bytes)
    }

    @Test func aLiveAnswerOnTheIntegratedModelIsCappedAndGetsTheTightSchema() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        let chat = ScriptedChat { messages, _, _ in ScriptedChat.reply(Self.found(messages), finish: .length) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        await service.setRecording(true, meetingID: nil)
        let result = try await service.ask("What did we decide about the Kobaltix budget?", meetingID: id)
        #expect(Self.asks(chat).count == 1, "a cut-off answer is already valid JSON: no second, larger call")
        let options = try #require(Self.asks(chat).first?.options)
        #expect(options.maxTokens == LLMService.liveAnswerTokens && options.maxSeconds == LLMService.liveAnswerSeconds)
        #expect(options.reusePrefix, "the warm prefix is kept")
        #expect(options.responseFormat == nil)
        let live = try Self.bounds(options.outputSchema)
        #expect(live.claims == 3 && live.answerBytes == 500)
        #expect(result.answer.found && result.answer.hasEvidence)
    }

    @Test func anyOtherQuestionOnTheIntegratedModelGetsTheFullSchemaAndTheNormalBudget() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        let chat = ScriptedChat { messages, _, _ in ScriptedChat.reply(Self.found(messages)) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        // After the meeting (one meeting), and across the library: neither is a live answer.
        _ = try await service.ask("What did we decide about the Kobaltix budget?", meetingID: id)
        _ = try await service.ask("What did we decide about the Kobaltix budget?", meetingID: nil)
        #expect(Self.asks(chat).count == 2)
        for call in Self.asks(chat) {
            #expect(call.options.maxSeconds == nil, "no clock outside a recording")
            #expect(call.options.maxTokens == ContextBudget(contextTokens: 65_536).askOutput && call.options.maxTokens > LLMService.liveAnswerTokens)
            let full = try Self.bounds(call.options.outputSchema)
            #expect(full.claims == 12 && full.answerBytes == 3000)
        }
        #expect(Self.asks(chat)[0].options.model == .deep)
    }

    @Test func aServerIsAskedForTheSameShapeThroughResponseFormat() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        let chat = ScriptedChat { messages, _, _ in ScriptedChat.reply(Self.found(messages)) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat))
        let result = try await service.ask("What did we decide about the Kobaltix budget?", meetingID: id)
        let options = try #require(Self.asks(chat).first?.options)
        #expect(options.outputSchema == nil && options.maxSeconds == nil)
        guard case .jsonSchema(let name, let data)? = options.responseFormat else { Issue.record("no response_format"); return }
        #expect(name == "answer")
        let schema = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(schema["anyOf"] == nil && schema["type"] as? String == "object", "a flat object: no root-level anyOf")
        // `found` is the first property, then `answer`, then `claims`: a server writes properties in that order.
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.matches(of: /"properties":\{"found":\{"type":"boolean"\},"answer":.*?,"claims":/).count == 1)
        #expect(result.answer.hasEvidence)
        // The request body carries it (for a profile that takes json_schema) and a profile that takes nothing sends nothing.
        let profile = ServerProfile.defaults(for: .lmStudio)
        let body = try ServerRequests.chatBody(model: "m", messages: [.user("q")], options: options, profile: profile)
        let sentBody = String(decoding: body, as: UTF8.self)
        #expect(sentBody.contains("\"response_format\""))
        // The schema reaches the server as written, not re-sorted by the body's own serialisation.
        #expect(sentBody.contains(String(decoding: data, as: UTF8.self)))
        #expect(!sentBody.contains("vauta-schema"))
        // A server that takes only JSON mode, and one that takes nothing, are not sent the schema.
        let jsonMode = try ServerRequests.chatBody(model: "m", messages: [.user("q")], options: options,
                                                   profile: ServerProfile(kind: .openAICompatible, thinking: .none, structuredOutput: .jsonObject))
        #expect(String(decoding: jsonMode, as: UTF8.self).contains(#""response_format":{"type":"json_object"}"#))
        let none = try ServerRequests.chatBody(model: "m", messages: [.user("q")], options: options, profile: ServerProfile.defaults(for: .openAICompatible))
        #expect(!String(decoding: none, as: UTF8.self).contains("response_format"))
    }

    @Test func appleIsHeldToTheShapeByThePromptAndTheValidation() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        // Apple: on this Mac, not the integrated model. First reply is not JSON, the retry is.
        let chat = ScriptedChat { messages, _, call in ScriptedChat.reply(call == 1 ? "Sure! The budget stays." : Self.found(messages)) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 4096, onDevice: true))
        let result = try await service.ask("What did we decide about the Kobaltix budget?", meetingID: id)
        let options = try #require(Self.asks(chat).first?.options)
        #expect(options.responseFormat == nil && options.maxSeconds == nil, "no server fields; Apple gets its own guided schema")
        #expect(Self.asks(chat).count == 2 && result.answer.found && result.answer.hasEvidence, "one retry on an invalid reply")
        try #require(!chat.calls.isEmpty)
        #expect(chat.calls[0].text.contains("\"found\"") && chat.calls[0].text.contains("The material is complete"))
    }

    @Test(arguments: [true, false])
    func foundWithoutAClaimIsAskedAgainOnAppleAndOnAServerWithoutASchema(apple: Bool) async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        let free = #"{"found": true, "answer": "The budget stays.", "claims": []}"#
        // The first reply breaks the shape; the second keeps it.
        let chat = ScriptedChat { messages, _, call in ScriptedChat.reply(call == 1 ? free : Self.found(messages)) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 4096, onDevice: apple))
        let result = try await service.ask("What did we decide about the Kobaltix budget?", meetingID: id)
        #expect(Self.asks(chat).count == 2 && result.answer.found && result.answer.hasEvidence)
        // If the second reply is as bad, nothing is shown as found: the error stands.
        let stubborn = ScriptedChat { _, _, _ in ScriptedChat.reply(free) }
        let again = LLMService(store: f.store, providers: TestProviders(chat: stubborn, contextTokens: 4096, onDevice: apple))
        await #expect(throws: LLMError.self) { try await again.ask("What did we decide about the Kobaltix budget?", meetingID: id) }
        #expect(stubborn.calls.count == 2)
    }

    @Test func aRefusalAndAnUnverifiedAnswerStayDifferentThroughTheService() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        for (kind, reply, found, evidence) in [("refusal", #"{"found": false, "answer": "", "claims": []}"#, false, false),
                                              ("unverified", #"{"found": true, "answer": "They doubled it.", "claims": [{"text": "Doubled", "citations": [1], "quote": "we double the whole budget"}]}"#, true, false)] {
            let chat = ScriptedChat { _, _, _ in ScriptedChat.reply(reply) }
            let service = LLMService(store: f.store, providers: TestProviders(chat: chat))
            let result = try await service.ask("What happened to the budget?", meetingID: id)
            #expect(result.answer.found == found && result.answer.hasEvidence == evidence, "\(kind)")
            #expect(!result.answer.answer.isEmpty, "\(kind): the app writes the refusal when the model wrote none")
            #expect(result.answer.isUnverified == (kind == "unverified"))
        }
    }

    // MARK: Review fixes (11a.1)

    @Test func aRefusalWithAnAnswerWrittenUnderItShowsTheAppsRefusalNotTheModelsText() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        let reply = #"{"found": false, "answer": "The Kobaltix budget is 5k euros and the board approved it last week.", "claims": []}"#
        let chat = ScriptedChat { _, _, _ in ScriptedChat.reply(reply) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat))
        let result = try await service.ask("What is the Kobaltix budget?", meetingID: id)
        #expect(!result.answer.found && result.answer.claims.isEmpty)
        #expect(!result.answer.answer.contains("5k") && result.answer.answer.contains("can’t find"))
    }

    @Test func aReplyWithNeitherFoundNorClaimsIsAskedAgainNotShownAsARefusal() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        let bare = #"{"answer": "The budget is 5k", "claims": []}"#
        let chat = ScriptedChat { messages, _, call in ScriptedChat.reply(call == 1 ? bare : Self.found(messages)) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 4096, onDevice: true))
        let result = try await service.ask("What did we decide about the Kobaltix budget?", meetingID: id)
        #expect(Self.asks(chat).count == 2 && result.answer.found && result.answer.hasEvidence)
    }

    @Test func aCapClosedIntegratedAnswerIsShownAsUnverifiedNotAsAnError() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        // The cap fired inside the first claim: the grammar closed it with the smallest segment number and filler for the quote.
        let cut = #"{"found": true, "answer": "The budget stays as it is for this quarter.", "claims": [{"text": "Budget...", "citations": [1], "quote": "........"}]}"#
        let chat = ScriptedChat { _, _, _ in ScriptedChat.reply(cut, finish: .length) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        await service.setRecording(true, meetingID: nil)
        let result = try await service.ask("What did we decide about the Kobaltix budget?", meetingID: id)
        #expect(chat.calls.count == 1, "nothing to ask again")
        #expect(result.answer.found && result.answer.isUnverified && result.answer.cutShort)
        #expect(result.answer.answer == "The budget stays as it is for this quarter.")
    }

    @Test func aServerThatRejectsTheSchemaIsAskedOnceMoreWithoutIt() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        let chat = ScriptedChat { messages, options, _ in
            if options.responseFormat != nil { throw LLMError.http(400, message: "Unsupported response_format: anyOf at the root") }
            return ScriptedChat.reply(Self.found(messages))
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat))
        let result = try await service.ask("What did we decide about the Kobaltix budget?", meetingID: id)
        let asks = Self.asks(chat)
        #expect(asks.count == 2 && asks[0].options.responseFormat != nil && asks[1].options.responseFormat == nil)
        #expect(result.answer.found && result.answer.hasEvidence)
        // Another kind of error is not retried.
        let down = ScriptedChat { _, _, _ in throw LLMError.http(401, message: nil) }
        await #expect(throws: LLMError.self) { try await LLMService(store: f.store, providers: TestProviders(chat: down)).ask("q?", meetingID: id) }
        #expect(down.calls.count == 1)
    }

    @Test func theTimeRuleIsSentOnlyWhileTheMeetingBeingAskedAboutIsRecording() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        let chat = ScriptedChat { messages, _, _ in ScriptedChat.reply(Self.found(messages)) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat))
        _ = try await service.ask("What will be presented about the Kobaltix budget?", meetingID: id)
        _ = try await service.ask("What will be presented about the Kobaltix budget?", meetingID: nil)
        await service.setRecording(true, meetingID: id)
        _ = try await service.ask("What was said so far about the Kobaltix budget?", meetingID: id)
        _ = try await service.ask("What was said so far about the Kobaltix budget?", meetingID: nil)
        let asks = Self.asks(chat).map(\.text)
        #expect(asks.count == 4)
        #expect(!asks[0].contains("Only what has been said up to now counts") && !asks[1].contains("Only what has been said up to now counts"))
        #expect(asks[2].contains("Only what has been said up to now counts"))
        #expect(!asks[3].contains("Only what has been said up to now counts"), "across the library the material is complete")
    }

    @Test func theAskShapeHasNoSampleIDsAndTheTimeHintOnlyComesWhileRecording() {
        let en = OutputLanguage(Locale(identifier: "en-US"))
        for documents in [false, true] {
            let text = VautaPrompts.askInstruction("q", language: en, documents: documents).content
            let shape = text.split(separator: "\n").first { $0.hasPrefix("Shape:") }.map(String.init) ?? ""
            #expect(!shape.isEmpty && !shape.contains { $0.isNumber }, "the shape has nothing to copy: \(shape)")
            #expect(!text.contains("comes later in the meeting"), "a finished meeting gets no 'comes later' hint")
            #expect(VautaPrompts.askInstruction("q", language: en, documents: documents, live: true).content.contains("the answer comes later in the meeting"))
        }
    }

    @Test func theTimeRuleNeedsALiveSessionOfThatMeeting() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        let chat = ScriptedChat { messages, _, _ in ScriptedChat.reply(Self.found(messages)) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat))
        // Recording without a live session (no meeting given): a finished meeting is still complete material.
        await service.setRecording(true, meetingID: nil)
        _ = try await service.ask("What will be presented about the Kobaltix budget?", meetingID: id)
        #expect(!Self.asks(chat).map(\.text)[0].contains("Only what has been said up to now counts"))
    }

    @Test func aShortRefusalWithAFigureIsStillARefusal() {
        #expect(!AnswerText.isSubstantive("I can't find that in your 2 meetings."))
        #expect(!AnswerText.isSubstantive("No se dijo nada en 2019."))
        #expect(AnswerText.isSubstantive("The budget rises to 40,000 euros in the second quarter of the year, per the plan."))
    }
}
