// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import VautaCore

/// A small stand-in for the real language model: an "original file" (a header, an audio tensor, the language tower, a tail), the
/// 4-bit file Vauta assembles from it (made here with `AffineQuantizer`), a tokenizer file and the spec that pins all of it.
struct SyntheticLanguageModel: Sendable {
    let id = UUID().uuidString.lowercased().prefix(8).description
    var spec: LanguageModelSpec
    let source: Data
    let tokenizer: Data
    let assembled: Data

    static func sha(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    static func bf16(_ f: Float) -> UInt16 { AffineQuantizer.floatToBF16(f) }

    /// Deterministic bf16 values, roughly normal.
    static func values(_ n: Int, seed: UInt64, scale: Float = 0.05) -> [UInt16] {
        var rng = SplitMix(seed)
        return (0..<n).map { _ in
            let u = (rng.unit() + rng.unit() + rng.unit() + rng.unit() - 2) * 0.8660254
            return bf16(Float(u) * scale)
        }
    }

    struct SplitMix: RandomNumberGenerator {
        var s: UInt64
        init(_ s: UInt64) { self.s = s }
        mutating func next() -> UInt64 {
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }

    /// Tensors of the tiny tower, in file order (names sorted backwards so that file order differs from output order).
    static let towerShapes: [(String, [Int])] = [
        ("model.language_model.norm.weight", [128]),
        ("model.language_model.layers.1.self_attn.v_proj.weight", [32, 128]),
        ("model.language_model.layers.1.self_attn.q_proj.weight", [64, 128]),
        ("model.language_model.layers.1.self_attn.k_proj.weight", [32, 128]),
        ("model.language_model.layers.1.self_attn.k_norm.weight", [32]),
        ("model.language_model.layers.1.layer_scalar", [1]),
        ("model.language_model.layers.0.self_attn.v_proj.weight", [32, 128]),
        ("model.language_model.layers.0.self_attn.q_proj.weight", [64, 128]),
        ("model.language_model.layers.0.self_attn.k_proj.weight", [32, 128]),
        ("model.language_model.layers.0.self_attn.k_norm.weight", [32]),
        ("model.language_model.layers.0.layer_scalar", [1]),
        ("model.language_model.layers.0.input_layernorm.weight", [128]),
        ("model.language_model.embed_tokens_per_layer.weight", [96, 192]),
        ("model.language_model.embed_tokens.weight", [80, 128]),
    ]

    init(blockSize: Int = 8192, tokenizerSize: Int = 300, firstSharedLayer: Int = 1, tower: [(String, [Int])] = SyntheticLanguageModel.towerShapes) {
        var sources: [LanguageModelSpec.SourceTensor] = []
        var span = Data()
        var offset = 0
        for (i, (name, shape)) in tower.enumerated() {
            let n = shape.reduce(1, *)
            var data = Data()
            for v in Self.values(n, seed: UInt64(i + 1)) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
            sources.append(.init(name: name, shape: shape, offset: offset, size: data.count, sha256: Self.sha(data),
                                 action: LanguageModelSpec.action(forSource: name, shape: shape, firstSharedLayer: firstSharedLayer)))
            span += data
            offset += data.count
        }
        // The original file: a header (JSON), a tensor before the tower, the tower, a tensor after it.
        let before = Data((0..<2000).map { UInt8(truncatingIfNeeded: $0 &* 7) }), after = Data((0..<900).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        var entries = ["\"model.audio_tower.a\":{\"dtype\":\"BF16\",\"shape\":[1000],\"data_offsets\":[0,\(before.count)]}"]
        for t in sources {
            entries.append("\"\(t.name)\":{\"dtype\":\"BF16\",\"shape\":[\(t.shape.map(String.init).joined(separator: ","))],\"data_offsets\":[\(before.count + t.offset),\(before.count + t.offset + t.size)]}")
        }
        entries.append("\"model.vision_tower.z\":{\"dtype\":\"BF16\",\"shape\":[450],\"data_offsets\":[\(before.count + span.count),\(before.count + span.count + after.count)]}")
        var json = Data(("{" + entries.joined(separator: ",") + ",\"__metadata__\":{\"format\":\"pt\"}}").utf8)
        while json.count % 8 != 0 { json.append(0x20) }
        var n = UInt64(json.count).littleEndian
        let header = Data(bytes: &n, count: 8) + json
        let source = header + before + span + after
        let tokenizer = Data((0..<tokenizerSize).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 3) })

        // The 4-bit file, made directly with the quantizer.
        var outs = LanguageModelSpec.derivedOutputs(from: sources)
        var dataBuffer = [UInt8](repeating: 0, count: outs.last.map { $0.offset + $0.size } ?? 0)
        let index = Dictionary(uniqueKeysWithValues: outs.enumerated().map { ($1.name, $0) })
        for t in sources where t.action != .drop {
            let raw = span.subdata(in: t.offset..<(t.offset + t.size))
            switch t.action {
            case .copy:
                let o = outs[index[t.outputName]!]
                dataBuffer.replaceSubrange(o.offset..<(o.offset + o.size), with: raw)
            case .quantize:
                let rows = t.shape[0], cols = t.shape[1]
                var w = [UInt32](repeating: 0, count: rows * cols / 8), sc = [UInt16](repeating: 0, count: rows * cols / 64), bi = sc
                raw.withUnsafeBytes { r in
                    try! AffineQuantizer.quantize(rows: rows, cols: cols, source: r.bindMemory(to: UInt16.self).baseAddress!, weights: &w, scales: &sc, biases: &bi)
                }
                for (suffix, bytes) in [(".weight", w.withUnsafeBytes { Data($0) }), (".scales", sc.withUnsafeBytes { Data($0) }), (".biases", bi.withUnsafeBytes { Data($0) })] {
                    let o = outs[index[t.outputStem + suffix]!]
                    dataBuffer.replaceSubrange(o.offset..<(o.offset + o.size), with: bytes)
                }
            case .drop: break
            }
        }
        for i in outs.indices {
            outs[i] = .init(name: outs[i].name, dtype: outs[i].dtype, shape: outs[i].shape, offset: outs[i].offset, size: outs[i].size,
                            sha256: Self.sha(Data(dataBuffer[outs[i].offset..<(outs[i].offset + outs[i].size)])))
        }
        var blocks: [String] = []
        var s = 0
        while s < span.count {
            blocks.append(Self.sha(span.subdata(in: s..<min(s + blockSize, span.count))))
            s += blockSize
        }
        var spec = LanguageModelSpec(
            repository: "test/lm-\(id)", revision: "abcdef0123456789abcdef0123456789abcdef01", sourceFile: "model.safetensors",
            sourceSize: source.count, sourceSHA256: Self.sha(source), sourceHeaderSize: header.count, sourceHeaderSHA256: Self.sha(header),
            spanStart: header.count + before.count, spanEnd: header.count + before.count + span.count, blockSize: blockSize, blocks: blocks,
            sources: sources, outputs: outs, assembledSize: 0, assembledSHA256: "", tokenizerFile: "tokenizer.json",
            tokenizerSize: tokenizer.count, tokenizerSHA256: Self.sha(tokenizer))
        let assembled = spec.headerBytes() + Data(dataBuffer)
        spec.assembledSize = assembled.count
        spec.assembledSHA256 = Self.sha(assembled)
        self.spec = spec
        self.source = source
        self.tokenizer = tokenizer
        self.assembled = assembled
    }
}

/// A temporary store for a test.
struct LanguageModelFixture {
    let root: URL
    let store: LanguageModelStore

