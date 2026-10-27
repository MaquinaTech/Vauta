// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// E3, on demand: a question typed while a meeting is recorded, answered by a model whose context cannot hold the lines said so far
/// (Apple's, 4K), is searched by meaning in the meeting too. A meeting is embedded once it ends, so until then it ranks by keywords;
/// this embeds its closed chunks at the moment somebody asks, and only then.
///
/// - Nothing runs unless a question is typed, the search model is the embedding provider, the Mac allows it (not in Low Power Mode,
///   not on battery, not hot) and the answering model cannot read the visible lines whole (with a larger context the lines fit and the prefix changes
///   nothing, docs/SEARCH_MODEL.md).
/// - A chunk is closed when a later one has started: the last chunk is still growing and is found by keywords. Closed chunks are
///   stored in the meeting's own chunks (keyed by where they start and a fingerprint of their text), so the next question embeds only
///   the chunks that closed since, and a chunk whose text changed (a speaker was named) is embedded again.
/// - It runs at interactive priority, in the question's turn, and stops with the question (cancellation) and with the recording
///   (the chunks of a batch that was in flight are not stored). The chunks are removed when the recording ends (a meeting with only some of its lines embedded is not "covered"), and the embedding
///   job that follows the meeting writes them all.
extension LLMService {
    /// A hidden switch (`defaults write … searchModelEmbedLivePrefixOnDemand -bool YES`). The default is `embedLivePrefixDefault`.
    public static let embedLivePrefixKey = "searchModelEmbedLivePrefixOnDemand"
    /// Off until one real recording has been measured inside the app (memory footprint with a typed question, the app's own dropped-chunk
    /// counter, live notes on) and it has been approved (docs/SEARCH_MODEL.md, "E3 on demand"). The preference turns it on.
    public static let embedLivePrefixDefault = false
    /// Chunks per request to the search model; the engine batches again by tokens, and cancellation is checked between requests.
    static let livePrefixBatch = 8

    public struct LivePrefixReport: Sendable, Equatable {
        public enum Skip: String, Sendable, Equatable {
            /// The switch is off.
            case disabled
            /// The meeting is not being recorded (any more).
            case notRecording
            /// The embeddings are not the search model on this Mac (off, a server, or the model is absent or not ready).
            case notSearchModel
            /// Low Power Mode, the battery or a hot Mac.
            case guarded
            /// Everywhere: the library does not rank by meaning, so the meeting's vectors would not be used.
            case libraryNotRanking
            /// The answering model reads the visible lines whole.
            case fitsInContext
            /// The visible lines are still the first chunk.
            case nothingClosed
            /// The recording stopped while the chunks were being embedded.
            case stopped
            /// The model could not embed (the answer goes on with keywords).
            case failed
        }

        public var skipped: Skip?
        /// Closed chunks of the visible lines.
        public var closedChunks = 0
        /// Embedded by this call.
        public var embeddedChunks = 0
        /// Already stored from an earlier question.
        public var reusedChunks = 0
        /// Stored chunks removed because their text changed.
        public var droppedChunks = 0
        public var seconds = 0.0
        public init() {}
    }

    /// The skips after which chunks stored earlier by a typed question may be stale and could still be ranked (`disabled` stores nothing,
    /// `notRecording` and `stopped` are handled by the recording ending, `libraryNotRanking` means they would not be used).
    static let staleLivePrefixSkips: Set<LivePrefixReport.Skip> = [.guarded, .failed, .fitsInContext, .nothingClosed, .notSearchModel]

    var embedsLivePrefixOnDemand: Bool {
        embedLivePrefixOverride ?? (searchDefaults.object(forKey: Self.embedLivePrefixKey) as? Bool) ?? Self.embedLivePrefixDefault
    }

    /// `true` or `false` replace the stored switch (tests and the evaluation); nil goes back to it.
    public func setEmbedLivePrefixOnDemand(_ on: Bool?) { embedLivePrefixOverride = on }

    /// Embeds the closed chunks of the meeting being recorded, as it stood at `upToSegment`. `budget`: the answering model's budget when
    /// the caller has not already established that the lines do not fit (a question over the whole library); nil = they do not fit.
    /// Throws only `CancellationError`: any other trouble (the store included) is a skip and the answer goes on with keywords.
    @discardableResult
    public func embedLivePrefix(meetingID live: Int64, upToSegment: Int64, budget: ContextBudget? = nil, question: String = "") async throws -> LivePrefixReport {
        let started = ContinuousClock.now
        do {
            return try await embedLivePrefixUnguarded(meetingID: live, upToSegment: upToSegment, budget: budget, question: question, started: started)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            var failed = LivePrefixReport()
            failed.skipped = .failed
            failed.seconds = Double((ContinuousClock.now - started) / .seconds(1))
            return failed
        }
    }

