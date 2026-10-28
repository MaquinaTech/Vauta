// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Guided model setup: recommendation and catalog")
struct ModelSetupCatalogTests {
    private let gib = ModelRecommendation.gibibyte

    @Test func memoryTiersAndBoundaries() {
        #expect(ModelRecommendation(physicalMemory: 8 * gib).tier == .belowMinimum)
        #expect(ModelRecommendation(physicalMemory: 16 * gib - 1).tier == .belowMinimum)
        #expect(ModelRecommendation(physicalMemory: 16 * gib).tier == .standard)
        #expect(ModelRecommendation(physicalMemory: 24 * gib).tier == .standard)
        #expect(ModelRecommendation(physicalMemory: 32 * gib - 1).tier == .standard)
        #expect(ModelRecommendation(physicalMemory: 32 * gib).tier == .large)
        #expect(ModelRecommendation(physicalMemory: 192 * gib).tier == .large)
    }

    @Test func modelsPerTier() {
        let none = ModelRecommendation(physicalMemory: 8 * gib)
        #expect(!none.hasRecommendation && none.models().isEmpty)
        let standard = ModelRecommendation(physicalMemory: 16 * gib)
        #expect(standard.main == .qwen35_9B && standard.fast == nil && standard.models() == [.qwen35_9B])
        let large = ModelRecommendation(physicalMemory: 64 * gib)
        #expect(large.main == .qwen38_27B && large.fast == .qwen35_9B)
        #expect(large.models() == [.qwen38_27B, .qwen35_9B])
        #expect(large.models(includeFast: false) == [.qwen38_27B])
    }

    @Test func commandsPerApp() {
        #expect(LocalModel.qwen35_9B.install(for: .lmStudio) == .command("lms get qwen/qwen3.5-9b"))
        #expect(LocalModel.qwen35_9B.install(for: .ollama) == .command("ollama pull qwen3.5:9b"))
        #expect(LocalModel.qwen38_27B.install(for: .lmStudio) == .command("lms get qwen/qwen3.8-27b"))
        #expect(LocalModel.qwen38_27B.install(for: .ollama) == .command("ollama pull qwen3.8:27b"))
        #expect(LocalModel.qwen35_9B.contextFix(for: .lmStudio) == .command("lms load qwen/qwen3.5-9b --context-length 32768"))
        #expect(LocalModel.qwen38_27B.contextFix(for: .ollama) == .appSetting)
        #expect(LocalModelApp.lmStudio.startServerCommand == "lms server start")
        #expect(LocalModelApp.ollama.startServerCommand == nil)
    }

    @Test func appsHaveOfficialSitesAndBundleIDs() {
        #expect(LocalModelApp.lmStudio.websiteURL.absoluteString == "https://lmstudio.ai")
        #expect(LocalModelApp.ollama.websiteURL.host() == "ollama.com")
        #expect(LocalModelApp.lmStudio.bundleIdentifiers == ["ai.elementlabs.lmstudio"])
        #expect(LocalModelApp.ollama.bundleIdentifiers.contains("com.electron.ollama"))
        #expect(LocalModelApp.allCases.allSatisfy { $0.websiteURL.scheme == "https" })
    }

    @Test func downloadSizes() {
        let large = ModelRecommendation(physicalMemory: 32 * gib)
        #expect(abs(large.downloadGB(for: .lmStudio) - 23.1) < 0.001)
        #expect(abs(large.downloadGB(for: .ollama, includeFast: false) - 18) < 0.001)
    }

    @Test func modelIDMatching() {
        let nine = LocalModel.qwen35_9B
        for id in ["qwen/qwen3.5-9b", "qwen3.5:9b", "mlx-community/Qwen3.5-9B-4bit", "Qwen3.5-9B-MLX", "qwen3.5:9b-q4_K_M"] {
            #expect(nine.matches(modelID: id), "\(id)")
        }
        for id in ["qwen/qwen3.5-19b", "qwen3.5:27b", "qwen3-9b", "qwen3.8-9b", "qwen3.55-9b", "llama-3.1-8b"] {
            #expect(!nine.matches(modelID: id), "\(id)")
        }
        #expect(LocalModel.qwen38_27B.matches(modelID: "qwen/qwen3.8-27b"))
        #expect(!LocalModel.qwen38_27B.matches(modelID: "qwen/qwen3.5-27b"))
    }

