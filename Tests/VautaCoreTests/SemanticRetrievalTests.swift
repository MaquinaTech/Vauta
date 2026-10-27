// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Ask's retrieval with the search model ranking, end to end through a real in-memory store and documents index with stored
/// int8 vectors from a deterministic stand-in encoder.
@Suite("Ranking: documents with the search model")
struct SemanticDocumentSearchTests {
    private let en = Locale(identifier: "en")

    private func embed(_ fx: IndexFixture) async throws {
        let todo = try await fx.index.passagesNeedingVectors(space: ConceptEmbedder.space, limit: 1_000)
        let items = todo.compactMap { id, text in VectorIndex.quantize(ConceptEmbedder.vector(text)).map { (id: id, q: $0.q, scale: $0.scale) } }
        try await fx.index.storeVectors(items, space: ConceptEmbedder.space)
    }

    @Test func meaningFindsWhatNoWordMatches() async throws {
        let fx = try IndexFixture()
        try await fx.add("cats.txt", text: "Felines\nDomestic cats sleep for most of the day.")
        try await fx.add("cars.txt", text: "Engines\nElectric motors deliver torque instantly.")
        try await embed(fx)
        let hits = try await fx.index.search("kitten", queryVector: ConceptEmbedder.vector("kitten"), space: ConceptEmbedder.space, limit: 2,
                                             locale: en, mode: .semantic)
        #expect(hits.first?.fileName == "cats.txt")
    }

    @Test func aBareCodeIsFoundEvenWhenTheModelDoesNotRankItAndNearMissesAreNotBoosted() async throws {
        let fx = try IndexFixture()
        for i in 0..<60 { try await fx.add("bill\(i).txt", text: "Billing note \(i)\nInvoice payments and billing for the finance team, batch \(i).") }
        try await fx.add("target.txt", text: "Reference\nThe contract id is INV-2026-0417 and it was signed.")
        try await fx.add("near.txt", text: "Reference\nThe contract id is INV-2026-04170 and it was signed.")
        try await embed(fx)
        // A bare code says nothing to the model: the 60 billing passages are not it, and the exact match joins the candidates.
        let bare = try await fx.index.search("INV-2026-0417", queryVector: ConceptEmbedder.vector("INV-2026-0417"), space: ConceptEmbedder.space, limit: 3,
                                             locale: en, mode: .semantic)
        #expect(bare.first?.fileName == "target.txt")
        // The near miss shares two of the three words and so has a high cosine, but it is not boosted: the exact one is above.
        let nearScore = try #require(bare.first { $0.fileName == "near.txt" }?.score)
        let targetScore = try #require(bare.first { $0.fileName == "target.txt" }?.score)
        #expect(targetScore - nearScore > 0.2, "the exact match carries the 0.30 boost, the near miss none")
    }

    @Test func aRareNameBoostsItsPassages() async throws {
        let fx = try IndexFixture()
        for i in 0..<40 { try await fx.add("plan\(i).txt", text: "Plan \(i)\nThe budget and spending costs for the finance plan, item \(i).") }
        try await fx.add("priya.txt", text: "Notes\nPriya Zielinski reviewed the budget and spending costs for the finance plan.")
        try await embed(fx)
        // Every passage is about the budget, so the cosines are close and the name decides.
        let question = "budget costs Priya"
        let hits = try await fx.index.search(question, queryVector: ConceptEmbedder.vector(question), space: ConceptEmbedder.space, limit: 3,
                                             locale: en, mode: .semantic)
        #expect(hits.first?.fileName == "priya.txt")
        // The name is what lifted it: its cosine alone is no better than the others'.
        let score = try #require(hits.first?.score)
        let others = hits.dropFirst().map(\.score).max() ?? 0
        #expect(score - others > 0.1)
    }

