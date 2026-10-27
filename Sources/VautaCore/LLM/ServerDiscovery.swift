// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

public enum ModelKind: String, Codable, Sendable {
    case chat
    case embedding
    case unknown
}

/// A model as a server lists it, with whatever the server's native API says about it.
public struct DiscoveredModel: Sendable, Equatable, Identifiable {
    public let id: String
    public var kind: ModelKind
    /// Context the model is (or will be) loaded with, when the server says.
    public var contextLength: Int?
    /// Largest context the model supports.
    public var maxContextLength: Int?
    /// Parameter count in billions, from the server or the name.
    public var parameterBillions: Double?
    /// Loaded in memory right now (LM Studio, Ollama), when known.
    public var loaded: Bool?

    public init(id: String, kind: ModelKind = .unknown, contextLength: Int? = nil, maxContextLength: Int? = nil,
                parameterBillions: Double? = nil, loaded: Bool? = nil) {
        self.id = id
        self.kind = kind
        self.contextLength = contextLength
        self.maxContextLength = maxContextLength
        self.parameterBillions = parameterBillions
        self.loaded = loaded
    }
}

public struct SuggestedRoles: Sendable, Equatable {
    public var fast: String?
    public var deep: String?
    public var embedding: String?
}

public struct DiscoveredServer: Sendable, Equatable {
    public let kind: ServerKind
    /// OpenAI base URL (`…/v1`).
    public let baseURL: URL
    public let version: String?
    public let models: [DiscoveredModel]
    public var suggestedRoles: SuggestedRoles { ServerDiscovery.suggestRoles(models) }

    public init(kind: ServerKind, baseURL: URL, version: String? = nil, models: [DiscoveredModel]) {
        self.kind = kind
        self.baseURL = baseURL
        self.version = version
        self.models = models
    }

    /// A local config for this server with the suggested models and its profile.
    public func suggestedConfig() -> LLMServerConfig {
        let roles = suggestedRoles
        let chatContext = [roles.fast, roles.deep].compactMap { name in models.first { $0.id == name }?.contextLength }.min()
        let context = chatContext.map { min(max($0, LLMServerConfig.contextRange.lowerBound), LLMServerConfig.contextRange.upperBound) }
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return LLMServerConfig(mode: .local, baseURL: base, fastModel: roles.fast ?? "", deepModel: roles.deep ?? "",
                               embeddingModel: roles.embedding ?? "", contextTokens: context ?? LLMServerConfig.defaultContext,
                               profile: .defaults(for: kind))
    }
}

/// Finds model servers running on this Mac and describes them. Only loopback
/// addresses are ever probed; servers on other computers are inspected only
/// when the user enters them (`LLMClient.inspect()`, with the full TLS rules).
public enum ServerDiscovery {
    /// A path to fetch from the server being identified.
    enum Path: Sendable, Hashable {
        /// Under the OpenAI base (`models`).
        case openAI(String)
        /// Under the native root (`api/tags`, `props`…).
        case native(String)
    }

    /// Fetches a path (GET, or POST with the body); nil on any failure or non-success status.
    typealias Fetch = @Sendable (Path, Data?) async -> Data?

    /// Well-known ports and the servers that use them, most likely first.
    static let knownPorts: [(port: Int, kinds: [ServerKind])] = [
        (1234, [.lmStudio]), (11434, [.ollama]), (8080, [.llamaCpp, .localAI, .mlx]), (8000, [.vllm]), (1337, [.jan]),
    ]

    /// Probes the well-known loopback ports concurrently with short timeouts.
    /// `ports` limits the probe to some of them (the guided setup asks only for LM Studio's and Ollama's).
    public static func scanLoopback(timeout: TimeInterval = 1.5, ports: Set<Int>? = nil) async -> [DiscoveredServer] {
        let session = loopbackSession(timeout: timeout)
        defer { session.invalidateAndCancel() }
        return await scanLoopback(session: session, timeout: timeout, ports: ports)
    }

