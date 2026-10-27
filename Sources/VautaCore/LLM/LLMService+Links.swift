// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Links from the tasks and decisions of a meeting to earlier ones (post-meeting actions, Part B). The passes read the store and write
/// suggestions; the person confirms or dismisses each one. Nothing here runs while a meeting is recorded or in the two minutes after it,
/// in Low Power Mode or when the Mac is hot: the pass waits. Nothing runs at all until `LinksRelease` turns a backend on.
extension LLMService {
    /// The backend the work would run on now, or nil when there is no chat model.
    var linkBackend: LinkBackend? {
        guard case .success(let chat) = providers.chat() else { return nil }
        return chat.integrated ? .integrated : chat.measuredSmallWindow ? .apple : .server
    }

    /// The policy the passes run with, or nil when links are off for this backend.
    func activeLinkPolicy() -> LinkPolicy? {
        if let linkPolicyOverride { return linkPolicyOverride }
        guard let backend = linkBackend, LinksRelease.suggestions(backend) else { return nil }
        return .released(backend)
    }

    /// The same rule as the indexer's text rule: not while recording (nor 120 s after), not in Low Power Mode, not hot.
    func linkPassAllowed() -> Bool {
        !recording && IndexerPolicy.decide(environmentProvider()).text
    }

    /// Forces the link policy (tests and the evaluation); `nil` goes back to the release choice.
    public func setLinkPolicy(_ policy: LinkPolicy?) { linkPolicyOverride = policy }

    // MARK: Evaluation

    /// Evaluation only: the meeting's minutes are in the store as the model wrote them; runs what follows `acta` (the keyword pass, the
    /// embedding job queued behind it, the vector pass and the model check) through the real queue, and returns when the queue is idle.
    public func linksAfterMinutesForEvaluation(_ meetingID: Int64, laterMeetings: [Int64] = []) async -> Bool {
        evaluationSkipsChunks = true
        await linksAfterMinutes(meetingID, laterMeetings: laterMeetings)
        return await waitUntilQueueIdle()
    }

    /// Returns when no job is queued or running (or `timeout` passes), kicking the queue meanwhile. For the evaluation and tests.
    public func waitUntilQueueIdle(timeout: Duration = .seconds(1800)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if worker == nil, ((try? await store.pendingJobCount()) ?? 0) == 0 { return true }
            kick()
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    // MARK: Triggers

    /// The minutes were written (or rewritten): the keyword pass runs for the meeting, and again for the later meetings that lost a suggestion
    /// pointing into the items the rewrite replaced. The meeting's items are then queued for embedding.
    func linksAfterMinutes(_ meetingID: Int64, laterMeetings: [Int64]) async {
        guard activeLinkPolicy() != nil else { return }
        await linkPass(meetingID)
        for later in laterMeetings.sorted() where later != meetingID { await linkPass(later) }
        await enqueueLinkEmbedding(meetingID)
    }

    /// The person added, edited or checked an item: two seconds later (several edits make one pass) the pass runs for the meeting and its
    /// items are queued for embedding.
    public func itemsChanged(meetingID: Int64) async {
        guard activeLinkPolicy() != nil else { return }
        linkEditTimers[meetingID]?.cancel()
        let delay = linkEditDelay
        linkEditTimers[meetingID] = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self.fireLinkEdit(meetingID)
        }
    }

    private func fireLinkEdit(_ meetingID: Int64) async {
        linkEditTimers[meetingID] = nil
        await linkPass(meetingID)
        await enqueueLinkEmbedding(meetingID)
    }

    /// Meetings of the last 180 days that a pass with an older recipe produced (a recipe bump): they run again, replacing suggestions only.
    public func catchUpLinks() async {
        guard activeLinkPolicy() != nil else { return }
        for id in (try? await store.meetingsNeedingLinks()) ?? [] { await linkPass(id) }
    }

    /// The Mac is quiet again (or the retry fired): the passes that waited run.
    func runWaitingLinkPasses() async {
        guard !linksWaiting.isEmpty else { return }
        guard linkPassAllowed() else { scheduleLinkRetry(); return }
        let ids = linksWaiting.sorted()
        let checks = linksWaitingCheck
        linksWaiting = []
        linksWaitingCheck = []
        // The model check never runs outside the embed job (it holds the model's lane and waits for the charger): a pass that was to be
        // checked runs now without it, and the job is queued again.
        for id in ids {
            await linkPass(id)
            if checks.contains(id) { await enqueueLinkEmbedding(id) }
        }
    }

