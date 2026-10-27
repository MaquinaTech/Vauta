// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Vectors for the passages of the person's documents, so a question finds meaning and not only words. Keywords always work
/// without them.
extension LLMService {
    /// Where the embeddings of passages would be computed, which decides whether the person's choice is needed first.
    public enum DocumentEmbeddingRoute: Sendable, Equatable {
        /// Not at all (search by meaning is off, or nothing is set up).
        case off
        /// On this Mac: Apple's on-device model, or a model server on this Mac (no traffic leaves it).
        case local
        /// A model server on the network: sends every indexed passage once. Only if the person turned it on.
        case network
    }

    public func documentEmbeddingRoute() -> DocumentEmbeddingRoute {
        switch providers.settings.embeddings {
        case .none: return .off
        case .onDeviceModel: return .local
        case .server:
            guard case .available = providers.embeddings() else { return .off }
            return providers.embeddingsLeaveThisMac ? .network : .local
        }
    }

    /// Embeds up to `limit` passages that have no vector in the current space and stores them. Returns how many were done (0
    /// when search by meaning is off, the route needs the person's choice and it was not given, or there is nothing left).
    /// Nothing leaves the Mac unless the route is `.network` and `allowNetwork` is true; that traffic is logged as
    /// "Indexing your documents".
    /// `shouldContinue` is asked before every batch (a recording that starts mid-way stops the work).
    @discardableResult
    public func embedDocumentPassages(limit: Int = 64, allowNetwork: Bool, shouldContinue: @Sendable () async -> Bool = { true }) async -> Int {
        guard let documents else { return 0 }
        let route = documentEmbeddingRoute()
        guard route == .local || (route == .network && allowNetwork),
              case .available(let model, let expectedModel) = providers.embeddings(),
              let embedder = model(Locale.Language(identifier: "en")), let expected = expectedModel(Locale.Language(identifier: "en")) else { return 0 }
        // One model for every language: vectors of any other model are dropped, and a passage without one of this model is embedded.
        try? await documents.dropVectors(otherThanModel: expected)
        var done = 0
        var cursor: Int64 = 0
        var failures = 0
        // Walks the passages that have no vector by id: one that cannot be embedded (a failed batch) is passed over, so it never
        // blocks the ones after it. Each round reads 256, orders them by length and embeds them in requests of 32 (the search model
        // groups them by its token budget).
        while done < limit {
            guard let round = try? await documents.passagesNeedingVectors(model: expected, after: cursor, limit: 256), let last = round.last else { break }
            cursor = last.id
            let todo = round.sorted { $0.text.count < $1.text.count }
            for start in stride(from: 0, to: todo.count, by: 32) {
                guard !Task.isCancelled, !searchModelRetiring, await shouldContinue() else { return done }
                let batch = Array(todo[start..<min(todo.count, start + 32)])
                do {
                    let result = try await LLMClient.$embeddingPurpose.withValue(.documents) { try await embedder.embed(batch.map(\.text), purpose: .document) }
                    guard result.vectors.count == batch.count else { continue }
                    guard !searchModelRetiring else { return done }   // deleted while the batch was computed: store nothing
                    var stored: [(id: Int64, q: Data, scale: Float)] = []
                    for (item, vector) in zip(batch, result.vectors) {
                        if let (q, scale) = VectorIndex.quantize(vector) {
                            stored.append((item.id, q, scale))
                        } else if SemanticRanker.isSearchModelSpace(result.space.model) {
                            // The search model could not embed this passage: a marker records it, so it is not tried again on
                            // every pass and coverage can be complete (keywords still find it).
                            let (q, scale) = VectorIndex.unembeddableMarker(dims: result.space.dimensions)
                            stored.append((item.id, q, scale))
                        }
                    }
                    // The same model at another size (a setting changed) is another space: its old vectors go.
                    try await documents.dropVectors(ofModel: result.space)
                    try await documents.storeVectors(stored, space: result.space)
                    done += stored.count
                    failures = 0
                } catch {
                    // A batch that fails is passed over; three in a row (a server that is down) end the pass.
                    failures += 1
                    if failures >= 3 { return done }
                }
            }
            await refreshSearchCoverage()
        }
        return done
    }
}
