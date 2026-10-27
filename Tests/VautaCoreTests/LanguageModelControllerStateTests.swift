// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Synchronization
import Testing
@testable import VautaCore

/// The transitions of the state machine behind Settings → Models, on a synthetic model and a stubbed Hugging Face.
@Suite("Language model: controller states", .serialized)
struct LanguageModelControllerStateTests {
    struct Rig {
        let model: SyntheticLanguageModel
        let behaviour: LanguageModelStub.Behaviour
        let fixture: LanguageModelFixture
        let store: LanguageModelStore
        let suite: String
        var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
        let env: LanguageModelSchedulingTests.EnvironmentBox
        let controller: LanguageModelController
        let access: LanguageModelAccess

        init(recording: Bool = false, capacity: (@Sendable () -> Int?)? = nil) {
            model = SyntheticLanguageModel()
            behaviour = LanguageModelStub.Behaviour(model)
            LanguageModelStub.register(behaviour)
            fixture = LanguageModelFixture(spec: model.spec)
            var store = fixture.store
            store.capacityOverride = capacity
            self.store = store
            suite = "lm-test-\(UUID().uuidString)"
            env = LanguageModelSchedulingTests.EnvironmentBox(IndexerEnvironment(isRecording: recording))
            access = LanguageModelAccess()
            let box = env
            controller = LanguageModelController(store: store, access: access, engine: LanguageModelEngine(store: store, gate: MLXWorkGate()),
                                                 environment: { box.current }, log: NetworkActivityLog(), protocolClasses: [LanguageModelStub.self],
                                                 supported: { nil }, defaults: UserDefaults(suiteName: suite)!, appBuild: "test", pollInterval: .milliseconds(10), prepare: { _ in })
        }

        func finish() { LanguageModelStub.unregister(behaviour); fixture.cleanup() }

        func state() async -> LanguageModelStatus.State { await controller.status.state }

        /// An import that waits for a recording stays an import (`importing`) and is marked as waiting; it is never the download's paused state.
        func eventuallyImportPaused() async -> Bool {
            await LanguageModelSchedulingTests.eventually { await controller.status.importPaused }
        }

        func eventually(_ condition: @escaping @Sendable (LanguageModelStatus.State) -> Bool) async -> Bool {
            await LanguageModelSchedulingTests.eventually { condition(await controller.status.state) }
        }
    }

    static func isReady(_ s: LanguageModelStatus.State) -> Bool { s == .ready }
    static func isPartial(_ s: LanguageModelStatus.State) -> Bool { if case .partial = s { true } else { false } }
    static func isPaused(_ s: LanguageModelStatus.State) -> Bool { if case .pausedForRecording = s { true } else { false } }

    @Test func notEnoughRoomFailsBeforeAnyRequest() async throws {
        let rig = Rig(capacity: { 1 << 20 })
        defer { rig.finish() }
        await rig.controller.start()
        await rig.controller.download()
        guard case .failed(.diskFull(let needed)) = await rig.state() else { Issue.record("expected diskFull, got \(await rig.state())"); return }
        #expect(needed > 0)
        #expect(rig.behaviour.hits.isEmpty, "the pre-flight check makes no request")
    }

    @Test func startingTheDownloadChoosesTheModelAtOnce() async throws {
        let rig = Rig(recording: true)
        defer { rig.finish() }
        let chosen = Mutex(0)
        await rig.controller.setHooks(LanguageModelHooks(chosen: { chosen.withLock { $0 += 1 } }))
        #expect(rig.defaults.string(forKey: ModelProviderSettings.chatKey) == nil)
        await rig.controller.start()
        await rig.controller.download()
        #expect(rig.defaults.string(forKey: ModelProviderSettings.chatKey) == "integrated", "the chat choice is saved before the transfer")
        #expect(chosen.withLock { $0 } == 1)
        await rig.controller.cancelAndDiscard()
        #expect(rig.defaults.string(forKey: ModelProviderSettings.chatKey) == "integrated", "cancelling the download does not undo the choice")
    }