    @Test func aPassageTheModelCouldNotEmbedDoesNotKeepCoverageIncomplete() async throws {
        let fx = try IndexFixture()
        try await fx.add("a.txt", text: "Felines\nDomestic cats sleep for most of the day.")
        try await fx.add("b.txt", text: "Engines\nElectric motors deliver torque instantly.")
        let todo = try await fx.index.passagesNeedingVectors(space: ConceptEmbedder.space, limit: 10)
        var items: [(id: Int64, q: Data, scale: Float)] = []
        for (n, (id, text)) in todo.enumerated() {
            if n == 0 { let m = VectorIndex.unembeddableMarker(dims: 256); items.append((id, m.q, m.scale)) }
            else if let (q, scale) = VectorIndex.quantize(ConceptEmbedder.vector(text)) { items.append((id, q, scale)) }
        }
        try await fx.index.storeVectors(items, space: ConceptEmbedder.space)
        let coverage = try await fx.index.vectorCoverage(space: ConceptEmbedder.space)
        #expect(coverage.isComplete && coverage.skipped == 1)
        #expect(try await fx.index.passagesNeedingVectors(space: ConceptEmbedder.space, limit: 10).isEmpty, "not tried again on every pass")
        let hits = try await fx.index.search("kitten", queryVector: ConceptEmbedder.vector("kitten"), space: ConceptEmbedder.space, limit: 5, locale: en, mode: .semantic)
        #expect(!hits.isEmpty)
    }

    @Test func keywordModeIgnoresVectorsAndTheDefaultKeepsTheFusion() async throws {
        let fx = try IndexFixture()
        try await fx.add("cats.txt", text: "Felines\nDomestic cats sleep for most of the day.")
        try await fx.add("cars.txt", text: "Engines\nElectric motors deliver torque instantly.")
        try await embed(fx)
        let keyword = try await fx.index.search("kitten", queryVector: ConceptEmbedder.vector("kitten"), space: ConceptEmbedder.space, limit: 2, locale: en, mode: .keyword)
        #expect(keyword.isEmpty, "no word matches and vectors are ignored")
        let fused = try await fx.index.search("kitten", queryVector: ConceptEmbedder.vector("kitten"), space: ConceptEmbedder.space, limit: 2, locale: en)
        #expect(fused.first?.fileName == "cats.txt", "the default is still the RRF fusion")
    }

    @Test func passagesWithoutAVectorYetJoinByTheirKeywordRank() async throws {
        let fx = try IndexFixture()
        try await fx.add("cats.txt", text: "Felines\nDomestic cats sleep for most of the day.")
        try await embed(fx)
        try await fx.add("fresh.txt", text: "Felines\nA kitten nap schedule was agreed this morning.")   // added after: no vector
        let hits = try await fx.index.search("kitten nap", queryVector: ConceptEmbedder.vector("kitten nap"), space: ConceptEmbedder.space, limit: 3,
                                             locale: en, mode: .semantic)
        #expect(hits.map(\.fileName).contains("fresh.txt"), "a new document stays findable while its vector is pending")
        let coverage = try await fx.index.vectorCoverage(space: ConceptEmbedder.space)
        #expect(coverage.total == 2 && coverage.covered == 1 && coverage.missing == 1)
    }

    @Test func coverageAndScopeCoverageCountPassages() async throws {
        let fx = try IndexFixture()
        let a = try await fx.add("a.txt", text: "Alpha\nThe launch plan for the release.")
        try await fx.add("b.txt", text: "Beta\nThe hiring plan for the quarter.")
        #expect(try await fx.index.vectorCoverage(space: ConceptEmbedder.space) == .init(covered: 0, total: 2))
        try await embed(fx)
        #expect(try await fx.index.vectorCoverage(space: ConceptEmbedder.space).isComplete)
        try await fx.add("c.txt", text: "Gamma\nA third file without a vector yet.")
        #expect(try await fx.index.isCovered(DocumentFilter([.init(source: 1, relPath: "a.txt")]), space: ConceptEmbedder.space))
        #expect(try await !fx.index.isCovered(DocumentFilter([.init(source: 1, relPath: "c.txt")]), space: ConceptEmbedder.space))
        _ = a
    }

