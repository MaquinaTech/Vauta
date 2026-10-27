// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Chunk embeddings for Ask, and keeping them in the current embedding space.
extension LLMService {
    /// Embeds a meeting's chunks with the model for its language. With
    /// embeddings turned off there is nothing to do.
    func embed(_ meetingID: Int64) async throws {
        // The links evaluation embeds items only: the chunks of Ask are not part of what it measures.
        if evaluationSkipsChunks { return }
        let embedder: any EmbeddingModel
        var expectedModel: String?
        switch providers.embeddings() {
        case .disabled:
            return
        case .unavailable(let issue):
            throw Self.error(for: issue)
        case .available(let model, let expected):
            guard let meeting = try await store.meeting(meetingID) else { return }
            guard let m = model(meeting.transcriptionLocale.language) else { throw LLMError.unsupportedLanguage }
            embedder = m
            expectedModel = expected(meeting.transcriptionLocale.language)
        }
        // A speaker named while this job runs changes the text it is embedding, and its own request to embed is
        // ignored (the job is still running): so look again after storing, and embed again while the text moved.
        // In the search model's space a chunk also has to fit its 512-token sequence.
        let budget = try? await (embedder as? ChunkBudgeting)?.chunkBudget()
        // With links on the job may be queued only for the meeting's items (after its minutes were written or an item was edited): chunks that
        // are already in this space and made from the current text are not embedded again. With links off nothing changes for Ask.
        if activeLinkPolicy() != nil, let expectedModel, let stored = (try? await store.chunkSpaces())?[meetingID], !stored.isEmpty,
           stored.allSatisfy({ space in space.model == expectedModel && (knownDimensions[expectedModel].map { $0 == space.dimensions } ?? true) }),
           (try? await store.chunksOutOfDate(meetingID, budget: budget)) == false {
            textChecked.insert(meetingID)
            return
        }
        var current = false
        for pass in 0..<4 {
            let plan = try await store.chunkPlan(meetingID, budget: budget)
            guard !plan.isEmpty else { return }
            var items: [(start: Double, end: Double, q: Data, scale: Float, key: String)] = []
            var space: EmbeddingSpace?
            for batchStart in stride(from: 0, to: plan.count, by: 32) {
                try Task.checkCancellation()
                // The Mac stopped being quiet (the charger was unplugged, Low Power Mode, heat, a recording): the job goes back to
                // the queue without using up an attempt, and nothing of this pass is stored.
                if bulkEmbeddingPaused != nil || searchModelRetiring { throw CancellationError() }
                let chunk = Array(plan[batchStart..<min(plan.count, batchStart + 32)])
                let batch = try await embedder.embed(chunk.map(\.text), purpose: .document)
                guard batch.vectors.count == chunk.count, space == nil || space == batch.space else {
                    throw LLMError.invalidResponse("embeddings changed size")
                }
                space = batch.space
                for (c, v) in zip(chunk, batch.vectors) {
                    if let (q, scale) = VectorIndex.quantize(v) {
                        items.append((c.start, c.end, q, scale, MeetingStore.textKey(c.text)))
                    } else if SemanticRanker.isSearchModelSpace(batch.space.model) {
                        // The search model could not embed this chunk: a marker records it, so the meeting still counts as
                        // embedded and the chunk is not tried again on every pass. Its text stays findable by keywords.
                        let (q, scale) = VectorIndex.unembeddableMarker(dims: batch.space.dimensions)
                        items.append((c.start, c.end, q, scale, MeetingStore.textKey(c.text)))
                    } else {
                        throw LLMError.invalidResponse("empty embedding")
                    }
                }
            }
            guard let space else { return }
            // The model was deleted while this pass ran: its vectors must not be stored after they were dropped.
            if searchModelRetiring { throw CancellationError() }
            try await store.replaceChunks(meetingID, items, space: space)
            await learn(space)
            await refreshSearchCoverage()
            current = (try? await store.chunksOutOfDate(meetingID, budget: budget)) != true
            if current || pass == 3 { break }
        }
        // A meeting whose chunks were still behind the transcript when the passes ran out stays unchecked, so the
        // next reconcile looks at it again.
        if current { textChecked.insert(meetingID) }
    }

    /// The chunk budget of the current embedding model, when it has one (the search model).
    func currentChunkBudget() async -> ChunkBudget? {
        guard case .available(let model, _) = providers.embeddings(), let embedder = model(Locale.Language(identifier: "en")) as? ChunkBudgeting else { return nil }
        return try? await embedder.chunkBudget()
    }

