// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

/// The line under an answer over the library: what was searched first, what reached the model next, what could not be searched last.
@Suite("Ask: the coverage line")
@MainActor
struct AskCoverageTextTests {
    @Test func itSaysWhatWasSearchedThenWhatReachedTheModel() throws {
        let day = Date(timeIntervalSince1970: 1_793_000_000)
        let full = try #require(AskModel.coverageText(AskCoverage(searched: 3, first: day, last: day, purged: 2, keywordsOnly: 1, sentMeetings: 2, sentDocuments: 4)))
        let parts = ["Searched 3 meetings (", "1 of them aren’t indexed for search by meaning yet", "Passages from 2 meetings and 4 documents were sent",
                     "2 older meetings no longer have a transcript"]
        let at = try parts.map { try #require(full.range(of: $0)?.lowerBound, "\($0) in \(full)") }
        #expect(at == at.sorted())

        #expect(AskModel.coverageText(AskCoverage(searched: 5, first: day, last: day, sentMeetings: 2))?.hasSuffix("Passages from 2 meetings were sent to the model.") == true)
        #expect(AskModel.coverageText(AskCoverage(searched: 0, sentDocuments: 2)) == "Passages from 2 documents were sent to the model.")
        #expect(AskModel.coverageText(AskCoverage(searched: 0)) == nil, "nothing to say")
    }
}