    @Test func freeDiskCheck() {
        let need = DiskSpace.requiredBytes(downloadGB: 7)
        #expect(need == 12_000_000_000)
        #expect(DiskSpace.isShort(downloadGB: 7, available: need - 1))
        #expect(!DiskSpace.isShort(downloadGB: 7, available: need))
        #expect(!DiskSpace.isShort(downloadGB: 7, available: nil))
        #expect((DiskSpace.availableBytes() ?? 1) > 0)
    }
}

@Suite("Guided model setup: status and configuration")
struct ModelSetupEvaluationTests {
    private let gib = ModelRecommendation.gibibyte

    private func server(_ kind: ServerKind, _ models: [DiscoveredModel]) -> DiscoveredServer {
        DiscoveredServer(kind: kind, baseURL: URL(string: "http://127.0.0.1:\(kind.defaultPort)/v1/")!, version: nil, models: models)
    }

    private func chat(_ id: String, context: Int? = nil) -> DiscoveredModel {
        DiscoveredModel(id: id, kind: .chat, contextLength: context, loaded: context != nil)
    }

    private func configuration(_ app: LocalModelApp = .lmStudio, memory: UInt64 = 16, fast: Bool = true,
                               existing: LLMServerConfig? = nil) -> SetupConfiguration {
        SetupConfiguration(app: app, recommendation: ModelRecommendation(physicalMemory: memory * gib), includeFastModel: fast,
                           existing: existing)
    }

    @Test func noServerMeansNotRunning() {
        #expect(SetupEvaluation.evaluate([], configuration: configuration()) == .serverNotRunning)
    }

    @Test func serverWithoutTheModel() {
        let lms = server(.lmStudio, [chat("google/gemma-3-4b", context: 32768)])
        #expect(SetupEvaluation.evaluate([lms], configuration: configuration()) == .noSuitableModel(serverKind: .lmStudio))
        // Another app's server without the model is not what the guide is about.
        let ollama = server(.ollama, [chat("llama3.2:3b")])
        #expect(SetupEvaluation.evaluate([ollama], configuration: configuration(.lmStudio)) == .serverNotRunning)
    }