    @Test func vectorsOfTheSearchModelCanBeDroppedByPrefix() async throws {
        let fx = try IndexFixture()
        try await fx.add("a.txt", text: "Alpha\nThe launch plan for the release.")
        try await embed(fx)
        #expect(try await fx.index.vectorCount() == 1)
        try await fx.index.dropVectors(modelPrefix: "embeddinggemma-2@")
        #expect(try await fx.index.vectorCount() == 0)
    }
}

@Suite("Ranking: meetings with the search model")
struct SemanticMeetingSearchTests {
    private func embed(_ fx: KnowledgeFixture, _ id: Int64, budget: ChunkBudget? = nil) async throws {
        let plan = try await fx.store.chunkPlan(id, budget: budget)
        let items = plan.map { c -> (start: Double, end: Double, q: Data, scale: Float, key: String) in
            let (q, scale) = VectorIndex.quantize(ConceptEmbedder.vector(c.text))!
            return (c.start, c.end, q, scale, MeetingStore.textKey(c.text))
        }
        try await fx.store.replaceChunks(id, items, space: ConceptEmbedder.space)
    }

    @Test func meaningFindsAPassageWithoutSharedWords() async throws {
        let fx = try KnowledgeFixture()
        let cats = try await fx.meeting(["Our feline research is going well.", "The cats slept all day."], locale: "en")
        let cars = try await fx.meeting(["Engine torque was measured today.", "The motors are quiet."], locale: "en")
        for id in [cats, cars] { try await embed(fx, id) }
        let found = try await fx.store.retrieve("kitten", queryVector: ConceptEmbedder.vector("kitten"), space: ConceptEmbedder.space,
                                                limit: 2, locale: Locale(identifier: "en"), mode: .semantic)
        #expect(found.first?.meeting.id == cats)
    }

    @Test func aCodeAndARareNameAreFoundEvenOutsideTheVectorTop() async throws {
        let fx = try KnowledgeFixture()
        var billing: [Int64] = []
        for i in 0..<55 { billing.append(try await fx.meeting(["Invoice payments and billing review number \(i).", "The finance team approved the invoices."], locale: "en")) }
        let target = try await fx.meeting(["The reference is INV-2026-0417 for the supplier.", "Priya Zielinski will confirm it."], locale: "en")
        let near = try await fx.meeting(["The reference is INV-2026-04170 for the supplier.", "Nothing else to add."], locale: "en")
        for id in billing + [target, near] { try await embed(fx, id) }
        let en = Locale(identifier: "en")
        let bare = try await fx.store.retrieve("INV-2026-0417", queryVector: ConceptEmbedder.vector("INV-2026-0417"), space: ConceptEmbedder.space,
                                               limit: 3, locale: en, mode: .semantic)
        #expect(bare.first?.meeting.id == target)
        let nearScore = bare.first { $0.meeting.id == near }?.score ?? 0
        #expect((bare.first?.score ?? 0) - nearScore > 0.2, "only the exact match is boosted")
        let byName = try await fx.store.retrieve("Priya", queryVector: ConceptEmbedder.vector("Priya"), space: ConceptEmbedder.space,
                                                 limit: 3, locale: en, mode: .semantic)
        #expect(byName.first?.meeting.id == target)
    }

