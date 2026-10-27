// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation

/// How related items were ranked.
public enum BriefRankingMode: String, Sendable, Codable, Equatable {
    /// The search model's raw cosine (floor `SemanticRanker.relatedFloor`).
    case semantic
    /// Content-word overlap (the keyword gate).
    case keyword
}

/// Where a line of the brief opens. Every shown item has one; a link whose target is gone is dropped when the brief is shown.
public enum BriefLink: Sendable, Equatable, Hashable {
    case segment(meetingID: Int64, segmentID: Int64)
    case meeting(meetingID: Int64, t: Double?)
    case person(entityID: Int64)
    case passage(key: String, sourceID: Int64, relPath: String)
    case file(sourceID: Int64, relPath: String)
    /// Opens the reminder in Reminders.
    case reminder(id: String)
    /// Opens the event in Calendar.
    case event(identifier: String)
    case none
}

public enum BriefSectionKind: String, Sendable, Codable, CaseIterable {
    case people, lastTime, openTasks, relatedMeetings, documents, reminders, invitation
}

public struct BriefItem: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case person, summary, decision, task, openQuestion, relatedMeeting, material, document, note, reminder, invitationLine
    }

    /// `b1`, `b2`… minted for this snapshot, in section order. The agenda cites these.
    public var id: String
    public let kind: Kind
    public let text: String
    /// The meeting an item comes from (decisions, tasks, open questions, summary, related meetings).
    public var meetingID: Int64?
    public var meetingDate: Date?
    public var decisionID: Int64?
    public var taskID: Int64?
    public var owner: String?
    public var due: Date?
    /// A task past due at the meeting, or a reminder due before it: shown with text, not colour alone.
    public var overdue = false
    public var dueBeforeMeeting = false
    /// The model proposed it and its figures or dates were not found in the minutes ("Check" mark).
    public var unconfirmed = false
    public var ownerUncertain = false
    /// The task or reminder belongs to the person (grouped under "Me").
    public var isYours = false
    /// People: the entity, when the lookup resolved the attendee to exactly one.
    public var entityID: Int64?
    public var lastMet: Date?
    public var meetingsTogether = 0
    /// False for a person read back from a kept brief, which stores no history: the page then says nothing about it.
    public var historyKnown = true
    /// An open question that no segment could be found for: "from the minutes".
    public var fromMinutes = false
    public var link: BriefLink
    /// Which source: a reminder's list, a file's name.
    public var source: String?
    /// One line of context: the passage a document or a related meeting matched on.
    public var detail: String?
    /// The raw cosine that brought the item in (semantic mode).
    public var cosine: Double?
    /// A task that has a live reminder Vauta created or linked ("In Reminders"). The reminder itself is not listed.
    public var inReminders = false
    /// A task the person confirmed as the same as earlier ones: how many mentions it stands for and the date of the first ("carried over since…").
    public var carriedMentions = 0
    public var carriedSince: Date?
    /// A decision the person confirmed as the same as an earlier one: when it was first decided.
    public var firstDecided: Date?
    /// A decision that replaces an earlier one the person confirmed it changes: the date, and the older decision's words (shown under it).
    public var replacesDate: Date?
    public var replacesText: String?

    public init(id: String = "", kind: Kind, text: String, link: BriefLink = .none) {
        self.id = id
        self.kind = kind
        self.text = text
        self.link = link
    }
}

public struct BriefSection: Sendable, Equatable {
    public let kind: BriefSectionKind
    /// At most `BriefSnapshot.windowLimit` items (the Meetings window); the panel shows the first `BriefSnapshot.panelLimit`.
    public var items: [BriefItem]
    /// How many items there were before the cap ("Show all (n)").
    public var total: Int

    public init(kind: BriefSectionKind, items: [BriefItem], total: Int? = nil) {
        self.kind = kind
        self.items = items
        self.total = total ?? items.count
    }
}

public struct BriefAgendaLine: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case followUp = "follow_up", decide, ask, review
    }
    public let kind: Kind
    public let text: String
    /// Item IDs of the snapshot (1 to 3).
    public let cites: [String]

    public init(kind: Kind, text: String, cites: [String]) {
        self.kind = kind
        self.text = text
        self.cites = cites
    }
}

