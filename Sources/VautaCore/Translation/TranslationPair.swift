// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

extension Locale.Language {
    /// Whether two languages need no translation between them: same language
    /// code (English from the US and from Britain), except that the Chinese
    /// scripts are different languages for a reader.
    public func isSameLanguage(as other: Locale.Language) -> Bool {
        guard let code = languageCode, code == other.languageCode else { return false }
        if code == .chinese {
            return effectiveScript == other.effectiveScript
        }
        return true
    }

    private var effectiveScript: Locale.Script? { script ?? Locale.Language(identifier: maximalIdentifier).script }

    /// The short stable code stored with translations ("es", "pt-PT", "zh-Hans").
    public var storageCode: String { minimalIdentifier }
}

/// What is translated into what: the language the other participants speak
/// and the language the user reads.
public struct TranslationPair: Sendable, Hashable {
    public let source: Locale.Language
    public let target: Locale.Language

    public init(source: Locale.Language, target: Locale.Language) {
        self.source = source
        self.target = target
    }

    /// `source` is the transcription language of the meeting.
    public init(sourceLocale: Locale, target: Locale.Language) {
        self.init(source: sourceLocale.language, target: target)
    }

    /// Translating a language into itself does nothing.
    public var isIdentity: Bool { source.isSameLanguage(as: target) }

    /// A stable identifier for caches and logs ("en>es"). Contains no content.
    public var id: String { "\(source.storageCode)>\(target.storageCode)" }

    /// The language the translation is stored under.
    public var targetCode: String { target.storageCode }

    /// "English → Spanish", both names in the user's language.
    public var displayName: String { Self.format(Self.name(of: source), Self.name(of: target)) }

    /// The pair as a label (a chip, a title, a status): each name starts with a capital, as in the language
    /// pickers ("Inglés → Español"), because `Locale` writes names in running-text case ("inglés").
    public var labelName: String {
        Self.format(Self.name(of: source).firstLetterCapitalized, Self.name(of: target).firstLetterCapitalized)
    }

    private static func format(_ source: String, _ target: String) -> String {
        String(localized: "\(source)\u{00A0}→\u{00A0}\(target)",
               comment: "Live Translation language pair; the arguments are the spoken language and the language you read, e.g. English → Spanish")
    }

    /// A language's name in the interface language.
    public static func name(of language: Locale.Language, in locale: Locale = .current) -> String {
        let id = language.minimalIdentifier
        return locale.localizedString(forIdentifier: id) ?? id
    }

    /// The target to use when the user chose none: the first of the preferred
    /// languages (in order) that differs from `source`. nil when every
    /// preferred language is the spoken one.
    public static func automaticTarget(source: Locale.Language, preferred: [String] = Locale.preferredLanguages) -> Locale.Language? {
        for id in preferred {
            let language = Locale.Language(identifier: id)
            if !language.isSameLanguage(as: source) { return language }
        }
        return nil
    }
}

extension String {
    /// The first letter capitalized for the current language.
    var firstLetterCapitalized: String {
        guard let first else { return self }
        return String(first).capitalized(with: .current) + dropFirst()
    }
}
