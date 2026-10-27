// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The state machine: a click starts the download, a recording pauses it, cancel keeps the prefix, delete removes everything.
@Suite("Search model: controller")
struct SearchModelControllerTests {
    struct Env {
        let model = SyntheticModel(tokenizerData: Data(TinyTokenizer.json.utf8))
        let behaviour: ModelStub.Behaviour
        let fixture: ModelFixture
        let log = NetworkActivityLog()
        let access = SearchModelAccess()
        nonisolated(unsafe) let defaults = UserDefaults(suiteName: "vauta.tests.\(UUID().uuidString)")!
        let encoderLog = FakeEncoderLog()
        let controller: SearchModelController
        let states = SharedBox<[SearchModelStatus.State]>([])
        let installedHook = SharedBox(0)
        let removedHook = SharedBox(0)

        init(_ configure: (ModelStub.Behaviour) -> Void = { _ in }, importer: (@Sendable ([URL], SearchModelStore, String) async throws -> SearchModelImporter.Outcome)? = nil,
             install: Bool = false, serverConfigured: Bool = false, recording: SharedBox<Bool>? = nil,
             footprint: @escaping @Sendable () -> Int = { 400 }) async {
            behaviour = ModelStub.Behaviour(model)
            configure(behaviour)
            ModelStub.register(behaviour)
            fixture = ModelFixture(spec: model.spec)
            let encoderLog = encoderLog
            let factory = SearchEncoderFactory { _, fp32 in FakeEncoder(fp32: fp32, log: encoderLog) }
            let engine = SearchModelEngine(store: fixture.store, factory: factory, appBuild: "test", footprint: footprint, gate: MLXWorkGate())
            if install {
                try? fixture.store.createStaging()
                try? model.assembled.write(to: fixture.store.stagedWeights)
                try? model.tokenizer.write(to: fixture.store.stagedTokenizer)
                try? fixture.store.install(SearchModelInstallRecord(revision: model.spec.revision, assembledSHA256: model.spec.assembledSHA256,
                                                                    tokenizerSHA256: model.spec.tokenizerSHA256, source: "import", installedAt: Date(), appBuild: "test"))
            }
            let real: @Sendable ([URL], SearchModelStore, String) async throws -> SearchModelImporter.Outcome = {
                try await SearchModelImporter.importFiles($0, store: $1, appBuild: $2)
            }
            controller = SearchModelController(store: fixture.store, engine: engine, access: access, defaults: defaults, log: log,
                                               protocolClasses: [ModelStub.self], supported: { true }, appBuild: "test", importer: importer ?? real)
            if serverConfigured { await controller.setServerConfigProvider { true } }
            let states = states, installed = installedHook, removed = removedHook
            await controller.setStatusHandler { status in states.mutate { $0.append(status.state) } }
            await controller.setHooks(SearchModelHooks(installed: { installed.add(1) }, removed: { removed.add(1) }))
            if let recording { access.setEnvironment { IndexerEnvironment(isRecording: recording.value) } }
            await controller.start()
        }

        func finish() {
            ModelStub.unregister(behaviour)
            fixture.cleanup()
        }

        func wait(for state: @Sendable @escaping (SearchModelStatus.State) -> Bool) async -> Bool {
            let controller = controller
            return await eventually { state(await controller.status.state) }
        }
    }

    @Test func downloadingInstallsPreparesAndAdoptsTheChoice() async throws {
        let env = await Env()
        defer { env.finish() }
        ModelProviderSettings(chat: .onDevice, embeddings: .none).save(defaults: env.defaults)
        await env.controller.download()
        #expect(await env.wait { $0 == .ready })
        #expect(env.access.availability == .installed && env.access.model != nil)
        #expect(ModelProviderSettings.load(defaults: env.defaults, hasServerConfig: false).embeddings == .onDeviceModel, "starting the download said they want it")
        #expect(env.installedHook.value == 1)
        let seen = env.states.value
        #expect(seen.contains { if case .downloading = $0 { true } else { false } } && seen.contains(.verifying) && seen.contains(.preparing) && seen.last == .ready)
        let entries = await env.log.snapshot()
        #expect(!entries.isEmpty && entries.allSatisfy { $0.purpose == .modelDownload })
        // The model loaded once to warm up (a fake here): prepared, not just copied.
        #expect(env.encoderLog.built == [false])
    }

