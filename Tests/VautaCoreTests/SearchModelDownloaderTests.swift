// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The download of the search model against a stand-in for Hugging Face and its CDN (`ModelStub`): no socket is opened, and a
/// synthetic three-block model replaces the real one.
@Suite("Search model: download")
struct SearchModelDownloaderTests {
    struct Env {
        let model = SyntheticModel()
        let behaviour: ModelStub.Behaviour
        let fixture: ModelFixture
        let log = NetworkActivityLog()
        let downloader: SearchModelDownloader

        init(_ configure: (ModelStub.Behaviour) -> Void = { _ in }) {
            behaviour = ModelStub.Behaviour(model)
            configure(behaviour)
            ModelStub.register(behaviour)
            fixture = ModelFixture(spec: model.spec)
            let session = SearchModelDownloader.makeSession(protocolClasses: [ModelStub.self], log: log)
            downloader = SearchModelDownloader(session: session, store: fixture.store, appBuild: "test")
        }

        func run(tokenizerOnly: Bool = false) async throws {
            try await downloader.run(tokenizerOnly: tokenizerOnly, progress: { _ in })
        }

        func finish() {
            ModelStub.unregister(behaviour)
            fixture.cleanup()
        }

        func entries() async -> [NetworkActivityEntry] { await log.snapshot() }
    }

    @Test func aFreshDownloadResolvesThenFetchesEveryBlockAndInstalls() async throws {
        let env = Env()
        defer { env.finish() }
        try await env.run()
        let store = env.fixture.store
        guard case .installed(let record) = store.disk() else { Issue.record("not installed"); return }
        #expect(record.revision == env.model.spec.revision && record.source == "download" && record.assembledSHA256 == env.model.spec.assembledSHA256)
        #expect(try Data(contentsOf: store.weightsURL) == env.model.assembled)
        #expect(try Data(contentsOf: store.tokenizerURL) == env.model.tokenizer)
        #expect(!FileManager.default.fileExists(atPath: store.stagingDirectory.path), "the staging folder became the install")
        // 302 + CDN GET for the tokenizer, 302 for the weights (cached CDN address afterwards) and one Range per block.
        let hits = env.behaviour.hits
        #expect(hits.filter { $0.host == "huggingface.co" }.count == 2)
        #expect(env.behaviour.rangeRequests == ["bytes=100-1099", "bytes=1100-2099", "bytes=2100-2599"])
        #expect(store.isExcludedFromBackup && FileManager.default.fileExists(atPath: store.root.appendingPathComponent(".metadata_never_index").path))
    }

    @Test func theNetworkActivityListsTheDownloadWithHostsAndPathsOnly() async throws {
        let env = Env()
        defer { env.finish() }
        try await env.run()
        let entries = await env.entries()
        #expect(!entries.isEmpty && entries.allSatisfy { $0.purpose == .modelDownload && $0.method == "GET" })
        #expect(entries.filter { $0.host == "huggingface.co" }.allSatisfy { $0.status == 302 })
        #expect(entries.filter { $0.host == "us.aws.cdn.hf.co" && $0.status == 206 }.count == 3)
        let dump = "\(entries)" + String(decoding: try await env.log.exportJSON(), as: UTF8.self)
        #expect(!dump.contains("SECRETSIGNATURE") && !dump.contains("X-Amz") && !dump.contains("Expires"), "the signed query never reaches the log")
        #expect(dump.contains("\"modelDownload\""))
        #expect(entries.allSatisfy { $0.bytesSent == 0 })
    }

    @Test func aStatus200ForARangeRequestIsRefusedBeforeItsBodyIsRead() async throws {
        let env = Env { $0.rangeStatus = 200 }
        defer { env.finish() }
        await #expect(throws: SearchModelError.unexpectedResponse) { try await env.run() }
        let partial = try Data(contentsOf: env.fixture.store.stagedWeightsPart)
        #expect(partial == env.model.spec.headerBytes(), "no body byte was written")
        #expect(env.fixture.store.disk() == .partial)
    }

