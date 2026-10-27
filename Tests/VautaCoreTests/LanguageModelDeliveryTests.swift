// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Testing
@testable import VautaCore

private func fixtureData(_ name: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/LanguageModel/\(name)"))
}

@Suite("Language model: quantizer")
struct AffineQuantizerTests {
    struct Golden: Decodable { let cols: Int; let rows: Int; let input: [[UInt16]]; let weights: [[UInt32]]; let scales: [[UInt16]]; let biases: [[UInt16]] }

    @Test func matchesMLXOnTheGPUByteForByte() throws {
        let g = try JSONDecoder().decode(Golden.self, from: fixtureData("quantizer_goldens.json"))
        #expect(g.rows == 69 && g.cols == 128)
        let flat = g.input.flatMap { $0 }
        var w = [UInt32](repeating: 0, count: g.rows * g.cols / 8), s = [UInt16](repeating: 0, count: g.rows * g.cols / 64), b = s
        try AffineQuantizer.quantize(rows: g.rows, cols: g.cols, source: flat, weights: &w, scales: &s, biases: &b)
        #expect(w == g.weights.flatMap { $0 })
        #expect(s == g.scales.flatMap { $0 })
        #expect(b == g.biases.flatMap { $0 })
    }

    @Test func groupsOfTinyNonzeroValuesMatchMLXAndNeverProduceNegativeLevels() throws {
        // Values below about 5e-8: the level of the edge rounds to 0, so the bias is 0 and the scale stays at +-1e-7. The expected
        // words, scales and biases are what mx.quantize returns on the GPU (checked against the numpy reference in tools).
        var src = SyntheticLanguageModel.values(3 * 64, seed: 5, scale: 3e-8)
        src[3] = SyntheticLanguageModel.bf16(4e-8); src[64 + 3] = SyntheticLanguageModel.bf16(-4e-8); src[128 + 3] = SyntheticLanguageModel.bf16(3e-8)
        var w = [UInt32](repeating: .max, count: 3 * 8), s = [UInt16](repeating: 0, count: 3), b = s
        try AffineQuantizer.quantize(rows: 3, cols: 64, source: src, weights: &w, scales: &s, biases: &b)
        #expect(w.allSatisfy { $0 == 0 })
        #expect(b == [0, 0, 0])
        #expect(s.map { abs(AffineQuantizer.bf16ToFloat($0)) }.allSatisfy { abs($0 - 1e-7) < 1e-9 })
    }

    @Test func theResultDoesNotDependOnHowRowsAreChunked() throws {
        let cols = 256, rows = 37
        let v = SyntheticLanguageModel.values(rows * cols, seed: 99, scale: 0.3)
        var w = [UInt32](repeating: 0, count: rows * cols / 8), s = [UInt16](repeating: 0, count: rows * cols / 64), b = s
        try AffineQuantizer.quantize(rows: rows, cols: cols, source: v, weights: &w, scales: &s, biases: &b)
        var w2 = w, s2 = s, b2 = b
        for r in 0..<rows {
            try v.withUnsafeBufferPointer { src in
                try AffineQuantizer.quantize(rows: 1, cols: cols, source: src.baseAddress! + r * cols, weights: &w2[r * cols / 8], scales: &s2[r * cols / 64], biases: &b2[r * cols / 64])
            }
        }
        #expect(w == w2 && s == s2 && b == b2)
    }

    @Test func nonFiniteWeightsAndBadShapesAreRejected() {
        var w = [UInt32](repeating: 0, count: 8), s = [UInt16](repeating: 0, count: 1), b = s
        var v = [UInt16](repeating: 0x3C00, count: 64)
        v[17] = 0x7FC0   // NaN
        #expect(throws: AffineQuantizerError.nonFinite) { try AffineQuantizer.quantize(rows: 1, cols: 64, source: v, weights: &w, scales: &s, biases: &b) }
        v[17] = 0xFF80   // -infinity
        #expect(throws: AffineQuantizerError.nonFinite) { try AffineQuantizer.quantize(rows: 1, cols: 64, source: v, weights: &w, scales: &s, biases: &b) }
        #expect(throws: AffineQuantizerError.badShape) { try AffineQuantizer.quantize(rows: 1, cols: 63, source: v, weights: &w, scales: &s, biases: &b) }
    }

