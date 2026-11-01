// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Validation errors of the knowledge layer (context, items, suggestions).
public enum KnowledgeError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    case emptyName
    case emptyTerm
    case emptySeriesTitle
    case emptyNote
    case emptyDecision
    case emptyTask
    /// A minutes template without instructions.
    case emptyTemplate
    case relationNeedsTwoNodes
    case suggestionGone
    /// The entity was deleted (or merged) since the screen was loaded.
    case entityGone
    /// Another person already uses this email address.
    case emailInUse(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: String(localized: "The name can’t be empty.", comment: "Error when saving a person or project without a name")
        case .emptyTerm: String(localized: "The term can’t be empty.", comment: "Error when saving a glossary term without text")
        case .emptySeriesTitle: String(localized: "The title can’t be empty.", comment: "Error when saving a recurring meeting series without a title")
        case .emptyNote: String(localized: "The note is empty.", comment: "Error when adding an empty note to a meeting")
        case .emptyDecision: String(localized: "The decision is empty.", comment: "Error when adding an empty decision")
        case .emptyTask: String(localized: "The task is empty.", comment: "Error when adding an empty task")
        case .emptyTemplate:
            String(localized: "Write what the minutes should cover.", comment: "Error when saving a minutes template whose instructions are empty")
        case .relationNeedsTwoNodes:
            String(localized: "A relation needs two different items.", comment: "Error when linking an item to itself")
        case .suggestionGone:
            String(localized: "This suggestion no longer exists.", comment: "Error when resolving a name suggestion that was already handled")
        case .entityGone:
            String(localized: "This person or project no longer exists.", comment: "Error when choosing an entity that was deleted")
        case .emailInUse(let email):
            String(localized: "Another person already uses \(email). Merge them instead.",
                   comment: "Error when saving a person whose email belongs to someone else; the argument is the email address")
        }
    }

    public var description: String { errorDescription ?? "\(Self.self)" }
}
