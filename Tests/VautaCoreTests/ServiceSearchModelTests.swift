// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// An embedder in the search model's space that also has a chunk budget, like `GemmaEmbeddingModel`.
struct BudgetedEmbedder: ChunkBudgeting {
    let calls = SharedBox(0)
    let limit: Int

    func chunkBudget() async throws -> ChunkBudget { ChunkBudget(limit: limit) { $0.split(separator: " ").count } }

    func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> EmbeddingBatch {
        calls.add(1)
        return EmbeddingBatch(vectors: texts.map(ConceptEmbedder.vector), space: ConceptEmbedder.space)
    }
}

/// The service with the search model: pauses, the thermal fallback, the ranking mode and the coverage it publishes.
@Suite("Service: search model")
struct ServiceSearchModelTests {
    static let lines = ["We reviewed the launch plan for the quarter", "The release rollout is on track", "Ana will send the numbers on Friday"]

    private func make(_ f: KnowledgeFixture, embedder: any EmbeddingModel, choice: ModelProviderSettings.Embeddings? = .onDeviceModel)
        -> (LLMService, TestProviders, UserDefaults) {
        let providers = TestProviders(chat: ScriptedChat { messages, _, _ in ScriptedChat.reply(ScriptedChat.minutesJSON(messages)) }, embedder: embedder)
        providers.embeddingChoice = choice
        nonisolated(unsafe) let defaults = UserDefaults(suiteName: "vauta.tests.\(UUID().uuidString)")!
        return (LLMService(store: f.store, providers: providers, searchDefaults: defaults), providers, defaults)
    }

    @Test func meetingsWaitForAQuietPoweredMacAndTheMinutesAreNotHeldUp() async throws {
        let f = try KnowledgeFixture()
        let embedder = BudgetedEmbedder(limit: 500)
        let (service, _, _) = make(f, embedder: embedder)
        let env = SharedBox(IndexerEnvironment(onBattery: true))
        await service.setEnvironmentProvider { env.value }
        let events = EventLog()
        await service.setJobEventHandler { events.append($0) }
        let id = try await f.meeting(Self.lines)
        await service.meetingEnded(id)
        #expect(await eventually { events.events.contains(.init(meetingID: id, kind: .minutes, outcome: .succeeded)) }, "the minutes run")
        #expect(embedder.calls.value == 0, "embedding waits for the charger")
        #expect(try await f.store.hasChunks(id) == false)
        let queued = try await f.store.jobs(for: id).first { $0.kind == .embed }
        #expect(queued?.state == .queued && queued?.attempts == 0, "back in the queue without using up an attempt")
        // On power, with the job due: it runs.
        env.mutate { $0 = IndexerEnvironment() }
        try await f.store.executeForTest("UPDATE llm_jobs SET not_before = NULL WHERE kind = 'embed'")
        await service.kick()
        #expect(await eventually { try await f.store.hasChunks(id) })
        #expect(embedder.calls.value > 0)
    }

    @Test(arguments: [IndexerEnvironment(isRecording: true), IndexerEnvironment(recordingStoppedAt: Date().addingTimeInterval(3600)), IndexerEnvironment(lowPowerMode: true),
                      IndexerEnvironment(thermalState: .serious), IndexerEnvironment(thermalState: .critical), IndexerEnvironment(onBattery: true)])
    func everyReasonPausesBulkEmbeddingOfTheSearchModel(env: IndexerEnvironment) async throws {
        let f = try KnowledgeFixture()
        let (service, _, _) = make(f, embedder: BudgetedEmbedder(limit: 500))
        await service.setEnvironmentProvider { env }
        #expect(await service.bulkEmbeddingPaused != nil)
    }

    @Test func aModelServersEmbeddingsAreNeverPausedByThisPolicy() async throws {
        let f = try KnowledgeFixture()
        let (service, _, _) = make(f, embedder: FakeEmbedder(space: EmbeddingSpace(model: "nomic", dimensions: 8)), choice: .server)
        await service.setEnvironmentProvider { IndexerEnvironment(lowPowerMode: true, onBattery: true) }
        #expect(await service.bulkEmbeddingPaused == nil)
        #expect(await service.queryEmbeddingAllowed)
    }