    @Test(.timeLimit(.minutes(2))) func aDroppedConnectionKeepsTheBlocksAndTheNextRunResumes() async throws {
        let rig = Rig()
        defer { rig.finish() }
        rig.behaviour.failRangeRequestsAfter = 4
        await rig.controller.start()
        await rig.controller.download()
        #expect(await rig.eventually { Self.isPartial($0) })
        let partial = await rig.controller.status
        guard case .partial(let verified, let total) = partial.state else { Issue.record("expected partial, got \(partial.state)"); return }
        #expect(verified > 0 && verified < total && partial.lastError == .offline, "paused with what is verified, and why")
        let firstRun = rig.behaviour.rangeRequests.count
        rig.behaviour.failRangeRequestsAfter = nil
        await rig.controller.download()
        #expect(await rig.eventually(Self.isReady))
        #expect(rig.behaviour.rangeRequests.count - firstRun < firstRun + rig.model.spec.blocks.count, "blocks already verified were not fetched again")
        TestHardware.expectIntegratedModelAvailability(of: rig.access)
    }

    @Test(.timeLimit(.minutes(2))) func cancellingDiscardsWhatWasKept() async throws {
        let rig = Rig(recording: true)
        defer { rig.finish() }
        await rig.controller.start()
        await rig.controller.download()
        #expect(await rig.eventually(Self.isPaused))
        await rig.controller.cancelAndDiscard()
        #expect(await rig.state() == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: rig.store.stagingDirectory.path), "the staging area is gone")
    }

    @Test(.timeLimit(.minutes(2))) func discardingAPausedDownloadStartsFromTheBeginning() async throws {
        let rig = Rig()
        defer { rig.finish() }
        rig.behaviour.failRangeRequestsAfter = 3
        await rig.controller.start()
        await rig.controller.download()
        #expect(await rig.eventually { Self.isPartial($0) })
        await rig.controller.discard()
        #expect(await rig.state() == .notInstalled)
        #expect(rig.store.disk() == .empty)
    }

    @Test(.timeLimit(.minutes(2))) func aRecordingPausesTheImportToo() async throws {
        let rig = Rig(recording: true)
        defer { rig.finish() }
        let file = rig.fixture.root.appendingPathComponent("original.safetensors")
        try FileManager.default.createDirectory(at: rig.fixture.root, withIntermediateDirectories: true)
        try rig.model.source.write(to: file)
        await rig.controller.start()
        let controller = rig.controller
        let run = Task { await controller.importFiles([file]) }
        let paused = await rig.eventuallyImportPaused()
        let now = await rig.state()
        #expect(paused, "paused with the conversion not started: \(now)")
        if case .importing = now {} else { Issue.record("an import that waits stays an import, not the download's paused state: \(now)") }
        #expect(await rig.controller.status.source == "import")
        rig.env.set(IndexerEnvironment(isRecording: false, recordingStoppedAt: Date(timeIntervalSinceNow: -121)))
        await run.value
        #expect(await !rig.controller.status.importPaused, "the mark goes with the wait")
        // The tokenizer is still missing after an import of the original file alone.
        #expect(await rig.state() == .needsFile(.tokenizer))
        #expect(rig.behaviour.hits.isEmpty, "an import never goes to the network")
    }

    @Test(.timeLimit(.minutes(2))) func cancellingAnImportRemovesItsLeftoversAndNeverOffersADownload() async throws {
        let rig = Rig(recording: true)
        defer { rig.finish() }
        let file = rig.fixture.root.appendingPathComponent("original.safetensors")
        try FileManager.default.createDirectory(at: rig.fixture.root, withIntermediateDirectories: true)
        try rig.model.source.write(to: file)
        await rig.controller.start()
        let controller = rig.controller
        let run = Task { await controller.importFiles([file]) }
        #expect(await rig.eventuallyImportPaused())
        await rig.controller.cancelImport()
        await run.value
        #expect(await rig.state() == .notInstalled, "a cancelled import is not a paused download that Resume would fetch")
        #expect(!FileManager.default.fileExists(atPath: rig.store.stagingDirectory.path))
        #expect(rig.behaviour.hits.isEmpty)
    }