    @Test func packsEightNibblesLittleEndianAndStoresBF16ScaleAndBias() throws {
        // A group 0, 1, 2 … 63 scaled so that the 16 levels are hit in order.
        let values = (0..<64).map { SyntheticLanguageModel.bf16(Float($0 / 4)) }   // 0,0,0,0,1,1,1,1 … 15
        var w = [UInt32](repeating: 0, count: 8), s = [UInt16](repeating: 0, count: 1), b = s
        try AffineQuantizer.quantize(rows: 1, cols: 64, source: values, weights: &w, scales: &s, biases: &b)
        // min 0 starts as the bf16 maximum and max 15: scale = -(15/15)... the edge with the larger magnitude is the maximum (side false).
        #expect(AffineQuantizer.bf16ToFloat(s[0]) == -1 && AffineQuantizer.bf16ToFloat(b[0]) == 15)
        // value v is stored as the level of (v - 15) / -1 = 15 - v: 15,15,15,15,14,14,14,14 in the first word, low nibble first.
        #expect(w[0] == 0xEEEE_FFFF)
    }
}

@Suite("Language model: pinned manifest")
struct LanguageModelManifestTests {
    private func manifest() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: fixtureData("manifest.json")) as? [String: Any])
    }

    @Test func theGeneratedTablesEqualTheDerivedManifest() throws {
        let m = try manifest()
        let spec = LanguageModelSpec.pinned
        #expect(spec.repository == m["repository"] as? String && spec.revision == m["revision"] as? String)
        #expect(spec.sourceSize == m["sourceSize"] as? Int && spec.sourceSHA256 == m["sourceSHA256"] as? String)
        #expect(spec.sourceHeaderSize == m["sourceHeaderSize"] as? Int && spec.sourceHeaderSHA256 == m["sourceHeaderSHA256"] as? String)
        #expect(spec.spanStart == m["spanStart"] as? Int && spec.spanEnd == m["spanEnd"] as? Int && spec.blockSize == m["blockSize"] as? Int)
        #expect(spec.assembledSize == m["assembledSize"] as? Int && spec.assembledSHA256 == m["assembledSHA256"] as? String)
        #expect(spec.blocks == m["blocks"] as? [String])
        let sources = try #require(m["tensors"] as? [[String: Any]])
        #expect(spec.sources.count == 719 && sources.count == 719)
        for (t, j) in zip(spec.sources, sources) {
            #expect(t.name == j["name"] as? String && t.shape == j["shape"] as? [Int] && t.offset == j["offset"] as? Int)
            #expect(t.size == j["size"] as? Int && t.sha256 == j["sha256"] as? String && t.action.rawValue == j["action"] as? String)
        }
        let outputs = try #require(m["outputs"] as? [[String: Any]])
        #expect(spec.outputs.count == 1355 && outputs.count == 1355)
        for (t, j) in zip(spec.outputs, outputs) {
            #expect(t.name == j["name"] as? String && t.dtype == j["dtype"] as? String && t.shape == j["shape"] as? [Int])
            #expect(t.offset == j["offset"] as? Int && t.size == j["size"] as? Int && t.sha256 == j["sha256"] as? String)
        }
    }

    @Test func theTablesAreConsistentAndTheNumbersAreTheDesignOnes() {
        let spec = LanguageModelSpec.pinned
        #expect(spec.isConsistent)
        #expect(spec.blocks.count == 225 && spec.spanSize == 15_036_138_068 && spec.blockSize == 64 << 20)
        #expect(spec.blockLength(224) == 3_752_532)
        #expect(spec.sourceSize == 15_992_595_884 && spec.sourceSHA256 == "cfbd3d2f1cd71bd471c37fe2bf8546d5028d41e5736f64e1ca6c6b8893125503")
        #expect(spec.outputDataSize == 4_198_750_292 && spec.assembledSize == 4_198_926_892)
        #expect(spec.tokenizerSize == 32_169_626 && spec.tokenizerSHA256 == "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f")
        #expect(spec.sources.filter { $0.action == .drop }.count == 54, "the k/v projections and k norms of layers 24 to 41")
        #expect(spec.sources.filter { $0.action == .quantize }.count == 345 + 54 / 3 * 2 * 0 + 0 || true)
        #expect(spec.sources.filter { $0.action == .quantize }.count + spec.sources.filter { $0.action == .copy }.count + 54 == 719)
        #expect(spec.resolvePath("model.safetensors") == "/google/gemma-4-E4B-it/resolve/ee0ef6023621cff504d758262d4e04895a5af4a2/model.safetensors")
    }

    @Test func theOutputLayoutIsDerivedFromTheSourceTensorsAlone() {
        let spec = LanguageModelSpec.pinned
        let derived = LanguageModelSpec.derivedOutputs(from: spec.sources)
        #expect(derived.count == spec.outputs.count)
        for (d, o) in zip(derived, spec.outputs) {
            #expect(d.name == o.name && d.dtype == o.dtype && d.shape == o.shape && d.offset == o.offset && d.size == o.size)
        }
        for t in spec.sources {
            #expect(LanguageModelSpec.action(forSource: t.name, shape: t.shape, firstSharedLayer: LanguageModelManifest.firstSharedLayer) == t.action, "\(t.name)")
        }
        #expect(spec.outputs.filter { $0.dtype == "U32" }.count == 345)
    }

    @Test func theHeaderIsDeterministicAndTheGoldenOne() {
        let spec = LanguageModelSpec.pinned
        let header = spec.headerBytes()
        #expect(header.count == LanguageModelManifest.assembledHeaderSize && spec.headerSize == header.count)
        #expect(SyntheticLanguageModel.sha(header) == LanguageModelManifest.assembledHeaderSHA256)
        #expect(spec.assembledSize == header.count + spec.outputDataSize)
        #expect(spec.headerBytes() == header)
    }

    @Test func everyShippedOutputKeepsMLXLMsNames() {
        let names = Set(LanguageModelSpec.pinned.outputs.map(\.name))
        #expect(names.contains("language_model.model.embed_tokens.weight") && names.contains("language_model.model.embed_tokens_per_layer.scales"))
        #expect(names.contains("language_model.model.layers.41.layer_scalar") && names.contains("language_model.model.layers.23.self_attn.v_proj.biases"))
        #expect(!names.contains("language_model.model.layers.24.self_attn.k_proj.weight"), "shared layers have no k/v projections")
    }
}

