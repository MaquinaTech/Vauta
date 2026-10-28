// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Security

/// The role of each model; the user picks the actual names in Settings → Models.
public enum LLMRole: String, Codable, Sendable, CaseIterable {
    /// Live notes while recording: fast, no reasoning.
    case fast
    /// Final minutes and Ask with citations.
    case deep
    /// Embeddings for Ask.
    case embedding
}

public struct ChatMessage: Sendable, Codable, Equatable {
    public let role: String
    public let content: String
    public init(_ role: String, _ content: String) {
        self.role = role
        self.content = content
    }
    public static func system(_ c: String) -> ChatMessage { ChatMessage("system", c) }
    public static func user(_ c: String) -> ChatMessage { ChatMessage("user", c) }
}

/// Which of the integrated model's two kept prefixes a call uses: the meeting being recorded (or just recorded), or anything else.
public enum KeptSlot: Sendable, Equatable { case meeting, ask }

public struct ChatOptions: Sendable {
    public var model: LLMRole
    public var maxTokens: Int
    /// Reasoning on or off; how it is requested depends on the server profile.
    public var thinking: Bool
    /// "low" | "medium" | "high" (with reasoning only).
    public var reasoningEffort: String?
    /// Structured output, sent only when the server profile supports it.
    public var responseFormat: ResponseFormat?
    /// Throw `LLMError.outputTruncated` instead of returning a cut-off answer.
    public var failOnTruncation: Bool
    /// A model name to use instead of the role's configured one (the role still
    /// picks the server address). nil = the role's model.
    public var modelOverride: String?
    /// Replaces the sampling preset's temperature. nil = the profile decides.
    public var temperature: Double?
    /// What the request is for, as the Network Activity window lists it.
    public var purpose: NetworkPurpose
    /// Only the integrated language model: decode within this grammar (see `OutputSchemas`).
    public var constraint: (any OutputConstraint)?
    /// Only the integrated language model: the shape of the JSON answer; it builds the grammar from it.
    public var outputSchema: OutputSchema?
    /// Only the integrated language model: keep the state of everything before the last message for the next call (live answers).
    public var reusePrefix: Bool
    /// Only the integrated language model: who waits for the GPU first.
    public var priority: MLXWorkGate.Priority
    /// Only the integrated language model: stop writing after this many seconds of decoding (a constrained value is still closed as
    /// valid JSON, finish `length`). nil = no limit.
    public var maxSeconds: Double?
    /// Only the integrated language model: which kept prefix a call with `reusePrefix` uses. nil = by priority (live work and the
    /// minutes use the meeting's, an answer uses the Ask one).
    public var slot: KeptSlot?
    /// Only the integrated language model: called as the prompt is read, with the tokens in the caches (kept ones included) and the
    /// prompt's length.
    public var onPrefill: (@Sendable (Int, Int) -> Void)?

    public init(model: LLMRole, maxTokens: Int, thinking: Bool = false, reasoningEffort: String? = nil,
                responseFormat: ResponseFormat? = nil, failOnTruncation: Bool = false,
                modelOverride: String? = nil, temperature: Double? = nil, purpose: NetworkPurpose = .other,
                constraint: (any OutputConstraint)? = nil, outputSchema: OutputSchema? = nil, reusePrefix: Bool = false, priority: MLXWorkGate.Priority = .minutes,
                maxSeconds: Double? = nil, slot: KeptSlot? = nil, onPrefill: (@Sendable (Int, Int) -> Void)? = nil) {
        self.slot = slot
        self.onPrefill = onPrefill
        self.maxSeconds = maxSeconds
        self.constraint = constraint
        self.outputSchema = outputSchema
        self.reusePrefix = reusePrefix
        self.priority = priority
        self.modelOverride = modelOverride
        self.temperature = temperature
        self.purpose = purpose
        self.model = model
        self.maxTokens = maxTokens
        self.thinking = thinking
        self.reasoningEffort = reasoningEffort
        self.responseFormat = responseFormat
        self.failOnTruncation = failOnTruncation
    }
}

public struct LatencyBreakdown: Codable, Sendable, Equatable {
    public var tokenizeSeconds = 0.0
    public var slotWaitSeconds = 0.0
    public var gateWaitSeconds = 0.0
    public var newPrefillTokens = 0
    public var prefillChunks = 0
    public var prefillSeconds = 0.0
    public init() {}
}

