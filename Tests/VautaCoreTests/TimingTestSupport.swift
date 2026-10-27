// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// CPU time the calling thread has used, in seconds. A budget on synchronous work measured with this does not depend on how busy
/// the rest of the Mac (or the rest of the suite) is, which a wall clock does.
func threadCPUSeconds() -> Double {
    var time = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
    return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
}

/// The CPU seconds `body` takes on the calling thread (synchronous work only).
func cpuSeconds(_ body: () throws -> Void) rethrows -> Double {
    let start = threadCPUSeconds()
    try body()
    return threadCPUSeconds() - start
}

/// The shortest of `runs` repetitions of a repeatable async operation: a budget on speed that a stall of the whole machine for one
/// repetition cannot fail (a real slowdown makes every repetition slow).
func fastest(of runs: Int = 3, _ body: () async throws -> Void) async rethrows -> Duration {
    var best: Duration?
    for _ in 0..<runs {
        let began = ContinuousClock.now
        try await body()
        let took = ContinuousClock.now - began
        if best == nil || took < best! { best = took }
    }
    return best ?? .zero
}
