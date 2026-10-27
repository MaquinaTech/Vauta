// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// E2: with the search model ranking, the evidence gate compares the raw cosine with a threshold per source, and the question never
/// finds itself.
@Suite("Live answers: the evidence gate with the search model (E2)")
struct QuestionEvidenceSemanticTests {
    /// A service whose search model is the concept embedder; every meeting is embedded as the app does after it ends.
    static func rig(live: [String], past: [String]) async throws -> (LLMService, live: Int64, past: Int64, [CitableSegment]) {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let pastID = try await f.meeting(past, locale: "en-US", outputLocale: "en-US", at: Date(timeIntervalSince1970: 1_790_000_000))
        let liveID = try await f.meeting(live, locale: "en-US", outputLocale: "en-US")
        let providers = TestProviders(chat: ScriptedChat { _, _, _ in ScriptedChat.reply("{}") }, embedder: BudgetedEmbedder(limit: 500))
        providers.embeddingChoice = .onDeviceModel
        nonisolated(unsafe) let defaults = UserDefaults(suiteName: "vauta.tests.\(UUID().uuidString)")!
        let service = LLMService(store: f.store, providers: providers, searchDefaults: defaults)
        await service.setEnvironmentProvider { IndexerEnvironment() }
        try await service.embed(pastID)
        try await service.embed(liveID)
        return (service, liveID, pastID, try await f.store.citableSegments(liveID))
    }

    static let filler = (0..<50).map { "word\($0)x" }.joined(separator: " ")

