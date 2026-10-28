// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// The rules shared with the EventKit reader, which qualifies events off the main actor.
final class BriefRulesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = BriefEventRules(calendarIDs: [])

    var value: BriefEventRules {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
