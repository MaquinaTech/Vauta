// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The single lane: one request to the model at a time, handed over by
/// priority (then arrival order).
extension LLMService {
    struct Waiter {
        let priority: Priority
        let seq: Int
        /// Resumed with true when the lane is handed over, false when the wait was cancelled.
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// Waits for the lane. Cancelling the calling task stops the wait at once
    /// (throws `CancellationError`) without taking the lane. After a normal
    /// return the caller owns the lane and must `release()` it.
    func acquire(_ p: Priority) async throws {
        try Task.checkCancellation()
        if !laneBusy {
            laneBusy = true
            laneOwner = p
            return
        }
        seq += 1
        let mySeq = seq
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    c.resume(returning: false)
                    return
                }
                waiters.append(Waiter(priority: p, seq: mySeq, continuation: c))
                waiters.sort { ($0.priority, $0.seq) < ($1.priority, $1.seq) }
            }
        } onCancel: {
            Task { await self.abandonWait(mySeq) }
        }
        guard granted else { throw CancellationError() }
        laneOwner = p
    }

    /// A cancelled waiter leaves the queue (if the lane was not handed to it yet).
    private func abandonWait(_ seq: Int) {
        guard let i = waiters.firstIndex(where: { $0.seq == seq }) else { return }
        waiters.remove(at: i).continuation.resume(returning: false)
    }

    func release() {
        if waiters.isEmpty {
            laneBusy = false
            laneOwner = nil
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }
}
