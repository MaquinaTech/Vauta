// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Synchronization

/// THE choke point: every network request Vauta makes goes through this type,
/// and each one is recorded in a `NetworkActivityLog` (metadata only).
///
/// This file is the only one allowed to create a URL session, start a URL
/// task or open a socket. A test scans the sources and fails if any other file
/// does, so new code cannot reach the network without being audited.
final class AuditedSession: Sendable {
    private let session: URLSession
    private let log: NetworkActivityLog
    /// Starting a task on an invalidated session raises an Objective-C exception (which nothing can catch), so a request that races
    /// with a delete, a cancel, a failure or a new configuration ends as cancelled instead: no task starts once `invalidateAndCancel`
    /// was called, and the URL session itself is invalidated only when no request can still be creating its task.
    private let state = Mutex(Lifecycle())

    private struct Lifecycle {
        /// `invalidateAndCancel` was called: no new task starts.
        var invalidated = false
        /// `bytes` and `data` calls past that check that are inside URLSession's own async call, which creates their task.
        var starting = 0
        /// The URL session was invalidated.
        var closed = false
    }

    init(configuration: URLSessionConfiguration, delegate: URLSessionDelegate? = nil, log: NetworkActivityLog = .shared) {
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.log = log
    }

    /// Cancels every task and lets no new one start. While a `bytes` or `data` call may still be creating its task, the tasks that
    /// exist are cancelled now and the URL session is invalidated when the last of those calls returns. A task such a call creates
    /// just after this is not in that list: it runs until its call returns (`bytes` at the response headers, `data` at the end of the
    /// body), and is cancelled then, with the URL session.
    func invalidateAndCancel() {
        state.withLock { s in
            s.invalidated = true
            if s.starting == 0 { close(&s) } else { session.getAllTasks { tasks in tasks.forEach { $0.cancel() } } }
        }
    }

    private func close(_ s: inout Lifecycle) {
        guard !s.closed else { return }
        s.closed = true
        session.invalidateAndCancel()
    }

    /// One of URLSession's async calls, which create their task inside: refused with `CancellationError` once the session is
    /// invalidated, and counted until it returns (its task exists by then), so the URL session is not invalidated in between.
    private func starting<T>(_ work: () async throws -> T) async throws -> T {
        try state.withLock { s in
            guard !s.invalidated else { throw CancellationError() }
            s.starting += 1
        }
        defer {
            state.withLock { s in
                s.starting -= 1
                if s.invalidated, s.starting == 0 { close(&s) }
            }
        }
        return try await work()
    }

    /// Lists a request that the destination rules refused before it was sent (nothing went out).
    func refuse(_ url: URL, method: String, purpose: NetworkPurpose, reason: NetworkBlockReason) async {
        await log.recordBlocked(purpose: purpose, url: url, method: method, reason: reason)
    }

    /// A streamed response. The entry completes when the body ends, fails or is abandoned. `delegate` receives this
    /// task's events first (the session's delegate gets the ones it does not implement).
    func bytes(for request: URLRequest, purpose: NetworkPurpose,
               delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (AuditedBytes, URLResponse) {
        let call = await begin(request, purpose)
        do {
            let (bytes, response) = try await starting { try await session.bytes(for: request, delegate: delegate) }
            let tracker = ActivityTracker(call: call, status: (response as? HTTPURLResponse)?.statusCode)
            return (AuditedBytes(base: bytes, tracker: tracker), response)
        } catch {
            await call.finish(status: nil, error: Self.kind(of: error), bytesReceived: 0)
            throw error
        }
    }

    /// A whole response in memory.
    func data(for request: URLRequest, purpose: NetworkPurpose) async throws -> (Data, URLResponse) {
        let call = await begin(request, purpose)
        do {
            let (data, response) = try await starting { try await session.data(for: request) }
            await call.finish(status: (response as? HTTPURLResponse)?.statusCode, error: nil, bytesReceived: data.count)
            return (data, response)
        } catch {
            await call.finish(status: nil, error: Self.kind(of: error), bytesReceived: 0)
            throw error
        }
    }

    /// A response streamed to `sink` in chunks, for downloads too large to hold in memory. `accept` sees the response first
    /// and can refuse it: the task is then cancelled before any body is read (a 200 for a range request never downloads
    /// 1.5 GB) and `AuditedStreamError.refused` is thrown. Redirects are never followed: the 3xx response is returned, and
    /// the caller decides whether its `Location` is allowed. `sink` runs on the session's queue; if it throws, the task is
    /// cancelled and the error is rethrown.
    func stream(_ request: URLRequest, purpose: NetworkPurpose, accept: @escaping @Sendable (HTTPURLResponse) -> Bool,
                sink: @escaping @Sendable (Data) throws -> Void) async throws -> HTTPURLResponse {
        let call = await begin(request, purpose)
        let handler = StreamHandler(accept: accept, sink: sink)
        do {
            let response: HTTPURLResponse = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, Error>) in
                    // Checked and started under the lock `invalidateAndCancel` takes: a session is never invalidated in between.
                    let task: URLSessionDataTask? = state.withLock { s in s.invalidated ? nil : session.dataTask(with: request) }
                    guard let task else { continuation.resume(throwing: CancellationError()); return }
                    handler.start(task, continuation)
                }
            } onCancel: { handler.cancel() }
            await call.finish(status: response.statusCode, error: nil, bytesReceived: handler.received)
            return response
        } catch {
            await call.finish(status: handler.statusCode, error: error is AuditedStreamError ? nil : Self.kind(of: error), bytesReceived: handler.received)
            throw error
        }
    }

    /// How a request that got no response failed. A connection cancelled while the
    /// caller was still waiting was refused by the session's trust check (the
    /// delegate cancels the TLS challenge), not stopped by the user.
    static func kind(of error: Error, callerCancelled: Bool = Task.isCancelled) -> NetworkErrorKind {
        let kind = NetworkErrorKind(error)
        return kind == .cancelled && !callerCancelled && error is URLError ? .tls : kind
    }

    private func begin(_ request: URLRequest, _ purpose: NetworkPurpose) async -> ActivityCall {
        // Only the size of the body is read: its content never reaches the log.
        let id = await log.begin(purpose: purpose, url: request.url ?? URL(fileURLWithPath: "/"),
                                 method: request.httpMethod ?? "GET", bytesSent: request.httpBody?.count ?? 0)
        return ActivityCall(log: log, id: id, start: .now)
    }
}

