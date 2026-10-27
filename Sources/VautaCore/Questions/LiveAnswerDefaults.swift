// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The model that does the live work of a recording, as far as live answers care: they behave differently on each (the evaluation
/// measured each one apart, decision D1).
public enum LiveAnswerBackendKind: String, Sendable, CaseIterable, Codable {
    /// Apple's on-device model.
    case apple
    /// A model server (this Mac or the network).
    case server
    /// The integrated Gemma 4 E4B.
    case integrated

    /// Which one answers while recording, from the person's choices: the provider for chat, and, with the integrated model, who does
    /// the live tasks.
    public static func current(chat: ModelProviderSettings.Chat, liveTasks: ModelProviderSettings.LiveTasks) -> LiveAnswerBackendKind {
        switch chat {
        case .server: .server
        case .onDevice: .apple
        case .integrated: liveTasks == .apple ? .apple : .integrated
        }
    }
}

/// Decision D1 (owner, 2026-10-16): live answers are on by default, with a first-run hint and a one-click way to turn them off, only
/// for the backends that pass the GO gates of decision D12 in the evaluation (docs/LANGUAGE_MODEL.md). A backend that fails ships with
/// the feature off, still available in Settings. This table is what the measurement fills; a backend nobody measured is off.
///
/// Decision D16 (owner, 2026-10-17): with Apple's on-device model live answers are not offered at all, whatever was stored (a blind
/// judge found 2% of its cards correct). Only the integrated model and a model server offer them.
public enum LiveAnswerDefaults {
    /// What was measured for a backend, in words, for the documentation and the tests. `passes` is true only when every gate passed.
    public struct Verdict: Sendable, Equatable {
        public let passes: Bool
        /// Whether live answers are offered with this backend at all (Settings shows the switches, the recording runs them).
        public let offered: Bool
        public let note: String

        public init(passes: Bool, offered: Bool = true, note: String) {
            self.passes = passes
            self.offered = offered
            self.note = note
        }
    }

    /// One entry for each backend. The note says what the verdict rests on; "not measured" is an off default.
    public static let verdicts: [LiveAnswerBackendKind: Verdict] = [
        .apple: Verdict(passes: false, offered: false, note: "not offered (decision D16): measured 2026-10-17, fails the D12 gates by a wide margin: English precision 48%, so_far recall 8%, 3.63 false cards an hour, 2% of shown cards correct (blind judge)"),
        .server: Verdict(passes: false, note: "not measured: the evaluation never contacts a model server"),
        .integrated: Verdict(passes: false, note: "measured 2026-10-17, fails the D12 gates: English precision 59%, so_far recall 10%, 1.60 false cards an hour, 21% of shown cards correct, card latency p90 29.1 s (blind judge)"),
    ]

    /// Whether the feature starts on for a person who never chose. `nil` (the backend is not known yet): off.
    public static func onByDefault(_ backend: LiveAnswerBackendKind?) -> Bool {
        backend.flatMap { verdicts[$0]?.passes } ?? false
    }

    /// Whether live answers are offered with this backend: Settings shows their switches and a recording may run them. Only Apple's
    /// on-device model is not offered. `nil` (no model is known yet) is not Apple's, so the person's choice stands.
    public static func offered(_ backend: LiveAnswerBackendKind?) -> Bool {
        backend.flatMap { verdicts[$0]?.offered } ?? true
    }
}