    @Test func aQueryIsEmbeddedExceptWhenTheMacIsCriticallyHot() async throws {
        let f = try KnowledgeFixture()
        let (service, _, _) = make(f, embedder: BudgetedEmbedder(limit: 500))
        // Recording, low power and battery do not stop one short query.
        await service.setEnvironmentProvider { IndexerEnvironment(isRecording: true, lowPowerMode: true, thermalState: .serious, onBattery: true) }
        let language = OutputLanguage(Locale(identifier: "en"))
        let query = try await service.queryVector("budget", language: language)
        #expect(query?.vector.count == 256 && query?.space == ConceptEmbedder.space)
        await service.setEnvironmentProvider { IndexerEnvironment(thermalState: .critical) }
        #expect(try await service.queryVector("budget", language: language) == nil, "keywords for that query")
    }

    @Test func chunksAreMadeWithTheModelsBudgetAndStayFresh() async throws {
        let f = try KnowledgeFixture()
        let long = (0..<44).map { "line \($0) has exactly six words" }
        let id = try await f.meeting(long, locale: "en")
        let small = BudgetedEmbedder(limit: 60)
        let (service, _, _) = make(f, embedder: small)
        await service.setEnvironmentProvider { IndexerEnvironment() }
        try await service.embed(id)
        let withBudget = try await f.store.intsForTest("SELECT COUNT(*) FROM chunks WHERE meeting_id = ?", [.integer(id)])[0]
        let plain = try await f.store.chunkPlan(id).count
        #expect(withBudget > Int64(plain), "the model's limit makes more, smaller chunks")
        #expect(try await f.store.chunksOutOfDate(id, budget: small.chunkBudget()) == false)
    }

    @Test func theRankingModeFollowsCoverageAndRemembersCompleteCoverage() async throws {
        let f = try KnowledgeFixture()
        let (service, _, defaults) = make(f, embedder: BudgetedEmbedder(limit: 500))
        let a = try await f.meeting(["The launch plan and the release rollout."], locale: "en")
        let b = try await f.meeting(["The hiring plan for the quarter."], locale: "en")
        let space = ConceptEmbedder.space
        func embed(_ id: Int64) async throws {
            let plan = try await f.store.chunkPlan(id)
            let items = plan.map { c in (start: c.start, end: c.end, q: VectorIndex.quantize(ConceptEmbedder.vector(c.text))!.q,
                                        scale: VectorIndex.quantize(ConceptEmbedder.vector(c.text))!.scale, key: MeetingStore.textKey(c.text)) }
            try await f.store.replaceChunks(id, items, space: space)
        }
        #expect(await service.meetingRankingMode(space: space, within: nil) == .keyword, "nothing indexed yet")
        try await embed(a)
        #expect(await service.meetingRankingMode(space: space, within: nil) == .keyword, "backfill: half done")
        #expect(await service.meetingRankingMode(space: space, within: a) == .semantic, "inside a covered meeting")
        #expect(await service.meetingRankingMode(space: space, within: b) == .keyword)
        try await embed(b)
        #expect(await service.meetingRankingMode(space: space, within: nil) == .semantic)
        #expect(defaults.bool(forKey: "searchModelCoverageReached.\(space.model).meetings"))
        // A server's space keeps the fusion.
        #expect(await service.meetingRankingMode(space: EmbeddingSpace(model: "nomic", dimensions: 8), within: nil) == .rrf)
        #expect(await service.meetingRankingMode(space: nil, within: nil) == .keyword)
    }

    @Test func aFilterRanksByItsOwnMeetingsAndLooksOnlyInThem() async throws {
        let f = try KnowledgeFixture()
        let (service, _, _) = make(f, embedder: BudgetedEmbedder(limit: 500))
        let a = try await f.meeting(["The launch plan and the release rollout."], locale: "en")
        let b = try await f.meeting(["Another release rollout review."], locale: "en")
        let c = try await f.meeting(["The release rollout slipped a week."], locale: "en")
        let space = ConceptEmbedder.space
        for id in [a, b] {
            let plan = try await f.store.chunkPlan(id)
            try await f.store.replaceChunks(id, plan.map { c in
                let q = VectorIndex.quantize(ConceptEmbedder.vector(c.text))!
                return (start: c.start, end: c.end, q: q.q, scale: q.scale, key: MeetingStore.textKey(c.text))
            }, space: space)
        }
        // The library is still indexing (c has no vectors), but a filter of indexed meetings ranks by meaning.
        #expect(await service.meetingRankingMode(space: space, within: nil) == .keyword)
        #expect(try await f.store.vectorCoverage(space: space, meetings: [a, c]) == .init(covered: 1, total: 2))
        #expect(await service.meetingRankingMode(space: space, within: nil, meetings: [a, b]) == .semantic)
        #expect(await service.meetingRankingMode(space: space, within: nil, meetings: [a, c]) == .keyword)
        #expect(await service.meetingRankingMode(space: space, within: nil, meetings: []) == .keyword, "nothing to rank")
        #expect(await service.meaningMatches(for: "release rollout") == nil, "the whole library still ranks by keywords")
        let found = try #require(await service.meaningMatches(for: "release rollout", in: [b]))
        #expect(found.meetings.map(\.meeting.id) == [b])
        #expect(found.documents.isEmpty)
    }

