// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The time a question puts its meetings in ("what did we decide last week?", "¿qué se dijo ayer?", "先週の会議で…"), read
/// without a model, so Ask can look only in the meetings held then.
///
/// A time can also be what the question is about rather than when the meetings were: "what is due this week", "last month's
/// figures", "the plan for October". `applies` tells them apart, conservatively:
/// - a past period said plainly ("last week", "two days ago", "el lunes pasado") applies;
/// - a current period ("today", "this week") is only offered, unless a meeting is named next to it ("today's meeting");
/// - a past period said as what something is of ("las ventas del mes pasado") is only offered, unless that is a meeting;
/// - a day applies after "on" ("on October 3", "el 3 de octubre"; a day with no meeting widens the search, see `LLMService.ask`)
///   and is offered otherwise; a month, quarter or year applies next to a meeting, is offered after "in" and is ignored otherwise;
/// - "since" makes any of them a stretch up to today, which applies;
/// - a deadline ("by Friday", "para hoy", "今週中に") and anything still to come are ignored.
///
/// Applied, the person can remove it; offered, they can apply it (Ask shows it as a control under the question).
public struct AskTimeScope: Sendable, Equatable {
    public enum Span: Sendable, Equatable { case day, week, month, quarter, year, range }

    /// Start included, end excluded; it never ends after today.
    public let interval: DateInterval
    /// How the interval is named on screen (`label`).
    public let span: Span
    /// Whether Ask uses it without being asked (see the type's description).
    public let applies: Bool

    public init(interval: DateInterval, span: Span, applies: Bool) {
        self.interval = interval
        self.span = span
        self.applies = applies
    }

    /// The time of `question`, written in one of `languages` (BCP-47; Ask passes the question's language when it can be told,
    /// else the person's), or nil when it names none. Several times are joined into one stretch ("this week and last week").
    public static func read(_ question: String, languages: [String], now: Date = .now, calendar: Calendar = .current) -> AskTimeScope? {
        let text = TextKeys.norm(question)
        guard !text.isEmpty else { return nil }
        let codes = Set(languages.compactMap { Locale(identifier: $0).language.languageCode?.identifier })
        let tokens = text.split(separator: " ").map(String.init)
        var found: [AskTimeScope] = []
        for code in codes.sorted() {
            if let lexicon = AskTimeWords.latin[code] {
                found += readLatin(tokens, lexicon).compactMap { decide($0.named, $0.context, now: now, calendar: calendar) }
            }
            if let script = AskTimeWords.scripts[code] {
                found += readScript(text, script).compactMap { decide($0.named, $0.context, now: now, calendar: calendar) }
            }
        }
        var unique: [AskTimeScope] = []
        for scope in found where !unique.contains(where: { $0.interval == scope.interval && $0.applies == scope.applies }) { unique.append(scope) }
        guard let first = unique.first else { return nil }
        guard unique.count > 1 else { return first }
        let start = unique.map(\.interval.start).min()!, end = unique.map(\.interval.end).max()!
        return AskTimeScope(interval: DateInterval(start: start, end: end), span: .range, applies: unique.allSatisfy(\.applies))
    }

    /// The interval as the person reads it: "Oct 28, 2026", "Oct 19 – 25, 2026", "October 2026", "Q3 2026", "2025".
    public func label(calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        let last = interval.end.addingTimeInterval(-1)
        switch span {
        case .month: formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        case .quarter: formatter.setLocalizedDateFormatFromTemplate("yQQQ")
        case .year: formatter.setLocalizedDateFormatFromTemplate("y")
        case .day: formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        case .week, .range:
            formatter.setLocalizedDateFormatFromTemplate("yMMMd")
            guard !calendar.isDate(interval.start, inSameDayAs: last) else { break }
            let range = DateIntervalFormatter()
            range.calendar = calendar
            range.timeZone = calendar.timeZone
            range.locale = locale
            range.dateTemplate = "yMMMd"
            return range.string(from: interval.start, to: last)
        }
        return formatter.string(from: interval.start)
    }

    // MARK: Deciding

    /// What a phrase names, before the words around it are read.
    enum Named: Equatable {
        case relative(AskTimeWords.Relative, current: Bool)
        case ago(AskTimeWords.Unit, Int)
        /// The last such weekday before today, or the one of last week ("先週の月曜", "上周一").
        case weekday(Int, lastWeek: Bool)
        case date(year: Int?, month: Int, day: Int?)
        case quarter(year: Int?, Int)
        case year(Int)
    }

    /// The words around a time: a deadline, the start of a stretch, a meeting it is the time of, something else it is the time
    /// of, the time in which something happened, or nothing of the kind.
    enum Context: Equatable { case deadline, since, meeting, genitive, into, plain }