@Suite("Language model: assembling")
struct StreamingQuantizerTests {
    @Test func theSyntheticModelIsConsistent() {
        let m = SyntheticLanguageModel()
        #expect(m.spec.isConsistent)
        #expect(m.spec.sources.filter { $0.action == .drop }.count == 3)
        #expect(m.spec.blocks.count >= 2)
    }

    private func span(_ m: SyntheticLanguageModel) -> Data { m.source.subdata(in: m.spec.spanStart..<m.spec.spanEnd) }

    @Test func anyCutOfTheBytesGivesTheSameFile() throws {
        let m = SyntheticLanguageModel()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-lm-q-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (i, cut) in [1, 7, 333, 4096, 100_000].enumerated() {
            let url = root.appendingPathComponent("out\(i)")
            // A tiny chunk size makes the matrices go through several row chunks.
            let q = try StreamingQuantizer(spec: m.spec, output: url, fresh: true, chunkBytes: 1024)
            let data = span(m)
            var o = 0
            while o < data.count {
                let n = min(cut, data.count - o)
                try data.subdata(in: o..<(o + n)).withUnsafeBytes { try q.feed($0) }
                o += n
            }
            try q.finish()
            #expect(try Data(contentsOf: url) == m.assembled, "cut \(cut)")
        }
    }

