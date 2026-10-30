// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Whether the next minutes on a model server reason before they answer. A request whose reasoning runs past the length limit is
/// asked again without it (`LLMService.complete`), so its minutes come from the request without reasoning anyway, after the whole
/// reasoning was spent: on MLXServer with qwen3.5-9b, 49 of the 51 reasoning requests of the 24 DEV meetings ran to the 10,000-token
/// limit, some ten minutes each, 70 % of the run's time. After `cutsBeforeSkipping` runs in a row whose reasoning ran out, the next
/// `skippedRuns` minutes are written without it; the run after them reasons again, and one more cut there skips again. A model whose
/// reasoning finishes never skips. Kept in memory only: a restart, or another model, starts from reasoning (at most `skippedRuns`
/// runs of another model go without it).
struct MinutesReasoningMemory: Sendable, Equatable {
    static let cutsBeforeSkipping = 2
    static let skippedRuns = 5

    private(set) var cuts = 0
    private(set) var skipsLeft = 0

    /// Whether the next minutes reason first.
    var reasons: Bool { skipsLeft == 0 }

    /// A run that reasoned and wrote its minutes, or whose reasoning ran past the limit.
    mutating func reasoned(ranOut: Bool) {
        guard ranOut else { cuts = 0; return }
        cuts += 1
        if cuts >= Self.cutsBeforeSkipping { skipsLeft = Self.skippedRuns }
    }

    /// A run written without reasoning because of the memory.
    mutating func skipped() {
        guard skipsLeft > 0 else { return }
        skipsLeft -= 1
        if skipsLeft == 0 { cuts = Self.cutsBeforeSkipping - 1 }
    }
}
