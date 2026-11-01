// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Synchronization

/// The outcome of a race between some work and a timer: the first to finish wins, the other is cancelled and never awaited.
/// The continuation is resumed and the cancelers are called outside the lock.
private final class RaceBox<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, Error>?
        var early: Result<T, Error>?
        var finished = false
        var cancelers: [@Sendable () -> Void] = []
    }
    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<T, Error>) {
        let early = state.withLock { s -> Result<T, Error>? in
            if s.early == nil { s.continuation = continuation }
            return s.early
        }
        if let early { continuation.resume(with: early) }
    }

    func addCanceler(_ canceler: @escaping @Sendable () -> Void) {
        let already = state.withLock { s in
            if !s.finished { s.cancelers.append(canceler) }
            return s.finished
        }
        if already { canceler() }
    }

    func finish(_ result: Result<T, Error>) {
        let won = state.withLock { s -> (continuation: CheckedContinuation<T, Error>?, cancelers: [@Sendable () -> Void])? in
            guard !s.finished else { return nil }
            s.finished = true
            let continuation = s.continuation
            s.continuation = nil
            if continuation == nil { s.early = result }
            let cancelers = s.cancelers
            s.cancelers = []
            return (continuation, cancelers)
        }
        guard let won else { return }
        won.continuation?.resume(with: result)
        for cancel in won.cancelers { cancel() }
    }
}

/// Runs `work` and gives up on it after `seconds`: the result is `.timedOut` and the work is cancelled. The work runs in its own
/// unstructured task and is never awaited after the timer wins, so a task that ignores cancellation (a synchronous parser
/// stuck on a crafted file) keeps its own thread but cannot hold the caller.
public func withDeadline<T: Sendable>(seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    let box = RaceBox<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            box.install(continuation)
            let job = Task {
                do { box.finish(.success(try await work())) } catch { box.finish(.failure(error)) }
            }
            let timer = Task {
                try? await Task.sleep(for: .seconds(seconds))
                box.finish(.failure(DocumentExtractionError(.timedOut)))
            }
            box.addCanceler { job.cancel(); timer.cancel() }
        }
    } onCancel: {
        box.finish(.failure(CancellationError()))
    }
}

/// Waits for `task` for at most `seconds`; returns false when it was still running (it is not waited for any longer).
func waitForTask(_ task: Task<Void, Never>?, seconds: TimeInterval) async -> Bool {
    guard let task else { return true }
    do {
        try await withDeadline(seconds: seconds) { await task.value }
        return true
    } catch {
        return false
    }
}

/// Runs a synchronous function on a thread of its own, so a parser that never returns holds no thread of the cooperative pool.
/// Cancellation of the caller is not seen by the function; it must watch its own clock.
///
/// The thread never makes a File Provider download a file (iCloud Drive, Google Drive, Dropbox, OneDrive): opening a file whose bytes
/// are in the cloud fails there instead of fetching it, and the indexer reports it as not downloaded.
func runOnDedicatedThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        let thread = Thread {
            forbidDatalessDownloads()
            continuation.resume(with: Result { try body() })
        }
        thread.stackSize = 4 << 20
        thread.qualityOfService = .utility
        thread.start()
    }
}

/// `runOnDedicatedThread` with a deadline, for the app: a file read that never returns (a hung drive, a crafted file) ends as "took too
/// long" and keeps only its own thread, never one of the cooperative pool.
public func runWithDeadline<T: Sendable>(seconds: TimeInterval, _ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withDeadline(seconds: seconds) { try await runOnDedicatedThread(body) }
}

/// This thread only: a dataless file (SF_DATALESS) is not materialized when it is opened or read (`EDEADLK` instead of a download).
func forbidDatalessDownloads() {
    _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
}

/// Counts the extractions that are running. One that is still running when the next file's turn comes has been abandoned by
/// its deadline: Apple's parsers (PDFKit, NSAttributedString) never look at a clock, so a crafted file can keep its thread
/// busy for the rest of the session. The indexer stops starting such parsers while too many are stuck.
final class ExtractionTracker: Sendable {
    private let count = Mutex(0)

    var live: Int { count.withLock { $0 } }

    func begin() { count.withLock { $0 += 1 } }

    func end() { count.withLock { $0 -= 1 } }
}
