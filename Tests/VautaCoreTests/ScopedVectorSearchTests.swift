// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// A search within one meeting or some files ranks that scope's own vectors exactly: a library of thousands of closer passages on
/// the same topic elsewhere must not push them out of a top K that is cut before the scope is applied.
@Suite("Ranking: a search within a scope")
struct ScopedVectorSearchTests {
    private static let question = "release rollout"
    private let en = Locale(identifier: "en")

    private static func item(_ start: Double, _ end: Double, _ text: String) -> (start: Double, end: Double, q: Data, scale: Float, key: String) {
        let (q, scale) = VectorIndex.quantize(ConceptEmbedder.vector(text))!
        return (start, end, q, scale, MeetingStore.textKey(text))
    }

    /// A meeting about the release, with three chunks of different closeness to the question (segments start at 0, 10 … 50).
    private func target(_ fx: KnowledgeFixture) async throws -> Int64 {
        let id = try await fx.meeting(["The launch plan and the release rollout were agreed.", "The supplier sends the checklist.",
                                       "The budget and spending costs were reviewed.", "Finance money is tight.",
                                       "The shipping date moves to the release week.", "The cats slept all day."], locale: "en")
        try await fx.store.replaceChunks(id, [Self.item(0, 18, "launch release rollout supplier checklist"),
                                              Self.item(20, 38, "budget spending costs finance"),
                                              Self.item(40, 58, "shipping release week cats")], space: ConceptEmbedder.space)
        return id
    }

    /// Other meetings whose chunks are all the question itself: closer than any chunk of the target.
    private func decoys(_ fx: KnowledgeFixture, meetings: Int = 3, chunks: Int = 1_000) async throws {
        let (q, scale) = VectorIndex.quantize(ConceptEmbedder.vector(Self.question))!
        for m in 0..<meetings {
            let id = try await fx.meeting(["Another release rollout review, number \(m)."], locale: "en")
            let items = (0..<chunks).map { i in (start: Double(i) * 100, end: Double(i) * 100 + 99, q: q, scale: scale, key: "d\(i)") }
            try await fx.store.replaceChunks(id, items, space: ConceptEmbedder.space)
        }
    }

    @Test(arguments: [SemanticRanker.Mode.semantic, .rrf])
    func aMeetingsOwnPassagesAreFoundWhateverTheRestOfTheLibraryHolds(mode: SemanticRanker.Mode) async throws {
        let alone = try KnowledgeFixture(), crowded = try KnowledgeFixture()
        let a = try await target(alone), b = try await target(crowded)
        try await decoys(crowded)
        func found(_ fx: KnowledgeFixture, _ id: Int64) async throws -> [String] {
            let passages = try await fx.store.retrieve(Self.question, queryVector: ConceptEmbedder.vector(Self.question), within: id,
                                                       space: ConceptEmbedder.space, limit: 5, locale: en, mode: mode)
            #expect(passages.allSatisfy { $0.meeting.id == id })
            return passages.map { "\($0.start)-\($0.end) \($0.score) \($0.cosine.map { "\($0)" } ?? "-")" }
        }
        let expected = try await found(alone, a)
        #expect(expected.count == 3, "every chunk of the meeting is a vector candidate")
        let crowdedFound = try await found(crowded, b)
        #expect(crowdedFound == expected, "3,000 closer chunks of other meetings change nothing inside this one")
    }

    @Test(arguments: [SemanticRanker.Mode.semantic, .rrf])
    func aSourcesOwnPassagesAreFoundWhateverTheOtherSourcesHold(mode: SemanticRanker.Mode) async throws {
        let alone = try IndexFixture(), crowded = try IndexFixture()
        for fx in [alone, crowded] {
            try await fx.add("release.txt", text: "Release\nThe launch plan and the release rollout were agreed with the supplier.")
            try await fx.add("budget.txt", text: "Budget\nThe spending costs were reviewed by finance.")
            try await fx.add("cats.txt", text: "Cats\nThe shipping date moved and the cats slept all day.")
            let todo = try await fx.index.passagesNeedingVectors(space: ConceptEmbedder.space, limit: 10)
            let items = todo.compactMap { id, text in VectorIndex.quantize(ConceptEmbedder.vector(text)).map { (id: id, q: $0.q, scale: $0.scale) } }
            try await fx.index.storeVectors(items, space: ConceptEmbedder.space)
        }
        try await crowded.addDecoys("notes.txt", source: 2, count: 3_000, vector: ConceptEmbedder.vector(Self.question))
        let scope = DocumentFilter([.init(source: 1)])
        func found(_ fx: IndexFixture) async throws -> [String] {
            let passages = try await fx.index.search(Self.question, queryVector: ConceptEmbedder.vector(Self.question), space: ConceptEmbedder.space,
                                                     within: scope, limit: 5, locale: en, mode: mode)
            #expect(passages.allSatisfy { $0.sourceID == 1 })
            return passages.map { "\($0.key) \($0.score) \($0.cosine.map { "\($0)" } ?? "-")" }
        }
        let expected = try await found(alone)
        #expect(expected.count == 3, "every passage of the source is a vector candidate")
        let crowdedFound = try await found(crowded)
        #expect(crowdedFound == expected, "3,000 closer passages of another source change nothing inside this one")
    }
}

extension IndexFixture {
    /// A file of `count` passages that all have `vector` (call it after the other files have their vectors).
    func addDecoys(_ name: String, source: Int64, count: Int, vector: [Float]) async throws {
        let scanned = ScannedDocumentFile(relPath: name, size: 1, mtime: 1, format: .text)
        let id = try await index.markPending(source: source, scanned: scanned, format: .text)
        let text = "Notes\nAnother release rollout note."
        let terms = DocumentTerms.terms(for: text)
        let passages = (0..<count).map { i in
            IndexedPassage(draft: PassageDraft(key: "decoy\(i)", ordinal: i, locator: .section(path: [], block: i + 1), text: text, ocr: false), terms: terms)
        }
        try await index.replacePassages(fileID: id, with: passages)
        try await index.finish(fileID: id, state: .indexed, title: nil, pages: nil, characters: text.count * count, ocrPages: [])
        let todo = try await index.passagesNeedingVectors(space: ConceptEmbedder.space, limit: count + 1)
        let (q, scale) = VectorIndex.quantize(vector)!
        try await index.storeVectors(todo.map { (id: $0.id, q: q, scale: scale) }, space: ConceptEmbedder.space)
    }
}