    @Test(.timeLimit(.minutes(2))) func cancellingTheSecondImportKeepsTheFirstFile() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let weights = rig.fixture.root.appendingPathComponent("original.safetensors"), tokenizer = rig.fixture.root.appendingPathComponent("tokenizer.json")
        try FileManager.default.createDirectory(at: rig.fixture.root, withIntermediateDirectories: true)
        try rig.model.source.write(to: weights)
        try rig.model.tokenizer.write(to: tokenizer)
        await rig.controller.start()
        await rig.controller.importFiles([tokenizer])
        #expect(await rig.state() == .needsFile(.weights))
        rig.env.set(IndexerEnvironment(isRecording: true))
        let controller = rig.controller
        let run = Task { await controller.importFiles([weights]) }
        #expect(await rig.eventuallyImportPaused())
        await rig.controller.cancelImport()
        await run.value
        #expect(await rig.state() == .needsFile(.weights), "the tokenizer chosen before stays; the card asks for the weights again")
        #expect(rig.behaviour.hits.isEmpty)
    }

    @Test(.timeLimit(.minutes(2))) func importingBothFilesInstallsTheModel() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let weights = rig.fixture.root.appendingPathComponent("assembled.safetensors"), tokenizer = rig.fixture.root.appendingPathComponent("tokenizer.json")
        try FileManager.default.createDirectory(at: rig.fixture.root, withIntermediateDirectories: true)
        try rig.model.assembled.write(to: weights)
        try rig.model.tokenizer.write(to: tokenizer)
        await rig.controller.start()
        await rig.controller.importFiles([tokenizer])
        #expect(await rig.state() == .needsFile(.weights))
        await rig.controller.importFiles([weights])
        #expect(await rig.state() == .ready)
        TestHardware.expectIntegratedModelAvailability(of: rig.access)
        // A file that is not the model is refused with its own reason.
        let wrong = rig.fixture.root.appendingPathComponent("other.bin")
        try Data(repeating: 1, count: 1_234).write(to: wrong)
        await rig.controller.delete()
        await rig.controller.importFiles([wrong])
        #expect(await rig.state() == .failed(.importWrongFile))
    }

    @Test(.timeLimit(.minutes(3))) func repairingFetchesOnlyFromTheFirstDamagedTensor() async throws {
        let rig = Rig()
        defer { rig.finish() }
        await rig.controller.start()
        await rig.controller.download()
        #expect(await rig.eventually(Self.isReady))
        let allBlocks = rig.behaviour.rangeRequests.count
        // A flipped byte in a tensor late in the file.
        let spec = rig.model.spec
        let victim = spec.outputs[spec.outputs.count * 3 / 4]
        let handle = try FileHandle(forUpdating: rig.store.weightsURL)
        let at = UInt64(spec.headerBytes().count + victim.offset + victim.size / 2)
        try handle.seek(toOffset: at)
        let byte = try handle.read(upToCount: 1)!.first!
        try handle.seek(toOffset: at)
        try handle.write(contentsOf: Data([byte ^ 0xFF]))
        try handle.close()
        await rig.controller.markDamaged()
        #expect(await rig.state() == .damaged)
        #expect(rig.access.availability == .unavailable(LanguageModelAccess.damagedReason))
        let before = rig.behaviour.rangeRequests.count
        await rig.controller.repair()
        #expect(await rig.eventually(Self.isReady))
        let fetched = rig.behaviour.rangeRequests.count - before
        #expect(fetched > 0 && fetched < allBlocks, "only the part from the damaged tensor was fetched again: \(fetched) of \(allBlocks)")
        try LanguageModelVerifier.fullVerify(file: rig.store.weightsURL, spec: spec)
        TestHardware.expectIntegratedModelAvailability(of: rig.access)
    }

    @Test(.timeLimit(.minutes(3))) func aPausedRepairIsStillARepairAfterARelaunchAndDiscardingItDeletesTheModel() async throws {
        let rig = Rig()
        defer { rig.finish() }
        await rig.controller.start()
        await rig.controller.download()
        #expect(await rig.eventually(Self.isReady))
        // A flipped byte in a tensor late in the file, so the repair has something to fetch (and so to wait for the recording to end).
        let spec = rig.model.spec
        let victim = spec.outputs[spec.outputs.count * 3 / 4]
        let handle = try FileHandle(forUpdating: rig.store.weightsURL)
        let at = UInt64(spec.headerBytes().count + victim.offset + victim.size / 2)
        try handle.seek(toOffset: at)
        let byte = try handle.read(upToCount: 1)!.first!
        try handle.seek(toOffset: at)
        try handle.write(contentsOf: Data([byte ^ 0xFF]))
        try handle.close()
        await rig.controller.markDamaged()
        rig.env.set(IndexerEnvironment(isRecording: true))
        await rig.controller.repair()
        // The recording holds the work at its first block (the card says what it is doing meanwhile): stop it there.
        #expect(await rig.eventually { state in
            switch state { case .checkingPartial, .repairing, .pausedForRecording: true; default: false }
        })
        await rig.controller.pause()
        #expect(await rig.eventually(Self.isPartial))
        let pausedSource = await rig.controller.status.source
        #expect(pausedSource == "repair" && rig.store.stagingIsRepair)
        // A relaunch reads the same staging area: the repair marker says what is in it.
        let again = LanguageModelController(store: rig.store, access: LanguageModelAccess(), environment: { IndexerEnvironment() }, log: NetworkActivityLog(),
                                            supported: { nil }, defaults: LanguageModelSchedulingTests.isolatedDefaults(), appBuild: "test", prepare: { _ in })
        await again.start()
        let relaunched = await again.status
        #expect(relaunched.source == "repair" && Self.isPartial(relaunched.state))
        await again.discard()
        let afterDiscard = await again.status.state
        #expect(afterDiscard == .notInstalled && !rig.store.stagingIsRepair)
        if case .installed = rig.store.disk() { Issue.record("the damaged model should be gone") }
    }

    @Test(.timeLimit(.minutes(2))) func deleteWhileDownloadingIgnoresTheLateCallbacks() async throws {
        let rig = Rig(recording: true)
        defer { rig.finish() }
        let removed = Mutex(0)
        await rig.controller.setHooks(LanguageModelHooks(removed: { removed.withLock { $0 += 1 } }))
        await rig.controller.start()
        await rig.controller.download()
        #expect(await rig.eventually(Self.isPaused))
        await rig.controller.delete()
        #expect(await rig.state() == .notInstalled && removed.withLock { $0 } == 1)
        rig.env.set(IndexerEnvironment(isRecording: false))
        try await Task.sleep(for: .milliseconds(150))
        #expect(await rig.state() == .notInstalled, "nothing the old run did changes the state after the delete")
        #expect(rig.behaviour.hits.isEmpty)
    }

    @Test func aMacBelowTheGateIsUnsupportedWithItsReason() async throws {
        let model = SyntheticLanguageModel()
        let fixture = LanguageModelFixture(spec: model.spec)
        defer { fixture.cleanup() }
        let controller = LanguageModelController(store: fixture.store, access: LanguageModelAccess(), environment: { IndexerEnvironment() }, log: NetworkActivityLog(),
                                                 supported: { LanguageModelGate.unsupported(memory: 8 << 30, gpuSupported: true) },
                                                 defaults: LanguageModelSchedulingTests.isolatedDefaults(), appBuild: "test", prepare: { _ in })
        await controller.start()
        #expect(await controller.status.state == .unsupported(.memory(installedGB: 8)))
        await controller.download()
        #expect(await controller.status.state == .unsupported(.memory(installedGB: 8)), "nothing starts on a Mac that does not qualify")
    }

    @Test func theGateIsTypedAndExactlySixteenGibibytesPass() {
        #expect(LanguageModelGate.unsupported(memory: 16 << 30, gpuSupported: true) == nil)
        #expect(LanguageModelGate.unsupported(memory: (16 << 30) - 1, gpuSupported: true) == .memory(installedGB: 16))
        #expect(LanguageModelGate.unsupported(memory: 24 << 30, gpuSupported: false) == .gpu)
        #expect(LanguageModelGate.refusal(memory: 8 << 30, gpuSupported: true) != nil && LanguageModelGate.refusal(memory: 16 << 30, gpuSupported: true) == nil)
    }
}
