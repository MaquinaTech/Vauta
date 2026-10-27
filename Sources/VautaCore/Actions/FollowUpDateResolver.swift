// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Finds the day and the time a follow-up meeting was said to take place, in the nine languages, and resolves them against the
/// meeting's own calendar day in the meeting's time zone (never the Mac's zone, never "today").
///
/// - An explicit date ("21 October", "10/21", "10月21日") is `said`.
/// - A weekday ("Tuesday", "next Tuesday") is the first such day after the meeting's day, always `inferred`: speakers disagree on
///   which week "next Tuesday" means, so the editor tells the person to check it.
/// - "Tomorrow" and "in two weeks" are exact arithmetic on the meeting's day; "next week" is the same weekday a week later, inferred;
///   a bare day of the month ("on the 3rd") is the next such day, inferred.
/// - Dates that are in the past ("last Tuesday", "el martes pasado") or deadlines ("by Friday") are not meetings.
enum FollowUpDateResolver {
    /// Whether a numeric date such as 5/6 is day-first (most of the world) or month-first (en-US).
    enum DateOrder: Sendable { case dayFirst, monthFirst }

    struct Day: Equatable {
        var day: DueDay
        var inferred: Bool
    }

    static func order(forLocale identifier: String?) -> DateOrder {
        guard let identifier else { return .dayFirst }
        let locale = Locale(identifier: identifier)
        if locale.language.languageCode?.identifier == "en", locale.region?.identifier == nil || locale.region?.identifier == "US" { return .monthFirst }
        return .dayFirst
    }

    // MARK: Day

    /// The day a text says, strictly after `meetingDay`; nil when it says none.
    static func day(in text: String, meetingDay: DueDay, order: DateOrder) -> Day? {
        let simple = Self.simple(text)
        let norm = TextKeys.norm(text)
        // "Last time we spoke on the 3rd": a date the talk looks back to is not a meeting (judged evaluation: it became 3 October).
        if FollowUpWords.lookbacks.contains(where: { FollowUpWords.matches(norm, $0) }) { return nil }
        let tokens = norm.split(separator: " ").map(String.init)
        let candidates: [Day?] = [
            explicit(simple, tokens: tokens, meetingDay: meetingDay, order: order),
            tomorrow(norm, meetingDay: meetingDay),
            inDays(simple, tokens: tokens, norm: norm, meetingDay: meetingDay),
            weekday(norm, simple: simple, meetingDay: meetingDay),
            nextWeek(norm, meetingDay: meetingDay),
            bareDay(simple, tokens: tokens, meetingDay: meetingDay),
        ]
        return candidates.compactMap { $0 }.first { $0.day > meetingDay }
    }

