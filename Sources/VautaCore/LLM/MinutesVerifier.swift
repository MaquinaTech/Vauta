// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Deterministic checks of a decision or task against the segment it cites. Pure: no model, no store, no network.
///
/// The model writes the minutes in the output language and may paraphrase, so the checks only compare what can be
/// compared literally and in any language: digits, calendar dates, and names. An item that fails one is kept and
/// marked "unconfirmed" (the user sees it and decides); nothing is deleted. The checks are deliberately strict about
/// what the segment says and lenient about how it is said.
public enum MinutesVerifier {
    // MARK: Figures

    /// The numbers written with digits in `text`, as comparable keys: separators and spaces are dropped, so
    /// "1,500", "1.500" and "1 500" are all "1500". Full-width digits count as digits.
    static func figures(in text: String) -> [String] {
        let chars = Array(text.precomposedStringWithCompatibilityMapping)
        func isDigit(_ i: Int) -> Bool { i < chars.count && chars[i].isASCII && chars[i].isNumber }
        var out: [String] = []
        var current = ""
        for (i, ch) in chars.enumerated() {
            if isDigit(i) {
                current.append(ch)
            } else if !current.isEmpty, ",.'\u{00A0}\u{202F}".contains(ch), isDigit(i + 1) {
                continue   // a separator inside a number
            } else {
                if !current.isEmpty { out.append(current) }
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static let hanDigits: [Character: Int] = ["〇": 0, "零": 0, "一": 1, "二": 2, "两": 2, "兩": 2, "三": 3, "四": 4, "五": 5,
                                                      "六": 6, "七": 7, "八": 8, "九": 9]
    private static let hanUnits: Set<Character> = ["十", "百", "千", "万", "萬", "億", "亿"]
    /// What follows a numeral when it counts something ("五家", "三人", "百万円"). "一" in 一緒, 一起, 统一 is not a number.
    private static let counters = Set("个個家人名位台本件枚回次度年月日天周週号號倍元块塊円圆円万萬億亿件社つ間时時分秒点点歳岁階层層人%％")

    /// The numbers written in Han numerals ("五十家", "三百万円") as comparable keys: the value, and for 万/億 also the
    /// number before the multiplier ("300" for 三百万), since minutes often write "300万". A single numeral with no counter
    /// after it (一緒, 一起, 统一) is a word, not a number.
    static func hanFigures(in text: String, excluding dateNumbers: Set<Int> = [], skippingIndefiniteOne: Bool = false) -> Set<String> {
        let chars = Array(text.precomposedStringWithCompatibilityMapping)
        var out = Set<String>()
        var i = 0
        while i < chars.count {
            guard hanDigits[chars[i]] != nil || hanUnits.contains(chars[i]) else { i += 1; continue }
            var j = i
            while j < chars.count, hanDigits[chars[j]] != nil || hanUnits.contains(chars[j]) { j += 1 }
            let run = Array(chars[i..<j])
            // "300万円": the 万 closes a number written with digits, which `figures` already read.
            if i > 0, chars[i - 1].isASCII, chars[i - 1].isNumber, hanUnits.contains(chars[i]) { i = j; continue }
            let counted = j < chars.count && counters.contains(chars[j])
            let isDate = counted && "年月日号號".contains(chars[j]) && hanValues(run).first.map(dateNumbers.contains) == true
            // On the item side a lone 一 before a counter ("发一个邮件", "一回確認") is an article, not the figure 1.
            let indefinite = skippingIndefiniteOne && run.count == 1 && run[0] == "一"
            if (run.count >= 2 || counted) && !isDate && !indefinite { for v in hanValues(run) { out.insert(String(v)) } }
            i = j
        }
        return out
    }

    private static func hanValues(_ run: [Character]) -> [Int] {
        if run.allSatisfy({ hanDigits[$0] != nil }) {   // positional: 二〇二六
            return [run.reduce(0) { $0 * 10 + (hanDigits[$1] ?? 0) }]
        }
        var total = 0, section = 0, number = 0
        var multiplied: [Int] = []
        for ch in run {
            if let d = hanDigits[ch] { number = d; continue }
            switch ch {
            case "十": section += (number == 0 ? 1 : number) * 10; number = 0
            case "百": section += (number == 0 ? 1 : number) * 100; number = 0
            case "千": section += (number == 0 ? 1 : number) * 1000; number = 0
            default:   // 万 or 億
                let unit = (ch == "万" || ch == "萬") ? 10_000 : 100_000_000
                let part = section + number
                total += (part == 0 ? 1 : part) * unit
                multiplied.append(part == 0 ? 1 : part)
                section = 0; number = 0
            }
        }
        return [total + section + number] + multiplied
    }

    /// Every figure of the item that is not part of its due date is written in the segment. The due date's own
    /// words are cut out of the item first (`removingDate`), so another number that happens to equal the day, month
    /// or year of the date still has to be in the segment.
    public static func figuresAreInSegment(item: String, segment: String, due: Date? = nil, timeZone: TimeZone = .current) -> Bool {
        let text = due.map { removingDate($0, from: item, timeZone: timeZone) } ?? item
        // Han numerals count too ("五十家供应商"), so a wrong figure written in kanji is caught as well; the ones that
        // write the due date itself ("十月十五日") are left to the date check.
        let dateNumbers = due.map { dateNumbers(of: $0, timeZone: timeZone) } ?? []
        let wanted = figures(in: text) + hanFigures(in: text, excluding: dateNumbers, skippingIndefiniteOne: true).sorted()
        guard !wanted.isEmpty else { return true }
        // The segment's own date words are cut out the same way, so "the 12th" cannot vouch for "12 laptops".
        let spoken = due.map { removingDate($0, from: segment, timeZone: timeZone) } ?? segment
        let have = Set(figures(in: spoken)).union(hanFigures(in: segment))
        return wanted.allSatisfy { have.contains($0) }
    }

    /// A "next" word sits right next to the weekday ("next friday", "viernes que viene"), not just anywhere in the segment.
    private static func nextWeekdayIsMentioned(_ norm: String, weekday: Int) -> Bool {
        // Scripts written without spaces (and Korean) keep the whole-segment test.
        if norm.unicodeScalars.contains(where: { TextKeys.isNoSpaceScript($0) || (0xAC00...0xD7AF).contains($0.value) }) {
            return DateWords.contains(norm, DateWords.nextWeekdayLeaders) && DateWords.mentionedWeekdays(norm).contains(weekday)
        }
        let words = norm.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        for (i, w) in words.enumerated() where DateWords.mentionedWeekdays(w).contains(weekday) {
            let near = words[max(0, i - 3)..<min(words.count, i + 4)].joined(separator: " ")
            if DateWords.contains(" " + near + " ", DateWords.nextWeekdayLeaders) { return true }
        }
        return false
    }

    /// The year (four and two digits), month and day of `due`.
    private static func dateNumbers(of due: Date, timeZone: TimeZone) -> Set<Int> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: due)
        guard let year = c.year, let month = c.month, let day = c.day else { return [] }
        return [year, year % 100, month, day]
    }

    /// `text` without the expressions that write `due` as a date: "2026-10-15", "15/10", "15th", "15 October",
    /// "October 15, 2026", "10月15日". Only an expression whose numbers all belong to the date is removed, so "3.5" stays.
    static func removingDate(_ due: Date, from text: String, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: due)
        guard let year = c.year, let month = c.month, let day = c.day else { return text }
        let allowed: Set<Int> = [year, year % 100, month, day]
        var folded = text.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let names = DateWords.months.values.joined().sorted { $0.count > $1.count }.joined(separator: "|")
        let patterns = [
            #"\d{4}\s*[-/.]\s*\d{1,2}\s*[-/.]\s*\d{1,2}"#,
            #"\d{1,2}\s*[-/.]\s*\d{1,2}(?:\s*[-/.]\s*\d{2,4})?"#,
            #"\d{1,2}(?:st|nd|rd|th|º|ª|er)\b"#,
            #"\d{1,2}\s*(?:de\s+|of\s+|di\s+|do\s+)?(?:"# + names + #")\b(?:\s*(?:de\s+|of\s+)?\d{4})?"#,
            #"\b(?:"# + names + #")\s+\d{1,2}(?:\s*,?\s*\d{4})?"#,
            #"(?:\d{4}\s*[年년]\s*)?\d{1,2}\s*[月월]\s*(?:\d{1,2}\s*[日일号號]?)?"#,
            #"\d{1,2}\s*[日일号號]"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = folded as NSString
            var result = ""
            var last = 0
            for match in regex.matches(in: folded, range: NSRange(location: 0, length: ns.length)) {
                let piece = ns.substring(with: match.range)
                let numbers = figures(in: piece).compactMap(Int.init)
                result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                if !numbers.isEmpty, numbers.allSatisfy({ allowed.contains($0) }) { result += " " } else { result += piece }
                last = match.range.location + match.range.length
            }
            result += ns.substring(from: last)
            folded = result
        }
        return folded
    }

