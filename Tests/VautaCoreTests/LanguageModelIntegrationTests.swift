// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Synchronization
import Testing
@testable import VautaCore

@Suite("Language model: integration", .serialized, .gpuExclusive)
struct LanguageModelIntegrationTests {
    // MARK: Work gate

    final class Order: Sendable {
        private let list = Mutex<[String]>([])
        func add(_ s: String) { list.withLock { $0.append(s) } }
        var value: [String] { list.withLock { $0 } }
    }

    @Test func theGateRunsOneJobAtATimeHighestPriorityFirst() async throws {
        let gate = MLXWorkGate()
        let order = Order()
        let release = Mutex(false)
        let holder = Task { try await gate.run(.minutes) { order.add("holder"); while !release.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) } } }
        while order.value.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let waiters = [("bulk", MLXWorkGate.Priority.bulk), ("minutes", .minutes), ("live", .live), ("interactive", .interactive), ("bulk2", .bulk)]
        var tasks: [Task<Void, Error>] = []
        for (name, p) in waiters {
            tasks.append(Task { try await gate.run(p) { order.add(name) } })
            while gate.waiting < tasks.count { try await Task.sleep(for: .milliseconds(5)) }
        }
        release.withLock { $0 = true }
        try await holder.value
        for t in tasks { try await t.value }
        #expect(order.value == ["holder", "interactive", "live", "minutes", "bulk", "bulk2"], "\(order.value)")
    }

    @Test func aWaitingJobCanBeCancelledAndNeverRuns() async throws {
        let gate = MLXWorkGate()
        let ran = Mutex(false)
        let release = Mutex(false)
        let holder = Task { try await gate.run(.live) { while !release.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) } } }
        try await Task.sleep(for: .milliseconds(30))
        let waiter = Task { try await gate.run(.bulk) { ran.withLock { $0 = true } } }
        while gate.waiting < 1 { try await Task.sleep(for: .milliseconds(5)) }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        release.withLock { $0 = true }
        try await holder.value
        #expect(!ran.withLock { $0 } && gate.waiting == 0)
        // The gate is free again.
        try await gate.run(.bulk) { ran.withLock { $0 = true } }
        #expect(ran.withLock { $0 })
    }

    // MARK: Hidden flag

    @Test func withTheFlagOffTheOnDeviceProviderIsApplesAsBefore() throws {
        let defaults = UserDefaults(suiteName: "lm-flag-\(UUID().uuidString)")!
        #expect(!LanguageModelAccess.flagEnabled(defaults: defaults, environment: [:]))
        defaults.set(true, forKey: "integratedLanguageModel")
        #expect(LanguageModelAccess.flagEnabled(defaults: defaults, environment: [:]))
        let other = UserDefaults(suiteName: "lm-flag-\(UUID().uuidString)")!
        #expect(LanguageModelAccess.flagEnabled(defaults: other, environment: ["VAUTA_INTEGRATED_LLM": "1"]))
        #expect(!LanguageModelAccess.flagEnabled(defaults: other, environment: ["VAUTA_INTEGRATED_LLM": "0"]))
        // Flag off: the provider is Apple's whatever the access holds (here nothing is installed).
        let providers = SystemModelProviders(client: LLMClient(), defaults: other, searchModel: SearchModelAccess(), loadConfig: { nil })
        switch providers.chat() {
        case .success(let p): #expect(p.model is AppleChatModel && p.onDevice)
        case .failure(let e): if case .onDeviceModel = e.issue {} else { Issue.record("unexpected issue \(e.issue)") }
        }
        #expect(LanguageModelAccess().availability == .notInstalled && LanguageModelAccess().chatModel == nil)
    }

    // MARK: Due-date rule

    static let meetingDay = ISO8601DateFormatter().date(from: "2026-10-12T09:00:00Z")!

    func tasks(due: String, segment: String) throws -> ValidatedMinutes {
        let segments: [Int64: CitableSegment] = [10: CitableSegment(id: 10, channel: .others, start: 60, text: segment)]
        let json = """
            {"title":"t","summary":"s","topics":[],"decisions":[],"tasks":[{"text":"Send the report","owner":null,"owner_id":null,"due":"\(due)","seg":10,"quote":"\(segment.prefix(11))"}],"entities":[],"open_questions":[]}
            """
        return try VautaPrompts.validateMinutes(json, segments: segments, candidates: [], selfEntity: 1, reference: Self.meetingDay)
    }

    @Test func aDueDateCopiedFromTheMeetingDayIsDroppedButTheTaskStays() throws {
        for due in ["2026-10-12", "2026-10-13"] {
            let m = try tasks(due: due, segment: "We should send the report to the client soon")
            #expect(m.tasks.count == 1 && m.tasks[0].due == nil && !m.tasks[0].unconfirmed, "due \(due)")
        }
    }

    @Test func aDueDateTheSegmentSupportsIsKept() throws {
        let tomorrow = try tasks(due: "2026-10-13", segment: "We should send the report tomorrow")
        #expect(tomorrow.tasks[0].due != nil && !tomorrow.tasks[0].unconfirmed)
        let friday = try tasks(due: "2026-10-16", segment: "We should send the report on Friday")
        #expect(friday.tasks[0].due != nil && !friday.tasks[0].unconfirmed)
        let spanish = try tasks(due: "2026-10-12", segment: "Hay que enviar el informe hoy mismo")
        #expect(spanish.tasks[0].due != nil, "\"hoy\" says the meeting's day")
    }

    @Test func aLaterUnsupportedDueDateStaysAsUnconfirmed() throws {
        let m = try tasks(due: "2026-11-30", segment: "We should send the report to the client soon")
        #expect(m.tasks[0].due != nil && m.tasks[0].unconfirmed)
    }

    // MARK: Model-gated (VAUTA_LLM_MODEL_DIR names an installed model and VAUTA_LLM_GOLDENS the fixtures folder)

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VAUTA_LLM_MODEL_DIR"] != nil && ProcessInfo.processInfo.environment["VAUTA_LLM_GOLDENS"] != nil))
    func theInstalledModelPassesTheGoldens() async {
        let goldens = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VAUTA_LLM_GOLDENS"] ?? "")
        let result = await LanguageModelSelfTest.run(includeModel: true, long: false, goldens: goldens)
        #expect(result.exitCode == LanguageModelSelfTest.ExitCode.pass, "\(result.lines.joined(separator: "\n"))")
    }

    @Test func aCallersTemperatureReachesTheSampler() {
        let card = DecodingSettings.card(seed: 5)
        #expect(IntegratedChatModel.sampling(requested: nil, settings: card) == card)
        #expect(IntegratedChatModel.sampling(requested: 0, settings: card) == .greedy)
        let warm = IntegratedChatModel.sampling(requested: 0.4, settings: card)
        #expect(warm.temperature == 0.4 && warm.topK == card.topK && warm.topP == card.topP && warm.seed == 5)
        #expect(IntegratedChatModel.sampling(requested: 0.4, settings: .greedy) == .greedy, "a greedy evaluation stays greedy")
    }

    @Test func aModelCheckThatSkippedTheParityGoldensIsNotAPass() {
        typealias C = LanguageModelSelfTest.ExitCode
        #expect(LanguageModelSelfTest.exitCode(failures: 0, paritySkipped: false) == C.pass)
        #expect(LanguageModelSelfTest.exitCode(failures: 0, paritySkipped: true) == C.paritySkipped && C.paritySkipped != C.pass)
        #expect(LanguageModelSelfTest.exitCode(failures: 2, paritySkipped: true) == C.fail)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VAUTA_LLM_MODEL_DIR"] != nil))
    func theInstalledModelWithoutGoldensReportsSkippedParityAndDoesNotPass() async {
        let result = await LanguageModelSelfTest.run(includeModel: true, long: false, goldens: nil)
        #expect(result.exitCode == LanguageModelSelfTest.ExitCode.paritySkipped, "\(result.lines.joined(separator: "\n"))")
        #expect(result.lines.contains { $0.contains("parity: SKIPPED") })
    }

    /// Cancelling a long prefill on the real model is seen within a few hundred milliseconds, not after a 512-token chunk (2.3 to 2.7 s
    /// at the measured 193 to 224 tokens/s). `VAUTA_LLM_CANCEL_TOKENS` (default 6,000) sets the prompt, `VAUTA_LLM_CANCEL_AFTER` (default
    /// 4 s) when to cancel: a later cancel measures deeper context, where each chunk costs more.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VAUTA_LLM_MODEL_DIR"] != nil), .timeLimit(.minutes(10)))
    func cancellingALongPrefillOnTheRealModelIsSeenWithinAFewHundredMilliseconds() async throws {
        let env = ProcessInfo.processInfo.environment
        let tokens = Int(env["VAUTA_LLM_CANCEL_TOKENS"] ?? "") ?? 6_000
        let after = Double(env["VAUTA_LLM_CANCEL_AFTER"] ?? "") ?? 4
        let engine = LanguageModelEngine(store: LanguageModelSelfTest.store())
        try await engine.load()
        let ids: [Int32] = [2] + (0..<tokens).map { Int32(1_000 + ($0 &* 7_919) % 20_000) }
        let job = Task { try await engine.generateIDs(ids, maxTokens: 1) }
        try await Task.sleep(for: .seconds(after))
        let cancelledAt = Date()
        job.cancel()
        _ = await job.result
        let latency = Date().timeIntervalSince(cancelledAt)
        print("cancel latency after \(after) s of a \(tokens)-token prefill: \(String(format: "%.3f", latency)) s")
        #expect(latency < 1.0, "cancel took \(latency) s")
        await engine.unload()
    }

    // MARK: Quiet window of the evaluation

    @Test func aQuietWindowNeedsLowLoadNoBusyProcessAndAnIdleGpu() async {
        let o = LLMEvaluation.Options(sets: URL(fileURLWithPath: "/tmp"), out: URL(fileURLWithPath: "/tmp"))
        typealias C = LLMEvaluation.MachineContext
        #expect(C(load1: 1.5, foreignCPUSum: 30, foreignCPUTop: 20, gpu: 2).isQuiet(o))
        #expect(!C(load1: 5, foreignCPUSum: 0, foreignCPUTop: 0, gpu: 0).isQuiet(o), "load1 not below 4")
        #expect(!C(load1: 1, foreignCPUSum: 160, foreignCPUTop: 90, gpu: 0).isQuiet(o), "a process above 50% of a core")
        #expect(C(load1: 1, foreignCPUSum: 120, foreignCPUTop: 49, gpu: 0).isQuiet(o), "many small ones do not break the window")
        #expect(!C(load1: 1, foreignCPUSum: 0, foreignCPUTop: 0, gpu: 35).isQuiet(o), "a busy GPU")
        // The counters are readable without privileges on this Mac (or absent, never a crash).
        let context = await LLMEvaluation.machineContext()
        #expect(context.load1 >= 0)
        if let top = context.foreignCPUTop, let sum = context.foreignCPUSum { #expect(top >= 0 && sum >= top) }
        if let gpu = context.gpu { #expect((0...100).contains(gpu)) }
    }

    /// Prefill speed against the chunk size on the real model, interleaved (A B C D A B C D), so a shared Mac's load moves all of them
    /// alike. Prints; asserts only that every mode ran. `VAUTA_LLM_BENCH_TOKENS` (default 4,000).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VAUTA_LLM_MODEL_DIR"] != nil && ProcessInfo.processInfo.environment["VAUTA_LLM_BENCH"] != nil),
          .timeLimit(.minutes(20)))
    func prefillSpeedAgainstChunkSize() async throws {
        let tokens = Int(ProcessInfo.processInfo.environment["VAUTA_LLM_BENCH_TOKENS"] ?? "") ?? 4_000
        let engine = LanguageModelEngine(store: LanguageModelSelfTest.store())
        try await engine.load()
        let ids: [Int32] = [2] + (0..<tokens).map { Int32(1_000 + ($0 &* 7_919) % 20_000) }
        var seconds: [String: [Double]] = [:]
        _ = try await engine.generateTimed(Array(ids.prefix(600)), maxTokens: 1)   // warm up
        for round in 0..<2 {
            for (name, chunk) in [("time-sized", nil), ("512", 512), ("128", 128), ("256", 256)] as [(String, Int?)] {
                await engine.setPrefillChunk(chunk)
                let r = try await engine.generateTimed(ids, maxTokens: 1)
                seconds[name, default: []].append(r.prefillSeconds)
                print("round \(round) chunk \(name): \(String(format: "%.1f", r.prefillSeconds)) s = \(Int(Double(tokens) / r.prefillSeconds)) tokens/s, load1 \(String(format: "%.1f", LLMEvaluation.load()[0]))")
            }
        }
        #expect(seconds.count == 4)
        await engine.unload()
    }

    // MARK: Source scans

    static var sources: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources") }

    static func files(under dir: String) -> [URL] {
        let root = sources.appendingPathComponent(dir)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    @Test func theLanguageModelNeverTouchesTheNetworkOrPrivateApisOutsideTheAuditedSession() throws {
        for url in Self.files(under: "VautaCore/LanguageModel") + Self.files(under: "VautaMLX/LLM") {
            let text = try String(contentsOf: url, encoding: .utf8)
            for banned in ["URLSession(", "dataTask(", "NWConnection", "IOReport", "Process()", "posix_spawn", "import MLX"] where !(banned == "import MLX" && url.path.contains("VautaMLX")) {
                #expect(!text.contains(banned), "\(url.lastPathComponent) contains \(banned)")
            }
        }
    }

    @Test func contentIsNeverTokenisedWithSpecialTokenMatchingInThePromptBuilders() throws {
        // The self-test compares `encodeBody` (the Hugging Face behaviour) with the goldens; nothing else may use it.
        for url in Self.files(under: "VautaCore/LanguageModel") where url.lastPathComponent != "LanguageModelSelfTest.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(!text.contains(".encodeBody("), "\(url.lastPathComponent): content must go through encodeLiteral")
        }
    }

    @Test func theShippedProviderPathIgnoresTheTestVariablesOfTheCommandLine() throws {
        // `VAUTA_LLM_MODEL_DIR` steers the hidden commands and the tests only; the app's own provider reads the app's store.
        let providers = try String(contentsOf: Self.sources.appendingPathComponent("VautaCore/LLM/ModelProviding.swift"), encoding: .utf8)
        #expect(!providers.contains("LanguageModelSelfTest") && !providers.contains("VAUTA_LLM_MODEL_DIR"))
        let access = try String(contentsOf: Self.sources.appendingPathComponent("VautaCore/LanguageModel/IntegratedChatModel.swift"), encoding: .utf8)
        #expect(!access.contains("VAUTA_LLM_MODEL_DIR") && access.contains("store: LanguageModelStore = LanguageModelStore()"))
    }

    @Test func everyPortedFileCarriesTheMITNotice() throws {
        for name in ["Gemma4TextModel", "KVCaches", "Sampler", "Generator", "Gemma4TextConfig"] {
            let url = Self.sources.appendingPathComponent("VautaMLX/LLM/\(name).swift")
            let head = try String(contentsOf: url, encoding: .utf8).prefix(500)
            #expect(head.contains("Apache-2.0 AND MIT") && head.contains("mlx-lm") && head.contains("Apple Inc."), "\(name)")
        }
    }
}
