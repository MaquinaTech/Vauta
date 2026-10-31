// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// How long "Meetings" stays unlocked after Touch ID or the password.
///
/// The timeout counts from the last activity, not from the unlock: using the
/// meetings window (`touch`) keeps it open, and it locks after `interval`
/// without activity. A nil interval never times out (it still locks with the
/// screen).
///
/// It counts on the continuous clock, never the wall clock: setting the Mac's date back (or forward) doesn't move when it
/// locks, and the time the Mac sleeps counts.
public struct UnlockWindow: Equatable, Sendable {
    public typealias Instant = ContinuousClock.Instant

    public private(set) var interval: TimeInterval?
    public private(set) var expiresAt: Instant?
    public private(set) var isUnlocked = false

    public init(interval: TimeInterval?) {
        self.interval = interval
    }

    public func isUnlocked(at now: Instant) -> Bool {
        guard isUnlocked else { return false }
        return expiresAt.map { now < $0 } ?? true
    }

    public mutating func unlock(at now: Instant) {
        isUnlocked = true
        expiresAt = interval.map { now + .seconds($0) }
    }

    /// Activity: extends the timeout from `now`. Does nothing once it has
    /// expired or when locked (an expired window never reopens by itself).
    public mutating func touch(at now: Instant) {
        guard isUnlocked(at: now) else { return }
        expiresAt = interval.map { now + .seconds($0) }
    }

    /// A new policy applies from `now` to an open window.
    public mutating func setInterval(_ interval: TimeInterval?, at now: Instant) {
        let open = isUnlocked(at: now)
        self.interval = interval
        if open { expiresAt = interval.map { now + .seconds($0) } }
    }

    public mutating func lock() {
        isUnlocked = false
        expiresAt = nil
    }
}