    @Test func someoneWhoChoseAModelServerKeepsIt() async throws {
        let env = await Env()
        defer { env.finish() }
        ModelProviderSettings(chat: .server, embeddings: .server).save(defaults: env.defaults)
        await env.controller.download()
        #expect(await env.wait { $0 == .ready })
        #expect(ModelProviderSettings.load(defaults: env.defaults, hasServerConfig: true).embeddings == .server)
    }

    @Test func aRecordingPausesTheDownloadAndItContinuesByItself() async throws {
        let recording = SharedBox(true)
        let env = await Env()
        defer { env.finish() }
        env.access.setEnvironment { IndexerEnvironment(isRecording: recording.value) }
        await env.controller.download()
        #expect(await env.wait { if case .pausedForRecording = $0 { true } else { false } })
        #expect(env.behaviour.rangeRequests.isEmpty, "no request while paused")
        recording.mutate { $0 = false }
        // Two minutes after a recording is simulated away: it ended long ago.
        env.access.setEnvironment { IndexerEnvironment(isRecording: false, recordingStoppedAt: Date(timeIntervalSinceNow: -600)) }
        #expect(await env.wait { $0 == .ready })
    }

    @Test func cancellingLeavesAPartialStateThatCanBeResumedOrDiscarded() async throws {
        let env = await Env { $0.failRangeRequestsAfter = 1 }
        defer { env.finish() }
        await env.controller.download()
        // The network dropped after a verified block: the card says where it stopped and why, and Resume continues from there.
        #expect(await env.wait { if case .partial = $0 { true } else { false } })
        #expect(await env.controller.status.lastError == .offline)
        #expect(env.fixture.store.disk() == .partial)
        // Resume: the network is back, only the missing blocks are requested.
        env.behaviour.failRangeRequestsAfter = nil
        let before = env.behaviour.rangeRequests.count
        await env.controller.download()
        #expect(await env.wait { $0 == .ready })
        #expect(env.behaviour.rangeRequests.count - before == 2)

        // The first block's connection stalls, so the download is always in flight when it is cancelled.
        let second = await Env { $0.stallRangeRequestsFrom = 0 }
        defer { second.finish() }
        await second.controller.download()
        for _ in 0..<48_000 where second.behaviour.rangeRequests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        await second.controller.cancel()
        #expect(await second.wait { if case .partial = $0 { true } else { false } })
        await second.controller.discard()
        #expect(await second.controller.status.state == .notInstalled && second.fixture.store.disk() == .empty)
    }

    @Test func deletingRemovesTheModelResetsTheChoiceAndTellsTheService() async throws {
        let env = await Env()
        defer { env.finish() }
        await env.controller.download()
        #expect(await env.wait { $0 == .ready })
        ModelProviderSettings(chat: .onDevice, embeddings: .onDeviceModel).save(defaults: env.defaults)
        await env.controller.delete()
        #expect(await env.controller.status.state == .notInstalled)
        #expect(env.access.availability == .notInstalled && env.access.model == nil)
        #expect(env.fixture.store.disk() == .empty && !FileManager.default.fileExists(atPath: env.fixture.store.modelParent.path))
        #expect(ModelProviderSettings.load(defaults: env.defaults, hasServerConfig: false).embeddings == .none)
        #expect(env.removedHook.value == 1)
    }