    private func scheduleLinkRetry() {
        linksRetry?.cancel()
        linksRetry = Task {
            try? await Task.sleep(for: .seconds(IndexerPolicy.resumeDelay + 10))
            guard !Task.isCancelled else { return }
            await self.runWaitingLinkPasses()
        }
    }

    /// Whether the search model can embed items now.
    private var searchModelAvailable: Bool {
        guard providers.settings.embeddings == .onDeviceModel, case .available = providers.embeddings() else { return false }
        return true
    }

    /// Queues the `embed` job for the meeting: it embeds the items (when the search model is there), runs the vector pass and then the model
    /// check. A backend with the check on needs the job even without the search model: the keyword pass is checked there too.
    private func enqueueLinkEmbedding(_ meetingID: Int64) async {
        guard let policy = activeLinkPolicy() else { return }
        if !searchModelAvailable {
            // Without the search model the job exists for the check alone; chunks of Ask are not its business, and an embedding model that
            // is unavailable would only make it fail.
            guard policy.modelCheck else { return }
            if case .unavailable = providers.embeddings() { return }
        }
        try? await store.enqueueJob(.embed, meeting: meetingID)
        await queueChanged()
    }

    // MARK: The pass

    /// Compares the meeting's items with earlier ones and replaces its suggestions. Returns the number of suggestions, or nil when links are
    /// off or the pass had to wait. Vectors are used for every pair that has them on both sides; the others go through the keyword gate.
    @discardableResult
    func linkPass(_ meetingID: Int64, check: Bool = false) async -> Int? {
        guard let policy = activeLinkPolicy() else { return nil }
        guard linkPassAllowed() else {
            linksWaiting.insert(meetingID)
            // Only a pass that would be checked asks for the embed job again; with the check off the resumed pass is the whole work.
            if check, policy.modelCheck { linksWaitingCheck.insert(meetingID) }
            scheduleLinkRetry()
            return nil
        }
        let started = ContinuousClock.now
        guard let inputs = try? await store.linkInputs(meetingID: meetingID, policy: policy) else { return nil }
        // A meeting with no items to link: nothing to suggest. Its recipe is recorded once its minutes exist (so it does not run again at every
        // launch); before that the minutes are not written yet.
        guard !inputs.sources.isEmpty else {
            let written = (try? await store.minutesWritten(meetingID)) ?? false
            try? await store.replaceSuggestions(meetingID: meetingID, proposals: [], markRecipe: written)
            onLinksChanged?(meetingID)
            return 0
        }
        var vectors: [String: LinkVector] = [:]
        if providers.settings.embeddings == .onDeviceModel, case .available(_, let expected) = providers.embeddings(),
           let model = expected(Locale.Language(identifier: "en")), SemanticRanker.isSearchModelSpace(model) {
            vectors = (try? await store.linkVectors(for: inputs, model: model)) ?? [:]
        }
        var proposals = LinkEngine(sources: inputs.sources, pool: inputs.pool, vectors: vectors, exclusions: inputs.exclusions, policy: policy).run()
        var modelCalls = 0
        if check, policy.modelCheck, !proposals.isEmpty {
            (proposals, modelCalls) = await checkWithModel(proposals, inputs: inputs, policy: policy)
        }
        try? await store.replaceSuggestions(meetingID: meetingID, proposals: proposals, perMeeting: policy.perMeeting)
        onLinksChanged?(meetingID)
        let elapsed = ContinuousClock.now - started
        let usedVectors = inputs.sources.contains { vectors[LinkExclusions.item($0.kind, $0.id)] != nil }
        var trace = LinkTrace(meetingID: meetingID, pass: usedVectors ? .vector : .keyword, sources: inputs.sources.count, pool: inputs.pool.count,
                              vectors: vectors.count, shown: proposals.count, milliseconds: Int((elapsed / .milliseconds(1)).rounded()))
        trace.duringRecording = recording
        trace.modelCalls = modelCalls
        if modelCalls > 0 { trace.pass = .checked }
        linkTraces.append(trace)
        return proposals.count
    }

    // MARK: Item embeddings

    /// Embeds the meeting's eligible items that have no vector (and up to 300 earlier ones) with the search model, then runs the vector
    /// pass. Part of the `embed` job: it waits for the charger, a quiet Mac and no recording like any embedding job, and a model server's
    /// embeddings are never used for links (they would send the items' words to it).
    func embedLinkItems(_ meetingID: Int64) async throws {
        guard let policy = activeLinkPolicy(), !recording else { return }
        if providers.settings.embeddings == .onDeviceModel, case .available(let model, let expected) = providers.embeddings(),
           let embedder = model(Locale.Language(identifier: "en")), let name = expected(Locale.Language(identifier: "en")),
           SemanticRanker.isSearchModelSpace(name) {
            try await embedMissingItems(meetingID, embedder: embedder, model: name, policy: policy)
        }
        // The pass that follows is the checked one. Without the search model it is the keyword pass that gets checked.
        await linkPass(meetingID, check: true)
    }