    @Test func aBoostedScoreDoesNotPassTheGateWhenTheRawCosineIsBelowTheThreshold() async throws {
        // The passage has the question's rare name (a +0.15 boost) and one concept in common, diluted by other words: its cosine is
        // low, its ranking score is not.
        let (service, live, _, segments) = try await Self.rig(live: ["Okay", "Fine", "Next", "Right", "How much money did Berlin spend?"],
                                                               past: ["Weekly sync", "The Berlin team talked about the budget. \(Self.filler)"])
        let evidence = await service.questionEvidence(text: "How much money did Berlin spend?", locale: "en-US", meetingID: live, segmentID: segments[4].id,
                                                      sources: [.pastMeetings])
        let passage = try #require(evidence.ungated.past.first)
        let cosine = try #require(passage.cosine)
        #expect(evidence.ungated.semantic.contains(.pastMeetings))
        #expect(cosine < QuestionEvidenceGate.calibratedMeetingThreshold && passage.score >= QuestionEvidenceGate.calibratedMeetingThreshold,
                "the boosted score (\(passage.score)) is above the threshold, the raw cosine (\(cosine)) is not")
        #expect(!evidence.passes, "one shared word and a raw cosine under the threshold")
        // The same passage passes when the person's threshold for that source is lower than its raw cosine.
        let lowered = await service.questionEvidence(text: "How much money did Berlin spend?", locale: "en-US", meetingID: live, segmentID: segments[4].id,
                                                     sources: [.pastMeetings], thresholds: .init(pastMeetings: cosine - 0.01))
        #expect(lowered.passing == .pastMeetings)
    }

    @Test func eachSourceHasItsOwnThreshold() async throws {
        // Both sources talk about the same concept in other words: only the cosine can pass them.
        let (service, live, _, segments) = try await Self.rig(live: ["Our finance and money matters were high", "Fine", "Next", "Right", "What is our budget spending and costs?"],
                                                               past: ["The finance and money matters were reviewed", "Weekly sync"])
        let text = "What is our budget spending and costs?"
        func passing(_ thresholds: QuestionEvidenceGate.Thresholds) async -> LiveAnswerSources {
            await service.questionEvidence(text: text, locale: "en-US", meetingID: live, segmentID: segments[4].id, sources: [.thisMeeting, .pastMeetings],
                                           thresholds: thresholds).passing
        }
        #expect(await passing(.all(0.1)) == [.thisMeeting, .pastMeetings])
        #expect(await passing(.init(thisMeeting: 2, pastMeetings: 0.1)) == .pastMeetings)
        #expect(await passing(.init(thisMeeting: 0.1, pastMeetings: 2)) == .thisMeeting)
        #expect(await passing(.all(2)) == [])
    }

    @Test func theQuestionDoesNotFindItselfInTheChunkThatHoldsIt() async throws {
        // The chunk holds the question, which is made of the words of one concept. Without the fix its cosine is high because of the
        // question; the two lines before the question and the question are left out, and what is left is about the weather.
        let lines = ["Let us begin the agenda", "The weather is nice outside", "Ana owns the payroll integration", "Okay next point", "What is our budget spending and costs?"]
        let (service, live, _, segments) = try await Self.rig(live: lines, past: ["Unrelated notes"])
        let text = "What is our budget spending and costs?"
        let leaking = await service.questionEvidence(text: text, locale: "en-US", meetingID: live, segmentID: segments[4].id, sources: [.thisMeeting],
                                                     excludeSelfMatch: false)
        #expect(leaking.passes, "the leak: the chunk that holds the question has a high cosine to it")
        let fixed = await service.questionEvidence(text: text, locale: "en-US", meetingID: live, segmentID: segments[4].id, sources: [.thisMeeting])
        #expect(!fixed.passes, "scored without the question, nothing in the earlier lines is about it")
        let kept = Set(fixed.ungated.thisMeeting.flatMap(\.segments).map(\.id))
        #expect(!kept.contains(segments[4].id) && !kept.contains(segments[3].id) && !kept.contains(segments[2].id))
        let cosine = try #require(fixed.ungated.thisMeeting.first?.cosine)
        #expect(cosine < 0.3, "raw cosine of the lines that are left: \(cosine)")
    }

    @Test func earlierEvidenceInTheSameChunkStillPassesAfterTheFix() async throws {
        let lines = ["Our budget spending and costs went over the plan last quarter", "The weather is nice outside", "Ana owns the payroll integration", "Okay next point",
                     "What is our budget spending and costs?"]
        let (service, live, _, segments) = try await Self.rig(live: lines, past: ["Unrelated notes"])
        let evidence = await service.questionEvidence(text: "What is our budget spending and costs?", locale: "en-US", meetingID: live, segmentID: segments[4].id,
                                                      sources: [.thisMeeting])
        #expect(evidence.passing == .thisMeeting)
        #expect(evidence.thisMeeting.flatMap(\.segments).map(\.id).contains(segments[0].id))
    }

    @Test func aPastMeetingWithoutVectorsNeverBorrowsTheCosineOfAnotherChunk() async throws {
        // The library is embedded (so it ranks by meaning), then a meeting is recorded that waits to be embedded. It shares one word with
        // the question, so it ranks first by keywords; the cosine of the vector hit at the same rank is not its own.
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let embedded = try await f.meeting(["The budget and finance costs were reviewed", "Weekly sync"], locale: "en-US", outputLocale: "en-US",
                                           at: Date(timeIntervalSince1970: 1_790_000_000))
        let live = try await f.meeting(["Okay", "Fine", "Next", "Right", "What is our budget spending and costs for the zebra?"], locale: "en-US", outputLocale: "en-US")
        let providers = TestProviders(chat: ScriptedChat { _, _, _ in ScriptedChat.reply("{}") }, embedder: BudgetedEmbedder(limit: 500))
        providers.embeddingChoice = .onDeviceModel
        nonisolated(unsafe) let defaults = UserDefaults(suiteName: "vauta.tests.\(UUID().uuidString)")!
        let service = LLMService(store: f.store, providers: providers, searchDefaults: defaults)
        await service.setEnvironmentProvider { IndexerEnvironment() }
        try await service.embed(embedded)
        try await service.embed(live)
        let waiting = try await f.meeting(["The zebra enclosure was repaired", "Nothing else"], locale: "en-US", outputLocale: "en-US", at: Date(timeIntervalSince1970: 1_791_000_000))
        let segments = try await f.store.citableSegments(live)
        let text = "What is our budget spending and costs for the zebra?"
        let evidence = await service.questionEvidence(text: text, locale: "en-US", meetingID: live, segmentID: segments[4].id, sources: [.pastMeetings])
        #expect(evidence.ungated.semantic.contains(.pastMeetings))
        let unembedded = try #require(evidence.ungated.past.first { $0.meeting.id == waiting })
        let embeddedPassage = try #require(evidence.ungated.past.first { $0.meeting.id == embedded })
        #expect(unembedded.cosine == nil, "its score is a placeholder, not a cosine")
        #expect(embeddedPassage.cosine != nil)
        #expect(QuestionEvidenceGate.matches(queryKeys: QuestionDedup.keys(text, locale: "en-US"), text: unembedded.segments.map(\.text).joined(separator: " "), locale: "en-US") == 1)
        #expect(!QuestionEvidenceGate.passes(matches: 1, cosine: QuestionEvidenceGate.gateScore(cosine: unembedded.cosine), semantic: true, threshold: 0.1),
                "one shared word and no cosine of its own: it does not pass")
    }

    @Test func aPassageThatCannotBeScoredWithoutTheQuestionDoesNotPassOnItsCosine() async throws {
        let embedder = FlakyDocumentEmbedder()
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let past = try await f.meeting(["Unrelated notes"], locale: "en-US", outputLocale: "en-US", at: Date(timeIntervalSince1970: 1_790_000_000))
        let live = try await f.meeting(["Our finance and money matters were high", "Fine", "Next", "Right", "What is our budget spending and costs?"], locale: "en-US", outputLocale: "en-US")
        let providers = TestProviders(chat: ScriptedChat { _, _, _ in ScriptedChat.reply("{}") }, embedder: embedder)
        providers.embeddingChoice = .onDeviceModel
        nonisolated(unsafe) let defaults = UserDefaults(suiteName: "vauta.tests.\(UUID().uuidString)")!
        let service = LLMService(store: f.store, providers: providers, searchDefaults: defaults)
        await service.setEnvironmentProvider { IndexerEnvironment() }
        try await service.embed(past)
        try await service.embed(live)
        let segments = try await f.store.citableSegments(live)
        let text = "What is our budget spending and costs?"
        let works = await service.questionEvidence(text: text, locale: "en-US", meetingID: live, segmentID: segments[4].id, sources: [.thisMeeting], thresholds: .all(0.5))
        #expect(works.passing == .thisMeeting, "the lines that are left are about the question's concept")
        embedder.failDocuments.mutate { $0 = true }
        let failing = await service.questionEvidence(text: text, locale: "en-US", meetingID: live, segmentID: segments[4].id, sources: [.thisMeeting], thresholds: .all(0.5))
        #expect(!failing.passes, "no vector for the lines that are left: no cosine")
        embedder.failDocuments.mutate { $0 = false }
        embedder.wrongSpace.mutate { $0 = true }
        let mismatched = await service.questionEvidence(text: text, locale: "en-US", meetingID: live, segmentID: segments[4].id, sources: [.thisMeeting], thresholds: .all(0.5))
        #expect(!mismatched.passes, "a vector of another space cannot be compared")
    }

    @Test func aStoredVectorIsScoredAtTheScaleOfTheIndex() {
        let v = ConceptEmbedder.vector("The budget and finance costs were reviewed")
        let stored = try! #require(VectorIndex.asStored(v))
        #expect(stored.count == v.count)
        let q = ConceptEmbedder.vector("What is our budget spending and costs?")
        #expect(abs(QuestionEvidenceGate.cosine(q, stored) - QuestionEvidenceGate.cosine(q, v)) < 0.01, "the rounding is small")
        #expect(VectorIndex.asStored([0, 0]) == nil)
    }

    @Test func withoutTheSearchModelTheGateIsUnchangedAndIgnoresThresholds() async throws {
        let (service, _, live, _, segments) = try await QuestionEvidenceTests.rig()
        let text = "Which month does the vendor contract expire?"
        let evidence = await service.questionEvidence(text: text, locale: "en-US", meetingID: live, segmentID: segments[4].id, sources: [.thisMeeting], thresholds: .all(-1))
        #expect(evidence.passes && evidence.ungated.semantic.isEmpty)
        let none = await service.questionEvidence(text: "Which colour is the sky?", locale: "en-US", meetingID: live, segmentID: segments[4].id, sources: [.thisMeeting],
                                                  thresholds: .all(-1))
        #expect(!none.passes, "a cosine counts only when the search model ranks")
    }
}

