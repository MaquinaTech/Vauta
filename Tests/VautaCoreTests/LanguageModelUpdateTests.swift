// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Testing
@testable import VautaCore

@Suite("Language model: update from an earlier conversion")
struct LanguageModelUpdateTests {
    /// The synthetic tower twice: as Vauta converts it now (q, k and v at 8 bits) and as the earlier all-4-bit conversion did.
    struct Env {
        let current = SyntheticLanguageModel()
        let earlier = SyntheticLanguageModel(bits: { _ in 4 })
        let behaviour: LanguageModelStub.Behaviour
        let fixture: LanguageModelFixture
        let downloader: LanguageModelDownloader

        var conversion: LanguageModelSpec.Conversion {
            LanguageModelSpec.Conversion(assembledSize: earlier.spec.assembledSize, headerSize: earlier.spec.headerSize,
                                         headerSHA256: Self.sha(earlier.spec.headerBytes()), assembledSHA256: earlier.spec.assembledSHA256)
        }

        init(_ configure: (LanguageModelStub.Behaviour) -> Void = { _ in }) {
            behaviour = LanguageModelStub.Behaviour(current)
            configure(behaviour)
            LanguageModelStub.register(behaviour)
            var spec = current.spec
            spec.earlier = [LanguageModelSpec.Conversion(assembledSize: earlier.spec.assembledSize, headerSize: earlier.spec.headerSize,
                                                         headerSHA256: Self.sha(earlier.spec.headerBytes()), assembledSHA256: earlier.spec.assembledSHA256)]
            fixture = LanguageModelFixture(spec: spec)
            downloader = LanguageModelDownloader(session: SearchModelDownloader.makeSession(protocolClasses: [LanguageModelStub.self], log: NetworkActivityLog()),
                                                 store: fixture.store, appBuild: "test")
        }

        /// Installs `weights` with a record of `assembledSHA256`, as an earlier build left it.
        func install(_ weights: Data, assembledSHA256: String) throws {
            let store = fixture.store
            try store.prepare()
            try FileManager.default.createDirectory(at: store.installDirectory, withIntermediateDirectories: true)
            try weights.write(to: store.weightsURL)
            try current.tokenizer.write(to: store.tokenizerURL)
            try store.updateRecord(LanguageModelInstallRecord(revision: current.spec.revision, assembledSHA256: assembledSHA256,
                                                              tokenizerSHA256: current.spec.tokenizerSHA256, source: "download", installedAt: Date(), appBuild: "old"))
        }

        func installEarlier() throws { try install(earlier.assembled, assembledSHA256: earlier.spec.assembledSHA256) }
        func finish() { LanguageModelStub.unregister(behaviour); fixture.cleanup() }
        static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

        /// The source tensors whose outputs are at 8 bits now.
        var changed: [LanguageModelSpec.SourceTensor] {
            current.spec.sources.filter { $0.action == .quantize && LanguageModelSpec.bits(forOutputStem: $0.outputStem) == 8 }
        }
    }

    @Test func anEarlierConversionIsRecognisedAndOnlyItsChangedTensorsArePlanned() throws {
        let env = Env()
        defer { env.finish() }
        try env.installEarlier()
        let store = env.fixture.store
        #expect(store.installedEarlierConversion == env.conversion)
        #expect(LanguageModelVerifier.quickCheckInstalled(store))
        try LanguageModelVerifier.fullVerifyInstalled(store)
        // The pinned checks alone refuse the earlier file: it is loaded only as what its record says it is.
        #expect(!LanguageModelVerifier.quickCheck(file: store.weightsURL, spec: store.spec))
        let plan = try #require(LanguageModelUpdate.plan(store))
        #expect(!env.changed.isEmpty && plan.fetches == env.changed)
        #expect(plan.downloadBytes == env.changed.reduce(0) { $0 + $1.size })
        #expect(plan.copies.count + 3 * env.changed.count == store.spec.outputs.count)
    }

    @Test func theUpdateFetchesOnlyTheChangedTensorsAndInstallsThePinnedFile() async throws {
        let env = Env()
        defer { env.finish() }
        try env.installEarlier()
        let store = env.fixture.store
        let plan = try #require(LanguageModelUpdate.plan(store))
        try await env.downloader.update(plan, progress: { _ in })
        guard case .installed(let record) = store.disk() else { Issue.record("not installed"); return }
        #expect(record.assembledSHA256 == env.current.spec.assembledSHA256 && record.source == "update")
        #expect(try Data(contentsOf: store.weightsURL) == env.current.assembled)
        #expect(try Data(contentsOf: store.tokenizerURL) == env.current.tokenizer)
        #expect(store.installedEarlierConversion == nil && LanguageModelUpdate.plan(store) == nil)
        let spec = env.current.spec
        let wanted = env.changed.map { "bytes=\(spec.spanStart + $0.offset)-\(spec.spanStart + $0.offset + $0.size - 1)" }
        #expect(env.behaviour.rangeRequests.sorted() == wanted.sorted(), "only the changed tensors, each once")
        #expect(!FileManager.default.fileExists(atPath: store.stagingDirectory.path))
    }