/// Why the suggested agenda is not shown.
public enum BriefAgendaState: Sendable, Equatable {
    /// Not asked for yet (or the deterministic brief is all there is).
    case none
    /// Accepted lines, every one verified.
    case lines([BriefAgendaLine])
    /// The model ran and fewer than two lines survived, or it failed: "No suggestions this time".
    case noSuggestions
    /// There is no model to ask (Apple Intelligence off, server unreachable, a backend that did not pass the gates).
    case unavailable
    /// A recording, Low Power Mode or heat keeps the model idle.
    case paused

    public var lines: [BriefAgendaLine] {
        if case .lines(let lines) = self { return lines }
        return []
    }
}

/// The brief of one event. Built from earlier meetings, documents, notes, reminders and the event; memory only (the cache) except
/// for the references that `BriefStoredReferences` keeps with a recorded meeting.
public struct BriefSnapshot: Sendable, Equatable {
    public static let panelLimit = 3
    public static let windowLimit = 10

    public let occurrence: BriefOccurrence
    public let title: String
    public let start: Date
    public let end: Date
    public let service: ConferencingService?
    public let seriesName: String?
    public let mode: BriefRankingMode
    /// Why the related sections were not looked for (a generic title with no history), if so.
    public let relatedSkipped: Bool
    public var sections: [BriefSection]
    public var agenda: BriefAgendaState

    public init(occurrence: BriefOccurrence, title: String, start: Date, end: Date, service: ConferencingService?, seriesName: String?,
                mode: BriefRankingMode, relatedSkipped: Bool, sections: [BriefSection], agenda: BriefAgendaState = .none) {
        self.occurrence = occurrence
        self.title = title
        self.start = start
        self.end = end
        self.service = service
        self.seriesName = seriesName
        self.mode = mode
        self.relatedSkipped = relatedSkipped
        self.sections = sections
        self.agenda = agenda
    }

    public func section(_ kind: BriefSectionKind) -> BriefSection? { sections.first { $0.kind == kind } }

    public var items: [BriefItem] { sections.flatMap(\.items) }

    public func item(_ id: String) -> BriefItem? { items.first { $0.id == id } }

    /// The first meeting with these people: no earlier meeting of anyone, and nothing else to show but the people.
    public var isFirstMeeting: Bool {
        !hasContent && (section(.people)?.items.allSatisfy { $0.meetingsTogether == 0 } ?? true)
    }

    /// Something worth a notification: a section other than the people, or a person met before.
    public var hasContent: Bool {
        sections.contains { $0.kind != .people && !$0.items.isEmpty } || (section(.people)?.items.contains { $0.meetingsTogether > 0 } ?? false)
    }

    /// A stable hash of everything shown (replays of the same inputs must give the same value).
    public var digest: String {
        var lines: [String] = [occurrence.identifier, "\(occurrence.startSeconds)", title, mode.rawValue, "\(relatedSkipped)", seriesName ?? ""]
        for section in sections {
            lines.append("# \(section.kind.rawValue) \(section.total)")
            for item in section.items {
                lines.append([item.id, item.kind.rawValue, item.text, "\(item.meetingID ?? 0)", "\(item.taskID ?? 0)", "\(item.decisionID ?? 0)",
                              item.owner ?? "", item.due.map { "\($0.timeIntervalSince1970)" } ?? "", "\(item.overdue)", "\(item.unconfirmed)",
                              "\(item.isYours)", "\(item.meetingsTogether)", "\(item.link)"].joined(separator: "|"))
            }
        }
        for line in agenda.lines { lines.append("A \(line.kind.rawValue) \(line.text) \(line.cites.joined(separator: ","))") }
        return SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// What the panel may show while Meetings is locked: the event's title and start, and nothing from the brief. The cache is dropped on
/// lock, so there is no brief to leak; this type is all the locked card is made from.
public struct BriefLockedSummary: Sendable, Equatable {
    public let title: String
    public let start: Date
    public let end: Date
    public let service: ConferencingService?

    public init(_ event: BriefEvent) {
        title = event.title
        start = event.start
        end = event.end
        service = event.service
    }
}