    @Test func oneMeetingWhoseEmbeddingJobFailedForGoodDoesNotKeepAskOnKeywords() async throws {
        let f = try KnowledgeFixture()
        let (service, _, _) = make(f, embedder: BudgetedEmbedder(limit: 500))
        let a = try await f.meeting(["The launch plan and the release rollout."], locale: "en")
        let b = try await f.meeting(["The hiring plan for the quarter."], locale: "en")
        let space = ConceptEmbedder.space
        let plan = try await f.store.chunkPlan(a)
        try await f.store.replaceChunks(a, plan.map { c in
            let q = VectorIndex.quantize(ConceptEmbedder.vector(c.text))!
            return (start: c.start, end: c.end, q: q.q, scale: q.scale, key: MeetingStore.textKey(c.text))
        }, space: space)
        // The first backfill: b is still to do, so Ask stays on keywords...
        #expect(try await f.store.vectorCoverage(space: space) == .init(covered: 1, total: 2))
        #expect(await service.meetingRankingMode(space: space, within: nil) == .keyword)
        // ...until its job runs out of attempts: it counts as neither covered nor missing, and the rest ranks by meaning.
        try await f.store.enqueueJob(.embed, meeting: b)
        let job = try #require(try await f.store.jobs(for: b).first { $0.kind == .embed })
        try await f.store.markJob(job.id, .failed, code: JobErrorCode(LLMError.invalidResponse("x")))
        #expect(try await f.store.vectorCoverage(space: space) == .init(covered: 1, total: 1))
        #expect(await service.meetingRankingMode(space: space, within: nil) == .semantic)
        // Settings changes forget the failed job: b counts again (and is tried again).
        try await f.store.forgetFailedJobs(.embed)
        #expect(try await f.store.vectorCoverage(space: space) == .init(covered: 1, total: 2))
    }

    @Test func embeddingStopsAndStoresNothingWhileTheSearchModelIsBeingDeleted() async throws {
        let f = try KnowledgeFixture()
        let (service, _, _) = make(f, embedder: BudgetedEmbedder(limit: 500))
        await service.setEnvironmentProvider { IndexerEnvironment() }
        let id = try await f.meeting(Self.lines, locale: "en")
        await service.searchModelRemoving()
        await #expect(throws: CancellationError.self) { try await service.embed(id) }
        #expect(try await f.store.hasChunks(id) == false)
        #expect(await service.embedDocumentPassages(allowNetwork: false) == 0)
        // Once the removal is over the service works again (with the model back, or another provider).
        await service.searchModelRemoved()
        try await service.embed(id)
        #expect(try await f.store.hasChunks(id))
    }

    @Test func theServicePublishesHowMuchIsIndexed() async throws {
        let f = try KnowledgeFixture()
        let docs = try IndexFixture()
        try await docs.add("a.txt", text: "Alpha\nA passage about launch plans.")
        let (service, _, _) = make(f, embedder: BudgetedEmbedder(limit: 500))
        await service.setDocuments(docs.index)
        await service.setEnvironmentProvider { IndexerEnvironment(isRecording: true) }
        let id = try await f.meeting(Self.lines)
        _ = id
        await service.refreshSearchCoverage()
        let index = try #require(await service.status.searchIndex)
        #expect(index.meetings == .init(covered: 0, total: 1) && index.documents == .init(covered: 0, total: 1))
        #expect(index.pause == .recording && !index.isComplete && index.fraction == 0)
        // Documents are embedded locally with the model, in requests of up to 32, and the coverage follows.
        await service.setEnvironmentProvider { IndexerEnvironment() }
        #expect(await service.embedDocumentPassages(allowNetwork: false) == 1)
        let after = try #require(await service.status.searchIndex)
        #expect(after.documents.isComplete && after.pause == nil)
    }

