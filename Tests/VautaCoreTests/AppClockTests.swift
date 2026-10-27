// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("AppClock")
struct AppClockTests {
    @Test("the app's clock is the system clock")
    func isTheSystemClock() {
        let before = Date()
        let now = AppClock.now
        let after = Date()
        #expect(now >= before && now <= after)
    }
}
