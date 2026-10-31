// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Synchronization
@testable import VautaCore

/// A small stand-in for the real model: a "source file" with a span of three blocks, the tensors that tile it, a tokenizer
/// file and the spec that pins all of them. The real model is never downloaded by a test.
struct SyntheticModel: Sendable {
    let id = UUID().uuidString.lowercased().prefix(8).description
    var spec: SearchModelSpec
    let source: Data
    let tokenizer: Data
    let span: Data
    let assembled: Data

    static func sha(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    init(blockSize: Int = 1000, spanSize: Int = 2500, prefix: Int = 100, suffix: Int = 400, tokenizerSize: Int = 300, tokenizerData: Data? = nil) {
        func bytes(_ n: Int, _ seed: UInt8) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }) }
        let span = bytes(spanSize, 7)
        let source = bytes(prefix, 1) + span + bytes(suffix, 2)
        let tokenizer = tokenizerData ?? bytes(tokenizerSize, 3)
        let tokenizerSize = tokenizer.count
        // Three tensors that tile the span.
        let sizes = [1000, 1000, spanSize - 2000]
        var offset = 0
        var tensors: [SearchModelSpec.Tensor] = []
        for (i, size) in sizes.enumerated() {
            tensors.append(.init(name: "t\(i)", dtype: "F16", shape: [size / 2], offset: offset, size: size,
                                 sha256: Self.sha(span.subdata(in: offset..<(offset + size)))))
            offset += size
        }
        var blocks: [String] = []
        var s = 0
        while s < spanSize {
            blocks.append(Self.sha(span.subdata(in: s..<min(s + blockSize, spanSize))))
            s += blockSize
        }
        var spec = SearchModelSpec(repository: "test/model-\(id)", revision: "abcdef0123456789abcdef0123456789abcdef01",
                                   sourceFile: "model.safetensors", sourceSize: source.count, sourceSHA256: Self.sha(source),
                                   spanStart: prefix, spanEnd: prefix + spanSize, blockSize: blockSize, blocks: blocks, tensors: tensors,
                                   assembledSize: 0, assembledSHA256: "", tokenizerFile: "tokenizer.json",
                                   tokenizerSize: tokenizerSize, tokenizerSHA256: Self.sha(tokenizer))
        let header = spec.headerBytes()
        let assembled = header + span
        spec.assembledSize = assembled.count
        spec.assembledSHA256 = Self.sha(assembled)
        self.spec = spec
        self.source = source
        self.tokenizer = tokenizer
        self.span = span
        self.assembled = assembled
    }
}

/// A temporary store for a test.
struct ModelFixture {
    let root: URL
    let store: SearchModelStore

    init(spec: SearchModelSpec) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-search-model-test-\(UUID().uuidString)", isDirectory: true)
        store = SearchModelStore(root: root.appendingPathComponent(SearchModelStore.folderName, isDirectory: true), spec: spec)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

/// Hugging Face and its CDN behind `URLProtocol`: no socket is opened. Each synthetic model has its own id in its repository
/// name and in the CDN path, so tests run in parallel.
final class ModelStub: URLProtocol, @unchecked Sendable {
    struct Hit: Sendable, Equatable {
        let host: String
        let path: String
        let range: String?
        let hasQuery: Bool
        var acceptEncoding: String?
        var userAgent: String?
    }

    final class Behaviour: @unchecked Sendable {
        let model: SyntheticModel
        private let lock = NSLock()
        private var _hits: [Hit] = []
        private var _rangeServed = 0
        // Scenario knobs (set before the download starts).
        var cdnHost = "us.aws.cdn.hf.co"
        var resolveStatus = 302
        var repoCommit: String?
        var linkedEtag: String?
        var rangeStatus = 206
        /// `Content-Encoding` the CDN answers with (a server that compresses although it was asked not to).
        var contentEncoding: String?
        var contentRange: (@Sendable (_ from: Int, _ to: Int, _ total: Int) -> String)?
        var shortBodyBy = 0
        var tamperBlockServings: [Int: Int] = [:]   // block index -> how many times to serve it corrupted
        var forbiddenFirstCDNRequests = 0
        /// CDN requests (counted from 0, the tokenizer's GET first) that answer 403, as an expired signed address does.
        var forbidCDNRequestNumbers: Set<Int> = []
        private var cdnServed = 0
        var failRangeRequestsAfter: Int?
        /// Range requests from this one on (counted from 0) get their headers and then silence, as a connection that stalls does: the
        /// request stays in flight until the client gives up, however long the test takes to act.
        var stallRangeRequestsFrom: Int?
        var chunk = 400
        var chunkDelayMicroseconds: UInt32 = 0
        init(_ model: SyntheticModel) { self.model = model }