    init(spec: LanguageModelSpec) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-language-model-test-\(UUID().uuidString)", isDirectory: true)
        store = LanguageModelStore(root: root.appendingPathComponent(LanguageModelStore.folderName, isDirectory: true), spec: spec)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

/// Hugging Face and its CDN behind `URLProtocol` for a synthetic language model: no socket is opened.
final class LanguageModelStub: URLProtocol, @unchecked Sendable {
    final class Behaviour: @unchecked Sendable {
        let model: SyntheticLanguageModel
        private let lock = NSLock()
        private var _hits: [(host: String, path: String, range: String?, encoding: String?)] = []
        var cdnHost = "us.aws.cdn.hf.co"
        var rangeStatus = 206
        var repoCommit: String?
        /// Answer the redirect without X-Repo-Commit, X-Linked-Etag and X-Linked-Size.
        var omitProvenanceHeaders = false
        /// Range requests (counted from 0) after which the connection drops.
        var failRangeRequestsAfter: Int?
        var tamperBlockServings: [Int: Int] = [:]
        var forbidNextCDN = 0
        /// The first Range request answers 403, as an expired signed address does.
        var forbidFirstRange = false
        var rangeServed = 0
        init(_ model: SyntheticLanguageModel) { self.model = model }
        var hits: [(host: String, path: String, range: String?, encoding: String?)] { lock.withLock { _hits } }
        func record(_ h: (host: String, path: String, range: String?, encoding: String?)) { lock.withLock { _hits.append(h) } }
        var rangeRequests: [String] { hits.filter { $0.host != "huggingface.co" }.compactMap(\.range) }
        func takeTamper(_ block: Int) -> Bool {
            lock.withLock {
                guard let n = tamperBlockServings[block], n > 0 else { return false }
                tamperBlockServings[block] = n - 1
                return true
            }
        }
        func nextRange() -> Int { lock.withLock { defer { rangeServed += 1 }; return rangeServed } }
        func takeForbidden() -> Bool { lock.withLock { if forbidNextCDN > 0 { forbidNextCDN -= 1; return true }; return false } }
    }

