// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The pure rules of the ranking: which items of a question are exact, how a candidate is boosted, and when the search model ranks.
@Suite("Ranking: exact items, boosts and modes")
struct SemanticRankerTests {
    @Test(arguments: [
        ("What happened with INV-2026-0417?", ["INV-2026-0417"]),
        ("status of PO-48213", ["PO-48213"]),
        ("see REF 0123/B please", ["0123/B"]),
        ("CASE#000123 follow up", ["CASE#000123"]),
        ("ticket 482913 is open", ["482913"]),
        ("TKT-9981 and TKT-9982", ["TKT-9981", "TKT-9982"]),
        ("build A100 passed", ["A100"]),
    ] as [(String, [String])])
    func codesAreRecognised(question: String, expected: [String]) {
        #expect(SemanticRanker.codes(in: question) == expected)
    }

    @Test(arguments: ["What about Q3?", "the year 2026", "an A4 page", "H2 results", "version 12", "50% of 12345", "just words here", "5-10",
                          "meeting on 2026-10-12", "due 12/10/2026", "moved to 12/10", "in 2026-10", "release 1.2.3", "total 500.00", "1.500.000 euros", "on 12.10.2026"])
    func ordinaryNumbersAndShortTagsAreNotCodes(question: String) {
        #expect(SemanticRanker.codes(in: question).isEmpty, "\(question)")
    }

    @Test func aDateOrVersionWithLettersOrAHashStaysACode() {
        #expect(SemanticRanker.codes(in: "see INV-2026-10-12") == ["INV-2026-10-12"])
        #expect(SemanticRanker.codes(in: "build v1.2.3 failed") == ["v1.2.3"])
        #expect(SemanticRanker.codes(in: "ticket 0123/45 and 2026-10-12") == ["0123/45"], "the date next to a code is not one")
        #expect(SemanticRanker.codes(in: "SSN 123-45-6789 or 555-1234") == ["123-45-6789", "555-1234"], "numbers that are not dates stay codes")
    }

    @Test func aCodeBecomesAPhraseOfAdjacentWords() {
        #expect(SemanticRanker.phrase("PO-48213") == "\"po 48213\"")
        #expect(SemanticRanker.phrase("INV-2026-0417") == "\"inv 2026 0417\"")
        #expect(SemanticRanker.phrase("0123/B") == "\"0123 b\"")
        #expect(SemanticRanker.phrase("---") == nil)
    }

    @Test func namesAreCapitalisedWordsOfThreeLettersOrMoreOrALoneWord() {
        #expect(SemanticRanker.nameCandidates(in: "What did Priya say about the budget?", excluding: []) == ["Priya"], "“What” is capitalised only because it opens the question")
        #expect(SemanticRanker.nameCandidates(in: "Wer hat mit Priya gesprochen?", excluding: []) == ["Priya"])
        #expect(SemanticRanker.nameCandidates(in: "Qué dijo Priya? Cuándo fue?", excluding: []) == ["Priya"])
        #expect(SemanticRanker.nameCandidates(in: "Ana, what did she say?", excluding: []) == ["Ana"], "a name may open the question")
        #expect(SemanticRanker.nameCandidates(in: "priya", excluding: []) == ["priya"], "a lone word, whatever its case")
        #expect(SemanticRanker.nameCandidates(in: "the budget review", excluding: []).isEmpty)
        #expect(SemanticRanker.nameCandidates(in: "NASA and IBM", excluding: []).isEmpty, "all capitals is not a name")
        #expect(SemanticRanker.nameCandidates(in: "Ana owns PO-48213", excluding: ["PO-48213"]) == ["Ana"])
        #expect(SemanticRanker.nameCandidates(in: "Status of PO-48213", excluding: ["PO-48213"]) == ["Status"], "the code's own words are never names")
        #expect(SemanticRanker.nameCandidates(in: "Zoë Müller", excluding: []) == ["Zoë", "Müller"])
        // Text without spaces is not segmented by the index: no names.
        #expect(SemanticRanker.nameCandidates(in: "田中さんは何と言いましたか", excluding: []).isEmpty)
    }

    @Test func aNameIsRareWhenItAppearsInAFewRows() {
        #expect(SemanticRanker.rareLimit(rows: 1_000) == 3)
        #expect(SemanticRanker.rareLimit(rows: 60_000) == 3)
        #expect(SemanticRanker.rareLimit(rows: 200_000) == 10)
    }

    @Test func boostsAddToTheCosine() {
        #expect(SemanticRanker.boost(codesMatched: 1, codesTotal: 1, namesMatched: 0, namesTotal: 0) == 0.30)
        #expect(SemanticRanker.boost(codesMatched: 1, codesTotal: 2, namesMatched: 0, namesTotal: 0) == 0, "every code is required")
        #expect(SemanticRanker.boost(codesMatched: 0, codesTotal: 0, namesMatched: 1, namesTotal: 2) == 0.075)
        #expect(abs(SemanticRanker.boost(codesMatched: 2, codesTotal: 2, namesMatched: 2, namesTotal: 2) - 0.45) < 1e-12)
        #expect(SemanticRanker.boost(codesMatched: 0, codesTotal: 0, namesMatched: 0, namesTotal: 0) == 0)
    }