    @Test func contextTooSmallReportsTheFix() {
        let lms = server(.lmStudio, [chat("qwen/qwen3.5-9b", context: 4096)])
        let status = SetupEvaluation.evaluate([lms], configuration: configuration())
        guard case .contextTooSmall(let shortfall) = status else { Issue.record("\(status)"); return }
        #expect(shortfall.current == 4096 && shortfall.required == 32768 && shortfall.serverKind == .lmStudio)
        #expect(shortfall.model.contextFix(for: .lmStudio) == .command("lms load qwen/qwen3.5-9b --context-length 32768"))
        // A loaded model is unloaded first (loading it again would add a second copy), by the identifier the server reported.
        #expect(shortfall.model.contextFix(for: .lmStudio, loadedID: shortfall.modelID)
                == .command("lms unload qwen/qwen3.5-9b && lms load qwen/qwen3.5-9b --context-length 32768"))
        #expect(shortfall.model.contextFix(for: .lmStudio, loadedID: "my model's copy")
                == .command("lms unload 'my model'\\''s copy' && lms load 'my model'\\''s copy' --context-length 32768"))
    }

    @Test func shortContextOfTheFastModelNamesTheFastModel() {
        let lms = server(.lmStudio, [chat("qwen/qwen3.8-27b", context: 32768), chat("mlx-community/qwen3.5-9b-4bit", context: 4096)])
        guard case .contextTooSmall(let shortfall) = SetupEvaluation.evaluate([lms], configuration: configuration(memory: 32)) else {
            Issue.record("not short"); return
        }
        #expect(shortfall.modelID == "mlx-community/qwen3.5-9b-4bit" && shortfall.current == 4096)
        #expect(shortfall.model.contextFix(for: .lmStudio, loadedID: shortfall.modelID)
                == .command("lms unload mlx-community/qwen3.5-9b-4bit && lms load mlx-community/qwen3.5-9b-4bit --context-length 32768"))
    }

    @Test func readyConfiguresTheServer() throws {
        let lms = server(.lmStudio, [chat("qwen/qwen3.5-9b", context: 32768),
                                     DiscoveredModel(id: "text-embedding-nomic-embed-text-v1.5", kind: .embedding)])
        let status = SetupEvaluation.evaluate([lms], configuration: configuration())
        guard case .ready(let candidate) = status else { Issue.record("\(status)"); return }
        let config = candidate.config
        #expect(config.mode == .local && config.baseURL == "http://127.0.0.1:1234/v1")
        #expect(config.fastModel == "qwen/qwen3.5-9b" && config.deepModel == "qwen/qwen3.5-9b")
        #expect(config.contextTokens == 32768 && config.profile?.kind == .lmStudio && candidate.contextVerified)
        _ = try config.validatedEndpoints(embeddingsOnServer: false)
    }

    @Test func largeMacUsesBothModels() {
        let lms = server(.lmStudio, [chat("qwen/qwen3.5-9b", context: 65536), chat("qwen/qwen3.8-27b", context: 40960),
                                     chat("google/gemma-3-1b", context: 4096)])
        guard case .ready(let both) = SetupEvaluation.evaluate([lms], configuration: configuration(memory: 64)) else {
            Issue.record("not ready"); return
        }
        #expect(both.mainModel == "qwen/qwen3.8-27b" && both.fastModel == "qwen/qwen3.5-9b")
        #expect(both.config.contextTokens == 40960)
        guard case .ready(let single) = SetupEvaluation.evaluate([lms], configuration: configuration(memory: 64, fast: false)) else {
            Issue.record("not ready"); return
        }
        #expect(single.mainModel == "qwen/qwen3.8-27b" && single.fastModel == "qwen/qwen3.8-27b")
        // Only the smaller evaluated model is there: it is accepted for both roles.
        let only9B = server(.lmStudio, [chat("qwen/qwen3.5-9b", context: 32768)])
        guard case .ready(let degraded) = SetupEvaluation.evaluate([only9B], configuration: configuration(memory: 64)) else {
            Issue.record("not ready"); return
        }
        #expect(degraded.mainModel == "qwen/qwen3.5-9b")
    }

    @Test func unknownContextIsReadyButUnverified() {
        let ollama = server(.ollama, [chat("qwen3.5:9b")])
        guard case .ready(let candidate) = SetupEvaluation.evaluate([ollama], configuration: configuration(.ollama)) else {
            Issue.record("not ready"); return
        }
        #expect(!candidate.contextVerified && candidate.config.contextTokens == 32768 && candidate.config.profile?.kind == .ollama)
    }

    @Test func keepsTheEmbeddingModelOfTheSameServer() {
        let existing = LLMServerConfig(mode: .local, baseURL: "http://127.0.0.1:1234/v1", fastModel: "a", deepModel: "b",
                                       embeddingModel: "my-embedder", profile: .defaults(for: .lmStudio))
        let lms = server(.lmStudio, [chat("qwen/qwen3.5-9b", context: 32768), DiscoveredModel(id: "other-embed", kind: .embedding)])
        guard case .ready(let same) = SetupEvaluation.evaluate([lms], configuration: configuration(existing: existing)) else {
            Issue.record("not ready"); return
        }
        #expect(same.config.embeddingModel == "my-embedder")
        // Its settings and its own address stay too, so the search index keeps matching.
        var tuned = existing
        tuned.embedding = EmbeddingSettings(dimensions: 768)
        tuned.roleBaseURLs = RoleBaseURLs(embedding: "http://127.0.0.1:8081/v1")
        guard case .ready(let kept) = SetupEvaluation.evaluate([lms], configuration: configuration(existing: tuned)) else {
            Issue.record("not ready"); return
        }
        #expect(kept.config.embedding == EmbeddingSettings(dimensions: 768))
        #expect(kept.config.roleBaseURLs == RoleBaseURLs(embedding: "http://127.0.0.1:8081/v1"))
        // Another server: nothing of the old embedding setup is carried over.
        let elsewhere = LLMServerConfig(mode: .local, baseURL: "http://127.0.0.1:11434/v1", fastModel: "a", deepModel: "b",
                                        embeddingModel: "old-embedder", profile: .defaults(for: .ollama))
        guard case .ready(let fresh) = SetupEvaluation.evaluate([lms], configuration: configuration(existing: elsewhere)) else {
            Issue.record("not ready"); return
        }
        #expect(fresh.config.embeddingModel != "old-embedder" && fresh.config.roleBaseURLs == nil)
    }

    @Test func bestServerWins() {
        let lms = server(.lmStudio, [chat("llama")])
        let ollama = server(.ollama, [chat("qwen3.5:9b", context: 32768)])
        guard case .ready(let candidate) = SetupEvaluation.evaluate([lms, ollama], configuration: configuration(.lmStudio)) else {
            Issue.record("not ready"); return
        }
        #expect(candidate.serverKind == .ollama)
    }
}

