// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The figures of an Ask answer's sentence: they must be in something the model read, else the answer is only partly verified.
@Suite("Ask: the figures of the answer's sentence")
struct AnswerFiguresTests {
    static func answer(_ sentence: String) -> VerifiedAnswer {
        VerifiedAnswer(answer: sentence, claims: [.init(id: "c0", text: "The budget was cut.", citations: [1], verified: true)], found: true)
    }

    @Test func aFigureInNothingTheModelReadIsNamed() {
        #expect(MinutesVerifier.unbackedFigures(item: "The budget is 50,000 euros", segment: "the budget is 5,000 euros") == ["50,000"])
        #expect(Set(MinutesVerifier.unbackedFigures(item: "预算是五十万", segment: "预算是五万")) == ["500000", "50"], "the whole and its multiplied part")
        #expect(MinutesVerifier.unbackedFigures(item: "It costs 12 and 12 again", segment: "nothing") == ["12"], "once")
        let checked = Self.answer("The budget was cut to 9,999 euros.").checkingFigures(against: "[S1 03:10] Ana: the budget was cut to 9,000 euros", languages: ["en"])
        #expect(checked.unbackedFigures == ["9,999"] && checked.kind == .partlyVerified)
    }

    @Test func whatTheModelReadBacksTheSentence() {
        let seen = """
            ## Weekly sync (2026-10-28)
            [S136 46:10] Speaker 5: we could meet at five, and the cost is ninety one euros
            [S137 46:20] Ana: the other quote said 1.500
            What did we agree?
            """
        for sentence in ["We agreed to meet at 5:00 PM.", "The cost is 91 euros, said in 46:10 (segments 136 and 137).",
                         "On October 28 the other quote was 1,500.", "Speaker 5 said it."] {
            let checked = Self.answer(sentence).checkingFigures(against: seen, languages: ["en"])
            #expect(checked.unbackedFigures.isEmpty && checked.kind == .verified, "\(sentence)")
        }
    }

    @Test func aRefusalOrAnAnswerNotYetIsLeftAlone() {
        let refusal = VerifiedAnswer(answer: "", claims: [], found: false)
        #expect(refusal.checkingFigures(against: "", languages: []) == refusal)
        let cut = Self.answer("It costs 77.").markedCutShort().checkingFigures(against: "nothing", languages: ["en"])
        #expect(cut.cutShort && cut.unbackedFigures == ["77"], "the flags it had stay")
        #expect(cut.markedCutShort().unbackedFigures == ["77"])
    }

    @Test func throughTheServiceTheSentenceIsCheckedAgainstTheRequest() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let meeting = try await f.meeting(["The Kobaltix budget was cut to nine thousand euros", "The office plants cost 340 euros"],
                                          locale: "en-US", outputLocale: "en-US")
        let segments = try await f.store.citableSegments(meeting)
        let first = try #require(segments.first)
        func asking(_ sentence: String) -> ScriptedChat {
            ScriptedChat { _, _, _ in
                ScriptedChat.reply(#"{"found": true, "answer": "\#(sentence)", "claims": [{"text": "The budget was cut.", "citations": [\#(first.id)], "quote": "\#(first.text)"}]}"#)
            }
        }
        let invented = LLMService(store: f.store, providers: TestProviders(chat: asking("The budget was cut to 9,500 euros."), contextTokens: 65_536))
        let wrong = try await invented.ask("What happened to the Kobaltix budget?", meetingID: meeting).answer
        #expect(wrong.kind == .partlyVerified && wrong.unbackedFigures == ["9,500"])
        // A true figure of another segment the model read is no reason to doubt the answer.
        let other = LLMService(store: f.store, providers: TestProviders(chat: asking("The budget was cut; the plants cost 340 euros."), contextTokens: 65_536))
        let right = try await other.ask("What happened to the Kobaltix budget?", meetingID: meeting).answer
        #expect(right.kind == .verified && right.unbackedFigures.isEmpty)
    }
}