    private static let registry = Mutex<[String: Behaviour]>([:])
    static func register(_ b: Behaviour) { registry.withLock { $0[b.model.id] = b } }
    static func unregister(_ b: Behaviour) { registry.withLock { $0[b.model.id] = nil } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private func reply(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        guard let url = request.url else { return }
        var h = headers
        h["Content-Length"] = String(body.count)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: h)!, cacheStoragePolicy: .notAllowed)
        var offset = 0
        while offset < body.count {
            let end = min(offset + 4000, body.count)
            client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        let path = url.path
        let range = request.value(forHTTPHeaderField: "Range")
        let id = Self.registry.withLock { r in r.keys.first { path.contains($0) } }
        guard let id, let b = Self.registry.withLock({ $0[id] }) else { reply(status: 200); return }
        b.record((host, path, range, request.value(forHTTPHeaderField: "Accept-Encoding")))
        let spec = b.model.spec
        let isTokenizer = path.hasSuffix(spec.tokenizerFile)
        if host == "huggingface.co" {
            var headers = [
                "Location": "https://\(b.cdnHost)/xet-bridge-us/\(id)/\(isTokenizer ? spec.tokenizerFile : spec.sourceFile)?X-Amz-Signature=SECRET"]
            if !b.omitProvenanceHeaders {
                headers["X-Repo-Commit"] = b.repoCommit ?? spec.revision
                headers["X-Linked-Etag"] = "\"" + (isTokenizer ? spec.tokenizerSHA256 : spec.sourceSHA256) + "\""
                headers["X-Linked-Size"] = String(isTokenizer ? spec.tokenizerSize : spec.sourceSize)
            }
            reply(status: 302, headers: headers)
            return
        }
        guard host == b.cdnHost else { reply(status: 200); return }
        if b.takeForbidden() { reply(status: 403); return }
        if isTokenizer { reply(status: 200, body: b.model.tokenizer); return }
        guard let range, range.hasPrefix("bytes=") else { reply(status: 200, body: b.model.source); return }
        let parts = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, parts[1] < b.model.source.count else { reply(status: 416); return }
        let served = b.nextRange()
        if served == 0, b.forbidFirstRange { b.forbidFirstRange = false; reply(status: 403); return }
        if let limit = b.failRangeRequestsAfter, served >= limit {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        var body = b.model.source.subdata(in: parts[0]..<(parts[1] + 1))
        if b.takeTamper((parts[0] - spec.spanStart) / spec.blockSize) { body[body.startIndex] ^= 0xFF }
        if b.rangeStatus != 206 { reply(status: b.rangeStatus, body: body); return }
        reply(status: 206, headers: ["Content-Range": "bytes \(parts[0])-\(parts[1])/\(b.model.source.count)"], body: body)
    }
}


/// One GPU-bound language model test at a time across suites. `.serialized` only orders the tests inside a suite; four such suites
/// still ran side by side, and their blocking tensor work held the cooperative threads that the time-bounded tests of other suites
/// (cancellation within a second or two) need, so those failed on a busy Mac. Apply as `@Suite(..., .gpuExclusive)`.
struct GPUExclusive: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    actor Lock {
        static let shared = Lock()
        private var busy = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func acquire() async {
            if !busy { busy = true; return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
    }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        guard testCase != nil else { return try await function() }
        await Lock.shared.acquire()
        do { try await function() } catch { await Lock.shared.release(); throw error }
        await Lock.shared.release()
    }
}

extension SuiteTrait where Self == GPUExclusive {
    static var gpuExclusive: GPUExclusive { GPUExclusive() }
}