    @Test func aTamperedDownloadInstallsNothing() async throws {
        let env = await Env { $0.tamperBlockServings = [0: 5] }
        defer { env.finish() }
        await env.controller.download()
        #expect(await env.wait { $0 == .failed(.mismatch) })
        #expect(env.access.availability == .notInstalled && env.fixture.store.disk() == .empty)
    }

    @Test func importingFromAFileInstallsWithoutTheNetwork() async throws {
        let env = await Env()
        defer { env.finish() }
        let dir = env.fixture.root.appendingPathComponent("picked", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try env.model.source.write(to: dir.appendingPathComponent("a.safetensors"))
        try env.model.tokenizer.write(to: dir.appendingPathComponent("tokenizer.json"))
        await env.controller.importFiles([dir.appendingPathComponent("a.safetensors"), dir.appendingPathComponent("tokenizer.json")])
        #expect(await env.controller.status.state == .ready)
        #expect(env.access.availability == .installed)
        #expect(await env.log.snapshot().isEmpty)
        #expect(env.behaviour.hits.isEmpty)
        let wrong = dir.appendingPathComponent("wrong.bin")
        try Data(count: 5).write(to: wrong)
        await env.controller.importFiles([wrong])
        #expect(await env.controller.status.state == .failed(.importWrongFile))
    }
}

extension SearchModelControllerTests {
    @Test func deletingWhileBulkEmbeddingRunsLeavesTheModelNotInstalledNotDamaged() async throws {
        let calls = SharedBox(0)
        // Every batch takes a moment, so the delete lands between two of them, where the embedding loop yields.
        let env = await Env(install: true, footprint: { calls.mutate { $0 += 1 }; usleep(15_000); return 400 })
        defer { env.finish() }
        #expect(await env.wait { $0 == .ready })
        let engine = await env.controller.searchEngine
        let embedding = Task { try await engine.embed(Array(repeating: "ab ab ab", count: 1500), purpose: .document) }
        for _ in 0..<48_000 where calls.value < 3 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(calls.value >= 3, "the embedding was under way")
        await env.controller.delete()
        _ = try? await embedding.value
        // The late report of the suspended embedding (its files are gone) must not turn the deleted model into a damaged one.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await env.controller.status.state == .notInstalled)
        #expect(env.access.availability == .notInstalled)
        #expect(env.states.value.last == .notInstalled && !env.states.value.contains(.damaged))
    }

    @Test func deletingTellsTheServiceBeforeTheFilesGo() async throws {
        let order = SharedBox<[String]>([])
        let env = await Env(install: true)
        defer { env.finish() }
        #expect(await env.wait { $0 == .ready })
        let store = env.fixture.store
        await env.controller.setHooks(SearchModelHooks(removing: { order.mutate { $0.append("removing files=\(store.disk() != .empty)") } },
                                                       removed: { order.mutate { $0.append("removed files=\(store.disk() != .empty)") } }))
        await env.controller.delete()
        #expect(order.value == ["removing files=true", "removed files=false"])
    }

    @Test func importingOnlyTheWeightsAsksForTheTokenizerAndDownloadingJustItFinishes() async throws {
        let env = await Env()
        defer { env.finish() }
        let file = env.fixture.root.appendingPathComponent("model.safetensors")
        try env.model.assembled.write(to: file)
        await env.controller.importFiles([file])
        #expect(await env.controller.status.state == .needsFile(missing: .tokenizer))
        #expect(env.behaviour.hits.isEmpty, "importing never touches the network")
        // A relaunch with the same staging says the same thing instead of “download stopped”.
        await env.controller.start()
        #expect(await env.controller.status.state == .needsFile(missing: .tokenizer))
        await env.controller.download(tokenizerOnly: true)
        #expect(await env.wait { $0 == .ready })
        #expect(env.behaviour.rangeRequests.isEmpty, "only the tokenizer was requested")
        #expect(env.behaviour.hits.allSatisfy { $0.path.hasSuffix(env.model.spec.tokenizerFile) })
    }