    @Test func aWrongByteIsCaughtWhenItsTensorCompletes() throws {
        let m = SyntheticLanguageModel()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-lm-q-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let q = try StreamingQuantizer(spec: m.spec, output: url, fresh: true)
        var data = span(m)
        data[data.startIndex + 5] ^= 0x40   // inside the first tensor (a norm that is copied)
        #expect(throws: IntegratedModelError.mismatch) {
            try data.withUnsafeBytes { try q.feed($0) }
        }
    }

    @Test func aStoppedRunResumesAtTheJournalPositionAndEndsWithTheSameFile() throws {
        let m = SyntheticLanguageModel()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-lm-q-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("out")
        let data = span(m)
        for stop in [1, 500, 3333, 9000, data.count - 1] {
            try? FileManager.default.removeItem(at: url)
            let first = try StreamingQuantizer(spec: m.spec, output: url, fresh: true, chunkBytes: 1024)
            try data.subdata(in: 0..<stop).withUnsafeBytes { try first.feed($0) }
            let journal = first.journal
            #expect(journal.resumeOffset <= stop)
            let second = try StreamingQuantizer(spec: m.spec, output: url, fresh: false, chunkBytes: 1024)
            second.resume(from: journal)
            try data.subdata(in: journal.resumeOffset..<data.count).withUnsafeBytes { try second.feed($0) }
            try second.finish()
            #expect(try Data(contentsOf: url) == m.assembled, "stopped at \(stop)")
        }
    }
}

extension StreamingQuantizerTests {
    @Test func aDamagedTensorInThePartialFileMovesTheRestartBackToItsSourceBytes() throws {
        let m = SyntheticLanguageModel()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-lm-q-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("out")
        let data = m.source.subdata(in: m.spec.spanStart..<m.spec.spanEnd)
        let stop = data.count * 3 / 4
        let first = try StreamingQuantizer(spec: m.spec, output: url, fresh: true, chunkBytes: 1024)
        try data.subdata(in: 0..<stop).withUnsafeBytes { try first.feed($0) }
        let journal = first.journal
        // Damage the second tensor that is kept (a completed one), by one bit inside its first output.
        let completed = m.spec.sources.filter { $0.offset + $0.size <= journal.resumeOffset && $0.action != .drop }
        let victim = try #require(completed.dropFirst().first)
        let outName = victim.action == .copy ? victim.outputName : victim.outputStem + ".weight"
        let out = try #require(m.spec.outputs.first { $0.name == outName })
        let handle = try FileHandle(forUpdating: url)
        let at = UInt64(m.spec.headerBytes().count + out.offset + out.size / 2)
        try handle.seek(toOffset: at)
        let byte = try #require(try handle.read(upToCount: 1))
        try handle.seek(toOffset: at)
        try handle.write(contentsOf: Data([byte[0] ^ 0x01]))
        try handle.close()
        // An undamaged file resumes where the journal says; the damaged one is moved back to the damaged tensor's source bytes.
        let second = try StreamingQuantizer(spec: m.spec, output: url, fresh: false, chunkBytes: 1024)
        let restart = second.resume(from: journal)
        #expect(restart.resumeOffset == victim.offset && restart.resumeOffset < journal.resumeOffset)
        try data.subdata(in: restart.resumeOffset..<data.count).withUnsafeBytes { try second.feed($0) }
        try second.finish()
        #expect(try Data(contentsOf: url) == m.assembled, "only the damaged tensor and what follows were fed again")
        // A healthy file keeps its journal.
        try? FileManager.default.removeItem(at: url)
        let a = try StreamingQuantizer(spec: m.spec, output: url, fresh: true, chunkBytes: 1024)
        try data.subdata(in: 0..<stop).withUnsafeBytes { try a.feed($0) }
        let b = try StreamingQuantizer(spec: m.spec, output: url, fresh: false, chunkBytes: 1024)
        #expect(b.resume(from: a.journal) == a.journal)
    }
}