    @Test func everyRequestAsksForTheStoredBytesAndACompressedAnswerIsRefused() async throws {
        let env = Env()
        defer { env.finish() }
        try await env.run()
        #expect(env.behaviour.hits.allSatisfy { $0.acceptEncoding == "identity" }, "no request leaves it to URLSession's gzip/br default")
        #expect(env.behaviour.hits.allSatisfy { $0.userAgent == "Vauta" }, "the app's name only, not the build or the system's versions")

        let compressed = Env { $0.contentEncoding = "gzip" }
        defer { compressed.finish() }
        await #expect(throws: SearchModelError.unexpectedResponse) { try await compressed.run() }
    }

    @Test func aWrongContentRangeIsRefused() async throws {
        for variant in 0..<3 {
            let env = Env {
                $0.contentRange = { from, to, total in
                    switch variant {
                    case 0: "bytes \(from + 1)-\(to)/\(total)"      // the start
                    case 1: "bytes \(from)-\(to - 1)/\(total)"      // the end
                    default: "bytes \(from)-\(to)/\(total + 1)"      // the total
                    }
                }
            }
            defer { env.finish() }
            await #expect(throws: SearchModelError.unexpectedResponse) { try await env.run() }
        }
    }

    @Test func aShortBodyIsRefused() async throws {
        let env = Env { $0.shortBodyBy = 10 }
        defer { env.finish() }
        await #expect(throws: SearchModelError.unexpectedResponse) { try await env.run() }
        #expect(env.fixture.store.disk() == .partial)
    }

    @Test func aBlockThatDoesNotMatchIsFetchedOnceMoreThenTheDownloadIsDiscarded() async throws {
        let once = Env { $0.tamperBlockServings = [1: 1] }
        defer { once.finish() }
        try await once.run()   // one retry fixes a transient corruption
        #expect(once.behaviour.rangeRequests.count == 4)
        guard case .installed = once.fixture.store.disk() else { Issue.record("not installed"); return }

        let twice = Env { $0.tamperBlockServings = [1: 2] }
        defer { twice.finish() }
        await #expect(throws: SearchModelError.mismatch) { try await twice.run() }
        #expect(!FileManager.default.fileExists(atPath: twice.fixture.store.stagedWeightsPart.path), "the partial file is deleted")
        #expect(twice.behaviour.rangeRequests.count == 3, "block 0, then block 1 twice")
    }

    @Test func aTamperedPinnedTensorOrAssembledHashDeletesThePartialFile() async throws {
        var model = SyntheticModel()
        model.spec.tensors[1] = .init(name: "t1", dtype: "F16", shape: [500], offset: 1000, size: 1000, sha256: String(repeating: "0", count: 64))
        let behaviour = ModelStub.Behaviour(model)
        ModelStub.register(behaviour)
        let fixture = ModelFixture(spec: model.spec)
        defer { ModelStub.unregister(behaviour); fixture.cleanup() }
        let session = SearchModelDownloader.makeSession(protocolClasses: [ModelStub.self], log: NetworkActivityLog())
        let downloader = SearchModelDownloader(session: session, store: fixture.store, appBuild: "test")
        await #expect(throws: SearchModelError.mismatch) { try await downloader.run(progress: { _ in }) }
        #expect(!FileManager.default.fileExists(atPath: fixture.store.stagedWeightsPart.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.store.stagedWeights.path))
        #expect(fixture.store.disk() != .empty, "the verified tokenizer may stay for the next try")
    }

    @Test func aDownloadThatStoppedAfterTheFirstBlockResumesWithTheRestOnly() async throws {
        let env = Env { $0.failRangeRequestsAfter = 1 }
        defer { env.finish() }
        await #expect(throws: SearchModelError.offline) { try await env.run() }
        #expect(env.behaviour.rangeRequests.count == 2, "block 0 served, block 1 failed")
        #expect(env.fixture.store.disk() == .partial)
        // The same files, with the network back.
        env.behaviour.failRangeRequestsAfter = nil
        let before = env.behaviour.rangeRequests.count
        try await env.run()
        #expect(Array(env.behaviour.rangeRequests.dropFirst(before)) == ["bytes=1100-2099", "bytes=2100-2599"], "only blocks 2 and 3")
        guard case .installed = env.fixture.store.disk() else { Issue.record("not installed"); return }
    }