    @Test func aKeywordOnlyCandidateGetsTheCosineOfTheSameRank() {
        let v: [Float] = [0.9, 0.8, 0.5]
        #expect(SemanticRanker.pseudoScore(rank: 0, vectorScores: v) == Double(Float(0.9)))
        #expect(SemanticRanker.pseudoScore(rank: 2, vectorScores: v) == 0.5)
        #expect(SemanticRanker.pseudoScore(rank: 9, vectorScores: v) == 0.5, "past the end: the last one")
        #expect(SemanticRanker.pseudoScore(rank: 0, vectorScores: []) == 0)
    }

    @Test func orderIsByScoreThenByKey() {
        let ordered = SemanticRanker.order(["b": 0.5, "a": 0.5, "c": 0.9, "d": 0.1])
        #expect(ordered.map(\.key) == ["c", "a", "b", "d"])
    }

    // MARK: Modes

    private let gemma = EmbeddingSpace(model: SearchModelManifest.spaceModel, dimensions: 256)
    private let server = EmbeddingSpace(model: "nomic-embed-text", dimensions: 768)
    private func coverage(_ covered: Int, _ total: Int) -> SemanticRanker.Coverage { .init(covered: covered, total: total) }

    @Test func withoutAQueryVectorTheKeywordPathRuns() {
        #expect(SemanticRanker.mode(space: nil, coverage: coverage(10, 10), reachedBefore: true) == .keyword)
    }

    @Test func aModelServersVectorsKeepTheFusionWhateverTheCoverage() {
        #expect(SemanticRanker.mode(space: server, coverage: coverage(0, 100), reachedBefore: false) == .rrf)
        #expect(SemanticRanker.mode(space: server, coverage: coverage(100, 100), reachedBefore: true) == .rrf)
    }

    @Test func whileBackfillingKeywordSearchRanksEvenWhenMostIsDone() {
        #expect(SemanticRanker.mode(space: gemma, coverage: coverage(0, 100), reachedBefore: false) == .keyword)
        #expect(SemanticRanker.mode(space: gemma, coverage: coverage(99, 100), reachedBefore: false) == .keyword)
        #expect(SemanticRanker.mode(space: gemma, coverage: coverage(0, 0), reachedBefore: false) == .keyword, "nothing to rank")
    }

    @Test func completeCoverageRanksBySemantics() {
        #expect(SemanticRanker.mode(space: gemma, coverage: coverage(100, 100), reachedBefore: false) == .semantic)
    }

    @Test func aSmallBacklogAfterCompleteCoverageIsTolerated() {
        // A meeting recorded minutes ago: one missing of 100, coverage was reached once.
        #expect(SemanticRanker.mode(space: gemma, coverage: coverage(99, 100), reachedBefore: true) == .semantic)
        #expect(SemanticRanker.mode(space: gemma, coverage: coverage(50_000, 50_040), reachedBefore: true) == .semantic, "40 items")
        #expect(SemanticRanker.mode(space: gemma, coverage: coverage(9_850, 10_000), reachedBefore: true) == .semantic, "150 items are 1.5%: within the 2%")
        #expect(SemanticRanker.mode(space: gemma, coverage: coverage(9_700, 10_000), reachedBefore: true) == .keyword, "300 items, 3%")
        #expect(SemanticRanker.mode(space: gemma, coverage: coverage(98_500, 100_000), reachedBefore: true) == .semantic, "1,500 items are 1.5%")
        #expect(SemanticRanker.mode(space: gemma, coverage: coverage(97_000, 100_000), reachedBefore: true) == .keyword, "3,000 items")
        #expect(SemanticRanker.mode(space: gemma, coverage: coverage(980, 1_000), reachedBefore: true) == .semantic, "20 of 1,000 is 2%")
        #expect(SemanticRanker.mode(space: gemma, coverage: coverage(9_790, 10_000), reachedBefore: true) == .keyword, "210 items")
    }

    @Test func aBigFolderAddedAfterwardsFlipsBackToKeywordUntilItIsIndexed() {
        #expect(SemanticRanker.mode(space: gemma, coverage: coverage(5_000, 20_000), reachedBefore: true) == .keyword)
    }

    @Test func insideOneMeetingOrFilterItDependsOnThatScopeOnly() {
        #expect(SemanticRanker.mode(space: gemma, coverage: coverage(0, 100), reachedBefore: false, scopeCovered: true) == .semantic)
        #expect(SemanticRanker.mode(space: gemma, coverage: coverage(100, 100), reachedBefore: true, scopeCovered: false) == .keyword)
        #expect(SemanticRanker.mode(space: server, coverage: coverage(0, 0), reachedBefore: false, scopeCovered: false) == .rrf)
    }
}