    @Test func importingOnlyTheTokenizerAsksForTheWeightsAndImportingThemFinishes() async throws {
        let env = await Env()
        defer { env.finish() }
        let tokenizer = env.fixture.root.appendingPathComponent("tokenizer.json")
        try env.model.tokenizer.write(to: tokenizer)
        await env.controller.importFiles([tokenizer])
        #expect(await env.controller.status.state == .needsFile(missing: .weights))
        let weights = env.fixture.root.appendingPathComponent("model.safetensors")
        try env.model.assembled.write(to: weights)
        await env.controller.importFiles([weights])
        #expect(await env.controller.status.state == .ready)
        #expect(env.behaviour.hits.isEmpty)
    }

    @Test func discardingAHalfImportedModelStartsOver() async throws {
        let env = await Env()
        defer { env.finish() }
        let file = env.fixture.root.appendingPathComponent("model.safetensors")
        try env.model.assembled.write(to: file)
        await env.controller.importFiles([file])
        await env.controller.discard()
        #expect(await env.controller.status.state == .notInstalled && env.fixture.store.disk() == .empty)
    }

    @Test func deletingDuringAnImportStopsItAndTheModelIsNotInstalledAfterwards() async throws {
        let started = SharedBox(false)
        // An import that ignores cancellation and ends "installed" after a while: the worst case for the race.
        let env = await Env(importer: { _, _, _ in
            started.mutate { $0 = true }
            try? await Task.sleep(for: .milliseconds(300))
            return .installed
        })
        defer { env.finish() }
        ModelProviderSettings(chat: .onDevice, embeddings: .none).save(defaults: env.defaults)
        let importing = Task { await env.controller.importFiles([URL(fileURLWithPath: "/nonexistent")]) }
        for _ in 0..<48_000 where !started.value { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await env.controller.status.cancellable)
        await env.controller.delete()
        await importing.value
        #expect(await env.controller.status.state == .notInstalled)
        #expect(env.access.availability == .notInstalled && env.access.model == nil)
        #expect(ModelProviderSettings.load(defaults: env.defaults, hasServerConfig: false).embeddings == .none, "the setting did not move")
        #expect(env.installedHook.value == 0)
    }

    @Test func cancellingAnImportCancelsTheWorkItself() async throws {
        let sawCancel = SharedBox(false)
        let env = await Env(importer: { _, _, _ in
            do { try await Task.sleep(for: .seconds(30)) } catch { sawCancel.mutate { $0 = true }; throw error }
            return .installed
        })
        defer { env.finish() }
        let importing = Task { await env.controller.importFiles([URL(fileURLWithPath: "/nonexistent")]) }
        for _ in 0..<48_000 where !(await env.controller.status.cancellable) { try await Task.sleep(for: .milliseconds(5)) }
        await env.controller.cancel()
        await importing.value
        #expect(sawCancel.value, "the detached import was cancelled, not just a wrapper")
        #expect(await env.controller.status.state == .notInstalled, "nothing was verified, so nothing is left to resume")
    }

    @Test func aDamagedInstallAtLaunchIsSaidToBeDamagedNotNotInstalled() async throws {
        let env = await Env(install: true)
        defer { env.finish() }
        #expect(await env.wait { $0 == .ready }, "prepared in the background after launch")
        var bytes = try Data(contentsOf: env.fixture.store.weightsURL)
        bytes[0] ^= 0xFF   // the header no longer matches
        try bytes.write(to: env.fixture.store.weightsURL)
        await env.controller.start()
        #expect(await env.controller.status.state == .damaged)
        #expect(await env.controller.status.installedBytes > 0, "the files are there, so Settings offers Delete")
        #expect(env.access.availability == .unavailable(.verificationFailed))
        // Try Again deletes the damaged files and downloads them again.
        await env.controller.retry()
        #expect(await env.wait { $0 == .ready })
        #expect(env.behaviour.rangeRequests.count == 3)
    }

