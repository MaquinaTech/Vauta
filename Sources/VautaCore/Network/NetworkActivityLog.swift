// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Why Vauta made a network request. Raw values are written to the exported
/// JSON, so they stay stable.
public enum NetworkPurpose: String, Codable, Sendable, CaseIterable {
    case minutes
    case liveNotes
    /// Expanding the user's shorthand notes from the transcript (live, at the end and on request).
    case notes
    case ask
    /// Questions heard in the meeting being recorded, checked and answered by the "While recording" model server. New raw value in W10.
    case liveAnswers
    /// Writing the suggested agenda of the pre-meeting brief with the person's model server. Never carries reminders' notes or the
    /// invitation's notes. New raw value with the brief: an exported log written by an older build never contains it.
    case brief
    case embeddings
    /// Indexing the person's documents: every indexed passage is sent once to the embedding model. Only when the person turned it
    /// on for a model server on the network.
    case documents
    case translation
    /// Downloading the optional search model (EmbeddingGemma 2) from huggingface.co, only when the person clicked Download.
    case modelDownload
    /// Downloading the optional integrated language model (Gemma 4 E4B) from huggingface.co, only when the person clicked Download.
    /// New raw value in 11b: an exported log written by an older build never contains it.
    case languageModelDownload
    case discovery
    case connectionTest
    case statusCheck
    case other
}

extension NetworkPurpose {
    /// A download of an optional model from Hugging Face (the search model or the language model).
    public var isModelDownload: Bool { self == .modelDownload || self == .languageModelDownload }
}

/// How a request ended when it did not produce an HTTP status.
public enum NetworkErrorKind: String, Codable, Sendable {
    case timedOut
    case unreachable
    case connectionLost
    case tls
    case cancelled
    case other

    init(_ error: Error) {
        switch (error as? URLError)?.code {
        case .timedOut: self = .timedOut
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet: self = .unreachable
        case .networkConnectionLost: self = .connectionLost
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired: self = .tls
        case .cancelled: self = .cancelled
        default: self = error is CancellationError ? .cancelled : .other
        }
    }
}

/// Why a request was refused before it was sent. A category only: never the content.
public enum NetworkBlockReason: String, Codable, Sendable, CaseIterable {
    /// The address is not the configured server (scheme, host, port or path).
    case destinationNotAllowed
    /// The server's name resolved to an address outside the allowed network.
    case untrustedAddress
    /// A path the selected server type does not use.
    case pathNotAllowed
}

/// One request Vauta made, as the audit shows it. It never holds content:
/// no body, prompt, header, key or query string, only where the request went,
/// what kind of request it was and how big and how long.
public struct NetworkActivityEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UInt64
    public let timestamp: Date
    public let purpose: NetworkPurpose
    public let scheme: String
    public let host: String
    public let port: Int
    public let method: String
    /// The URL path only (no query, no fragment).
    public let path: String
    /// Approximate body bytes sent (headers and protocol overhead are not counted).
    public internal(set) var bytesSent: Int
    /// Approximate body bytes received.
    public internal(set) var bytesReceived: Int
    /// HTTP status, once the server answered.
    public internal(set) var status: Int?
    /// Set when the request failed or was interrupted.
    public internal(set) var error: NetworkErrorKind?
    /// Seconds from sending to the end of the response; nil while in progress.
    public internal(set) var duration: TimeInterval?
    /// How many identical probes this row stands for (see `NetworkActivityLog`): repeated
    /// loopback discovery probes with the same destination, path and result are one row.
    public internal(set) var count: Int
    /// When the latest of those probes was made (`timestamp` is the first).
    public internal(set) var lastTimestamp: Date
    /// Set when the request was refused before it was sent; nothing went over the network.
    public let blocked: NetworkBlockReason?

    enum CodingKeys: String, CodingKey {
        case id, purpose, scheme, host, port, method, path, bytesSent, bytesReceived, status, error, duration, count, blocked
        case timestamp = "time"
        case lastTimestamp = "lastTime"
    }

    public var isInProgress: Bool { duration == nil }
    public var isSuccess: Bool { error == nil && blocked == nil && !isInProgress && status.map { (200..<300).contains($0) || isExpectedRedirect($0) } ?? false }

    /// A model download looks each file up at Hugging Face, which answers with a redirect to its download server: that is the
    /// answer Vauta asks for, not a failure.
    private func isExpectedRedirect(_ status: Int) -> Bool { purpose.isModelDownload && (300..<400).contains(status) }
    /// Whether the entry counts as a failed request in the totals (a blocked one never was a request).
    var isFailure: Bool { blocked == nil && !isExpectedProbeMiss && (error != nil || (status.map { !(200..<300).contains($0) && !isExpectedRedirect($0) } ?? false)) }

    /// A discovery probe that found nothing at the address: Vauta looks for model servers on this Mac, so a
    /// server that isn't running is the normal answer, not a fault.
    public var isExpectedProbeMiss: Bool { purpose == .discovery && error == .unreachable }

    /// Longest path kept. Paths come from fixed endpoint names; the cap is a guard.
    static let maxPathLength = 120

    public init(id: UInt64, timestamp: Date, purpose: NetworkPurpose, url: URL, method: String, bytesSent: Int,
                bytesReceived: Int = 0, status: Int? = nil, error: NetworkErrorKind? = nil, duration: TimeInterval? = nil,
                blocked: NetworkBlockReason? = nil, count: Int = 1, lastTimestamp: Date? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.lastTimestamp = lastTimestamp ?? timestamp
        self.count = max(1, count)
        self.blocked = blocked
        self.purpose = purpose
        let scheme = url.scheme?.lowercased() ?? "http"
        self.scheme = scheme
        self.host = (url.host(percentEncoded: false) ?? "unknown").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        self.port = url.port ?? (scheme == "https" ? 443 : 80)
        self.method = method.uppercased()
        let path = url.path(percentEncoded: true)
        self.path = String((path.isEmpty ? "/" : path).prefix(Self.maxPathLength))
        self.bytesSent = bytesSent
        self.bytesReceived = bytesReceived
        self.status = status
        self.error = error
        self.duration = duration
    }

    /// `127.0.0.1:1234`, `[::1]:8080`.
    public var destination: String { NetworkDestination.label(host: host, port: port) }

    /// Where the destination is: this Mac, the local network, a download the person started or outside.
    public var scope: NetworkDestination.Scope {
        let base = NetworkDestination.Scope(host: host)
        return purpose.isModelDownload && base == .outside ? .download : base
    }
}

