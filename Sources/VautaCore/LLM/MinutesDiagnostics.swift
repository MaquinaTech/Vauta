// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import os

/// What the checks did to one set of minutes: how many items the model proposed, how many survived and why the rest did not. Counts
/// and reason names only (no transcript text), so it can go to a trace and to the debug log.
public struct MinutesDiagnostics: Sendable, Equatable, Codable {
    public var proposed: Int
    public var kept: Int
    public var dropped: Int
    /// `"<kind>.<reason>"` → count (`ValidatedMinutes.drops`).
    public var drops: [String: Int]
    /// Items kept on a looser match (`ValidatedMinutes.counts`).
    public var counts: [String: Int] = [:]
    public var dueGiven: Int
    public var dueUnreadable: Int
    public var dueRuleViolations: Int
    public var openQuestions: Int
    public var topics: Int
    /// Blocks of a long meeting that were summarised separately (0 when the meeting went in one request), how many left no extract
    /// at all (cut off even at the smallest size) and how many extracts the small-window digest could not read. Their decisions and
    /// tasks are not in the minutes.
    public var blocks = 0
    public var blocksOmitted = 0
    public var blocksUnreadable = 0
    /// Share of the prompt that was already in the model's kept prefix (the meeting read while it was recorded); nil when no prefix was
    /// kept or the meeting went by blocks.
    public var prefixReuse: Double?
    /// More than a quarter of the blocks are missing from the minutes.
    public var isIncomplete: Bool { blocks > 0 && (blocksOmitted + blocksUnreadable) * 4 > blocks }

    public init(_ minutes: ValidatedMinutes) {
        proposed = minutes.proposed
        kept = minutes.decisions.count + minutes.tasks.count + minutes.mentions.count
        dropped = minutes.dropped
        drops = minutes.drops
        counts = minutes.counts
        dueGiven = minutes.dueGiven
        dueUnreadable = minutes.dueUnreadable
        dueRuleViolations = minutes.dueRuleViolations
        openQuestions = minutes.openQuestions.count
        topics = minutes.topics.count
    }

    /// One line for the debug log, reasons sorted: `proposed 14 kept 5 dropped 9 [decision.quoteNotFound 4, …] due 3 rule 2`.
    public var line: String {
        let reasons = drops.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        let loose = counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        return "proposed \(proposed) kept \(kept) dropped \(dropped) [\(reasons)] anchored [\(loose)] due written \(dueGiven) unreadable \(dueUnreadable) rule \(dueRuleViolations)"
            + (prefixReuse.map { String(format: " prefix reuse %.2f", $0) } ?? "")
            + (blocks > 0 ? " blocks \(blocks) omitted \(blocksOmitted) unreadable \(blocksUnreadable)" : "")
    }

    private static let logger = Logger(subsystem: "local.vauta", category: "Minutes")

    /// Writes `line` to the unified log (debug level: nothing is kept unless a developer asks for it).
    public func log() {
        let text = line
        Self.logger.debug("minutes checks: \(text, privacy: .public)")
    }
}
