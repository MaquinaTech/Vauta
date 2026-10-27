// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Search model: batching and the footprint governor")
struct SearchModelBatchingTests {
    @Test func rowsAreSortedByLengthAndBatchedByPaddedTokens() {
        let lengths = [10, 500, 12, 300, 11, 500, 10]
        let plan = SearchBatchPlanner.plan(lengths: lengths, tokenBudget: 1024, maxRows: 32)
        #expect(plan.flatMap { $0 }.sorted() == Array(lengths.indices), "every row exactly once")
        for batch in plan {
            let longest = batch.map { lengths[$0] }.max()!
            #expect(batch.count * longest <= 1024 || batch.count == 1, "padded tokens within the budget")
        }
        #expect(plan[0].map { lengths[$0] } == [10, 10, 11, 12], "the short rows travel together")
        #expect(plan.last!.allSatisfy { lengths[$0] == 500 } || plan.count > 1)
    }

    @Test func aBatchHasAtMost32Rows() {
        let plan = SearchBatchPlanner.plan(lengths: Array(repeating: 5, count: 100), tokenBudget: 1024, maxRows: 32)
        #expect(plan.map(\.count) == [32, 32, 32, 4])
    }

    @Test func aRowLongerThanTheBudgetStillGetsABatchOfItsOwn() {
        #expect(SearchBatchPlanner.plan(lengths: [512, 512], tokenBudget: 300, maxRows: 32).map(\.count) == [1, 1])
    }

    @Test func theGovernorHalvesAboveTheLimitAndRestoresAfterTwentyCalmBatches() {
        var g = SearchFootprintGovernor()
        #expect(g.budget == 1024)
        let shouldClear = g.observe(footprintMB: 1500)
        #expect(shouldClear, "free MLX's cache too")
        #expect(g.budget == 512)
        _ = g.observe(footprintMB: 1500)
        _ = g.observe(footprintMB: 1500)
        #expect(g.budget == 256, "never below the minimum")
        for _ in 0..<19 { _ = g.observe(footprintMB: 500) }
        #expect(g.budget == 256)
        _ = g.observe(footprintMB: 500)
        #expect(g.budget == 1024)
        // A reading in the middle band resets the calm count.
        _ = g.observe(footprintMB: 1500)
        for _ in 0..<19 { _ = g.observe(footprintMB: 500) }
        _ = g.observe(footprintMB: 1000)
        _ = g.observe(footprintMB: 500)
        #expect(g.budget == 512)
    }
}