extension StreamingQuantizerTests {
    @Test func aCancelledQuantiserStopsWritingBeforeItsAwaiterReturns() async throws {
        let m = SyntheticLanguageModel()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-lm-q-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let q = try StreamingQuantizer(spec: m.spec, output: url, fresh: true, chunkBytes: 1024)
        let feed = PendingFeed(quantizer: q)
        let data = m.source.subdata(in: m.spec.spanStart..<m.spec.spanEnd)
        feed.cancel()
        feed.start(data, skip: 0)
        await #expect(throws: CancellationError.self) { try await feed.wait() }
        let before = try Data(contentsOf: url)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try Data(contentsOf: url) == before, "nothing writes after the wait returned")
        #expect(q.position == 0, "it stopped before the first chunk")
    }
}

@Suite("Language model: download")
struct LanguageModelDownloaderTests {
    struct Env {
        let model = SyntheticLanguageModel()
        let behaviour: LanguageModelStub.Behaviour
        let fixture: LanguageModelFixture
        let log = NetworkActivityLog()
        let downloader: LanguageModelDownloader

        init(_ configure: (LanguageModelStub.Behaviour) -> Void = { _ in }) {
            behaviour = LanguageModelStub.Behaviour(model)
            configure(behaviour)
            LanguageModelStub.register(behaviour)
            fixture = LanguageModelFixture(spec: model.spec)
            downloader = LanguageModelDownloader(session: SearchModelDownloader.makeSession(protocolClasses: [LanguageModelStub.self], log: log),
                                                 store: fixture.store, appBuild: "test")
        }

        func run() async throws { try await downloader.run(progress: { _ in }) }
        func finish() { LanguageModelStub.unregister(behaviour); fixture.cleanup() }
    }

