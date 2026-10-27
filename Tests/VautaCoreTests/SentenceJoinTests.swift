// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Testing
@testable import VautaCore

@Suite struct SentenceJoinTests {
    @Test func closesAStatusWithoutFullStop() {
        let joined = ["No model chosen", "Set up a local model."].joinedAsSentences()
        #expect(joined.contains("No model chosen. Set up") || joined.contains("No model chosen。Set up"))
    }

    @Test func keepsSentencesThatAlreadyEnd() {
        #expect(["Done.", "Next."].joinedAsSentences().hasPrefix("Done."))
        #expect(!["Done.", "Next."].joinedAsSentences().contains(".."))
        #expect(["Done (really.)", "Next."].joinedAsSentences().contains("really.) "))
        #expect(["完了。", "次へ。"].joinedAsSentences().hasPrefix("完了。"))
    }

    @Test func singleAndEmptyPartsAreUntouched() {
        #expect(["No model chosen"].joinedAsSentences() == "No model chosen")
        #expect(["", "Next."].joinedAsSentences() == "Next.")
        #expect([String]().joinedAsSentences() == "")
    }
}
