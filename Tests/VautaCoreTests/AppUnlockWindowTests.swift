// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("App: relock policy")
struct AppUnlockWindowTests {
    private let t0 = ContinuousClock.now

    @Test func locksAfterTheIntervalWithoutActivity() {
        var window = UnlockWindow(interval: 300)
        #expect(!window.isUnlocked(at: t0))
        window.unlock(at: t0)
        #expect(window.isUnlocked(at: t0 + .seconds(299)))
        #expect(!window.isUnlocked(at: t0 + .seconds(300)))
        #expect(window.expiresAt == t0 + .seconds(300))
    }

    @Test func activityExtendsTheTimeout() {
        var window = UnlockWindow(interval: 300)
        window.unlock(at: t0)
        window.touch(at: t0 + .seconds(200))
        #expect(window.isUnlocked(at: t0 + .seconds(450)))
        #expect(!window.isUnlocked(at: t0 + .seconds(500)))
    }

    @Test func activityNeverReopensAnExpiredWindow() {
        var window = UnlockWindow(interval: 60)
        window.unlock(at: t0)
        window.touch(at: t0 + .seconds(61))
        #expect(!window.isUnlocked(at: t0 + .seconds(62)))
        var locked = UnlockWindow(interval: 60)
        locked.touch(at: t0)
        #expect(!locked.isUnlocked(at: t0))
    }

    @Test func untilScreenLocksHasNoTimeout() {
        var window = UnlockWindow(interval: nil)
        window.unlock(at: t0)
        #expect(window.expiresAt == nil)
        #expect(window.isUnlocked(at: t0 + .seconds(86_400)))
        window.lock()
        #expect(!window.isUnlocked(at: t0 + .seconds(1)))
    }

    @Test func aNewPolicyAppliesFromNow() {
        var window = UnlockWindow(interval: 60)
        window.unlock(at: t0)
        window.setInterval(900, at: t0 + .seconds(30))
        #expect(window.isUnlocked(at: t0 + .seconds(900)))
        #expect(!window.isUnlocked(at: t0 + .seconds(930)))
        window.setInterval(nil, at: t0 + .seconds(100))
        #expect(window.isUnlocked(at: t0 + .seconds(10_000)))
        // Changing the policy of a locked window doesn't unlock it.
        var locked = UnlockWindow(interval: 60)
        locked.setInterval(nil, at: t0)
        #expect(!locked.isUnlocked(at: t0))
    }
}
