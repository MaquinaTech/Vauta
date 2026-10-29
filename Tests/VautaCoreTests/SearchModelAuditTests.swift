// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The search model touches the network only through the audited session, only on a click, and only MLX's own target imports MLX.
@Suite("Search model: audit and dependencies")
struct SearchModelAuditTests {
    @Test func theNewPurposeIsFrozen() {
        #expect(NetworkPurpose.modelDownload.rawValue == "modelDownload")
        #expect(NetworkPurpose.allCases.contains(.modelDownload))
        // Every raw value that was written to an exported file before stays.
        let frozen = ["minutes", "liveNotes", "notes", "ask", "embeddings", "documents", "translation", "discovery", "connectionTest", "statusCheck", "other"]
        #expect(Set(frozen).isSubset(of: Set(NetworkPurpose.allCases.map(\.rawValue))))
    }

    @Test func aModelDownloadIsADownloadTheNetworkActivityDoesNotCallOutsideTheNetwork() async throws {
        let log = NetworkActivityLog()
        let id = await log.begin(purpose: .modelDownload, url: URL(string: "https://huggingface.co/google/embeddinggemma-2/resolve/x/model.safetensors")!, method: "GET", bytesSent: 0)
        await log.finish(id, status: 302, error: nil, bytesReceived: 0, duration: 0.1)
        var entries = await log.snapshot()
        #expect(entries[0].scope == .download && entries[0].isSuccess && !entries[0].isFailure, "the 302 is the answer asked for")
        #expect(NetworkDestination.summarize(entries).first?.scope == .download)
        // The same host reached for another purpose is outside.
        let other = await log.begin(purpose: .other, url: URL(string: "https://huggingface.co/x")!, method: "GET", bytesSent: 0)
        await log.finish(other, status: 200, error: nil, bytesReceived: 5, duration: 0.1)
        entries = await log.snapshot()
        #expect(entries[1].scope == .outside)
        #expect(NetworkDestination.summarize(entries).first?.scope == .outside, "one request that is not a download makes it what its address says")
        // Local destinations are unchanged.
        let local = await log.begin(purpose: .minutes, url: URL(string: "http://127.0.0.1:1234/v1/models")!, method: "GET", bytesSent: 0)
        await log.finish(local, status: 200, error: nil, bytesReceived: 5, duration: 0.1)
        #expect(await log.snapshot()[2].scope == .thisMac)
        let json = String(decoding: try await log.exportJSON(), as: UTF8.self)
        #expect(json.contains("\"modelDownload\"") && json.contains("\"outside\""))
    }

    @Test func onlyTheMLXTargetImportsMLX() async throws {
        let problems = try await offPool { () -> [String] in
            var out: [String] = []
            for (path, text) in try NetworkAuditSourceScanTests.sourceFiles() where !path.hasPrefix("Sources/VautaMLX/") {
                let code = NetworkAuditSourceScanTests.code(text)
                if code.range(of: #"(?m)^\s*(@\w+\s+)?((public|internal|package|private|fileprivate)\s+)?import\s+(MLX\w*|Cmlx)\b"#, options: .regularExpression) != nil {
                    out.append(path)
                }
            }
            return out
        }
        #expect(problems.isEmpty, "Only Sources/VautaMLX may import MLX: \(problems)")
    }

    @Test func theMLXTargetIsSeenByTheScan() async throws {
        let found = try await offPool { () -> Bool in
            try NetworkAuditSourceScanTests.sourceFiles().contains { $0.path.hasPrefix("Sources/VautaMLX/") && $0.text.contains("import MLX") }
        }
        #expect(found, "the scan must see the files it is meant to confine")
    }

    @Test func theDownloaderAndTheOtherSearchModelFilesNeverOpenAConnection() async throws {
        let problems = try await offPool { () -> [String] in
            try NetworkAuditSourceScanTests.sourceFiles().filter { $0.path.contains("/SearchModel/") || $0.path.hasPrefix("Sources/VautaMLX/") }
                .flatMap { file in NetworkAuditSourceScanTests.violations(in: file.text, at: file.path).map { "\(file.path): \($0)" } }
        }
        #expect(problems.isEmpty, "\(problems)")
    }

    @Test func packageResolvedHasExactlyTheForkAndSwiftNumerics() throws {
        let root = NetworkAuditSourceScanTests.packageRoot()
        let data = try Data(contentsOf: root.appending(path: "Package.resolved"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pins = try #require(json["pins"] as? [[String: Any]])
        var found: [String: String] = [:]
        for pin in pins {
            guard let location = pin["location"] as? String, let state = pin["state"] as? [String: Any], let revision = state["revision"] as? String else { continue }
            found[location] = revision
        }
        #expect(found == ["https://github.com/MaquinaTech/mlx-swift.git": "999f159e905affa3cc25bc1127a6cb489a5ffbb9",
                          "https://github.com/apple/swift-numerics": "0c0290ff6b24942dadb83a929ffaaa1481df04a2"])
        let manifest = try String(contentsOf: root.appending(path: "Package.swift"), encoding: .utf8)
        #expect(manifest.components(separatedBy: ".package(").count == 2, "one package")
        #expect(manifest.contains("revision: \"999f159e905affa3cc25bc1127a6cb489a5ffbb9\""), "pinned by revision, never by version or branch")
        #expect(!manifest.contains("branch:") && !manifest.contains("from:") && !manifest.contains("exact:"))
    }