extension Sequence where Element == NetworkActivityEntry {
    /// The requests behind these rows: a row that merged repeated probes counts each of them.
    public var requestCount: Int { reduce(0) { $0 + $1.count } }

    /// The rows for one purpose (all of them when `purpose` is nil).
    public func filtered(by purpose: NetworkPurpose?) -> [NetworkActivityEntry] {
        filter { purpose == nil || $0.purpose == purpose }
    }
}

/// A place Vauta connected to, with what went through it.
public struct NetworkDestination: Codable, Sendable, Equatable, Identifiable {
    public enum Scope: String, Codable, Sendable {
        /// This Mac (127.0.0.1, ::1, localhost).
        case thisMac
        /// A private address or a name that only exists on the local network.
        case localNetwork
        /// Anything else. Vauta's rules never allow it; shown so a violation cannot hide.
        case outside
        /// A server on the internet that the person reached on purpose by clicking Download (the search model): the exact hosts
        /// are on an allowlist, and every request to them is of the purpose `modelDownload`.
        case download

        init(host: String) {
            self = ServerAddress.isLoopback(host) ? .thisMac : ServerAddress.isPrivateNetworkHost(host) ? .localNetwork : .outside
        }
    }

    public let scheme: String
    public let host: String
    public let port: Int
    public var requests: Int
    public var failures: Int
    public var bytesSent: Int
    public var bytesReceived: Int

    public var id: String { "\(scheme)://\(Self.label(host: host, port: port))" }
    public var label: String { Self.label(host: host, port: port) }

    public internal(set) var scope: Scope

    init(scheme: String, host: String, port: Int, scope: Scope? = nil) {
        self.scheme = scheme
        self.host = host
        self.port = port
        requests = 0
        failures = 0
        bytesSent = 0
        bytesReceived = 0
        self.scope = scope ?? Scope(host: host)
    }

    static func label(host: String, port: Int) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// Entries grouped by destination, busiest first.
    public static func summarize(_ entries: [NetworkActivityEntry]) -> [NetworkDestination] {
        var byID: [String: NetworkDestination] = [:]
        for e in entries {
            let fresh = NetworkDestination(scheme: e.scheme, host: e.host, port: e.port, scope: e.scope)
            guard e.blocked == nil else { continue }
            var d = byID[fresh.id] ?? fresh
            // One request that is not a download makes the destination what its address says.
            if e.scope != d.scope { d.scope = Scope(host: d.host) }
            // A refused request never reached the destination: it is not a connection to it.
            d.requests += e.count
            if e.isFailure { d.failures += e.count }
            d.bytesSent += e.bytesSent
            d.bytesReceived += e.bytesReceived
            byID[d.id] = d
        }
        return byID.values.sorted { ($0.requests, $1.id) > ($1.requests, $0.id) }
    }
}

