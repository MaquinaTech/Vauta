// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
internal import NaturalLanguage

/// Deterministic text keys used to recognize names in transcripts: no model,
/// no network and no state. The same input always gives the same output.
public enum TextKeys {
    // MARK: Normalization

    /// Comparison key: Unicode compatibility form, case-, diacritic- and
    /// width-insensitive, only letters and digits, single spaces
    /// ("  Telefónica,  S.A." → "telefonica s a", "Łukasz" → "lukasz",
    /// "مُحَمَّد" → "محمد").
    ///
    /// It defines the persisted `aliases.alias_norm`, so it is deliberately
    /// independent of any locale (system or meeting). Changing it requires
    /// re-running `MeetingStore.recomputeAliasNormalization(_:)`.
    public static func norm(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var scalars = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            if isIgnorableMark(scalar) { continue }
            if let replacement = letterFolding[scalar] {
                scalars.append(contentsOf: replacement.unicodeScalars)
            } else {
                scalars.append(scalar)
            }
        }
        var out = ""
        out.reserveCapacity(scalars.count)
        var pendingSpace = false
        for ch in String(scalars) {
            if ch.isLetter || ch.isNumber {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(ch)
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    /// Letters that diacritic folding keeps but people (and transcribers)
    /// write interchangeably with a base letter. Applied after case folding,
    /// so only lowercase forms are needed. `ß` already folds to "ss".
    private static let letterFolding: [Unicode.Scalar: String] = [
        "ł": "l", "ø": "o", "æ": "ae", "œ": "oe", "đ": "d", "ð": "d", "þ": "th", "ı": "i", "ħ": "h", "ŧ": "t",
    ]

    /// Arabic harakat, Quranic annotation marks and tatweel, and Hebrew points
    /// and cantillation marks: optional vocalization that does not change the word.
    private static func isIgnorableMark(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x0610...0x061A, 0x064B...0x065F, 0x0670, 0x06D6...0x06DC, 0x06DF...0x06E8, 0x06EA...0x06ED, 0x0640:
            true
        case 0x0591...0x05BD, 0x05BF, 0x05C1...0x05C2, 0x05C4...0x05C5, 0x05C7:
            true
        default:
            false
        }
    }

    // MARK: Scripts written without spaces

    /// Scripts whose words are not separated by spaces (Han, Kana, Thai, Lao,
    /// Khmer, Myanmar). Names in them are matched without word separators.
    public static func isNoSpaceScript(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x0E00...0x0EFF,            // Thai, Lao
             0x1000...0x109F,            // Myanmar
             0x1780...0x17FF,            // Khmer
             0x3005, 0x3007,             // ideographic iteration and zero
             0x3040...0x30FF,            // Hiragana, Katakana
             0x31F0...0x31FF,            // Katakana phonetic extensions
             0x3400...0x4DBF,            // CJK extension A
             0x4E00...0x9FFF,            // CJK unified ideographs
             0xF900...0xFAFF,            // CJK compatibility ideographs
             0xFF66...0xFF9F,            // half-width Katakana
             0x20000...0x323AF:          // CJK extensions B…H
            true
        default:
            false
        }
    }

    public static func isNoSpaceScript(_ ch: Character) -> Bool {
        ch.unicodeScalars.first.map(isNoSpaceScript) ?? false
    }

    /// Canonical key for exact matching: a normalized key with the spaces
    /// between two no-space-script characters removed, so "王 伟", the
    /// tokens ["王", "伟"] and the alias "王伟" all give "王伟".
    public static func matchKey(_ normalized: String) -> String {
        guard normalized.contains(" ") else { return normalized }
        let chars = Array(normalized)
        var out = ""
        out.reserveCapacity(chars.count)
        for (i, ch) in chars.enumerated() {
            if ch == " ", i > 0, i + 1 < chars.count, isNoSpaceScript(chars[i - 1]), isNoSpaceScript(chars[i + 1]) { continue }
            out.append(ch)
        }
        return out
    }

    // MARK: Tokens