/// A scanner that counts its calls and returns a scripted list. A blocking one never ends a scan by itself:
/// each scan waits until its task is cancelled, and counts the cancellation.
private actor StubScanner: ServerScanning {
    private(set) var scans = 0
    private(set) var cancelled = 0
    private var servers: [DiscoveredServer]
    private let blocks: Bool

    init(servers: [DiscoveredServer] = [], blocksUntilCancelled: Bool = false) {
        self.servers = servers
        self.blocks = blocksUntilCancelled
    }

    func set(_ servers: [DiscoveredServer]) { self.servers = servers }

    func scan() async -> [DiscoveredServer] {
        scans += 1
        if blocks {
            do {
                while true { try await Task.sleep(for: .seconds(3_600)) }
            } catch {
                cancelled += 1
            }
        }
        return servers
    }
}

@Suite("Guided model setup: polling lifecycle")
@MainActor
struct ModelSetupWatcherTests {
    private func configuration() -> SetupConfiguration {
        SetupConfiguration(app: .lmStudio, recommendation: ModelRecommendation(physicalMemory: 16 * ModelRecommendation.gibibyte))
    }

    private func wait(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<24_000 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test func doesNothingUntilStarted() async {
        let stub = StubScanner()
        let watcher = ModelSetupWatcher(scanner: stub, interval: .milliseconds(5), configuration: configuration())
        try? await Task.sleep(for: .milliseconds(60))
        #expect(await stub.scans == 0 && !watcher.isActive && watcher.status == .searching)
    }

    @Test func pollsWhileActiveAndStopsWhenStopped() async {
        let stub = StubScanner()
        let watcher = ModelSetupWatcher(scanner: stub, interval: .milliseconds(5), configuration: configuration())
        watcher.start()
        watcher.start()  // idempotent
        #expect(await wait { await stub.scans >= 3 })
        #expect(watcher.status == .serverNotRunning && watcher.isActive)
        watcher.stop()
        #expect(!watcher.isActive)
        try? await Task.sleep(for: .milliseconds(30))
        let after = await stub.scans
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await stub.scans == after, "no scan after stop()")
    }

    @Test func reportsChangesAsTheServerComesUp() async {
        let stub = StubScanner()
        let watcher = ModelSetupWatcher(scanner: stub, interval: .milliseconds(5), configuration: configuration())
        watcher.start()
        #expect(await wait { watcher.status == .serverNotRunning })
        let lms = DiscoveredServer(kind: .lmStudio, baseURL: URL(string: "http://127.0.0.1:1234/v1/")!, version: nil,
                                   models: [DiscoveredModel(id: "qwen/qwen3.5-9b", kind: .chat, contextLength: 32768)])
        await stub.set([lms])
        #expect(await wait { if case .ready = watcher.status { true } else { false } })
        watcher.stop()
    }

    @Test func stopCancelsAScanInFlight() async {
        // Only stop() can end this scan, so no deadline decides the result, however slow the runner is.
        let stub = StubScanner(blocksUntilCancelled: true)
        let watcher = ModelSetupWatcher(scanner: stub, interval: .milliseconds(5), configuration: configuration())
        watcher.start()
        #expect(await wait { await stub.scans == 1 })
        watcher.stop()
        #expect(await wait { await stub.cancelled == 1 }, "stop() cancels the scan in flight")
        #expect(watcher.status == .searching, "a cancelled scan publishes nothing")
        #expect(await stub.scans == 1, "no scan after stop()")
    }

    @Test func canRestartAfterStop() async {
        let stub = StubScanner()
        let watcher = ModelSetupWatcher(scanner: stub, interval: .milliseconds(5), configuration: configuration())
        watcher.start()
        #expect(await wait { await stub.scans >= 1 })
        watcher.stop()
        let before = await stub.scans
        watcher.start()
        #expect(await wait { await stub.scans > before + 1 })
        watcher.stop()
    }

    @Test func changingTheConfigurationReevaluatesWithoutScanning() async {
        let ollama = DiscoveredServer(kind: .ollama, baseURL: URL(string: "http://127.0.0.1:11434/v1/")!, version: nil,
                                      models: [DiscoveredModel(id: "qwen3.5:9b", kind: .chat, contextLength: 8192)])
        let stub = StubScanner(servers: [ollama])
        // An interval no test run reaches: a second scan cannot come in before the count is compared.
        let watcher = ModelSetupWatcher(scanner: stub, interval: .seconds(86_400), configuration: configuration())
        watcher.start()
        #expect(await wait { watcher.status != .searching })
        let scans = await stub.scans
        var other = configuration()
        other.app = .ollama
        watcher.configuration = other
        if case .contextTooSmall(let shortfall) = watcher.status { #expect(shortfall.serverKind == .ollama) } else { Issue.record("\(watcher.status)") }
        #expect(await stub.scans == scans)
        watcher.stop()
    }
}