/// What Vauta sent over the network during this run of the app.
///
/// The one record of network activity, fed by `AuditedSession`, the only code
/// allowed to open connections. It keeps the last `capacity` entries in memory:
/// nothing is written to disk except an export the user asks for, and the
/// entries are gone when the app quits.
public actor NetworkActivityLog {
    public static let shared = NetworkActivityLog()
    public static let defaultCapacity = 1000
    /// Identical loopback discovery probes closer together than this are one row.
    static let defaultCoalesceWindow: TimeInterval = 60
    /// How far back a probe looks for the row it repeats.
    private static let coalesceLookback = 64

    private let capacity: Int
    private let coalesceWindow: TimeInterval
    private var entries: [NetworkActivityEntry] = []
    private var nextID: UInt64 = 1
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

    init(capacity: Int = NetworkActivityLog.defaultCapacity, coalesceWindow: TimeInterval = NetworkActivityLog.defaultCoalesceWindow) {
        self.capacity = max(1, capacity)
        self.coalesceWindow = coalesceWindow
    }

    // MARK: Recording

    /// Starts an entry and returns its id.
    func begin(purpose: NetworkPurpose, url: URL, method: String, bytesSent: Int) -> UInt64 {
        let id = nextID
        nextID += 1
        entries.append(NetworkActivityEntry(id: id, timestamp: Date(), purpose: purpose, url: url, method: method, bytesSent: bytesSent))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        notify()
        return id
    }

    /// Completes an entry. Ignored when the entry was cleared or has already dropped out of the buffer.
    func finish(_ id: UInt64, status: Int?, error: NetworkErrorKind?, bytesReceived: Int, duration: TimeInterval) {
        guard let i = entries.lastIndex(where: { $0.id == id }) else { return }
        entries[i].status = status
        entries[i].error = error
        entries[i].bytesReceived = bytesReceived
        entries[i].duration = duration
        coalesce(at: i)
        notify()
    }

    /// A request refused by the destination rules before anything was sent. Metadata only: where it
    /// would have gone, what kind of request it was and why it was refused.
    func recordBlocked(purpose: NetworkPurpose, url: URL, method: String, reason: NetworkBlockReason) {
        let id = nextID
        nextID += 1
        entries.append(NetworkActivityEntry(id: id, timestamp: Date(), purpose: purpose, url: url, method: method, bytesSent: 0,
                                            duration: 0, blocked: reason))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        notify()
    }

    /// Repeated loopback discovery probes (the guided setup polls every couple of seconds) with the same
    /// destination, path and result become one row with a count and the time of the latest, so polling
    /// cannot push everything else out of the buffer. The merged row moves to the newest position.
    private func coalesce(at index: Int) {
        let new = entries[index]
        guard new.purpose == .discovery, new.blocked == nil, new.scope == .thisMac else { return }
        let oldest = max(0, index - Self.coalesceLookback)
        guard let j = entries[oldest..<index].lastIndex(where: { old in
            old.purpose == .discovery && old.blocked == nil && !old.isInProgress
                && old.host == new.host && old.port == new.port && old.scheme == new.scheme
                && old.method == new.method && old.path == new.path
                && old.status == new.status && old.error == new.error
                && new.timestamp.timeIntervalSince(old.lastTimestamp) <= coalesceWindow
        }) else { return }
        var merged = entries[j]
        merged.count += new.count
        merged.lastTimestamp = new.lastTimestamp
        merged.bytesSent += new.bytesSent
        merged.bytesReceived += new.bytesReceived
        merged.duration = new.duration
        entries.remove(at: index)
        entries.remove(at: j)
        entries.append(merged)
    }

    // MARK: Reading

    /// Oldest first.
    public func snapshot() -> [NetworkActivityEntry] { entries }

    public func clear() {
        entries.removeAll()
        notify()
    }

    /// Yields whenever the log changes (coalesced: observers read `snapshot()` after each tick).
    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeObserver(id) }
            }
        }
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func notify() {
        for continuation in observers.values { continuation.yield() }
    }

    // MARK: Export

    /// The JSON the user saves from the Network Activity window.
    public func exportJSON(now: Date = Date()) throws -> Data {
        try NetworkActivityExport(entries: entries, now: now).encoded()
    }
}

/// The exported file: a header that says what it is, the entries and the per-destination totals.
struct NetworkActivityExport: Encodable {
    static let formatName = "vauta-network-activity"
    static let version = 1

    let format = Self.formatName
    let version = Self.version
    let exported: Date
    let scope = "this run of the app; in-memory only"
    let note = "Metadata only: no content, prompts, headers, keys or query strings."
    let destinations: [NetworkDestination]
    let entries: [NetworkActivityEntry]

    init(entries: [NetworkActivityEntry], now: Date) {
        self.exported = now
        self.entries = entries
        self.destinations = NetworkDestination.summarize(entries)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