    /// A word of a text with its original form, its normalized form and its
    /// range in the original string (for surfaces such as "Jean-Luc").
    public struct Token: Sendable, Equatable {
        public let original: String
        public let norm: String
        public let range: Range<String.Index>
        /// Starts with an uppercase letter and does not open a sentence.
        /// Only a proper-noun hint in languages where `LanguageProfile.capitalizationMarksNames`.
        public let capitalizedMidSentence: Bool
    }

    /// Words of `text` segmented with the rules of the given language (not
    /// the system locale), so the result does not depend on the Mac's settings.
    public static func tokens(_ text: String, profile: LanguageProfile = .legacy) -> [Token] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(NLLanguage(rawValue: profile.languageCode))
        var out: [Token] = []
        var sentenceStart = true
        var lastEnd = text.startIndex
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            // NLTokenizer can return a range that starts inside the previous
            // one ("6.4に"), so the gap between them may be empty.
            if lastEnd < range.lowerBound,
               text[lastEnd..<range.lowerBound].contains(where: profile.isSentenceTerminator) { sentenceStart = true }
            lastEnd = max(lastEnd, range.upperBound)
            let word = String(text[range])
            let n = norm(word)
            guard !n.isEmpty else { return true }
            out.append(Token(original: word, norm: n, range: range,
                             capitalizedMidSentence: !sentenceStart && (word.first?.isUppercase ?? false)))
            sentenceStart = false
            return true
        }
        return out
    }

    // MARK: Fuzzy keys

    /// Bounded Levenshtein distance: returns `limit + 1` as soon as the
    /// distance is known to exceed it (O(n·limit), not the whole matrix).
    public static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        if abs(x.count - y.count) > limit { return limit + 1 }
        if x.isEmpty || y.isEmpty { return max(x.count, y.count) }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            var rowMin = cur[0]
            let lo = max(1, i - limit), hi = min(y.count, i + limit)
            if lo > 1 { cur[lo - 1] = limit + 1 }
            if lo <= hi {
                for j in lo...hi {
                    let cost = x[i - 1] == y[j - 1] ? 0 : 1
                    cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                    rowMin = min(rowMin, cur[j])
                }
            }
            if hi < y.count { cur[hi + 1] = limit + 1 }
            if rowMin > limit { return limit + 1 }
            swap(&prev, &cur)
        }
        return min(prev[y.count], limit + 1)
    }

    /// Approximate Spanish sound key: groups what a Spanish transcriber
    /// confuses by ear (b/v, ll/y, c/z/s, k/qu/c, g/j, silent h, double
    /// letters). "Vallejo" and "Ballejo" → "bayejo"; "Quique" and "Kike" → "kike".
    /// Only valid for Spanish-like orthographies: use `LanguageProfile.phoneticKey`,
    /// which returns nil for languages where these rules do not hold.
    public static func phonetic(_ text: String) -> String {
        let s = Array(norm(text).replacingOccurrences(of: " ", with: ""))
        var out: [Character] = []
        var i = 0
        func next(_ k: Int) -> Character? { i + k < s.count ? s[i + k] : nil }
        while i < s.count {
            let c = s[i]
            var emit: String
            var skip = 1
            switch c {
            case "v", "w": emit = "b"
            case "z": emit = "s"
            case "x": emit = "ks"
            case "h": emit = ""
            case "y": emit = (next(1).map { "aeiou".contains($0) } ?? false) ? "y" : "i"
            case "l": emit = next(1) == "l" ? "y" : "l"; if next(1) == "l" { skip = 2 }
            case "q": emit = "k"; if next(1) == "u" { skip = 2 }
            case "c":
                if next(1) == "h" { emit = "ch"; skip = 2 }
                else if let n = next(1), "ei".contains(n) { emit = "s" }
                else { emit = "k" }
            case "g":
                if let n = next(1), "ei".contains(n) { emit = "j" }
                else if next(1) == "u", let n = next(2), "ei".contains(n) { emit = "g"; skip = 2 }
                else { emit = "g" }
            default: emit = String(c)
            }
            for e in emit where out.last != e { out.append(e) }
            i += skip
        }
        return String(out)
    }
}