/// One entry being written.
struct ActivityCall: Sendable {
    let log: NetworkActivityLog
    let id: UInt64
    let start: ContinuousClock.Instant

    func finish(status: Int?, error: NetworkErrorKind?, bytesReceived: Int) async {
        await log.finish(id, status: status, error: error, bytesReceived: bytesReceived, duration: seconds(since: start))
    }

    func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

/// Counts a streamed body and completes the entry exactly once: at the end of the
/// stream, at a failure, on `finish()`, or, for a stream dropped half-read, when
/// the last reference goes away.
final class ActivityTracker: @unchecked Sendable {
    private let call: ActivityCall
    private let status: Int?
    private let lock = NSLock()
    private var done = false
    /// Written only by the single task reading the stream.
    var received = 0

    init(call: ActivityCall, status: Int?) {
        self.call = call
        self.status = status
    }

    private func claim() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }

    func finish(error: NetworkErrorKind?) async {
        guard claim() else { return }
        await call.finish(status: status, error: error, bytesReceived: received)
    }

    deinit {
        guard claim() else { return }
        let (call, status, received) = (call, status, received)
        Task { await call.finish(status: status, error: nil, bytesReceived: received) }
    }
}

/// The bytes of a response, counted as they are read.
struct AuditedBytes: AsyncSequence {
    typealias Element = UInt8

    let base: URLSession.AsyncBytes
    let tracker: ActivityTracker

    /// Completes the entry when the caller stops reading before the end.
    func finish() async { await tracker.finish(error: nil) }

    func makeAsyncIterator() -> Iterator { Iterator(base: base.makeAsyncIterator(), tracker: tracker) }

    struct Iterator: AsyncIteratorProtocol {
        var base: URLSession.AsyncBytes.AsyncIterator
        let tracker: ActivityTracker

        mutating func next() async throws -> UInt8? {
            do {
                guard let byte = try await base.next() else {
                    await tracker.finish(error: nil)
                    return nil
                }
                tracker.received += 1
                return byte
            } catch {
                await tracker.finish(error: NetworkErrorKind(error))
                throw error
            }
        }
    }
}


enum AuditedStreamError: Error {
    /// `accept` refused the response; nothing of its body was read.
    case refused(HTTPURLResponse)
}

/// The per-task delegate of `AuditedSession.stream`: shows the response to `accept`, hands the body to `sink` in chunks and
/// never follows a redirect.
private final class StreamHandler: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let accept: @Sendable (HTTPURLResponse) -> Bool
    private let sink: @Sendable (Data) throws -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var failure: Error?
    private var refused = false
    private var cancelledEarly = false
    private var _received = 0

    init(accept: @escaping @Sendable (HTTPURLResponse) -> Bool, sink: @escaping @Sendable (Data) throws -> Void) {
        self.accept = accept
        self.sink = sink
    }

    var received: Int { lock.withLock { _received } }
    var statusCode: Int? { lock.withLock { response?.statusCode } }

    func start(_ task: URLSessionDataTask, _ continuation: CheckedContinuation<HTTPURLResponse, Error>) {
        let cancelled: Bool = lock.withLock {
            self.task = task
            self.continuation = continuation
            return cancelledEarly
        }
        task.delegate = self
        if cancelled { task.cancel() } else { task.resume() }
    }

    func cancel() {
        let task: URLSessionDataTask? = lock.withLock {
            cancelledEarly = true
            return self.task
        }
        task?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            lock.withLock { failure = URLError(.badServerResponse) }
            completionHandler(.cancel)
            return
        }
        lock.withLock { self.response = http }
        if accept(http) {
            completionHandler(.allow)
        } else {
            lock.withLock { refused = true }
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { _received += data.count }
        do { try sink(data) } catch {
            lock.withLock { failure = error }
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, response, failure, refused): (CheckedContinuation<HTTPURLResponse, Error>?, HTTPURLResponse?, Error?, Bool) = lock.withLock {
            defer { self.continuation = nil }
            return (self.continuation, self.response, self.failure, self.refused)
        }
        guard let continuation else { return }
        if let failure { continuation.resume(throwing: failure) }
        else if refused, let response { continuation.resume(throwing: AuditedStreamError.refused(response)) }
        else if let error { continuation.resume(throwing: error) }
        else if let response { continuation.resume(returning: response) }
        else { continuation.resume(throwing: URLError(.badServerResponse)) }
    }
}
