// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import NaturalLanguage
import Testing
@testable import VautaCore

@Suite("Models: embeddings")
struct ModelsEmbeddingTests {
    @Test(arguments: [
        ("text-embedding-qwen3-embedding-4b", EmbeddingFamily.qwen3), ("Qwen/Qwen3-Embedding-8B", .qwen3),
        ("intfloat/multilingual-e5-large", .e5), ("multilingual-e5-large-instruct", .e5Instruct), ("e5-base-v2", .e5),
        ("nomic-embed-text", .nomic), ("text-embedding-nomic-embed-text-v1.5", .nomic),
        ("mxbai-embed-large", .mxbai), ("snowflake-arctic-embed2", .mxbai),
        ("embeddinggemma:300m", .embeddingGemma), ("google/embeddinggemma-300m", .embeddingGemma),
        ("bge-m3", .plain), ("text-embedding-3-large", .plain),
    ])
    func familyDetection(name: String, family: EmbeddingFamily) {
        #expect(EmbeddingFamily.detect(modelName: name) == family)
    }

    @Test func prefixes() {
        #expect(EmbeddingFamily.qwen3.prepare("q", as: .query).hasPrefix("Instruct: ") && EmbeddingFamily.qwen3.prepare("q", as: .query).hasSuffix("\nQuery: q"))
        #expect(EmbeddingFamily.qwen3.prepare("d", as: .document) == "d")
        #expect(EmbeddingFamily.e5.prepare("q", as: .query) == "query: q" && EmbeddingFamily.e5.prepare("d", as: .document) == "passage: d")
        #expect(EmbeddingFamily.nomic.prepare("q", as: .query) == "search_query: q")
        #expect(EmbeddingFamily.nomic.prepare("d", as: .document) == "search_document: d")
        #expect(EmbeddingFamily.mxbai.prepare("q", as: .query) == "Represent this sentence for searching relevant passages: q")
        #expect(EmbeddingFamily.mxbai.prepare("d", as: .document) == "d")
        #expect(EmbeddingFamily.embeddingGemma.prepare("q", as: .query) == "task: search result | query: q")
        #expect(EmbeddingFamily.embeddingGemma.prepare("d", as: .document) == "title: none | text: d")
        #expect(EmbeddingFamily.plain.prepare("q", as: .query) == "q")
    }

    @Test func matryoshkaHeuristics() {
        for name in ["Qwen3-Embedding-4B", "nomic-embed-text", "nomic-embed-text:latest", "embeddinggemma", "mxbai-embed-large", "text-embedding-3-small"] {
            #expect(EmbeddingFamily.isKnownMatryoshka(modelName: name), "\(name)")
        }
        for name in ["bge-m3", "multilingual-e5-large", "all-minilm", "nomic-embed-text-v1"] {
            #expect(!EmbeddingFamily.isKnownMatryoshka(modelName: name), "\(name)")
        }
    }

    @Test func policies() throws {
        let legacy = EmbeddingPolicy(model: "anything", settings: nil, legacy: true)
        #expect(legacy.truncateTo == 1024)
        #expect(try legacy.shape([Float](repeating: 1, count: 2048)).count == 1024)
        // 0.1.x rejected vectors shorter than 1024; legacy configs still do.
        #expect(throws: LLMError.embeddingDimensions(768, minimum: 1024)) { try legacy.shape([Float](repeating: 1, count: 768)) }
        let profiled = EmbeddingPolicy(model: "bge-m3", settings: nil, legacy: false)
        #expect(try profiled.shape([Float](repeating: 1, count: 768)).count == 768)
        #expect(throws: LLMError.embeddingDimensions(255, minimum: 256)) { try profiled.shape([Float](repeating: 1, count: 255)) }

        #expect(EmbeddingPolicy(model: "bge-m3", settings: nil, legacy: false).truncateTo == nil)
        #expect(EmbeddingPolicy(model: "Qwen3-Embedding-8B", settings: nil, legacy: false).truncateTo == 1024)
        #expect(EmbeddingPolicy(model: "bge-m3", settings: EmbeddingSettings(dimensions: 512, matryoshka: true), legacy: false).truncateTo == 512)
        #expect(EmbeddingPolicy(model: "Qwen3-Embedding-8B", settings: EmbeddingSettings(matryoshka: false), legacy: false).truncateTo == nil)
        #expect(EmbeddingPolicy(model: "bge-m3", settings: EmbeddingSettings(family: .e5), legacy: false).family == .e5)
    }
}
