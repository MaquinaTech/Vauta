// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The detector's sleeper for a card budget that must not pass by itself (the tests set it to an hour): a short wait really sleeps, a long one
/// holds until `release` is set or its task is cancelled, so what the test checks never depends on how long the Mac takes.
func holdingSleeper(release: Locked<Bool> = Locked(false)) -> @Sendable (Double) async -> Void {
    { seconds in
        if seconds > 5 {
            while !release.withLock({ $0 }), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        } else {
            try? await Task.sleep(for: .seconds(seconds))
        }
    }
}

/// Polls an async condition until it holds or `timeout` passes (generous: the whole suite runs thousands of tests at once and a loaded Mac can
/// starve the pool for more than a minute, so the timeout only bounds a hang).
func settle(timeout: Duration = .seconds(240), _ condition: @Sendable () async throws -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if (try? await condition()) == true { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return (try? await condition()) == true
}
