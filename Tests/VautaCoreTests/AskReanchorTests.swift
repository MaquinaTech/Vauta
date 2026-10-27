// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Answers whose claims cite the wrong moment: the citation moves to where the words are, among what was visible.
@Suite("Ask: re-anchoring citations")
struct AskReanchorTests {
    static func seg(_ id: Int64, _ start: Double, _ text: String) -> CitableSegment {
        CitableSegment(id: id, channel: .others, start: start, text: text)
    }
    static let all: [CitableSegment] = [
        seg(39, 100, "We talked about the schedule for a while"),
        seg(139, 300, "The board approved the new vendor contract on Tuesday"),
        seg(200, 500, "The board approved the new vendor contract on Tuesday again"),
    ]
    static let reply = #"{"found": true, "answer": "The board approved the contract.", "claims": [{"text": "Approved", "citations": [39], "quote": "board approved the new vendor contract"}]}"#

    @Test func aWrongIdIsMovedToTheSegmentThatHoldsTheQuote() throws {
        let sent = [Int64(39): Self.all[0]]
        let withoutPool = try VautaPrompts.verifyAnswer(Self.reply, sent: sent)
        #expect(withoutPool.isUnverified, "the cheap pass leaves it unverified")
        let a = try VautaPrompts.verifyAnswer(Self.reply, sent: sent, pool: QuoteAnchor.Pool(Self.all))
        #expect(a.hasEvidence && a.claims[0].citations == [139] && a.claims[0].reanchoredFrom == 39, "\(a.claims[0])")
    }

    @Test func aCitationToAnUnsentSegmentCanBeMovedToo() throws {
        let reply = #"{"found": true, "answer": "x", "claims": [{"text": "Approved", "citations": [150], "quote": "board approved the new vendor contract"}]}"#
        let a = try VautaPrompts.verifyAnswer(reply, sent: [39: Self.all[0]], pool: QuoteAnchor.Pool(Self.all))
        #expect(a.claims[0].verified && a.claims[0].citations == [139])
    }

    @Test func theVisibleWindowDecides() throws {
        // A live question at t = 300: only what is before it is in the pool.
        let atQuestion = Self.all.filter { $0.start <= 300 }
        let early = QuoteAnchor.Pool(Self.all.filter { $0.start <= 200 })
        let early1 = try VautaPrompts.verifyAnswer(Self.reply, sent: [39: Self.all[0]], pool: early)
        #expect(early1.isUnverified, "the occurrence is after the question")
        let later = try VautaPrompts.verifyAnswer(Self.reply, sent: [39: Self.all[0]], pool: QuoteAnchor.Pool(atQuestion))
        #expect(later.hasEvidence && later.claims[0].citations == [139])
    }

    @Test func aQuoteInAnotherLanguageStaysUnverified() throws {
        let es = [Self.seg(1, 0, "Hablamos del calendario"), Self.seg(2, 5, "La junta aprobó el nuevo contrato con el proveedor")]
        let english = #"{"found": true, "answer": "x", "claims": [{"text": "Approved", "citations": [1], "quote": "the board approved the new vendor contract"}]}"#
        let a = try VautaPrompts.verifyAnswer(english, sent: [1: es[0]], pool: QuoteAnchor.Pool(es, language: "es"), language: "es")
        #expect(a.isUnverified)
        let spanish = #"{"found": true, "answer": "x", "claims": [{"text": "Approved", "citations": [1], "quote": "La junta aprobó el nuevo contrato"}]}"#
        let b = try VautaPrompts.verifyAnswer(spanish, sent: [1: es[0]], pool: QuoteAnchor.Pool(es, language: "es"), language: "es")
        #expect(b.hasEvidence && b.claims[0].citations == [2])
    }

    @Test func documentCitationsAreNeverReanchored() throws {
        let doc = DocumentPassage(id: 1, key: "k1", fileID: 1, sourceID: 1, relPath: "a.pdf", fileName: "a.pdf", title: nil, format: .pdf, locator: .page(1), text: "Title\nThe vendor contract was approved last year by the board", ocr: false, score: 1)
        let reply = #"{"found": true, "answer": "x", "claims": [{"text": "Approved", "citations": ["D1"], "quote": "board approved the new vendor contract"}]}"#
        let a = try VautaPrompts.verifyAnswer(reply, sent: [:], documents: ["D1": doc], pool: QuoteAnchor.Pool(Self.all))
        #expect(a.isUnverified && a.claims[0].citations.isEmpty)
    }

    @Test func exactClaimsAreUntouched() throws {
        let reply = #"{"found": true, "answer": "x", "claims": [{"text": "Approved", "citations": [139], "quote": "board approved the new vendor contract"}]}"#
        let a = try VautaPrompts.verifyAnswer(reply, sent: [139: Self.all[1]], pool: QuoteAnchor.Pool(Self.all))
        #expect(a.claims[0].citations == [139] && a.claims[0].reanchoredFrom == nil)
    }
}

/// The cited segment was visible but not among the sent passages, and quotes are only moved within the meeting they were cited in.
@Suite("Ask: re-anchoring across meetings and at the moment of the question")
struct AskReanchorLibraryTests {
    typealias T = AskReanchorTests

