// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

public enum LinkKind: String, Sendable, CaseIterable, Codable {
    case task, decision
}

public enum LinkRelation: String, Sendable, Codable {
    /// The newer item is the earlier one again (tasks and decisions).
    case same
    /// A decision that replaces an earlier one: a figure, a date or a status in the same role differs (decisions only).
    case changes
}

public enum LinkState: String, Sendable, Codable {
    case suggested, confirmed, dismissed
}

public enum LinkMethod: String, Sendable, Codable {
    case vector, keyword, model, user
}

/// The words that differ between two decisions, copied from the two texts (`item_links.evidence`: `{"a":[earlier…],"b":[now…]}`).
public struct LinkEvidence: Sendable, Equatable, Hashable, Codable {
    public var earlier: [String]
    public var now: [String]

    public init(earlier: [String], now: [String]) {
        self.earlier = earlier
        self.now = now
    }

    private enum CodingKeys: String, CodingKey { case earlier = "a", now = "b" }

    var json: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    init?(json: String?) {
        guard let json, let value = try? JSONDecoder().decode(LinkEvidence.self, from: Data(json.utf8)) else { return nil }
        self = value
    }
}

/// A task or a decision as the link pass sees it: its words, its meeting and the context that lets two meetings be compared.
public struct LinkItem: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var kind: LinkKind
    public var meetingID: Int64
    public var startedAt: Date
    public var text: String
    public var segmentID: Int64?
    public var t: Double?
    /// The task's owner (a person), when it has one.
    public var ownerID: Int64?
    public var dueDay: DueDay?
    public var status: TaskItem.Status = .open
    public var seriesID: Int64?
    /// People who were in the meeting, the person themself left out.
    public var people: Set<Int64> = []
    /// Projects and clients the item's words mention.
    public var projects: Set<Int64> = []
    /// Language code of the item (`es`, `en`…): detected from its words, else the meeting's.
    public var language: String
    /// The locale identifier of the meeting (keys are made with its rules).
    public var locale: String
    public var unconfirmed = false
    public var unconfirmedReason: String?
    public var source = "llm"

    public init(id: Int64, kind: LinkKind, meetingID: Int64, startedAt: Date, text: String, language: String, locale: String) {
        self.id = id
        self.kind = kind
        self.meetingID = meetingID
        self.startedAt = startedAt
        self.text = text
        self.language = language
        self.locale = locale
    }

    /// The marker of a rank: `rank` or `rank:<doubt>`.
    public var isRankedOut: Bool { unconfirmed && UnconfirmedReason.isRankedOut(unconfirmedReason) }
}

/// What a pass proposes for one newer item: the earlier item, how sure the method is and what differs.
public struct LinkProposal: Sendable, Equatable {
    public var kind: LinkKind
    public var srcID: Int64
    public var dstID: Int64
    public var relation: LinkRelation
    public var method: LinkMethod
    public var score: Double
    public var evidence: LinkEvidence?

    public init(kind: LinkKind, srcID: Int64, dstID: Int64, relation: LinkRelation, method: LinkMethod, score: Double, evidence: LinkEvidence? = nil) {
        self.kind = kind
        self.srcID = srcID
        self.dstID = dstID
        self.relation = relation
        self.method = method
        self.score = score
        self.evidence = evidence
    }
}

/// A row of `item_links`.
public struct StoredLink: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let kind: LinkKind
    public let srcID: Int64
    public let dstID: Int64
    public let relation: LinkRelation
    public let state: LinkState
    public let method: LinkMethod
    public let score: Double?
    public let evidence: LinkEvidence?
    public let recipe: Int
    public let createdAt: Date
    public let decidedAt: Date?
}

/// A suggestion or a confirmed link as the Minutes tab shows it: the link and the earlier item with its meeting.
public struct LinkRow: Sendable, Identifiable, Hashable {
    public var id: Int64 { link.id }
    public let link: StoredLink
    /// The earlier item (the destination).
    public let earlierText: String
    public let earlierMeetingID: Int64
    public let earlierMeetingTitle: String
    public let earlierMeetingDate: Date
    public let earlierSegmentID: Int64?
    public let earlierT: Double?
    /// The earlier task's owner, due day and status (tasks only).
    public let earlierOwner: String?
    public let earlierDueDay: DueDay?
    public let earlierStatus: TaskItem.Status?
    public let earlierUnconfirmed: Bool
    public let earlierUnconfirmedReason: String?
    /// The newer task's due day (tasks only): a "same" task with another due day than the earlier one shows "due date changed from…".
    public var newerDueDay: DueDay?
}
