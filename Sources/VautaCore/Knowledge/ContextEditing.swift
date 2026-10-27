// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Parsing of alias lists typed or pasted by the user.
public enum AliasList {
    /// List separators across scripts: comma, semicolon, the ideographic and
    /// full-width commas (ja, zh), the Arabic comma and semicolon, and newlines.
    static let separators: Set<Character> = [",", ";", "、", "，", "；", "،", "؛"]

    public static func isSeparator(_ c: Character) -> Bool { c.isNewline || separators.contains(c) }

    /// The aliases in `text`, trimmed, without empty entries and without
    /// duplicates (case-, accent- and width-insensitive; the first spelling wins).
    public static func parse(_ text: String) -> [String] {
        unique(text.split(whereSeparator: isSeparator).map { $0.trimmingCharacters(in: .whitespaces) })
    }

    /// `existing` plus the aliases in `text` that are new: neither already in
    /// the list nor the same as `name`. Order is kept; new ones go last.
    public static func adding(_ text: String, to existing: [String], name: String) -> [String] {
        var seen = Set(([name] + existing).map(TextKeys.norm))
        var out = existing
        for alias in parse(text) where seen.insert(TextKeys.norm(alias)).inserted { out.append(alias) }
        return out
    }

    static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { item in
            let key = TextKeys.norm(item)
            return !key.isEmpty && seen.insert(key).inserted
        }
    }
}

/// The self entity is shown as the localized "Me" while it keeps its stored
/// legacy name. Saving the form must not store that label as its name.
public enum SelfEntityName {
    /// Text the name field shows when editing `entity`.
    public static func fieldText(for entity: Entity) -> String { entity.displayName }

    /// Name to store when the user saves `typed` for `entity`: the stored
    /// name is kept when the field still shows the localized label (or is
    /// empty) for the self entity; anything else is a real name.
    public static func storedName(typed: String, for entity: Entity?) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let entity, entity.isSelf else { return typed }
        return trimmed.isEmpty || trimmed == entity.displayName ? entity.name : typed
    }
}

/// What a merge moves into the target, computed before asking the user.
public struct MergeSummary: Sendable, Equatable {
    /// Aliases the target gains (the source name included), in display order.
    public let newAliases: [String]
    public let mentions: Int
    public let meetings: Int
    public let tasks: Int
    public let relations: Int
    public let glossaryTerms: Int
    public let series: Int
    /// The source's email moves to the target (it had none).
    public let movesEmail: Bool
    /// The source's email is discarded: the target keeps its own.
    public let dropsEmail: Bool
    /// The source's note is discarded.
    public let dropsNote: Bool

    /// `footprint` is the source's.
    public init(source: Entity, footprint: EntityFootprint, target: Entity) {
        var known = Set(([target.name] + target.aliases).map(TextKeys.norm))
        // The self entity's stored pronoun is never an alias.
        let sourceNames = (source.isSelf && source.name == MeetingStore.legacySelfName ? [] : [source.name])
            + footprint.aliases.map(\.text)
        newAliases = sourceNames.filter { known.insert(TextKeys.norm($0)).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        mentions = footprint.mentions
        meetings = footprint.meetings
        tasks = footprint.tasks
        relations = footprint.relations
        glossaryTerms = footprint.glossaryTerms
        series = footprint.series
        let hasEmail = !(footprint.email ?? "").isEmpty
        let targetHasEmail = !(target.email ?? "").isEmpty
        movesEmail = hasEmail && !targetHasEmail
        dropsEmail = hasEmail && targetHasEmail
        dropsNote = footprint.hasNote
    }

    /// Nothing but the entry itself goes away.
    public var isEmpty: Bool {
        newAliases.isEmpty && mentions == 0 && meetings == 0 && tasks == 0 && relations == 0 && glossaryTerms == 0
            && series == 0 && !movesEmail && !dropsEmail && !dropsNote
    }
}

/// What deleting an entity removes, and what stays but loses the link.
public struct DeletionSummary: Sendable, Equatable {
    // Removed.
    public let aliases: Int
    public let mentions: Int
    public let meetings: Int
    public let relations: Int
    public let mergedEntries: Int
    // Kept, without the link.
    public let tasks: Int
    public let glossaryTerms: Int
    public let series: Int

    public init(footprint f: EntityFootprint) {
        aliases = f.aliases.count
        mentions = f.mentions
        meetings = f.meetings
        relations = f.relations
        mergedEntries = f.mergedEntries
        tasks = f.tasks
        glossaryTerms = f.glossaryTerms
        series = f.series
    }

    /// `meetings` counts the links to meetings (mentions and attendance) that go away.
    public var removesAnything: Bool { aliases + mentions + meetings + relations + mergedEntries > 0 }
    public var detachesAnything: Bool { tasks + glossaryTerms + series > 0 }
}

/// Progress of a re-analysis over many meetings. One failing meeting never
/// stops the run; cancelling stops before the next meeting.
public struct ReanalysisProgress: Sendable, Equatable {
    public enum State: Sendable, Equatable { case idle, running, finished, cancelled }

    public private(set) var state: State = .idle
    public private(set) var total = 0
    /// Meetings analyzed successfully.
    public private(set) var analyzed = 0
    /// Meetings without a transcript any more: left as they were.
    public private(set) var skipped = 0
    public private(set) var failed = 0
    /// Totals found in the analyzed meetings.
    public private(set) var found = AnalysisSummary()

    public init() {}

    public var isRunning: Bool { state == .running }
    /// Meetings visited so far, whatever the outcome.
    public var processed: Int { analyzed + skipped + failed }
    /// The meeting being analyzed, 1-based ("3 of 14").
    public var current: Int { min(processed + 1, total) }
    public var fractionCompleted: Double { total == 0 ? 1 : Double(processed) / Double(total) }

    public mutating func start(total: Int) {
        self = ReanalysisProgress()
        self.total = max(0, total)
        state = .running
    }

    public mutating func record(_ summary: AnalysisSummary) {
        guard state == .running, processed < total else { return }
        if summary.skipped {
            skipped += 1
        } else {
            analyzed += 1
            found.mentions += summary.mentions
            found.ambiguous += summary.ambiguous
            found.corrections += summary.corrections
        }
    }

    public mutating func recordFailure() {
        guard state == .running, processed < total else { return }
        failed += 1
    }

    public mutating func cancel() {
        guard state == .running else { return }
        state = .cancelled
    }

    public mutating func finish() {
        guard state == .running else { return }
        state = .finished
    }
}