    static func decide(_ named: Named, _ context: Context, now: Date, calendar: Calendar) -> AskTimeScope? {
        guard context != .deadline, let (interval, span) = interval(named, now: now, calendar: calendar) else { return nil }
        if context == .since {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            return AskTimeScope(interval: DateInterval(start: interval.start, end: tomorrow), span: .range, applies: true)
        }
        let applies: Bool?
        switch named {
        case .relative(_, current: true):
            applies = context == .meeting
        case .relative, .ago, .weekday:
            applies = context != .genitive
        case .date(_, _, day: .some):
            applies = context == .meeting || context == .into
        case .date, .quarter, .year:
            // "What were the sales in September?" is about September as often as "what happened in September?" is about its
            // meetings, and a month always has some: a wrong filter would hide the answer without a word, so it is only offered.
            switch context {
            case .meeting: applies = true
            case .into: applies = false
            default: applies = nil
            }
        }
        return applies.map { AskTimeScope(interval: interval, span: span, applies: $0) }
    }

    /// The interval a phrase names, cut at the end of today; nil when it has not begun yet ("in December" in October, "on the
    /// 5th" before the 5th) or is not a date.
    static func interval(_ named: Named, now: Date, calendar: Calendar) -> (DateInterval, Span)? {
        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
        func cut(_ interval: DateInterval?, _ span: Span) -> (DateInterval, Span)? {
            guard let interval, interval.start < tomorrow else { return nil }
            return (DateInterval(start: interval.start, end: min(interval.end, tomorrow)), span)
        }
        func days(_ from: Int, _ count: Int) -> DateInterval? {
            guard let start = calendar.date(byAdding: .day, value: from, to: today),
                  let end = calendar.date(byAdding: .day, value: count, to: start) else { return nil }
            return DateInterval(start: start, end: end)
        }
        func of(_ component: Calendar.Component, _ offset: Int) -> DateInterval? {
            calendar.date(byAdding: component, value: offset, to: now).flatMap { calendar.dateInterval(of: component, for: $0) }
        }
        func quarter(year: Int, _ q: Int) -> DateInterval? {
            guard (1...4).contains(q), let start = calendar.date(from: DateComponents(year: year, month: (q - 1) * 3 + 1, day: 1)),
                  let end = calendar.date(byAdding: .month, value: 3, to: start) else { return nil }
            return DateInterval(start: start, end: end)
        }
        let thisYear = calendar.component(.year, from: now)
        switch named {
        case .relative(let period, _):
            switch period {
            case .day(let n): return cut(days(n, 1), .day)
            case .week(let n): return cut(of(.weekOfYear, n), .week)
            case .month(let n): return cut(of(.month, n), .month)
            case .year(let n): return cut(of(.year, n), .year)
            case .quarter(let n):
                let q = (calendar.component(.month, from: now) - 1) / 3 + 1
                guard let current = quarter(year: thisYear, q), let start = calendar.date(byAdding: .month, value: 3 * n, to: current.start),
                      let end = calendar.date(byAdding: .month, value: 3, to: start) else { return nil }
                return cut(DateInterval(start: start, end: end), .quarter)
            case .rolling(let unit, let n):
                guard let back = calendar.date(byAdding: unit.component, value: -n, to: today) else { return nil }
                return cut(DateInterval(start: calendar.startOfDay(for: back), end: tomorrow), .range)
            }
        case .ago(let unit, let n):
            switch unit {
            // "Three days ago": people round, so the day before and after count too.
            case .day: return cut(days(-n - 1, 3), .range)
            case .week: return cut(of(.weekOfYear, -n), .week)
            case .month: return cut(of(.month, -n), .month)
            case .year: return cut(of(.year, -n), .year)
            }
        case .weekday(let weekday, let lastWeek):
            if lastWeek {
                guard let week = of(.weekOfYear, -1) else { return nil }
                for k in 0..<7 {
                    guard let day = calendar.date(byAdding: .day, value: k, to: week.start) else { continue }
                    if calendar.component(.weekday, from: day) == weekday { return cut(days(calendar.dateComponents([.day], from: today, to: day).day ?? 0, 1), .day) }
                }
                return nil
            }
            for k in 1...7 {
                guard let day = calendar.date(byAdding: .day, value: -k, to: today) else { continue }
                if calendar.component(.weekday, from: day) == weekday { return cut(days(-k, 1), .day) }
            }
            return nil
        case .date(let year, let month, let day):
            guard (1...12).contains(month) else { return nil }
            let y = year ?? thisYear
            if let day {
                let parts = DateComponents(year: y, month: month, day: day)
                // February 30 is not a date (Calendar would move it to March).
                guard let start = calendar.date(from: parts), calendar.component(.day, from: start) == day,
                      let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
                return cut(DateInterval(start: start, end: end), .day)
            }
            return cut(calendar.date(from: DateComponents(year: y, month: month, day: 1)).flatMap { calendar.dateInterval(of: .month, for: $0) }, .month)
        case .quarter(let year, let q):
            return cut(quarter(year: year ?? thisYear, q), .quarter)
        case .year(let y):
            return cut(calendar.date(from: DateComponents(year: y, month: 1, day: 1)).flatMap { calendar.dateInterval(of: .year, for: $0) }, .year)
        }
    }
}

extension AskTimeWords.Unit {
    var component: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }
}