    static func scanLoopback(session: AuditedSession, timeout: TimeInterval, ports: Set<Int>? = nil) async -> [DiscoveredServer] {
        await withTaskGroup(of: (Int, DiscoveredServer?).self) { group in
            for (port, kinds) in knownPorts where ports?.contains(port) ?? true {
                group.addTask {
                    let root = URL(string: "http://127.0.0.1:\(port)/")!
                    return (port, await identify(baseURL: root.appending(path: "v1/"), hints: kinds,
                                                 fetch: loopbackFetch(session: session, root: root, timeout: timeout)))
                }
            }
            var found: [(Int, DiscoveredServer)] = []
            for await (port, server) in group { if let server { found.append((port, server)) } }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Inspects a server the user typed, if it is on this Mac (`http://127.0.0.1:5000/v1`).
    public static func inspectLoopback(baseURL: String, timeout: TimeInterval = 3) async -> DiscoveredServer? {
        var raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") { raw.removeLast() }
        guard let base = URL(string: raw + "/"), base.scheme?.lowercased() == "http", let host = base.host(),
              ServerAddress.isLoopback(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))),
              base.user == nil, base.query == nil else { return nil }
        var rootPath = base.path()
        if rootPath.hasSuffix("/v1/") { rootPath.removeLast(3) }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = rootPath.isEmpty ? "/" : rootPath
        guard let root = components?.url else { return nil }
        let session = loopbackSession(timeout: timeout)
        defer { session.invalidateAndCancel() }
        let hints = knownPorts.first { $0.port == base.port }?.kinds ?? []
        return await identify(baseURL: base, hints: hints, fetch: loopbackFetch(session: session, root: root, timeout: timeout, purpose: .connectionTest))
    }

    static func loopbackSession(timeout: TimeInterval, protocolClasses: [AnyClass]? = nil,
                                log: NetworkActivityLog = .shared) -> AuditedSession {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.httpCookieStorage = nil
        c.urlCredentialStorage = nil
        c.connectionProxyDictionary = [kCFNetworkProxiesHTTPEnable: false, kCFNetworkProxiesHTTPSEnable: false,
                                       kCFNetworkProxiesProxyAutoConfigEnable: false, kCFNetworkProxiesProxyAutoDiscoveryEnable: false,
                                       kCFNetworkProxiesSOCKSEnable: false]
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout * 4
        if let protocolClasses { c.protocolClasses = protocolClasses }
        return AuditedSession(configuration: c, delegate: NoRedirects(), log: log)
    }