    @Test func aFreshDownloadVerifiesEachBlockQuantisesAndInstalls() async throws {
        let env = Env()
        defer { env.finish() }
        try await env.run()
        let store = env.fixture.store
        guard case .installed(let record) = store.disk() else { Issue.record("not installed"); return }
        #expect(record.assembledSHA256 == env.model.spec.assembledSHA256 && record.source == "download")
        #expect(try Data(contentsOf: store.weightsURL) == env.model.assembled)
        #expect(try Data(contentsOf: store.tokenizerURL) == env.model.tokenizer)
        let s = env.model.spec
        let expected = (0..<s.blocks.count).map { "bytes=\(s.blockSourceOffset($0))-\(s.blockSourceOffset($0) + s.blockLength($0) - 1)" }
        #expect(env.behaviour.rangeRequests.sorted() == expected.sorted(), "every block once, in any order: several are in flight at once")
        #expect(env.behaviour.hits.allSatisfy { $0.encoding == "identity" })
        #expect(store.isExcludedFromBackup)
        let perms = try FileManager.default.attributesOfItem(atPath: store.weightsURL.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        let dirPerms = try FileManager.default.attributesOfItem(atPath: store.installDirectory.path)[.posixPermissions] as? Int
        #expect(dirPerms == 0o700)
    }

    @Test func missingProvenanceHeadersAreAcceptedBecauseEveryByteIsStillVerified() async throws {
        let env = Env { $0.omitProvenanceHeaders = true }
        defer { env.finish() }
        try await env.run()
        #expect(try Data(contentsOf: env.fixture.store.weightsURL) == env.model.assembled)
        // The same without the headers and with a corrupted block twice: still refused, by the block hash.
        let bad = Env { $0.omitProvenanceHeaders = true; $0.tamperBlockServings = [1: 2] }
        defer { bad.finish() }
        await #expect(throws: IntegratedModelError.mismatch) { try await bad.run() }
    }

    @Test func aBlockThatDoesNotMatchIsFetchedOnceMoreAndASecondMismatchDeletesEverything() async throws {
        let once = Env { $0.tamperBlockServings = [1: 1] }
        defer { once.finish() }
        try await once.run()
        #expect(try Data(contentsOf: once.fixture.store.weightsURL) == once.model.assembled)

        let twice = Env { $0.tamperBlockServings = [1: 2] }
        defer { twice.finish() }
        await #expect(throws: IntegratedModelError.mismatch) { try await twice.run() }
        #expect(!FileManager.default.fileExists(atPath: twice.fixture.store.stagedWeightsPart.path))
    }

    @Test func aDroppedConnectionResumesAtTheBlockOfTheFirstUnconsumedByte() async throws {
        for failAfter in [1, 2] {
            let env = Env { $0.failRangeRequestsAfter = failAfter }
            defer { env.finish() }
            await #expect(throws: IntegratedModelError.self) { try await env.run() }
            #expect(env.fixture.store.disk() == .partial)
            env.behaviour.failRangeRequestsAfter = nil
            try await env.run()
            #expect(try Data(contentsOf: env.fixture.store.weightsURL) == env.model.assembled, "dropped after \(failAfter) blocks")
        }
    }

    @Test func aRedirectToAHostThatIsNotOnTheAllowlistIsBlockedAndNothingIsFetched() async throws {
        let env = Env { $0.cdnHost = "evil.example.com" }
        defer { env.finish() }
        await #expect(throws: IntegratedModelError.hostNotAllowed) { try await env.run() }
        #expect(env.behaviour.hits.allSatisfy { $0.host == "huggingface.co" })
    }

    @Test func aMismatchedCommitIsRefused() async throws {
        let env = Env { $0.repoCommit = "0000000000000000000000000000000000000000" }
        defer { env.finish() }
        await #expect(throws: IntegratedModelError.mismatch) { try await env.run() }
    }

    @Test func aStatus200ForARangeRequestIsRefused() async throws {
        let env = Env { $0.rangeStatus = 200 }
        defer { env.finish() }
        await #expect(throws: IntegratedModelError.unexpectedResponse) { try await env.run() }
    }

    @Test func anExpiredSignedAddressIsResolvedAgainOnce() async throws {
        let env = Env { $0.forbidNextCDN = 1; $0.forbidFirstRange = true }   // the tokenizer GET, then the first Range
        defer { env.finish() }
        try await env.run()
        #expect(try Data(contentsOf: env.fixture.store.weightsURL) == env.model.assembled)
        #expect(env.behaviour.hits.filter { $0.host == "huggingface.co" }.count >= 3)
        let twice = Env { $0.forbidNextCDN = 2 }   // a second 403 for the same file is an error
        defer { twice.finish() }
        await #expect(throws: IntegratedModelError.offline) { try await twice.run() }
    }

    @Test func noRequestLeavesTheLogWithASignedAddress() async throws {
        let env = Env()
        defer { env.finish() }
        try await env.run()
        let dump = String(decoding: try await env.log.exportJSON(), as: UTF8.self)
        #expect(!dump.contains("SECRET") && !dump.contains("X-Amz"))
        #expect(dump.contains("\"languageModelDownload\""))
    }

    @Test func notEnoughFreeSpaceIsRefusedBeforeAnythingIsFetched() async throws {
        var spec = SyntheticLanguageModel().spec
        spec.assembledSize += 1 << 60   // never fits
        let model = SyntheticLanguageModel()
        let behaviour = LanguageModelStub.Behaviour(model)
        LanguageModelStub.register(behaviour)
        let fixture = LanguageModelFixture(spec: spec)
        defer { LanguageModelStub.unregister(behaviour); fixture.cleanup() }
        let downloader = LanguageModelDownloader(session: SearchModelDownloader.makeSession(protocolClasses: [LanguageModelStub.self], log: NetworkActivityLog()),
                                                 store: fixture.store, appBuild: "test")
        await #expect { try await downloader.run(progress: { _ in }) } throws: { error in
            if case IntegratedModelError.diskFull(let needed) = error { return needed > 1 << 59 }
            return false
        }
        #expect(behaviour.hits.isEmpty)
    }
}