        var hits: [Hit] { lock.withLock { _hits } }
        func record(_ hit: Hit) { lock.withLock { _hits.append(hit) } }
        func count(host: String) -> Int { hits.filter { $0.host == host }.count }
        var rangeRequests: [String] { hits.filter { $0.host != "huggingface.co" }.compactMap(\.range) }
        func nextRangeIndex() -> Int { lock.withLock { defer { _rangeServed += 1 }; return _rangeServed } }
        func takeTamper(_ block: Int) -> Bool {
            lock.withLock {
                guard let n = tamperBlockServings[block], n > 0 else { return false }
                tamperBlockServings[block] = n - 1
                return true
            }
        }
        func takeForbidden() -> Bool {
            lock.withLock {
                defer { cdnServed += 1 }
                if forbidCDNRequestNumbers.contains(cdnServed) { return true }
                guard forbiddenFirstCDNRequests > 0 else { return false }
                forbiddenFirstCDNRequests -= 1
                return true
            }
        }
    }

    private static let registry = Mutex<[String: Behaviour]>([:])

    static func register(_ behaviour: Behaviour) { registry.withLock { $0[behaviour.model.id] = behaviour } }
    static func unregister(_ behaviour: Behaviour) { registry.withLock { $0[behaviour.model.id] = nil } }

    private let stopped = Mutex(false)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { stopped.withLock { $0 = true } }

