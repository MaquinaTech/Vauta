// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The sanitizers workflow (`.github/workflows/sanitizers.yml`) sets `VAUTA_TEST_TIME_SCALE`: the code runs many times slower there, on
/// three cores, and one long CPU test can hold the pool for minutes. Waits stretch by the factor, and a time budget is not held: the test
/// still runs its timed code, so the sanitizer checks it, but the time would measure the sanitizer. 1 everywhere else.
enum TestTiming {
    static let scale: Double = ProcessInfo.processInfo.environment["VAUTA_TEST_TIME_SCALE"].flatMap(Double.init).map { max(1, $0) } ?? 1

    /// False under a sanitizer.
    static var holdsBudgets: Bool { scale == 1 }

    static func scaled(_ timeout: Duration) -> Duration { timeout * scale }
}
