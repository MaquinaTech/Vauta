// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
import VautaMLX
@testable import VautaCore

/// Tests that need the GPU (skipped on a Mac without one) and, further down, the installed model (skipped unless
/// `VAUTA_SEARCH_MODEL_DIR` names an install folder). Tests never download the model.
@Suite("Search model: MLX on the GPU", .serialized)
struct SearchModelMLXTests {
    static let gpu = MLXRuntime.isSupported
    /// Needs the GPU and `VAUTA_SEARCH_MODEL_DIR` naming an install: otherwise the test shows as skipped, with this reason.
    static let hasModel = installedStore() != nil

    @Test(.enabled(if: SearchModelMLXTests.gpu, "needs an Apple silicon GPU"))
    func theKernelSelfTestPasses() {
        let report = KernelSelfTest.run(.full)
        #expect(report.failed.isEmpty, "\(report.failed)")
        #expect(report.total == 59 && report.passed == 59)
        let encoder = KernelSelfTest.run(.encoder)
        #expect(encoder.ok && encoder.total == 17)
    }

    @Test(.enabled(if: SearchModelMLXTests.gpu, "needs an Apple silicon GPU"))
    func theCacheStaysWithinItsLimitAndClearingFreesIt() {
        MLXRuntime.configure()
        KernelSelfTest.exerciseRandomShapes(count: 200)
        #expect(MLXRuntime.cacheBytes <= MLXRuntime.cacheLimitBytes + (16 << 20), "cache \(MLXRuntime.cacheBytes >> 20) MB")
        MLXRuntime.clearCache()
        #expect(MLXRuntime.cacheBytes < (4 << 20))
    }

    @Test func theFootprintReaderWorks() {
        #expect(MLXRuntime.physFootprintMB() > 0)
    }

    // MARK: Needs the installed model

    static func installedStore() -> SearchModelStore? {
        guard MLXRuntime.isSupported, ProcessInfo.processInfo.environment["VAUTA_SEARCH_MODEL_DIR"] != nil else { return nil }
        let store = SearchModelSelfTest.store()
        guard case .installed = store.disk() else { return nil }
        return store
    }

    @Test(.enabled(if: SearchModelMLXTests.hasModel, "needs the installed model: set VAUTA_SEARCH_MODEL_DIR"))
    func theInstalledFilesVerify() throws {
        guard let store = Self.installedStore() else { return }  // enabled(if:) already skipped the test without a model
        try SearchModelVerifier.fullVerify(file: store.weightsURL, spec: store.spec)
        try SearchModelVerifier.verifyTokenizer(file: store.tokenizerURL, spec: store.spec)
    }

