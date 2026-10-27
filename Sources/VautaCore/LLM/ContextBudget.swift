// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Token budgets derived from the chat model's real context window. Input
/// budgets cover the whole prompt (system, entities, material and
/// instruction); output budgets include any reasoning.
///
/// Large windows (≥ 12K) scale the values calibrated on a 32K server. Small
/// windows, like the on-device model's 4K, get explicit shares: fewer
/// entities, a shorter live window, map-reduce minutes with small blocks and
/// fewer passages for Ask.
public struct ContextBudget: Sendable, Equatable {
    public let contextTokens: Int

    public init(contextTokens: Int) {
        self.contextTokens = max(2_048, contextTokens)
    }

    var isSmall: Bool { contextTokens < 12_000 }

    func scaled(_ tokensAt32K: Int) -> Int { contextTokens * tokensAt32K / 32_768 }

    /// Headroom for the estimate's error and the chat template's own tokens.
    var safety: Int { contextTokens / 20 + 128 }

    /// Known people and projects offered to the model.
    var entityLimit: Int { isSmall ? 25 : 120 }
    var liveEntityLimit: Int { isSmall ? 15 : 60 }

    // MARK: Minutes

    var minutesOutput: Int { isSmall ? contextTokens * 3 / 10 : min(10_000, scaled(10_000)) }
    /// A meeting whose whole prompt fits this is summarized in one request.
    var minutesInput: Int { isSmall ? contextTokens - minutesOutput - safety : scaled(18_000) }
    var blockOutput: Int { isSmall ? contextTokens / 5 : 1_200 }
    var blockInput: Int { isSmall ? contextTokens - blockOutput - safety : scaled(11_000) }

    // MARK: Live notes

    /// The live transcript window (older lines slide out).
    var liveWindow: Int { isSmall ? contextTokens * 2 / 5 : scaled(20_000) }
    var liveOutput: Int { isSmall ? 400 : 500 }
    /// How many of the user's own notes the live pass sees (so it does not repeat them) and how much of each: a few
    /// short ones on a small window, where they share the 4K with the transcript, the people and the earlier notes.
    var liveUserNotes: (count: Int, characters: Int) { isSmall ? (5, 80) : (12, 200) }

    // MARK: Notepad (the user's shorthand notes, expanded from the transcript)

    /// The transcript around one note (about 1,600 tokens on the on-device model: 3 to 5 minutes of speech).
    var noteWindow: Int { isSmall ? contextTokens * 2 / 5 : scaled(8_000) }
    var noteOutput: Int { isSmall ? 320 : 600 }
    /// Sentences per note, and notes per request: one on a small window, a few consecutive ones on a large one.
    var noteSentences: Int { isSmall ? 3 : 5 }
    var noteBatchLimit: Int { isSmall ? 1 : 5 }

    // MARK: Ask

    var askInput: Int { isSmall ? contextTokens - askOutput - safety : scaled(20_000) }
    var askOutput: Int { isSmall ? 700 : 1_500 }
    var askPassageLimit: Int { isSmall ? 3 : 8 }
    /// Of the passages Ask sends, at most this many come from the person's documents (the total stays `askPassageLimit`: on the
    /// on-device model at most 3 items, 2 of them from documents, sharing `askPassageCharacters`).
    var docPassageLimit: Int { isSmall ? 2 : 6 }
    /// Passages of a meeting's own materials that go with its whole transcript.
    var docMaterialLimit: Int { isSmall ? 1 : 4 }
    /// Characters of retrieved passages (about 3 characters per token).
    var askPassageCharacters: Int { isSmall ? askInput * 3 / 2 : 18_000 }

    /// A larger output limit to retry an answer cut at `current`, or nil
    /// when the window has no meaningful room left for it.
    func raisedOutput(from current: Int, promptTokens: Int) -> Int? {
        let room = contextTokens - promptTokens - safety
        let raised = min(current * 2, room)
        return raised >= current + current / 4 ? raised : nil
    }
}
