// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

public enum EntityKind: String, CaseIterable, Sendable, Identifiable, Codable {
    case person, project, client, topic, team, system

    public var id: String { rawValue }

    /// Localized display name of the kind.
    public var label: String {
        switch self {
        case .person: String(localized: "Person", comment: "Entity kind: a person")
        case .project: String(localized: "Project", comment: "Entity kind: a project")
        case .client: String(localized: "Client", comment: "Entity kind: a client or customer")
        case .topic: String(localized: "Topic", comment: "Entity kind: a topic")
        case .team: String(localized: "Team", comment: "Entity kind: a team")
        case .system: String(localized: "System", comment: "Entity kind: a software system")
        }
    }

    /// Localized plural, used as a section title.
    public var plural: String {
        switch self {
        case .person: String(localized: "People", comment: "Section title: entity kind person, plural")
        case .project: String(localized: "Projects", comment: "Section title: entity kind project, plural")
        case .client: String(localized: "Clients", comment: "Section title: entity kind client, plural")
        case .topic: String(localized: "Topics", comment: "Section title: entity kind topic, plural")
        case .team: String(localized: "Teams", comment: "Section title: entity kind team, plural")
        case .system: String(localized: "Systems", comment: "Section title: entity kind system, plural")
        }
    }

    public var symbol: String {
        switch self {
        case .person: "person.fill"
        case .project: "folder.fill"
        case .client: "building.2.fill"
        case .topic: "number"
        case .team: "person.3.fill"
        case .system: "server.rack"
        }
    }
}

/// Graph node kind: anything that can have edges.
public enum NodeKind: String, Sendable, Codable {
    case entity, decision, task, meeting
}

public struct NodeRef: Hashable, Sendable {
    public let kind: NodeKind
    public let id: Int64
    public init(_ kind: NodeKind, _ id: Int64) {
        self.kind = kind
        self.id = id
    }
}

public struct Entity: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let kind: EntityKind
    public let name: String
    public let note: String?
    public let email: String?
    /// user | calendar | llm
    public let source: String
    /// Entities from the calendar stay pending until the user confirms them.
    public let confirmed: Bool
    /// Aliases besides the name (learned ones included).
    public let aliases: [String]
    public let lastSeen: Date?
    public let mentionCount: Int
    /// The person that stands for the user of this Mac (task owner "me").
    public var isSelf: Bool = false

    /// Name to show: the self entity keeps its legacy stored name ("Yo") for
    /// the prompts but is shown as the localized "Me" until the user renames it.
    public var displayName: String { MeetingStore.displayName(name, isSelf: isSelf) }
}

public struct EntityDraft: Sendable {
    public var id: Int64?
    public var kind: EntityKind
    public var name: String
    public var note: String
    public var email: String
    /// Every alias the entity should keep besides the name. Aliases missing
    /// from this list are removed on save, whatever their origin; the ones
    /// kept keep their origin and weight.
    public var aliases: [String]

    public init(id: Int64? = nil, kind: EntityKind, name: String, note: String = "", email: String = "", aliases: [String] = []) {
        self.id = id
        self.kind = kind
        self.name = name
        self.note = note
        self.email = email
        self.aliases = aliases
    }

    public init(_ e: Entity) {
        self.init(id: e.id, kind: e.kind, name: e.name, note: e.note ?? "", email: e.email ?? "", aliases: e.aliases)
    }
}

public struct GlossaryTerm: Sendable, Identifiable, Hashable {
    public var id: Int64?
    public var term: String
    public var expansion: String
    public var note: String
    public var entityID: Int64?
    /// Pinned: takes priority in the transcriber's custom vocabulary.
    public var pinned: Bool

    public init(id: Int64? = nil, term: String, expansion: String = "", note: String = "", entityID: Int64? = nil, pinned: Bool = false) {
        self.id = id
        self.term = term
        self.expansion = expansion
        self.note = note
        self.entityID = entityID
        self.pinned = pinned
    }
}

/// Recurring meeting: title pattern (or calendar key) and default entities.
public struct MeetingSeries: Sendable, Identifiable, Hashable {
    public var id: Int64?
    public var calendarKey: String?
    public var titlePattern: String
    public var defaultEntities: [Int64]