    @Test func aCodeInTheOverlapSegmentBoostsBothChunksThatHoldIt() async throws {
        let fx = try KnowledgeFixture()
        // Segments start at 0, 10, 20, 30. Chunk A holds the first two, chunk B the last three: segment 1 is in both.
        let id = try await fx.meeting(["The cats slept all day.", "The reference is INV-2026-0417 for the supplier.",
                                       "The budget and spending costs were reviewed.", "Finance money is tight."], locale: "en")
        func item(_ start: Double, _ end: Double, _ text: String) -> (start: Double, end: Double, q: Data, scale: Float, key: String) {
            let (q, scale) = VectorIndex.quantize(ConceptEmbedder.vector(text))!
            return (start, end, q, scale, MeetingStore.textKey(text))
        }
        try await fx.store.replaceChunks(id, [item(0, 18, "cats kitten feline"), item(10, 38, "budget spending costs finance")], space: ConceptEmbedder.space)
        // B is the closer chunk by meaning; the code is in the overlap. If only A were boosted (+0.30) A would win; both are boosted.
        let found = try await fx.store.retrieve("budget INV-2026-0417", queryVector: ConceptEmbedder.vector("budget INV-2026-0417"),
                                                space: ConceptEmbedder.space, limit: 1, locale: Locale(identifier: "en"), mode: .semantic)
        #expect(found.first?.segments.contains { $0.text.contains("spending") } == true)
    }

    @Test func aMeetingWithoutChunksYetStaysFindableByKeywords() async throws {
        let fx = try KnowledgeFixture()
        let old = try await fx.meeting(["The launch plan and the release rollout.", "Shipping is next week."], locale: "en")
        try await embed(fx, old)
        let fresh = try await fx.meeting(["The zebra migration schedule was agreed.", "Nothing else."], locale: "en")   // no chunks
        let found = try await fx.store.retrieve("zebra migration", queryVector: ConceptEmbedder.vector("zebra migration"), space: ConceptEmbedder.space,
                                                limit: 3, locale: Locale(identifier: "en"), mode: .semantic)
        #expect(found.contains { $0.meeting.id == fresh })
        let coverage = try await fx.store.vectorCoverage(space: ConceptEmbedder.space)
        #expect(coverage == .init(covered: 1, total: 2))
        #expect(try await fx.store.isCovered(old, space: ConceptEmbedder.space))
        #expect(try await !fx.store.isCovered(fresh, space: ConceptEmbedder.space))
    }

    @Test func aMeetingWhoseChunksAreInAnotherSpaceStaysFindableByKeywords() async throws {
        let fx = try KnowledgeFixture()
        let old = try await fx.meeting(["The launch plan and the release rollout.", "Shipping is next week."], locale: "en")
        try await embed(fx, old)
        // Embedded by a model server earlier: its chunks exist, but not in the search model's space.
        let other = EmbeddingSpace(model: "nomic-embed-text", dimensions: 256)
        let foreign = try await fx.meeting(["The zebra migration schedule was agreed.", "Nothing else."], locale: "en")
        let (q, scale) = VectorIndex.quantize(ConceptEmbedder.vector("zebra"))!
        try await fx.store.replaceChunks(foreign, [(start: 0, end: 18, q: q, scale: scale, key: "k")], space: other)
        let found = try await fx.store.retrieve("zebra migration", queryVector: ConceptEmbedder.vector("zebra migration"), space: ConceptEmbedder.space,
                                                limit: 3, locale: Locale(identifier: "en"), mode: .semantic)
        #expect(found.contains { $0.meeting.id == foreign })
    }

    @Test func insideOneMeetingOnlyThatMeetingIsSearched() async throws {
        let fx = try KnowledgeFixture()
        let a = try await fx.meeting(["The launch plan and the release rollout."], locale: "en")
        let b = try await fx.meeting(["The launch plan and the release rollout again."], locale: "en")
        for id in [a, b] { try await embed(fx, id) }
        let found = try await fx.store.retrieve("release", queryVector: ConceptEmbedder.vector("release"), within: a, space: ConceptEmbedder.space,
                                                limit: 5, locale: Locale(identifier: "en"), mode: .semantic)
        #expect(!found.isEmpty && found.allSatisfy { $0.meeting.id == a })
    }

