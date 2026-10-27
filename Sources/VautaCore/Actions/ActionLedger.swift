// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation

/// Where an action went: a reminder, a calendar event written through EventKit, or an `.ics` file handed to Calendar.
public enum ActionTarget: String, Sendable, CaseIterable {
    case reminder, event, ics
}

public enum ActionSource: String, Sendable {
    case task
    case followUp = "follow_up"
}

/// The life of a ledger row (`created_actions.state`). `writing` is the intent that is committed before anything is written to
/// EventKit, so a crash between the write and the bookkeeping can be recovered without a duplicate.
public enum ActionState: String, Sendable {
    case writing, created, linked
    case handedOff = "handed_off"
    case orphaned, removed, missing

    /// The states that count against a second write (the unique index of `created_actions`).
    public var isLive: Bool { self == .writing || self == .created || self == .linked || self == .handedOff }
}

/// One row of the ledger: what Vauta created (or linked) in Reminders or Calendar. Identifiers and a hash of the written title only;
/// the text lives in Reminders/Calendar and in the task.
public struct CreatedAction: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let target: ActionTarget
    public let source: ActionSource
    public let sourceID: Int64
    public let meetingID: Int64?
    public var itemID: String?
    public var externalID: String?
    public let containerID: String?
    public let titleHash: String
    public var state: ActionState
    public let writtenAt: Date
    public var updatedAt: Date
    /// The due days of a reminder at the moment Vauta wrote it; nil for a row that did not record them (a linked reminder, an event).
    public var dueBasis: DueBasis?

    public var isLive: Bool { state.isLive }
}

/// What Vauta wrote and what it was written from. Reading the reminder back, a due day the person chose in the editor is not a
/// mismatch: only a change since the write (the task's day or the reminder's) is.
public struct DueBasis: Sendable, Equatable {
    /// The task's due day when the reminder was written.
    public var task: DueDay?
    /// The due day the reminder was written with (the editor's day, or none).
    public var written: DueDay?

    public init(task: DueDay?, written: DueDay?) {
        self.task = task
        self.written = written
    }

    /// Stored as "task|written" with "-" for no day.
    var stored: String { "\(task?.string ?? "-")|\(written?.string ?? "-")" }

    init?(stored: String?) {
        guard let parts = stored?.split(separator: "|", omittingEmptySubsequences: false), parts.count == 2 else { return nil }
        func day(_ part: Substring) -> DueDay?? { part == "-" ? .some(nil) : DueDay(String(part)).map { .some($0) } }
        guard let task = day(parts[0]), let written = day(parts[1]) else { return nil }
        self.init(task: task, written: written)
    }
}

/// A `writing` row with what is needed to take it back if the write fails.
public struct ActionIntent: Sendable, Equatable {
    public let action: CreatedAction
    /// The task's `source` before acting made it the person's ("llm"), so a write that failed leaves the task as it was.
    let restoreSource: String?
}

public enum ActionLedgerError: Error, Equatable {
    /// A live row already exists for this source and target: nothing is written.
    case alreadyLive(CreatedAction)
    case sourceMissing
}

/// Identifiers of everything live in the ledger, for the brief (a reminder Vauta created is shown once, as the task).
public struct LedgerIdentifiers: Sendable, Equatable {
    public var itemIDs: Set<String> = []
    public var externalIDs: Set<String> = []
    public var taskIDs: Set<Int64> = []
    public init(itemIDs: Set<String> = [], externalIDs: Set<String> = [], taskIDs: Set<Int64> = []) {
        self.itemIDs = itemIDs
        self.externalIDs = externalIDs
        self.taskIDs = taskIDs
    }
}

/// Title keys for the duplicate checks: the normalized title (accents, case and punctuation removed, spaces collapsed), its hash and the
/// similarity of two titles by content words.
public enum ActionTitle {
    public static func normalized(_ title: String) -> String { TextKeys.norm(title) }

    /// SHA-256 of the normalized title, as hex. Stored instead of the title: it finds an item again after a crash, and an orphan of the
    /// same task, without keeping any text in the ledger.
    public static func hash(_ title: String) -> String {
        SHA256.hash(data: Data(normalized(title).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func words(_ title: String) -> Set<String> {
        let norm = normalized(title)
        // Scripts written without spaces are compared by character, as elsewhere.
        if norm.unicodeScalars.contains(where: TextKeys.isNoSpaceScript) {
            return Set(norm.unicodeScalars.filter { !$0.properties.isWhitespace }.map { String($0) })
        }
        return Set(norm.split(separator: " ").map(String.init).filter { $0.count > 1 || $0.unicodeScalars.contains { $0.properties.numericType != nil } })
    }

    /// Jaccard similarity of the content words of two titles (0...1).
    public static func similarity(_ a: String, _ b: String) -> Double {
        let (x, y) = (words(a), words(b))
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    /// The title without the "Name: " Vauta puts in front of a task someone else owns (the first colon within 60 characters).
    public static func withoutOwnerPrefix(_ title: String) -> String {
        guard let colon = title.range(of: ": "), title.distance(from: title.startIndex, to: colon.lowerBound) <= 60 else { return title }
        let rest = title[colon.upperBound...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? title : rest
    }

    /// Equal after normalizing, or at least `threshold` alike by content words. A task's
    /// "Ana: " prefix is not part of what it says: a reminder with and one without it are compared on the words after it too.
    public static func isSame(_ a: String, _ b: String, threshold: Double) -> Bool {
        let pairs = [(a, b), (withoutOwnerPrefix(a), b), (a, withoutOwnerPrefix(b)), (withoutOwnerPrefix(a), withoutOwnerPrefix(b))]
        return pairs.contains { x, y in
            let (nx, ny) = (normalized(x), normalized(y))
            return !nx.isEmpty && (nx == ny || similarity(x, y) >= threshold)
        }
    }
}