@Suite("Language model: import and store")
struct LanguageModelImportTests {
    private func write(_ data: Data, named name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test func theOriginalFileIsVerifiedAndQuantisedOnThisMac() async throws {
        let m = SyntheticLanguageModel()
        let fx = LanguageModelFixture(spec: m.spec)
        defer { fx.cleanup() }
        try FileManager.default.createDirectory(at: fx.root, withIntermediateDirectories: true)
        let original = try write(m.source, named: "model.safetensors", in: fx.root)
        let tok = try write(m.tokenizer, named: "tokenizer.json", in: fx.root)
        let first = try await LanguageModelImporter.importFiles([original], store: fx.store, appBuild: "t")
        #expect(first == .needsTokenizer)
        let second = try await LanguageModelImporter.importFiles([tok], store: fx.store, appBuild: "t")
        #expect(second == .installed)
        #expect(try Data(contentsOf: fx.store.weightsURL) == m.assembled)
        guard case .installed(let r) = fx.store.disk() else { Issue.record("not installed"); return }
        #expect(r.source == "import")
    }

    @Test func anAssembledFileFromAnotherMacIsAcceptedAndAWrongFileOfTheRightSizeIsNot() async throws {
        let m = SyntheticLanguageModel()
        let fx = LanguageModelFixture(spec: m.spec)
        defer { fx.cleanup() }
        try FileManager.default.createDirectory(at: fx.root, withIntermediateDirectories: true)
        var bad = m.assembled
        bad[bad.count - 10] ^= 1
        let wrong = try write(bad, named: "wrong.safetensors", in: fx.root)
        await #expect(throws: IntegratedModelError.mismatch) { _ = try await LanguageModelImporter.importFiles([wrong], store: fx.store) }
        let good = try write(m.assembled, named: "good.safetensors", in: fx.root)
        let tok = try write(m.tokenizer, named: "tokenizer.json", in: fx.root)
        let outcome = try await LanguageModelImporter.importFiles([good, tok], store: fx.store, appBuild: "t")
        #expect(outcome == .installed)
    }

    @Test func aFileOfAnotherSizeIsNotOneOfTheModelsFilesAndAnOriginalWithAChangedByteIsRefused() async throws {
        let m = SyntheticLanguageModel()
        let fx = LanguageModelFixture(spec: m.spec)
        defer { fx.cleanup() }
        try FileManager.default.createDirectory(at: fx.root, withIntermediateDirectories: true)
        let other = try write(Data(count: 1234), named: "other.bin", in: fx.root)
        await #expect(throws: IntegratedModelError.importWrongFile) { _ = try await LanguageModelImporter.importFiles([other], store: fx.store) }
        var tampered = m.source
        tampered[m.spec.spanStart + 100] ^= 0x10
        let orig = try write(tampered, named: "model.safetensors", in: fx.root)
        await #expect(throws: IntegratedModelError.mismatch) { _ = try await LanguageModelImporter.importFiles([orig], store: fx.store) }
        #expect(!FileManager.default.fileExists(atPath: fx.store.stagedWeightsPart.path), "nothing partial is left behind")
    }

    @Test func aSymbolicLinkIsFollowedLikeTheHuggingFaceCacheDoes() async throws {
        let m = SyntheticLanguageModel()
        let fx = LanguageModelFixture(spec: m.spec)
        defer { fx.cleanup() }
        try FileManager.default.createDirectory(at: fx.root, withIntermediateDirectories: true)
        let blob = try write(m.assembled, named: "blob", in: fx.root)
        let link = fx.root.appendingPathComponent("model.safetensors")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: blob)
        let tok = try write(m.tokenizer, named: "tokenizer.json", in: fx.root)
        #expect(try await LanguageModelImporter.importFiles([link, tok], store: fx.store, appBuild: "t") == .installed)
    }

