// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Whether a text is embedded as a search query or as a stored document.
/// Many embedding models expect a different prefix for each.
public enum EmbeddingPurpose: Sendable {
    case query
    case document
}

/// Embedding model families with their query/document conventions.
public enum EmbeddingFamily: String, Codable, Sendable, CaseIterable {
    /// Qwen3-Embedding: `Instruct: <task>\nQuery: <q>`; documents as they are.
    case qwen3
    /// multilingual-e5 / e5: `query: ` and `passage: `.
    case e5
    /// e5 "-instruct" variants: instruction for queries only.
    case e5Instruct
    /// nomic-embed-text: `search_query: ` and `search_document: `.
    case nomic
    /// mxbai-embed-large and arctic-embed: retrieval instruction for queries only.
    case mxbai
    /// EmbeddingGemma: `task: search result | query: ` and `title: none | text: `.
    case embeddingGemma
    /// bge-m3 and other models without prefixes.
    case plain

    /// The retrieval task given to instruction-tuned models (English, as their authors recommend).
    static let retrievalTask = "Given a question about work meetings, retrieve transcript passages that answer it"

    /// Guesses the family from the model name as the server lists it.
    public static func detect(modelName: String) -> EmbeddingFamily {
        let n = modelName.lowercased()
        if n.contains("qwen3-embedding") || n.contains("qwen3_embedding") || n.contains("qwen3embedding") { return .qwen3 }
        if n.contains("e5") && n.contains("instruct") { return .e5Instruct }
        if n.contains("multilingual-e5") || n.contains("/e5-") || n.hasPrefix("e5-") || n.contains("-e5-") { return .e5 }
        if n.contains("nomic-embed") { return .nomic }
        if n.contains("mxbai-embed") || n.contains("arctic-embed") { return .mxbai }
        if n.contains("embeddinggemma") || n.contains("embedding-gemma") { return .embeddingGemma }
        return .plain
    }

    /// Whether the model is known to be trained with Matryoshka representation
    /// learning, so its vectors may be cut to a shorter prefix.
    public static func isKnownMatryoshka(modelName: String) -> Bool {
        let n = modelName.lowercased()
        return ["qwen3-embedding", "qwen3_embedding", "nomic-embed-text-v1.5", "nomic-embed-text:v1.5", "nomic-embed-text-v2",
                "embeddinggemma", "embedding-gemma", "mxbai-embed-large", "text-embedding-3", "arctic-embed-m-v1.5",
                "arctic-embed-l-v2", "jina-embeddings-v3"].contains { n.contains($0) }
            // Ollama's "nomic-embed-text" tag is v1.5.
            || n == "nomic-embed-text" || n.hasPrefix("nomic-embed-text:latest")
    }

    /// The text to send for `purpose`.
    public func prepare(_ text: String, as purpose: EmbeddingPurpose) -> String {
        switch (self, purpose) {
        case (.qwen3, .query), (.e5Instruct, .query): "Instruct: \(Self.retrievalTask)\nQuery: \(text)"
        case (.e5, .query): "query: \(text)"
        case (.e5, .document): "passage: \(text)"
        case (.nomic, .query): "search_query: \(text)"
        case (.nomic, .document): "search_document: \(text)"
        case (.mxbai, .query): "Represent this sentence for searching relevant passages: \(text)"
        case (.embeddingGemma, .query): "task: search result | query: \(text)"
        case (.embeddingGemma, .document): "title: none | text: \(text)"
        default: text
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EmbeddingFamily(rawValue: raw) ?? .plain
    }
}

/// Optional embedding settings stored in the server config. Every field may be
/// omitted; `nil` means "decide from the model name".
public struct EmbeddingSettings: Codable, Sendable, Equatable {
    /// Target length for Matryoshka truncation (default 1024).
    public var dimensions: Int?
    /// Overrides the Matryoshka heuristic.
    public var matryoshka: Bool?
    /// Overrides the query/document prefix family.
    public var family: EmbeddingFamily?

    public init(dimensions: Int? = nil, matryoshka: Bool? = nil, family: EmbeddingFamily? = nil) {
        self.dimensions = dimensions
        self.matryoshka = matryoshka
        self.family = family
    }

    public static let minimumDimensions = 256
    public static let defaultMatryoshkaDimensions = 1024
}

/// The vector space a set of embeddings lives in. Vectors from different
/// spaces must never be compared; the `chunks` table stores both fields, so
/// the service re-embeds a meeting when they differ from the current space.
public struct EmbeddingSpace: Codable, Sendable, Hashable {
    /// Model name as stored in `chunks.model`.
    public let model: String
    /// Vector length as stored in `chunks.dims`.
    public let dimensions: Int

    public init(model: String, dimensions: Int) {
        self.model = model
        self.dimensions = dimensions
    }

    /// Whether vectors stored with `model`/`dimensions` must be recomputed.
    public func requiresReembedding(storedModel: String, storedDimensions: Int) -> Bool {
        storedModel != model || storedDimensions != dimensions
    }
}

/// Vectors returned by an embedding provider, in input order.
public struct EmbeddingBatch: Sendable, Equatable {
    public let vectors: [[Float]]
    public let space: EmbeddingSpace

    public init(vectors: [[Float]], space: EmbeddingSpace) {
        self.vectors = vectors
        self.space = space
    }
}

/// The resolved embedding behaviour for one config.
struct EmbeddingPolicy: Equatable {
    let family: EmbeddingFamily
    /// Cut longer vectors to this length (Matryoshka models only).
    let truncateTo: Int?
    /// Shorter vectors are rejected.
    let minimum: Int

    /// A config without profile and without embedding settings keeps the
    /// 0.1.x behaviour: vectors longer than 1024 are cut to 1024 and shorter
    /// ones are rejected (the 0.1.x vector index only holds 1024 dimensions).
    init(model: String, settings: EmbeddingSettings?, legacy: Bool) {
        family = settings?.family ?? EmbeddingFamily.detect(modelName: model)
        let matryoshka = settings?.matryoshka ?? (legacy || EmbeddingFamily.isKnownMatryoshka(modelName: model))
        truncateTo = matryoshka ? max(EmbeddingSettings.minimumDimensions, settings?.dimensions ?? EmbeddingSettings.defaultMatryoshkaDimensions) : nil
        minimum = legacy && settings == nil ? EmbeddingSettings.defaultMatryoshkaDimensions : EmbeddingSettings.minimumDimensions
    }

    /// Validates and, for Matryoshka models, truncates a vector.
    func shape(_ v: [Float]) throws -> [Float] {
        guard v.count >= minimum else { throw LLMError.embeddingDimensions(v.count, minimum: minimum) }
        if let n = truncateTo, v.count > n { return Array(v.prefix(n)) }
        return v
    }
}
