// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The current time as the screens that show it ("today", "overdue", "started 12 minutes ago") read it.
///
/// In the app this is always the system clock. Only the diagnostics build used by `scripts/render-ui.sh` can fix it
/// (`SampleWorld.snapshotNow`), so every rendered scene shows the same simulated moment, whatever day it is rendered on.
public enum AppClock {
    #if VAUTA_DIAGNOSTICS
    private final class Fixed: @unchecked Sendable {
        let lock = NSLock()
        var value: Date?
    }
    private static let fixed = Fixed()

    /// Freezes the clock at `date` (`nil` goes back to the system clock). Only the snapshot renderer calls it.
    public static func fix(at date: Date?) { fixed.lock.withLock { fixed.value = date } }
    #endif

    public static var now: Date {
        #if VAUTA_DIAGNOSTICS
        if let date = fixed.lock.withLock({ fixed.value }) { return date }
        #endif
        return Date()
    }
}