    @Test func keywordModeIgnoresVectors() async throws {
        let fx = try KnowledgeFixture()
        let cats = try await fx.meeting(["Our feline research is going well.", "The cats slept all day."], locale: "en")
        try await embed(fx, cats)
        let keyword = try await fx.store.retrieve("kitten", queryVector: ConceptEmbedder.vector("kitten"), space: ConceptEmbedder.space,
                                                  limit: 2, locale: Locale(identifier: "en"), mode: .keyword)
        #expect(keyword.isEmpty)
        let fused = try await fx.store.retrieve("kitten", queryVector: ConceptEmbedder.vector("kitten"), space: ConceptEmbedder.space,
                                                limit: 2, locale: Locale(identifier: "en"))
        #expect(fused.first?.meeting.id == cats)
    }

    @Test func relatedMeetingsAreTheOnesWithTheBestChunkAboveTheThreshold() async throws {
        let fx = try KnowledgeFixture()
        let a = try await fx.meeting(["The launch plan and the release rollout."], locale: "en")
        let b = try await fx.meeting(["The release rollout and the shipping date."], locale: "en")
        let c = try await fx.meeting(["The cats slept all day."], locale: "en")
        for id in [a, b, c] { try await embed(fx, id) }
        let related = try await fx.store.relatedMeetings(queryVector: ConceptEmbedder.vector("launch release rollout"), space: ConceptEmbedder.space, excluding: a)
        #expect(related.map(\.meeting.id) == [b], "the cat meeting is below the threshold and this meeting is excluded")
    }

    @Test func relatedMeetingsAreFoundEvenWhenTheOpenMeetingHasMoreThanEightyChunks() async throws {
        let fx = try KnowledgeFixture()
        let long = try await fx.meeting(["The launch plan and the release rollout."], locale: "en")
        let other = try await fx.meeting(["The release rollout and the shipping date."], locale: "en")
        // A two-hour meeting: 100 chunks, all of them closer to its own topics than anything else.
        let items = (0..<100).map { i -> (start: Double, end: Double, q: Data, scale: Float, key: String) in
            let (q, scale) = VectorIndex.quantize(ConceptEmbedder.vector("launch release rollout shipping number \(i)"))!
            return (Double(i) * 70, Double(i) * 70 + 69, q, scale, "k\(i)")
        }
        try await fx.store.replaceChunks(long, items, space: ConceptEmbedder.space)
        try await embed(fx, other)
        let related = try await fx.store.relatedMeetings(queryVector: ConceptEmbedder.vector("launch release rollout shipping"), space: ConceptEmbedder.space, excluding: long)
        #expect(related.map(\.meeting.id) == [other])
    }

    @Test func aChunkTheModelCouldNotEmbedIsMarkedSoTheMeetingStillCountsAndTheMarkerIsNeverASearchResult() async throws {
        let fx = try KnowledgeFixture()
        let id = try await fx.meeting(["The cats slept all day.", "Invoice INV-2026-0417 was paid."], locale: "en")
        let (q, scale) = VectorIndex.quantize(ConceptEmbedder.vector("cats slept"))!
        let marker = VectorIndex.unembeddableMarker(dims: 256)
        try await fx.store.replaceChunks(id, [(0, 5, q, scale, "a"), (6, 12, marker.q, marker.scale, "b")], space: ConceptEmbedder.space)
        let coverage = try await fx.store.vectorCoverage(space: ConceptEmbedder.space)
        #expect(coverage.isComplete && coverage.skipped == 1 && coverage.covered == 1)
        let hits = try await fx.store.relatedMeetings(queryVector: ConceptEmbedder.vector("cats slept"), space: ConceptEmbedder.space, excluding: -1)
        #expect(hits.count == 1, "the marker is not in the index: it cannot score")
        // Only markers: the meeting is covered too (nothing was embeddable), instead of waiting forever.
        let only = try await fx.meeting(["   "], locale: "en")
        try await fx.store.replaceChunks(only, [(0, 5, marker.q, marker.scale, "c")], space: ConceptEmbedder.space)
        #expect(try await fx.store.isCovered(only, space: ConceptEmbedder.space))
        #expect(SemanticRanker.mode(space: ConceptEmbedder.space, coverage: try await fx.store.vectorCoverage(space: ConceptEmbedder.space), reachedBefore: false) == .semantic)
    }