@Suite("Search model: engine")
struct SearchModelEngineTests {
    @Test func embedsInInputOrderWithUnitVectorsInBatches() async throws {
        let f = try EngineFixture()
        defer { f.cleanup() }
        let texts = ["ab", "ab ab ab ab", "ab ab", "ab ab ab ab ab ab"]
        let vectors = try await f.engine.embed(texts, purpose: .document)
        #expect(vectors.count == 4 && vectors.allSatisfy { $0.count == 256 })
        for v in vectors { #expect(abs(v.reduce(0) { $0 + $1 * $1 }.squareRoot() - 1) < 1e-4) }
        // The order of the input is kept even though rows are sorted by length inside.
        let single = try await f.engine.embed([texts[2]], purpose: .document)
        #expect(single[0] == vectors[2])
        #expect(f.log.batches.first?.fp32 == false)
    }

    @Test func queriesAndDocumentsUseTheirOwnPrompts() async throws {
        let f = try EngineFixture()
        defer { f.cleanup() }
        let q = try await f.engine.embed(["ab"], purpose: .query)
        let d = try await f.engine.embed(["ab"], purpose: .document)
        #expect(q[0] != d[0])
        let t = try TinyTokenizer.tokenizer()
        #expect(q[0] == FakeEncoder.vector(t.encode("ab", prefix: SearchModelManifest.queryPrompt).ids))
        #expect(d[0] == FakeEncoder.vector(t.encode("ab", prefix: SearchModelManifest.documentPrompt).ids))
    }

    @Test func aNonFiniteRowIsRunAgainAloneInFP32AndTheWideEncoderIsReleased() async throws {
        let f = try EngineFixture(nonFiniteWhen: { $0.filter { $0 == 9 }.count >= 3 })   // a row with many "▁ab" tokens overflows in fp16
        defer { f.cleanup() }
        let t = try TinyTokenizer.tokenizer()
        let long = String(repeating: "ab ", count: 8)
        let ids = t.encode(long, prefix: SearchModelManifest.documentPrompt).ids
        let v = try await f.engine.embed([long, "ab"], purpose: .document)
        #expect(v[0] == FakeEncoder.vector(ids), "the fp32 vector of that row")
        let stats = await f.engine.currentStats
        #expect(stats.retriedInFP32 == 1 && stats.skipped == 0)
        #expect(f.log.batches.contains { $0.fp32 && $0.rows == 1 })
        #expect(f.log.built.filter { $0 }.count == 1 && f.log.released.contains(true), "built lazily, released right after")
    }

    @Test func aRowThatIsStillNotFiniteIsSkippedAndCounted() async throws {
        let f = try EngineFixture()
        defer { f.cleanup() }
        await f.engine.setForcedNonFinite(rows: [0], inFP32: true)
        let v = try await f.engine.embed(["ab"], purpose: .document)
        #expect(v == [[]])
        let stats = await f.engine.currentStats
        #expect(stats.retriedInFP32 == 1 && stats.skipped == 1)
    }

    @Test func theTestHookForcesTheRetryPath() async throws {
        let f = try EngineFixture()
        defer { f.cleanup() }
        let plain = try await f.engine.embed(["ab ab"], purpose: .document)
        await f.engine.setForcedNonFinite(rows: [0])
        let retried = try await f.engine.embed(["ab ab"], purpose: .document)
        #expect(retried == plain, "the fp32 retry gives the same vector (the fake is exact in both)")
        #expect(await f.engine.currentStats.retriedInFP32 == 1)
    }

    @Test func aHighFootprintShrinksTheBudgetAndFreesTheCache() async throws {
        let cleared = SharedBox(0)
        let f = try EngineFixture(footprint: { 1600 }, clearCache: { cleared.add(1) })
        defer { f.cleanup() }
        _ = try await f.engine.embed(Array(repeating: "ab ab ab", count: 100), purpose: .document)
        let stats = await f.engine.currentStats
        #expect(stats.currentBudget == 256 && cleared.value > 0)
        #expect(f.log.batches.allSatisfy { $0.rows * $0.longest <= 1024 || $0.rows == 1 })
        #expect(f.log.batches.last!.rows * f.log.batches.last!.longest <= 256 || f.log.batches.last!.rows == 1, "later batches are smaller")
    }

    @Test func theModelIsUnloadedAfterAQuietPeriodAndLoadedAgainWhenNeeded() async throws {
        let f = try EngineFixture(idle: .milliseconds(80))
        defer { f.cleanup() }
        _ = try await f.engine.embed(["ab"], purpose: .query)
        #expect(await f.engine.isLoaded)
        try await Task.sleep(for: .milliseconds(400))
        #expect(await !f.engine.isLoaded)
        #expect(f.log.released.contains(false))
        _ = try await f.engine.embed(["ab"], purpose: .query)
        #expect(await f.engine.isLoaded && f.log.built.filter { !$0 }.count == 2)
        await f.engine.unload()
        #expect(await !f.engine.isLoaded)
    }

    @Test func memoryPressureBetweenBatchesDoesNotFailARun() async throws {
        let f = try EngineFixture()
        defer { f.cleanup() }
        let texts = (0..<3_000).map { "ab ab \($0 % 7) ab" }
        let run = Task { try await f.engine.embed(texts, purpose: .document) }
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(2))
            await f.engine.unload()   // what a memory-pressure warning does
        }
        let vectors = try await run.value
        #expect(vectors.count == 3_000 && vectors.allSatisfy { $0.count == 256 }, "the model loaded again and the run finished")
    }

    @Test func afterMemoryPressureAQuestionLoadsAtOnceAndBulkEmbeddingCanBeCancelledWhileItWaits() async throws {
        let f = try EngineFixture(pressureCooldown: .seconds(60))   // far longer than any wait below: a wait would show
        defer { f.cleanup() }
        _ = try await f.engine.embed(["ab"], purpose: .query)
        #expect(f.log.built == [false])
        await f.engine.memoryPressure()
        #expect(await !f.engine.isLoaded)
        #expect(await f.engine.currentStats.currentBudget == 256, "restarts with the smallest batches")
        // A question loads at once, whatever the cooldown.
        _ = try await f.engine.embed(["ab"], purpose: .query)
        #expect(f.log.built == [false, false])
        // Bulk embedding does not reload into the pressure: it waits, and cancelling ends the wait.
        await f.engine.memoryPressure()
        let waiting = Task { try await f.engine.embed(["ab"], purpose: .document) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await !f.engine.isLoaded && f.log.built == [false, false], "still waiting: nothing was loaded")
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(f.log.built == [false, false])
    }

    @Test func bulkEmbeddingLoadsAgainOnlyAfterThePressureHasBeenQuietForTheCooldown() async throws {
        let f = try EngineFixture(pressureCooldown: .milliseconds(700))
        defer { f.cleanup() }
        let started = ContinuousClock.now
        await f.engine.memoryPressure()
        let vectors = try await f.engine.embed(["ab", "ab ab"], purpose: .document)
        #expect(ContinuousClock.now - started >= .milliseconds(650), "waited for the pressure to pass")
        #expect(vectors.count == 2 && f.log.built == [false])
    }

    @Test func cancellationStopsBetweenBatches() async throws {
        let f = try EngineFixture()
        defer { f.cleanup() }
        let task = Task { try await f.engine.embed(Array(repeating: "ab", count: 5_000), purpose: .document) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func aFileThatNoLongerMatchesMakesTheModelUnusable() async throws {
        let f = try EngineFixture()
        defer { f.cleanup() }
        let seen = SharedBox<[SearchModelError]>([])
        await f.engine.setUnusableHandler { error in seen.mutate { $0.append(error) } }
        var bytes = try Data(contentsOf: f.fixture.store.weightsURL)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: f.fixture.store.weightsURL)
        await #expect(throws: SearchModelError.mismatch) { try await f.engine.embed(["ab"], purpose: .query) }
        #expect(seen.value == [.mismatch])
    }

    @Test func planningChunksNeverBuildsTheEncoderOrRunsTheGPU() async throws {
        let f = try EngineFixture()
        defer { f.cleanup() }
        let model = GemmaEmbeddingModel(engine: f.engine)
        let budget = try await model.chunkBudget()
        #expect(budget.limit > 32 && budget.count("ab ab") > 0)
        _ = try await f.engine.tokenCounts(["ab"], purpose: .document)
        _ = try await f.engine.bodyBudget(purpose: .query)
        #expect(f.log.built.isEmpty && f.log.batches.isEmpty, "only the tokenizer was loaded")
        #expect(await !f.engine.isLoaded)
        _ = try await f.engine.embed(["ab"], purpose: .query)
        #expect(f.log.built == [false], "embedding builds it, once")
    }

    @Test func aTamperedTokenizerIsRefusedAtLoadEvenWhenTheWeightsAreFine() async throws {
        let f = try EngineFixture()
        defer { f.cleanup() }
        let seen = SharedBox<[SearchModelError]>([])
        await f.engine.setUnusableHandler { error in seen.mutate { $0.append(error) } }
        var bytes = try Data(contentsOf: f.fixture.store.tokenizerURL)
        bytes[bytes.count / 2] ^= 0x01   // same size, one bit different
        try bytes.write(to: f.fixture.store.tokenizerURL)
        await #expect(throws: SearchModelError.mismatch) { try await f.engine.tokenCounts(["ab"], purpose: .document) }
        await #expect(throws: SearchModelError.mismatch) { try await f.engine.embed(["ab"], purpose: .query) }
        #expect(seen.value.first == .mismatch && f.log.built.isEmpty)
        // Missing: unreadable, also unusable.
        try FileManager.default.removeItem(at: f.fixture.store.tokenizerURL)
        await #expect(throws: SearchModelError.self) { try await f.engine.planningTokenizer() }
    }

    @Test func severalNonFiniteRowsInOneBatchBuildTheWideEncoderOnce() async throws {
        let f = try EngineFixture(nonFiniteWhen: { $0.filter { $0 == 9 }.count >= 3 })
        defer { f.cleanup() }
        let long = String(repeating: "ab ", count: 8), longer = String(repeating: "ab ", count: 9)
        let v = try await f.engine.embed([long, longer, "ab", long + "ab"], purpose: .document)
        #expect(v.allSatisfy { $0.count == 256 })
        #expect(await f.engine.currentStats.retriedInFP32 == 3)
        #expect(f.log.built.filter { $0 }.count == 1, "one fp32 encoder for the whole batch")
    }

    @Test func bodyBudgetIsTheSequenceLimitMinusBosEosAndPrompt() async throws {
        let f = try EngineFixture()
        defer { f.cleanup() }
        let t = try TinyTokenizer.tokenizer()
        let doc = try await f.engine.bodyBudget(purpose: .document)
        #expect(doc == 512 - 2 - t.count("", prefix: SearchModelManifest.documentPrompt))
        let counts = try await f.engine.tokenCounts(["ab", ""], purpose: .document)
        #expect(counts == [t.count("ab", prefix: SearchModelManifest.documentPrompt), t.count("", prefix: SearchModelManifest.documentPrompt)])
    }

    // MARK: Gate

    @Test func theEncoderIsNeverBuiltOrRunOutsideTheGate() throws {
        let url = LanguageModelIntegrationTests.sources.appendingPathComponent("VautaCore/SearchModel/SearchModelEngine.swift")
        let whole = try String(contentsOf: url, encoding: .utf8)
        let text = String(whole[whole.range(of: "public actor SearchModelEngine")!.lowerBound...])
        var members: [[String]] = []
        for line in text.components(separatedBy: "\n") {
            let indent = line.prefix { $0 == " " }.count
            let body = line.trimmingCharacters(in: .whitespaces)
            if indent == 4, body.contains("func ") || body.contains("init(") { members.append([]) }
            if !members.isEmpty { members[members.count - 1].append(line) }
        }
        // Helpers that do GPU work and say so: they may only be called from inside `gate.run`.
        let helpers = ["func load()", "func buildEncoder()", "func run(tokens", "func retryInFP32("]
        let calls = ["try load()", "buildEncoder()", "try run(tokens", "retryInFP32("]
        var callers = 0
        for member in members {
            let head = member.first ?? ""
            let chunk = member.joined(separator: "\n")
            if helpers.contains(where: { head.contains($0) }) {
                // A helper reaches `factory.make` (and with it the kernel self-test) or the encoder itself.
                continue
            }
            guard let touch = calls.compactMap({ chunk.range(of: $0)?.lowerBound }).min() else {
                #expect(!chunk.contains("factory.make(") && !chunk.contains("EncoderSelfTest.passed") && !chunk.contains("encoder.embedBatch("), "\(head) reaches the GPU")
                continue
            }
            let gateAt = chunk.range(of: "gate.run(")?.lowerBound
            #expect(gateAt != nil && gateAt! < touch, "\(head) reaches the GPU before taking the gate")
            callers += 1
        }
        #expect(callers >= 2, "prepare and embed")
        // And the helpers themselves are the only members that name the factory.
        let factoryUsers = members.filter { $0.joined().contains("factory.make(") }.compactMap(\.first).map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(factoryUsers.allSatisfy { h in helpers.contains(where: { h.contains($0) }) }, "factory.make is used only by gate-only helpers: \(factoryUsers)")
    }

    @Test func aBulkEmbeddingWaitingBehindAnotherJobIsNotUnloadedForBeingIdle() async throws {
        let gate = MLXWorkGate()
        let f = try EngineFixture(idle: .milliseconds(60), gate: gate)
        defer { f.cleanup() }
        try await gate.acquire(.interactive)
        let run = Task { try await f.engine.embed(["ab ab"], purpose: .document) }
        try await Task.sleep(for: .milliseconds(300))   // five idle timeouts while it waits for the gate
        gate.release()
        let vectors = try await run.value
        #expect(vectors.count == 1 && vectors[0].count == 256)
        #expect(f.log.built == [false], "the encoder was built once, inside the gate, after the wait")
    }
}