/// What a schema-constrained call cost in grammar work (evaluation only): masks computed, their percentiles, the first one (which
/// builds the lazy tables), and the time to build the constraint (the first use builds the trie of the whole vocabulary).
public struct ConstraintTiming: Codable, Sendable, Equatable {
    public var masks: Int
    public var totalSeconds: Double
    public var p50Seconds: Double
    public var p99Seconds: Double
    public var maxSeconds: Double
    public var firstSeconds: Double
    public var setupSeconds: Double
    /// Host time of turning the allowed set into the additive mask array of the logits (the per-step upload of the vocabulary-sized mask).
    public var uploadSeconds: Double
    public init(masks: Int, totalSeconds: Double, p50Seconds: Double, p99Seconds: Double, maxSeconds: Double, firstSeconds: Double, setupSeconds: Double, uploadSeconds: Double) {
        self.masks = masks
        self.totalSeconds = totalSeconds
        self.p50Seconds = p50Seconds
        self.p99Seconds = p99Seconds
        self.maxSeconds = maxSeconds
        self.firstSeconds = firstSeconds
        self.setupSeconds = setupSeconds
        self.uploadSeconds = uploadSeconds
    }
}

public struct ChatResult: Sendable {
    public let content: String
    public let promptTokens: Int
    public let cachedTokens: Int
    public let completionTokens: Int
    /// nil when the provider does not report it.
    public let finishReason: FinishReason?
    /// Seconds from the entry of `ChatModel.chat` to the first generated token, for the on-device models (the evaluation reads it);
    /// nil when not measured. The same starting point for every provider, so it includes loading, tokenisation and queueing.
    public let firstTokenSeconds: Double?
    /// The integrated model's own figure, from the start of its generation loop (excludes the setup above); nil for other providers.
    public let engineFirstTokenSeconds: Double?
    /// Grammar-work timing of a schema-constrained call on the integrated model (evaluation); nil otherwise.
    public var constraintTiming: ConstraintTiming?
    /// Where the time before the first token went on the integrated model (evaluation): tokenising the prompt, waiting for the kept
    /// prefix's lock and for the GPU, the prompt tokens that had to be read (the kept prefix is not counted), and the prefill chunks.
    public var breakdown: LatencyBreakdown?

    public init(content: String, promptTokens: Int, cachedTokens: Int, completionTokens: Int, finishReason: FinishReason? = nil,
                firstTokenSeconds: Double? = nil, engineFirstTokenSeconds: Double? = nil) {
        self.firstTokenSeconds = firstTokenSeconds
        self.engineFirstTokenSeconds = engineFirstTokenSeconds
        self.content = content
        self.promptTokens = promptTokens
        self.cachedTokens = cachedTokens
        self.completionTokens = completionTokens
        self.finishReason = finishReason
    }

    /// The answer stopped at the token limit and is incomplete.
    public var isTruncated: Bool { finishReason == .length }
}