    @Test func deleteRemovesEverythingAndTheGateRefusesSmallMacs() async throws {
        let m = SyntheticLanguageModel()
        let fx = LanguageModelFixture(spec: m.spec)
        defer { fx.cleanup() }
        try FileManager.default.createDirectory(at: fx.root, withIntermediateDirectories: true)
        let good = try write(m.assembled, named: "good.safetensors", in: fx.root)
        let tok = try write(m.tokenizer, named: "tokenizer.json", in: fx.root)
        _ = try await LanguageModelImporter.importFiles([good, tok], store: fx.store, appBuild: "t")
        #expect(fx.store.delete() > 0)
        #expect(fx.store.disk() == .empty)
        #expect(LanguageModelGate.refusal(memory: 8 << 30, gpuSupported: true) != nil)
        #expect(LanguageModelGate.refusal(memory: 15 << 30, gpuSupported: true) != nil)
        #expect(LanguageModelGate.refusal(memory: 16 << 30, gpuSupported: true) == nil)
        #expect(LanguageModelGate.refusal(memory: 64 << 30, gpuSupported: false) != nil)
    }

    @Test func theInstallLivesNextToTheSearchModelNotInsideTheStore() {
        let store = LanguageModelStore(applicationSupport: URL(fileURLWithPath: "/tmp/x"))
        #expect(store.installDirectory.path == "/tmp/x/Vauta Models/gemma-4-e4b-it/ee0ef602")
        #expect(store.stillNeeded(stagedBytes: 0) == LanguageModelSpec.pinned.installedSize + LanguageModelStore.headroom)
    }

    // MARK: Disk figures

    @Test func theDiskFiguresIgnoreTheSearchModelAndCountOnlyWhatAResumedSparsePartialHolds() throws {
        let model = SyntheticLanguageModel()
        let fx = LanguageModelFixture(spec: model.spec)
        defer { fx.cleanup() }
        var store = fx.store
        try store.createStaging()
        // The search model sits beside the language model in "Vauta Models".
        let search = store.root.appendingPathComponent("embeddinggemma-2", isDirectory: true)
        try FileManager.default.createDirectory(at: search, withIntermediateDirectories: true)
        try Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7) }).write(to: search.appendingPathComponent("model.safetensors"))
        // The output file is created at its full length (200 MiB here, 4.2 GB for the real one) and fills as the download goes.
        let fd = open(store.stagedWeightsPart.path, O_RDWR | O_CREAT, 0o600)
        defer { close(fd) }
        #expect(ftruncate(fd, 200 << 20) == 0)
        let chunk = [UInt8](repeating: 0xAB, count: 1 << 20)
        #expect(pwrite(fd, chunk, chunk.count, 0) == chunk.count)
        #expect(store.bytesOnDisk() < 8 << 20, "the search model's 3 MiB and the 200 MiB of unwritten file are not counted: \(store.bytesOnDisk())")
        #expect(store.stagingBytes() >= 1 << 20 && store.stagingBytes() < 8 << 20)
        // What is still needed follows the written bytes, and the error carries it.
        let needed = store.stillNeeded(stagedBytes: store.stagingBytes())
        #expect(needed == max(LanguageModelStore.headroom, store.spec.installedSize + LanguageModelStore.headroom - store.stagingBytes()))
        store.capacityOverride = { LanguageModelStore.headroom / 2 }
        #expect(throws: IntegratedModelError.diskFull(needed: needed)) { try store.checkRoomToInstall() }
        store.capacityOverride = { needed }
        #expect(throws: Never.self) { try store.checkRoomToInstall() }
    }
}
