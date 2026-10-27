// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What two decisions that look alike differ in, by rules on their words. No model. A pair is **changed** only when the
/// difference sits in the same role on both sides: one figure with the same unit, one date in a deadline role, a reversal attached to a
/// shared verb or object, or a status pair. A pair that differs in a way that makes them different subjects (another quarter, several
/// other figures) is **unrelated** and is dropped. Anything else is **same**. Tasks are only ever "same".
enum LinkDifference {
    enum Verdict: Equatable {
        case same
        case changes(LinkEvidence)
        case unrelated
    }

    /// A figure of a text: its digits, its unit and the words as written.
    struct Figure: Equatable {
        var value: String
        var unit: String
        var span: String
    }

    /// The read of one text.
    struct Reading {
        var figures: [Figure] = []
        /// A quarter, a half, a year, a month or a numbered week: another one is another subject.
        var periods: Set<String> = []
        /// Dates with their words ("12 Oct") and the word that leads them, for the deadline role.
        var dates: [(key: String, span: String, leaders: Set<String>)] = []
        var weekdays: [(day: Int, span: String, leaders: Set<String>)] = []
    }

    /// `language` is the items' language (they share it, D16); the meeting's language when it is not given.
    static func judge(kind: LinkKind, newer: String, earlier: String, locale: String, language itemLanguage: String? = nil, wordsShared: Set<String>? = nil) -> Verdict {
        guard kind == .decision else { return .same }
        let language = LanguageProfile(identifier: locale)
        let code = itemLanguage ?? language.languageCode
        let now = read(newer, profile: language, language: code), before = read(earlier, profile: language, language: code)

        // Another period, quarter or year: different subjects.
        let periodsNow = now.periods.subtracting(before.periods), periodsBefore = before.periods.subtracting(now.periods)
        if !periodsNow.isEmpty, !periodsBefore.isEmpty { return .unrelated }

        // Figures: exactly one differing value on each side, in the same unit.
        let onlyNow = now.figures.filter { f in !before.figures.contains { $0.value == f.value } }
        let onlyBefore = before.figures.filter { f in !now.figures.contains { $0.value == f.value } }
        let figureDiffers = !onlyNow.isEmpty && !onlyBefore.isEmpty
        if figureDiffers, onlyNow.count != 1 || onlyBefore.count != 1 || onlyNow[0].unit != onlyBefore[0].unit { return .unrelated }

        // Dates and weekdays: exactly one differing on each side, both after the same word.
        let dateNow = now.dates.filter { d in !before.dates.contains { $0.key == d.key } }
        let dateBefore = before.dates.filter { d in !now.dates.contains { $0.key == d.key } }
        let dayNow = now.weekdays.filter { d in !before.weekdays.contains { $0.day == d.day } }
        let dayBefore = before.weekdays.filter { d in !now.weekdays.contains { $0.day == d.day } }
        let spansNow = dateNow.map(\.span) + dayNow.map(\.span), spansBefore = dateBefore.map(\.span) + dayBefore.map(\.span)
        let leadersNow = dateNow.flatMap(\.leaders) + dayNow.flatMap(\.leaders), leadersBefore = dateBefore.flatMap(\.leaders) + dayBefore.flatMap(\.leaders)
        let dateDiffers = !spansNow.isEmpty && !spansBefore.isEmpty
        if dateDiffers, spansNow.count != 1 || spansBefore.count != 1 || Set(leadersNow).isDisjoint(with: leadersBefore) { return .unrelated }

        if figureDiffers && dateDiffers { return .unrelated }
        if figureDiffers { return .changes(LinkEvidence(earlier: [onlyBefore[0].span], now: [onlyNow[0].span])) }
        if dateDiffers { return .changes(LinkEvidence(earlier: spansBefore, now: spansNow)) }

        // A status pair: approved against rejected.
        let foldedNow = TextKeys.norm(newer), foldedBefore = TextKeys.norm(earlier)
        let sharedWords = wordsShared ?? LinkText.words(newer, locale: locale).intersection(LinkText.words(earlier, locale: locale))
        if sharedWords.count >= 2 {
            let approvedNow = BriefStatusWords.claims(in: foldedNow, BriefStatusWords.decided), approvedBefore = BriefStatusWords.claims(in: foldedBefore, BriefStatusWords.decided)
            let rejectedNow = BriefStatusWords.claims(in: foldedNow, LinkDifferenceWords.rejected), rejectedBefore = BriefStatusWords.claims(in: foldedBefore, LinkDifferenceWords.rejected)
            if !approvedBefore.isEmpty, !rejectedNow.isEmpty, approvedNow.isEmpty, rejectedBefore.isEmpty {
                return .changes(LinkEvidence(earlier: [approvedBefore[0]], now: [rejectedNow[0]]))
            }
            if !rejectedBefore.isEmpty, !approvedNow.isEmpty, rejectedNow.isEmpty, approvedBefore.isEmpty {
                return .changes(LinkEvidence(earlier: [rejectedBefore[0]], now: [approvedNow[0]]))
            }
        }

        // A reversal in one text only, attached to a word both texts share in the same clause.
        let shared = sharedWords
        if let phrase = reversal(in: newer, other: foldedBefore, shared: shared, locale: locale, language: code) {
            return .changes(LinkEvidence(earlier: [], now: [phrase]))
        }
        if let phrase = reversal(in: earlier, other: foldedNow, shared: shared, locale: locale, language: code) {
            return .changes(LinkEvidence(earlier: [phrase], now: []))
        }
        return .same
    }