/// Vauta's only network channel: to the configured model server and nothing else.
/// Every request goes through `AuditedSession`, which records it (metadata only)
/// in the Network Activity log.
///
/// - Destinations are fixed by the validated configuration (`LLMServerConfig`):
///   loopback on this Mac, or HTTPS to an address on the local network. URLs
///   are only built from `Endpoint` (or the profile's native paths on the same
///   origin) and re-checked before each request and on each response.
/// - HTTPS: TLS 1.3 minimum; ephemeral session with no cache, cookies,
///   credentials or proxy. Redirects are refused.
/// - Trust: a private CA bundle, when given, holds the ONLY anchors (no network
///   fetches during evaluation); otherwise the system anchors. With pins, the
///   leaf certificate's SPKI SHA-256 must also match one of them.
/// - For hosts given by name, the connected peer address must be private
///   (loopback for local mode); otherwise further requests are refused.
/// - The key (optional) is read from the Keychain for each request and never logged.
public final class LLMClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Keychain account of the server key (optional: local LM Studio or Ollama need none).
    public static let bearerAccount = ServerCredentials.bearerAccount
    /// Caps on what is accepted from the server.
    static let maxChatBytes = 2 << 20
    static let maxBodyBytes = 64 << 20

    enum Endpoint: String {
        case models = "models"
        case chat = "chat/completions"
        case embeddings = "embeddings"
    }

    private let bearer: @Sendable () throws -> String?
    private let protocolClasses: [AnyClass]?
    private let log: NetworkActivityLog
    private let lock = NSLock()
    private var _session: AuditedSession?
    private var _config: LLMServerConfig?
    private var _endpoints: [LLMRole: LLMServerConfig.Endpoint] = [:]
    private var _primary: LLMServerConfig.Endpoint?
    /// Set when a host name resolved outside the allowed network.
    private var _peerViolation: String?

    private var config: LLMServerConfig? { lock.withLock { _config } }
    private var primary: LLMServerConfig.Endpoint? { lock.withLock { _primary } }
    private var allEndpoints: [LLMServerConfig.Endpoint] {
        lock.withLock { (_primary.map { [$0] } ?? []) + Array(_endpoints.values) }
    }

    /// Created on first use (URLSession retains its delegate: this client lives as long as the app).
    private var session: AuditedSession {
        lock.withLock {
            if let s = _session { return s }
            let s = makeSession()
            _session = s
            return s
        }
    }

    private func makeSession() -> AuditedSession {
        let c = URLSessionConfiguration.ephemeral
        c.tlsMinimumSupportedProtocolVersion = .TLSv13
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCredentialStorage = nil
        c.connectionProxyDictionary = [kCFNetworkProxiesHTTPEnable: false, kCFNetworkProxiesHTTPSEnable: false,
                                       kCFNetworkProxiesProxyAutoConfigEnable: false, kCFNetworkProxiesProxyAutoDiscoveryEnable: false,
                                       kCFNetworkProxiesSOCKSEnable: false]
        c.httpMaximumConnectionsPerHost = 2
        c.waitsForConnectivity = false
        // No data for 15 min = down (reading a long prompt on a modest machine
        // takes minutes, and the server may send nothing meanwhile).
        c.timeoutIntervalForRequest = 900
        c.timeoutIntervalForResource = 3 * 3600
        if let protocolClasses { c.protocolClasses = protocolClasses }
        return AuditedSession(configuration: c, delegate: self, log: log)
    }

    public convenience init(config: LLMServerConfig? = nil,
                            bearer: @escaping @Sendable () throws -> String? = { try ServerCredentials.readBearer() }) {
        self.init(config: config, bearer: bearer, protocolClasses: nil)
    }

    /// `protocolClasses`: URL loading stubs for tests.
    init(config: LLMServerConfig?, bearer: @escaping @Sendable () throws -> String?, protocolClasses: [AnyClass]?,
         log: NetworkActivityLog = .shared) {
        self.bearer = bearer
        self.log = log
        self.protocolClasses = protocolClasses
        super.init()
        apply(config)
    }

    /// New configuration (or none): closes open connections.
    /// An invalid configuration counts as none.
    public func apply(_ config: LLMServerConfig?) {
        // The client does not know whether embeddings run on the server; an
        // empty embedding model only fails the embedding calls (`modelName`).
        let primary = try? config?.validated(embeddingsOnServer: false, keepingLegacyNames: true)
        let endpoints = (try? config?.validatedEndpoints(embeddingsOnServer: false, keepingLegacyNames: true)) ?? [:]
        let valid = primary != nil && !endpoints.isEmpty
        lock.withLock {
            _config = valid ? config : nil
            _primary = valid ? primary : nil
            _endpoints = valid ? endpoints : [:]
            _peerViolation = nil
            _session?.invalidateAndCancel()
            _session = nil
        }
    }

    /// Closes connections (e.g. after the key changes).
    public func reset() {
        lock.withLock {
            _session?.invalidateAndCancel()
            _session = nil
        }
    }

    public var isConfigured: Bool { primary != nil }

    /// Context window the configured chat models are loaded with.
    public var contextTokens: Int? { config?.contextTokens }

    private func modelName(_ role: LLMRole) throws -> String {
        guard let config else { throw LLMError.notConfigured }
        let name = config.model(for: role)
        if name.isEmpty { throw LLMError.notConfigured }
        return name
    }

    // MARK: API

    /// Models the server lists (`GET /models` on the main base URL, or on the role's own URL).
    public func models(for role: LLMRole? = nil, purpose: NetworkPurpose = .statusCheck) async throws -> [String] {
        let (data, _) = try await send(.models, role: role, body: nil, limit: 1 << 20, purpose: purpose)
        struct List: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
        guard let list = try? JSONDecoder().decode(List.self, from: data) else { throw LLMError.invalidResponse("model list") }
        return list.data.map(\.id)
    }

    /// Models listed by every base URL in use: the main one and each role's own
    /// (`roleBaseURLs`), without duplicates. A model served from a role URL is
    /// therefore not reported missing.
    public func allModels(purpose: NetworkPurpose = .statusCheck) async throws -> [String] {
        let (primary, endpoints) = lock.withLock { (_primary, _endpoints) }
        guard let primary else { throw LLMError.notConfigured }
        var bases = [primary.base]
        var roles: [LLMRole?] = [nil]
        for role in LLMRole.allCases {
            if let endpoint = endpoints[role], !bases.contains(endpoint.base) {
                bases.append(endpoint.base)
                roles.append(role)
            }
        }
        var out: [String] = []
        for role in roles {
            for id in try await models(for: role, purpose: purpose) where !out.contains(id) { out.append(id) }
        }
        return out
    }

    /// Streaming chat (SSE). `onProgress` receives the chunks generated so far
    /// (content + reasoning) to show progress. Cancellable.
    public func chat(_ messages: [ChatMessage], _ options: ChatOptions,
                     onProgress: (@Sendable (Int) -> Void)? = nil) async throws -> ChatResult {
        guard let config else { throw LLMError.notConfigured }
        let name = try options.modelOverride.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? modelName(options.model)
        let body = try ServerRequests.chatBody(model: name, messages: messages, options: options,
                                               profile: config.effectiveProfile)
        let request = try await preparedRequest(.chat, role: options.model, body: body, purpose: options.purpose)
        let (bytes, response) = try await perform { try await self.session.bytes(for: request, purpose: options.purpose) }
        try await check(response, bytes)
        var parser = ChatStreamParser()
        var lastReported = 0
        do {
            try await Self.lines(bytes) { line in
                let more = try parser.consume(line)
                if parser.produced >= lastReported + 16 {
                    lastReported = parser.produced
                    onProgress?(parser.produced)
                }
                return more
            }
            try parser.finish()
        } catch let e as LLMError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch {
            // A cut in the middle of the stream is a network failure (retryable).
            throw LLMError.network(from: error)
        }
        try Task.checkCancellation()
        if options.failOnTruncation, parser.finishReason == .length { throw LLMError.outputTruncated }
        return ChatResult(content: Self.strippingThinking(parser.content), promptTokens: parser.promptTokens,
                          cachedTokens: parser.cachedTokens, completionTokens: parser.completionTokens ?? parser.produced,
                          finishReason: parser.finishReason)
    }

    /// Some servers return the reasoning inside the content (`<think>…</think>`
    /// and similar): it is not part of the answer.
    static func strippingThinking(_ s: String) -> String {
        ModelOutput.strippingReasoning(s)
    }

    /// Raw embeddings (no query/document prefixes), shaped by the config's
    /// embedding policy. Kept for callers of the 0.1.x API.
    public func embed(_ inputs: [String]) async throws -> [[Float]] {
        try await embedBatch(inputs).vectors
    }

    /// Embeddings with the model family's query/document prefixes. The result
    /// carries the vector space, so callers can detect a model or size change.
    public func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> EmbeddingBatch {
        guard let config else { throw LLMError.notConfigured }
        let family = config.embeddingPolicy.family
        return try await embedBatch(texts.map { family.prepare($0, as: purpose) })
    }

    /// The purpose the next embedding requests are logged with (Network Activity): indexing the person's documents sets it.
    @TaskLocal static var embeddingPurpose: NetworkPurpose = .embeddings

    private func embedBatch(_ inputs: [String]) async throws -> EmbeddingBatch {
        guard let config else { throw LLMError.notConfigured }
        let model = try modelName(.embedding)
        guard !inputs.isEmpty else { return EmbeddingBatch(vectors: [], space: EmbeddingSpace(model: model, dimensions: 0)) }
        let body = try ServerRequests.embeddingsBody(model: model, inputs: inputs, legacy: config.profile == nil)
        let (data, _) = try await send(.embeddings, role: .embedding, body: body, limit: Self.maxBodyBytes, purpose: Self.embeddingPurpose)
        let raw = try Self.decodeEmbeddings(data, count: inputs.count)
        let policy = config.embeddingPolicy
        let vectors = try raw.map(policy.shape)
        guard let dims = vectors.first?.count, vectors.allSatisfy({ $0.count == dims }) else {
            throw LLMError.invalidResponse("embeddings of different sizes")
        }
        return EmbeddingBatch(vectors: vectors, space: EmbeddingSpace(model: model, dimensions: dims))
    }

    /// `data[].embedding` as floats or base64 little-endian float32, ordered by `index`.
    static func decodeEmbeddings(_ data: Data, count: Int) throws -> [[Float]] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["data"] as? [[String: Any]], items.count == count else {
            throw LLMError.invalidResponse("embeddings")
        }
        var out: [(Int, [Float])] = []
        for (i, item) in items.enumerated() {
            let index = item["index"] as? Int ?? i
            if let numbers = item["embedding"] as? [NSNumber] {
                out.append((index, numbers.map(\.floatValue)))
            } else if let b64 = item["embedding"] as? String, let bytes = Data(base64Encoded: b64), bytes.count % 4 == 0 {
                out.append((index, bytes.withUnsafeBytes { raw in
                    (0..<bytes.count / 4).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
                }))
            } else {
                throw LLMError.invalidResponse("embeddings")
            }
        }
        guard Set(out.map(\.0)).count == count else { throw LLMError.invalidResponse("embeddings") }
        return out.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// A native endpoint of the main server (`api/tags`, `props`…), allowed by
    /// the profile on the same origin. Returns nil for non-success statuses.
    func native(_ path: String, body: Data? = nil, limit: Int = 4 << 20, purpose: NetworkPurpose = .statusCheck) async throws -> Data? {
        guard let target = primary else { throw LLMError.notConfigured }
        let url = target.nativeRoot.appending(path: path)
        guard target.nativePaths.contains(path) else {
            await log.recordBlocked(purpose: purpose, url: url, method: body == nil ? "GET" : "POST", reason: .pathNotAllowed)
            throw LLMError.network(Self.destinationNotAllowed)
        }
        var request: URLRequest
        do {
            request = try authorizedRequest(url, target: target, body: body)
        } catch {
            await recordRefusal(error, url: url, body: body, purpose: purpose)
            throw error
        }
        request.timeoutInterval = 10
        let (bytes, response) = try await perform { try await self.session.bytes(for: request, purpose: purpose) }
        guard let http = response as? HTTPURLResponse, let url = http.url else { return nil }
        try Self.requireAllowed(url, target)
        guard (200..<300).contains(http.statusCode) else {
            await bytes.finish()
            return nil
        }
        return try await Self.collect(bytes, limit: limit)
    }

    /// Identifies the configured server, its models, their kind and context.
    public func inspect() async throws -> DiscoveredServer {
        guard let target = primary else { throw LLMError.notConfigured }
        let hint = config?.profile?.kind
        let fetch: ServerDiscovery.Fetch = { [self] path, body in
            switch path {
            case .openAI(let p):
                guard p == Endpoint.models.rawValue else { return nil }
                return try? await self.send(.models, role: nil, body: nil, limit: 4 << 20, purpose: .connectionTest).0
            case .native(let p):
                guard target.nativePaths.contains(p) else { return nil }
                return try? await self.native(p, body: body, purpose: .connectionTest)
            }
        }
        // A server that answers nothing at all is reported as an error, not as an empty server.
        let listed = try await allModels(purpose: .connectionTest)
        guard let server = await ServerDiscovery.identify(baseURL: target.base, hints: hint.map { [$0] } ?? [], fetch: fetch) else {
            throw LLMError.invalidResponse("model list")
        }
        // Models served from a role's own URL are offered too.
        let known = Set(server.models.map(\.id))
        let extra = listed.filter { !known.contains($0) }.map { DiscoveredModel(id: $0) }
        return extra.isEmpty ? server
            : DiscoveredServer(kind: server.kind, baseURL: server.baseURL, version: server.version, models: server.models + extra)
    }

    // MARK: Transport

    /// Whole response with a cap: reading stops as soon as it is exceeded.
    private func send(_ endpoint: Endpoint, role: LLMRole?, body: Data?, limit: Int,
                      purpose: NetworkPurpose) async throws -> (Data, HTTPURLResponse) {
        let request = try await preparedRequest(endpoint, role: role, body: body, purpose: purpose)
        let (bytes, response) = try await perform { try await self.session.bytes(for: request, purpose: purpose) }
        try await check(response, bytes)
        guard let http = response as? HTTPURLResponse, response.expectedContentLength <= Int64(limit) else {
            await bytes.finish()
            throw LLMError.tooLarge
        }
        return (try await Self.collect(bytes, limit: limit), http)
    }

    private static func collect(_ bytes: AuditedBytes, limit: Int) async throws -> Data {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { throw LLMError.tooLarge }
            }
        } catch let e as LLMError {
            await bytes.finish()
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LLMError.network(from: error)
        }
        return data
    }

    /// SSE lines with a per-line cap (an endless line cannot grow without bound).
    private static func lines(_ bytes: AuditedBytes, maxLine: Int = 1 << 20,
                              _ body: (String) throws -> Bool) async throws {
        do {
            try await scanLines(bytes, maxLine: maxLine, body)
        } catch {
            await bytes.finish()
            throw error
        }
        await bytes.finish()
    }

    private static func scanLines(_ bytes: AuditedBytes, maxLine: Int, _ body: (String) throws -> Bool) async throws {
        var line = Data()
        var total = 0
        for try await byte in bytes {
            total += 1
            guard total < maxBodyBytes else { throw LLMError.tooLarge }
            if byte == 0x0A {
                if line.last == 0x0D { line.removeLast() }
                if try !body(String(decoding: line, as: UTF8.self)) { return }
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
                if line.count > maxLine { throw LLMError.tooLarge }
            }
        }
        if !line.isEmpty { _ = try body(String(decoding: line, as: UTF8.self)) }
    }

    /// `makeRequest`, listing in the network audit a request that the destination rules refuse before it is sent.
    private func preparedRequest(_ endpoint: Endpoint, role: LLMRole?, body: Data?, purpose: NetworkPurpose) async throws -> URLRequest {
        do {
            return try makeRequest(endpoint, role: role, body: body)
        } catch {
            if let url = try? target(for: role).base.appending(path: endpoint.rawValue) {
                await recordRefusal(error, url: url, body: body, purpose: purpose)
            }
            throw error
        }
    }

    private func recordRefusal(_ error: Error, url: URL, body: Data?, purpose: NetworkPurpose) async {
        guard let reason = Self.blockReason(of: error) else { return }
        await log.recordBlocked(purpose: purpose, url: url, method: body == nil ? "GET" : "POST", reason: reason)
    }

    /// Which destination rule an error from building a request came from; nil for any other error.
    static func blockReason(of error: Error) -> NetworkBlockReason? {
        switch error as? LLMError {
        case .untrustedPeerAddress: .untrustedAddress
        case .network(let detail) where detail == destinationNotAllowed: .destinationNotAllowed
        default: nil
        }
    }

    static let destinationNotAllowed = "destination not allowed"

    /// Requests are only built for the configured base URLs.
    func makeRequest(_ endpoint: Endpoint, role: LLMRole? = nil, body: Data?) throws -> URLRequest {
        let target = try self.target(for: role)
        return try authorizedRequest(target.base.appending(path: endpoint.rawValue), target: target, body: body)
    }

    private func target(for role: LLMRole?) throws -> LLMServerConfig.Endpoint {
        let (primary, endpoints) = lock.withLock { (_primary, _endpoints) }
        guard let primary else { throw LLMError.notConfigured }
        return role.flatMap { endpoints[$0] } ?? primary
    }

    private func authorizedRequest(_ url: URL, target: LLMServerConfig.Endpoint, body: Data?) throws -> URLRequest {
        try Self.requireAllowed(url, target)
        if let address = lock.withLock({ _peerViolation }) { throw LLMError.untrustedPeerAddress(address) }
        var r = URLRequest(url: url)
        let stored: String?
        do {
            stored = try bearer()
        } catch let e as LLMError {
            throw e
        } catch {
            throw LLMError.keychainUnavailable   // locked or unavailable: retry later
        }
        if let token = stored?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            guard Self.isValidToken(token) else { throw LLMError.invalidStoredToken }
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        r.httpMethod = body == nil ? "GET" : "POST"
        r.httpBody = body
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(body == nil ? "application/json" : "application/json, text/event-stream", forHTTPHeaderField: "Accept")
        r.httpShouldHandleCookies = false
        r.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return r
    }

    /// Same scheme, host and port as the target; under its base path, or one of
    /// the profile's native paths under the native root.
    static func requireAllowed(_ url: URL, _ target: LLMServerConfig.Endpoint) throws {
        let scheme = url.scheme?.lowercased()
        let host = url.host()?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        let path = url.path()
        let root = target.nativeRoot.path()
        let isNative = path.hasPrefix(root) && target.nativePaths.contains(String(path.dropFirst(root.count)))
        guard scheme == (target.secure ? "https" : "http"), host == target.host, port == target.port,
              url.user == nil, url.password == nil, path.hasPrefix(target.base.path()) || isNative else {
            throw LLMError.network(Self.destinationNotAllowed)
        }
    }

    public static func isValidToken(_ t: String) -> Bool {
        !t.isEmpty && t.count <= 512 && t.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7f }
    }

    private func perform<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let e as LLMError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            if Task.isCancelled { throw CancellationError() }
            if let address = lock.withLock({ _peerViolation }) { throw LLMError.untrustedPeerAddress(address) }
            throw LLMError.network(String(localized: "connection refused (invalid certificate or destination)",
                                          comment: "Network error detail when TLS trust or the destination check fails"))
        } catch {
            throw LLMError.network(from: error)
        }
    }

    /// Checks the response destination and maps non-success statuses, reading
    /// a capped part of the body for the server's explanation.
    private func check(_ response: URLResponse, _ bytes: AuditedBytes) async throws {
        guard let http = response as? HTTPURLResponse, let url = http.url else { throw LLMError.invalidResponse("no HTTP response") }
        guard let target = allEndpoints.first(where: { (try? Self.requireAllowed(url, $0)) != nil }) else {
            throw LLMError.network(Self.destinationNotAllowed)
        }
        try Self.requireAllowed(url, target)
        guard !(200..<300).contains(http.statusCode) else { return }
        var body = Data()
        do {
            for try await byte in bytes {
                body.append(byte)
                if body.count >= ServerErrorBody.maxBytes { break }
            }
        } catch {
            // The status alone still says what happened.
        }
        await bytes.finish()
        throw ServerErrorBody.error(status: http.statusCode, body: body, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
    }

    // MARK: Trust and peer checks

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        ServerTrust.evaluate(challenge, allEndpoints)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        ServerTrust.evaluate(challenge, allEndpoints)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        nil
    }

    /// For hosts given by name, the address actually connected to must be
    /// private (or loopback in local mode); otherwise later requests are refused
    /// until the configuration is applied again.
    public func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let url = task.originalRequest?.url, let host = url.host()?.lowercased(),
              let mode = config?.mode, !ServerAddress.isIPLiteral(host) else { return }
        for address in metrics.transactionMetrics.compactMap(\.remoteAddress) where !Self.peerAllowed(address, mode: mode) {
            lock.withLock { _peerViolation = address }
        }
    }

    /// In remote mode the peer may also be a global address on a subnet this
    /// Mac is directly attached to (e.g. a `.local` name answered over IPv6).
    static func peerAllowed(_ address: String, mode: LLMServerConfig.Mode,
                            onLink: (String) -> Bool = ServerAddress.isOnLink) -> Bool {
        switch mode {
        case .local: ServerAddress.isLoopback(address)
        case .remote:
            ServerAddress.isIPLiteral(address) && !ServerAddress.isLoopback(address)
                && (ServerAddress.isPrivateOrLoopbackPeer(address) || onLink(address))
        }
    }
}
