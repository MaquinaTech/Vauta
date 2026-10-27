// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The key a quote is compared by, ignoring case, punctuation, spacing and filler words ("uh", "um", "えーと", "嗯"…), the same on
/// both sides (the quote and the segment), so the filler words a transcript keeps or drops never decide whether a quote is real.
public enum QuoteKey {
    /// Whether a run of spelled-out single letters ("T V") is read as the acronym ("TV"). Off by default: the
    /// shipped rule ignores only case, punctuation, whitespace and filler words, as approved. The code stays so the decision is one line.
    public static let joinsSpelledInitials = false

    /// Words of `text` after `TextKeys.norm`, fillers removed, runs of single consonant letters ("T V") joined ("tv") only when
    /// `joinInitials`, and every character of a script written without spaces as a word of its own. `language` is the BCP-47 tag or
    /// language code of the transcript; nil removes only the interjections no app language also uses as a word.
    public static func make(_ text: String, language: String? = nil, joinInitials: Bool = QuoteKey.joinsSpelledInitials) -> [String] {
        var norm = TextKeys.norm(text)
        let code = languageCode(language)
        if code == "ja" || code == "zh" || code == nil {
            for filler in cjkFillers(code) where norm.contains(filler) { norm = norm.replacingOccurrences(of: filler, with: " ") }
        }
        let fillers = fillers(for: code)
        let squeezed = Set(fillers.map(squeeze))
        var tokens: [String] = []
        for chunk in norm.split(separator: " ") {
            var current = ""
            func flush() {
                guard !current.isEmpty else { return }
                defer { current = "" }
                if fillers.contains(current) { return }
                if isElongatedFiller(current, squeezed: squeezed) { return }
                tokens.append(current)
            }
            for ch in chunk {
                if TextKeys.isNoSpaceScript(ch) { flush(); tokens.append(String(ch)) } else { current.append(ch) }
            }
            flush()
        }
        return joinInitials ? Self.joinInitials(tokens) : tokens
    }

    /// A filler stretched out ("ummm", "hmmm", "uhh"): the word is a filler once each run of one letter is written once, and the
    /// letters that repeat are those a hesitation is made of. "err" (a word) is not one.
    private static func isElongatedFiller(_ word: String, squeezed: Set<String>) -> Bool {
        let s = squeeze(word)
        guard s != word, squeezed.contains(s), word.allSatisfy({ $0.isLetter && $0.isASCII }) else { return false }
        var previous: Character?
        for ch in word {
            if ch == previous, !"uhmaen".contains(ch) { return false }
            previous = ch
        }
        return true
    }

    /// "t v" → "tv": single letters in a row are an acronym spelled out. A run joins only when none of its letters is also a word
    /// ("a", "e", "i", "o", "y"), so "a b c" is never merged across real words.
    private static func joinInitials(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var run: [String] = []
        func flush() {
            defer { run = [] }
            let letters = run.compactMap(\.first)
            let joins = run.count >= 2 && !letters.contains { realWords.contains($0) }
            if joins { out.append(run.joined()) } else { out += run }
        }
        for t in tokens {
            if t.count == 1, let c = t.first, c.isLetter, c.isASCII { run.append(t) } else { flush(); out.append(t) }
        }
        flush()
        return out
    }

    private static let realWords: Set<Character> = ["a", "e", "i", "o", "y"]

    /// The letters of `word` with each run of one letter written once ("ummm" → "um", "hmm" → "hm").
    static func squeeze(_ word: String) -> String {
        var out = ""
        for ch in word where ch != out.last { out.append(ch) }
        return out
    }

