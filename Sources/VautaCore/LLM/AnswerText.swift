// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The text of an Ask answer, cleaned of what belongs to the citations: segment tags (`[S12]`, `[S5 · 01:18 · Others]`, `(S20:39)`,
/// `[D2]`), timestamps in brackets (`[01:18]`, `(12:34)`) and the words a model copies from the prompt's placeholders. The
/// citations carry the evidence; the sentence is for reading.
enum AnswerText {
    /// A bracket or parenthesis that holds a segment (`S12`) or document (`D2`) number written the way Vauta writes it: the number
    /// alone (`[S12]`), or followed by `·`, `:` or `,` and the rest (`[S5 · 01:18 · Others]`, `(S20:39)`, `[S12, S13]`). Uppercase
    /// only, and not "(S3 bucket)" or "[D1 visa]": a product or plan name that happens to start with S or D and a digit stays.
    private static let tag = try! NSRegularExpression(pattern: #"[\[\(（［]\s*([SD]\d+)(?:\s*[·:,][^\]\)）］\n]{0,80})?\s*[\]\)）］]"#)
    /// A time on its own in brackets: `[01:18]`, `(1:02:33)`.
    private static let clock = try! NSRegularExpression(pattern: #"[\[\(（［]\s*\d{1,2}:\d{2}(?::\d{2})?\s*[\]\)）］]"#)
    private static let spaceBeforePunctuation = try! NSRegularExpression(pattern: #"\s+([,.;:!?])"#)

    /// `codes`: the segment and document codes that were sent (`S12`, `D2`). When given, a tag is removed only if its code is one of
    /// them, so "vitamin (D3)" or "Audi (S3)" keep theirs unless that very code was in the material; nil removes every tag.
    static func clean(_ text: String, codes: Set<String>? = nil) -> String {
        var out = stripRangesAndMarkup(text, codes: codes)
        for match in tag.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
            guard let whole = Range(match.range, in: out), let code = Range(match.range(at: 1), in: out) else { continue }
            if let codes, !codes.contains(String(out[code])) { continue }
            out.replaceSubrange(whole, with: "")
        }
        out = clock.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "")
        out = spaceBeforePunctuation.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1")
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Words of the prompts' old skeleton that a model may write back instead of an answer.
    static func isPlaceholder(_ text: String) -> Bool {
        let t = TextKeys.norm(text)
        return t.isEmpty || t == "a short answer" || t.contains("say you cannot find it") || t == "answer" || t == "respuesta"
    }

    /// More than a refusal sentence: a model that writes `found` false and then an answer of its own. A refusal ("I can't find that in
    /// your meetings") is short and has no figure in it; this is about thirteen words, eighty characters (for the scripts that do not
    /// separate words) or a number.
    static func isSubstantive(_ text: String) -> Bool {
        guard !isPlaceholder(text) else { return false }
        return text.split(whereSeparator: \.isWhitespace).count > 12 || text.count > 80 || (text.count > 40 && text.contains { $0.isNumber })
    }
}

// MARK: Ranges, markup and segment numbers written as words (11b)

extension AnswerText {
    /// `(S3 to S43)`, `(S3–S43)`, `[S3 - S43]`, `(segments 3 to 43)`, `(S3 a S43)`: a range of segments in brackets. It needs a marker
    /// that says "segment": the S or D before a number, or the word (a years range `(2025-2026)`, a scale `(1 to 5)` or `(18-25)`
    /// is prose and stays). Groups: 1 the word, 2 the letter of the first number, 3 the number, 4 and 5 the same for the second.
    private static let rangeTag = try! NSRegularExpression(
        pattern: #"[\[\(（［]\s*(segments?|segmentos?|segmente?|segmenti|Seg\.?)?\s*([SD]?)(\d+)\s*(?:to|a|à|al|bis|e|et|und|through|thru|–|—|-|~|から|까지|到|至)\s*([SD]?)(\d+)\s*[\]\)）］]"#,
        options: [.caseInsensitive])
    /// The same without brackets, only in the `S3-S43` form (an unbracketed "from 3 to 5" is just prose).
    private static let bareRange = try! NSRegularExpression(pattern: #"\bS(\d+)\s*[–—-]\s*S(\d+)\b"#)
    /// `$…$` that holds markup.
    private static let dollars = try! NSRegularExpression(pattern: #"\$([^$\n]{1,200})\$"#)
    private static let wrapper = try! NSRegularExpression(pattern: #"(?:\\|\t)(?:text|mathrm|mathbf|textbf|mathit|textit|operatorname)\{([^{}]*)\}"#)
    private static let tabWrapper = try! NSRegularExpression(pattern: #"\t(?:ext|extbf)\{([^{}]*)\}"#)

    /// Removes segment ranges (the sent codes only, like `clean`'s tags) and unwraps `$\text{25 Euro}$`. The JSON artefact in which
    /// a `\t` of `\text` became a tab is repaired the same way. Dollar amounts (`$25`, `$5–$10`) are left alone.
    static func stripRangesAndMarkup(_ text: String, codes: Set<String>?) -> String {
        var out = text
        for match in rangeTag.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
            guard let whole = Range(match.range, in: out), let a = Range(match.range(at: 3), in: out), let b = Range(match.range(at: 5), in: out) else { continue }
            let prefixA = Range(match.range(at: 2), in: out).map { String(out[$0]).uppercased() } ?? ""
            let prefixB = Range(match.range(at: 4), in: out).map { String(out[$0]).uppercased() } ?? ""
            guard match.range(at: 1).location != NSNotFound || !prefixA.isEmpty || !prefixB.isEmpty else { continue }
            if let codes {
                // A bracket of the form "(S3 to S43)" is removed only when its codes were sent; "(segments 3 to 43)" when S3 was.
                let ca = (prefixA.isEmpty ? "S" : prefixA) + out[a], cb = (prefixB.isEmpty ? "S" : prefixB) + out[b]
                guard codes.contains(ca) || codes.contains(cb) else { continue }
            }
            out.replaceSubrange(whole, with: "")
        }
        for match in bareRange.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
            guard let whole = Range(match.range, in: out), let a = Range(match.range(at: 1), in: out), let b = Range(match.range(at: 2), in: out) else { continue }
            if let codes, !codes.contains("S" + out[a]), !codes.contains("S" + out[b]) { continue }
            out.replaceSubrange(whole, with: "")
        }
        for match in dollars.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
            guard let whole = Range(match.range, in: out), let inner = Range(match.range(at: 1), in: out) else { continue }
            var body = String(out[inner])
            guard body.contains("\\") || body.contains("{") || body.contains("}") || body.contains("\t") else { continue }
            body = tabWrapper.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "$1")
            body = wrapper.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "$1")
            body = body.replacingOccurrences(of: "\\%", with: "%").replacingOccurrences(of: "\\", with: "")
                .replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
            out.replaceSubrange(whole, with: body.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out
    }

    // MARK: Segment numbers as words

    private static let segmentWord = #"(?:(?<![\p{L}])segment(?:os|o|en|e|s|i)?(?![\p{L}])|セグメント|세그먼트|片段)"#
    private static let before = #"(?:(?:in den|in|en los|en las|en el|en|im|dans les|dans le|dans|nei|nelle|nel|nos|nas|no|na|em|aux|au|à|at|from|del|de)\s+)?"#
    private static let marker = #"(?:\s*(?:n[°ºo]\.?|#|numbers?|número|numéro|nummer|numero|nº|№))?"#
    private static let joiners: Set<String> = ["and", "to", "y", "a", "e", "et", "à", "und", "bis", "~", "から", "까지", "到", "和", "through", "-", "–"]
    private static let digitsOrWords = try! NSRegularExpression(
        pattern: "(\\(\\s*)?(\(before))(\(segmentWord))(\(marker))\\s*", options: [.caseInsensitive])

    /// "in segment 5143", "en los segmentos cinco mil ciento cuarenta y tres y cinco mil ciento cuarenta y cuatro", "(segment 12 to 14)":
    /// the segment number written in words or digits goes (the citations carry it). A segment word with no number after it ("the
    /// segment of customers") stays. `language`: the BCP-47 code of the answer, for spelled-out numbers.
    ///
    /// A number is only taken for a segment's when something says so: a bracket before the word, a preposition ("in segment 5") whose
    /// number was sent (`codes`; without the codes the preposition decides), the word of a script written without spaces
    /// (セグメント12), or, for digits, a number that was sent. "Customer segment two
    /// grew" and "targeting segment 18-25" stay.
    static func dropSegmentWords(_ text: String, language: String? = nil, codes: Set<String>? = nil) -> String {
        var out = text
        let locale = Locale(identifier: language ?? "en")
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = locale
        var searchFrom = out.startIndex
        while let match = digitsOrWords.firstMatch(in: out, range: NSRange(searchFrom..., in: out)) {
            guard let whole = Range(match.range, in: out) else { break }
            let opening = match.range(at: 1).location != NSNotFound
            guard let afterFirst = numberEnd(in: out, from: whole.upperBound, formatter: formatter) else { searchFrom = whole.upperBound; continue }
            let hasPreposition = Range(match.range(at: 2), in: out).map { !out[$0].isEmpty } ?? false
            let word = Range(match.range(at: 3), in: out).map { String(out[$0]) } ?? ""
            let spaceless = ["セグメント", "세그먼트", "片段"].contains(word)
            let number = out[whole.upperBound..<afterFirst].trimmingCharacters(in: .whitespaces)
            let sent = codes?.contains("S" + number) == true
            // A preposition alone ("growth in segment 3 of the market", "nos enfocaremos en el segmento dos") is not enough when the codes
            // that were sent are known: the number must be one of them. Without the codes (a caller that has none) the preposition decides.
            let value = Int(number) ?? formatter.number(from: number)?.intValue
            let prepositionSaysSo = hasPreposition && (codes == nil || value.map { codes?.contains("S\($0)") == true } == true)
            guard opening || prepositionSaysSo || spaceless || sent else { searchFrom = whole.upperBound; continue }
            var end = afterFirst
            // "(and|to|y|…) <number>"
            let restRange = out[end...]
            if let join = restRange.firstMatch(of: /^\s*(and|to|y|a|e|et|à|und|bis|through|~|から|까지|到|和)\s*/.ignoresCase()),
               let second = numberEnd(in: out, from: join.range.upperBound, formatter: formatter) {
                end = second
            }
            // A trailing particle (ja に / で, ko 에서) and the closing bracket of an opening one.
            if let particle = out[end...].firstMatch(of: /^(に|で|では|에서)/) { end = particle.range.upperBound }
            if opening, let close = out[end...].firstMatch(of: /^\s*[\)）]/) { end = close.range.upperBound }
            let start = whole.lowerBound
            out.replaceSubrange(start..<end, with: "")
            searchFrom = start
        }
        guard out != text else { return text }
        out = out.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The end of a number that starts at `from`: digits, or the longest run of up to eight words the formatter reads as a number.
    private static func numberEnd(in text: String, from: String.Index, formatter: NumberFormatter) -> String.Index? {
        if let digits = text[from...].firstMatch(of: /^\d+/) { return digits.range.upperBound }
        var words: [Range<String.Index>] = []
        var cursor = from
        while words.count < 8, let w = text[cursor...].firstMatch(of: /^\s*([\p{L}\-]+)/) {
            words.append(w.range)
            cursor = w.range.upperBound
        }
        for count in stride(from: words.count, through: 1, by: -1) {
            let slice = text[from..<words[count - 1].upperBound].trimmingCharacters(in: .whitespaces)
            if let n = formatter.number(from: slice), n.intValue > 0 || slice.lowercased() == "zero" { return words[count - 1].upperBound }
        }
        return nil
    }
}

extension MinutesText {
    /// The prose of the minutes (title, summary, items, topics, questions) without what belongs to the citations: segment tags and
    /// ranges, segment numbers written as words, and TeX markup.
    static func cleanProse(_ text: String, codes: Set<String>? = nil, language: String? = nil) -> String {
        AnswerText.dropSegmentWords(AnswerText.clean(text, codes: codes), language: language, codes: codes)
    }
}

extension MinutesText {
    /// 1 when a summary does not end in sentence punctuation (the sign of a string cut short), else nil. For traces only.
    static func unfinishedTail(_ summary: String) -> Int? {
        guard summary.count >= 20, let last = summary.trimmingCharacters(in: .whitespacesAndNewlines).last else { return nil }
        return ".!?。！？…".contains(last) || last == "”" || last == "»" || last == ")" ? nil : 1
    }
}
