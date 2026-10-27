// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
internal import NaturalLanguage

/// Language-dependent rules for name recognition and keyword search, chosen
/// by the meeting language (`meetings.locale`, NULL = legacy `es-ES`).
/// Pure value type: no store, no network.
public struct LanguageProfile: Sendable, Equatable {
    /// What an initial capital letter says about a word.
    public enum Casing: Sendable, Equatable {
        /// Only proper nouns (and sentence starts) are capitalized: en, es, fr…
        case properNounsCapitalized
        /// Every noun is capitalized (German, Luxembourgish): no name signal.
        case nounsCapitalized
        /// The script has no letter case (Han, Kana, Hangul, Arabic, Hebrew, Indic, Thai…).
        case caseless
    }

    /// The legacy meeting language: meetings recorded before `meetings.locale` existed.
    public static let legacyLocaleIdentifier = MeetingStore.Meeting.legacyLocaleIdentifier
    public static let legacy = LanguageProfile(locale: Locale(identifier: legacyLocaleIdentifier))

    public let locale: Locale
    /// ISO 639 code ("es", "en", "zh"…).
    public let languageCode: String
    public let casing: Casing
    /// False for languages written without spaces between words (zh, ja, th, lo, km, my).
    public let usesSpaces: Bool
    /// Normalized function words dropped from keyword queries (and never
    /// matched as names unless they look like one).
    public let stopwords: Set<String>
    /// Normalized words that transcribers capitalize but are never names:
    /// fillers, weekday and month names, meeting app names.
    public let noiseWords: Set<String>
    /// Characters that end a sentence (the next capitalized word is not a name hint).
    public let sentenceTerminators: Set<Character>

    public init(locale: Locale) {
        self.locale = locale
        let code = locale.language.languageCode?.identifier.lowercased() ?? "es"
        languageCode = code
        let script = Self.script(of: locale)
        let casedScripts: Set<String> = ["Latn", "Cyrl", "Grek", "Armn"]
        if !casedScripts.contains(script) {
            casing = .caseless
        } else if ["de", "lb"].contains(code) {
            casing = .nounsCapitalized
        } else {
            casing = .properNounsCapitalized
        }
        usesSpaces = !["zh", "ja", "th", "lo", "km", "my", "bo"].contains(code)
        stopwords = Self.normalized(Self.stopwordLists[code] ?? Self.stopwordLists["en"]!)
        noiseWords = Self.normalized(Self.fillerLists[code] ?? [])
            .union(Self.normalized(Self.meetingAppNames))
            .union(Self.calendarWords(locale))
        sentenceTerminators = Self.baseTerminators.union(Self.extraTerminators[code] ?? [])
    }

    public init(identifier: String?) {
        self.init(locale: Locale(identifier: identifier ?? Self.legacyLocaleIdentifier))
    }

    /// Profile for a free text such as a question, whose language may differ
    /// from the meeting's: the dominant language detected on device, or `fallback`.
    public static func detecting(_ text: String, fallback: LanguageProfile = .legacy) -> LanguageProfile {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return fallback }
        let profile = LanguageProfile(locale: Locale(identifier: language.rawValue))
        return profile.languageCode == fallback.languageCode ? fallback : profile
    }

    /// True if a capitalized word in the middle of a sentence hints at a name.
    public var capitalizationMarksNames: Bool { casing == .properNounsCapitalized }

    public func isSentenceTerminator(_ ch: Character) -> Bool { sentenceTerminators.contains(ch) }

    /// A token that reads as a proper noun in this language.
    public func looksLikeName(_ token: TextKeys.Token) -> Bool {
        capitalizationMarksNames && token.capitalizedMidSentence
    }

    /// Sound key for misrecognition hints, or nil where no valid rule set
    /// exists: the Spanish rules make "Hannah" sound like "Ana", which is
    /// right in Spanish and wrong in English.
    public func phoneticKey(_ text: String) -> String? {
        ["es", "ca", "gl"].contains(languageCode) ? TextKeys.phonetic(text) : nil
    }

    // MARK: Data

    private static func script(of locale: Locale) -> String {
        if let script = locale.language.script?.identifier { return script }
        let maximal = Locale.Language(identifier: locale.identifier).maximalIdentifier
        return Locale.Language(identifier: maximal).script?.identifier ?? "Latn"
    }

    private static func normalized(_ words: [String]) -> Set<String> {
        Set(words.map(TextKeys.norm).filter { !$0.isEmpty })
    }

    /// Weekday and month names (full, short and stand-alone) in the meeting language.
    private static func calendarWords(_ locale: Locale) -> Set<String> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let symbols = calendar.weekdaySymbols + calendar.shortWeekdaySymbols + calendar.standaloneWeekdaySymbols
            + calendar.monthSymbols + calendar.shortMonthSymbols + calendar.standaloneMonthSymbols
        // Short symbols of one or two letters ("Mo", "M.") would only hide real names.
        return normalized(symbols).filter { $0.count >= 3 }
    }

    private static let baseTerminators: Set<Character> = [".", "?", "!", ":", ";", "\n", "…", "‽"]

    private static let extraTerminators: [String: Set<Character>] = [
        "es": ["¿", "¡"], "ca": ["¿", "¡"], "gl": ["¿", "¡"],
        "zh": ["。", "！", "？", "；", "：", "．"], "ja": ["。", "！", "？", "．"], "ko": ["。", "！", "？"],
        "ar": ["؟", "؛", "۔"], "fa": ["؟", "؛"], "ur": ["؟", "۔"],
        "hi": ["।", "॥"], "mr": ["।"], "bn": ["।"], "ne": ["।"],
        "am": ["።", "፧", "፨"], "hy": ["։", "՞", "՜"], "el": [";"], "my": ["။", "၊"], "th": [], "bo": ["།"],
    ]

    /// Meeting apps that transcribers write capitalized ("we're on Teams").
    static let meetingAppNames = [
        "google", "meet", "zoom", "teams", "slack", "webex", "facetime", "discord", "skype", "whereby", "jitsi",
        "chime", "gotomeeting", "huddle", "around", "loom", "safari", "chrome", "edge", "firefox", "arc", "brave",
        "opera", "vivaldi", "outlook", "calendar", "ok", "okay",
    ]
}