    @Test func aTamperedTokenizerAtLaunchMakesTheInstallDamaged() async throws {
        let env = await Env(install: true)
        defer { env.finish() }
        #expect(await env.wait { $0 == .ready })
        try Data(count: 5).write(to: env.fixture.store.tokenizerURL)
        await env.controller.start()
        #expect(await env.controller.status.state == .damaged)
    }

    @Test func anInstalledModelIsPreparedInTheBackgroundAtLaunchAndNotWhileRecording() async throws {
        let recording = SharedBox(true)
        // The environment is set before the first start, as the app does.
        let env = await Env(install: true, recording: recording)
        defer { env.finish() }
        #expect(await env.controller.status.state == .ready)
        #expect(env.encoderLog.built.isEmpty, "no GPU work while recording")
        recording.mutate { $0 = false }
        env.access.setEnvironment { IndexerEnvironment(isRecording: false, recordingStoppedAt: Date(timeIntervalSinceNow: -600)) }
        await env.controller.preload()
        #expect(await env.wait { $0 == .ready } && env.encoderLog.built == [false], "loaded once, in the background")
        #expect(env.states.value.contains(.preparing))
        await env.controller.preload()
        #expect(env.encoderLog.built == [false], "already loaded: nothing to do")
    }

    @Test func installingKeepsTheModelServerOfSomeoneWhoNeverChoseAndTouchesNoChatChoice() async throws {
        let env = await Env(serverConfigured: true)
        defer { env.finish() }
        // 0.1 behaviour: no saved keys, a server configured, so search and minutes are on the server.
        #expect(env.defaults.string(forKey: "modelProviderChat") == nil)
        await env.controller.download()
        #expect(await env.wait { $0 == .ready })
        #expect(env.defaults.string(forKey: "modelProviderChat") == nil && env.defaults.string(forKey: "modelProviderEmbeddings") == nil, "nothing was written")
        #expect(ModelProviderSettings.load(defaults: env.defaults, hasServerConfig: true) == .init(chat: .server, embeddings: .server))
    }

    @Test func aDropAfterTheNetworkWentAwayKeepsTheVerifiedBlocksAndSaysWhy() async throws {
        let env = await Env { $0.failRangeRequestsAfter = 2 }
        defer { env.finish() }
        await env.controller.download()
        #expect(await env.wait { if case .partial = $0 { true } else { false } })
        let status = await env.controller.status
        #expect(status.lastError == .offline)
        if case .partial(let verified, _) = status.state { #expect(verified > env.model.spec.tokenizerSize) }
        #expect(env.fixture.store.disk() == .partial)
    }
}

@Suite("Search model: progress meter")
struct SearchModelProgressMeterTests {
    @Test func updatesAreAtMostFourPerSecondAndTheRemainingTimeComesAfterThreeSeconds() {
        let meter = SearchModelProgressMeter()
        var emitted = 0
        var firstETA: Double?
        for i in 0..<400 {
            let t = Double(i) * 0.01
            if let tick = meter.record(bytes: i * 1_000_000, total: 574_000_000, at: t) {
                emitted += 1
                if tick.remaining != nil, firstETA == nil { firstETA = t }
            }
        }
        #expect(emitted <= 4 * 4 + 1, "four seconds, four updates a second")
        #expect((firstETA ?? 99) >= 3)
    }

    @Test func theRateIsAMovingAverage() {
        let meter = SearchModelProgressMeter(window: 5, interval: 0)
        var last: Double?
        for i in 0...20 { last = meter.record(bytes: i * 10_000_000, total: 1_000_000_000, at: Double(i))?.rate ?? last }
        #expect(abs((last ?? 0) - 10_000_000) < 1)
        // A slowdown shows up within the window.
        for i in 21...30 { last = meter.record(bytes: 200_000_000 + (i - 20) * 1_000_000, total: 1_000_000_000, at: Double(i))?.rate ?? last }
        #expect((last ?? 99_000_000) < 3_000_000)
    }
}