    // MARK: Dates

    /// `due` falls on the meeting's day or the day after (in `timeZone`).
    public static func isMeetingDayOrNext(_ due: Date, reference: Date, timeZone: TimeZone = .current) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: reference), to: calendar.startOfDay(for: due)).day ?? 99
        return (0...1).contains(offset)
    }

    /// The due date is supported by the words of the segment: an explicit day (and month), a weekday, "today" or
    /// "tomorrow" counted from the meeting's date, or a period like "next week" that the calendar cannot contradict.
    /// A due date with none of these in its segment is not supported.
    public static func dueIsInSegment(_ due: Date, segment: String, reference: Date, timeZone: TimeZone = .current) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: due)
        guard let day = parts.day, let month = parts.month, let weekday = parts.weekday else { return true }
        let norm = TextKeys.norm(segment)

        // An explicit date: "December 15", "15/10", "10月15日", "the 15th".
        let monthNames = Set(DateWords.months.filter { DateWords.contains(norm, $0.value) }.map(\.key))
        let units = numberedUnits(in: segment)
        let unitMonths = Set(units.filter { $0.1 == "month" }.map(\.0)), unitDays = Set(units.filter { $0.1 == "day" }.map(\.0))
        let written = Set(figures(in: segment).compactMap(Int.init))
        let startOfReference = calendar.startOfDay(for: reference)
        let dueDay = calendar.startOfDay(for: due)
        let offset = calendar.dateComponents([.day], from: startOfReference, to: dueDay).day ?? 0
        // A date nobody says is "the next one": bound by the calendar so "the 15th" cannot back a date a year away.
        let nearby = (-1...366).contains(offset)
        if nearby, monthNames.contains(month), written.isEmpty || written.contains(day) { return true }
        if nearby, unitMonths.contains(month), unitDays.isEmpty || unitDays.contains(day) { return true }
        if nearby, unitMonths.isEmpty, unitDays.contains(day) { return true }
        if slashDates(in: segment).contains(where: { $0.day == day && $0.month == month }) { return true }
        if (-1...62).contains(offset), ordinalDays(in: segment).contains(day) { return true }

        // A weekday: the due date is that day, or the day before ("before Friday"), within the coming days.
        let mentioned = DateWords.mentionedWeekdays(norm)
        if (0...8).contains(offset), mentioned.contains(where: { $0 == weekday || ($0 == 1 ? 7 : $0 - 1) == weekday }) { return true }
        // "Next Friday" said on a Tuesday usually means the Friday of next week: ten days away.
        if (7...13).contains(offset), nextWeekdayIsMentioned(norm, weekday: weekday) { return true }

        // Today and tomorrow, counted from the meeting's day.
        if offset == 1, DateWords.mentionsTomorrow(norm) { return true }
        if DateWords.contains(norm, DateWords.today), offset == 0 { return true }
        if DateWords.contains(norm, DateWords.endOfDay), offset == 0 { return true }

        // Whole phrases for a stretch of the calendar: the due date has to fall inside it.
        if DateWords.contains(norm, DateWords.thisWeek), (0...7).contains(offset) { return true }
        if DateWords.contains(norm, DateWords.nextWeek), (1...14).contains(offset) { return true }
        if DateWords.contains(norm, DateWords.inTwoWeeks), (10...18).contains(offset) { return true }
        let monthGap = calendar.dateComponents([.month], from: calendar.date(from: calendar.dateComponents([.year, .month], from: reference))!,
                                                to: calendar.date(from: calendar.dateComponents([.year, .month], from: due))!).month
        if DateWords.contains(norm, DateWords.thisMonth), monthGap == 0, offset >= 0 { return true }
        if DateWords.contains(norm, DateWords.nextMonth), monthGap == 1 { return true }
        return false
    }

    /// A day of the month written as a day: "the 15th", "on 15", "el 15", "le 15", "am 15", "15º". A lone number
    /// in the segment ("3 people") is not a date.
    private static func ordinalDays(in text: String) -> Set<Int> {
        let pattern = #"(?i)(?:\b(?:the|on|el|le|il|am|dia|den|um)\s+(\d{1,2})\b)|(?:\b(\d{1,2})(?:st|nd|rd|th|º|ª|er)\b)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text.precomposedStringWithCompatibilityMapping as NSString
        var out = Set<Int>()
        for match in regex.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)) {
            for group in 1...2 where match.range(at: group).location != NSNotFound {
                let range = match.range(at: group)
                guard let n = Int(ns.substring(with: range)), (1...31).contains(n) else { continue }
                if group == 1 {
                    // "on 3 projects" is a quantity: a bare number must be followed by nothing, or by a month.
                    let rest = TextKeys.norm(ns.substring(from: range.location + range.length))
                    let next = rest.split(separator: " ").first.map(String.init)
                    let connectors: Set<String> = ["de", "of", "di", "do", "del", "da"]
                    if let next, !connectors.contains(next), !DateWords.months.values.joined().contains(next) { continue }
                }
                out.insert(n)
            }
        }
        return out
    }

    /// Numbers followed by a month or day marker of Japanese, Korean or Chinese ("10月", "15日", "10월 15일").
    private static func numberedUnits(in text: String) -> [(Int, String)] {
        var out: [(Int, String)] = []
        let chars = Array(text.precomposedStringWithCompatibilityMapping)
        var i = 0
        while i < chars.count {
            guard chars[i].isASCII, chars[i].isNumber else { i += 1; continue }
            var j = i
            var number = 0
            while j < chars.count, chars[j].isASCII, chars[j].isNumber, j - i < 4 { number = number * 10 + Int(String(chars[j]))!; j += 1 }
            var k = j
            while k < chars.count, chars[k] == " " { k += 1 }
            if k < chars.count {
                switch chars[k] {
                case "月", "월": out.append((number, "month"))
                case "日", "일", "号", "號": out.append((number, "day"))
                default: break
                }
            }
            i = max(j, i + 1)
        }
        return out
    }

    /// "15/10", "10-15", "15.10.2026", "2026-10-15": two numbers that can be a day and a month, in either order.
    private static func slashDates(in text: String) -> [(day: Int, month: Int)] {
        let folded = text.precomposedStringWithCompatibilityMapping
        var out: [(Int, Int)] = []
        let words = folded.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "(" || $0 == ")" })
        for word in words {
            let pieces = word.split(whereSeparator: { $0 == "/" || $0 == "-" || $0 == "." }).map(String.init)
            guard pieces.count >= 2, pieces.count <= 3, pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { continue }
            let numbers = pieces.compactMap(Int.init)
            guard numbers.count == pieces.count else { continue }
            if pieces[0].count == 4 {   // year first: 2026-10-15
                if numbers.count == 3, (1...12).contains(numbers[1]), (1...31).contains(numbers[2]) { out.append((numbers[2], numbers[1])) }
                continue
            }
            let (a, b) = (numbers[0], numbers[1])
            if (1...31).contains(a), (1...12).contains(b) { out.append((a, b)) }
            if (1...12).contains(a), (1...31).contains(b), a != b { out.append((b, a)) }
        }
        return out
    }

    // MARK: Names

    /// A person named in the item's text is also named in the segment (by name or alias, as whole words), or is
    /// the person the segment's confident speaker label points to. Names the text does not mention are not checked.
    /// A name counts as written in the item only with its own capitals ("Ana", "Mark"), so the everyday words that
    /// equal a name or an alias ("mark the invoices", Spanish "al", "will", "may") never look like a person. The
    /// segment side stays case-insensitive: transcripts are often lowercase.
    public static func namedPeopleAreBacked(itemText: String, people: [CandidateEntity], segment: String,
                                            speakerEntity: Int64?) -> Bool {
        let itemWords = caseWords(itemText), initial = sentenceInitial(itemText), itemNorm = TextKeys.norm(itemText), segNorm = TextKeys.norm(segment)
        for person in people where person.id != speakerEntity {
            let names = [person.name] + person.aliases
            let inItem = names.contains { name in
                let norm = TextKeys.norm(name)
                guard norm.count >= 2 else { return false }
                if norm.unicodeScalars.contains(where: TextKeys.isNoSpaceScript) { return itemNorm.contains(norm) }
                return containsWords(itemWords, caseWords(name), skippingInitial: initial)
            }
            guard inItem else { continue }
            let backed = names.contains { name in
                let norm = TextKeys.norm(name)
                return norm.count >= 2 && PromptText.containsNormalizedWords(segNorm, norm)
            }
            if !backed { return false }
        }
        return true
    }

    /// The words of `text` with accents and width folded but capitals kept.
    private static func caseWords(_ text: String) -> [String] {
        text.precomposedStringWithCompatibilityMapping.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// For each word of `caseWords(text)`: whether it opens the text or follows . : ; ! ? (or a CJK stop), where a
    /// capital says nothing about being a name.
    private static func sentenceInitial(_ text: String) -> [Bool] {
        var out: [Bool] = []
        var atStart = true, inWord = false
        for ch in text.precomposedStringWithCompatibilityMapping {
            if ch.isLetter || ch.isNumber {
                if !inWord { out.append(atStart); atStart = false; inWord = true }
            } else {
                inWord = false
                if ".:;!?。！？；：".contains(ch) { atStart = true }
            }
        }
        return out
    }

    /// Names that are also everyday words (imperative verbs, articles, prepositions, months): at the start of a sentence
    /// their capital says nothing, so "Mark the invoices" or "Al cliente le enviamos" names nobody. Any other name
    /// ("Bruno envía el informe") is still a person there.
    private static let homographNames: Set<String> = ["mark", "will", "may", "bill", "grant", "al"]

    /// `needle` appears in `words`. A single-word needle in sentence-initial position does not count ("Mark the invoices").
    private static func containsWords(_ words: [String], _ needle: [String], skippingInitial initial: [Bool] = []) -> Bool {
        guard !needle.isEmpty, words.count >= needle.count else { return false }
        return (0...(words.count - needle.count)).contains { i in
            guard Array(words[i..<(i + needle.count)]) == needle else { return false }
            if needle.count == 1, initial.count == words.count, initial[i], homographNames.contains(TextKeys.norm(needle[0])) { return false }
            return true
        }
    }
}
