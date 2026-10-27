// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Brief: summary sentence and printed dates")
struct BriefSummaryTests {
    @Test func anAbbreviationDoesNotEndTheSentence() {
        #expect(BriefText.firstSentence("Se aprobó la moción presentada por la Sra. Pérez. Luego se votó.") == "Se aprobó la moción presentada por la Sra. Pérez.")
        #expect(BriefText.firstSentence("Dr. Smith opened. Then they voted.") == "Dr. Smith opened.")
        #expect(BriefText.firstSentence("First. Second.") == "First.")
        #expect(BriefText.firstSentence("We discussed budget, staffing, etc. The board will vote.") == "We discussed budget, staffing, etc.")
        #expect(BriefText.firstSentence("Se votó que no. Luego se cerró la sesión.") == "Se votó que no.")
        #expect(BriefText.firstSentence("They listed apples, etc. and more. Then they left.") == "They listed apples, etc. and more.")
        #expect(BriefText.firstSentence("Ticket No. 5 was closed. Then they left.") == "Ticket No. 5 was closed.")
        #expect(BriefText.firstSentence("Maria J. Smith opened. Then they voted.") == "Maria J. Smith opened.")
        #expect(BriefText.firstSentence("We chose option a. Then we voted.") == "We chose option a.")
        #expect(BriefText.firstSentence("The deadline falls on the 21st. Then they left.") == "The deadline falls on the 21st.")
        #expect(BriefText.firstSentence("They reviewed the art. Then they left.") == "They reviewed the art.")
        #expect(BriefText.firstSentence("No full stop here") == "No full stop here")
        #expect(BriefText.firstSentence("会議を開始した。次に進んだ。") == "会議を開始した。")
    }

    @Test func aSentenceThatDatesTheMeetingDifferentlyIsSkipped() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid") ?? .current
        let date = calendar.date(from: DateComponents(year: 2004, month: 12, day: 25, hour: 10)) ?? .now
        let text = "During the general work meeting on 2005-01-01 they chose a design. The team agreed to meet again."
        #expect(BriefText.firstSentence(text, meetingDate: date, calendar: calendar) == "The team agreed to meet again.")
        let same = "On 2004-12-25 they chose a design."
        #expect(BriefText.firstSentence(same, meetingDate: date, calendar: calendar) == same)
        #expect(BriefText.firstSentence("Only 2005-01-01 here.", meetingDate: date, calendar: calendar) == nil)
        #expect(BriefText.firstSentence("No date here.", meetingDate: nil) == "No date here.")
    }

    @Test func aDateWrittenInWordsIsRecognisedInTheSummaryLanguage() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid") ?? .current
        let date = calendar.date(from: DateComponents(year: 2004, month: 12, day: 25, hour: 10)) ?? .now
        let es = "El 1 de enero de 2005 se aprobó el diseño. El equipo acordó volver a reunirse."
        #expect(BriefText.firstSentence(es, meetingDate: date, calendar: calendar) == "El equipo acordó volver a reunirse.")
        let en = "On January 1, 2005 they chose a design. The team agreed to meet again."
        #expect(BriefText.firstSentence(en, meetingDate: date, calendar: calendar) == "The team agreed to meet again.")
        #expect(BriefText.firstSentence("Le 1er janvier 2005, le design a été choisi. L’équipe a convenu de se revoir.", meetingDate: date, calendar: calendar) == "L’équipe a convenu de se revoir.")
        #expect(BriefText.firstSentence("Il 1 gennaio 2005 si è scelto il design. Il team si rivedrà.", meetingDate: date, calendar: calendar) == "Il team si rivedrà.")
        let ownDay = "El 25 de diciembre de 2004 se aprobó el diseño."
        #expect(BriefText.firstSentence(ownDay, meetingDate: date, calendar: calendar) == ownDay, "the meeting's own day is not another date")
        let month = "The January pricing was approved."
        #expect(BriefText.firstSentence(month, meetingDate: date, calendar: calendar) == month, "a month with no day is not a date")
        #expect(BriefText.firstSentence("1月1日に決定した。次に進んだ。", meetingDate: date, calendar: calendar) == "次に進んだ。")
    }

    @Test func aDayIsPrintedInTheCalendarsTimeZoneNotUTC() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid") ?? .current
        let midnight = calendar.date(from: DateComponents(year: 2005, month: 5, day: 3)) ?? .now
        #expect(BriefText.isoDay(midnight, calendar: calendar) == "2005-05-03", "local midnight is the previous day in UTC")
    }

    @Test func aGermanOrdinalDoesNotEndTheSentence() {
        let de = "Das Team hat beschlossen, den Start am 28. beizubehalten. Danach folgt der Test."
        #expect(BriefText.sentences(de) == ["Das Team hat beschlossen, den Start am 28. beizubehalten.", "Danach folgt der Test."])
        #expect(BriefText.sentences("Start am 1. Januar geplant. Weiter.") == ["Start am 1. Januar geplant.", "Weiter."])
        #expect(BriefText.sentences("We shipped 28. The team agreed.") == ["We shipped 28.", "The team agreed."], "a capitalised word still ends it")
    }
}
