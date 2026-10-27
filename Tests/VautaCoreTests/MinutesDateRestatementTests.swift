// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The meeting's own date written into the title or the summary goes, in the nine languages of the app, unless the transcript says that day.
@Suite("Minutes: the date of the meeting is not restated")
struct MinutesDateRestatementTests {
    static let utc = TimeZone(identifier: "UTC")!
    static var meetingDate: Date { Date(timeIntervalSince1970: 1_104_580_800) }   // 2005-01-01 12:00 UTC

    static func longDate(_ language: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: language)
        f.timeZone = utc
        f.dateStyle = .long
        f.timeStyle = .none
        return f.string(from: meetingDate)
    }

    @Test(arguments: [("en", "the team kept the budget", "The team kept the budget"), ("es", "el equipo mantuvo el presupuesto", "El equipo mantuvo el presupuesto"),
                      ("fr", "l’équipe a gardé le budget", "L’équipe a gardé le budget"), ("de", "das Team behielt das Budget", "Das Team behielt das Budget"),
                      ("it", "il team ha mantenuto il budget", "Il team ha mantenuto il budget"), ("pt", "a equipe manteve o orçamento", "A equipe manteve o orçamento"),
                      ("ja", "チームは予算を維持した", "チームは予算を維持した"), ("ko", "팀은 예산을 유지했다", "팀은 예산을 유지했다"),
                      ("zh", "团队保留了预算", "团队保留了预算")])
    func theDateAtTheStartOfASentenceGoesInEveryLanguage(language: String, rest: String, expected: String) {
        let date = Self.longDate(language)
        let out = MinutesText.dropMeetingDate("\(date), \(rest)", meetingDate: Self.meetingDate, timeZone: Self.utc, language: language, segments: [])
        #expect(out == expected, "\(date) → \(out)")
        let iso = MinutesText.dropMeetingDate("2005-01-01: \(rest)", meetingDate: Self.meetingDate, timeZone: Self.utc, language: language, segments: [])
        #expect(iso == expected, "\(iso)")
    }

    @Test func aDateTheTranscriptSaysStays() {
        let spoken = [CitableSegment(id: 1, channel: .others, start: 0, text: "We met on January 1 to plan the year")]
        let text = "On January 1, 2005, the team kept the budget"
        #expect(MinutesText.dropMeetingDate(text, meetingDate: Self.meetingDate, timeZone: Self.utc, language: "en", segments: spoken) == text)
        #expect(MinutesText.dropMeetingDate(text, meetingDate: Self.meetingDate, timeZone: Self.utc, language: "en", segments: []) == "The team kept the budget")
    }

    @Test func otherDatesAndTextWithoutOneAreUntouched() {
        let text = "The team kept the budget until March 3, 2005."
        #expect(MinutesText.dropMeetingDate(text, meetingDate: Self.meetingDate, timeZone: Self.utc, language: "en", segments: []) == text)
    }
}
