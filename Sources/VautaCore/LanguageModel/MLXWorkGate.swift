// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Synchronization

/// One GPU job at a time across the two MLX models (the language model and the search model's encoder), with priorities:
/// an interactive answer goes before live notes, which go before minutes, which go before bulk embedding. A running body is
/// never interrupted; a waiting one with a higher priority goes first. Fair within a priority (first come, first served). A long
/// job (a generation) does not hold the gate for its whole length: it takes it per prefill chunk and per decode burst through a
/// `GenerationLease`, so a more urgent waiter runs between two of them.
public final class MLXWorkGate: Sendable {
    public enum Priority: Int, Sendable, Comparable {
        /// Reading the meeting while it is recorded (the incremental prefix): above bulk embedding, below everything else.
        /// `autoAnswer`: the answer to a question heard in the meeting. Above the live notes, which step aside for it; below a question the
        /// person asked, which does not wait for it.
        /// `brief`: the suggested agenda of the pre-meeting brief, above the minutes and below the live notes.
        case bulk = 0, warm = 1, minutes = 2, brief = 3, live = 4, autoAnswer = 5, interactive = 6
        public static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    private struct Waiter {
        let id: UInt64
        let priority: Priority
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct State {
        var busy = false
        var counter: UInt64 = 0
        var waiters: [Waiter] = []
    }

    private let state = Mutex(State())
    public static let shared = MLXWorkGate()
    public init() {}

    /// Jobs waiting (not counting the running one).
    public var waiting: Int { state.withLock { $0.waiters.count } }

    /// Whether a job with a priority above `priority` is waiting: the running job should give the gate up at its next checkpoint.
    func hasWaiter(above priority: Priority) -> Bool { state.withLock { s in s.waiters.contains { $0.priority > priority } } }

    /// Registers the waiter and the free-gate check in one step, so a release cannot slip between them.
    func acquire(_ priority: Priority) async throws {
        let ticket = Mutex<UInt64?>(nil)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let outcome: (granted: Bool, id: UInt64) = state.withLock { s in
                    if !s.busy { s.busy = true; return (true, 0) }
                    s.counter += 1
                    s.waiters.append(Waiter(id: s.counter, priority: priority, continuation: c))
                    return (false, s.counter)
                }
                if outcome.granted { c.resume(); return }
                ticket.withLock { $0 = outcome.id }
                // Cancelled before the ticket was recorded: the handler found nothing to remove.
                if Task.isCancelled { cancelWaiter(outcome.id) }
            }
        } onCancel: {
            if let id = ticket.withLock({ $0 }) { cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        let w = state.withLock { s in s.waiters.firstIndex { $0.id == id }.map { s.waiters.remove(at: $0) } }
        w?.continuation.resume(throwing: CancellationError())
    }

    func release() {
        let next: Waiter? = state.withLock { s in
            // Highest priority first; among equals, the oldest.
            guard let i = s.waiters.indices.max(by: { a, b in
                let x = s.waiters[a], y = s.waiters[b]
                return x.priority != y.priority ? x.priority < y.priority : x.id > y.id
            }) else {
                s.busy = false
                return nil
            }
            return s.waiters.remove(at: i)
        }
        next?.continuation.resume()
    }

    /// Runs `body` when the gate is free. Cancellation while waiting throws `CancellationError`.
    public func run<T: Sendable>(_ priority: Priority, isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async throws -> T {
        try await acquire(priority)
        defer { release() }
        return try await body()
    }
}