/// E2, documents: the gate reads the raw cosine of a document passage against `thresholds.documents`, never the boosted score, and a
/// passage that has no vector yet has no cosine.
@Suite("Live answers: the evidence gate over documents (E2)")
struct QuestionEvidenceDocumentTests {
    static let filler = (0..<50).map { "word\($0)x" }.joined(separator: " ")

    /// A service in semantic mode over a documents index whose passages were embedded with the concept embedder.
    static func rig(_ files: [(String, String)]) async throws -> (LLMService, IndexFixture, meeting: Int64) {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let meeting = try await f.meeting(["Okay"], locale: "en-US", outputLocale: "en-US")
        let docs = try IndexFixture()
        for (name, text) in files { try await docs.add(name, text: text) }
        try await embed(docs)
        let providers = TestProviders(chat: ScriptedChat { _, _, _ in ScriptedChat.reply("{}") }, embedder: BudgetedEmbedder(limit: 500))
        providers.embeddingChoice = .onDeviceModel
        nonisolated(unsafe) let defaults = UserDefaults(suiteName: "vauta.tests.\(UUID().uuidString)")!
        let service = LLMService(store: f.store, providers: providers, searchDefaults: defaults)
        await service.setEnvironmentProvider { IndexerEnvironment() }
        await service.setDocuments(docs.index)
        return (service, docs, meeting)
    }

    static func embed(_ fx: IndexFixture) async throws {
        let todo = try await fx.index.passagesNeedingVectors(space: ConceptEmbedder.space, limit: 1_000)
        let items = todo.compactMap { id, text in VectorIndex.quantize(ConceptEmbedder.vector(text)).map { (id: id, q: $0.q, scale: $0.scale) } }
        try await fx.index.storeVectors(items, space: ConceptEmbedder.space)
    }

