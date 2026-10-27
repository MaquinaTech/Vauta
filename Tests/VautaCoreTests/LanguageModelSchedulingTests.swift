// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Synchronization
import Testing
@testable import VautaMLX
@testable import VautaCore

@Suite("Language model: gate leases, heat, recording pause, damaged files", .serialized, .gpuExclusive)
struct LanguageModelSchedulingTests {
    /// A value behind a lock that can be passed around (a `Mutex` itself cannot be copied).
    final class Locked<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ v: T) { value = v }
        func withLock<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
    }

    final class Box: @unchecked Sendable { let engine: Gemma4Engine; init(_ e: Gemma4Engine) { engine = e } }

    /// Writes a pseudo-random token sequence that never repeats (so the loop guard stays out of it): a long free-running generation
    /// that goes on until the token limit.
    final class Endless: LogitConstraint, @unchecked Sendable {
        private let rng = Mutex(SyntheticLanguageModel.SplitMix(99))
        func nextMask() -> LogitMask { .forced(Int32(10 + rng.withLock { $0.next() } % 400)) }
        func accept(_ token: Int32) {}
    }

    /// Polls `condition` until it holds (at most 120 s: the full suite runs on a Mac that may be busy).
    static func eventually(_ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    /// A fresh suite: the controller saves the chat choice when a download starts, and a test must never write the user's defaults.
    static func isolatedDefaults() -> UserDefaults {
        let name = "lm-test-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    static func nominal() -> ThermalSource { ThermalSource(state: { .nominal }, poll: .milliseconds(5), slowPause: .milliseconds(5)) }

    // MARK: Policy

    @Test func thermalPolicyByPriority() {
        typealias P = MLXWorkGate.Priority
        for p in [P.bulk, .warm, .minutes, .live, .interactive] {
            #expect(ThermalPolicy.action(for: p, .nominal) == .run && ThermalPolicy.action(for: p, .fair) == .run)
        }
        #expect(ThermalPolicy.action(for: .bulk, .serious) == .wait && ThermalPolicy.action(for: .minutes, .serious) == .wait && ThermalPolicy.action(for: .warm, .serious) == .wait)
        #expect(ThermalPolicy.action(for: .bulk, .critical) == .wait && ThermalPolicy.action(for: .minutes, .critical) == .wait)
        #expect(ThermalPolicy.action(for: .live, .serious) == .slow && ThermalPolicy.action(for: .live, .critical) == .wait)
        #expect(ThermalPolicy.action(for: .interactive, .serious) == .run && ThermalPolicy.action(for: .interactive, .critical) == .slow)
    }

    // MARK: Gate

    /// A checkpoint that, once `after` tokens have been written, waits until the more urgent job is queued (or has been served), so the
    /// test does not depend on how fast the Mac runs the tiny model.
    static func holdUntilUrgentJobIsQueued(after: Int, produced: Locked<Int>, served: Locked<Bool>, gate: MLXWorkGate) -> @Sendable () async throws -> Void {
        { while produced.withLock({ $0 }) >= after, !served.withLock({ $0 }), gate.waiting == 0 { try await Task.sleep(for: .milliseconds(2)) } }
    }

    @Test(.timeLimit(.minutes(2))) func anInteractiveJobRunsBetweenTwoBurstsOfALongGeneration() async throws {
        let box = Box(try LanguageModelEngineTests.engine())
        let gate = MLXWorkGate()
        let produced = Locked(0)
        let served = Locked(false)
        let embeddedAt = Mutex<Int?>(nil)
        let lease = GenerationLease(gate: gate, priority: .minutes, thermal: Self.nominal())
        let hold = Self.holdUntilUrgentJobIsQueued(after: 40, produced: produced, served: served, gate: gate)
        let generation = Task.detached { () -> Int in
            try await lease.begin()
            defer { lease.end() }
            let r = try await box.engine.generate(GenerationRequest(prompt: LanguageModelGenerationTests.prompt(20), maxTokens: 900, sampling: .card(seed: 5)),
                                                  constraint: Endless(), onToken: { _ in produced.withLock { $0 += 1 } },
                                                  checkpoint: { try await hold(); try await lease.checkpoint() })
            return r.tokens.count
        }
        while produced.withLock({ $0 }) < 40 { try await Task.sleep(for: .milliseconds(2)) }
        // A search query's embedding: it must not wait for the 900 tokens.
        try await gate.run(.interactive) { embeddedAt.withLock { $0 = produced.withLock { $0 } }; served.withLock { $0 = true } }
        let at = try #require(embeddedAt.withLock { $0 })
        let total = try await generation.value
        #expect(total == 900, "the generation went on to the end: \(total)")
        #expect(at >= 40 && at < 100, "the embedding ran after \(at) of \(total) tokens, not after all of them")
        #expect(lease.yielded.urgent >= 1)
    }

    @Test(.timeLimit(.minutes(2))) func aMoreUrgentGenerationGoesFirstAndBothFinish() async throws {
        let box = Box(try LanguageModelEngineTests.engine())
        let gate = MLXWorkGate()
        let order = Mutex<[String]>([])
        let minutes = GenerationLease(gate: gate, priority: .minutes, thermal: Self.nominal())
        let live = GenerationLease(gate: gate, priority: .live, thermal: Self.nominal())
        let produced = Locked(0)
        let served = Locked(false)
        let hold = Self.holdUntilUrgentJobIsQueued(after: 30, produced: produced, served: served, gate: gate)
        let slow = Task.detached { () -> Int in
            try await minutes.begin()
            defer { minutes.end() }
            let r = try await box.engine.generate(GenerationRequest(prompt: LanguageModelGenerationTests.prompt(20), maxTokens: 500, sampling: .card(seed: 2)),
                                                  constraint: Endless(), onToken: { _ in produced.withLock { $0 += 1 } },
                                                  checkpoint: { try await hold(); try await minutes.checkpoint() })
            order.withLock { $0.append("minutes") }
            return r.tokens.count
        }
        while produced.withLock({ $0 }) < 30 { try await Task.sleep(for: .milliseconds(2)) }
        let fast = Task.detached { () -> Int in
            try await live.begin()
            defer { live.end() }
            served.withLock { $0 = true }
            let r = try await box.engine.generate(GenerationRequest(prompt: LanguageModelGenerationTests.prompt(20, seed: 8), maxTokens: 40, sampling: .card(seed: 3)),
                                                  constraint: Endless(), checkpoint: { try await live.checkpoint() })
            order.withLock { $0.append("live") }
            return r.tokens.count
        }
        let (a, b) = try await (slow.value, fast.value)
        #expect(a == 500 && b == 40)
        #expect(order.withLock { $0 } == ["live", "minutes"], "the live job finished first, in the middle of the minutes job: \(order.withLock { $0 })")
    }

    // MARK: Heat

    @Test(.timeLimit(.minutes(1))) func aMinutesJobWaitsOutAHotMacWithoutHoldingTheGate() async throws {
        let state = Mutex(ProcessInfo.ThermalState.serious)
        let gate = MLXWorkGate()
        let lease = GenerationLease(gate: gate, priority: .minutes, thermal: ThermalSource(state: { state.withLock { $0 } }, poll: .milliseconds(5), slowPause: .milliseconds(5)))
        try await lease.begin()
        let done = Mutex(false)
        let step = Task { try await lease.checkpoint(); done.withLock { $0 = true } }
        try await Task.sleep(for: .milliseconds(60))
        #expect(!done.withLock { $0 }, "waiting while the Mac is hot")
        // The gate is free meanwhile: a search embedding goes through.
        try await gate.run(.bulk) {}
        state.withLock { $0 = .fair }
        try await step.value
        #expect(done.withLock { $0 } && lease.yielded.thermal == 1)
        lease.end()
        #expect(gate.waiting == 0)
        try await gate.run(.bulk) {}
    }

    @Test(.timeLimit(.minutes(1))) func anAutoAnswerGivesTheGateUpWhenTheHeatTurnsSeriousAndALiveNoteRuns() async throws {
        let state = Mutex(ProcessInfo.ThermalState.nominal)
        let gate = MLXWorkGate()
        let lease = GenerationLease(gate: gate, priority: .autoAnswer, thermal: ThermalSource(state: { state.withLock { $0 } }, poll: .seconds(60)))
        try await lease.begin()
        try await lease.checkpoint()
        state.withLock { $0 = .serious }
        await #expect(throws: GenerationTooWarm.self) { try await lease.checkpoint() }
        // It did not wait for the Mac to cool down: the gate is free and a live note goes through at once.
        let ran = Mutex(false)
        try await gate.run(.live) { ran.withLock { $0 = true } }
        #expect(ran.withLock { $0 } && lease.yielded.thermal == 1)
        lease.end()
    }

    @Test(.timeLimit(.minutes(1))) func aWaitingJobCanBeCancelled() async throws {
        let gate = MLXWorkGate()
        let lease = GenerationLease(gate: gate, priority: .bulk, thermal: ThermalSource(state: { .critical }, poll: .milliseconds(5)))
        try await lease.begin()
        let step = Task { try await lease.checkpoint() }
        try await Task.sleep(for: .milliseconds(30))
        step.cancel()
        await #expect(throws: CancellationError.self) { try await step.value }
        lease.end()
        try await gate.run(.interactive) {}
    }

    @Test(.timeLimit(.minutes(1))) func anAnswerIsSlowedAtCriticalAndNotAtSerious() async throws {
        let gate = MLXWorkGate()
        for (state, slowed) in [(ProcessInfo.ThermalState.serious, false), (.critical, true)] {
            let lease = GenerationLease(gate: gate, priority: .interactive, thermal: ThermalSource(state: { state }, poll: .milliseconds(5), slowPause: .milliseconds(80)))
            try await lease.begin()
            let t0 = Date()
            try await lease.checkpoint()
            let elapsed = Date().timeIntervalSince(t0)
            lease.end()
            // Counted, not timed, for "not slowed": a loaded Mac can take longer than the pause for nothing.
            #expect(lease.yielded.thermal == (slowed ? 1 : 0), "\(state.rawValue)")
            if slowed { #expect(elapsed >= 0.07, "the pause was \(elapsed) s") }
        }
    }

    @Test(.timeLimit(.minutes(2))) func aGenerationPausesWhileHotAndFinishesWhenItCoolsDown() async throws {
        let box = Box(try LanguageModelEngineTests.engine())
        let state = Mutex(ProcessInfo.ThermalState.serious)
        let gate = MLXWorkGate()
        let lease = GenerationLease(gate: gate, priority: .minutes, thermal: ThermalSource(state: { state.withLock { $0 } }, poll: .milliseconds(5)))
        let produced = Locked(0)
        let run = Task.detached { () -> Int in
            try await lease.begin()
            defer { lease.end() }
            return try await box.engine.generate(GenerationRequest(prompt: LanguageModelGenerationTests.prompt(80), maxTokens: 100, sampling: .card(seed: 1)),
                                                 constraint: Endless(), onToken: { _ in produced.withLock { $0 += 1 } }, checkpoint: { try await lease.checkpoint() }).tokens.count
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(produced.withLock { $0 } == 0, "nothing runs while the Mac is hot")
        state.withLock { $0 = .nominal }
        #expect(try await run.value == 100)
    }

    // MARK: Recording pause

    final class EnvironmentBox: Sendable {
        private let value: Mutex<IndexerEnvironment>
        init(_ v: IndexerEnvironment) { value = Mutex(v) }
        func set(_ v: IndexerEnvironment) { value.withLock { $0 = v } }
        var current: IndexerEnvironment { value.withLock { $0 } }
    }

    private static func environment(_ box: EnvironmentBox) -> @Sendable () -> IndexerEnvironment { { box.current } }

    @Test(.timeLimit(.minutes(2))) func theDownloadPausesWhileARecordingRunsAndGoesOnTwoMinutesAfter() async throws {
        let model = SyntheticLanguageModel()
        let behaviour = LanguageModelStub.Behaviour(model)
        LanguageModelStub.register(behaviour)
        let fixture = LanguageModelFixture(spec: model.spec)
        defer { LanguageModelStub.unregister(behaviour); fixture.cleanup() }
        let env = EnvironmentBox(IndexerEnvironment(isRecording: true))
        let access = LanguageModelAccess()
        let controller = LanguageModelController(store: fixture.store, access: access, engine: LanguageModelEngine(store: fixture.store, gate: MLXWorkGate()),
                                                 environment: Self.environment(env), log: NetworkActivityLog(), protocolClasses: [LanguageModelStub.self],
                                                 supported: { nil }, defaults: Self.isolatedDefaults(), appBuild: "test",
                                                 pollInterval: .milliseconds(10), prepare: { _ in })
        let states = Mutex<[LanguageModelStatus.State]>([])
        await controller.setStatusHandler { s in states.withLock { if $0.last != s.state { $0.append(s.state) } } }
        await controller.start()
        #expect(await controller.status.state == .notInstalled)
        await controller.download()
        // Recording: paused, and no block was requested.
        let paused = await Self.eventually { if case .pausedForRecording = await controller.status.state { true } else { false } }
        let nowState = await controller.status.state
        #expect(paused, "expected a pause, got \(nowState)")
        try await Task.sleep(for: .milliseconds(150))
        #expect(behaviour.rangeRequests.isEmpty && behaviour.hits.isEmpty, "nothing was requested during the recording")
        // The recording stops: still paused for two minutes.
        env.set(IndexerEnvironment(isRecording: false, recordingStoppedAt: Date()))
        try await Task.sleep(for: .milliseconds(200))
        if case .pausedForRecording = await controller.status.state {} else { Issue.record("expected the two-minute tail, got \(await controller.status.state)") }
        #expect(behaviour.hits.isEmpty)
        // Two minutes after: the download goes on by itself and finishes.
        env.set(IndexerEnvironment(isRecording: false, recordingStoppedAt: Date(timeIntervalSinceNow: -121)))
        _ = await Self.eventually { await controller.status.state == .ready }
        #expect(await controller.status.state == .ready)
        #expect(!behaviour.rangeRequests.isEmpty)
        #expect(access.availability == .installed)
        let seen = states.withLock { $0 }
        #expect(seen.contains { if case .pausedForRecording = $0 { true } else { false } } && seen.contains { if case .downloading = $0 { true } else { false } })
        // Delete: back to nothing, and the access offers nothing.
        await controller.delete()
        #expect(await controller.status.state == .notInstalled && access.availability == .notInstalled && access.chatModel == nil)
    }

    @Test func aStoppedDownloadKeepsItsBlocksAndASecondRunResumes() async throws {
        let model = SyntheticLanguageModel()
        let behaviour = LanguageModelStub.Behaviour(model)
        LanguageModelStub.register(behaviour)
        let fixture = LanguageModelFixture(spec: model.spec)
        defer { LanguageModelStub.unregister(behaviour); fixture.cleanup() }
        let env = EnvironmentBox(IndexerEnvironment(isRecording: true))
        let controller = LanguageModelController(store: fixture.store, access: LanguageModelAccess(), engine: LanguageModelEngine(store: fixture.store, gate: MLXWorkGate()),
                                                 environment: Self.environment(env), log: NetworkActivityLog(), protocolClasses: [LanguageModelStub.self],
                                                 supported: { nil }, defaults: Self.isolatedDefaults(), appBuild: "test", pollInterval: .milliseconds(10))
        await controller.download()
        _ = await Self.eventually { if case .pausedForRecording = await controller.status.state { true } else { false } }
        await controller.pause()
        _ = await Self.eventually { if case .partial = await controller.status.state { true } else { false } }
        if case .partial = await controller.status.state {} else { Issue.record("expected a partial download, got \(await controller.status.state)") }
    }

    // MARK: Damaged files

    @Test(.enabled(if: LanguageModelGate.refusal(gpuSupported: MLXRuntime.isSupported) == nil, "needs a Mac that meets the model's requirements"))
    func damagedFilesTurnTheModelOffSoChatFallsBackToApple() async throws {
        let access = LanguageModelAccess()
        let model = SyntheticLanguageModel()
        let fixture = LanguageModelFixture(spec: model.spec)
        defer { fixture.cleanup() }
        // An installed store whose weights are the right size and header but whose body differs: the quick check passes, the full one fails.
        try fixture.store.prepare()
        try FileManager.default.createDirectory(at: fixture.store.installDirectory, withIntermediateDirectories: true)
        var bad = model.assembled
        bad[bad.count - 1] ^= 0xFF
        try bad.write(to: fixture.store.weightsURL)
        try model.tokenizer.write(to: fixture.store.tokenizerURL)
        let record = LanguageModelInstallRecord(revision: model.spec.revision, assembledSHA256: model.spec.assembledSHA256, tokenizerSHA256: model.spec.tokenizerSHA256,
                                                source: "test", installedAt: Date(), appBuild: "test", verifiedByBuild: "test")
        try fixture.store.updateRecord(record)
        // Where the hardware qualifies the access offers the model; here we only need the engine's report to reach it.
        let engine = LanguageModelEngine(store: fixture.store, gate: MLXWorkGate(), onDamaged: { access.markDamaged() })
        await #expect(throws: (any Error).self) { try await engine.load() }
        #expect(await engine.isDamaged)
        #expect(access.availability == .unavailable(LanguageModelAccess.damagedReason) && access.chatModel == nil)
        // A second call does not hash the file again: it fails at once. With the file gone, hashing it again would fail differently.
        try FileManager.default.removeItem(at: fixture.store.weightsURL)
        await #expect(throws: IntegratedModelError.mismatch) { try await engine.load() }
    }

    // MARK: One engine, kept warm while recording

    @Test func chatAndTheControllerShareOneEngineSoDeleteUnloadsWhatChatUses() async throws {
        let model = SyntheticLanguageModel()
        let fixture = LanguageModelFixture(spec: model.spec)
        defer { fixture.cleanup() }
        let access = LanguageModelAccess()
        let first = access.engine(for: fixture.store)
        #expect(access.engine(for: fixture.store) === first, "asking again gives the same engine")
        let controller = LanguageModelController(store: fixture.store, access: access, environment: { IndexerEnvironment() }, log: NetworkActivityLog(),
                                                 supported: { nil }, defaults: Self.isolatedDefaults(), appBuild: "test")
        #expect(await controller.languageEngine === first, "the controller uses the engine chat uses")
        // An engine for another store is a different one.
        let other = LanguageModelFixture(spec: model.spec)
        defer { other.cleanup() }
        #expect(access.engine(for: other.store) !== first)
    }

    @Test func theRecordingKeepsTheModelWarmAndTheIdleTimerDoesNotUnloadIt() async throws {
        let model = SyntheticLanguageModel()
        let fixture = LanguageModelFixture(spec: model.spec)
        defer { fixture.cleanup() }
        let access = LanguageModelAccess()
        let engine = access.engine(for: fixture.store)
        access.setRecording(true)
        _ = await Self.eventually { await engine.isKeptWarm }
        #expect(await engine.isKeptWarm)
        let epoch = await engine.epoch
        await engine.unloadIfIdle()
        #expect(await engine.epoch == epoch, "no idle unload while recording")
        // An engine made while a recording is going on starts warm too.
        let lateAccess = LanguageModelAccess()
        lateAccess.setRecording(true)
        let later = lateAccess.engine(for: fixture.store)
        _ = await Self.eventually { await later.isKeptWarm }
        #expect(await later.isKeptWarm)
        access.setRecording(false)
        _ = await Self.eventually { await !engine.isKeptWarm }
        #expect(await !engine.isKeptWarm)
        await engine.unloadIfIdle()
        #expect(await engine.epoch == epoch + 1, "the recording ended: the idle timer may unload")
    }

    @Test func sourceTheRecorderTellsTheLanguageModelWhenARecordingStartsAndStops() throws {
        let url = LanguageModelIntegrationTests.sources.appendingPathComponent("Vauta/App/RecorderModel.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("LanguageModelAccess.shared.setRecording("))
    }

    // MARK: Entry points

    @Test func everyGpuEntryPointOfTheEngineIsUnderTheGate() throws {
        let url = LanguageModelIntegrationTests.sources.appendingPathComponent("VautaCore/LanguageModel/LanguageModelEngine.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        // Split into members (a line indented by exactly four spaces that starts a function starts a new one); any member that
        // touches the GPU must take the gate (`gate.run`) or a lease before it does.
        var members: [[String]] = []
        for line in text.components(separatedBy: "\n") {
            let indent = line.prefix { $0 == " " }.count
            let body = line.trimmingCharacters(in: .whitespaces)
            if indent == 4, body.contains("func ") || body.hasPrefix("init(") || body.hasPrefix("public init(") { members.append([]) }
            if !members.isEmpty { members[members.count - 1].append(line) }
        }
        var checked = 0
        for member in members {
            let chunk = member.joined(separator: "\n")
            let touch = ["Gemma4Engine(", "LanguageModelKernelCheck.passed", "engine.generate(", "engine.lastLogits(", "engine.prefillPrefix("].compactMap { chunk.range(of: $0)?.lowerBound }.min()
            guard let touch else { continue }
            let gateAt = ["gate.run(", "lease.begin()", "GenerationLease("].compactMap { chunk.range(of: $0)?.lowerBound }.min()
            #expect(gateAt != nil && gateAt! < touch, "\(member.first ?? "") reaches the GPU before taking the gate")
            checked += 1
        }
        #expect(checked >= 4, "load, the generation runner, the incremental reading and lastLogits")
    }
}