@Suite("Search model: embedding model")
struct GemmaEmbeddingModelTests {
    @Test func theSpaceIsTheFrozenOne() {
        #expect(GemmaEmbeddingModel.space == EmbeddingSpace(model: "embeddinggemma-2@914f7f89/r1", dimensions: 256))
    }

    @Test func aShortTextIsOneWindowAndALongOneIsSplitAndCombined() async throws {
        let f = try EngineFixture()
        defer { f.cleanup() }
        let model = GemmaEmbeddingModel(engine: f.engine)
        let short = try await model.embed(["ab ab"], purpose: .document)
        #expect(short.space == GemmaEmbeddingModel.space && short.vectors[0].count == 256)
        // 700 one-token words do not fit one sequence: the windows are embedded and averaged.
        let sentence = String(repeating: "ab ", count: 49) + "ab. "
        let long = String(repeating: sentence, count: 14)
        let batch = try await model.embed([long], purpose: .document)
        let v = batch.vectors[0]
        #expect(abs(v.reduce(0) { $0 + $1 * $1 }.squareRoot() - 1) < 1e-4)
        let budget = try await f.engine.bodyBudget(purpose: .document)
        let tokens = try await f.engine.tokenCounts([long], purpose: .document)[0]
        #expect(tokens > budget, "the fixture really is longer than a window")
        let direct = try await f.engine.embed([long], purpose: .document)[0]
        #expect(v != direct, "not just the first window cut at the limit")
        #expect(f.log.batches.map(\.longest).max()! <= 512)
    }