    @Test func theModelsFolderIsOutsideTheStoreDirectoryAndBackupsHoldNoModelFiles() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-support-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let models = SearchModelStore(applicationSupport: base)
        let storeDirectory = MeetingStore.locateDirectory(under: base)
        #expect(!models.root.path.hasPrefix(storeDirectory.path + "/") && models.root != storeDirectory)
        try models.prepare()
        try Data(count: 10).write(to: models.modelParent.appendingPathComponent("sentinel"))
        // A backup is the store's own database image: it cannot contain a file that is not in it.
        let fx = StoreFixture()
        let store = try fx.open()
        let backup = try await store.createBackup(password: "correct horse battery staple", appVersion: "0.9.0")
        #expect(backup.range(of: Data("sentinel".utf8)) == nil && backup.range(of: Data("Vauta Models".utf8)) == nil)
        #expect(models.isExcludedFromBackup)
    }
}

@Suite("Search model: nothing happens without a click")
struct SearchModelLaunchTests {
    private static func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "vauta.tests.\(UUID().uuidString)")! }

    private func controller(_ fixture: ModelFixture, log: NetworkActivityLog, access: SearchModelAccess = SearchModelAccess(),
                            supported: Bool = true, model: SyntheticModel? = nil) -> SearchModelController {
        let log2 = FakeEncoderLog()
        let factory = SearchEncoderFactory { _, fp32 in FakeEncoder(fp32: fp32, log: log2) }
        let engine = SearchModelEngine(store: fixture.store, factory: factory, appBuild: "test", gate: MLXWorkGate())
        return SearchModelController(store: fixture.store, engine: engine, access: access,
                                     defaults: Self.freshDefaults(), log: log,
                                     protocolClasses: [ModelStub.self], supported: { supported }, appBuild: "test")
    }

    @Test func startingWithNoModelWithAPartialDownloadOrWithAReadyModelMakesNoRequest() async throws {
        let model = SyntheticModel(tokenizerData: Data(TinyTokenizer.json.utf8))
        // No model.
        let empty = ModelFixture(spec: model.spec)
        defer { empty.cleanup() }
        let log = NetworkActivityLog()
        let a = controller(empty, log: log)
        await a.start()
        #expect(await a.status.state == .notInstalled)
        // A partial download.
        let partial = ModelFixture(spec: model.spec)
        defer { partial.cleanup() }
        try partial.store.createStaging()
        try Data(count: 10).write(to: partial.store.stagedWeightsPart)
        let b = controller(partial, log: log)
        await b.start()
        guard case .partial = await b.status.state else { Issue.record("expected partial"); return }
        // A ready model.
        let ready = ModelFixture(spec: model.spec)
        defer { ready.cleanup() }
        try ready.store.createStaging()
        try model.assembled.write(to: ready.store.stagedWeights)
        try model.tokenizer.write(to: ready.store.stagedTokenizer)
        try ready.store.install(SearchModelInstallRecord(revision: model.spec.revision, assembledSHA256: model.spec.assembledSHA256,
                                                         tokenizerSHA256: model.spec.tokenizerSHA256, source: "download", installedAt: Date(), appBuild: "x"))
        let access = SearchModelAccess()
        let c = controller(ready, log: log, access: access)
        await c.start()
        #expect(access.availability == .installed && access.model != nil)
        // The model loads in the background (preparing, then ready); none of it is network.
        let controller = c
        #expect(await eventually { await controller.status.state == .ready })
        #expect(await log.snapshot().isEmpty, "zero entries at launch")
    }

    @Test func aMacWithoutAGPUIsUnsupportedAndKeepsKeywordSearch() async throws {
        let model = SyntheticModel()
        let fixture = ModelFixture(spec: model.spec)
        defer { fixture.cleanup() }
        let access = SearchModelAccess()
        let c = controller(fixture, log: NetworkActivityLog(), access: access, supported: false)
        await c.start()
        #expect(await c.status.state == .unsupported(.unsupportedHardware))
        #expect(access.availability == .unavailable(.unsupportedHardware) && access.model == nil)
        await c.download()
        #expect(await c.status.state == .unsupported(.unsupportedHardware), "no download starts")
    }

    @Test func aBrokenInstallIsReportedWithoutLoadingIt() async throws {
        let model = SyntheticModel(tokenizerData: Data(TinyTokenizer.json.utf8))
        let fixture = ModelFixture(spec: model.spec)
        defer { fixture.cleanup() }
        try fixture.store.createStaging()
        try model.assembled.dropLast(3).write(to: fixture.store.stagedWeights)
        try model.tokenizer.write(to: fixture.store.stagedTokenizer)
        try fixture.store.install(SearchModelInstallRecord(revision: model.spec.revision, assembledSHA256: "x", tokenizerSHA256: "y", source: "download",
                                                           installedAt: Date(), appBuild: "x"))
        let access = SearchModelAccess()
        let c = controller(fixture, log: NetworkActivityLog(), access: access)
        await c.start()
        #expect(await c.status.state == .damaged && access.availability == .unavailable(.verificationFailed))
    }
}