    @Test func chunksFitTheModelsSequenceLimitWhenABudgetIsGiven() async throws {
        let fx = try KnowledgeFixture()
        // 40 lines of 6 words, 3 s apart: ~130 s windows of about 40 lines without a budget.
        let lines = (0..<44).map { "line \($0) has exactly six words" }
        let id = try await fx.meeting(lines, locale: "en")
        let count: @Sendable (String) -> Int = { $0.split(separator: " ").count }
        let plain = try await fx.store.chunkPlan(id)
        let budgeted = try await fx.store.chunkPlan(id, budget: ChunkBudget(limit: 60, count: count))
        #expect(plain.count < budgeted.count)
        for chunk in budgeted {
            let lineCount = chunk.text.split(separator: "\n").count
            // Each line is "Others: line N has exactly six words" (8 words) plus a newline token.
            #expect(chunk.text.split(separator: "\n").map { count(String($0)) }.reduce(0, +) + (lineCount - 1) <= 60 || lineCount == 1)
        }
        // Without a budget the plan is exactly the one server spaces use.
        let same = try await fx.store.chunkPlan(id, budget: nil)
        #expect(same.map(\.text) == plain.map(\.text) && same.map(\.start) == plain.map(\.start))
        // Overlap: one segment shared between neighbours.
        #expect(budgeted.count > 1 && budgeted[1].start < budgeted[0].end + 1)
    }

    @Test func aSingleLineOverTheBudgetIsItsOwnChunk() async throws {
        let fx = try KnowledgeFixture()
        let long = Array(repeating: "word", count: 200).joined(separator: " ")
        let id = try await fx.meeting([long, "short one", "short two"], locale: "en")
        let plan = try await fx.store.chunkPlan(id, budget: ChunkBudget(limit: 50, count: { $0.split(separator: " ").count }))
        #expect(plan.first?.text.contains(long) == true && plan.first?.text.split(separator: "\n").count == 1)
        #expect(plan.count >= 2)
    }

    @Test func chunkFreshnessUsesTheSamePlan() async throws {
        let fx = try KnowledgeFixture()
        let lines = (0..<44).map { "line \($0) has exactly six words" }
        let id = try await fx.meeting(lines, locale: "en")
        let budget = ChunkBudget(limit: 60, count: { $0.split(separator: " ").count })
        try await embed(fx, id, budget: budget)
        let fresh = try await fx.store.chunksOutOfDate(id, budget: budget)
        #expect(!fresh, "stable with the budget it was made with")
        let withoutBudget = try await fx.store.chunksOutOfDate(id, budget: nil)
        #expect(withoutBudget, "another plan means other chunks")
    }

    @Test func droppingTheModelsChunksLeavesOtherSpaces() async throws {
        let fx = try KnowledgeFixture()
        let id = try await fx.meeting(["The launch plan."], locale: "en")
        try await embed(fx, id)
        let other = EmbeddingSpace(model: "nomic-embed-text", dimensions: 256)
        let id2 = try await fx.meeting(["The hiring plan."], locale: "en")
        let item = [(start: 0.0, end: 5.0, q: VectorIndex.quantize(ConceptEmbedder.vector("hiring"))!.q, scale: VectorIndex.quantize(ConceptEmbedder.vector("hiring"))!.scale, key: "k")]
        try await fx.store.replaceChunks(id2, item, space: other)
        try await fx.store.dropChunks(modelPrefix: "embeddinggemma-2@")
        let first = try await fx.store.hasChunks(id), second = try await fx.store.hasChunks(id2)
        #expect(!first && second)
    }
}
