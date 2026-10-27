// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The parts of the integrated model's minutes request that can be switched on or off, so the evaluation can regenerate a meeting's minutes
/// with the request as it shipped and with the items-first one (`llm-eval --harness old|new`). `shipped` is the items-first request as a
/// whole; which backend runs it in the app is `MinutesHarnessRelease.harness(integrated:)`. Only the integrated model reads it.
public struct MinutesHarness: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The decisions, tasks and open questions come before the summary in the JSON shape and in the grammar, so the summary is written
    /// after the model has listed what the meeting settled. The stored keys do not change.
    public static let itemsFirst = MinutesHarness(rawValue: 1)
    /// The summary rule asks to end with the outcomes (approved or rejected with the vote, final figures and dates), to write what was
    /// settled as settled, to call a point open only when the speakers did, and to say when an item was read from the previous session's minutes.
    public static let outcomeRule = MinutesHarness(rawValue: 2)
    /// The definitions and the recall cue of the instruction (`MinutesArms.recallPrompt`, A1), measured together with the rest.
    public static let recall = MinutesHarness(rawValue: 4)
    /// The minutes request decodes greedily (temperature 0) instead of with the model card's sampling.
    public static let greedy = MinutesHarness(rawValue: 8)
    /// Evaluation only: the minutes request decodes at temperature 0.3.
    public static let cool = MinutesHarness(rawValue: 16)

    /// The instruction says how many decisions and tasks a meeting of this length usually has, and the grammar asks for at least one
    /// fewer of each (`MinutesHarness.expected`), against the few items the model lists unprompted.
    public static let count = MinutesHarness(rawValue: 32)

    /// The items-first request, every part: items first, the outcome rule, the recall wording, the expected counts and greedy decoding. This is
    /// what `--harness new` regenerates, and what the app runs on the integrated model (`MinutesHarnessRelease.released`).
    public static let shipped: MinutesHarness = [.itemsFirst, .outcomeRule, .recall, .count, .greedy]
    /// The request as the app shipped it before this item.
    public static let legacy: MinutesHarness = []

    /// The temperature of the minutes request, or nil for the engine's own sampling.
    public var temperature: Double? { contains(.greedy) ? 0 : contains(.cool) ? 0.3 : nil }

    /// How many decisions and tasks a meeting of this length usually has, from the span of its segments (about one decision per 10 minutes
    /// and one task per 15, at least 2 and 1, at most 6 and 4). The grammar asks for one fewer of each (never fewer than 1 and 0).
    public static func expected(segments: [CitableSegment]) -> ExpectedItems {
        guard let first = segments.map(\.start).min(), let last = segments.map(\.start).max() else { return ExpectedItems(decisions: 2, tasks: 1) }
        let minutes = max(0, last - first) / 60
        return ExpectedItems(decisions: min(6, max(2, Int((minutes / 10).rounded()))), tasks: min(4, max(1, Int((minutes / 15).rounded()))))
    }

    /// How many decisions and tasks to expect.
    public struct ExpectedItems: Sendable, Equatable {
        public var decisions: Int, tasks: Int
        public init(decisions: Int, tasks: Int) { self.decisions = decisions; self.tasks = tasks }
    }

    /// "old" / "legacy", "new" / "shipped", or a comma list of `items`, `rule`, `recall`, `count`, `greedy`, `t03`.
    public static func parse(_ text: String) -> MinutesHarness? {
        switch text.lowercased() {
        case "old", "legacy", "none": return .legacy
        case "new", "shipped", "all": return .shipped
        default:
            var out: MinutesHarness = []
            for word in text.lowercased().split(separator: ",") {
                switch word {
                case "new", "shipped": out.formUnion(.shipped)
                case "old", "legacy": break
                case "items": out.insert(.itemsFirst)
                case "rule": out.insert(.outcomeRule)
                case "recall": out.insert(.recall)
                case "greedy", "t0": out.insert(.greedy)
                case "t03", "cool": out.insert(.cool)
                case "count": out.insert(.count)
                default: return nil
                }
            }
            return out
        }
    }

    /// For the traces: "items+rule+recall+greedy+count", or "legacy".
    public var names: String {
        let parts = [contains(.itemsFirst) ? "items" : nil, contains(.outcomeRule) ? "rule" : nil, contains(.recall) ? "recall" : nil,
                     contains(.greedy) ? "greedy" : nil, contains(.cool) ? "t03" : nil, contains(.count) ? "count" : nil].compactMap { $0 }
        return parts.isEmpty ? "legacy" : parts.joined(separator: "+")
    }
}

/// Which request the app sends, by backend. Decided on 2026-10-24: the integrated model runs the whole request the blind judge measured,
/// `MinutesHarness.shipped`: items first, the outcome rule, the recall wording, the expected counts with the item floor they bring (the
/// grammar then asks for at least one fewer decision and task than a meeting of that length usually has) and greedy decoding. The added latency was accepted:
/// the added latency (docs/LANGUAGE_MODEL.md, "Harness phase: what ships"). Apple's model and the model servers do not read this request.
public enum MinutesHarnessRelease {
    public static let released: MinutesHarness = .shipped
    public static func harness(integrated: Bool) -> MinutesHarness { integrated ? released : .legacy }
}