    @Test func removingTheModelDropsItsVectorsAndNothingElse() async throws {
        let f = try KnowledgeFixture()
        let docs = try IndexFixture()
        try await docs.add("a.txt", text: "Alpha\nA passage about launch plans.")
        let (service, providers, _) = make(f, embedder: BudgetedEmbedder(limit: 500))
        await service.setDocuments(docs.index)
        let id = try await f.meeting(Self.lines)
        try await service.embed(id)
        _ = await service.embedDocumentPassages(allowNetwork: false)
        let hadChunks = try await f.store.hasChunks(id), vectors = try await docs.index.vectorCount()
        #expect(hadChunks && vectors == 1)
        providers.embeddingChoice = ModelProviderSettings.Embeddings.none   // Settings goes back to keyword search when the model is deleted
        await service.searchModelRemoved()
        let stillChunks = try await f.store.hasChunks(id), vectorsLeft = try await docs.index.vectorCount()
        #expect(!stillChunks && vectorsLeft == 0)
        #expect(await service.status.searchIndex == nil)
    }

    @Test func aMissingModelIsReportedAsAnIssueNotACrash() async throws {
        let access = SearchModelAccess()
        let defaults = UserDefaults(suiteName: "vauta.tests.\(UUID().uuidString)")!
        ModelProviderSettings(chat: .onDevice, embeddings: .onDeviceModel).save(defaults: defaults)
        let providers = SystemModelProviders(client: LLMClient(), defaults: defaults, searchModel: access, loadConfig: { nil })
        guard case .unavailable(.searchModelNotInstalled) = providers.embeddings() else { Issue.record("expected not installed"); return }
        access.set(.unavailable(.selfTestFailed), model: nil)
        guard case .unavailable(.searchModelUnavailable(.selfTestFailed)) = providers.embeddings() else { Issue.record("expected unavailable"); return }
        #expect(LLMService.error(for: .searchModelNotInstalled) == .searchModelUnavailable)
        #expect(LLMService.error(for: .searchModelUnavailable(.unsupportedHardware)) == .searchModelUnavailable)
        #expect(ProviderIssue.searchModelNotInstalled.localizedDescription.isEmpty == false)
        #expect(ProviderIssue.searchModelUnavailable(.selfTestFailed).recoverySuggestion != nil)
        #expect(JobErrorCode(LLMError.searchModelUnavailable) == .searchModelUnavailable)
        #expect(JobErrorCode.searchModelUnavailable.rawValue == "search_model_unavailable")
    }

    @Test func anInstalledModelIsOneModelForEveryLanguage() throws {
        let access = SearchModelAccess()
        let defaults = UserDefaults(suiteName: "vauta.tests.\(UUID().uuidString)")!
        ModelProviderSettings(chat: .onDevice, embeddings: .onDeviceModel).save(defaults: defaults)
        let engine = SearchModelEngine(store: SearchModelStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("vauta-none-\(UUID().uuidString)")))
        access.set(.installed, model: GemmaEmbeddingModel(engine: engine))
        let providers = SystemModelProviders(client: LLMClient(), defaults: defaults, searchModel: access, loadConfig: { nil })
        guard case .available(let model, let expected) = providers.embeddings() else { Issue.record("expected available"); return }
        for code in ["en", "es", "ja", "zh-Hans", "ar"] {
            #expect(model(Locale.Language(identifier: code)) != nil)
            #expect(expected(Locale.Language(identifier: code)) == "embeddinggemma-2@914f7f89/r1")
        }
    }
}

/// An embedder whose engine could not embed anything: it answers zero vectors, as `GemmaEmbeddingModel` does for a query.
struct ZeroVectorEmbedder: EmbeddingModel {
    func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> EmbeddingBatch {
        EmbeddingBatch(vectors: texts.map { _ in [Float](repeating: 0, count: 256) }, space: ConceptEmbedder.space)
    }
}

