// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Where a server given by name really is, checked before anything is sent to it.
///
/// `URLSessionTaskMetrics` give the connected address only when a request has
/// finished, so checking the real requests would let the first one (its body
/// and the key) reach wherever the name resolved. Instead, the first request to
/// each name-based server on a session waits for a probe that carries nothing:
/// `GET <base>/models` with no body and no key (a 401 is fine). The probe's
/// metrics are awaited (`PeerWatch`, fulfilled by `didFinishCollecting`, never
/// by the order of other callbacks); the request goes out only once they have
/// arrived and every address in them is allowed. When they do not arrive in
/// time, or carry no address, nothing is sent (fails closed). IP literals need
/// no probe: the address is the one checked in the configuration.
///
/// What remains (SECURITY.md, Peer check): the probe checks the connection it
/// opened, which the next requests reuse while it stays open. URLSession may
/// still open another one, a second in parallel
/// (`httpMaximumConnectionsPerHost = 2`) or a new one after the idle one
/// closed, and it resolves the name again. A request on such a connection is
/// checked only when it completes, as every request is, and stops the ones
/// after it. TLS still runs first on that connection: with a private CA or a
/// pin (required for names in configurations newer than 0.1.x), a server
/// without the expected certificate never receives the request.
extension LLMClient {
    /// Most of a probe's answer that is read (and dropped).
    static let maxProbeBytes = 1 << 20

    /// The session to send a request to `target` on, once the peer of a name-based host is known to be allowed.
    func checkedSession(for target: LLMServerConfig.Endpoint) async throws -> AuditedSession {
        let (session, gate) = connection
        guard !ServerAddress.isIPLiteral(target.host), let mode = config?.mode else { return session }
        let key = "\(target.secure ? "https" : "http")://\(target.host):\(target.port)"
        try await gate.check(key) { try await self.probe(target, on: session, mode: mode) }
        try Task.checkCancellation()
        return session
    }

    /// The stored key as it would be sent, for redacting it from server messages; nil when there is none.
    var storedToken: String? {
        guard let token = (try? bearer())?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return nil }
        return token
    }

    /// One request without body or key; throws unless its metrics name only allowed peers.
    private func probe(_ target: LLMServerConfig.Endpoint, on session: AuditedSession, mode: LLMServerConfig.Mode) async throws {
        let url = target.base.appending(path: Endpoint.models.rawValue)
        try Self.requireAllowed(url, target)
        if let address = peerViolation { throw LLMError.untrustedPeerAddress(address) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let watch = PeerWatch(addresses: peerAddresses)
        let (bytes, response) = try await perform { try await session.bytes(for: request, purpose: .connectionTest, delegate: watch) }
        guard let answered = response.url, (try? Self.requireAllowed(answered, target)) != nil else {
            await bytes.finish()
            throw LLMError.network(Self.destinationNotAllowed)
        }
        // Read to the end, whatever the status: the metrics come when the task completes.
        var read = 0
        do {
            for try await _ in bytes {
                read += 1
                if read > Self.maxProbeBytes { throw LLMError.tooLarge }
            }
        } catch let e as LLMError {
            await bytes.finish()
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LLMError.network(from: error)
        }
        guard let addresses = await watch.addresses(within: peerCheckTimeout), !addresses.isEmpty else {
            throw LLMError.network(Self.connectionRefused)
        }
        if let outside = addresses.first(where: { !Self.peerAllowed($0, mode: mode) }) {
            recordPeerViolation(outside)
            throw LLMError.untrustedPeerAddress(outside)
        }
    }
}

/// The name-based servers a session has checked. Requests that arrive while a probe runs wait for the same probe; a
/// failed probe is not remembered, so the next request tries again.
actor PeerGate {
    private var allowed: Set<String> = []
    private var running: [String: Task<Void, Error>] = [:]

    func check(_ key: String, probe: @escaping @Sendable () async throws -> Void) async throws {
        if allowed.contains(key) { return }
        let task = running[key] ?? Task { try await probe() }
        running[key] = task
        do {
            try await task.value
            allowed.insert(key)
            if running[key] == task { running[key] = nil }
        } catch {
            if running[key] == task { running[key] = nil }
            throw error
        }
    }
}

/// The task delegate of one probe: keeps the peer addresses of its metrics and hands them to the one waiter.
/// `@unchecked Sendable`: every stored variable is read and written under `lock`.
final class PeerWatch: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let extract: @Sendable (URLSessionTaskMetrics) -> [String]
    private let lock = NSLock()
    private var found: [String]?
    private var waiter: CheckedContinuation<[String]?, Never>?
    private var timer: Task<Void, Never>?

    init(addresses: @escaping @Sendable (URLSessionTaskMetrics) -> [String]) {
        extract = addresses
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let addresses = extract(metrics)
        let (waiter, timer) = lock.withLock {
            found = addresses
            defer { (self.waiter, self.timer) = (nil, nil) }
            return (self.waiter, self.timer)
        }
        timer?.cancel()
        waiter?.resume(returning: addresses)
    }

    /// The addresses once the metrics are in, or nil when they are not within `timeout`.
    func addresses(within timeout: Duration) async -> [String]? {
        await withCheckedContinuation { continuation in
            let ready: [String]? = lock.withLock {
                if let found { return found }
                waiter = continuation
                timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    if !Task.isCancelled { self?.expire() }
                }
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    private func expire() {
        let waiter = lock.withLock {
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(returning: nil)
    }
}