    static func simple(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    // MARK: Explicit dates

    private static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }
    private static let iso = regex(#"(?<![\d-])(\d{4})-(\d{1,2})-(\d{1,2})(?![\d-])"#)
    private static let slash = regex(#"(?<![\d/])(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?(?![\d/])"#)
    private static let dotted = regex(#"(?<![\d.])(\d{1,2})\.(\d{1,2})\.(?:(\d{4}|\d{2})(?!\d))?"#)
    private static let cjkMonthDay = regex(#"(\d{1,2})\s*(?:月|월)\s*(\d{1,2})\s*(?:日|号|號|일)"#)
    private static let cjkBareDay = regex(#"(?<![\d月월])(\d{1,2})\s*(?:日|号|號|일)(?![後后前間间以本曜])"#)

    private static func groups(_ r: NSRegularExpression, _ text: String) -> [[String?]] {
        let ns = text as NSString
        return r.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? nil : ns.substring(with: m.range(at: $0)) }
        }
    }

    private static func explicit(_ simple: String, tokens: [String], meetingDay: DueDay, order: DateOrder) -> Day? {
        for g in groups(iso, simple) {
            if let y = g[0].flatMap(Int.init), let m = g[1].flatMap(Int.init), let d = g[2].flatMap(Int.init), let day = DueDay(year: y, month: m, day: d) {
                return Day(day: day, inferred: false)
            }
        }
        for g in groups(cjkMonthDay, simple) {
            if let m = g[0].flatMap(Int.init), let d = g[1].flatMap(Int.init), let day = nextOccurrence(month: m, day: d, year: nil, after: meetingDay) { return Day(day: day, inferred: false) }
        }
        for g in groups(slash, simple) {
            guard let a = g[0].flatMap(Int.init), let b = g[1].flatMap(Int.init) else { continue }
            let year = g[2].flatMap(Int.init).map { $0 < 100 ? 2000 + $0 : $0 }
            if let day = numeric(a, b, year: year, order: order, after: meetingDay) { return Day(day: day, inferred: false) }
        }
        if order == .dayFirst {
            for g in groups(dotted, simple) {
                guard let a = g[0].flatMap(Int.init), let b = g[1].flatMap(Int.init) else { continue }
                let year = g[2].flatMap(Int.init).map { $0 < 100 ? 2000 + $0 : $0 }
                if let day = nextOccurrence(month: b, day: a, year: year, after: meetingDay) { return Day(day: day, inferred: false) }
            }
        }
        if let day = monthName(tokens, meetingDay: meetingDay, simple: simple) { return Day(day: day, inferred: false) }
        return nil
    }

    private static func numeric(_ a: Int, _ b: Int, year: Int?, order: DateOrder, after meetingDay: DueDay) -> DueDay? {
        let (first, second) = order == .dayFirst ? ((day: a, month: b), (day: b, month: a)) : ((day: b, month: a), (day: a, month: b))
        // The expected order first; the other one only when the expected one is not a date (21/10 in en-US is 21 October).
        return nextOccurrence(month: first.month, day: first.day, year: year, after: meetingDay)
            ?? ((first.month > 12 || first.day > 31) ? nextOccurrence(month: second.month, day: second.day, year: year, after: meetingDay) : nil)
    }

    /// The first date with this month and day after `meetingDay` (this year or the next), or exactly `year` when it was said.
    private static func nextOccurrence(month: Int, day: Int, year: Int?, after meetingDay: DueDay) -> DueDay? {
        if let year { return DueDay(year: year, month: month, day: day) }
        for y in [meetingDay.year, meetingDay.year + 1] {
            if let candidate = DueDay(year: y, month: month, day: day), candidate > meetingDay { return candidate }
        }
        return nil
    }

    private static let monthFillers: Set<String> = ["de", "of", "del", "di", "du", "the", "le", "el", "em", "no", "in", "am", "on", "il", "dia", "den"]

    private static func dayNumber(_ token: String) -> Int? {
        var t = token
        for suffix in ["st", "nd", "rd", "th", "er", "ro", "o"] where t.hasSuffix(suffix) && t.count > suffix.count && t.dropLast(suffix.count).allSatisfy(\.isNumber) {
            t = String(t.dropLast(suffix.count))
            break
        }
        guard t.count <= 2, let n = Int(t), (1...31).contains(n) else { return nil }
        return n
    }

    private static func monthName(_ tokens: [String], meetingDay: DueDay, simple: String) -> DueDay? {
        for (i, token) in tokens.enumerated() {
            guard let month = FollowUpWords.monthNames[token] else { continue }
            var day: Int?
            var leading = i   // the first token of the date expression, for the deadline check
            var j = i - 1
            while j >= 0, j >= i - 3, monthFillers.contains(tokens[j]) { j -= 1 }
            if j >= 0, let n = dayNumber(tokens[j]) { day = n; leading = j }
            if day == nil {
                var k = i + 1
                while k < tokens.count, k <= i + 2, monthFillers.contains(tokens[k]) { k += 1 }
                if k < tokens.count, let n = dayNumber(tokens[k]) { day = n }
            }
            guard let day else { continue }
            // "By 21 October", "before October 21": a deadline, not a meeting.
            if tokens[max(0, leading - 2)..<leading].contains(where: { FollowUpWords.deadlineBefore.contains($0) }) { continue }
            var year: Int?
            // A four-digit year right after the day or the month.
            for k in (i + 1)..<min(tokens.count, i + 4) where tokens[k].count == 4 { if let y = Int(tokens[k]), (2000...2100).contains(y) { year = y; break } }
            if let found = nextOccurrence(month: month, day: day, year: year, after: meetingDay) { return found }
        }
        return nil
    }

    // MARK: Relative days

    private static func tomorrow(_ norm: String, meetingDay: DueDay) -> Day? {
        DateWords.mentionsTomorrow(norm) ? Day(day: meetingDay.adding(days: 1), inferred: false) : nil
    }

    private static let dayUnits: Set<String> = ["day", "days", "dia", "dias", "jour", "jours", "tag", "tage", "tagen", "giorno", "giorni"]
    private static let weekUnits: Set<String> = ["week", "weeks", "semana", "semanas", "semaine", "semaines", "woche", "wochen", "settimana", "settimane"]
    private static let inLeaders: Set<String> = ["in", "en", "dentro", "dans", "tra", "fra", "em", "daqui", "within"]
    private static let beforeLeaders: Set<String> = ["hace", "vor", "fa", "ago", "il", "faz"]

    private static func inDays(_ simple: String, tokens: [String], norm: String, meetingDay: DueDay) -> Day? {
        if DateWords.contains(norm, DateWords.inTwoWeeks) { return Day(day: meetingDay.adding(days: 14), inferred: false) }
        for (i, token) in tokens.enumerated() where dayUnits.contains(token) || weekUnits.contains(token) {
            guard i >= 1 else { continue }
            let number = Int(tokens[i - 1]) ?? FollowUpWords.numberWords[tokens[i - 1]]
            guard let number, (1...12).contains(number) else { continue }
            var j = i - 2
            while j >= 0, j >= i - 4, ["de", "a"].contains(tokens[j]) { j -= 1 }
            guard j >= 0, inLeaders.contains(tokens[j]) else { continue }
            if i + 1 < tokens.count, ["ago", "atras", "fa"].contains(tokens[i + 1]) { continue }
            if j >= 1, beforeLeaders.contains(tokens[j - 1]) { continue }
            return Day(day: meetingDay.adding(days: number * (weekUnits.contains(token) ? 7 : 1)), inferred: false)
        }
        // CJK: 3日後, 2週間後, 两周后, 3天后, 2일 후, 2주 후.
        let cjk = regex(#"(\d{1,2}|[一二两兩三四五六七八九十])\s*(日後|日后|天后|天後|週間後|周后|周後|週後|일\s*후|일후|주\s*후|주후)"#)
        if let g = groups(cjk, simple).first, let raw = g[0], let unit = g[1] {
            let n = Int(raw) ?? FollowUpWords.numberWords[raw]
            if let n {
                let weeks = unit.contains("週") || unit.contains("周") || unit.hasPrefix("주")
                return Day(day: meetingDay.adding(days: n * (weeks ? 7 : 1)), inferred: false)
            }
        }
        return nil
    }

    // MARK: Weekdays

    private static func isUnspaced(_ word: String) -> Bool {
        word.unicodeScalars.contains { TextKeys.isNoSpaceScript($0) || (0xAC00...0xD7AF).contains($0.value) }
    }

    /// The weekday a text names (exactly one), with the words before and after it (for the past and deadline checks) and the few
    /// characters up to its end (for the scripts written without spaces).
    private static func namedWeekday(_ norm: String) -> (weekday: Int, before: String, after: String, window: String)? {
        let named = DateWords.mentionedWeekdays(norm)
        guard named.count == 1, let weekday = named.first else { return nil }
        let tokens = norm.split(separator: " ").map(String.init)
        var words = DateWords.weekdays[weekday] ?? []
        if let ambiguous = DateWords.ambiguousWeekdays[weekday] { words.append(ambiguous) }
        for word in words {
            if isUnspaced(word) {
                if let r = norm.range(of: word) { return (weekday, String(norm[..<r.lowerBound]), String(norm[r.upperBound...]), String(String(norm[..<r.upperBound]).suffix(10))) }
            } else if let i = tokens.firstIndex(of: word) {
                return (weekday, tokens[..<i].joined(separator: " "), tokens[(i + 1)...].joined(separator: " "), "")
            }
        }
        return (weekday, "", "", "")
    }

    private static func weekday(_ norm: String, simple: String, meetingDay: DueDay) -> Day? {
        guard let w = namedWeekday(norm) else { return nil }
        if isPast(before: w.before, after: w.after, window: w.window) || isDeadline(before: w.before, after: w.after) { return nil }
        var offset = (w.weekday - meetingDay.weekday + 7) % 7
        if offset == 0 { offset = 7 }
        var day = meetingDay.adding(days: offset)
        // "next week, Tuesday": the Tuesday of the week after the meeting's (Monday to Sunday).
        if DateWords.contains(norm, DateWords.nextWeek) {
            let mondayOffset = (meetingDay.weekday + 5) % 7   // days since Monday
            let nextMonday = meetingDay.adding(days: 7 - mondayOffset)
            day = nextMonday.adding(days: (w.weekday + 5) % 7)
        }
        return Day(day: day, inferred: true)
    }

    private static func nextWeek(_ norm: String, meetingDay: DueDay) -> Day? {
        DateWords.contains(norm, DateWords.nextWeek) ? Day(day: meetingDay.adding(days: 7), inferred: true) : nil
    }

    // MARK: A day of the month with no month ("on the 3rd")

    private static func bareDay(_ simple: String, tokens: [String], meetingDay: DueDay) -> Day? {
        var found: Int?
        for (i, token) in tokens.enumerated() {
            if token.count >= 3, token.dropLast(2).allSatisfy(\.isNumber), ["st", "nd", "rd", "th"].contains(String(token.suffix(2))), let n = dayNumber(token) { found = n; break }
            if ["dia", "le", "il"].contains(token) || (token == "the" && i > 0 && tokens[i - 1] == "on"), i + 1 < tokens.count, let n = dayNumber(tokens[i + 1]),
               i + 2 >= tokens.count || FollowUpWords.monthNames[tokens[i + 2]] == nil, !unitWords.contains(i + 2 < tokens.count ? tokens[i + 2] : "") { found = n; break }
        }
        if found == nil, let g = groups(cjkBareDay, simple).first, let n = g[0].flatMap(Int.init), (1...31).contains(n) { found = n }
        if found == nil, let g = groups(regex(#"\bam (\d{1,2})\.(?!\d)"#), simple).first, let n = g[0].flatMap(Int.init), (1...31).contains(n) { found = n }
        guard let dayOfMonth = found else { return nil }
        var year = meetingDay.year, month = meetingDay.month
        for _ in 0..<14 {
            if let candidate = DueDay(year: year, month: month, day: dayOfMonth), candidate > meetingDay { return Day(day: candidate, inferred: true) }
            month += 1
            if month > 12 { month = 1; year += 1 }
        }
        return nil
    }

    private static let unitWords: Set<String> = ["people", "personas", "persone", "personnes", "pessoas", "leute", "percent", "euros", "euro", "usd", "dollars", "items",
                                                 "options", "dias", "days", "tage", "giorni", "jours", "h", "heures", "horas", "uhr", "ore"]

    // MARK: Past and deadline

    static func isPast(before: String, after: String, window: String = "") -> Bool {
        let b = before.split(separator: " ").map(String.init).suffix(2), a = after.split(separator: " ").map(String.init).prefix(1)
        if b.contains(where: { FollowUpWords.pastBefore.contains($0) }) { return true }
        if a.contains(where: { FollowUpWords.pastAfter.contains($0) }) { return true }
        return FollowUpWords.pastCJK.contains { window.contains($0) }
    }

    static func isDeadline(before: String, after: String) -> Bool {
        let b = before.split(separator: " ").map(String.init).suffix(2)
        if b.contains(where: { FollowUpWords.deadlineBefore.contains($0) }) { return true }
        return FollowUpWords.deadlineAfterCJK.contains { after.prefix(4).contains($0) }
    }

    // MARK: Time

    private static let clock = regex(#"(?<![\d:.])(\d{1,2}):(\d{2})(?![\d:])\s*(a\.?\s?m\.?|p\.?\s?m\.?)?"#)
    private static let frenchHour = regex(#"(?<![\d])(\d{1,2})\s?h\s?(\d{2})?(?![a-z])"#)
    private static let meridiem = regex(#"(?<![\d:])(\d{1,2})\s?(a\.?\s?m\.?|p\.?\s?m\.?)(?![a-z])"#)
    private static let uhr = regex(#"(?<![\d])(\d{1,2})(?:[:.](\d{2}))?\s?uhr"#)
    private static let leader = regex(#"\b(?:at|a las|a la|alle|alle ore|as|vers|um|gegen|ab|around|about)\s+(\d{1,2}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|una|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|diez|once|doce|deux|trois|quatre|cinq|sept|huit|neuf|dix|onze|douze|ein|eins|zwei|drei|vier|funf|sechs|sieben|acht|neun|zehn|elf|zwolf|due|tre|quattro|cinque|sei|sette|otto|nove|dieci|undici|dodici|duas|quatro|oito|dez|doze)(?::(\d{2}))?(?![\d%])(?!\s?(?:people|personas|persone|personnes|pessoas|leute|percent|prozent|procent|por ciento|per cento|por cento|euro|euros|dollars|days|dias|giorni|jours|tage|weeks|items|options|minutes|min))"#)
    private static let oclock = regex(#"\b(\d{1,2}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\s?o['’]?\s?clock"#)
    private static let cjkHour = regex(#"(\d{1,2})\s*(?:時|시|点|點)(?![間간])(?:\s*(\d{1,2})\s*(?:分|분)?|\s*半|\s*반)?"#)

    /// The minute of the day a text says ("at 10", "10:30", "3 pm", "14h30", "um 10 Uhr", "10時"), nil when it says no time. An hour
    /// from 1 to 6 with nothing that says morning or afternoon is ambiguous and is left unsaid, so the person chooses.
    static func minuteOfDay(in text: String) -> Int? {
        let s = simple(text)
        func make(_ hour: Int, _ minute: Int, marker: Bool?, ambiguousOK: Bool = false) -> Int? {
            var h = hour
            guard (0...23).contains(h), (0...59).contains(minute) else { return nil }
            if let pm = marker {
                if pm, h < 12 { h += 12 }
                if !pm, h == 12 { h = 0 }
                if h > 12 && !pm { return nil }
            } else if (1...6).contains(h), !ambiguousOK { return nil }
            return h * 60 + minute
        }
        func isPM(_ m: String?) -> Bool? { m.map { $0.hasPrefix("p") } }
        if let g = groups(clock, s).first, let h = g[0].flatMap(Int.init), let m = g[1].flatMap(Int.init), let r = make(h, m, marker: isPM(g[2]), ambiguousOK: h >= 7 || h == 0) { return r }
        if let g = groups(meridiem, s).first, let h = g[0].flatMap(Int.init), (1...12).contains(h), let r = make(h, 0, marker: isPM(g[1])) { return r }
        if let g = groups(uhr, s).first, let h = g[0].flatMap(Int.init), let r = make(h, g[1].flatMap(Int.init) ?? 0, marker: nil, ambiguousOK: true) { return r }
        if let g = groups(frenchHour, s).first, let h = g[0].flatMap(Int.init), let r = make(h, g[1].flatMap(Int.init) ?? 0, marker: nil) { return r }
        if let g = groups(cjkHour, s).first, let h = g[0].flatMap(Int.init) {
            let half = s.contains("半") || s.contains("반")
            let afternoon = FollowUpWords.pmCJK.contains { s.contains($0) }, morning = FollowUpWords.amCJK.contains { s.contains($0) }
            let minute = half ? 30 : (g[1].flatMap(Int.init) ?? 0)
            if let r = make(h, minute, marker: afternoon ? true : (morning ? false : nil)) { return r }
        }
        if let g = groups(oclock, s).first, let raw = g[0] {
            let h = Int(raw) ?? FollowUpWords.numberWords[raw]
            if let h, let r = make(h, 0, marker: dayPartMarker(s)) { return r }
        }
        if let g = groups(leader, s).first, let raw = g[0] {
            let h = Int(raw) ?? FollowUpWords.numberWords[raw]
            if let h, let r = make(h, g[1].flatMap(Int.init) ?? 0, marker: dayPartMarker(s)) { return r }
        }
        return nil
    }

    private static func dayPartMarker(_ simple: String) -> Bool? {
        let words = Set(simple.split { !$0.isLetter }.map(String.init))
        if !words.isDisjoint(with: FollowUpWords.pm) { return true }
        if !words.isDisjoint(with: FollowUpWords.am) { return false }
        return nil
    }
}

/// The words of a transcript line that say the day of a follow-up meeting ("next Tuesday"), for the line that tells the person what to
/// check. It is the clause of the line from which the resolver reads the day, so it names the date and not the start of the line.
public enum FollowUpPhrase {
    public static func phrase(in text: String, meetingStart: Date, timeZone: TimeZone, locale: String?, day expected: DueDay? = nil, limit: Int = 60) -> String? {
        let meetingDay = DueDay.containing(meetingStart, in: timeZone)
        let order = FollowUpDateResolver.order(forLocale: locale)
        for clause in clauses(of: text) {
            guard let found = FollowUpDateResolver.day(in: clause, meetingDay: meetingDay, order: order), expected == nil || found.day == expected else { continue }
            return shorten(clause, limit: limit)
        }
        return nil
    }

    /// The pieces of a line between sentence and comma marks (a full stop or comma inside a number or a time does not split).
    static func clauses(of text: String) -> [String] {
        let always: Set<Character> = ["。", "！", "？", "、", "，", "；", "\n"]
        let spaced: Set<Character> = [".", "!", "?", ";", ","]
        var out: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            if always.contains(c) || (spaced.contains(c) && (i + 1 >= chars.count || chars[i + 1].isWhitespace)) {
                out.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        out.append(current)
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// The text without the sentence or clause marks and spaces at its end, so an ellipsis never follows a full stop ("sync.…").
    public static func withoutTrailingMarks(_ text: String) -> String {
        var out = Substring(text)
        let marks: Set<Character> = [".", ",", ";", ":", "!", "?", "。", "、", "，", "；", "：", "！", "？"]
        while let last = out.last, last.isWhitespace || marks.contains(last) { out = out.dropLast() }
        return String(out)
    }

    /// Cut at a word boundary (never inside a word) with an ellipsis; text written without spaces is cut at a character.
    public static func shorten(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        if let space = head.lastIndex(where: \.isWhitespace), head.distance(from: head.startIndex, to: space) > limit / 2 {
            return withoutTrailingMarks(String(head[..<space])) + "…"
        }
        return withoutTrailingMarks(head) + "…"
    }
}
