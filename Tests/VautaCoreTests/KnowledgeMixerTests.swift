// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite struct KnowledgeMixerTests {
    private func c(_ score: Double, _ chars: Int = 300) -> KnowledgeMixer.Candidate { .init(score: score, characters: chars) }

    @Test func interleavesBothKindsByScore() {
        let choice = KnowledgeMixer.mix(meetings: [c(0.9), c(0.5), c(0.1)], documents: [c(0.8), c(0.4), c(0.3)], limit: 4, documentLimit: 6, maxCharacters: 10_000)
        // The best four overall are 0.9 (m0), 0.8 (d0), 0.5 (m1), 0.4 (d1).
        #expect(choice.meetings == [0, 1] && choice.documents == [0, 1])
    }

    @Test func neitherKindTakesMoreThanTwoThirdsOfTheSlots() {
        let strongDocs = KnowledgeMixer.mix(meetings: [c(0.1), c(0.09), c(0.08)], documents: [c(0.9), c(0.8), c(0.7), c(0.6)], limit: 3, documentLimit: 6, maxCharacters: 10_000)
        #expect(strongDocs.documents.count == 2 && strongDocs.meetings.count == 1)
        let strongMeetings = KnowledgeMixer.mix(meetings: [c(0.9), c(0.8), c(0.7), c(0.6)], documents: [c(0.1), c(0.09)], limit: 3, documentLimit: 6, maxCharacters: 10_000)
        #expect(strongMeetings.meetings.count == 2 && strongMeetings.documents.count == 1)
    }

    @Test func documentsNeverExceedTheirOwnLimit() {
        let choice = KnowledgeMixer.mix(meetings: [], documents: (0..<9).map { c(1 - Double($0) / 10) }, limit: 8, documentLimit: 6, maxCharacters: 100_000)
        #expect(choice.documents.count == 6)
        // With only documents the two-thirds guard does not apply, only the documents' own limit.
        let small = KnowledgeMixer.mix(meetings: [], documents: [c(1), c(0.9), c(0.8)], limit: 3, documentLimit: 2, maxCharacters: 100_000)
        #expect(small.documents == [0, 1])
    }

    @Test func theCharacterBudgetIsSharedAndASmallerPassageMayStillFit() {
        let choice = KnowledgeMixer.mix(meetings: [c(0.9, 2_500), c(0.5, 500)], documents: [c(0.8, 2_500), c(0.7, 600)], limit: 3, documentLimit: 2, maxCharacters: 3_200)
        // m0 (2500) fits; d0 (2500) does not; d1 (600) fits; m1 (500) is skipped, the limit of the budget is reached.
        #expect(choice.meetings == [0] && choice.documents == [1])
    }

    @Test func onTheSmallWindowAnAnswerHasAtMostThreeItemsAndTwoFromDocuments() {
        let budget = ContextBudget(contextTokens: 4_096)
        #expect(budget.askPassageLimit == 3 && budget.docPassageLimit == 2 && budget.docMaterialLimit == 1)
        let mid = ContextBudget(contextTokens: 12_000)
        #expect(mid.askPassageLimit == 8 && mid.docPassageLimit == 6 && mid.docMaterialLimit == 4)
        #expect(ContextBudget(contextTokens: 32_768).docPassageLimit == 6)
        let choice = KnowledgeMixer.mix(meetings: [c(0.2), c(0.1)], documents: [c(0.9), c(0.8), c(0.7)], limit: budget.askPassageLimit,
                                        documentLimit: budget.docPassageLimit, maxCharacters: budget.askPassageCharacters)
        #expect(choice.meetings.count + choice.documents.count == 3 && choice.documents.count <= 2)
    }

    @Test func aThreeItemPromptOnTheSmallWindowStaysUnderTheInputBudget() {
        let budget = ContextBudget(contextTokens: 4_096)
        let meetingText = String(repeating: "a meeting line about the quarterly plan. ", count: 18)   // ~740 characters
        let doc = DocumentPassage(id: 1, key: "k", fileID: 1, sourceID: 1, relPath: "Plan.pdf", fileName: "Plan.pdf", title: nil, format: .pdf, locator: .page(4),
                                  text: "Plan\n" + String(repeating: "A passage of the plan with figures and owners. ", count: 17), ocr: false, score: 1)
        let docs = VautaPrompts.documentsMessage([doc, doc])
        let instruction = VautaPrompts.askInstruction("What does the plan say about owners?", language: OutputLanguage(Locale(identifier: "en-US")), documents: true)
        let messages: [ChatMessage] = [.system(VautaPrompts.system), .user("<<<EXCERPTS FROM YOUR MEETINGS\n\(meetingText)\n>>>"), docs.message, instruction]
        #expect(PromptText.tokens(messages) <= budget.askInput)
    }
}

@Suite struct KnowledgeMixerMixedScaleTests {
    @Test func rankScoresMakeMeaningAndKeywordCorporaComparable() {
        // Meetings ranked by meaning (cosine ~1), documents by keywords (RRF ~0.03): raw scores let every meeting win.
        let meetings = (0..<6).map { KnowledgeMixer.Candidate(score: 1.2 - Double($0) * 0.05, characters: 100) }
        let documents = (0..<6).map { KnowledgeMixer.Candidate(score: 0.03 - Double($0) * 0.001, characters: 100) }
        let raw = KnowledgeMixer.mix(meetings: meetings, documents: documents, limit: 6, documentLimit: 6, maxCharacters: 10_000)
        #expect(raw.documents.count == 2)  // only the leftovers of the two-thirds cap
        let ranked = KnowledgeMixer.mix(
            meetings: KnowledgeMixer.rankScores(count: 6).map { .init(score: $0, characters: 100) },
            documents: KnowledgeMixer.rankScores(count: 6).map { .init(score: $0, characters: 100) },
            limit: 6, documentLimit: 6, maxCharacters: 10_000)
        #expect(ranked.meetings == [0, 1, 2])
        #expect(ranked.documents == [0, 1, 2])
    }
}
