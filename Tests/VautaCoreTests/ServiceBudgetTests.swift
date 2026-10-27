// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Service: context budgets")
struct ServiceBudgetTests {
    @Test func largeWindowKeepsTheCalibrated32KValues() {
        let b = ContextBudget(contextTokens: 32_768)
        #expect(!b.isSmall)
        #expect(b.minutesOutput == 10_000 && b.minutesInput == 18_000)
        #expect(b.blockInput == 11_000 && b.blockOutput == 1_200)
        #expect(b.liveWindow == 20_000 && b.askInput == 20_000 && b.askPassageLimit == 8 && b.entityLimit == 120)
        #expect(b.minutesInput + b.minutesOutput <= b.contextTokens)
    }

    @Test func smallWindowFitsEveryRequest() {
        let b = ContextBudget(contextTokens: 4_096)
        #expect(b.isSmall)
        #expect(b.minutesInput + b.minutesOutput + b.safety <= 4_096)
        #expect(b.blockInput + b.blockOutput + b.safety <= 4_096)
        #expect(b.askInput + b.askOutput + b.safety <= 4_096)
        #expect(b.liveWindow < 2_000 && b.askPassageLimit == 3 && b.entityLimit == 25)
        // The prompt overhead leaves real room for transcript in each block.
        let overhead = PromptText.tokens([.system(VautaPrompts.system), VautaPrompts.blockInstruction(OutputLanguage(Locale(identifier: "en-US")))])
        #expect(b.blockInput - overhead > 1_500)
    }

    @Test func raisedOutputNeedsRoom() {
        let big = ContextBudget(contextTokens: 32_768)
        #expect(big.raisedOutput(from: 1_500, promptTokens: 10_000) == 3_000)
        let small = ContextBudget(contextTokens: 4_096)
        #expect(small.raisedOutput(from: 1_200, promptTokens: 2_600) == nil)
        #expect(small.raisedOutput(from: 400, promptTokens: 1_500) == 800)
    }

    @Test func theUserIsAlwaysOfferedToTheModel() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["We review the plan."], locale: "en-US")
        let me = try await f.store.selfEntity()
        try await f.store.executeForTest("UPDATE entities SET last_seen = 0 WHERE id = ?", [.integer(me)])
        for i in 0..<40 {
            try await f.store.executeForTest("INSERT INTO entities(kind, name, confirmed, last_seen, created_at) VALUES ('person', ?, 1, ?, 0)",
                                       [.text("Person \(i)"), .real(Double(1_000 + i))])
        }
        let candidates = try await f.store.candidateEntities(id, limit: ContextBudget(contextTokens: 4_096).entityLimit)
        #expect(candidates.count == 25 && candidates.contains { $0.id == me })
    }
}