    @Test(.enabled(if: SearchModelMLXTests.hasModel, "needs the installed model: set VAUTA_SEARCH_MODEL_DIR"))
    func theFP16EncoderMatchesTheStoredFP32Goldens() async throws {
        guard let store = Self.installedStore(), let goldens = SearchModelGoldens.vectors else { return }
        let engine = SearchModelEngine(store: store)
        let vectors = try await engine.embed(SearchModelGoldens.strings, purpose: .document)
        for (v, g) in zip(vectors, goldens) { #expect(SearchModelGoldens.cosine(v, g) >= 0.999) }
        // Queries use their own prompt: a question and its answer are close, an unrelated sentence is not.
        let q = try await engine.embed(["When is the budget review?"], purpose: .query)[0]
        let related = SearchModelGoldens.cosine(q, goldens[0]), unrelated = SearchModelGoldens.cosine(q, goldens[6])
        #expect(related > unrelated + 0.05)
        await engine.unload()
    }

    @Test(.enabled(if: SearchModelMLXTests.hasModel, "needs the installed model: set VAUTA_SEARCH_MODEL_DIR"))
    func aRowForcedThroughTheFP32RetryGivesTheSameVector() async throws {
        guard let store = Self.installedStore() else { return }  // enabled(if:) already skipped the test without a model
        let engine = SearchModelEngine(store: store)
        let text = SearchModelGoldens.strings[1]
        let plain = try await engine.embed([text], purpose: .document)[0]
        await engine.setForcedNonFinite(rows: [0])
        let retried = try await engine.embed([text], purpose: .document)[0]
        #expect(SearchModelGoldens.cosine(plain, retried) >= 0.999)
        let stats = await engine.currentStats
        #expect(stats.retriedInFP32 == 1 && stats.skipped == 0)
        await engine.unload()
    }

    @Test(.enabled(if: SearchModelMLXTests.hasModel, "needs the installed model: set VAUTA_SEARCH_MODEL_DIR"))
    func languagesLineUp() async throws {
        guard let store = Self.installedStore(), let goldens = SearchModelGoldens.vectors else { return }
        let engine = SearchModelEngine(store: store)
        // The same sentence in another language is closer than an unrelated one.
        let es = try await engine.embed(["Aplazamos el lanzamiento hasta mediados de noviembre."], purpose: .query)[0]
        #expect(SearchModelGoldens.cosine(es, goldens[1]) > SearchModelGoldens.cosine(es, goldens[7]))
        await engine.unload()
    }

    @Test(.enabled(if: SearchModelMLXTests.hasModel, "needs the installed model: set VAUTA_SEARCH_MODEL_DIR"))
    func badTokenIdsAreRejectedNotRead() throws {
        guard let store = Self.installedStore() else { return }  // enabled(if:) already skipped the test without a model
        let encoder = try GemmaTextEncoder(url: store.weightsURL, compute: .fp16)
        #expect(throws: SafetensorsError.tokenOutOfRange(262_144)) { try encoder.embedBatch(tokens: [[2, 262_144, 1]], matryoshka: 256) }
        #expect(throws: SafetensorsError.tokenOutOfRange(-5)) { try encoder.embedBatch(tokens: [[2, -5, 1]], matryoshka: 256) }
        #expect(throws: SafetensorsError.emptySequence) { try encoder.embedBatch(tokens: [[]], matryoshka: 256) }
        #expect(throws: SafetensorsError.emptySequence) { try encoder.embedBatch(tokens: [Array(repeating: 5, count: 513)], matryoshka: 256) }
        let ok = try encoder.embedBatch(tokens: [[2, 1000, 1]], matryoshka: 256)
        #expect(ok.vectors.count == 256 && ok.nonFinite == [false])
    }

    @Test(.enabled(if: SearchModelMLXTests.hasModel, "needs the installed model: set VAUTA_SEARCH_MODEL_DIR"))
    func aLargeRunStaysUnderTheFootprintCapAndTheMemoryComesBack() async throws {
        guard let store = Self.installedStore() else { return }  // enabled(if:) already skipped the test without a model
        let engine = SearchModelEngine(store: store)
        try await engine.prepare()
        let words = ["budget", "launch", "invoice", "hiring", "contract", "migration", "review", "supplier", "roadmap", "forecast"]
        var rng = SystemRandomNumberGenerator()
        let texts = (0..<2_000).map { _ in (0..<Int.random(in: 30...160, using: &rng)).map { _ in words.randomElement(using: &rng)! }.joined(separator: " ") }
        var peak = 0
        for start in stride(from: 0, to: texts.count, by: 200) {
            _ = try await engine.embed(Array(texts[start..<(start + 200)]), purpose: .document)
            peak = max(peak, MLXRuntime.physFootprintMB())
        }
        #expect(peak < 1_400, "peak footprint \(peak) MB")
        let loaded = MLXRuntime.physFootprintMB()
        await engine.unload()
        let after = MLXRuntime.physFootprintMB()
        // Recorded for docs/SEARCH_MODEL.md (the spike did not measure it).
        print("search model footprint: peak \(peak) MB, loaded \(loaded) MB, after unload \(after) MB")
        #expect(after < loaded)
    }
}
