// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The tokenizer and its token index stay when the model is unloaded for being idle (the next question does not build them again), and
/// go with memory pressure or an unload asked for.
@Suite("Language model: the tokenizer across unloads")
struct LanguageModelTokenizerKeepTests {
    /// An engine whose store holds a real (tiny) tokenizer pinned by its spec; no weights are needed to read the tokenizer.
    static func engine() throws -> (LanguageModelEngine, LanguageModelFixture) {
        let json = Data(TinyTokenizer.json.utf8)
        var spec = SyntheticLanguageModel().spec
        spec.tokenizerSize = json.count
        spec.tokenizerSHA256 = SyntheticLanguageModel.sha(json)
        let fixture = LanguageModelFixture(spec: spec)
        try fixture.store.prepare()
        try FileManager.default.createDirectory(at: fixture.store.installDirectory, withIntermediateDirectories: true)
        try json.write(to: fixture.store.tokenizerURL)
        return (LanguageModelEngine(store: fixture.store, gate: MLXWorkGate()), fixture)
    }

    @Test func anIdleUnloadKeepsTheTokenizerAndItsIndex() async throws {
        let (engine, fixture) = try Self.engine()
        defer { fixture.cleanup() }
        // The token index is keyed by the tokenizer (other tests clear the shared cache as they unload, so it is not looked at here).
        let first = try await engine.loadedTokenizer()
        await engine.unloadIfIdle()
        let after = try await engine.loadedTokenizer()
        #expect(after === first, "the same tokenizer, not read and checked again, so its index is found again")

        await engine.memoryPressure()
        let fresh = try await engine.loadedTokenizer()
        #expect(fresh !== first, "memory pressure lets it go")
        await engine.unload()
        #expect(try await engine.loadedTokenizer() !== fresh, "an unload asked for (the model deleted or replaced) lets them go too")
    }

    @Test func theIndexOfAFreedTokenizerIsNeverAnothersByItsAddress() throws {
        let cache = TokenIndexCache()
        var a: GemmaTokenizer? = try TinyTokenizer.tokenizer()
        let index = cache.index(for: a!)
        #expect(cache.index(for: a!) === index && cache.hasIndex(for: a!), "built once")
        // The cache holds the tokenizer, so its address cannot be taken by another one while its index is kept.
        weak var held = a
        a = nil
        #expect(held != nil)
        cache.clear()
        #expect(held == nil, "cleared, the tokenizer is let go")
    }
}
