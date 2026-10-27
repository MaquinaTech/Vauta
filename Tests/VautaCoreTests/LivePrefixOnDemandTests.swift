// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// An embedder in the search model's space that records every text it embeds, and can be held.
struct RecordingEmbedder: ChunkBudgeting {
    let texts = SharedBox<[String]>([])
    /// The questions (query purpose) it was asked to embed.
    let queries = SharedBox<[String]>([])
    var gate: EmbedGate?
    var limit = 500

    func chunkBudget() async throws -> ChunkBudget { ChunkBudget(limit: limit) { $0.split(separator: " ").count } }

    func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> EmbeddingBatch {
        if purpose == .document { self.texts.mutate { $0 += texts } } else { queries.mutate { $0 += texts } }
        await gate?.wait()
        return EmbeddingBatch(vectors: texts.map(ConceptEmbedder.vector), space: ConceptEmbedder.space)
    }

    var documentsEmbedded: Int { texts.value.count }
}

/// E3, on demand: a question typed during a recording that Apple-sized context cannot hold whole embeds the closed chunks of the
/// meeting being recorded, once, and nothing runs otherwise.
@Suite("Ask: the meeting being recorded, embedded on demand (E3)")
struct LivePrefixOnDemandTests {
    static let question = "What is our budget spending and costs?"
    static let concept = "Our finance and money matters were high this quarter"

    /// A meeting that is still being recorded: `count` long lines, 10 s apart (about 10 lines, 100 s, per chunk); line 25 is about money.
    static func lines(_ count: Int, from first: Int = 0) -> [String] {
        (first..<(first + count)).map { i in
            i == 25 ? concept : "Line \(i) of the long meeting about the roadmap, the vendors and the timetable for the next quarter, item \(i), with more words to fill it up"
        }
    }

    final class Rig: @unchecked Sendable {
        let fixture: KnowledgeFixture
        let service: LLMService
        let providers: TestProviders
        let chat: ScriptedChat
        let embedder: RecordingEmbedder
        let environment = SharedBox(IndexerEnvironment())
        let live: Int64
        init(fixture: KnowledgeFixture, service: LLMService, providers: TestProviders, chat: ScriptedChat, embedder: RecordingEmbedder, live: Int64) {
            self.fixture = fixture
            self.service = service
            self.providers = providers
            self.chat = chat
            self.embedder = embedder
            self.live = live
        }

        var store: MeetingStore { fixture.store }
        func lastSegment() async throws -> Int64 { try await store.citableSegments(live).last?.id ?? 0 }
        func append(_ lines: [String], from first: Int) async throws {
            for (k, line) in lines.enumerated() {
                let i = first + k
                try await store.append(Segment(channel: i % 2 == 0 ? .others : .me, start: Double(i * 10), end: Double(i * 10 + 8), text: line, isFinal: true), to: live)
            }
        }
        func storedChunks() async throws -> Int { Int(try await store.intsForTest("SELECT COUNT(*) FROM chunks WHERE meeting_id = ?", [.integer(live)])[0]) }
    }