    /// The question's vector, with the model for its language, or nil when
    /// embeddings are off or fail: Ask then works with keywords and the graph.
    func queryVector(_ question: String, language: OutputLanguage) async throws -> (vector: [Float], space: EmbeddingSpace)? {
        guard queryEmbeddingAllowed else { return nil }
        guard case .available(let model, _) = providers.embeddings(),
              let embedder = model(Locale(identifier: language.identifier).language) else { return nil }
        do {
            let batch = try await embedder.embed([question], purpose: .query)
            // A question the model could not embed (an all-zero vector) ranks nothing: keywords answer it.
            guard let vector = batch.vectors.first, vector.contains(where: { $0 != 0 }), vector.allSatisfy(\.isFinite) else { return nil }
            await learn(batch.space)
            return (vector, batch.space)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            status.lastError = error.localizedDescription
            publish()
            return nil
        }
    }

    /// Remembers the vector size of a model; a new size means stored chunks
    /// of that model are in another space and are embedded again.
    func learn(_ space: EmbeddingSpace) async {
        guard knownDimensions[space.model] != space.dimensions else { return }
        let stored = (try? await store.chunkSpaces()) ?? [:]
        let changed = knownDimensions[space.model] != nil || stored.values.contains {
            $0.contains { $0.model == space.model && $0.dimensions != space.dimensions }
        }
        knownDimensions[space.model] = space.dimensions
        if changed { await reconcileEmbeddings() }
    }

    /// A meeting's speakers were named, renamed or changed: the marks on its tasks' owners are recomputed, and its
    /// chunks are embedded again when their text no longer matches the transcript (nothing happens without embeddings, without chunks or without a change).
    public func speakersChanged(meetingID: Int64) async {
        // Owners are marked "not confirmed" against the speakers as they were when the minutes were written.
        _ = try? await store.refreshOwnerMarks(meetingID)
        guard case .available = providers.embeddings(),
              (try? await store.chunksOutOfDate(meetingID, budget: await currentChunkBudget())) == true,
              let meeting = try? await store.meeting(meetingID), meeting.endedAt != nil else { return }
        try? await store.enqueueJob(.embed, meeting: meetingID)
        await queueChanged()
    }

    /// A person was renamed, merged or deleted: the names inside the chunks of the meetings where they speak may have
    /// changed, so those meetings are looked at again.
    public func peopleChanged() async {
        textChecked.removeAll()
        for id in (try? await store.meetingsWithSpeakers()) ?? [] { _ = try? await store.refreshOwnerMarks(id) }
        await reconcileEmbeddings()
        await queueChanged()
    }

    /// Queues embedding jobs for meetings whose chunks are missing, in
    /// another space than the current model's (the model, its size or the
    /// provider changed) or made from text that has changed (speaker names). Runs in the background like any other job.
    func reconcileEmbeddings() async {
        guard case .available(_, let expectedModel) = providers.embeddings(),
              let meetings = try? await store.embeddableMeetings(),
              let spaces = try? await store.chunkSpaces(),
              let withSpeakers = try? await store.meetingsWithSpeakers() else { return }
        var queued = false
        var budget: ChunkBudget??   // loaded on the first meeting that needs the text check
        for meeting in meetings {
            guard let model = expectedModel(meeting.transcriptionLocale.language) else { continue }
            let stored = spaces[meeting.id] ?? []
            let stale = stored.isEmpty || stored.contains { space in
                space.model != model || (knownDimensions[model].map { $0 != space.dimensions } ?? false)
            }
            // Same space, but the speakers' names changed what the chunks say.
            var outOfDate = stale
            // Only a meeting with speakers can change its text, and one already looked at this session is
            // rechecked by `speakersChanged` or `peopleChanged`, not on every settings change.
            if !outOfDate, withSpeakers.contains(meeting.id), !textChecked.contains(meeting.id) {
                if budget == nil { budget = .some(await currentChunkBudget()) }
                outOfDate = (try? await store.chunksOutOfDate(meeting.id, budget: budget ?? nil)) == true
                if !outOfDate { textChecked.insert(meeting.id) }
            }
            if outOfDate {
                try? await store.enqueueJob(.embed, meeting: meeting.id)
                queued = true
            }
        }
        if queued {
            status.queued = (try? await store.pendingJobCount()) ?? status.queued
            publish()
        }
        await refreshSearchCoverage()
    }
}
