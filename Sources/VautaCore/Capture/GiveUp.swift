// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Waits for work that may never finish, but only until the person gives up on it or a deadline passes. Starting a recording
/// waits on macOS: a permission it has not had an answer to (after an update re-signs an ad-hoc build, macOS asks for system
/// audio again, in a dialog that can sit behind other windows), or a device that does not answer. Those calls can't be cancelled,
/// so the work goes on, and `late` gets what it ends with when it finishes after it was given up.
public enum GiveUp {
    public enum Reason: Error, Equatable, Sendable {
        /// `abandoned` said so.
        case abandoned
        /// The deadline passed first.
        case deadline
    }

    /// `work`'s result, or `Reason` as soon as `abandoned` (asked every `poll`) is true or `deadline` has passed.
    public static func run<T: Sendable>(deadline: Duration, poll: Duration = .milliseconds(100),
                                        abandoned: @escaping @Sendable () async -> Bool,
                                        late: @escaping @Sendable (Result<T, Error>) async -> Void = { _ in },
                                        _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let once = Once()
        return try await withCheckedThrowingContinuation { (waiting: CheckedContinuation<T, Error>) in
            Task.detached {
                let result: Result<T, Error>
                do { result = .success(try await work()) } catch { result = .failure(error) }
                if once.claim() { waiting.resume(with: result) } else { await late(result) }
            }
            Task.detached {
                let end = ContinuousClock.now + deadline
                while ContinuousClock.now < end {
                    if once.isClaimed { return }
                    if await abandoned() {
                        if once.claim() { waiting.resume(throwing: Reason.abandoned) }
                        return
                    }
                    try? await Task.sleep(for: poll)
                }
                if once.claim() { waiting.resume(throwing: Reason.deadline) }
            }
        }
    }

    /// The first of the two tasks to claim it resumes the caller.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
        var isClaimed: Bool { lock.withLock { claimed } }
    }
}
