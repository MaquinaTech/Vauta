// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
import VautaCore
@testable import Vauta

/// The headers of the meetings list: an earlier month names its year only when it isn't this one.
@Suite struct MeetingDateSectionTitleTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return calendar
    }

    @Test func aMonthOfThisYearIsNamedAlone() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 10))!
        let thisYear = MeetingDateSection.month(year: 2026, month: 9).title(now: now, calendar: calendar)
        let lastYear = MeetingDateSection.month(year: 2025, month: 9).title(now: now, calendar: calendar)
        #expect(!thisYear.isEmpty && !thisYear.contains("2026"))
        #expect(lastYear.contains("2025"))
        #expect(thisYear != lastYear)
    }

    @Test func everySectionHasAHeader() {
        let now = Date.now
        for section in [MeetingDateSection.today, .yesterday, .thisWeek, .thisMonth] {
            #expect(!section.title(now: now, calendar: calendar).isEmpty)
        }
    }
}