    private func embedMissingItems(_ meetingID: Int64, embedder: any EmbeddingModel, model name: String, policy: LinkPolicy) async throws {
        let missing = try await store.itemsWithoutVectors(meetingID: meetingID, model: name, policy: policy)
        for batchStart in stride(from: 0, to: missing.count, by: 32) {
            try Task.checkCancellation()
            if bulkEmbeddingPaused != nil || searchModelRetiring { throw CancellationError() }
            let batch = Array(missing[batchStart..<min(missing.count, batchStart + 32)])
            let result = try await embedder.embed(batch.map { LinkText.embeddingText($0.text) }, purpose: .document)
            guard result.vectors.count == batch.count, SemanticRanker.isSearchModelSpace(result.space.model) else { return }
            if searchModelRetiring { throw CancellationError() }
            var rows: [(kind: LinkKind, id: Int64, q: Data, scale: Float)] = []
            for (item, vector) in zip(batch, result.vectors) {
                if let (q, scale) = VectorIndex.quantize(vector) {
                    rows.append((item.kind, item.id, q, scale))
                } else {
                    // The model could not embed this text: a marker records it, so it is not tried again on every pass.
                    let (q, scale) = VectorIndex.unembeddableMarker(dims: result.space.dimensions)
                    rows.append((item.kind, item.id, q, scale))
                }
            }
            try await store.storeItemVectors(rows, model: result.space.model)
        }
    }

    // MARK: The model check

    /// Asks the backend's model about the pairs the deterministic pass found. It runs inside the job that holds the model's lane
    /// (the `embed` job), never while recording, never on a model server, and the integrated model only when it is loaded and the Mac is on
    /// the charger. A failure leaves the deterministic result. Returns the proposals and the number of calls.
    private func checkWithModel(_ proposals: [LinkProposal], inputs: LinkInputs, policy: LinkPolicy) async -> ([LinkProposal], Int) {
        guard !recording, let chat = try? chatProvider(), chat.integrated || chat.measuredSmallWindow else { return (proposals, 0) }
        let backend: LinkBackend = chat.integrated ? .integrated : .apple
        if backend == .integrated, policy.modelCheckNeedsLoadedModel {
            guard environmentProvider().onBattery == false, await briefIntegratedLoaded() else { return (proposals, 0) }
        }
        let items = Dictionary((inputs.sources + inputs.pool).map { (LinkExclusions.item($0.kind, $0.id), $0) }, uniquingKeysWith: { first, _ in first })
        var pairs: [LinkCheckPair] = []
        for (index, p) in proposals.enumerated() {
            guard let newer = items[LinkExclusions.item(p.kind, p.srcID)], let earlier = items[LinkExclusions.item(p.kind, p.dstID)] else { continue }
            pairs.append(LinkCheckPair(id: "p\(index + 1)", kind: p.kind, newer: newer.text, earlier: earlier.text, newerDate: newer.startedAt,
                                       earlierDate: earlier.startedAt, srcID: p.srcID, dstID: p.dstID, language: newer.language))
        }
        let language = OutputLanguage(Locale(identifier: inputs.sources.first?.locale ?? "en"))
        let packed = LinkVerifier.pack(pairs, backend: backend, budget: ContextBudget(contextTokens: chat.contextTokens), language: language)
        guard !packed.isEmpty else { return (proposals, 0) }
        let schema = LinkCheckPrompt.schema(packed)
        let options = ChatOptions(model: .deep, maxTokens: LinkVerifier.outputTokens + 100, outputSchema: chat.integrated ? schema : nil,
                                  priority: .bulk, maxSeconds: chat.integrated ? 30 : nil)
        do {
            let reply = try await chat.model.chat(LinkCheckPrompt.messages(packed, language: language), options, onProgress: nil).content
            let verdicts = LinkCheckPrompt.parse(reply)
            guard !verdicts.isEmpty else { return (proposals, 1) }
            // Pairs that were not packed keep the deterministic result.
            return (LinkVerifier.apply(proposals, pairs: packed, verdicts: verdicts, policy: policy), 1)
        } catch {
            return (proposals, 1)
        }
    }
}
