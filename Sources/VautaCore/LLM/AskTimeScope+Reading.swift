// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Finding the times in a question and reading the words around them (`AskTimeScope.read`).
extension AskTimeScope {
    struct Found {
        let named: Named
        let context: Context
    }

    // MARK: Languages written with spaces

    static func readLatin(_ tokens: [String], _ lexicon: AskTimeWords.Lexicon) -> [Found] {
        var hits: [(range: Range<Int>, named: Named)] = []
        let n = tokens.count
        for phrase in lexicon.periods {
            for i in occurrences(of: phrase.words, in: tokens) { hits.append((i..<(i + phrase.words.count), .relative(phrase.period, current: phrase.current))) }
        }
        var adjectives = Set<Int>()
        for phrase in lexicon.adjectives {
            for i in occurrences(of: phrase.words, in: tokens) {
                hits.append((i..<(i + phrase.words.count), .relative(phrase.period, current: phrase.current)))
                adjectives.insert(i)
            }
        }
        for i in 0..<n {
            // "<n> days ago", "hace <n> días", "the last <n> days".
            if i + 1 < n, let count = number(tokens[i]), let unit = lexicon.units[tokens[i + 1]] {
                let value = count * unit.count
                if let k = leader(lexicon.agoBefore, endingAt: i, in: tokens) { hits.append(((i - k)..<(i + 2), .ago(unit.unit, value))) }
                if let k = leader(lexicon.agoAfter, startingAt: i + 2, in: tokens) { hits.append((i..<(i + 2 + k), .ago(unit.unit, value))) }
                if let k = leader(lexicon.lastBefore, endingAt: i, in: tokens) { hits.append(((i - k)..<(i + 2), .relative(.rolling(unit.unit, value), current: false))) }
            }
            // "les 3 derniers jours".
            if i + 2 < n, let count = number(tokens[i]), lexicon.lastBetween.contains([tokens[i + 1]]), let unit = lexicon.units[tokens[i + 2]] {
                hits.append((i..<(i + 3), .relative(.rolling(unit.unit, count * unit.count), current: false)))
            }
            // "last Monday", "el lunes pasado", "na segunda-feira passada".
            if let weekday = AskTimeWords.weekdays[tokens[i]] {
                let end = i + 1 < n && tokens[i + 1] == "feira" ? i + 2 : i + 1
                if let k = leader(lexicon.weekdayBefore, endingAt: i, in: tokens) { hits.append(((i - k)..<end, .weekday(weekday, lastWeek: false))) }
                if let k = leader(lexicon.weekdayAfter, startingAt: end, in: tokens) { hits.append((i..<(end + k), .weekday(weekday, lastWeek: false))) }
            }
            if let month = lexicon.months[tokens[i]] { hits.append(date(month, at: i, in: tokens)) }
            if let quarter = quarter(at: i, in: tokens, lexicon) { hits.append(quarter) }
            if let year = yearNumber(tokens[i]) { hits.append((i..<(i + 1), .year(year))) }
        }
        let excluded = lexicon.excluded.flatMap { words in occurrences(of: words, in: tokens).map { $0..<($0 + words.count) } }
        hits.removeAll { hit in excluded.contains { $0.overlaps(hit.range) } }
        return longestFirst(hits, length: \.range.count, overlaps: { $0.range.overlaps($1.range) }).map { hit in
            // An adjective is the time of the noun after it: a meeting, or something else.
            let adjective = adjectives.contains(hit.range.lowerBound) && hit.range.count == 1
            let owner = namesMeeting(Array(tokens[hit.range.upperBound...].prefix(2)), lexicon) ? Context.meeting : .genitive
            return Found(named: hit.named, context: adjective ? owner : context(of: hit.range, in: tokens, lexicon))
        }
    }

    /// A month, with the day and the year written next to it: "October 3", "3rd of October", "3 de octubre de 2025", "Oktober 2025".
    private static func date(_ month: Int, at i: Int, in tokens: [String]) -> (range: Range<Int>, named: Named) {
        var lower = i, upper = i + 1, day: Int?
        if i >= 1, let d = dayNumber(tokens[i - 1]) {
            day = d; lower = i - 1
        } else if i >= 2, ["de", "of", "d"].contains(tokens[i - 1]), let d = dayNumber(tokens[i - 2]) {
            day = d; lower = i - 2
        } else if upper < tokens.count, yearNumber(tokens[upper]) == nil, let d = dayNumber(tokens[upper]) {
            day = d; upper += 1
        }
        var year: Int?
        if upper < tokens.count, let y = yearNumber(tokens[upper]) {
            year = y; upper += 1
        } else if upper + 1 < tokens.count, ["de", "of", "del"].contains(tokens[upper]), let y = yearNumber(tokens[upper + 1]) {
            year = y; upper += 2
        }
        return (lower..<upper, .date(year: year, month: month, day: day))
    }

