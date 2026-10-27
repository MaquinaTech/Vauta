// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// `llm-eval --search-model <dir>`: EVALUATION ONLY. The search model (EmbeddingGemma 2) from an install folder named on the
/// command line, as the evaluation's embeddings. The folder is the one that holds `model.safetensors` and `tokenizer.json`
/// (`<root>/embeddinggemma-2/<revision>`); both are checked against the pins of the app (`SearchModelSpec.pinned`: sizes, per tensor and
/// whole-file SHA-256) before the first use, so a run never measures a model that is not the shipped one.
///
/// Vectors are cached by purpose and text for the length of the run: the chunks of a meeting prefix are the chunks of the next prefix,
/// and the same text always gives the same vector, so an arm never differs from another by the GPU's batching. The cache holds
/// vectors only, in memory.
public final class EvaluationSearchModel: ChunkBudgeting, @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case notAnInstall(String)
        case mismatch(String)
        public var description: String {
            switch self {
            case .notAnInstall(let why): "search model folder: \(why)"
            case .mismatch(let what): "search model folder does not match the pinned model (\(what))"
            }
        }
    }

    private let base: GemmaEmbeddingModel
    private let engine: SearchModelEngine
    private let lock = NSLock()
    private var cache: [String: [Float]] = [:]
    private var budget: ChunkBudget?
    private var _hits = 0, _misses = 0
    private var cacheOn = true

    /// Off: every text goes to the model (a measurement of what embedding costs). The cache is emptied when it is turned off.
    public var cacheEnabled: Bool {
        get { lock.withLock { cacheOn } }
        set { lock.withLock { cacheOn = newValue; if !newValue { cache = [:] } } }
    }

    /// Cache hits and misses (texts), for the report.
    public var cacheStatistics: (hits: Int, misses: Int) { lock.withLock { (_hits, _misses) } }

    private init(engine: SearchModelEngine) {
        self.engine = engine
        base = GemmaEmbeddingModel(engine: engine)
    }

    /// Opens and verifies the install in `directory`, and loads the model (the GPU kernels are self-tested by the engine).
    public static func open(directory: URL, spec: SearchModelSpec = .pinned) async throws -> EvaluationSearchModel {
        let install = directory.standardizedFileURL
        let root = install.deletingLastPathComponent().deletingLastPathComponent()
        let store = SearchModelStore(root: root, spec: spec)
        guard install.path == store.installDirectory.standardizedFileURL.path else {
            throw Failure.notAnInstall("expected a folder named \(SearchModelStore.modelFolder)/\(spec.revisionFolder), got \(install.path)")
        }
        guard FileManager.default.fileExists(atPath: store.weightsURL.path), FileManager.default.fileExists(atPath: store.tokenizerURL.path) else {
            throw Failure.notAnInstall("model.safetensors or tokenizer.json is missing")
        }
        do {
            try SearchModelVerifier.fullVerify(file: store.weightsURL, spec: spec)
            try SearchModelVerifier.verifyTokenizer(file: store.tokenizerURL, spec: spec)
        } catch { throw Failure.mismatch("\(error)") }
        let engine = SearchModelEngine(store: store)
        try await engine.prepare()
        return EvaluationSearchModel(engine: engine)
    }

    public func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> EmbeddingBatch {
        let tag = purpose == .query ? "q\u{1F}" : "d\u{1F}"
        var out = [[Float]?](repeating: nil, count: texts.count)
        var missing: [Int] = []
        let caching = cacheEnabled
        lock.withLock {
            for (i, t) in texts.enumerated() {
                if caching, let v = cache[tag + t] { out[i] = v; _hits += 1 } else { missing.append(i); _misses += 1 }
            }
        }
        if !missing.isEmpty {
            let unique = Array(Set(missing.map { texts[$0] })).sorted()
            let batch = try await base.embed(unique, purpose: purpose)
            guard batch.vectors.count == unique.count else { throw LLMError.invalidResponse("embeddings changed size") }
            if caching { lock.withLock { for (t, v) in zip(unique, batch.vectors) { cache[tag + t] = v } } }
            let byText = Dictionary(uniqueKeysWithValues: zip(unique, batch.vectors))
            for i in missing { out[i] = byText[texts[i]] }
        }
        return EmbeddingBatch(vectors: out.map { $0 ?? [] }, space: GemmaEmbeddingModel.space)
    }

    public func chunkBudget() async throws -> ChunkBudget {
        if let budget = lock.withLock({ budget }) { return budget }
        let made = try await base.chunkBudget()
        lock.withLock { budget = made }
        return made
    }

    public func unload() async { await engine.unload() }
}
