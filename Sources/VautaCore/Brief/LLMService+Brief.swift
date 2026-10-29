// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The brief's use of the model layer: the retrieval (the search model, never a remote embedding model) and the suggested agenda.
///
/// While a meeting is recorded nothing here starts a model call: the retrieval is lexical and the agenda is refused, so a recording
/// never waits for a brief.
extension LLMService {
    /// Where the agenda would be written now, or nil when no chat model can be used.
    public func briefBackend() -> BriefBackend? {
        guard case .success(let chat) = providers.chat(for: .main) else { return nil }
        if chat.integrated { return .integrated }
        return chat.onDevice ? .apple : .server
    }

    /// The integrated model is in memory now (the brief never loads it on battery or under memory pressure; a loaded one is used).
    public func briefIntegratedLoaded() async -> Bool {
        guard let model = LanguageModelAccess.shared.chatModel else { return false }
        return await model.engine.isLoaded
    }

    /// The context window the agenda is sized for.
    public func briefBudget() -> ContextBudget? {
        guard case .success(let chat) = providers.chat(for: .main) else { return nil }
        return ContextBudget(contextTokens: chat.contextTokens)
    }

    /// The search model ranks the brief only when `BriefRankingShipping` allows it and when it is installed and its vectors cover the library (the same rule as Ask), nothing keeps
    /// the Mac from embedding, and no meeting is being recorded. Embeddings on a model server never rank a brief: the topic would leave
    /// this Mac.
    func briefRankingMode() async -> BriefRankingMode {
        guard BriefRankingShipping.searchModelRanks, !recording, providers.settings.embeddings == .onDeviceModel, queryEmbeddingAllowed,
              case .available = providers.embeddings() else { return .keyword }
        let space = GemmaEmbeddingModel.space
        let meetings = await meetingRankingMode(space: space, within: nil)
        let docs = documents == nil ? SemanticRanker.Mode.semantic : await documentRankingMode(space: space, filter: nil)
        return meetings == .semantic && docs == .semantic ? .semantic : .keyword
    }

    func briefMeetings(for query: String, excluding: Set<Int64>, limit: Int, mode: BriefRankingMode) async -> [BriefMeetingHit] {
        let locale = Locale(identifier: OutputLanguage.detect(query, fallback: OutputLanguage(Locale.current)).identifier)
        var found: [RetrievedPassage] = []
        if mode == .semantic, !recording, let q = await meaningQuery(query) {
            found = (try? await store.retrieve(query, queryVector: q.vector, excluding: excluding.first, space: q.space, limit: limit + excluding.count,
                                               locale: locale, mode: .semantic)) ?? []
        } else {
            found = (try? await store.retrieve(query, queryVector: nil, excluding: excluding.first, limit: limit + excluding.count, locale: locale,
                                               mode: .keyword)) ?? []
        }
        return found.filter { !excluding.contains($0.meeting.id) }.prefix(limit).map { passage in
            let text = passage.segments.map(\.text).joined(separator: " ")
            return BriefMeetingHit(meetingID: passage.meeting.id,
                                   title: MeetingStore.Meeting.displayTitle(passage.meeting.title, startedAt: passage.meeting.startedAt),
                                   date: passage.meeting.startedAt, text: String(text.prefix(400)), segmentID: passage.segments.first?.id, t: passage.start,
                                   cosine: passage.cosine)
        }
    }

    func briefDocuments(for query: String, limit: Int, mode: BriefRankingMode) async -> [BriefDocumentHit] {
        guard let documents else { return [] }
        let locale = Locale(identifier: OutputLanguage.detect(query, fallback: OutputLanguage(Locale.current)).identifier)
        var found: [DocumentPassage] = []
        if mode == .semantic, !recording, let q = await meaningQuery(query) {
            found = (try? await documents.search(query, queryVector: q.vector, space: q.space, limit: limit, locale: locale, mode: .semantic)) ?? []
        } else {
            found = (try? await documents.search(query, limit: limit, locale: locale, mode: .keyword)) ?? []
        }
        return found.map { p in
            BriefDocumentHit(sourceID: p.sourceID, relPath: p.relPath, fileName: p.fileName, passageKey: p.key, text: String(VautaPrompts.body(of: p).prefix(400)),
                             cosine: p.cosine)
        }
    }