    @Test func aTensorThatDoesNotMatchTwiceLeavesTheInstallAsItWas() async throws {
        let probe = Env()
        let first = probe.changed[0]
        let block = first.offset / probe.current.spec.blockSize
        probe.finish()
        let env = Env { $0.tamperBlockServings = [block: 2] }
        defer { env.finish() }
        try env.installEarlier()
        let store = env.fixture.store
        let plan = try #require(LanguageModelUpdate.plan(store))
        await #expect(throws: IntegratedModelError.mismatch) { try await env.downloader.update(plan, progress: { _ in }) }
        #expect(try Data(contentsOf: store.weightsURL) == env.earlier.assembled)
        #expect(store.installedEarlierConversion == env.conversion)
        #expect(!FileManager.default.fileExists(atPath: store.stagingDirectory.path))
        // Once is fetched again and goes through.
        let once = Env { $0.tamperBlockServings = [block: 1] }
        defer { once.finish() }
        try once.installEarlier()
        try await once.downloader.update(try #require(LanguageModelUpdate.plan(once.fixture.store)), progress: { _ in })
        #expect(try Data(contentsOf: once.fixture.store.weightsURL) == once.current.assembled)
    }

    @Test func aCurrentOrUnknownInstallOrADamagedEarlierFileHasNoUpdate() throws {
        let env = Env()
        defer { env.finish() }
        try env.install(env.current.assembled, assembledSHA256: env.current.spec.assembledSHA256)
        #expect(env.fixture.store.installedEarlierConversion == nil && LanguageModelUpdate.plan(env.fixture.store) == nil)
        // A record of a conversion this build does not know.
        try env.install(env.earlier.assembled, assembledSHA256: String(repeating: "0", count: 64))
        #expect(LanguageModelUpdate.plan(env.fixture.store) == nil && !LanguageModelVerifier.quickCheckInstalled(env.fixture.store))
        // The earlier file with a changed header byte: its header hash no longer matches.
        var damaged = env.earlier.assembled
        damaged[20] ^= 0x01
        try env.install(damaged, assembledSHA256: env.earlier.spec.assembledSHA256)
        #expect(LanguageModelUpdate.plan(env.fixture.store) == nil && !LanguageModelVerifier.quickCheckInstalled(env.fixture.store))
    }

    @Test func aChangedTensorThatIsDamagedInTheInstalledFileFailsTheCopyAndKeepsTheInstall() async throws {
        let env = Env()
        defer { env.finish() }
        // An unchanged tensor's bytes flipped in the installed file: the copy compares each with its pinned hash.
        var damaged = env.earlier.assembled
        damaged[damaged.count - 3] ^= 0x01
        try env.install(damaged, assembledSHA256: env.earlier.spec.assembledSHA256)
        let store = env.fixture.store
        let plan = try #require(LanguageModelUpdate.plan(store))
        await #expect(throws: IntegratedModelError.mismatch) { try await env.downloader.update(plan, progress: { _ in }) }
        #expect(try Data(contentsOf: store.weightsURL) == damaged)
        #expect(!FileManager.default.fileExists(atPath: store.stagingDirectory.path))
    }

    @Test func theControllerOffersTheUpdateKeepsTheModelInUseAndEndsOnThePinnedFile() async throws {
        let env = Env()
        defer { env.finish() }
        try env.installEarlier()
        let store = env.fixture.store
        let access = LanguageModelAccess()
        let controller = LanguageModelController(store: store, access: access, engine: LanguageModelEngine(store: store, gate: MLXWorkGate()),
                                                 environment: { IndexerEnvironment(isRecording: false) }, log: NetworkActivityLog(),
                                                 protocolClasses: [LanguageModelStub.self], supported: { nil },
                                                 defaults: UserDefaults(suiteName: "lm-update-\(UUID().uuidString)")!, appBuild: "test",
                                                 pollInterval: .milliseconds(10), prepare: { _ in })
        await controller.start()
        let offered = await controller.status
        #expect(offered.state == .ready && offered.updateBytes == LanguageModelUpdate.plan(store)?.downloadBytes && offered.updateBytes != nil)
        await controller.update()
        let done = await LanguageModelSchedulingTests.eventually {
            let s = await controller.status
            return s.state == .ready && s.updateBytes == nil && s.source == "update"
        }
        #expect(done)
        guard case .installed(let record) = store.disk() else { Issue.record("not installed"); return }
        #expect(record.assembledSHA256 == env.current.spec.assembledSHA256)
        // Started again on the updated install: nothing to offer.
        await controller.start()
        #expect(await controller.status.updateBytes == nil)
    }
}