    /// "Q3", "Q3 2025", "the third quarter", "el tercer trimestre de 2025", "3. Quartal".
    private static func quarter(at i: Int, in tokens: [String], _ lexicon: AskTimeWords.Lexicon) -> (range: Range<Int>, named: Named)? {
        let token = tokens[i]
        var q: Int?, lower = i, upper = i + 1
        if token.count == 2, token.first == "q", let v = token.last?.wholeNumberValue, (1...4).contains(v) {
            q = v
        } else if lexicon.quarter.contains(token), i >= 1, let v = lexicon.ordinals[tokens[i - 1]] ?? Int(tokens[i - 1]), (1...4).contains(v) {
            q = v; lower = i - 1
        }
        guard let q else { return nil }
        var year: Int?
        if upper < tokens.count, let y = yearNumber(tokens[upper]) {
            year = y; upper += 1
        } else if upper + 1 < tokens.count, ["de", "of", "del", "di", "do", "des"].contains(tokens[upper]), let y = yearNumber(tokens[upper + 1]) {
            year = y; upper += 2
        } else if lower >= 1, let y = yearNumber(tokens[lower - 1]) {
            year = y; lower -= 1
        }
        return (lower..<upper, .quarter(year: year, q))
    }

    /// Articles between a leader and its time ("in the last two weeks", "en el mes de octubre"), and the words of "the month of".
    private static let skippable: Set<String> = ["the", "el", "la", "los", "las", "le", "les", "l", "il", "lo", "gli", "o", "os", "as", "die", "den", "dem", "das",
                                                 "dia", "giorno", "month", "mes", "mois", "monat", "mese"]
    private static let monthWords: Set<String> = ["month", "mes", "mois", "monat", "mese"]

    private static func context(of range: Range<Int>, in tokens: [String], _ lexicon: AskTimeWords.Lexicon) -> Context {
        var before = Array(tokens[..<range.lowerBound])
        let after = Array(tokens[range.upperBound...])
        // "the month of October", "el mes de octubre": the words of the month are not what it is of.
        if before.count >= 2, ["of", "de", "d", "di"].contains(before.last!), monthWords.contains(before[before.count - 2]) { before.removeLast(2) }
        let leaders: [(Context, [[String]])] = [(.deadline, lexicon.deadline), (.since, lexicon.since), (.into, lexicon.into), (.genitive, lexicon.genitive)]
        var found: (context: Context, start: Int)?
        var rest = before
        while true {
            var here: (context: Context, start: Int)?
            for (kind, list) in leaders {
                if let k = leader(list, endingAt: rest.count, in: rest), rest.count - k < (here?.start ?? .max) { here = (kind, rest.count - k) }
            }
            // An article that is also a leader ("el 3 de octubre": on) counts unless a leader comes before it ("desde el lunes").
            let article = here.map { rest.count - $0.start == 1 && skippable.contains(rest[$0.start]) } ?? false
            if let here, !article { found = here; break }
            if found == nil { found = here }
            guard let last = rest.last, skippable.contains(last) else { break }
            rest.removeLast()
        }
        if let found, found.context == .deadline || found.context == .since { return found.context }
        // "last week's meeting", "yesterday's figures".
        if lexicon.possessive, after.first == "s" { return namesMeeting(Array(after.dropFirst().prefix(3)), lexicon) ? .meeting : .genitive }
        if let found, found.context == .genitive {
            return namesMeeting(Array(rest[..<found.start].suffix(3)), lexicon) ? .meeting : .genitive
        }
        if namesMeeting(Array(before.suffix(3)), lexicon) || namesMeeting(Array(after.prefix(3)), lexicon) { return .meeting }
        return found?.context ?? .plain
    }

    private static func namesMeeting(_ window: [String], _ lexicon: AskTimeWords.Lexicon) -> Bool {
        lexicon.meetings.contains { !occurrences(of: $0, in: window).isEmpty }
    }

    // MARK: Japanese, Korean and Chinese