    private func reply(status: Int, headers: [String: String] = [:], body: Data = Data(), declaredLength: Int? = nil, chunk: Int = 400, delay: UInt32 = 0,
                       encoding: String? = nil) {
        guard let url = request.url else { return }
        var h = headers
        h["Content-Length"] = String(declaredLength ?? body.count)
        if let encoding { h["Content-Encoding"] = encoding }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: h)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var offset = 0
        while offset < body.count {
            if stopped.withLock({ $0 }) { return }
            let end = min(offset + chunk, body.count)
            client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
            if delay > 0 { usleep(delay) }
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        let path = url.path
        let range = request.value(forHTTPHeaderField: "Range")
        let id = Self.registry.withLock { registry -> String? in registry.keys.first { path.contains($0) } }
        guard let id, let b = Self.registry.withLock({ $0[id] }) else {
            // Anything else (a host that is not allowed) just answers; the test counts what reached it.
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        b.record(Hit(host: host, path: path, range: range, hasQuery: url.query != nil, acceptEncoding: request.value(forHTTPHeaderField: "Accept-Encoding"),
                        userAgent: request.value(forHTTPHeaderField: "User-Agent")))
        let spec = b.model.spec
        let file = path.hasSuffix(spec.tokenizerFile) ? spec.tokenizerFile : spec.sourceFile
        if host == "huggingface.co" {
            var headers = ["Location": "https://\(b.cdnHost)/xet-bridge-us/\(id)/\(file)?X-Amz-Signature=SECRETSIGNATURE&Expires=123"]
            headers["X-Repo-Commit"] = b.repoCommit ?? spec.revision
            headers["X-Linked-Etag"] = "\"" + (b.linkedEtag ?? (file == spec.tokenizerFile ? spec.tokenizerSHA256 : spec.sourceSHA256)) + "\""
            headers["X-Linked-Size"] = String(file == spec.tokenizerFile ? spec.tokenizerSize : spec.sourceSize)
            if b.resolveStatus != 302 { reply(status: b.resolveStatus); return }
            reply(status: 302, headers: headers)
            return
        }
        guard host == b.cdnHost else { reply(status: 200); return }
        if b.takeForbidden() { reply(status: 403); return }
        let data = file == spec.tokenizerFile ? b.model.tokenizer : b.model.source
        guard let range, range.hasPrefix("bytes="), file == spec.sourceFile else { reply(status: 200, body: data, chunk: b.chunk, encoding: b.contentEncoding); return }
        let parts = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, parts[1] < data.count else { reply(status: 416); return }
        let served = b.nextRangeIndex()
        if let limit = b.failRangeRequestsAfter, served >= limit {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        if let from = b.stallRangeRequestsFrom, served >= from {
            let stalled = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Range": "bytes \(parts[0])-\(parts[1])/\(data.count)", "Content-Length": String(parts[1] - parts[0] + 1)])!
            client?.urlProtocol(self, didReceive: stalled, cacheStoragePolicy: .notAllowed)
            return   // never finishes: the request stays in flight until the client cancels it (`stopLoading`)
        }
        var body = data.subdata(in: parts[0]..<(parts[1] + 1))
        let block = (parts[0] - spec.spanStart) / spec.blockSize
        if b.takeTamper(block) { body[body.startIndex] ^= 0xFF }
        let declared = body.count
        if b.shortBodyBy > 0 { body = body.prefix(max(0, body.count - b.shortBodyBy)) }
        let contentRange = b.contentRange?(parts[0], parts[1], data.count) ?? "bytes \(parts[0])-\(parts[1])/\(data.count)"
        reply(status: b.rangeStatus, headers: ["Content-Range": contentRange], body: body, declaredLength: declared, chunk: b.chunk, delay: b.chunkDelayMicroseconds, encoding: b.contentEncoding)
    }
}


/// A hand-built `tokenizer.json` of about 2 KB in the Hugging Face format: BPE merges, byte fallback, added special tokens and two
/// canonically equivalent keys that must stay distinct.
enum TinyTokenizer {
    static let json = """
    {"added_tokens":[{"id":0,"content":"<pad>","special":true},{"id":1,"content":"<eos>","special":true},{"id":2,"content":"<bos>","special":true},{"id":3,"content":"<unk>","special":true}],
     "model":{"type":"BPE","vocab":{"<pad>":0,"<eos>":1,"<bos>":2,"<unk>":3,"\\u2581":4,"a":5,"b":6,"\\u2581a":7,"ab":8,"\\u2581ab":9,"c":10,
       "<0xC3>":11,"<0xBC>":12,"<0x0A>":13,"<0xA9>":14,"\\u00e9":20,"e\\u0301":21,"e":22,"\\u0301":23,"|":24,":":25,"\\u2581|":26},
      "merges":[["a","b"],["\\u2581","a"],["\\u2581a","b"],["\\u2581","ab"],["e","\\u0301"]]}}
    """

    static func tokenizer() throws -> GemmaTokenizer { try GemmaTokenizer(tokenizerJSON: Data(json.utf8)) }
}

/// An encoder that makes a deterministic 256-dimensional unit vector from the token ids: no GPU, no model.
final class FakeEncoder: SearchEncoding {
    let fp32: Bool
    let nonFiniteWhen: @Sendable ([Int32]) -> Bool
    let log: FakeEncoderLog

    init(fp32: Bool, log: FakeEncoderLog, nonFiniteWhen: @escaping @Sendable ([Int32]) -> Bool = { _ in false }) {
        self.fp32 = fp32
        self.log = log
        self.nonFiniteWhen = nonFiniteWhen
        log.built(fp32: fp32)
    }

    deinit { log.released(fp32: fp32) }

    static func vector(_ tokens: [Int32]) -> [Float] {
        var v = [Float](repeating: 0, count: 256)
        for (i, t) in tokens.enumerated() { v[(Int(t) &* 7 &+ i) % 256] += Float(1 + (Int(t) % 5)) }
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return v.map { $0 / max(norm, 1e-9) }
    }

    func embedBatch(tokens: [[Int32]]) throws -> (vectors: [Float], nonFinite: [Bool]) {
        log.batch(rows: tokens.count, longest: tokens.map(\.count).max() ?? 0, fp32: fp32)
        let bad = tokens.map { !fp32 && nonFiniteWhen($0) }
        return (tokens.flatMap { Self.vector($0) }, bad)
    }
}

final class FakeEncoderLog: @unchecked Sendable {
    struct Batch: Equatable { let rows: Int; let longest: Int; let fp32: Bool }
    private let lock = NSLock()
    private var _batches: [Batch] = []
    private var _built: [Bool] = []
    private var _released: [Bool] = []
    var batches: [Batch] { lock.withLock { _batches } }
    var built: [Bool] { lock.withLock { _built } }
    var released: [Bool] { lock.withLock { _released } }
    func batch(rows: Int, longest: Int, fp32: Bool) { lock.withLock { _batches.append(Batch(rows: rows, longest: longest, fp32: fp32)) } }
    func built(fp32: Bool) { lock.withLock { _built.append(fp32) } }
    func released(fp32: Bool) { lock.withLock { _released.append(fp32) } }
}

/// An installed synthetic model in a temporary store, with the tiny tokenizer, and an engine on a fake encoder.
struct EngineFixture {
    let model: SyntheticModel
    let fixture: ModelFixture
    let log = FakeEncoderLog()
    let engine: SearchModelEngine

    init(idle: Duration = .seconds(180), footprint: @escaping @Sendable () -> Int = { 400 }, nonFiniteWhen: @escaping @Sendable ([Int32]) -> Bool = { _ in false },
         clearCache: @escaping @Sendable () -> Void = {}, pressureCooldown: Duration = .seconds(30),
         gate: MLXWorkGate = MLXWorkGate()) throws {
        model = SyntheticModel(tokenizerData: Data(TinyTokenizer.json.utf8))
        fixture = ModelFixture(spec: model.spec)
        let store = fixture.store
        try store.createStaging()
        try model.assembled.write(to: store.stagedWeights)
        try model.tokenizer.write(to: store.stagedTokenizer)
        try store.install(SearchModelInstallRecord(revision: model.spec.revision, assembledSHA256: model.spec.assembledSHA256,
                                                   tokenizerSHA256: model.spec.tokenizerSHA256, source: "import", installedAt: Date(), appBuild: "test"))
        let log = log
        let factory = SearchEncoderFactory { _, fp32 in FakeEncoder(fp32: fp32, log: log, nonFiniteWhen: nonFiniteWhen) }
        engine = SearchModelEngine(store: store, factory: factory, appBuild: "test", idleTimeout: idle, footprint: footprint, clearCache: clearCache,
                                   pressureCooldown: pressureCooldown, gate: gate)
    }

    func cleanup() { fixture.cleanup() }
}

/// A stand-in for the model: words of the same concept share a dimension, other words land on hashed dimensions with a small
/// weight, so a question and a passage about the same thing have a high cosine without sharing a word.
enum ConceptEmbedder {
    static let concepts: [[String]] = [
        ["cat", "cats", "kitten", "feline", "felines"], ["car", "cars", "engine", "motor", "motors", "vehicle"],
        ["budget", "spending", "costs", "finance", "money"], ["hire", "hiring", "recruit", "recruiting", "staffing"],
        ["invoice", "invoices", "billing", "payment", "payments"], ["launch", "release", "shipping", "rollout"],
    ]

    static func vector(_ text: String) -> [Float] {
        var v = [Float](repeating: 0, count: 256)
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) {
            if let c = concepts.firstIndex(where: { $0.contains(word) }) {
                v[c] += 1
            } else {
                var h: UInt64 = 1469598103934665603
                for b in word.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
                v[16 + Int(h % 240)] += 0.15
            }
        }
        if v.allSatisfy({ $0 == 0 }) { v[255] = 1 }
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return v.map { $0 / norm }
    }

    static let space = EmbeddingSpace(model: SearchModelManifest.spaceModel, dimensions: 256)
}
