// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Finds the model servers running on this Mac. A protocol so tests can stub it.
public protocol ServerScanning: Sendable {
    func scan() async -> [DiscoveredServer]
}

/// The production scanner: read-only requests to `127.0.0.1`, only on the ports of the apps the guide covers.
public struct LoopbackServerScanner: ServerScanning {
    public init() {}

    public func scan() async -> [DiscoveredServer] {
        await ServerDiscovery.scanLoopback(ports: Set(LocalModelApp.allCases.map(\.serverKind.defaultPort)))
    }
}

/// A server and models ready to be saved.
public struct SetupCandidate: Equatable, Sendable {
    public let config: LLMServerConfig
    public let serverKind: ServerKind
    public let mainModel: String
    public let fastModel: String
    /// False when the server did not say which context the models load with (for example a model that is not loaded yet).
    public let contextVerified: Bool
}

/// A model found with less context than Vauta needs.
public struct ContextShortfall: Equatable, Sendable {
    public let serverKind: ServerKind
    public let modelID: String
    public let model: LocalModel
    public let current: Int
    public let required: Int
}

/// Where the guide stands, from what the servers report.
public enum SetupStatus: Equatable, Sendable {
    /// No scan has finished yet.
    case searching
    /// The app's server does not answer.
    case serverNotRunning
    /// The server runs but has none of the recommended models.
    case noSuitableModel(serverKind: ServerKind)
    case contextTooSmall(ContextShortfall)
    case ready(SetupCandidate)

    fileprivate var rank: Int {
        switch self {
        case .ready: 3
        case .contextTooSmall: 2
        case .noSuitableModel: 1
        case .searching, .serverNotRunning: 0
        }
    }
}

/// What the watcher looks for.
public struct SetupConfiguration: Equatable, Sendable {
    public var app: LocalModelApp
    public var recommendation: ModelRecommendation
    /// Whether the fast model is wanted too (`large` tier); false = "one model only".
    public var includeFastModel: Bool
    /// The saved server configuration, to keep its embedding model when the destination is the same.
    public var existing: LLMServerConfig?

    public init(app: LocalModelApp, recommendation: ModelRecommendation, includeFastModel: Bool = true, existing: LLMServerConfig? = nil) {
        self.app = app
        self.recommendation = recommendation
        self.includeFastModel = includeFastModel
        self.existing = existing
    }
}

public enum SetupEvaluation {
    /// The best result across the servers found. A server of the chosen app wins ties; servers of
    /// another kind count only when they already hold a recommended model.
    public static func evaluate(_ servers: [DiscoveredServer], configuration: SetupConfiguration) -> SetupStatus {
        var best: (status: SetupStatus, preferred: Bool)?
        for server in servers {
            let preferred = server.kind == configuration.app.serverKind
            let status = evaluate(server, configuration: configuration)
            if case .noSuitableModel = status, !preferred { continue }
            if let current = best, (current.status.rank, current.preferred ? 1 : 0) >= (status.rank, preferred ? 1 : 0) { continue }
            best = (status, preferred)
        }
        return best?.status ?? .serverNotRunning
    }

    static func evaluate(_ server: DiscoveredServer, configuration: SetupConfiguration) -> SetupStatus {
        let chat = server.models.filter { $0.kind != .embedding }
        func find(_ model: LocalModel) -> DiscoveredModel? { chat.first { model.matches(modelID: $0.id) } }
        let acceptable = configuration.recommendation.acceptable
        guard let (mainSpec, main) = acceptable.lazy.compactMap({ spec in find(spec).map { (spec, $0) } }).first else {
            return .noSuitableModel(serverKind: server.kind)
        }
        var fast = main
        if configuration.includeFastModel, let fastSpec = configuration.recommendation.fast, let found = find(fastSpec) { fast = found }

        let chosen = [main, fast]
        let known = chosen.compactMap(\.contextLength)
        if let smallest = known.min(), smallest < ModelSetupGuide.requiredContext {
            let short = chosen.first { $0.contextLength == smallest } ?? main
            return .contextTooSmall(ContextShortfall(serverKind: server.kind, modelID: short.id, model: mainSpec, current: smallest,
                                                     required: ModelSetupGuide.requiredContext))
        }

        var config = server.suggestedConfig()
        config.fastModel = fast.id
        config.deepModel = main.id
        let range = LLMServerConfig.contextRange
        config.contextTokens = known.min().map { min(max($0, range.lowerBound), range.upperBound) } ?? ModelSetupGuide.requiredContext
        // Search by meaning stays as it is: keep the embedding model of the same server, with its settings
        // (dimensions, prefixes) and its own address if it had one, so the search index stays valid.
        if let existing = configuration.existing, ServerDraftComparison.sameBase(existing.baseURL, config.baseURL) {
            config.embeddingModel = existing.embeddingModel
            config.embedding = existing.embedding
            if let embeddingURL = existing.roleBaseURLs?.embedding { config.roleBaseURLs = RoleBaseURLs(embedding: embeddingURL) }
        }
        return .ready(SetupCandidate(config: config, serverKind: server.kind, mainModel: main.id, fastModel: fast.id,
                                     contextVerified: known.count == chosen.count))
    }
}

enum ServerDraftComparison {
    static func sameBase(_ a: String, _ b: String) -> Bool {
        func normalized(_ s: String) -> String {
            var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while t.hasSuffix("/") { t.removeLast() }
            return t
        }
        return !normalized(a).isEmpty && normalized(a) == normalized(b)
    }
}

/// Polls the scanner while it is started, and only then. Started when the guide appears, stopped when it
/// closes, the onboarding page changes or the app relocks; `stop()` cancels a scan in flight.
@MainActor
public final class ModelSetupWatcher {
    public private(set) var status: SetupStatus = .searching
    public private(set) var isActive = false
    /// Called on the main actor whenever the status is recomputed (also when it is unchanged).
    public var onUpdate: (@MainActor (SetupStatus) -> Void)?
    public var configuration: SetupConfiguration {
        didSet { if configuration != oldValue, let servers = lastServers { publish(servers) } }
    }

    private let scanner: any ServerScanning
    private let interval: Duration
    private var task: Task<Void, Never>?
    private var lastServers: [DiscoveredServer]?

    public init(scanner: any ServerScanning = LoopbackServerScanner(), interval: Duration = .seconds(3),
                configuration: SetupConfiguration) {
        self.scanner = scanner
        self.interval = interval
        self.configuration = configuration
    }

    public func start() {
        guard task == nil else { return }
        isActive = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let scanner = self?.scanner else { return }
                let servers = await scanner.scan()
                guard !Task.isCancelled, let self else { return }
                self.publish(servers)
                try? await Task.sleep(for: self.interval)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        isActive = false
    }

    private func publish(_ servers: [DiscoveredServer]) {
        lastServers = servers
        status = SetupEvaluation.evaluate(servers, configuration: configuration)
        onUpdate?(status)
    }
}
