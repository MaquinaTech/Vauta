// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The parts of the minutes' summary that can be switched on or off, so the evaluation can regenerate a meeting's minutes with the summary
/// as it shipped and with the outcome-first one (`llm-eval --summary old|new`). `shipped` is the outcome-first summary as a whole; which backend
/// runs it in the app is `MinutesSummaryRelease.summary(integrated:)`.
public struct MinutesSummary: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The digest of a long meeting on a small window carries the validated decisions and tasks as an "Outcomes" list with a status,
    /// cut last; under budget the block summaries (earlier blocks first) and the topics go first.
    public static let outcomes = MinutesSummary(rawValue: 1)
    /// The block summaries say what was decided, rejected or left open and the final figures, and the digest asks for the same.
    public static let wording = MinutesSummary(rawValue: 2)
    /// Swift checks the written summary: sentences with segment numbers or tags, repeats, a transcript label as the subject and the
    /// meeting's date are dropped; figures the transcript does not hold are counted.
    public static let checks = MinutesSummary(rawValue: 4)

    /// The outcome-first summary, every part (what `--summary new` regenerates).
    public static let shipped: MinutesSummary = [.outcomes, .wording, .checks]
    /// The summary as the app shipped it before this phase.
    public static let legacy: MinutesSummary = []

    /// "old" / "legacy", "new" / "shipped", or a comma list of `outcomes`, `wording`, `checks`.
    public static func parse(_ text: String) -> MinutesSummary? {
        switch text.lowercased() {
        case "old", "legacy", "none": return .legacy
        case "new", "shipped", "all": return .shipped
        default:
            var out: MinutesSummary = []
            for word in text.lowercased().split(separator: ",") {
                switch word {
                case "new", "shipped": out.formUnion(.shipped)
                case "old", "legacy": break
                case "outcomes": out.insert(.outcomes)
                case "wording": out.insert(.wording)
                case "checks": out.insert(.checks)
                default: return nil
                }
            }
            return out
        }
    }

    /// For the traces: "outcomes+wording+checks", or "legacy".
    public var names: String {
        let parts = [contains(.outcomes) ? "outcomes" : nil, contains(.wording) ? "wording" : nil, contains(.checks) ? "checks" : nil].compactMap { $0 }
        return parts.isEmpty ? "legacy" : parts.joined(separator: "+")
    }
}

/// Which summary the app runs, by backend. The blind comparison on the sealed test meetings (docs/LANGUAGE_MODEL.md, "Harness phase"): the
/// integrated model runs the outcome-first summary (more outcomes covered, no more factual errors). Apple's model keeps the summary it had:
/// the new one covers more outcomes but states more facts the transcript does not back, a trade-off left undecided.
public enum MinutesSummaryRelease {
    public static func summary(integrated: Bool) -> MinutesSummary { integrated ? .shipped : .legacy }
}