    /// The raw cosine of each text to the topic with the search model (short texts, on the fly). nil when it cannot be done.
    func briefCosines(query: String, texts: [String]) async -> [Double]? {
        guard !recording, providers.settings.embeddings == .onDeviceModel, queryEmbeddingAllowed,
              case .available(let model, _) = providers.embeddings() else { return nil }
        guard !texts.isEmpty else { return [] }
        let language = OutputLanguage.detect(query, fallback: OutputLanguage(Locale.current))
        guard let q = try? await queryVector(String(query.prefix(BriefQuery.maximumCharacters)), language: language),
              SemanticRanker.isSearchModelSpace(q.space.model), let embedder = model(Locale(identifier: language.identifier).language) else { return nil }
        var out: [Double] = []
        var index = 0
        while index < texts.count {
            let batch = texts[index..<min(texts.count, index + 64)].map { String($0.prefix(300)) }
            guard let vectors = try? await embedder.embed(batch, purpose: .document).vectors, vectors.count == batch.count else { return nil }
            out += vectors.map { QuestionDedup.cosine(q.vector, $0) }
            index += 64
        }
        return out
    }

    /// One request for the suggested agenda. Refused while recording; the reply is judged by `BriefVerifier`, not here.
    func briefWrite(_ messages: [ChatMessage], schema: OutputSchema, maxTokens: Int, backend: BriefBackend) async throws -> String {
        guard !recording else { throw LLMError.modelUnavailable }
        let chat = try chatProvider()
        // The prompt was packed for `backend` (a model server never receives the invitation's lines). If the provider changed since,
        // nothing is sent: the next build packs for the one in use.
        guard briefBackend() == backend else { throw LLMError.modelUnavailable }
        var options = ChatOptions(model: .deep, maxTokens: maxTokens, purpose: .brief, outputSchema: chat.integrated ? schema : nil, priority: .brief,
                                  maxSeconds: chat.integrated ? backend.timeoutSeconds : nil)
        if backend == .server { options.responseFormat = .jsonSchema(name: "brief_agenda", schema: schema.jsonSchemaData()) }
        // A server that does not understand the schema is asked once more without it: the prompt carries the same shape.
        return try await StructuredOutputRetry.run(&options) { try await chat.model.chat(messages, $0, onProgress: nil).content }
    }

    /// The retrieval and the writer of the brief, backed by this service.
    public nonisolated func briefAdapters() -> (retriever: any BriefRetriever, writer: any BriefAgendaWriter) {
        let adapter = BriefAdapter(service: self)
        return (adapter, adapter)
    }
}

private struct BriefAdapter: BriefRetriever, BriefAgendaWriter {
    let service: LLMService
    func mode() async -> BriefRankingMode { await service.briefRankingMode() }
    func meetings(for query: String, excluding: Set<Int64>, limit: Int, mode: BriefRankingMode) async -> [BriefMeetingHit] {
        await service.briefMeetings(for: query, excluding: excluding, limit: limit, mode: mode)
    }
    func documents(for query: String, limit: Int, mode: BriefRankingMode) async -> [BriefDocumentHit] {
        await service.briefDocuments(for: query, limit: limit, mode: mode)
    }
    func cosines(query: String, texts: [String]) async -> [Double]? { await service.briefCosines(query: query, texts: texts) }
    func write(_ messages: [ChatMessage], schema: OutputSchema, maxTokens: Int, backend: BriefBackend) async throws -> String {
        try await service.briefWrite(messages, schema: schema, maxTokens: maxTokens, backend: backend)
    }
}
