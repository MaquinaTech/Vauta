// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// A calendar day with no time and no time zone: the day a task is due, as the minutes wrote it (`tasks.due_day`, 'YYYY-MM-DD').
///
/// A due day is a label, not an instant. It is never turned into a `Date` and formatted again in another zone, which is how a day
/// drifts when the person travels: reminders take its year, month and day as floating `DateComponents`, and an email prints it
/// through UTC noon of the same day. The arithmetic is the proleptic Gregorian civil calendar, so nothing here depends on the Mac's
/// settings.
public struct DueDay: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month), day >= 1, day <= Self.daysIn(month: month, year: year) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Strictly `YYYY-MM-DD` (ASCII digits, a real date).
    public init?(_ string: String) {
        let bytes = Array(string.utf8)
        guard bytes.count == 10, bytes[4] == 0x2D, bytes[7] == 0x2D else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for i in range {
                guard (0x30...0x39).contains(bytes[i]) else { return nil }
                value = value * 10 + Int(bytes[i] - 0x30)
            }
            return value
        }
        guard let y = number(0..<4), let m = number(5..<7), let d = number(8..<10) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// The calendar day of `date` in `timeZone` (the person's zone when they set it; the meeting's when minutes were written).
    public static func containing(_ date: Date, in timeZone: TimeZone) -> DueDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return DueDay(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1) ?? DueDay(year: 1970, month: 1, day: 1)!
    }

    /// 'YYYY-MM-DD'.
    public var string: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var description: String { string }

    public static func < (a: DueDay, b: DueDay) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }

    // MARK: Civil arithmetic (days since 1970-01-01)

    static func isLeap(_ year: Int) -> Bool { (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 }

    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// Days since 1970-01-01 (Howard Hinnant's `days_from_civil`).
    public var epochDay: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    public init(epochDay z0: Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        self.year = y
        self.month = m
        self.day = d
    }

    public func adding(days: Int) -> DueDay { DueDay(epochDay: epochDay + days) }

    /// The longest a due day may lie after the meeting and still be believed.
    public static let plausibleSpanDays = 366

    /// A due day is believable when it is not before the meeting's own day and not more than a year after it. The evaluation found
    /// days years before the meeting (a model copying a date from its training data): they are dropped, never written to Reminders or
    /// an email.
    public func isPlausible(meetingDay: DueDay) -> Bool {
        let gap = epochDay - meetingDay.epochDay
        return gap >= 0 && gap <= Self.plausibleSpanDays
    }

    /// Calendar numbering: 1 = Sunday … 7 = Saturday.
    public var weekday: Int {
        let w = ((epochDay % 7) + 7 + 4) % 7   // 1970-01-01 was a Thursday
        return w + 1
    }

    // MARK: Using the day

    /// Year, month and day only: no calendar, no time zone, no time. This is what a reminder's `dueDateComponents` takes, so the due day
    /// floats with the person instead of naming an instant.
    public var floatingComponents: DateComponents { DateComponents(year: year, month: month, day: day) }

    /// The same day with a wall-clock time, still floating (a reminder alert at 09:00 of that day, wherever the person is).
    public func floatingComponents(minuteOfDay: Int) -> DateComponents {
        DateComponents(year: year, month: month, day: day, hour: minuteOfDay / 60, minute: minuteOfDay % 60)
    }

    /// A moment in UTC that carries the same year, month and day (at noon, far from either edge), to be formatted with a UTC calendar.
    var utcNoon: Date { Date(timeIntervalSince1970: Double(epochDay) * 86_400 + 43_200) }
    public var utcNoonDate: Date { utcNoon }

    /// "Friday 16 October" in `locale`'s wording and order, never converted through a time zone.
    public func formatted(locale: Locale, withYear: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = TimeZone(identifier: "UTC")
        f.calendar = Calendar(identifier: .gregorian)
        f.setLocalizedDateFormatFromTemplate(withYear ? "EEEEdMMMMy" : "EEEEdMMMM")
        return f.string(from: utcNoon)
    }

    /// The start of this day in `timeZone`, for sorting and the existing `due` column. Not for display.
    public func startOfDay(in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: floatingComponents) ?? utcNoon
    }
}
