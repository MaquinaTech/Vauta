// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The template a meeting's minutes are written with: one of Vauta's (`MinutesTemplate`), measured on meetings, or one the person
/// wrote (`CustomMinutesTemplate`), which is not. Either way the minutes have the same JSON shape and every decision and task is
/// checked against the transcript: a template only says what to cover and stress.
public enum MinutesTemplateChoice: Hashable, Sendable, Identifiable {
    case builtIn(MinutesTemplate)
    case custom(Int64)

    public static let general = MinutesTemplateChoice.builtIn(.general)
    private static let customPrefix = "custom:"

    public var id: String { storedValue }

    /// How it is stored (`meetings.template`, `series.template` and the `minutesTemplate` preference): a built-in template's raw
    /// value, as since templates exist, or "custom:" and the template's id.
    public var storedValue: String {
        switch self {
        case .builtIn(let template): template.rawValue
        case .custom(let id): Self.customPrefix + String(id)
        }
    }

    /// A stored value read back: nil for none, or for a value no version writes (the minutes then use the general template).
    public init?(stored: String?) {
        guard let stored else { return nil }
        if let template = MinutesTemplate(rawValue: stored) {
            self = .builtIn(template)
        } else if stored.hasPrefix(Self.customPrefix), let id = Int64(stored.dropFirst(Self.customPrefix.count)), id > 0 {
            self = .custom(id)
        } else {
            return nil
        }
    }

    public var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    /// The built-in template, or the general one under a template the person wrote (whose instructions take the place of its own).
    public var base: MinutesTemplate {
        if case .builtIn(let template) = self { return template }
        return .general
    }
}

/// A minutes template the person wrote: a name and what the minutes should cover and stress, in their words. It is not measured on
/// meetings as Vauta's templates are, and says so wherever it is offered (`label`).
public struct CustomMinutesTemplate: Sendable, Hashable, Identifiable {
    public let id: Int64
    public var name: String
    public var instructions: String
    public let createdAt: Date

    public init(id: Int64, name: String, instructions: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.createdAt = createdAt
    }

    /// A name for menus, and instructions of a long paragraph or two. A small model reads less of them
    /// (`ContextBudget.customTemplateCharacters`).
    public static let nameLimit = 60
    public static let instructionsLimit = 4_000

    /// Shown with every custom template: Vauta has not measured it on meetings as it did its own.
    public static var label: String {
        String(localized: "Custom · not evaluated",
               comment: "Minutes template: shown with a template the person wrote, which Vauta has not measured on meetings as it did its own templates")
    }
}