    public init(id: Int64? = nil, calendarKey: String? = nil, titlePattern: String, defaultEntities: [Int64] = []) {
        self.id = id
        self.calendarKey = calendarKey
        self.titlePattern = titlePattern
        self.defaultEntities = defaultEntities
    }
}

public struct RelationInfo: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let src: NodeRef
    public let rel: String
    public let dst: NodeRef
    public let srcLabel: String
    public let dstLabel: String
}

/// Relations the user can create by hand between entities.
public enum RelationKind: String, CaseIterable, Sendable, Identifiable {
    case worksOn = "works_on", memberOf = "member_of", forClient = "for_client", dependsOn = "depends_on", relatedTo = "related_to"
    /// From the meeting graph (never created by hand).
    case about, owner

    public var id: String { rawValue }
    /// Localized reading of the edge ("Ana · works on · Kobaltix").
    public var label: String {
        switch self {
        case .worksOn: String(localized: "works on", comment: "Relation between a person and a project")
        case .memberOf: String(localized: "member of", comment: "Relation between a person and a team")
        case .forClient: String(localized: "for client", comment: "Relation between a project and a client")
        case .dependsOn: String(localized: "depends on", comment: "Relation between two projects or systems")
        case .relatedTo: String(localized: "related to", comment: "Generic relation between two entities")
        case .about: String(localized: "mentioned in", comment: "Relation between a person or project and a decision or task that mentions it")
        case .owner: String(localized: "owns", comment: "Relation read from a person to a task: the person is responsible for it")
        }
    }
    public static let manual: [RelationKind] = [.worksOn, .memberOf, .forClient, .dependsOn, .relatedTo]
}

public struct NameHit: Sendable, Identifiable, Hashable {
    public enum Target: Sendable, Hashable { case entity(Int64), glossary(Int64) }
    public let target: Target
    public let text: String
    public let detail: String

    public init(target: Target, text: String, detail: String = "") {
        self.target = target; self.text = text; self.detail = detail
    }

    public var id: String {
        switch target {
        case .entity(let i): "e\(i)"
        case .glossary(let i): "g\(i)"
        }
    }
}

public struct MentionRef: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let entityID: Int64
    public let meeting: MeetingStore.Meeting
    public let segmentID: Int64?
    public let t: Double
    public let surface: String
    /// Text of the segment (nil once the raw text was purged).
    public let context: String?
    public let resolvedBy: String
    /// Who said the sentence (nil once the raw text was purged).
    public let channel: Channel?
    /// The speaker of the sentence, when its meeting has speaker data.
    public let speaker: SpeakerTag?
}

public struct SuggestionCandidate: Sendable, Codable, Hashable {
    public let entityID: Int64?
    public let glossaryID: Int64?
    public let label: String
    public let score: Double
}

public struct Suggestion: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable { case ambiguous, correction }
    public let id: Int64
    public let meetingID: Int64
    public let segmentID: Int64?
    public let t: Double
    public let kind: Kind
    public let surface: String
    public let candidates: [SuggestionCandidate]
    public let occurrences: Int
}

public struct GraphNode: Sendable, Identifiable, Hashable {
    public var id: NodeRef { ref }
    public let ref: NodeRef
    public let label: String
    /// Entity kind, task state or meeting date (localized).
    public let detail: String
    public let depth: Int
    public let rel: String
}

public struct TimelineEntry: Sendable, Identifiable, Hashable {
    public var id: Int64 { meeting.id }
    public let meeting: MeetingStore.Meeting
    public let mentions: Int
    public let firstT: Double?
    public let attended: Bool
    /// The user named a speaker of this meeting as the person (and that speaker has lines).
    public let spoke: Bool
}

public struct AnalysisSummary: Sendable, Equatable {
    public var mentions = 0
    public var ambiguous = 0
    public var corrections = 0
    /// The meeting has no transcript any more (raw text purged): nothing was
    /// re-analyzed and its existing knowledge was kept as it was.
    public var skipped = false
    public init() {}
}
