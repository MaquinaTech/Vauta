// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Search by meaning with the search model: which ranking Ask and the sidebar use, how much of the library is indexed, and the
/// housekeeping when the model goes away.
extension LLMService {
    /// How much of the library has vectors in the search model's space, for the Settings progress line and the Ask mode label.
    public struct SearchIndexStatus: Sendable, Equatable {
        public var meetings = SemanticRanker.Coverage(covered: 0, total: 0)
        public var documents = SemanticRanker.Coverage(covered: 0, total: 0)
        /// Why indexing waits (recording, Low Power Mode, a hot Mac, the battery), when it does.
        public var pause: IndexerPolicy.PauseReason?
        public var onBattery = false
        /// The search model ranks Ask and the sidebar now, for meetings and documents (the coverage rule is met for both); false
        /// while one of them still indexes.
        public var ranking = false
        /// The rule is decided per corpus: meetings already rank by meaning while the documents may still index, and the other way
        /// round. A corpus with nothing in it counts as ranking.
        public var meetingsRanking = false
        public var documentsRanking = false

        public init() {}

        public var covered: Int { meetings.covered + documents.covered }
        public var total: Int { meetings.total + documents.total }
        /// Items (chunks of meetings, passages of documents) the model looked at and could not embed. They are left out of the way
        /// to complete the index; keywords still find them.
        public var skipped: Int { meetings.skipped + documents.skipped }
        public var isComplete: Bool { meetings.isComplete && documents.isComplete }
        public var fraction: Double { total == 0 ? 1 : Double(covered) / Double(total) }
    }

    private static func reachedKey(_ space: EmbeddingSpace, _ kind: String) -> String { "searchModelCoverageReached.\(space.model).\(kind)" }

    /// The space the person's search runs in when it is the search model's (nil otherwise).
    private var searchModelSpace: EmbeddingSpace? {
        providers.settings.embeddings == .onDeviceModel ? GemmaEmbeddingModel.space : nil
    }

    /// The ranking for meetings, from the question's space and how much of the meetings is indexed. Complete coverage is
    /// remembered, so adding a meeting does not flip Ask back to keywords for a minute.
    ///
    /// `heardLive`: the ranking for a question heard in the meeting being recorded. That meeting ranks by keywords whatever chunks the typed
    /// questions stored (they stop at the last typed question, and the measured live path is keywords with a translated question).
    func meetingRankingMode(space: EmbeddingSpace?, within: Int64?, heardLive: Bool = false) async -> SemanticRanker.Mode {
        guard let space else { return .keyword }
        guard SemanticRanker.isSearchModelSpace(space.model) else { return .rrf }
        if heardLive, let within, recording, liveSessionMeeting == within { return .keyword }
        if let within { return SemanticRanker.mode(space: space, coverage: .init(covered: 0, total: 0), reachedBefore: false,
                                                   scopeCovered: (try? await store.isCovered(within, space: space)) ?? false) }
        let coverage = (try? await store.vectorCoverage(space: space)) ?? .init(covered: 0, total: 0)
        let key = Self.reachedKey(space, "meetings")
        if coverage.isComplete, coverage.total > 0 { searchDefaults.set(true, forKey: key) }
        return SemanticRanker.mode(space: space, coverage: coverage, reachedBefore: searchDefaults.bool(forKey: key))
    }

    /// The ranking for documents (`filter`: a meeting's materials, nil: all).
    func documentRankingMode(space: EmbeddingSpace?, filter: DocumentFilter?) async -> SemanticRanker.Mode {
        guard let space else { return .keyword }
        guard SemanticRanker.isSearchModelSpace(space.model) else { return .rrf }
        guard let documents else { return .keyword }
        if let filter { return SemanticRanker.mode(space: space, coverage: .init(covered: 0, total: 0), reachedBefore: false,
                                                    scopeCovered: (try? await documents.isCovered(filter, space: space)) ?? false) }
        let coverage = (try? await documents.vectorCoverage(space: space)) ?? .init(covered: 0, total: 0)
        let key = Self.reachedKey(space, "documents")
        if coverage.isComplete, coverage.total > 0 { searchDefaults.set(true, forKey: key) }
        return SemanticRanker.mode(space: space, coverage: coverage, reachedBefore: searchDefaults.bool(forKey: key))
    }

