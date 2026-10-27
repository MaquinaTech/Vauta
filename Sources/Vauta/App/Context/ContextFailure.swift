// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// What the user was doing when something failed: it picks the alert title.
enum ContextOperation: Equatable {
    case load
    case saveEntity(EntityKind)
    case deleteEntity
    case dismiss
    case confirm
    case merge
    case addRelation
    case removeRelation
    case saveTerm
    case deleteTerm
    case saveSeries
    case deleteSeries
    case reanalyze

    var failureTitle: String {
        switch self {
        case .load: String(localized: "Couldn’t load your context", comment: "Alert title: reading people, projects and glossary failed")
        case .saveEntity(let kind):
            switch kind {
            case .person: String(localized: "Couldn’t save the person", comment: "Alert title")
            case .project: String(localized: "Couldn’t save the project", comment: "Alert title")
            case .client: String(localized: "Couldn’t save the client", comment: "Alert title")
            case .team: String(localized: "Couldn’t save the team", comment: "Alert title")
            case .system: String(localized: "Couldn’t save the system", comment: "Alert title: a software system")
            case .topic: String(localized: "Couldn’t save the topic", comment: "Alert title")
            }
        case .deleteEntity: String(localized: "Couldn’t delete", comment: "Alert title: deleting a person or project failed")
        case .dismiss: String(localized: "Couldn’t dismiss the person", comment: "Alert title: dismissing a person suggested by the calendar failed")
        case .confirm: String(localized: "Couldn’t confirm the person", comment: "Alert title: confirming a person suggested by the calendar failed")
        case .merge: String(localized: "Couldn’t merge", comment: "Alert title: merging two people or projects failed")
        case .addRelation: String(localized: "Couldn’t add the relation", comment: "Alert title")
        case .removeRelation: String(localized: "Couldn’t remove the relation", comment: "Alert title")
        case .saveTerm: String(localized: "Couldn’t save the term", comment: "Alert title: saving a glossary term failed")
        case .deleteTerm: String(localized: "Couldn’t delete the term", comment: "Alert title: deleting a glossary term failed")
        case .saveSeries: String(localized: "Couldn’t save the recurring meeting", comment: "Alert title")
        case .deleteSeries: String(localized: "Couldn’t delete the recurring meeting", comment: "Alert title")
        case .reanalyze: String(localized: "Couldn’t find names again", comment: "Alert title: searching the context names in all meetings failed")
        }
    }
}

/// An error ready to show: title, what happened, what to do, and an action
/// that does it when there is one.
struct ContextFailure: Identifiable {
    enum Action {
        /// Merge the entry being edited into the person who owns the email.
        case merge(source: Entity, into: Int64)
        /// Open the person who owns the email, adding the new entry's names as aliases.
        case useExisting(Entity, aliases: [String])
    }

    let id = UUID()
    let title: String
    let message: String
    let recovery: String?
    var action: Action?

    init(_ error: Error, during operation: ContextOperation) {
        title = operation.failureTitle
        let localized = error as? LocalizedError
        message = localized?.errorDescription ?? error.localizedDescription
        recovery = localized?.recoverySuggestion ?? Self.recovery(for: error)
    }

    /// The title of the merge action (also what the snapshot of this alert shows).
    static var mergeTitle: String { String(localized: "Merge…", comment: "Alert button: merge this entry into the person who already has the email") }

    var actionTitle: String? {
        switch action {
        case .merge: Self.mergeTitle
        case .useExisting(let e, _):
            String(localized: "Open “\(e.displayName)”", comment: "Alert button: edit the existing person instead; the argument is their name")
        case nil: nil
        }
    }

    private static func recovery(for error: Error) -> String? {
        switch error as? KnowledgeError {
        case .entityGone?, .suggestionGone?:
            String(localized: "The list has been refreshed.", comment: "Recovery suggestion when an item changed elsewhere")
        case .emailInUse?:
            String(localized: "Each email address can belong to only one person.", comment: "Recovery suggestion for a duplicate email")
        default: nil
        }
    }
}