    @Test func cancellingKeepsTheVerifiedPrefix() async throws {
        // The second block's connection stalls, so the download is always in flight when it is cancelled.
        let env = Env { $0.stallRangeRequestsFrom = 1 }
        defer { env.finish() }
        let task = Task { try await env.run() }
        // Wait until the first block arrived and the second was asked for, then cancel.
        let part = env.fixture.store.stagedWeightsPart
        for _ in 0..<48_000 where env.behaviour.rangeRequests.count < 2 || !FileManager.default.fileExists(atPath: part.path) {
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        guard case .failure(let failure) = await task.result, failure is CancellationError else { Issue.record("expected the cancellation"); return }
        let partial = env.fixture.store.stagedWeightsPart
        let good = try SearchModelDownloader.resume(part: partial, spec: env.model.spec)
        #expect(good >= 1, "the blocks that were verified stay")
        #expect(env.fixture.store.disk() == .partial)
    }

    @Test func anExpiredSignedAddressIsResolvedAgainOnce() async throws {
        let once = Env { $0.forbiddenFirstCDNRequests = 1 }
        defer { once.finish() }
        try await once.run()
        #expect(once.behaviour.count(host: "huggingface.co") >= 3, "the tokenizer was looked up again")

        let twice = Env { $0.forbiddenFirstCDNRequests = 5 }
        defer { twice.finish() }
        await #expect(throws: SearchModelError.offline) { try await twice.run() }
    }

    @Test func eachBlockMayRenewAnExpiredAddressOnceAndOnlyThenResolvesAgain() async throws {
        // CDN request 0 is the tokenizer; 1 is block 0 and 4 is block 2 (after block 1 at request 3): two expiries far apart.
        let env = Env { $0.forbidCDNRequestNumbers = [1, 4] }
        defer { env.finish() }
        try await env.run()
        guard case .installed = env.fixture.store.disk() else { Issue.record("not installed"); return }
        // Tokenizer + weights + one lookup per expiry: later blocks reuse the address they have.
        #expect(env.behaviour.hits.filter { $0.host == "huggingface.co" }.count == 4)
    }

    @Test func aRedirectToAnotherHostIsBlockedAndNothingIsSentThere() async throws {
        let env = Env { $0.cdnHost = "evil.example" }
        defer { env.finish() }
        await #expect(throws: SearchModelError.hostNotAllowed) { try await env.run() }
        #expect(env.behaviour.count(host: "evil.example") == 0, "the stub saw no request for that host")
        let entries = await env.entries()
        let blocked = entries.filter { $0.blocked != nil }
        #expect(blocked.count == 1 && blocked[0].host == "evil.example" && blocked[0].purpose == .modelDownload && blocked[0].blocked == .destinationNotAllowed)
        #expect(!"\(entries)".contains("SECRETSIGNATURE"))
    }

    @Test func provenanceHeadersThatDisagreeFailTheDownload() async throws {
        let commit = Env { $0.repoCommit = "ffffffffffffffffffffffffffffffffffffffff" }
        defer { commit.finish() }
        await #expect(throws: SearchModelError.mismatch) { try await commit.run() }
        let etag = Env { $0.linkedEtag = String(repeating: "a", count: 64) }
        defer { etag.finish() }
        await #expect(throws: SearchModelError.mismatch) { try await etag.run() }
    }

    @Test func aRevisionThatIsGoneIsReported() async throws {
        let env = Env { $0.resolveStatus = 404 }
        defer { env.finish() }
        await #expect(throws: SearchModelError.revisionGone) { try await env.run() }
    }

    @Test func aPathThatIsNotOneOfTheTwoPinnedFilesIsRefusedBeforeSending() async throws {
        let spec = SyntheticModel().spec
        let ok = URL(string: "https://huggingface.co\(spec.resolvePath("model.safetensors"))")!
        #expect(SearchModelDestinations.isAllowedResolve(ok, spec: spec))
        for bad in ["https://huggingface.co/\(spec.repository)/resolve/main/model.safetensors",
                    "https://huggingface.co\(spec.resolvePath("model.safetensors"))/../other",
                    "https://huggingface.co\(spec.resolvePath("config.json"))",
                    "http://huggingface.co\(spec.resolvePath("model.safetensors"))",
                    "https://hf.co\(spec.resolvePath("model.safetensors"))",
                    "https://huggingface.co:8443\(spec.resolvePath("model.safetensors"))",
                    "https://user@huggingface.co\(spec.resolvePath("model.safetensors"))"] {
            #expect(!SearchModelDestinations.isAllowedResolve(URL(string: bad)!, spec: spec), "\(bad)")
        }
        #expect(SearchModelDestinations.isAllowedCDN(URL(string: "https://us.aws.cdn.hf.co/xet-bridge-us/abc/def?sig=1")!))
        for bad in ["http://us.aws.cdn.hf.co/x", "https://cdn.hf.co/x", "https://evil.us.aws.cdn.hf.co/x", "https://us.aws.cdn.hf.co.evil.example/x",
                    "https://us.aws.cdn.hf.co:444/x", "https://user:pw@us.aws.cdn.hf.co/x", "https://huggingface.co/x", "https://us.aws.cdn.hf.co"] {
            #expect(!SearchModelDestinations.isAllowedCDN(URL(string: bad)!), "\(bad)")
        }
    }

    @Test func theAllowlistIsExactlyTheHostsVerifiedSoFar() {
        // Adding a host is a deliberate change: resolve both files from other regions first (docs/RELEASING.md).
        #expect(SearchModelDestinations.allowedCDNHosts == ["us.aws.cdn.hf.co"])
        #expect(SearchModelDestinations.host == "huggingface.co")
    }

    @Test func runningOutOfSpaceWhileWritingReportsWhatIsStillMissing() {
        let spec = SearchModelSpec.pinned
        let whole = SearchModelDownloader.stillNeeded(spec: spec, stagedBytes: 0)
        #expect(whole == spec.downloadSize + SearchModelDownloader.headroom)
        let half = SearchModelDownloader.stillNeeded(spec: spec, stagedBytes: spec.downloadSize / 2)
        #expect(half < whole && half > SearchModelDownloader.headroom - 1)
        #expect(SearchModelDownloader.stillNeeded(spec: spec, stagedBytes: spec.downloadSize * 3) == SearchModelDownloader.headroom, "never zero")
    }

    @Test func notEnoughFreeSpaceFailsBeforeAnyRequest() async throws {
        let env = Env()
        defer { env.finish() }
        // The pinned check needs the download plus 256 MB; a spec that claims 100 TB cannot fit.
        var huge = env.model.spec
        huge.tokenizerSize = 100_000_000_000_000
        let downloader = SearchModelDownloader(session: SearchModelDownloader.makeSession(protocolClasses: [ModelStub.self], log: env.log),
                                               store: SearchModelStore(root: env.fixture.store.root, spec: huge), appBuild: "test")
        do { try await downloader.run(progress: { _ in }); Issue.record("expected diskFull") } catch let error as SearchModelError {
            guard case .diskFull = error else { Issue.record("\(error)"); return }
        }
        let entries = await env.entries()
        #expect(env.behaviour.hits.isEmpty && entries.isEmpty)
    }

    @Test func resumingOnlyNeedsSpaceForWhatIsMissing() async throws {
        let env = Env()
        defer { env.finish() }
        guard let free = env.fixture.store.availableCapacity(), free > 4 * SearchModelDownloader.headroom else { return }
        // A model as big as the free space does not fit from scratch, but with half of it already staged it does.
        var big = env.model.spec
        big.tokenizerSize = free
        let store = SearchModelStore(root: env.fixture.store.root, spec: big)
        let downloader = SearchModelDownloader(session: SearchModelDownloader.makeSession(protocolClasses: [ModelStub.self], log: env.log), store: store, appBuild: "test")
        await #expect(throws: SearchModelError.self) { try await downloader.preflight() }
        try store.createStaging()
        let handle = try FileHandle(forWritingTo: { FileManager.default.createFile(atPath: store.stagedWeights.path, contents: nil); return store.stagedWeights }())
        try handle.truncate(atOffset: UInt64(free / 2))
        try handle.close()
        try await downloader.preflight()
    }

    @Test func theTokenizerAloneCanBeFetchedAfterAnImport() async throws {
        let env = Env()
        defer { env.finish() }
        // The verified weights are already staged (an import without the tokenizer).
        try env.fixture.store.createStaging()
        try env.model.assembled.write(to: env.fixture.store.stagedWeights)
        try await env.run(tokenizerOnly: true)
        guard case .installed = env.fixture.store.disk() else { Issue.record("not installed"); return }
        #expect(env.behaviour.rangeRequests.isEmpty, "no weights were requested")
    }
}