    /// Sets how the service sees the Mac (recording, power, heat), for the pause rules of bulk embedding and the thermal fallback
    /// of query embedding.
    public func setEnvironmentProvider(_ provider: @escaping @Sendable () -> IndexerEnvironment) {
        environmentProvider = provider
    }

    /// Bulk embedding of meetings waits while recording and after (two minutes), in Low Power Mode, when the Mac is hot and on
    /// battery. Only when the search model does the embedding: a model server has its own rules.
    var bulkEmbeddingPaused: IndexerPolicy.PauseReason? {
        guard providers.settings.embeddings == .onDeviceModel else { return nil }
        let policy = IndexerPolicy.decide(environmentProvider())
        if let reason = policy.pause { return reason }
        return policy.embeddings ? nil : .lowPower
    }

    /// A query is embedded on this Mac unless the Mac is critically hot: then search uses keywords for that query.
    var queryEmbeddingAllowed: Bool {
        providers.settings.embeddings != .onDeviceModel || environmentProvider().thermalState != .critical
    }

    /// The Mac's state changed (the charger, Low Power Mode, heat, a recording): the embedding jobs that waited for it run again.
    public func environmentChanged() async {
        if bulkEmbeddingPaused == nil { try? await store.releaseDeferredEmbeddings() }
        await refreshSearchCoverage()
        await runWaitingLinkPasses()
        kick()
    }

    /// Recomputes how much of the library is indexed and publishes it. Cheap (a few counts), called after embedding work.
    public func refreshSearchCoverage() async {
        guard let space = searchModelSpace, case .available = providers.embeddings() else {
            if status.searchIndex != nil { status.searchIndex = nil; publish() }
            return
        }
        var index = SearchIndexStatus()
        index.meetings = (try? await store.vectorCoverage(space: space)) ?? index.meetings
        if let documents { index.documents = (try? await documents.vectorCoverage(space: space)) ?? index.documents }
        let env = environmentProvider()
        index.pause = IndexerPolicy.decide(env).pause
        index.onBattery = env.onBattery
        let meetingMode = await meetingRankingMode(space: space, within: nil)
        let documentMode = await documentRankingMode(space: space, filter: nil)
        index.meetingsRanking = index.meetings.total == 0 || meetingMode == .semantic
        index.documentsRanking = index.documents.total == 0 || documentMode == .semantic
        index.ranking = index.meetingsRanking && index.documentsRanking
        if index.isComplete {
            searchDefaults.set(true, forKey: Self.reachedKey(space, "meetings"))
            searchDefaults.set(true, forKey: Self.reachedKey(space, "documents"))
        }
        if status.searchIndex != index { status.searchIndex = index; publish() }
    }

    func forgetSearchModelCoverage() {
        for kind in ["meetings", "documents"] { searchDefaults.removeObject(forKey: Self.reachedKey(GemmaEmbeddingModel.space, kind)) }
    }

    /// The search model is about to be deleted: the embedding job that is running stops, and nothing is stored in its space until
    /// `searchModelRemoved` (a batch that was already being computed is dropped, not stored after the vectors were removed).
    public func searchModelRemoving() {
        searchModelRetiring = true
        if currentJob?.kind == .embed { backgroundTask?.cancel() }
    }

    /// The search model was deleted: its vectors are useless without the model that embeds questions, so they go.
    public func searchModelRemoved() async {
        try? await store.dropChunks(modelPrefix: "embeddinggemma-2@")
        try? await store.dropItemVectors(modelPrefix: "embeddinggemma-2@")
        try? await documents?.dropVectors(modelPrefix: "embeddinggemma-2@")
        forgetSearchModelCoverage()
        status.searchIndex = nil
        searchModelRetiring = false
        await configurationChanged()
    }
}

