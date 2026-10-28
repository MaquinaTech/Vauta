// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
internal import NaturalLanguage

/// Small text utilities shared by the prompts and their validation.
public enum PromptText {
    // MARK: Token estimates

    /// Conservative token estimate without a tokenizer. Latin and other
    /// alphabetic text runs at about 3.2 characters per token, Han, Kana and
    /// Hangul at about 1.1, other scripts (Cyrillic, Arabic, Thai…) at about
    /// 2; mixed text is weighted by its share of each. Each line adds a few
    /// tokens for the "[S12345 · 05:12 · Ana (remote)?]" prefixes (digits and a speaker label).
    public static func tokens(_ text: String) -> Int {
        var latin = 0, dense = 0, other = 0, lines = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A: lines += 1; latin += 1
            case 0..<0x0370, 0x1E00...0x1EFF, 0x2000...0x206F: latin += 1
            case 0x1100...0x11FF, 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x323AF: dense += 1
            default: other += 1
            }
        }
        // latin / 3.2 + dense / 1.1 + other / 2, rounded up, in integers (denominator 704 = 32 · 11 · 2).
        let scaled = latin * 220 + dense * 640 + other * 352
        return (scaled + 703) / 704 + lines * 7 + 8
    }

    public static func tokens(_ messages: [ChatMessage]) -> Int { messages.reduce(0) { $0 + tokens($1.content) + 4 } }

    // MARK: Dates

    /// "2026-10-06 (Tuesday)": the calendar day in `timeZone` (the user's,
    /// not UTC, so a late meeting keeps its day) with its English weekday,
    /// so the model can resolve "on Friday" or "tomorrow".
    public static func day(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd (EEEE)"
        return f.string(from: date)
    }

    /// A model date ("YYYY-MM-DD") as the start of that day in `timeZone`;
    /// nil when it is not a date or is implausibly far (> 3 years) from `reference`.
    /// A day whose midnight does not exist in `timeZone` (a daylight-saving change at 00:00, as in Santiago, Havana or
    /// Beirut) starts at its first moment: `DateFormatter` returns nil for it, so a strict "YYYY-MM-DD" is read as a
    /// `DueDay`, and the formatter only reads the looser forms it accepts ("2026-1-5").
    static func parseDay(_ s: String, reference: Date, timeZone: TimeZone = .current) -> Date? {
        let text = s.trimmingCharacters(in: .whitespaces)
        let d: Date
        if let day = DueDay(text) {
            d = day.startOfDay(in: timeZone)
        } else {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timeZone
            f.dateFormat = "yyyy-MM-dd"
            guard let parsed = f.date(from: text) else { return nil }
            d = parsed
        }
        return abs(d.timeIntervalSince(reference)) < 3 * 365 * 86_400 ? d : nil
    }

    static func clock(_ t: Double) -> String { String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60) }

    // MARK: Words

    /// Whether `name` appears in `text` as whole words, comparing normalized
    /// keys (`TextKeys.norm`): "Ana" is not found in "mañana". Names in
    /// scripts written without spaces (Chinese, Japanese, Thai) are matched
    /// as substrings, since those scripts have no word separators.
    public static func containsWords(_ text: String, _ name: String) -> Bool {
        containsNormalizedWords(TextKeys.norm(text), TextKeys.norm(name))
    }

    static func containsNormalizedWords(_ text: String, _ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        if name.unicodeScalars.contains(where: TextKeys.isNoSpaceScript) { return text.contains(name) }
        return " \(text) ".contains(" \(name) ")
    }

    // MARK: Sanitizing

    /// Material cannot open or close the prompt's delimiters.
    public static func defang(_ text: String) -> String {
        text.replacingOccurrences(of: "<<<", with: "‹‹‹").replacingOccurrences(of: ">>>", with: "›››")
    }

    /// Without control characters (except newlines), trimmed and cut to `n` characters.
    static func clip(_ s: String, _ n: Int) -> String {
        let c = s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" }
        return String(String(String.UnicodeScalarView(c)).trimmingCharacters(in: .whitespacesAndNewlines).prefix(n))
    }
}

/// The language the model must write in, named in English with its BCP-47
/// tag ("Write everything in Spanish (es-ES).").
public struct OutputLanguage: Sendable, Equatable {
    /// BCP-47 tag.
    public let identifier: String

    public init(_ locale: Locale) { identifier = locale.identifier(.bcp47) }

    /// Minutes and answers about a meeting: its output language, else its
    /// transcription language, else the legacy language (es-ES).
    public init(meeting: MeetingStore.Meeting) { self.init(meeting.minutesLocale) }

    /// English name of the language ("Spanish", "Japanese", "Chinese").
    public var englishName: String {
        let locale = Locale(identifier: identifier)
        let code = locale.language.languageCode?.identifier ?? identifier
        return Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? identifier
    }

    /// The sentence that goes into every instruction.
    public var instruction: String { "Write everything in \(englishName) (\(identifier))." }

    /// The language a question is written in, or `fallback` when it cannot
    /// be told (too short or ambiguous). The fallback is kept when the
    /// question is in its language, so its region survives ("es-MX").
    public static func detect(_ text: String, fallback: OutputLanguage) -> OutputLanguage {
        guard let detected = confident(text) else { return fallback }
        let fallbackCode = Locale(identifier: fallback.identifier).language.languageCode
        return Locale(identifier: detected.identifier).language.languageCode == fallbackCode ? fallback : detected
    }

    /// The first of `texts` whose language can be told, else `fallback`: what a person said wins over a rewrite of it.
    public static func detect(_ texts: [String], fallback: OutputLanguage) -> OutputLanguage {
        for text in texts where confident(text) != nil { return detect(text, fallback: fallback) }
        return fallback
    }

    /// The language of `text` when the recognizer is at least half sure of it; nil for a short or ambiguous text.
    public static func confident(_ text: String) -> OutputLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, probability) = recognizer.languageHypotheses(withMaximum: 1).first,
              probability >= 0.5, language != .undetermined else { return nil }
        return OutputLanguage(Locale(identifier: language.rawValue))
    }

    /// Whether both are the same language (the region does not matter).
    public func sameLanguage(as other: OutputLanguage) -> Bool {
        Locale(identifier: identifier).language.languageCode == Locale(identifier: other.identifier).language.languageCode
    }
}