    /// Fetches from `root` on loopback only; never follows redirects.
    static func loopbackFetch(session: AuditedSession, root: URL, timeout: TimeInterval, purpose: NetworkPurpose = .discovery) -> Fetch {
        { path, body in
            let url: URL = switch path {
            case .openAI(let p): root.appending(path: "v1/" + p)
            case .native(let p): root.appending(path: p)
            }
            guard url.scheme == "http", let host = url.host(), ServerAddress.isLoopback(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
            else {
                await session.refuse(url, method: body == nil ? "GET" : "POST", purpose: purpose, reason: .destinationNotAllowed)
                return nil
            }
            var request = URLRequest(url: url, timeoutInterval: body == nil ? timeout : timeout * 2)
            request.httpMethod = body == nil ? "GET" : "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            guard let (data, response) = try? await session.data(for: request, purpose: purpose),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count <= 8 << 20
            else { return nil }
            return data
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    // MARK: Identification

    /// Identifies the server behind `baseURL` through `fetch`; nil when it does
    /// not answer the OpenAI model list.
    static func identify(baseURL: URL, hints: [ServerKind], fetch: Fetch) async -> DiscoveredServer? {
        guard let listData = await fetch(.openAI("models"), nil), let listed = json(listData)?["data"] as? [[String: Any]] else {
            return nil
        }
        var models = listed.compactMap { item -> DiscoveredModel? in
            guard let id = item["id"] as? String else { return nil }
            return DiscoveredModel(id: id, contextLength: item["max_model_len"] as? Int, parameterBillions: parameterBillions(fromName: id))
        }
        let owners = Set(listed.compactMap { ($0["owned_by"] as? String)?.lowercased() })

        var kind: ServerKind?
        var version: String?
        if let v = await fetch(.native("api/version"), nil).flatMap(json), let s = v["version"] as? String {
            kind = .ollama
            version = s
            models = await ollamaModels(fetch: fetch, fallback: models)
        } else if let v0 = await fetch(.native("api/v0/models"), nil).flatMap(json), let data = v0["data"] as? [[String: Any]] {
            kind = .lmStudio
            models = lmStudioModels(data, fallback: models)
        } else if let props = await fetch(.native("props"), nil).flatMap(json),
                  props["default_generation_settings"] != nil || props["n_ctx"] != nil || props["model_path"] != nil {
            kind = hints.contains(.jan) ? .jan : .llamaCpp
            let settings = props["default_generation_settings"] as? [String: Any]
            let nCtx = (settings?["n_ctx"] as? Int) ?? (props["n_ctx"] as? Int)
            for i in models.indices { models[i].contextLength = models[i].contextLength ?? nCtx; models[i].loaded = true }
        } else if let v = await fetch(.native("version"), nil).flatMap(json), let s = v["version"] as? String {
            version = s
            let looksVLLM = hints.contains(.vllm) || owners.contains("vllm") || models.contains { $0.contextLength != nil }
            kind = looksVLLM ? .vllm : .localAI
        }
        if kind == nil {
            if owners.contains("vllm") { kind = .vllm }
            else if owners.contains("llamacpp") { kind = .llamaCpp }
            else if hints.contains(.jan) { kind = .jan }
            else if models.contains(where: { $0.id.lowercased().contains("mlx") }) || hints == [.mlx] { kind = .mlx }
            else if hints.count == 1 { kind = hints[0] }
        }
        for i in models.indices where models[i].kind == .unknown { models[i].kind = kindFromName(models[i].id) }
        return DiscoveredServer(kind: kind ?? .openAICompatible, baseURL: baseURL, version: version, models: models)
    }

    /// Ollama: `/api/tags` lists the models, `/api/show` gives capabilities and
    /// context, `/api/ps` the context of loaded models.
    private static func ollamaModels(fetch: Fetch, fallback: [DiscoveredModel]) async -> [DiscoveredModel] {
        guard let tags = await fetch(.native("api/tags"), nil).flatMap(json)?["models"] as? [[String: Any]] else { return fallback }
        let running = (await fetch(.native("api/ps"), nil).flatMap(json)?["models"] as? [[String: Any]]) ?? []
        var loadedContext: [String: Int] = [:]
        for m in running {
            if let name = (m["name"] ?? m["model"]) as? String { loadedContext[name] = m["context_length"] as? Int ?? 0 }
        }
        var out: [DiscoveredModel] = []
        for tag in tags.prefix(64) {
            guard let name = (tag["name"] ?? tag["model"]) as? String else { continue }
            let details = tag["details"] as? [String: Any]
            var model = DiscoveredModel(id: name, parameterBillions: (details?["parameter_size"] as? String).flatMap(parameterBillions(fromSize:))
                                            ?? parameterBillions(fromName: name))
            if let body = try? JSONSerialization.data(withJSONObject: ["model": name]),
               let show = await fetch(.native("api/show"), body).flatMap(json) {
                let capabilities = Set(show["capabilities"] as? [String] ?? [])
                if capabilities.contains("embedding") { model.kind = .embedding }
                else if capabilities.contains("completion") { model.kind = .chat }
                if let info = show["model_info"] as? [String: Any] {
                    model.maxContextLength = info.first { $0.key.hasSuffix(".context_length") }?.value as? Int
                }
                // An explicit `num_ctx` in the Modelfile is the context Ollama loads with.
                if let parameters = show["parameters"] as? String {
                    model.contextLength = parameters.split(separator: "\n").compactMap { line -> Int? in
                        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                        return parts.count == 2 && parts[0] == "num_ctx" ? Int(parts[1]) : nil
                    }.first
                }
            }
            if let ctx = loadedContext[name] {
                model.loaded = true
                if ctx > 0 { model.contextLength = ctx }
            } else if !running.isEmpty {
                model.loaded = false
            }
            out.append(model)
        }
        return out.isEmpty ? fallback : out
    }

    /// LM Studio `/api/v0/models`: type (llm, vlm, embeddings), state and contexts.
    private static func lmStudioModels(_ data: [[String: Any]], fallback: [DiscoveredModel]) -> [DiscoveredModel] {
        let out = data.compactMap { item -> DiscoveredModel? in
            guard let id = item["id"] as? String else { return nil }
            let kind: ModelKind = switch item["type"] as? String {
            case "llm", "vlm": .chat
            case "embeddings", "embedding": .embedding
            default: .unknown
            }
            let loaded = (item["state"] as? String).map { $0 == "loaded" }
            return DiscoveredModel(id: id, kind: kind, contextLength: item["loaded_context_length"] as? Int,
                                   maxContextLength: item["max_context_length"] as? Int,
                                   parameterBillions: parameterBillions(fromName: id), loaded: loaded)
        }
        return out.isEmpty ? fallback : out
    }

    // MARK: Heuristics

    public static func kindFromName(_ id: String) -> ModelKind {
        let n = id.lowercased()
        let embeddingHints = ["embed", "bge-", "bge_", "/bge", "e5-", "gte-", "minilm", "multilingual-e5", "arctic-embed", "jina-embeddings", "rerank"]
        return embeddingHints.contains { n.contains($0) } || n.hasPrefix("bge") ? .embedding : .unknown
    }

    /// `qwen3:30b-a3b` → 30, `gemma-3-27b-it` → 27, `Qwen3-4B-MLX` → 4.
    static func parameterBillions(fromName name: String) -> Double? {
        let n = name.lowercased()
        guard let match = n.firstMatch(of: /(?:^|[^a-z0-9.])(\d+(?:\.\d+)?)b(?:$|[^a-z0-9])/) else { return nil }
        return Double(match.1)
    }

    /// Ollama `parameter_size`: "30.5B", "567M".
    static func parameterBillions(fromSize size: String) -> Double? {
        let s = size.trimmingCharacters(in: .whitespaces).uppercased()
        guard let unit = s.last, let value = Double(s.dropLast()) else { return nil }
        switch unit {
        case "B": return value
        case "M": return value / 1000
        case "T": return value * 1000
        default: return nil
        }
    }

    /// Embedding models in order of preference (multilingual retrieval quality).
    static let embeddingPreference: [EmbeddingFamily] = [.qwen3, .plain, .e5Instruct, .e5, .embeddingGemma, .nomic, .mxbai]

    /// fast = smallest chat model, deep = largest, embedding = best-known family.
    static func suggestRoles(_ models: [DiscoveredModel]) -> SuggestedRoles {
        let embeddings = models.filter { $0.kind == .embedding }
        let embedding = embeddings.min { a, b in
            rank(a.id) < rank(b.id)
        }?.id
        let chats = models.filter { $0.kind == .chat || ($0.kind == .unknown && kindFromName($0.id) != .embedding) }
        let sized = chats.sorted { ($0.parameterBillions ?? 0) < ($1.parameterBillions ?? 0) }
        return SuggestedRoles(fast: sized.first?.id, deep: sized.last?.id, embedding: embedding)
    }

    private static func rank(_ id: String) -> Int {
        let family = EmbeddingFamily.detect(modelName: id)
        let n = id.lowercased()
        // bge-m3 is the strong "plain" model; other plain models go last.
        if family == .plain { return n.contains("bge-m3") ? 1 : embeddingPreference.count }
        return embeddingPreference.firstIndex(of: family) ?? embeddingPreference.count
    }

    private static func json(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