    /// `context`: the answering model's window. `enabled`: the switch (nil = its default).
    static func rig(lines count: Int = 55, context: Int = 4_096, enabled: Bool? = true, embedder: RecordingEmbedder = RecordingEmbedder(),
                    choice: ModelProviderSettings.Embeddings? = .onDeviceModel, recording: Bool = true, past: [String]? = nil) async throws -> Rig {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        if let past { _ = try await f.meeting(past, locale: "en-US", outputLocale: "en-US", at: Date(timeIntervalSince1970: 1_790_000_000)) }
        let id = try await f.store.startMeeting(at: .now, locale: Locale(identifier: "en-US"), outputLocale: Locale(identifier: "en-US"))
        let chat = ScriptedChat { _, _, _ in ScriptedChat.reply(#"{"found": false, "answer": "", "claims": []}"#) }
        let providers = TestProviders(chat: chat, contextTokens: context, embedder: choice == ModelProviderSettings.Embeddings.none ? nil : embedder, onDevice: context < 12_000)
        providers.embeddingChoice = choice
        nonisolated(unsafe) let defaults = UserDefaults(suiteName: "vauta.tests.\(UUID().uuidString)")!
        let service = LLMService(store: f.store, providers: providers, searchDefaults: defaults)
        let rig = Rig(fixture: f, service: service, providers: providers, chat: chat, embedder: embedder, live: id)
        await service.setEnvironmentProvider { [environment = rig.environment] in environment.value }
        await service.setEmbedLivePrefixOnDemand(enabled)
        try await rig.append(lines(count), from: 0)
        if recording { await service.setRecording(true, meetingID: id) }
        if let past { _ = past; try await service.embed(try #require(try f.store.embeddableMeetings().first).id) }
        return rig
    }

    // MARK: When it runs

    @Test func aTypedQuestionThatTheWindowCannotHoldEmbedsTheClosedChunksAndFindsByMeaning() async throws {
        let rig = try await Self.rig()
        let result = try await rig.service.ask(Self.question, meetingID: rig.live)
        let plan = try await rig.store.chunkPlan(rig.live, budget: ChunkBudget(limit: 500) { $0.split(separator: " ").count })
        #expect(plan.count > 3)
        #expect(try await rig.storedChunks() == plan.count - 1, "every chunk but the one still growing")
        #expect(rig.embedder.documentsEmbedded == plan.count - 1)
        let sent = result.passages.flatMap(\.segments).map(\.text)
        #expect(sent.contains(Self.concept), "the question shares no word with the line about money: only the vectors find it")
    }

    @Test func withoutTheSwitchNothingIsEmbeddedAndTheMeetingRanksByKeywords() async throws {
        let rig = try await Self.rig(enabled: false)
        let result = try await rig.service.ask(Self.question, meetingID: rig.live)
        let stored = try await rig.storedChunks()
        #expect(rig.embedder.documentsEmbedded == 0 && stored == 0)
        #expect(!result.passages.flatMap(\.segments).map(\.text).contains(Self.concept))
    }

    @Test func theSwitchIsAHiddenPreferenceWhoseDefaultIsTheConstant() async throws {
        let rig = try await Self.rig(enabled: nil)
        #expect(await rig.service.embedsLivePrefixOnDemand == LLMService.embedLivePrefixDefault)
        nonisolated(unsafe) let defaults = UserDefaults(suiteName: "vauta.tests.\(UUID().uuidString)")!
        defaults.set(true, forKey: LLMService.embedLivePrefixKey)
        let on = LLMService(store: rig.store, providers: rig.providers, searchDefaults: defaults)
        #expect(await on.embedsLivePrefixOnDemand)
        defaults.set(false, forKey: LLMService.embedLivePrefixKey)
        #expect(await on.embedsLivePrefixOnDemand == false)
    }

    @Test func aWindowThatHoldsTheVisibleLinesEmbedsNothing() async throws {
        // The same meeting on a model with a large context: the lines go in whole, retrieval does not run, the embedding would change nothing.
        let rig = try await Self.rig(context: 65_536)
        _ = try await rig.service.ask(Self.question, meetingID: rig.live)
        let stored = try await rig.storedChunks()
        #expect(rig.embedder.documentsEmbedded == 0 && stored == 0)
        // Over the whole library the check is the same one.
        let report = try await rig.service.embedLivePrefix(meetingID: rig.live, upToSegment: try await rig.lastSegment(), budget: ContextBudget(contextTokens: 65_536), question: Self.question)
        #expect(report.skipped == .fitsInContext)
    }

    @Test func nothingRunsWhenNobodyAsks() async throws {
        let rig = try await Self.rig()
        try await rig.append(Self.lines(30, from: 55), from: 55)
        await rig.service.environmentChanged()
        await rig.service.refreshSearchCoverage()
        try await Task.sleep(for: .milliseconds(150))
        let stored = try await rig.storedChunks()
        #expect(rig.embedder.documentsEmbedded == 0 && stored == 0, "recording, growing and the Mac changing its mind embed nothing")
    }

    @Test func aQuestionAboutDocumentsOnlyOrAboutAnotherMeetingEmbedsNothing() async throws {
        let rig = try await Self.rig(past: ["Weekly sync notes", "The Berlin pilot was approved"])
        let before = rig.embedder.documentsEmbedded   // the past meeting, embedded by the rig as the app does after a meeting ends
        _ = try await rig.service.ask(Self.question, meetingID: nil, scope: .documents)
        let past = try #require(try await rig.store.embeddableMeetings().first).id
        _ = try await rig.service.ask("What was approved?", meetingID: past)
        let stored = try await rig.storedChunks()
        #expect(rig.embedder.documentsEmbedded == before && stored == 0)
    }

    @Test func aQuestionHeardInTheMeetingNeverEmbedsThePrefix() async throws {
        let rig = try await Self.rig()
        let evidence = await rig.service.questionEvidence(text: Self.question, locale: "en-US", meetingID: rig.live, segmentID: try await rig.lastSegment(),
                                                          sources: [.thisMeeting])
        _ = evidence
        let stored = try await rig.storedChunks()
        #expect(rig.embedder.documentsEmbedded == 0 && stored == 0, "a heard question does not embed the lines (E1: no measurable gain there)")
    }

    // MARK: The search model and the Mac

    @Test(arguments: [ModelProviderSettings.Embeddings.none, .server])
    func withoutTheSearchModelNothingIsEmbedded(choice: ModelProviderSettings.Embeddings) async throws {
        let rig = try await Self.rig(choice: choice)
        let report = try await rig.service.embedLivePrefix(meetingID: rig.live, upToSegment: try await rig.lastSegment())
        #expect(report.skipped == .notSearchModel)
        _ = try await rig.service.ask(Self.question, meetingID: rig.live)
        let stored = try await rig.storedChunks()
        #expect(rig.embedder.documentsEmbedded == 0 && stored == 0)
    }

    @Test func aSearchModelThatIsNotReadyEmbedsNothing() async throws {
        let rig = try await Self.rig()
        rig.providers.embedder = nil   // installed state lost: the provider reports it as disabled
        let report = try await rig.service.embedLivePrefix(meetingID: rig.live, upToSegment: try await rig.lastSegment())
        #expect(report.skipped == .notSearchModel)
    }

    @Test(arguments: [IndexerEnvironment(lowPowerMode: true), IndexerEnvironment(onBattery: true), IndexerEnvironment(thermalState: .serious), IndexerEnvironment(thermalState: .critical)])
    func lowPowerModeTheBatteryAndAHotMacHoldItBack(env: IndexerEnvironment) async throws {
        let rig = try await Self.rig()
        rig.environment.mutate { $0 = env }
        let report = try await rig.service.embedLivePrefix(meetingID: rig.live, upToSegment: try await rig.lastSegment())
        #expect(report.skipped == .guarded)
        let result = try await rig.service.ask(Self.question, meetingID: rig.live)
        let stored = try await rig.storedChunks()
        #expect(rig.embedder.documentsEmbedded == 0 && stored == 0)
        #expect(!result.passages.isEmpty || result.answer.found == false, "the question is still answered, with keywords")
    }

    @Test(arguments: [IndexerEnvironment(isRecording: true), IndexerEnvironment(thermalState: .fair)])
    func theRecordingItselfAndAFairMacDoNotStopAQuestion(env: IndexerEnvironment) async throws {
        let rig = try await Self.rig()
        rig.environment.mutate { $0 = env }
        let report = try await rig.service.embedLivePrefix(meetingID: rig.live, upToSegment: try await rig.lastSegment())
        #expect(report.skipped == nil && report.embeddedChunks > 0)
    }

    @Test func aStoreThatFailsMakesTheEmbeddingASkipAndTheQuestionIsStillAnswered() async throws {
        let rig = try await Self.rig()
        // Storing a chunk fails (a full disk, a commit error): the question is answered with keywords.
        _ = try await rig.store.intsForTest("CREATE TRIGGER no_chunks BEFORE INSERT ON chunks BEGIN SELECT RAISE(ABORT, 'disk'); END")
        let report = try await rig.service.embedLivePrefix(meetingID: rig.live, upToSegment: try await rig.lastSegment())
        #expect(report.skipped == .failed)
        let result = try await rig.service.ask(Self.question, meetingID: rig.live)
        #expect(!result.passages.isEmpty || result.answer.found == false)
        let stored = try await rig.storedChunks()
        #expect(stored == 0)
    }

    @Test func whenTheRecordingEndsTheMeetingIsNotCoveredUntilTheEmbeddingJobWritesItAll() async throws {
        let rig = try await Self.rig()
        _ = try await rig.service.ask(Self.question, meetingID: rig.live)
        let space = GemmaEmbeddingModel.space
        let during = try await rig.storedChunks()
        let coveredDuring = try await rig.store.isCovered(rig.live, space: space)
        #expect(during > 0 && coveredDuring, "during the recording the typed questions use their chunks")
        await rig.service.setRecording(false, meetingID: nil)
        _ = try await rig.store.endMeeting(rig.live, at: .now)
        let after = try await rig.storedChunks()
        let covered = try await rig.store.isCovered(rig.live, space: space)
        let coverage = try await rig.store.vectorCoverage(space: space)
        #expect(after == 0 && !covered && coverage.covered == 0, "chunks that stop at the last typed question are not the meeting's")
    }

    @Test func aQuestionHeardAfterATypedOneStillUsesTheTranslatedKeywordSearch() async throws {
        let rig = try await Self.rig()
        let spanish = "¿Cuál es el calendario para el próximo trimestre?"
        let english = "What is the timetable for the next quarter?"
        let translator = MapTranslator([spanish: english])
        await rig.service.setQueryTranslation(MapBackend(translator))
        _ = try await rig.service.ask(Self.question, meetingID: rig.live)
        let stored = try await rig.storedChunks()
        #expect(stored > 0)
        let evidence = await rig.service.questionEvidence(text: spanish, locale: "en-US", meetingID: rig.live, segmentID: try await rig.lastSegment(), sources: [.thisMeeting])
        #expect(translator.calls == [spanish], "the meeting being recorded ranks by keywords, so the question is translated")
        #expect(!evidence.ungated.semantic.contains(.thisMeeting))
        #expect(evidence.matches["thisMeeting"].map { $0 >= QuestionEvidenceGate.minimumMatches } == true)
    }

    @Test func itIsOnlyForTheMeetingBeingRecorded() async throws {
        let rig = try await Self.rig(recording: false)
        let report = try await rig.service.embedLivePrefix(meetingID: rig.live, upToSegment: try await rig.lastSegment())
        #expect(report.skipped == .notRecording)
        await rig.service.setRecording(true, meetingID: rig.live)
        #expect(try await rig.service.embedLivePrefix(meetingID: rig.live + 1, upToSegment: 1).skipped == .notRecording)
    }

    @Test func overTheWholeLibraryItNeedsAnIndexThatRanksByMeaning() async throws {
        // No meeting is embedded yet: the library ranks by keywords, so the meeting's vectors would not be used.
        let none = try await Self.rig()
        let skipped = try await none.service.embedLivePrefix(meetingID: none.live, upToSegment: try await none.lastSegment(), budget: ContextBudget(contextTokens: 4_096), question: Self.question)
        #expect(skipped.skipped == .libraryNotRanking && none.embedder.documentsEmbedded == 0)
        // With an embedded past meeting the library ranks by meaning.
        let ranking = try await Self.rig(past: ["Weekly sync notes", "The Berlin pilot was approved"])
        let report = try await ranking.service.embedLivePrefix(meetingID: ranking.live, upToSegment: try await ranking.lastSegment(), budget: ContextBudget(contextTokens: 4_096), question: Self.question)
        #expect(report.skipped == nil && report.embeddedChunks > 0)
        let result = try await ranking.service.ask(Self.question, meetingID: nil)
        #expect(result.passages.flatMap(\.segments).map(\.text).contains(Self.concept))
    }

    // MARK: Cache and increments

    @Test func theNextQuestionEmbedsOnlyTheChunksThatClosedSince() async throws {
        let rig = try await Self.rig()
        let first = try await rig.service.embedLivePrefix(meetingID: rig.live, upToSegment: try await rig.lastSegment())
        #expect(first.embeddedChunks == first.closedChunks && first.reusedChunks == 0 && first.closedChunks > 3)
        let again = try await rig.service.embedLivePrefix(meetingID: rig.live, upToSegment: try await rig.lastSegment())
        #expect(again.embeddedChunks == 0 && again.reusedChunks == first.closedChunks, "the same lines: nothing to embed")
        #expect(rig.embedder.documentsEmbedded == first.embeddedChunks)
        // 25 more lines close two or three chunks (and the one that was growing).
        try await rig.append(Self.lines(25, from: 55), from: 55)
        let later = try await rig.service.embedLivePrefix(meetingID: rig.live, upToSegment: try await rig.lastSegment())
        #expect(later.reusedChunks == first.closedChunks, "everything that was closed stays")
        #expect(later.embeddedChunks > 0 && later.embeddedChunks <= 4 && later.closedChunks == first.closedChunks + later.embeddedChunks)
        #expect(rig.embedder.documentsEmbedded == first.embeddedChunks + later.embeddedChunks)
    }

    @Test func aChunkWhoseTextChangedIsEmbeddedAgainAndTheStaleOneIsDropped() async throws {
        let rig = try await Self.rig()
        let first = try await rig.service.embedLivePrefix(meetingID: rig.live, upToSegment: try await rig.lastSegment())
        // A speaker was named since: the text of one stored chunk is no longer the transcript's.
        try await rig.store.executeForTest("UPDATE chunks SET text_key = 'stale' WHERE id = (SELECT min(id) FROM chunks WHERE meeting_id = ?)", [.integer(rig.live)])
        let again = try await rig.service.embedLivePrefix(meetingID: rig.live, upToSegment: try await rig.lastSegment())
        #expect(again.droppedChunks == 1 && again.embeddedChunks == 1 && again.reusedChunks == first.closedChunks - 1)
        #expect(try await rig.storedChunks() == first.closedChunks)
    }

    @Test func theQuestionSeesTheMeetingAsItStoodWhenItWasAsked() async throws {
        let rig = try await Self.rig()
        let bound = try await rig.lastSegment()
        try await rig.append(Self.lines(40, from: 55), from: 55)
        let report = try await rig.service.embedLivePrefix(meetingID: rig.live, upToSegment: bound)
        let plan = try await rig.store.chunkPlan(rig.live, budget: ChunkBudget(limit: 500) { $0.split(separator: " ").count }, upToSegment: bound)
        #expect(report.closedChunks == plan.count - 1, "lines said after the question are not embedded for it")
        let all = try await rig.store.chunkPlan(rig.live, budget: ChunkBudget(limit: 500) { $0.split(separator: " ").count })
        #expect(all.count > plan.count)
    }

    @Test func theEmbeddingJobThatFollowsTheMeetingReplacesTheChunks() async throws {
        let rig = try await Self.rig()
        _ = try await rig.service.embedLivePrefix(meetingID: rig.live, upToSegment: try await rig.lastSegment())
        await rig.service.setRecording(false, meetingID: rig.live)
        _ = try await rig.store.endMeeting(rig.live, at: .now)
        try await rig.service.embed(rig.live)
        let plan = try await rig.store.chunkPlan(rig.live, budget: ChunkBudget(limit: 500) { $0.split(separator: " ").count })
        #expect(try await rig.storedChunks() == plan.count, "the whole meeting, the last chunk too")
        #expect(try await rig.store.chunksOutOfDate(rig.live, budget: ChunkBudget(limit: 500) { $0.split(separator: " ").count }) == false)
    }

    // MARK: Cancellation

    @Test func theRecordingStoppingWhileABatchRunsStoresNothingOfIt() async throws {
        let gate = EmbedGate()
        await gate.close()
        let rig = try await Self.rig(embedder: RecordingEmbedder(gate: gate))
        let bound = try await rig.lastSegment()
        let task = Task { try await rig.service.embedLivePrefix(meetingID: rig.live, upToSegment: bound) }
        #expect(await eventually { await gate.held > 0 })
        await rig.service.setRecording(false, meetingID: rig.live)
        await gate.release()
        let report = try await task.value
        #expect(report.skipped == .stopped)
        #expect(try await rig.storedChunks() == 0)
    }

    @Test func aLaterTypedQuestionThatIsSkippedSearchesTheMeetingByKeywordsNotByStaleVectors() async throws {
        let rig = try await Self.rig()
        let first = try await rig.service.ask(Self.question, meetingID: rig.live)
        #expect(first.passages.flatMap(\.segments).map(\.text).contains(Self.concept))
        #expect(try await rig.storedChunks() > 0)
        // The Mac goes on battery: the next question embeds nothing, and the vectors of the first one no longer cover what was said since.
        rig.environment.mutate { $0.onBattery = true }
        let second = try await rig.service.ask(Self.question, meetingID: rig.live)
        #expect(!second.passages.flatMap(\.segments).map(\.text).contains(Self.concept), "ranked by keywords: no shared word with the line about money")
    }

    @Test func aWholeLibraryQuestionThatIsSkippedDoesNotRankTheLiveMeetingByTheStaleVectorsOfAnEarlierOne() async throws {
        let rig = try await Self.rig(past: ["Weekly sync notes", "The Berlin pilot was approved"])
        let first = try await rig.service.ask(Self.question, meetingID: nil)
        #expect(first.passages.flatMap(\.segments).map(\.text).contains(Self.concept))
        #expect(try await rig.storedChunks() > 0)
        rig.environment.mutate { $0.onBattery = true }
        let second = try await rig.service.ask(Self.question, meetingID: nil)
        #expect(!second.passages.flatMap(\.segments).map(\.text).contains(Self.concept), "the live meeting comes from keywords only: no shared word with the line about money")
        #expect(try await rig.storedChunks() == 0, "the stale chunks are gone; the embedding job writes the whole set")
    }

    @Test func aMacThatGoesOnBatteryBetweenBatchesStopsTheEmbeddingAndKeepsTheBatchesAlreadyStored() async throws {
        let rig = try await Self.rig(lines: 140)
        let environment = rig.environment
        await rig.service.setBeforeOnDemandChunksStored { environment.mutate { $0.onBattery = true } }
        let report = try await rig.service.embedLivePrefix(meetingID: rig.live, upToSegment: try await rig.lastSegment())
        #expect(report.skipped == .guarded)
        #expect(report.embeddedChunks == LLMService.livePrefixBatch)
        #expect(try await rig.storedChunks() == LLMService.livePrefixBatch)
    }

    @Test func chunksLeftByAnInterruptedRecordingAreDiscardedSoThePartialSetIsNotCovered() async throws {
        let rig = try await Self.rig()
        _ = try await rig.service.embedLivePrefix(meetingID: rig.live, upToSegment: try await rig.lastSegment())
        #expect(try await rig.storedChunks() > 0)
        // The app dies here: nothing remembers the meeting was embedded on demand. The next launch discards what is left.
        let relaunched = LLMService(store: rig.store, providers: rig.providers, searchDefaults: UserDefaults(suiteName: "vauta.tests.\(UUID().uuidString)")!)
        await relaunched.discardLivePrefixChunks(rig.live)
        #expect(try await rig.storedChunks() == 0)
    }

    @Test func theRecordingEndingWhileTheChunksAreBeingStoredLeavesNoPartialVectorsAndForgetsNothingElse() async throws {
        let rig = try await Self.rig(past: ["An earlier meeting about the budget and the hiring plan for next year, with enough words to be a meeting of its own."])
        let earlier = try #require(try await rig.store.intsForTest("SELECT id FROM meetings WHERE id <> ?", [.integer(rig.live)]).first)
        let earlierChunks = try await rig.store.intsForTest("SELECT COUNT(*) FROM chunks WHERE meeting_id = ?", [.integer(earlier)])[0]
        #expect(earlierChunks > 0)
        // The recording ends at the moment the first batch is being committed.
        let service = rig.service, live = rig.live
        await service.setBeforeOnDemandChunksStored { await service.setRecording(false, meetingID: live) }
        let report = try await service.embedLivePrefix(meetingID: live, upToSegment: try await rig.lastSegment())
        #expect(report.skipped == .stopped)
        #expect(try await rig.storedChunks() == 0, "an ended meeting holds no part of its vectors: the embedding job writes all of them")
        #expect(await service.onDemandMeetings.isEmpty)
        // The next recording's end must not touch what the embedding job wrote for the earlier meeting.
        await service.setBeforeOnDemandChunksStored(nil)
        _ = try await rig.store.endMeeting(rig.live, at: .now)
        let next = try await rig.store.startMeeting(at: .now, locale: Locale(identifier: "en-US"), outputLocale: Locale(identifier: "en-US"))
        await service.setRecording(true, meetingID: next)
        await service.setRecording(false, meetingID: next)
        let after = try await rig.store.intsForTest("SELECT COUNT(*) FROM chunks WHERE meeting_id = ?", [.integer(earlier)])[0]
        #expect(after == earlierChunks)
    }

    @Test func cancellingTheQuestionStopsTheEmbeddingAndKeepsTheChunksOfEarlierBatches() async throws {
        let gate = EmbedGate()
        let rig = try await Self.rig(embedder: RecordingEmbedder(gate: gate))
        let bound = try await rig.lastSegment()
        // One batch goes through, the next is held.
        _ = try await rig.service.embedLivePrefix(meetingID: rig.live, upToSegment: bound)
        let stored = try await rig.storedChunks()
        try await rig.append(Self.lines(30, from: 55), from: 55)
        await gate.close()
        let task = Task { try await rig.service.embedLivePrefix(meetingID: rig.live, upToSegment: try await rig.lastSegment()) }
        #expect(await eventually { await gate.held > 0 })
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try await rig.storedChunks() >= stored, "what was embedded before stays")
        // Cancelling the Ask itself ends it with a cancellation too.
        await gate.close()
        let asking = Task { try await rig.service.ask(Self.question, meetingID: rig.live) }
        #expect(await eventually { await gate.held > 1 })
        asking.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await asking.value }
    }
}
