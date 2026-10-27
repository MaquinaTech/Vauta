// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// The four lists of the context editor.
enum ContextSection: String, CaseIterable, Identifiable {
    case people, work, glossary, series

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .people: LocalizedStringResource("People", comment: "Context editor section: people")
        case .work: LocalizedStringResource("Projects & Clients", comment: "Context editor section: projects, clients, teams, systems and topics")
        case .glossary: LocalizedStringResource("Glossary", comment: "Context editor section: acronyms and internal terms")
        case .series: LocalizedStringResource("Recurring Meetings", comment: "Context editor section: meetings that repeat")
        }
    }

    var symbol: String {
        switch self {
        case .people: "person.2"
        case .work: "folder"
        case .glossary: "character.book.closed"
        case .series: "repeat"
        }
    }

    /// Entity kinds listed in the section (empty for glossary and series).
    var kinds: [EntityKind] {
        switch self {
        case .people: [.person]
        case .work: [.project, .client, .team, .system, .topic]
        case .glossary, .series: []
        }
    }

    var listsEntities: Bool { !kinds.isEmpty }

    /// The section that lists entities of `kind`.
    static func containing(_ kind: EntityKind) -> ContextSection { kind == .person ? .people : .work }
}

/// The item open in the detail pane.
enum ContextSelection: Hashable {
    case entity(Int64)
    case term(Int64)
    case series(Int64)
}

/// A move the user asked for; held back while unsaved changes are pending.
enum ContextNavigation: Equatable {
    case select(ContextSelection?)
    case section(ContextSection)
    case create
}

/// Editable copy of an entity.
struct EntityForm: Equatable {
    var id: Int64?
    var kind: EntityKind = .person
    var name = ""
    var aliases: [String] = []
    /// Text typed in the alias field and not turned into tokens yet.
    var aliasInput = ""
    var email = ""
    var note = ""

    init(kind: EntityKind = .person) { self.kind = kind }

    init(_ e: Entity) {
        id = e.id
        kind = e.kind
        name = SelfEntityName.fieldText(for: e)
        aliases = e.aliases
        email = e.email ?? ""
        note = e.note ?? ""
    }

    var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// What to store. `entity` is the stored entity being edited, if any: the
    /// self entity keeps its stored name while the field shows "Me".
    func draft(editing entity: Entity?) -> EntityDraft {
        EntityDraft(id: id, kind: kind, name: SelfEntityName.storedName(typed: name, for: entity), note: note,
                    email: kind == .person ? email : (entity?.email ?? ""),
                    aliases: AliasList.adding(aliasInput, to: aliases, name: name))
    }
}

/// Editable copy of a glossary term.
struct TermForm: Equatable {
    var id: Int64?
    var term = ""
    var expansion = ""
    var note = ""
    var entityID: Int64?
    var pinned = false

    init() {}

    init(_ g: GlossaryTerm) {
        id = g.id
        term = g.term
        expansion = g.expansion
        note = g.note
        entityID = g.entityID
        pinned = g.pinned
    }

    var canSave: Bool { !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var value: GlossaryTerm { GlossaryTerm(id: id, term: term, expansion: expansion, note: note, entityID: entityID, pinned: pinned) }
}

/// Editable copy of a recurring meeting series.
struct SeriesForm: Equatable {
    var id: Int64?
    var calendarKey: String?
    var title = ""
    var entities: Set<Int64> = []

    init() {}

    init(_ s: MeetingSeries) {
        id = s.id
        calendarKey = s.calendarKey
        title = s.titlePattern
        entities = Set(s.defaultEntities)
    }

    var canSave: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var value: MeetingSeries {
        MeetingSeries(id: id, calendarKey: calendarKey, titlePattern: title, defaultEntities: entities.sorted())
    }
}

/// A merge waiting for the user's confirmation.
struct MergeRequest: Identifiable {
    let source: Entity
    let footprint: EntityFootprint
    var targetID: Int64?
    var id: Int64 { source.id }
}

/// An entity delete (or a dismissed calendar person) waiting for confirmation.
struct DeleteRequest: Identifiable {
    let entity: Entity
    let summary: DeletionSummary
    /// A pending calendar person the user does not want.
    let isDismissal: Bool
    var id: Int64 { entity.id }
}