@Suite("Service: unembeddable query")
struct ServiceUnembeddableQueryTests {
    @Test func aQueryTheModelCouldNotEmbedFallsBackToKeywords() async throws {
        let f = try KnowledgeFixture()
        let providers = TestProviders(chat: ScriptedChat { messages, _, _ in ScriptedChat.reply(ScriptedChat.minutesJSON(messages)) }, embedder: ZeroVectorEmbedder())
        providers.embeddingChoice = .onDeviceModel
        nonisolated(unsafe) let defaults = UserDefaults(suiteName: "vauta.tests.\(UUID().uuidString)")!
        let service = LLMService(store: f.store, providers: providers, searchDefaults: defaults)
        #expect(try await service.queryVector("budget", language: OutputLanguage(Locale(identifier: "en"))) == nil)
    }

    @Test func theEngineGivesAnEmptyVectorForAQueryItCannotEmbed() async throws {
        let f = try EngineFixture()
        defer { f.cleanup() }
        await f.engine.setForcedNonFinite(rows: [0], inFP32: true)
        let batch = try await GemmaEmbeddingModel(engine: f.engine).embed(["ab"], purpose: .query)
        #expect(batch.vectors[0].allSatisfy { $0 == 0 })
    }
}

/// Changes the Mac's state after its first batch, as unplugging it in the middle of a long job would.
struct UnpluggingEmbedder: ChunkBudgeting {
    let calls = SharedBox(0)
    let onFirstCall: @Sendable () -> Void
    func chunkBudget() async throws -> ChunkBudget { ChunkBudget(limit: 7) { $0.split(separator: " ").count } }
    func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> EmbeddingBatch {
        if calls.value == 0 { onFirstCall() }
        calls.add(1)
        return EmbeddingBatch(vectors: texts.map(ConceptEmbedder.vector), space: ConceptEmbedder.space)
    }
}

@Suite("Service: embedding jobs and the Mac's state")
struct ServiceEmbedJobPauseTests {
    @Test func aRunningEmbedJobStopsBetweenBatchesWhenTheMacIsUnplugged() async throws {
        let f = try KnowledgeFixture()
        let env = SharedBox(IndexerEnvironment())
        let embedder = UnpluggingEmbedder { env.mutate { $0 = IndexerEnvironment(onBattery: true) } }
        let providers = TestProviders(chat: ScriptedChat { messages, _, _ in ScriptedChat.reply(ScriptedChat.minutesJSON(messages)) }, embedder: embedder)
        providers.embeddingChoice = .onDeviceModel
        nonisolated(unsafe) let defaults = UserDefaults(suiteName: "vauta.tests.\(UUID().uuidString)")!
        let service = LLMService(store: f.store, providers: providers, searchDefaults: defaults)
        await service.setEnvironmentProvider { env.value }
        let id = try await f.meeting((0..<160).map { "line \($0) has exactly six words" })
        await service.meetingEnded(id)
        #expect(await eventually { embedder.calls.value >= 1 })
        #expect(await eventually {
            let job = try await f.store.jobs(for: id).first { $0.kind == .embed }
            return job?.state == .queued && job?.attempts == 0
        })
        #expect(embedder.calls.value == 1, "stopped before the second batch")
        #expect(try await f.store.hasChunks(id) == false)
    }
}

@Suite("Service: coverage memory")
struct ServiceCoverageMemoryTests {
    @Test func leavingTheSearchModelForgetsThatItsIndexWasComplete() async throws {
        let f = try KnowledgeFixture()
        let providers = TestProviders(chat: ScriptedChat { messages, _, _ in ScriptedChat.reply(ScriptedChat.minutesJSON(messages)) }, embedder: BudgetedEmbedder(limit: 500))
        providers.embeddingChoice = .onDeviceModel
        nonisolated(unsafe) let defaults = UserDefaults(suiteName: "vauta.tests.\(UUID().uuidString)")!
        let service = LLMService(store: f.store, providers: providers, searchDefaults: defaults)
        let keys = ["meetings", "documents"].map { "searchModelCoverageReached.\(GemmaEmbeddingModel.space.model).\($0)" }
        keys.forEach { defaults.set(true, forKey: $0) }
        await service.configurationChanged()
        #expect(keys.allSatisfy { defaults.bool(forKey: $0) }, "still the search model: kept")
        providers.embeddingChoice = .server
        await service.configurationChanged()
        #expect(keys.allSatisfy { !defaults.bool(forKey: $0) }, "another choice: forgotten")
    }
}