    // MARK: Reversals

    /// A polarity phrase that `text` has and `other` (folded) has not, in a clause that also holds one of the `shared` content words. Clauses end
    /// at . ? ! ; so a reversal of one thing does not touch the next sentence.
    static func reversal(in text: String, other: String, shared: Set<String>, locale: String, language: String?) -> String? {
        guard !shared.isEmpty else { return nil }
        let clauses = text.split(whereSeparator: { ".?!;。？！；".contains($0) }).map(String.init)
        for clause in clauses {
            let folded = TextKeys.norm(clause)
            let near = QuestionDedup.keys(clause, locale: locale)
            guard !near.isDisjoint(with: shared) else { continue }
            for phrase in LinkDifferenceWords.polarity(for: language) {
                let cjk = BriefStatusWords.isCJK(phrase)
                let here = cjk ? folded.contains(phrase) : PromptText.containsNormalizedWords(folded, phrase)
                let there = cjk ? other.contains(phrase) : PromptText.containsNormalizedWords(other, phrase)
                if here, !there { return phrase }
            }
        }
        return nil
    }

    // MARK: Reading a text

    static func read(_ text: String, profile: LanguageProfile, language: String? = nil) -> Reading {
        var reading = Reading()
        let source = Array(text.precomposedStringWithCompatibilityMapping)
        // Tokens: a number run keeps its separators; a word is letters; everything else is a gap.
        struct Token { var text: String; var isNumber: Bool; var range: Range<Int> }
        var tokens: [Token] = []
        var i = 0
        func isDigit(_ k: Int) -> Bool { k < source.count && source[k].isASCII && source[k].isNumber }
        while i < source.count {
            let ch = source[i]
            if isDigit(i) {
                var j = i + 1
                while j < source.count {
                    if isDigit(j) { j += 1 }
                    else if ".,'\u{00A0}\u{202F}".contains(source[j]), isDigit(j + 1) { j += 1 }
                    else if source[j] == " ", j - i <= 3 || source[i..<j].contains(where: { !$0.isNumber }),
                            isDigit(j + 1), isDigit(j + 2), isDigit(j + 3), !isDigit(j + 4) { j += 4 }   // "48 200"
                    else { break }
                }
                tokens.append(Token(text: String(source[i..<j]), isNumber: true, range: i..<j))
                i = j
            } else if ch.isLetter {
                var j = i + 1
                while j < source.count, source[j].isLetter { j += 1 }
                tokens.append(Token(text: String(source[i..<j]), isNumber: false, range: i..<j))
                i = j
            } else {
                tokens.append(Token(text: String(ch), isNumber: false, range: i..<(i + 1)))
                i += 1
            }
        }
        func folded(_ k: Int) -> String { k >= 0 && k < tokens.count ? TextKeys.norm(tokens[k].text) : "" }
        func isWord(_ k: Int) -> Bool { k >= 0 && k < tokens.count && tokens[k].text.first?.isLetter == true }
        func span(_ from: Int, _ to: Int) -> String {
            guard from <= to, from >= 0, to < tokens.count else { return "" }
            return String(source[tokens[from].range.lowerBound..<tokens[to].range.upperBound]).trimmingCharacters(in: .whitespaces)
        }
        /// The previous words (up to four) as the "leaders" of a date: the words that say what the date is for.
        func leaders(before k: Int) -> Set<String> {
            var out = Set<String>()
            var n = 0, p = k - 1
            while p >= 0, n < 4 {
                if isWord(p) { let f = folded(p); if f.count >= 2, !LinkDifferenceWords.dateJoiners.contains(f) { out.insert(f) }; n += 1 }
                p -= 1
            }
            return out
        }
        let abbreviations = LinkDifferenceWords.monthAbbreviations(for: language ?? profile.languageCode)
        func monthNumber(_ k: Int) -> Int? {
            guard isWord(k) else { return nil }
            let f = folded(k)
            if let m = DateWords.months.first(where: { $0.value.contains(f) })?.key { return m }
            guard let m = abbreviations[f] else { return nil }
            // "may", "mar", "set"… are months only as "May", "12 mar.": a capital or a full stop.
            if LinkDifferenceWords.ambiguousAbbreviations.contains(f) {
                let written = tokens[k].text
                let capital = written.first?.isUppercase == true
                let stop = k + 1 < tokens.count && tokens[k + 1].text == "."
                guard capital || stop else { return nil }
            }
            return m
        }
        /// Next/previous word index skipping joiners and gaps.
        func neighbor(of k: Int, step: Int) -> Int? {
            var p = k + step
            var skipped = 0
            while p >= 0, p < tokens.count, skipped < 4 {
                if isWord(p), !LinkDifferenceWords.dateJoiners.contains(folded(p)) { return p }
                if isWord(p) { p += step; skipped += 1; continue }
                if tokens[p].text == " " || tokens[p].text == "." { p += step; skipped += 1; continue }
                return nil
            }
            return nil
        }
        var consumed = Set<Int>()
        // CJK dates: 10月15日.
        let cjk = /(\d{1,2})\s*月\s*(\d{1,2})\s*[日号號]?/
        for match in text.precomposedStringWithCompatibilityMapping.matches(of: cjk) {
            reading.dates.append((key: "\(match.output.1)-\(match.output.2)", span: String(match.output.0), leaders: []))
        }
        // Slash and ISO dates: 2026-10-12, 12/10/2026, 12.10.
        let numeric = /(\d{4})-(\d{1,2})-(\d{1,2})|(\d{1,2})[\/.](\d{1,2})(?:[\/.](\d{2,4}))?(?![\d])/
        let whole = String(source)
        for match in whole.matches(of: numeric) {
            let s = String(match.output.0)
            guard s.contains("-") || s.contains("/") || s.count <= 10 else { continue }
            // "1.500" is a number, not 1 May.
            if s.contains("."), !s.contains("/"), match.output.6 == nil, s.split(separator: ".").last.map({ $0.count == 3 }) == true { continue }
            reading.dates.append((key: s, span: s, leaders: []))
            let lower = whole.distance(from: whole.startIndex, to: match.range.lowerBound), upper = whole.distance(from: whole.startIndex, to: match.range.upperBound)
            for (n, t) in tokens.enumerated() where t.range.lowerBound >= lower && t.range.upperBound <= upper { consumed.insert(n) }
        }
        for (k, token) in tokens.enumerated() where !consumed.contains(k) {
            if token.isNumber {
                let digits = token.text.filter(\.isNumber)
                // Quarter or half: Q3, H2 (the letter is its own token just before).
                if k > 0, isWord(k - 1), ["q", "h"].contains(folded(k - 1)), digits.count == 1 {
                    reading.periods.insert(folded(k - 1) + digits)
                    consumed.insert(k); consumed.insert(k - 1)
                    continue
                }
                // A year.
                if digits.count == 4, let year = Int(digits), (1900...2100).contains(year), token.text == digits {
                    reading.periods.insert("y" + digits)
                    consumed.insert(k)
                    continue
                }
                // A day next to a month name: 12 Oct, 12 de octubre, October 12, 12th of October.
                if let day = Int(digits), (1...31).contains(day), token.text == digits {
                    var month: (Int, Int)?
                    if let after = neighbor(of: k, step: 1), let m = monthNumber(after) { month = (m, after) }
                    else if let before = neighbor(of: k, step: -1), let m = monthNumber(before) { month = (m, before) }
                    if let (m, at) = month {
                        let from = min(k, at), to = max(k, at)
                        reading.dates.append((key: "\(m)-\(day)", span: span(from, to), leaders: leaders(before: from)))
                        for n in from...to { consumed.insert(n) }
                        continue
                    }
                }
                // A numbered week or version: "week 12".
                if let lead = (1...2).lazy.map({ k - $0 }).first(where: { isWord($0) && !LinkDifferenceWords.dateJoiners.contains(folded($0)) }),
                   LinkDifferenceWords.periodLeaders.contains(folded(lead)), k - lead <= 2 {
                    reading.periods.insert(folded(lead) + digits)
                    consumed.insert(k)
                    continue
                }
                // A figure, with its unit: a currency before it, or the symbol or word after it.
                var value = digits
                var unit = ""
                var end = k
                var lastIndex = k
                if k + 1 < tokens.count, isWord(k + 1), ["k", "m", "b"].contains(folded(k + 1)) { value += folded(k + 1); end = k + 1; lastIndex = end }
                var next = lastIndex + 1
                while next < tokens.count, tokens[next].text == " " || tokens[next].text == "\u{00A0}" { next += 1 }
                if next < tokens.count {
                    let f = folded(next)
                    if let mapped = LinkDifferenceWords.units[tokens[next].text] ?? LinkDifferenceWords.units[f] {
                        unit = mapped; end = next
                    } else if isWord(next), f.count >= 2, !profile.stopwords.contains(f), monthNumber(next) == nil, DateWords.mentionedWeekdays(f).isEmpty {
                        unit = f; end = next
                    }
                }
                var begin = k
                if unit.isEmpty, k > 0 {
                    var prev = k - 1
                    while prev >= 0, tokens[prev].text == " " { prev -= 1 }
                    if prev >= 0, let mapped = LinkDifferenceWords.units[tokens[prev].text], !mapped.isEmpty { unit = mapped; begin = prev }
                }
                reading.figures.append(Figure(value: value, unit: unit, span: span(begin, end)))
                for n in begin...end { consumed.insert(n) }
            } else if isWord(k) {
                let f = folded(k)
                // Weekday names.
                if !DateWords.mentionedWeekdays(f).isEmpty, let day = DateWords.mentionedWeekdays(f).first {
                    reading.weekdays.append((day: day, span: tokens[k].text, leaders: leaders(before: k)))
                    continue
                }
                // A month on its own ("in October") is a period.
                if let m = monthNumber(k), f.count >= 4 {
                    reading.periods.insert("m\(m)")
                }
            }
        }
        // Han numerals and other counts are not read: a difference in them is left to the vector and keyword gates.
        return reading
    }
}