    static func readScript(_ text: String, _ script: AskTimeWords.Script) -> [Found] {
        var hits: [(range: Range<Int>, named: Named)] = []
        let characters = Array(text)
        func offsets(_ range: Range<String.Index>) -> Range<Int> {
            text.distance(from: text.startIndex, to: range.lowerBound)..<text.distance(from: text.startIndex, to: range.upperBound)
        }
        for period in script.periods {
            var from = text.startIndex
            while let range = text.range(of: period.text, range: from..<text.endIndex) {
                hits.append((offsets(range), .relative(period.period, current: period.current)))
                from = range.upperBound
            }
        }
        func each(_ pattern: String, _ make: (Regex<AnyRegexOutput>.Match) -> Named?) {
            guard !pattern.isEmpty, let regex = try? Regex(pattern) else { return }
            for match in text.matches(of: regex) { if let named = make(match) { hits.append((offsets(match.range), named)) } }
        }
        func group(_ match: Regex<AnyRegexOutput>.Match, _ name: String) -> String? { match.output[name]?.substring.map(String.init) }
        func count(_ match: Regex<AnyRegexOutput>.Match) -> (AskTimeWords.Unit, Int)? {
            guard let n = group(match, "n").flatMap(AskTimeWords.cjkNumber), (1...99).contains(n),
                  let unit = group(match, "u").flatMap({ script.units[$0] }) else { return nil }
            return (unit.unit, n * unit.count)
        }
        each(script.ago) { match in count(match).map { .ago($0.0, $0.1) } }
        each(script.rolling) { match in count(match).map { .relative(.rolling($0.0, $0.1), current: false) } }
        each(script.weekdayLastWeek) { match in group(match, "w").flatMap { script.weekdays[$0] }.map { .weekday($0, lastWeek: true) } }
        each(script.weekdayPast) { match in group(match, "w").flatMap { script.weekdays[$0] }.map { .weekday($0, lastWeek: false) } }
        each(script.date) { match in
            guard let month = group(match, "m").flatMap(AskTimeWords.cjkNumber), (1...12).contains(month) else { return nil }
            let day = group(match, "d").flatMap(AskTimeWords.cjkNumber)
            if group(match, "d") != nil, !(1...31).contains(day ?? 0) { return nil }
            return .date(year: group(match, "y").flatMap { Int($0) }, month: month, day: day)
        }
        each(script.quarter) { match in
            guard let q = group(match, "q").flatMap(AskTimeWords.cjkNumber), (1...4).contains(q) else { return nil }
            return .quarter(year: group(match, "y").flatMap { Int($0) }, q)
        }
        each(script.year) { match in group(match, "y").flatMap { Int($0) }.flatMap { yearNumber(String($0)) }.map { .year($0) } }
        let excluded = script.excluded.flatMap { word in
            var out: [Range<Int>] = [], from = text.startIndex
            while let range = text.range(of: word, range: from..<text.endIndex) { out.append(offsets(range)); from = range.upperBound }
            return out
        }
        hits.removeAll { hit in excluded.contains { $0.overlaps(hit.range) } }
        return longestFirst(hits, length: \.range.count, overlaps: { $0.range.overlaps($1.range) }).map { hit in
            let before = String(characters[..<hit.range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let after = String(characters[hit.range.upperBound...]).trimmingCharacters(in: .whitespaces)
            return Found(named: hit.named, context: context(before: before, after: after, whole: text, script))
        }
    }

    private static func context(before: String, after: String, whole: String, _ script: AskTimeWords.Script) -> Context {
        if script.deadlineAfter.contains(where: after.hasPrefix) || script.deadlineBefore.contains(where: before.hasSuffix) { return .deadline }
        if script.sinceAfter.contains(where: after.hasPrefix) || script.sinceBefore.contains(where: before.hasSuffix) { return .since }
        if let marker = script.genitiveAfter.first(where: after.hasPrefix) {
            let owner = after.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return script.meetings.contains(where: owner.hasPrefix) ? .meeting : .genitive
        }
        // Without spaces, "next to" is the whole question: "先週は会議で何を決めた" names its meeting too.
        if script.meetings.contains(where: whole.contains) { return .meeting }
        if script.intoAfter.contains(where: after.hasPrefix) || script.intoBefore.contains(where: before.hasSuffix) { return .into }
        return .plain
    }

    // MARK: Shared

    /// The hits that do not overlap a longer one: "the day before yesterday" over "yesterday", "一昨日" over "昨日".
    static func longestFirst<T>(_ hits: [T], length: (T) -> Int, overlaps: (T, T) -> Bool) -> [T] {
        var kept: [T] = []
        for hit in hits.enumerated().sorted(by: { (length($0.element), -$0.offset) > (length($1.element), -$1.offset) }).map(\.element)
        where !kept.contains(where: { overlaps($0, hit) }) {
            kept.append(hit)
        }
        return kept
    }

    static func occurrences(of words: [String], in tokens: [String]) -> [Int] {
        guard !words.isEmpty, words.count <= tokens.count else { return [] }
        return (0...(tokens.count - words.count)).filter { i in tokens[i..<(i + words.count)].elementsEqual(words) }
    }

    /// The length of the longest of `phrases` that ends right before `index` (or starts at it).
    static func leader(_ phrases: [[String]], endingAt index: Int, in tokens: [String]) -> Int? {
        phrases.filter { $0.count <= index && tokens[(index - $0.count)..<index].elementsEqual($0) }.map(\.count).max()
    }

    static func leader(_ phrases: [[String]], startingAt index: Int, in tokens: [String]) -> Int? {
        phrases.filter { index + $0.count <= tokens.count && tokens[index..<(index + $0.count)].elementsEqual($0) }.map(\.count).max()
    }

    static func number(_ token: String) -> Int? {
        if let n = Int(token) { return (1...99).contains(n) ? n : nil }
        return AskTimeWords.numbers[token]
    }

    /// A day of the month, with the ordinal endings the six languages write ("3rd", "1er", "1º" read as "1o").
    static func dayNumber(_ token: String) -> Int? {
        let digits = token.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2, let day = Int(digits), (1...31).contains(day) else { return nil }
        let rest = token.dropFirst(digits.count)
        return rest.isEmpty || ["st", "nd", "rd", "th", "er", "re", "o", "a", "e"].contains(String(rest)) ? day : nil
    }

    /// A year written in full, from 1990 to 2100.
    static func yearNumber(_ token: String) -> Int? {
        guard token.count == 4, let year = Int(token), (1990...2100).contains(year) else { return nil }
        return year
    }
}