/// Search by meaning outside Ask: the sidebar's "By meaning" group, the related documents and the related meetings of a meeting.
/// All of them need the search model to be ready and its vectors to cover the library (the same rule as Ask); otherwise they return
/// nil and the caller keeps the keyword results it already has.
extension LLMService {
    public struct MeaningMatches: Sendable {
        public let meetings: [RetrievedPassage]
        public let documents: [DocumentPassage]
    }

    func meaningQuery(_ text: String) async -> (vector: [Float], space: EmbeddingSpace)? {
        guard providers.settings.embeddings == .onDeviceModel else { return nil }
        let language = OutputLanguage.detect(text, fallback: OutputLanguage(Locale.current))
        guard let query = try? await queryVector(String(text.prefix(400)), language: language),
              SemanticRanker.isSearchModelSpace(query.space.model) else { return nil }
        return query
    }

    /// The best passages of the meetings and of the documents for `text`, by meaning (`SemanticRanker.related`: no cosine below
    /// `SemanticRanker.relatedFloor`). nil when the search model is not ranking (not installed, still indexing, or the question
    /// could not be embedded). Twice the passages are asked for, so the ones the floor drops leave room for others.
    public func meaningMatches(for text: String, meetingLimit: Int = 5, documentLimit: Int = 5) async -> MeaningMatches? {
        guard let query = await meaningQuery(text) else { return nil }
        let locale = Locale(identifier: OutputLanguage.detect(text, fallback: OutputLanguage(Locale.current)).identifier)
        let meetingMode = await meetingRankingMode(space: query.space, within: nil)
        let documentMode = await documentRankingMode(space: query.space, filter: nil)
        guard meetingMode == .semantic || documentMode == .semantic else { return nil }
        var meetings: [RetrievedPassage] = []
        if meetingMode == .semantic {
            let found = (try? await store.retrieve(text, queryVector: query.vector, space: query.space, limit: 2 * meetingLimit, locale: locale, mode: .semantic)) ?? []
            meetings = SemanticRanker.related(found, cosine: \.cosine, limit: meetingLimit)
        }
        var documentPassages: [DocumentPassage] = []
        if documentMode == .semantic, let documents {
            let found = (try? await documents.search(text, queryVector: query.vector, space: query.space, limit: 2 * documentLimit, locale: locale, mode: .semantic)) ?? []
            documentPassages = SemanticRanker.related(found, cosine: \.cosine, limit: documentLimit)
        }
        return MeaningMatches(meetings: meetings, documents: documentPassages)
    }

    /// Passages of the person's documents that go with `words` (the topics and decisions of a meeting), by meaning
    /// (`SemanticRanker.related`). nil when the search model is not ranking documents: the caller then uses keywords.
    public func relatedDocuments(for words: String, limit: Int = 3) async -> [DocumentPassage]? {
        guard let documents, let query = await meaningQuery(words),
              await documentRankingMode(space: query.space, filter: nil) == .semantic else { return nil }
        let locale = Locale(identifier: OutputLanguage.detect(words, fallback: OutputLanguage(Locale.current)).identifier)
        let found = try? await documents.search(words, queryVector: query.vector, space: query.space, limit: 2 * limit, locale: locale, mode: .semantic)
        return found.map { SemanticRanker.related($0, cosine: \.cosine, limit: limit) }
    }

    /// Up to `limit` other meetings whose best passage is close to `words` (cosine of at least `minimumScore`, `SemanticRanker.relatedFloor` by default). Only with the search
    /// model ranking meetings; there is no keyword version.
    public func relatedMeetings(for words: String, excluding meetingID: Int64, limit: Int = 3, minimumScore: Float = SemanticRanker.relatedFloor) async -> [(meeting: MeetingStore.Meeting, score: Float)]? {
        guard let query = await meaningQuery(words), await meetingRankingMode(space: query.space, within: nil) == .semantic else { return nil }
        return try? await store.relatedMeetings(queryVector: query.vector, space: query.space, excluding: meetingID, limit: limit, minimumScore: minimumScore)
    }
}