    static func languageCode(_ language: String?) -> String? {
        guard let language, !language.isEmpty else { return nil }
        let base = language.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init)?.lowercased()
        return base
    }

    /// Whole-word fillers. Only interjections that are not also words of the language: "este" (es), "é" (pt), "那个" (zh) and
    /// "그" (ko) are words and are never removed; "um" is a word in Portuguese and "er" in German.
    static func fillers(for code: String?) -> Set<String> {
        let common: Set<String> = ["mm", "mmm", "hm", "hmm", "mhm", "uh", "ah", "eh"]
        switch code {
        case "en": return common.union(["um", "er", "erm", "uhm", "ehm"])
        case "es": return common.union(["ehm", "uhm"])
        case "fr": return common.union(["euh", "heu", "hum"])
        case "de": return common.union(["ahm", "ehm", "hum"])
        case "it": return common.union(["ehm", "uhm"])
        // "hã" folds to "ha", which is also the verb "há": it is not removed.
        case "pt": return common.union(["ahn", "hum", "ehm"])
        case "ko": return ["어", "음", "으음"]
        case "ja", "zh": return ["mm", "hm", "hmm"]
        default: return ["mm", "mmm", "hm", "hmm", "mhm", "uhm", "ehm", "euh", "heu"]
        }
    }

    /// Fillers of the scripts written without spaces, removed wherever they occur (longest first).
    static func cjkFillers(_ code: String?) -> [String] {
        switch code {
        case "ja": return ["あのー", "えーと", "えっと", "うーん", "えー"]
        case "zh": return ["嗯", "呃", "唔"]
        case nil: return ["あのー", "えーと", "えっと", "うーん", "えー", "嗯", "呃", "唔"]
        default: return []
        }
    }

    /// Whether `needle` is a contiguous run of `hay`.
    static func contains(_ hay: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        let first = needle[0]
        var i = 0
        let last = hay.count - needle.count
        while i <= last {
            if hay[i] == first {
                var j = 1
                while j < needle.count, hay[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }

    /// A quote is long enough to anchor on when its key has 8 characters and at least 3 words, or 6 characters of a script written
    /// without spaces: a short common phrase ("I think") is never re-anchored.
    static func isAnchorable(_ key: [String]) -> Bool {
        guard key.joined(separator: " ").count >= 8 else { return false }
        let cjk = key.filter { $0.count == 1 && TextKeys.isNoSpaceScript($0.first!) }.count
        let words = key.count - cjk
        return words >= 3 || cjk >= 6
    }
}

/// Finds where a quote really is. A claim or item is kept only when its quote appears word for word, ignoring case, punctuation,
/// spacing and filler words, in the segment it cites or, if the model cited the wrong one, in the nearest segment of the material
/// that was visible. Matching is literal against the transcript: nothing is translated, so a quote in another language never matches.
public enum QuoteAnchor {
    public enum How: Sendable, Equatable {
        /// Word for word in the cited segment (the rule before re-anchoring).
        case exact
        /// In the cited segment once fillers and spacing are ignored.
        case modulo
        /// In another segment: the nearest occurrence to the one cited.
        case reanchored(from: Int64?)
    }

    public struct Match: Sendable, Equatable {
        public let segment: Int64
        public let how: How
    }

    /// The segments a quote may be anchored in, with their keys computed once.
    public struct Pool: Sendable {
        let entries: [(id: Int64, key: [String])]
        let position: [Int64: Int]
        let language: String?
        let byID: [Int64: CitableSegment]
        /// The meeting of each segment, when the pool holds several: a quote is only moved within the meeting it was cited in.
        let group: [Int64: Int64]

        /// `languages`: the transcription language of each segment when the pool spans meetings in different languages (the library); the
        /// segments it does not list use `language`.
        public init(_ segments: [CitableSegment], language: String? = nil, groups: [Int64: Int64] = [:], languages: [Int64: String] = [:]) {
            self.language = language
            group = groups
            byID = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            entries = segments.map { ($0.id, QuoteKey.make($0.text, language: languages[$0.id] ?? language)) }
            var p: [Int64: Int] = [:]
            for (i, e) in entries.enumerated() { p[e.id] = i }
            position = p
        }

        public func segment(_ id: Int64) -> CitableSegment? { byID[id] }
        public var isEmpty: Bool { entries.isEmpty }
        public var count: Int { entries.count }
    }

    /// Looks for `quote` in the cited segment, then in the pool.
    /// - Parameters:
    ///   - cited: the segment id the model cited (nil if it cited none that exists).
    ///   - citedText: that segment's text when it is known.
    ///   - pool: the visible segments, in time order (nil: no re-anchoring).
    public static func resolve(quote: String?, cited: Int64?, citedText: String?, pool: Pool?, language: String? = nil) -> Match? {
        let q = TextKeys.norm(quote ?? "")
        guard q.count >= 8 else { return nil }
        // The cited segment was visible but may not have been sent (retrieval): its text is in the pool.
        let citedText = citedText ?? cited.flatMap { pool?.segment($0)?.text }
        if let cited, let citedText, TextKeys.norm(citedText).contains(q) { return Match(segment: cited, how: .exact) }
        let key = QuoteKey.make(quote ?? "", language: language)
        guard QuoteKey.isAnchorable(key) else { return nil }
        if let cited, let citedText, QuoteKey.contains(QuoteKey.make(citedText, language: language), key) {
            return Match(segment: cited, how: .modulo)
        }
        guard let pool else { return nil }
        var best: (id: Int64, distance: Int, position: Int)?
        let anchorPosition = cited.flatMap { pool.position[$0] }
        let citedGroup = cited.flatMap { pool.group[$0] }
        for (i, entry) in pool.entries.enumerated() where entry.id != cited && QuoteKey.contains(entry.key, key) {
            if let citedGroup, pool.group[entry.id] != citedGroup { continue }
            let distance: Int
            if let anchorPosition { distance = abs(i - anchorPosition) }
            else if let cited { distance = Int(clamping: abs(entry.id - cited)) }
            else { distance = i }
            if best == nil || distance < best!.distance { best = (entry.id, distance, i) }
        }
        guard let best else { return nil }
        return Match(segment: best.id, how: .reanchored(from: cited))
    }
}
