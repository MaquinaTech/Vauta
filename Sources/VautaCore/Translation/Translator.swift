// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Translates text of one language pair. A translator is long-lived: it is
/// created once per pair and used for the whole meeting.
public protocol Translator: Sendable {
    func translate(_ text: String) async throws -> String
    /// Several texts at once, in order. The default calls `translate` one by one.
    func translate(batch: [String]) async throws -> [String]
}

extension Translator {
    public func translate(batch: [String]) async throws -> [String] {
        var out: [String] = []
        out.reserveCapacity(batch.count)
        for text in batch { out.append(try await translate(text)) }
        return out
    }
}

/// Whether a pair can be translated now.
public enum PairAvailability: Sendable, Equatable {
    /// The language models are on this Mac.
    case installed
    /// Supported, after a one-time download from Apple.
    case downloadable
    case unsupported
}

/// Where translators come from: Apple's Translation framework in the app, a
/// stub in tests.
public protocol TranslationBackend: Sendable {
    func availability(from source: Locale.Language, to target: Locale.Language) async -> PairAvailability
    /// A translator for an installed pair.
    func makeTranslator(from source: Locale.Language, to target: Locale.Language) async throws -> any Translator
}

/// What a language is, next to a source, for pickers and Settings.
public struct TranslationTarget: Sendable, Identifiable, Hashable {
    public let language: Locale.Language
    public let availability: PairAvailability

    public init(language: Locale.Language, availability: PairAvailability) {
        self.language = language
        self.availability = availability
    }

    public var id: String { language.storageCode }
    public var name: String { TranslationPair.name(of: language) }
}

extension TranslationBackend {
    /// The languages that can be translated into from `source`, with their
    /// availability, sorted by name. Languages the pair cannot use are left out.
    public func targets(from source: Locale.Language, among candidates: [Locale.Language]) async -> [TranslationTarget] {
        let usable = candidates.filter { !$0.isSameLanguage(as: source) }
        let found = await withTaskGroup(of: TranslationTarget?.self) { group in
            for language in usable {
                group.addTask {
                    let availability = await availability(from: source, to: language)
                    return availability == .unsupported ? nil : TranslationTarget(language: language, availability: availability)
                }
            }
            var out: [TranslationTarget] = []
            for await target in group { if let target { out.append(target) } }
            return out
        }
        return found.sorted { LanguageNameSort.precedes($0.name, $1.name) }
    }
}

/// Collapses regional variants for a picker: English (US), English (UK)…
/// become English, while Portuguese from Portugal and the traditional Chinese
/// scripts stay apart because a reader notices the difference.
public func pickerLanguages(_ supported: [Locale.Language]) -> [Locale.Language] {
    let bases = Set(supported.filter { $0.region == nil && $0.minimalIdentifier == ($0.languageCode?.identifier ?? "") }
        .compactMap { $0.languageCode?.identifier })
    let keepRegions: Set<String> = ["pt", "zh"]
    var seen = Set<String>()
    return supported.filter { language in
        let id = language.minimalIdentifier
        guard let code = language.languageCode?.identifier else { return false }
        if id != code, bases.contains(code), !keepRegions.contains(code) { return false }
        return seen.insert(id).inserted
    }
}