    @Test func windowsFitTheBudgetAndCoverTheWholeText() async throws {
        let f = try EngineFixture()
        defer { f.cleanup() }
        let budget = try await f.engine.bodyBudget(purpose: .document)
        let text = (0..<30).map { _ in String(repeating: "ab ", count: 40) + "ab." }.joined(separator: " ")
        let windows = try await GemmaEmbeddingModel.split(text, budget: budget, engine: f.engine)
        #expect(windows.count > 1 && windows.joined().filter { !$0.isWhitespace } == text.filter { !$0.isWhitespace })
        let counts = try await f.engine.tokenCounts(windows, purpose: .document)
        let prompt = SearchModelManifest.maxSequence - 2 - budget
        #expect(counts.allSatisfy { $0 - prompt <= budget })
    }

    @Test func oneUnbrokenRunIsCutByCharacters() async throws {
        let f = try EngineFixture()
        defer { f.cleanup() }
        let budget = try await f.engine.bodyBudget(purpose: .document)
        let run = String(repeating: "ab", count: 1500)   // one word of 1,500 tokens
        let windows = try await GemmaEmbeddingModel.split(run, budget: budget, engine: f.engine)
        #expect(windows.count >= 3 && windows.joined() == run)
    }

    @Test func combiningWeighsByTokensAndNeedsEveryWindow() {
        let a: [Float] = [1] + [Float](repeating: 0, count: 255)
        let b: [Float] = [0, 1] + [Float](repeating: 0, count: 254)
        let mix = GemmaEmbeddingModel.combine([(a, 300), (b, 100)], dims: 256)
        #expect(abs(mix[0] - 0.9487) < 1e-3 && abs(mix[1] - 0.3162) < 1e-3)
        #expect(GemmaEmbeddingModel.combine([(a, 10), ([], 5)], dims: 256).allSatisfy { $0 == 0 }, "a window that failed makes the passage unembeddable")
        #expect(GemmaEmbeddingModel.combine([(a, 10)], dims: 256) == a)
    }

    @Test func aMeetingChunkBudgetIsBelowTheSequenceLimit() async throws {
        let f = try EngineFixture()
        defer { f.cleanup() }
        let budget = try await GemmaEmbeddingModel(engine: f.engine).chunkBudget()
        let body = try await f.engine.bodyBudget(purpose: .document)
        #expect(budget.limit == body - 8 && budget.count("ab ab") == 2)
    }
}

/// A value shared with a `@Sendable` closure.
final class SharedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { lock.withLock { _value } }
    func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&_value) } }
}

extension SharedBox where T == Int {
    func add(_ n: Int) { mutate { $0 += n } }
}
