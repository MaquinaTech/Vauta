// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Restoring a backup replaces the whole store, queue included.
extension LLMService {
    /// Stops the running background job (it goes back to the queue) and holds
    /// the queue until `resumeAfterRestore`, so no result is written into a
    /// store that is about to be replaced.
    public func pauseForRestore() async {
        restoring = true
        backgroundTask?.cancel()
        await worker?.value
    }

    /// Picks the queue up again from the store as it is now (restored or not).
    public func resumeAfterRestore() async {
        restoring = false
        await start()
    }
}
