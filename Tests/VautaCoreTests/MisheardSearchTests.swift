// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Ask finds a person or project of the question where the transcript misheard the name, through the corrections the context graph
/// found: at half the weight while one is open, as the name once the person accepted it, and no more once it was turned down.
@Suite("Ask · misheard names")
struct MisheardSearchTests {
    private let en = Locale(identifier: "en")
    private let question = "What did we decide about Kobaltix?"

    /// A meeting that never says "Kobaltix" right, analyzed in English: the corrector offers "Cobaltics" for it.
    private func misheard(_ f: KnowledgeFixture) async throws -> (meeting: Int64, kobaltix: Int64) {
        let kobaltix = try await f.store.saveEntity(EntityDraft(kind: .project, name: "Kobaltix"))
        let m = try await f.meeting(["Good morning everyone.", "Then we asked Cobaltics about the launch date.", "Lunch is at noon today."],
                                    locale: "en")
        _ = try await f.store.analyze(m, locale: Locale(identifier: "en-US"))
        return (m, kobaltix)
    }

    private func correction(_ f: KnowledgeFixture, _ m: Int64) async throws -> Suggestion {
        try #require(try await f.store.suggestions(m).first { $0.kind == .correction && $0.surface == "Cobaltics" })
    }

    private func saysCobaltics(_ passages: [RetrievedPassage], in meeting: Int64? = nil) -> Bool {
        passages.contains { p in (meeting == nil || p.meeting.id == meeting) && p.segments.contains { $0.text.contains("Cobaltics") } }
    }

    @Test func anOpenCorrectionBringsItsLines() async throws {
        let f = try KnowledgeFixture()
        let (m, kobaltix) = try await misheard(f)
        #expect(try await correction(f, m).candidates.first?.entityID == kobaltix)
        // No word of the question is in the transcript: only the correction finds the line, by keywords and in Apple's small windows.
        #expect(saysCobaltics(try await f.store.retrieve(question, queryVector: nil, limit: 3, locale: en)))
        #expect(saysCobaltics(try await f.store.retrieve(question, queryVector: nil, limit: 3, locale: en, windows: .standard)))
        // A question about something else does not bring it.
        #expect(!saysCobaltics(try await f.store.retrieve("What did we decide about the budget?", queryVector: nil, limit: 3, locale: en)))
    }

    @Test func anOpenCorrectionCountsOnlyInItsMeeting() async throws {
        let f = try KnowledgeFixture()
        _ = try await misheard(f)
        // Never analyzed, so the corrector has not looked at it: nothing says its "Cobaltics" is Kobaltix.
        let other = try await f.meeting(["Cobaltics shipped the first build.", "Nothing else to add."], locale: "en")
        #expect(!saysCobaltics(try await f.store.retrieve(question, queryVector: nil, limit: 5, locale: en), in: other))
    }

    @Test func aCorrectionTurnedDownCountsNoMore() async throws {
        let f = try KnowledgeFixture()
        let (m, _) = try await misheard(f)
        try await f.store.resolveSuggestion(try await correction(f, m).id, entity: nil)
        #expect(!saysCobaltics(try await f.store.retrieve(question, queryVector: nil, limit: 3, locale: en)))
        #expect(!saysCobaltics(try await f.store.retrieve(question, queryVector: nil, limit: 3, locale: en, windows: .standard)))
    }

    @Test func anAcceptedCorrectionCountsAsTheNameInEveryMeeting() async throws {
        let f = try KnowledgeFixture()
        let (m, kobaltix) = try await misheard(f)
        try await f.store.resolveSuggestion(try await correction(f, m).id, entity: kobaltix)
        // The spelling is now a name of Kobaltix: a meeting the corrector never looked at says it too.
        let other = try await f.meeting(["Cobaltics shipped the first build.", "Nothing else to add."], locale: "en")
        let found = try await f.store.retrieve(question, queryVector: nil, limit: 5, locale: en)
        #expect(saysCobaltics(found, in: m))
        #expect(saysCobaltics(found, in: other))
    }

    @Test func theSearchModelRankingTakesThemAsCandidatesWithHalfTheLift() async throws {
        let f = try KnowledgeFixture()
        let (m, _) = try await misheard(f)
        // Sixty meetings closer to the question by meaning fill the vector top 50: the misheard line is not among them.
        var others: [Int64] = []
        for i in 0..<60 { others.append(try await f.meeting(["Launch release rollout \(i).", "Shipping launch."], locale: "en")) }
        for id in others + [m] { try await embed(f, id) }
        let q = "Kobaltix launch"
        let found = try await f.store.retrieve(q, queryVector: ConceptEmbedder.vector(q), space: ConceptEmbedder.space, limit: 80, locale: en,
                                               mode: .semantic)
        let passage = try #require(found.first { p in p.segments.contains { $0.text.contains("Cobaltics") } },
                                   "the open correction makes the line a candidate")
        let cosine = try #require(passage.cosine, "with its own cosine")
        #expect(abs(passage.score - cosine - 0.04) < 0.000_1, "half the 0.08 of a name the transcript got right")
    }

    private func embed(_ f: KnowledgeFixture, _ id: Int64) async throws {
        let plan = try await f.store.chunkPlan(id, budget: nil)
        let items = plan.map { c -> (start: Double, end: Double, q: Data, scale: Float, key: String) in
            let (q, scale) = VectorIndex.quantize(ConceptEmbedder.vector(c.text))!
            return (c.start, c.end, q, scale, MeetingStore.textKey(c.text))
        }
        try await f.store.replaceChunks(id, items, space: ConceptEmbedder.space)
    }
}
