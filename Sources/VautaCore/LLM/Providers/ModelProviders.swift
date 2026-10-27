// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// A chat model: streams text and reports usage and why it stopped.
/// Implemented by the OpenAI-compatible client (`LLMClient`) and by the Apple
/// on-device model (`AppleChatModel`).
public protocol ChatModel: Sendable {
    /// `onProgress` receives a growing count of generated chunks. Cancellable.
    func chat(_ messages: [ChatMessage], _ options: ChatOptions, onProgress: (@Sendable (Int) -> Void)?) async throws -> ChatResult
    /// Context window in tokens, when known.
    var contextTokens: Int? { get async }
}

/// An embedding model: vectors in a stable `EmbeddingSpace`.
/// Implemented by `LLMClient` (a model server) and by `GemmaEmbeddingModel` (the search model on this Mac).
public protocol EmbeddingModel: Sendable {
    func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> EmbeddingBatch
}

/// An embedding model that has a sequence limit shorter than a meeting chunk: it gives the budget chunks are planned with.
public protocol ChunkBudgeting: EmbeddingModel {
    func chunkBudget() async throws -> ChunkBudget
}

extension LLMClient: ChatModel, EmbeddingModel {}