    @Test func aBoostedDocumentPassageDoesNotPassOnItsScoreAndTheDocumentsThresholdIsTheOneApplied() async throws {
        let question = "How much money did Berlin spend?"
        let (service, _, meeting) = try await Self.rig([("berlin.txt", "Notes\nThe Berlin team talked about the budget. \(Self.filler)"),
                                                        ("other.txt", "Notes\nThe weather was nice and the lunch was good.")])
        let evidence = await service.questionEvidence(text: question, locale: "en-US", meetingID: meeting, segmentID: nil, sources: [.documents])
        #expect(evidence.ungated.semantic.contains(.documents))
        let passage = try #require(evidence.ungated.documents.first { $0.fileName == "berlin.txt" })
        let cosine = try #require(passage.cosine)
        let threshold = QuestionEvidenceGate.calibratedMeetingThreshold
        #expect(cosine < threshold && passage.score >= threshold, "the boosted score (\(passage.score)) is above the threshold, the raw cosine (\(cosine)) is not")
        #expect(!evidence.passes && evidence.documents.isEmpty, "one shared word and a raw cosine under the threshold")
        // Only the threshold of the documents counts: the other two sources' values change nothing.
        let others = await service.questionEvidence(text: question, locale: "en-US", meetingID: meeting, segmentID: nil, sources: [.documents],
                                                    thresholds: .init(thisMeeting: -1, pastMeetings: -1))
        #expect(!others.passes)
        let lowered = await service.questionEvidence(text: question, locale: "en-US", meetingID: meeting, segmentID: nil, sources: [.documents],
                                                     thresholds: .init(thisMeeting: 2, pastMeetings: 2, documents: cosine - 0.01))
        #expect(lowered.passing == .documents)
        let raised = await service.questionEvidence(text: question, locale: "en-US", meetingID: meeting, segmentID: nil, sources: [.documents],
                                                    thresholds: .init(thisMeeting: -1, pastMeetings: -1, documents: 2))
        #expect(!raised.passes)
    }

    @Test func aDocumentPassageWithoutAVectorHasNoCosineAndPassesOnSharedWordsOnly() async throws {
        let (service, docs, meeting) = try await Self.rig([("budget.txt", "Finance\nThe budget and finance costs were reviewed."),
                                                           ("other.txt", "Notes\nThe weather was nice and the lunch was good.")])
        // The library is fully embedded once (so it ranks by meaning from then on, as in the app).
        let primed = await service.questionEvidence(text: "budget", locale: "en-US", meetingID: meeting, segmentID: nil, sources: [.documents])
        #expect(primed.ungated.semantic.contains(.documents))
        // Added after the others were embedded: it joins by keywords (a rare name and a code), with a placeholder score.
        try await docs.add("zebra.txt", text: "Zoo\nThe Zebulon enclosure INV-2026-0417 was repaired.")
        let question = "What is our budget spending for INV-2026-0417 and Zebulon?"
        let evidence = await service.questionEvidence(text: question, locale: "en-US", meetingID: meeting, segmentID: nil, sources: [.documents],
                                                      thresholds: .all(0.1))
        let fresh = try #require(evidence.ungated.documents.first { $0.fileName == "zebra.txt" })
        let embedded = try #require(evidence.ungated.documents.first { $0.fileName == "budget.txt" })
        #expect(fresh.cosine == nil, "its score is a placeholder, not a cosine")
        #expect(embedded.cosine != nil)
        let shared = QuestionEvidenceGate.matches(queryKeys: QuestionDedup.keys(question, locale: "en-US"), text: fresh.text, locale: "en-US")
        #expect(!QuestionEvidenceGate.passes(matches: min(shared, 1), cosine: QuestionEvidenceGate.gateScore(cosine: fresh.cosine), semantic: true, threshold: 0.1),
                "without a cosine of its own it needs two shared words")
    }
}

/// The concept embedder, with switches that make the embedding of a document fail or answer in another space (the question is always embedded).
final class FlakyDocumentEmbedder: ChunkBudgeting, @unchecked Sendable {
    let failDocuments = SharedBox(false)
    let wrongSpace = SharedBox(false)

    func chunkBudget() async throws -> ChunkBudget { ChunkBudget(limit: 500) { $0.split(separator: " ").count } }

    func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> EmbeddingBatch {
        struct Failed: Error {}
        if purpose == .document, failDocuments.value { throw Failed() }
        let space = purpose == .document && wrongSpace.value ? EmbeddingSpace(model: "other", dimensions: 256) : ConceptEmbedder.space
        return EmbeddingBatch(vectors: texts.map(ConceptEmbedder.vector), space: space)
    }
}
