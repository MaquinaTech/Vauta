// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Security

/// Vauta's model server (OpenAI-compatible API: LM Studio, Ollama, llama.cpp,
/// mlx-lm, vLLM…). Two modes, chosen by whoever installs Vauta:
/// - `local`: on this Mac. Loopback only (127.0.0.1, ::1, localhost), so text
///   never leaves the computer; plain HTTP is allowed.
/// - `remote`: another computer on the local network. HTTPS only, private
///   addresses or local names only (never the internet), with an optional
///   private CA as the only trust anchor and optional certificate pins.
///   Hosts given by name need a private CA or a pin, because the name could
///   resolve anywhere; configs saved by the earlier version without either keep working
///   and report `SecurityWarning.hostNameWithoutPinnedTrust`.
///
/// Not secret, but changing it would divert meetings: it lives in the Keychain
/// (bound to Vauta's signature), never in UserDefaults. The key is stored apart
/// (`ServerCredentials`).
///
/// Stored as JSON under `llm-server-v1`. Fields added after 0.1.x (`profile`,
/// `roleBaseURLs`, `embedding`) are optional and omitted when nil, so a 0.1.x
/// config decodes, behaves and re-encodes exactly as before.
public struct LLMServerConfig: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable, CaseIterable { case local, remote }

    public var mode: Mode
    /// Base URL up to and including `/v1`, e.g. `http://127.0.0.1:1234/v1`.
    public var baseURL: String
    /// Private CA bundle in PEM (HTTPS only). Every certificate in it becomes
    /// an anchor, and they are then the ONLY trusted authorities.
    public var caPEM: String?
    /// SHA-256 (base64) of the server certificate's SubjectPublicKeyInfo; empty
    /// = no pin. Several are allowed (current + next, for rotation).
    public var pins: [String]
    /// Live notes while recording: fast, no reasoning.
    public var fastModel: String
    /// Final minutes and Ask: the best model the machine can run.
    public var deepModel: String
    /// Embeddings for Ask.
    public var embeddingModel: String
    /// Context (tokens) the server loads the chat models with (the smaller of the two).
    public var contextTokens: Int
    /// Request dialect; nil = written by the earlier version (`ServerProfile.legacy`).
    public var profile: ServerProfile?
    /// Optional base URLs per role (same mode rules as `baseURL`).
    public var roleBaseURLs: RoleBaseURLs?
    /// Optional embedding overrides.
    public var embedding: EmbeddingSettings?

    public static let account = "llm-server-v1"
    public static let defaultContext = 32_768
    public static let contextRange = 8_192...262_144

    public init(mode: Mode, baseURL: String, caPEM: String? = nil, pins: [String] = [],
                fastModel: String, deepModel: String, embeddingModel: String, contextTokens: Int = defaultContext,
                profile: ServerProfile? = nil, roleBaseURLs: RoleBaseURLs? = nil, embedding: EmbeddingSettings? = nil) {
        self.mode = mode
        self.baseURL = baseURL
        self.caPEM = caPEM
        self.pins = pins
        self.fastModel = fastModel
        self.deepModel = deepModel
        self.embeddingModel = embeddingModel
        self.contextTokens = contextTokens
        self.profile = profile
        self.roleBaseURLs = roleBaseURLs
        self.embedding = embedding
    }

    /// Templates for Settings (the user picks the models).
    public static let lmStudio = LLMServerConfig(mode: .local, baseURL: "http://127.0.0.1:1234/v1", fastModel: "", deepModel: "", embeddingModel: "")
    public static let ollama = LLMServerConfig(mode: .local, baseURL: "http://127.0.0.1:11434/v1", fastModel: "", deepModel: "", embeddingModel: "")
    public static let remoteTemplate = LLMServerConfig(mode: .remote, baseURL: "https://192.168.1.50:8443/v1", fastModel: "", deepModel: "", embeddingModel: "")

    /// The profile requests are built with.
    public var effectiveProfile: ServerProfile { profile ?? .legacy }

    /// Model name for a role, as the server lists it.
    public func model(for role: LLMRole) -> String {
        let name = switch role {
        case .fast: fastModel
        case .deep: deepModel
        case .embedding: embeddingModel
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    var embeddingPolicy: EmbeddingPolicy {
        EmbeddingPolicy(model: model(for: .embedding), settings: embedding, legacy: profile == nil)
    }

    // Optional fields have defaults: imported JSON may omit them.
    enum CodingKeys: String, CodingKey {
        case mode, baseURL, caPEM, pins, fastModel, deepModel, embeddingModel, contextTokens, profile, roleBaseURLs, embedding
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(Mode.self, forKey: .mode)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        caPEM = try c.decodeIfPresent(String.self, forKey: .caPEM)
        pins = try c.decodeIfPresent([String].self, forKey: .pins) ?? []
        fastModel = try c.decode(String.self, forKey: .fastModel)
        deepModel = try c.decode(String.self, forKey: .deepModel)
        embeddingModel = try c.decode(String.self, forKey: .embeddingModel)
        contextTokens = try c.decodeIfPresent(Int.self, forKey: .contextTokens) ?? Self.defaultContext
        profile = try c.decodeIfPresent(ServerProfile.self, forKey: .profile)
        roleBaseURLs = try c.decodeIfPresent(RoleBaseURLs.self, forKey: .roleBaseURLs)
        embedding = try c.decodeIfPresent(EmbeddingSettings.self, forKey: .embedding)
    }

    // MARK: Validation

    public enum Invalid: Error, Equatable, Sendable {
        case invalidURL
        case urlHasCredentialsOrQuery
        case unsupportedScheme
        case localRequiresLoopback
        case remoteRequiresHTTPS
        case remoteIsLoopback
        case notPrivateHost(String)
        case hostNameRequiresTrust(String)
        case missingModel(LLMRole)
        case contextOutOfRange
        case caRequiresHTTPS
        case invalidCA
        case invalidPin(String)
        case pinsRequireHTTPS
        case invalidEmbeddingDimensions
    }

    /// Conditions that are accepted for compatibility but deserve a warning in the UI.
    public enum SecurityWarning: Equatable, Sendable {
        /// A remote host given by name, trusted through public CAs only: the
        /// name could resolve outside the local network. Add a private CA or a pin.
        case hostNameWithoutPinnedTrust(String)
    }

    /// What the client uses: a checked destination and its trust material.
    public struct Endpoint: Sendable, Equatable {
        /// Ends in `/`: endpoint paths are appended to it.
        public let base: URL
        public let host: String
        public let port: Int
        public let secure: Bool
        /// Private CA certificates (DER); when present they are the only anchors.
        let caDERs: [Data]
        let pins: Set<String>
        /// Root for native endpoints (`/api/...`, `/props`): the base without its trailing `v1/`.
        let nativeRoot: URL
        /// Native paths allowed on this origin (from the server profile).
        let nativePaths: Set<String>
        /// The host is a name, not an IP literal: the peer address is checked after connecting.
        var hostIsName: Bool { !ServerAddress.isIPLiteral(host) }
    }

    /// Validates the main base URL. Throws `Invalid`.
    ///
    /// `embeddingsOnServer`: whether search by meaning runs on this server
    /// (`ModelProviderSettings.embeddings == .server`). Only then is the
    /// embedding model name required.
    public func validated(embeddingsOnServer: Bool = true) throws -> Endpoint {
        try validateCommon(embeddingsOnServer: embeddingsOnServer)
        return try endpoint(baseURL)
    }

    /// One endpoint per role (the main one unless the role has its own URL).
    public func validatedEndpoints(embeddingsOnServer: Bool = true) throws -> [LLMRole: Endpoint] {
        let main = try validated(embeddingsOnServer: embeddingsOnServer)
        var out: [LLMRole: Endpoint] = [:]
        for role in LLMRole.allCases {
            out[role] = try roleBaseURLs?[role].map(endpoint) ?? main
        }
        return out
    }

    /// Accepted but risky settings (see `SecurityWarning`).
    public var securityWarnings: [SecurityWarning] {
        guard mode == .remote, !hasPinnedTrust else { return [] }
        let hosts = ([baseURL] + LLMRole.allCases.compactMap { roleBaseURLs?[$0] }).compactMap(Self.host(of:))
        return Array(Set(hosts.filter { !ServerAddress.isIPLiteral($0) })).sorted().map { .hostNameWithoutPinnedTrust($0) }
    }

    private var hasPinnedTrust: Bool {
        !(caPEM?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || pins.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func validateCommon(embeddingsOnServer: Bool) throws {
        for role in LLMRole.allCases where embeddingsOnServer || role != .embedding {
            let v = model(for: role)
            guard !v.isEmpty, v.count <= 200, v.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
                throw Invalid.missingModel(role)
            }
        }
        guard Self.contextRange.contains(contextTokens) else { throw Invalid.contextOutOfRange }
        if let d = embedding?.dimensions, d < EmbeddingSettings.minimumDimensions || d > 16_384 {
            throw Invalid.invalidEmbeddingDimensions
        }
    }

    private static func host(of raw: String) -> String? {
        URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    private func endpoint(_ url: String) throws -> Endpoint {
        var raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") { raw.removeLast() }
        guard let c = URLComponents(string: raw), let scheme = c.scheme?.lowercased(), let host = c.host, !host.isEmpty else {
            throw Invalid.invalidURL
        }
        guard c.user == nil, c.password == nil, c.query == nil, c.fragment == nil else { throw Invalid.urlHasCredentialsOrQuery }
        guard scheme == "http" || scheme == "https" else { throw Invalid.unsupportedScheme }
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        switch mode {
        case .local:
            guard ServerAddress.isLoopback(h) else { throw Invalid.localRequiresLoopback }
        case .remote:
            guard scheme == "https" else { throw Invalid.remoteRequiresHTTPS }
            guard !ServerAddress.isLoopback(h) else { throw Invalid.remoteIsLoopback }
            guard ServerAddress.isPrivateNetworkHost(h) else { throw Invalid.notPrivateHost(h) }
            // New-format configs only; 0.1.x configs get a warning instead.
            if profile != nil, !ServerAddress.isIPLiteral(h), !hasPinnedTrust { throw Invalid.hostNameRequiresTrust(h) }
        }
        let port = c.port ?? (scheme == "https" ? 443 : 80)
        var caDERs: [Data] = []
        if let pem = caPEM?.trimmingCharacters(in: .whitespacesAndNewlines), !pem.isEmpty {
            guard scheme == "https" else { throw Invalid.caRequiresHTTPS }
            caDERs = Self.ders(fromPEM: pem)
            guard !caDERs.isEmpty, caDERs.allSatisfy({ SecCertificateCreateWithData(nil, $0 as CFData) != nil }) else {
                throw Invalid.invalidCA
            }
        }
        var pinSet = Set<String>()
        for p in pins.map({ $0.trimmingCharacters(in: .whitespaces) }) where !p.isEmpty {
            guard Data(base64Encoded: p)?.count == 32 else { throw Invalid.invalidPin(p) }
            pinSet.insert(p)
        }
        guard pinSet.isEmpty || scheme == "https" else { throw Invalid.pinsRequireHTTPS }
        guard var base = URL(string: raw + "/") else { throw Invalid.invalidURL }
        if base.path().isEmpty { base = base.appending(path: "/") }
        var rootPath = base.path()
        if rootPath.hasSuffix("/v1/") { rootPath.removeLast(3) }
        var rootComponents = URLComponents(url: base, resolvingAgainstBaseURL: false)
        rootComponents?.path = rootPath
        guard let nativeRoot = rootComponents?.url else { throw Invalid.invalidURL }
        return Endpoint(base: base, host: h, port: port, secure: scheme == "https", caDERs: caDERs, pins: pinSet,
                        nativeRoot: nativeRoot, nativePaths: effectiveProfile.kind.nativePaths)
    }

    /// Kept for callers of the 0.1.x API.
    static func isLoopback(_ h: String) -> Bool { ServerAddress.isLoopback(h) }
    static func isPrivateNetworkHost(_ h: String) -> Bool { ServerAddress.isPrivateNetworkHost(h) }

    /// Every certificate in a PEM bundle, in order. A malformed or unterminated
    /// block makes the whole bundle invalid (empty result), so a broken
    /// certificate is never silently left out of the trust anchors.
    static func ders(fromPEM pem: String) -> [Data] {
        var out: [Data] = []
        var body: [String]?
        for line in pem.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line == "-----BEGIN CERTIFICATE-----" {
                guard body == nil else { return [] }
                body = []
            } else if line == "-----END CERTIFICATE-----" {
                guard let b = body, let der = Data(base64Encoded: b.joined()), !der.isEmpty else { return [] }
                out.append(der)
                body = nil
            } else if body != nil {
                body?.append(line)
            }
        }
        return body == nil ? out : []
    }

    /// The first certificate of a PEM bundle.
    static func der(fromPEM pem: String) -> Data? { ders(fromPEM: pem).first }

    // MARK: Keychain

    /// The stored config; nil = not configured (a config that no longer
    /// decodes counts as not configured). Throws `LLMError.keychainUnavailable`
    /// when the Keychain is locked or access was cancelled: the config may
    /// exist, so callers keep what they have and retry later instead of
    /// treating the server as unconfigured.
    public static func load() throws -> LLMServerConfig? {
        try load(service: VautaIdentity.keychainService)
    }

    static func load(service: String) throws -> LLMServerConfig? {
        let json: String?
        do {
            json = try KeychainSecret.read(account, service: service)
        } catch {
            throw LLMError.keychainUnavailable
        }
        guard let json else { return nil }
        return try? JSONDecoder().decode(LLMServerConfig.self, from: Data(json.utf8))
    }

    /// Saves only a valid config; nil deletes it.
    public static func save(_ config: LLMServerConfig?, embeddingsOnServer: Bool = true) throws {
        try save(config, embeddingsOnServer: embeddingsOnServer, service: VautaIdentity.keychainService)
    }

    static func save(_ config: LLMServerConfig?, embeddingsOnServer: Bool = true, service: String) throws {
        guard let config else { KeychainSecret.delete(account, service: service); return }
        _ = try config.validatedEndpoints(embeddingsOnServer: embeddingsOnServer)
        let json = try JSONEncoder().encode(config)
        try KeychainSecret.write(String(decoding: json, as: UTF8.self), account: account, label: "Vauta model server", service: service)
    }
}

extension LLMServerConfig.Invalid: LocalizedError, CustomStringConvertible {
    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            String(localized: "The server URL isn’t valid (example: http://127.0.0.1:1234/v1).", comment: "Server config error")
        case .urlHasCredentialsOrQuery:
            String(localized: "The URL can’t contain a user name, password, query or fragment.", comment: "Server config error")
        case .unsupportedScheme:
            String(localized: "The URL must start with http:// or https://.", comment: "Server config error")
        case .localRequiresLoopback:
            String(localized: "“A model server on this Mac” only accepts 127.0.0.1, ::1 or localhost. For another computer, choose “A model server on your network”.",
                   comment: "Server config error")
        case .remoteRequiresHTTPS:
            String(localized: "A model server on your network must be reached over HTTPS, so meetings never cross the network unencrypted.",
                   comment: "Server config error")
        case .remoteIsLoopback:
            String(localized: "That address is this Mac: choose “A model server on this Mac”.", comment: "Server config error")
        case .notPrivateHost(let host):
            String(localized: "“\(host)” isn’t a local network address (10.x, 172.16–31.x, 192.168.x, 100.64–127.x, fc00::/7, fe80::/10, *.local, *.lan, *.home.arpa, *.internal or *.ts.net). Vauta never sends meetings to the internet.",
                   comment: "Server config error; argument is a host")
        case .hostNameRequiresTrust(let host):
            String(localized: "“\(host)” is a name that could point outside your network. Add the server’s private certificate authority or a certificate pin.",
                   comment: "Server config error; argument is a host")
        case .missingModel(let role):
            switch role {
            case .fast: String(localized: "Enter the fast model name exactly as the server lists it.", comment: "Server config error")
            case .deep: String(localized: "Enter the main model name exactly as the server lists it.", comment: "Server config error")
            case .embedding: String(localized: "Enter the name of the model for search by meaning exactly as the server lists it.", comment: "Server config error")
            }
        case .contextOutOfRange:
            String(localized: "The context length must be between 8K and 256K tokens.", comment: "Server config error")
        case .caRequiresHTTPS:
            String(localized: "A private certificate authority only applies to https:// addresses.", comment: "Server config error")
        case .invalidCA:
            String(localized: "The certificate authority isn’t a valid PEM certificate (-----BEGIN CERTIFICATE-----…).", comment: "Server config error")
        case .invalidPin(let pin):
            String(localized: "The pin “\(pin)” isn’t a base64 SHA-256 (44 characters).", comment: "Server config error; argument is the pin")
        case .pinsRequireHTTPS:
            String(localized: "Certificate pins only apply to https:// addresses.", comment: "Server config error")
        case .invalidEmbeddingDimensions:
            String(localized: "The size for search by meaning must be at least 256.", comment: "Server config error")
        }
    }

    public var description: String { errorDescription ?? "Invalid server configuration" }
}