    @Test func aCitedSegmentThatWasVisibleButNotSentHoldsTheQuoteWhereItIs() throws {
        // The model cited 139 (visible, not sent) and quoted it; 200 also has the words and is nearer to nothing else.
        let reply = #"{"found": true, "answer": "x", "claims": [{"text": "Approved", "citations": [139], "quote": "board approved the new vendor contract"}]}"#
        let a = try VautaPrompts.verifyAnswer(reply, sent: [39: T.all[0]], pool: QuoteAnchor.Pool(T.all))
        #expect(a.claims[0].verified && a.claims[0].citations == [139] && a.claims[0].reanchoredFrom == nil, "the cited segment is kept, not moved to a farther occurrence")
        // Several citations: the one that holds the quote counts, whichever comes first.
        let two = #"{"found": true, "answer": "x", "claims": [{"text": "Approved", "citations": [39, 200], "quote": "board approved the new vendor contract on tuesday again"}]}"#
        let b = try VautaPrompts.verifyAnswer(two, sent: [39: T.all[0]], pool: QuoteAnchor.Pool(T.all))
        #expect(b.claims[0].verified && b.claims[0].citations == [200])
    }

    @Test func aLibraryAnswerIgnoresTheFillersOfEachSegmentsOwnLanguage() throws {
        // "um" is a filler in English and a word in Portuguese: with no single transcript language, each segment decides.
        let en = T.seg(1, 0, "so um we will approve the vendor contract on friday")
        let pt = T.seg(2, 0, "então um contrato novo foi aprovado na sexta")
        let enReply = #"{"found": true, "answer": "x", "claims": [{"text": "A", "citations": [1], "quote": "we will approve the vendor contract on friday"}]}"#
        let ptReply = #"{"found": true, "answer": "x", "claims": [{"text": "A", "citations": [2], "quote": "contrato novo foi aprovado na sexta"}]}"#
        let languages: [Int64: String] = [1: "en-US", 2: "pt-BR"]
        let a = try VautaPrompts.verifyAnswer(enReply, sent: [1: en], languages: languages)
        #expect(a.claims[0].verified)
        let withoutLanguages = try VautaPrompts.verifyAnswer(#"{"found": true, "answer": "x", "claims": [{"text": "A", "citations": [1], "quote": "so we will approve the vendor contract on friday"}]}"#, sent: [1: en])
        #expect(withoutLanguages.isUnverified, "no language: only the interjections no language uses as a word are ignored")
        let withLanguages = try VautaPrompts.verifyAnswer(#"{"found": true, "answer": "x", "claims": [{"text": "A", "citations": [1], "quote": "so we will approve the vendor contract on friday"}]}"#, sent: [1: en], languages: languages)
        #expect(withLanguages.claims[0].verified, "the English segment ignores its um")
        let b = try VautaPrompts.verifyAnswer(ptReply, sent: [2: pt], languages: languages)
        #expect(b.claims[0].verified)
        let skipsUm = #"{"found": true, "answer": "x", "claims": [{"text": "A", "citations": [2], "quote": "então contrato novo foi aprovado na sexta"}]}"#
        #expect(try VautaPrompts.verifyAnswer(skipsUm, sent: [2: pt], languages: languages).isUnverified, "in Portuguese um is a word and is not skipped")
    }

    @Test func aQuoteMovesOnlyWithinTheMeetingItWasCitedIn() {
        let a1 = T.seg(1, 0, "Opening remarks and the agenda for today"), a2 = T.seg(2, 5, "The vendor contract was approved by the board on Tuesday")
        let b1 = T.seg(3, 0, "Welcome to the planning session for the quarter"), b2 = T.seg(4, 5, "Nothing about contracts here at all")
        let pool = QuoteAnchor.Pool([a1, a2, b1, b2], groups: [1: 100, 2: 100, 3: 200, 4: 200])
        // Cited in meeting 200, but the words are in meeting 100: no move across meetings.
        #expect(QuoteAnchor.resolve(quote: "vendor contract was approved by the board", cited: 4, citedText: b2.text, pool: pool) == nil)
        // Cited in meeting 100: found in the same meeting.
        #expect(QuoteAnchor.resolve(quote: "vendor contract was approved by the board", cited: 1, citedText: a1.text, pool: pool)?.segment == 2)
    }

    @Test func theLibraryPoolHoldsEachMeetingAndTheMeetingBeingRecordedOnlyUpToTheQuestion() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let a = try await f.meeting(["Alpha one", "Alpha two"], locale: "en-US", outputLocale: "en-US")
        let b = try await f.meeting(["Beta one", "Beta two"], locale: "en-US", outputLocale: "en-US")
        let chat = ScriptedChat { _, _, _ in ScriptedChat.reply("{}") }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat))
        let aSegments = try await f.store.citableSegments(a), bSegments = try await f.store.citableSegments(b)
        let built = await service.buildAnchorPool(meetingID: nil, visible: [], meetings: [a, b], liveAtQuestion: (a, aSegments[0].id, 0), language: nil)
        let (pool, owner) = try #require(built)
        #expect(pool.segment(aSegments[0].id) != nil && pool.segment(aSegments[1].id) == nil, "a line said after the question is not in the pool")
        #expect(pool.segment(bSegments[1].id) != nil && owner[bSegments[1].id] == b && owner[aSegments[0].id] == a)
    }

    @Test func aLibraryAnswerMovesAQuoteToAnotherLineOfTheSameMeetingAndSaysWhichMeeting() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        var lines = (0..<80).map { "Filler line \($0) about nothing in particular at all, number \($0)" }
        lines[5] = "The Kobaltix budget was approved for the quarter"
        lines[70] = "Ana will send the numbers on Friday afternoon"
        let a = try await f.meeting(lines, locale: "en-US", outputLocale: "en-US")
        _ = try await f.meeting(["The Kobaltix budget was discussed again", "Ana will send the numbers on Friday afternoon too"], locale: "en-US", outputLocale: "en-US")
        let segments = try await f.store.citableSegments(a)
        let cited = segments[5].id, holder = segments[70].id
        let chat = ScriptedChat { _, _, _ in
            ScriptedChat.reply(#"{"found": true, "answer": "Ana sends them.", "claims": [{"text": "Ana sends the numbers", "citations": [\#(cited)], "quote": "Ana will send the numbers on Friday afternoon"}]}"#)
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536))
        let result = try await service.ask("What about the Kobaltix budget?", meetingID: nil)
        let claim = try #require(result.answer.claims.first)
        if result.sent[holder] == nil {
            #expect(claim.verified && claim.citations == [holder] && claim.reanchoredFrom == cited, "\(claim)")
            #expect(result.anchoredMeetings[holder] == a, "the moved citation says which meeting it is in")
        } else {
            #expect(claim.verified, "the line was among the passages already")
        }
    }

    @Test func aLineSaidWhileTheModelWritesIsNotWhereAQuoteMovesTo() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(["We reviewed the Kobaltix budget for the quarter", "Fine, we keep the budget as it is"], locale: "en-US", outputLocale: "en-US")
        let store = try #require(f.store)
        let chat = ScriptedChat { messages, _, _ in
            // Someone speaks while the model is writing, and the answer quotes that new line.
            _ = try await store.append(Segment(channel: .others, start: 90, end: 95, text: "Ana will send the numbers on Friday afternoon", isFinal: true), to: id)
            guard let (sid, _) = ScriptedChat.firstSegment(messages) else { return ScriptedChat.reply("{}") }
            return ScriptedChat.reply(#"{"found": true, "answer": "Ana sends the numbers.", "claims": [{"text": "Ana sends them", "citations": [\#(sid)], "quote": "Ana will send the numbers on Friday afternoon"}]}"#)
        }
        let service = LLMService(store: store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        await service.setRecording(true, meetingID: id)
        let result = try await service.ask("Who sends the numbers?", meetingID: id)
        #expect(result.answer.kind == .unverified, "the pool is what was visible when the question was asked")
        // The same quote of a line that was there before the question is moved to where it is.
        let before = ScriptedChat { messages, _, _ in
            guard let (sid, _) = ScriptedChat.firstSegment(messages) else { return ScriptedChat.reply("{}") }
            return ScriptedChat.reply(#"{"found": true, "answer": "Kept.", "claims": [{"text": "Kept", "citations": [\#(sid)], "quote": "Fine, we keep the budget as it is"}]}"#)
        }
        let second = LLMService(store: store, providers: TestProviders(chat: before, contextTokens: 65_536, integrated: true))
        await second.setRecording(true, meetingID: id)
        let moved = try await second.ask("Did we keep the budget?", meetingID: id)
        #expect(moved.answer.kind == .verified && moved.answer.claims[0].reanchoredFrom != nil)
    }

    @Test func aLineSavedWhileTheQuestionWaitsForTheLaneIsNotVisible() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(["We reviewed the Kobaltix budget for the quarter", "Fine, we keep the budget as it is"], locale: "en-US", outputLocale: "en-US")
        let store = try #require(f.store)
        let chat = ScriptedChat { messages, _, _ in
            guard let (sid, _) = ScriptedChat.firstSegment(messages) else { return ScriptedChat.reply("{}") }
            return ScriptedChat.reply(#"{"found": true, "answer": "Ana sends the numbers.", "claims": [{"text": "Ana sends them", "citations": [\#(sid)], "quote": "Ana will send the numbers on Friday afternoon"}]}"#)
        }
        let service = LLMService(store: store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        await service.setRecording(true, meetingID: id)
        // Another job holds the lane when the question is asked; a line is saved before it is released.
        try await service.acquire(.background)
        let question = Task { try await service.ask("Who sends the numbers?", meetingID: id) }
        try await Task.sleep(for: .milliseconds(300))
        _ = try await store.append(Segment(channel: .others, start: 90, end: 95, text: "Ana will send the numbers on Friday afternoon", isFinal: true), to: id)
        await service.release()
        let result = try await question.value
        #expect(result.answer.kind == .unverified, "the line was said after the question, so a quote of it is not verified")
    }
}