    private func embedLivePrefixUnguarded(meetingID live: Int64, upToSegment: Int64, budget: ContextBudget?, question: String,
                                          started: ContinuousClock.Instant) async throws -> LivePrefixReport {
        var report = LivePrefixReport()
        func finish(_ why: LivePrefixReport.Skip? = nil) -> LivePrefixReport {
            report.skipped = why
            report.seconds = Double((ContinuousClock.now - started) / .seconds(1))
            return report
        }
        guard embedsLivePrefixOnDemand else { return finish(.disabled) }
        guard recording, liveSessionMeeting == live else { return finish(.notRecording) }
        guard providers.settings.embeddings == .onDeviceModel, case .available(let model, let expected) = providers.embeddings(),
              let meeting = try await store.meeting(live), let embedder = model(meeting.transcriptionLocale.language) as? any ChunkBudgeting,
              let name = expected(meeting.transcriptionLocale.language), SemanticRanker.isSearchModelSpace(name) else { return finish(.notSearchModel) }
        guard IndexerPolicy.allowsOnDemandEmbedding(environmentProvider()), !searchModelRetiring else { return finish(.guarded) }
        let space = EmbeddingSpace(model: name, dimensions: GemmaEmbeddingModel.space.dimensions)
        if let budget {
            // Over the whole library the meeting is one source among many: with a model that reads it whole, nothing is needed, and a
            // library that ranks by keywords would not use the meeting's vectors.
            let visible = try await store.citableSegments(live).filter { $0.id <= upToSegment }
            if !visible.isEmpty, PromptText.tokens([.system(VautaPrompts.system), VautaPrompts.transcriptMessage(visible), .user(question)]) <= budget.askInput {
                return finish(.fitsInContext)
            }
            guard await meetingRankingMode(space: space, within: nil) == .semantic else { return finish(.libraryNotRanking) }
        }
        try Task.checkCancellation()
        let chunkBudget = try? await embedder.chunkBudget()
        let plan = try await store.chunkPlan(live, budget: chunkBudget, upToSegment: upToSegment)
        // The last chunk is still growing: it is found by keywords until a later one starts.
        let closed = Array(plan.dropLast())
        report.closedChunks = closed.count
        guard !closed.isEmpty else { return finish(.nothingClosed) }
        let wanted = Set(closed.map { MeetingStore.ChunkKey(start: $0.start, key: MeetingStore.textKey($0.text)) })
        report.droppedChunks = try await store.dropChunks(live, keeping: wanted, space: space)
        let have = try await store.storedChunkKeys(live, space: space)
        let missing = closed.filter { !have.contains(MeetingStore.ChunkKey(start: $0.start, key: MeetingStore.textKey($0.text))) }
        report.reusedChunks = closed.count - missing.count
        for first in stride(from: 0, to: missing.count, by: Self.livePrefixBatch) {
            try Task.checkCancellation()
            guard recording, liveSessionMeeting == live, !searchModelRetiring else { return finish(.stopped) }
            // Like bulk embedding, which asks again before every batch: a Mac that unplugged, entered Low Power Mode or got hot while a
            // long prefix was embedding stops here (the batches already stored stay).
            guard IndexerPolicy.allowsOnDemandEmbedding(environmentProvider()) else { return finish(.guarded) }
            let part = Array(missing[first..<min(missing.count, first + Self.livePrefixBatch)])
            let batch: EmbeddingBatch
            do {
                batch = try await SearchModelEngine.$interactiveDocuments.withValue(true) { try await embedder.embed(part.map(\.text), purpose: .document) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return finish(.failed)
            }
            // A question that was cancelled while the batch ran stores nothing of it.
            try Task.checkCancellation()
            guard batch.vectors.count == part.count, batch.space == space else { return finish(.failed) }
            // The recording may have stopped, or the model been deleted, while the batch ran: nothing of it is stored.
            guard recording, liveSessionMeeting == live, !searchModelRetiring else { return finish(.stopped) }
            var items: [(start: Double, end: Double, q: Data, scale: Float, key: String)] = []
            for (chunk, vector) in zip(part, batch.vectors) {
                // A chunk the model cannot embed is stored as a marker, like the embedding job does, so it is not tried again.
                let (q, scale) = VectorIndex.quantize(vector) ?? VectorIndex.unembeddableMarker(dims: space.dimensions)
                items.append((chunk.start, chunk.end, q, scale, MeetingStore.textKey(chunk.text)))
            }
            // Recorded before the store is asked: the store waits, and the recording may end meanwhile.
            onDemandMeetings.insert(live)
            await beforeOnDemandChunksStored?()
            try await store.addChunks(live, items, space: space)
            // The recording ended while the chunks were being stored: the embedding job writes the whole meeting, a part must not stay.
            guard recording, liveSessionMeeting == live else {
                onDemandMeetings.remove(live)
                _ = try? await store.dropChunks(live, keeping: [], space: space)
                return finish(.stopped)
            }
            report.embeddedChunks += part.count
        }
        return finish()
    }
}

extension LLMService {
    /// Removes the chunks that typed questions stored for a meeting that is being recorded (or was, when the app died): they stop at the
    /// last of those questions and may hold text a rename has changed, so a search must not rank by them. The meeting then ranks by
    /// keywords until the embedding job writes its whole set (a meeting without chunks is not covered and is queued by `reconcileEmbeddings`).
    public func discardLivePrefixChunks(_ meetingID: Int64) async {
        onDemandMeetings.remove(meetingID)
        _ = try? await store.dropChunks(meetingID, keeping: [], space: GemmaEmbeddingModel.space)
    }
}

extension IndexerPolicy {
    /// May a question typed during a recording embed the meeting being recorded? The recording pause does not apply (the person asked
    /// and the work is bounded and cached); the rest of bulk embedding's rules do: not on battery, not in Low Power Mode, not on a hot Mac.
    public static func allowsOnDemandEmbedding(_ env: IndexerEnvironment) -> Bool {
        !env.onBattery && !env.lowPowerMode && env.thermalState != .serious && env.thermalState != .critical
    }
}
