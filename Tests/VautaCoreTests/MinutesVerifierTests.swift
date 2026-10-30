// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The deterministic checks of a decision or task against the segment it cites.
@Suite("Minutes: verification against the cited segment")
struct MinutesVerifierTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let utc = TimeZone(identifier: "UTC")!
    /// Tuesday 2026-10-06, the day of the meetings below.
    private var meeting: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 10))! }
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date { calendar.date(from: DateComponents(year: y, month: m, day: d))! }
    private func due(_ due: Date, _ segment: String) -> Bool {
        MinutesVerifier.dueIsInSegment(due, segment: segment, reference: meeting, timeZone: utc)
    }

    // MARK: Figures

    @Test func figuresAreComparedAsDigits() {
        #expect(MinutesVerifier.figures(in: "Budget of 1,500 euros, 20% and 3.5 weeks") == ["1500", "20", "35"])
        #expect(MinutesVerifier.figures(in: "予算は１２００万円") == ["1200"], "full-width digits are digits")
        #expect(MinutesVerifier.figuresAreInSegment(item: "Raise the budget to 1,500", segment: "subimos el presupuesto a 1.500 euros"))
        #expect(MinutesVerifier.figuresAreInSegment(item: "Send the report", segment: "anything"), "no figures, nothing to check")
        #expect(!MinutesVerifier.figuresAreInSegment(item: "Raise the budget to 15,000", segment: "subimos el presupuesto a 1.500 euros"))
        #expect(!MinutesVerifier.figuresAreInSegment(item: "Send 40 slides", segment: "send the slides"))
        // The date of the task is checked as a date, not as figures.
        #expect(MinutesVerifier.figuresAreInSegment(item: "Send the slides by 2026-10-09", segment: "send the slides by Friday", due: day(2026, 10, 9), timeZone: utc))
        // Numbers written in kanji cannot be compared digit by digit.
        #expect(MinutesVerifier.figuresAreInSegment(item: "Budget 300", segment: "予算は三百万円です"))
    }

    /// The number of a transcript label is not a figure: "Speaker 5 to build the dictionary" cites words that never say "5".
    @Test func aSpeakerLabelIsNotAFigure() {
        #expect(MinutesVerifier.figuresAreInSegment(item: "Speaker 5 to build the frequency dictionary", segment: "I'll build the frequency dictionary"))
        #expect(MinutesVerifier.figuresAreInSegment(item: "Speaker 4 and Speaker 5 to meet on Wednesday", segment: "let's meet on Wednesday"))
        #expect(MinutesVerifier.figuresAreInSegment(item: "Me 2 books the room", segment: "I'll book the room"))
        // The figures next to a label are still checked, and "me" in a sentence is not a label.
        #expect(!MinutesVerifier.figuresAreInSegment(item: "Speaker 5 to send 40 slides", segment: "I'll send the slides"))
        #expect(!MinutesVerifier.figuresAreInSegment(item: "Send me 2 copies", segment: "send me the copies"))
    }

    @Test func hanNumeralsAreComparedNotSkipped() {
        #expect(MinutesVerifier.figuresAreInSegment(item: "联系50家客户", segment: "我们联系五十家客户"))
        #expect(!MinutesVerifier.figuresAreInSegment(item: "联系50家客户", segment: "我们一起联系五家客户"), "一起 is a word, 五 is 5")
        #expect(MinutesVerifier.figuresAreInSegment(item: "予算300万円", segment: "予算は三百万円です"))
        #expect(!MinutesVerifier.figuresAreInSegment(item: "予算400万円", segment: "予算は三百万円です"))
        #expect(!MinutesVerifier.figuresAreInSegment(item: "40 slides", segment: "统一一下"), "统一 and 一下 are words")
    }

    @Test func aWrongFigureWrittenInHanNumeralsIsCaught() {
        #expect(!MinutesVerifier.figuresAreInSegment(item: "联系五十家供应商", segment: "我们联系五家供应商"))
        #expect(MinutesVerifier.figuresAreInSegment(item: "联系五十家供应商", segment: "我们联系五十家供应商"))
        #expect(MinutesVerifier.figuresAreInSegment(item: "联系五十家供应商", segment: "我们联系50家供应商"), "digits and numerals compare")
        #expect(!MinutesVerifier.figuresAreInSegment(item: "予算四百万円", segment: "予算は三百万円です"))
        #expect(MinutesVerifier.figuresAreInSegment(item: "統一する", segment: "anything"), "a word that holds a numeral is not a figure")
        // The date's own numerals are the date check's business.
        #expect(MinutesVerifier.figuresAreInSegment(item: "十月十五日までに送る", segment: "金曜日までに送ります", due: day(2026, 10, 15), timeZone: utc))
        #expect(!MinutesVerifier.figuresAreInSegment(item: "十月十五日までに五十件送る", segment: "金曜日までに五件送ります", due: day(2026, 10, 15), timeZone: utc))
    }

    @Test func aQuantityEqualToTheDueDateIsStillChecked() {
        let due = day(2026, 10, 12)
        #expect(!MinutesVerifier.figuresAreInSegment(item: "Order 12 laptops", segment: "Order 50 laptops by the 12th", due: due, timeZone: utc))
        #expect(MinutesVerifier.figuresAreInSegment(item: "Order 50 laptops by 12 October", segment: "Order 50 laptops by the 12th", due: due, timeZone: utc))
        #expect(MinutesVerifier.figuresAreInSegment(item: "Send by 2026-10-12", segment: "Send it by the 12th", due: due, timeZone: utc))
        #expect(MinutesVerifier.figuresAreInSegment(item: "10月12日までに送る", segment: "send by the 12th", due: due, timeZone: utc))
    }

    // MARK: Dates

    @Test func relativeDaysAreCountedFromTheMeeting() {
        #expect(due(day(2026, 10, 7), "I'll send it tomorrow"))
        #expect(!due(day(2026, 10, 9), "I'll send it tomorrow"))
        #expect(due(day(2026, 10, 6), "Lo hago hoy mismo"))
        #expect(due(day(2026, 10, 7), "Je l'envoie demain"))
        #expect(due(day(2026, 10, 7), "明日までに送ります"))
        #expect(due(day(2026, 10, 7), "내일까지 보낼게요"))
        #expect(due(day(2026, 10, 7), "我明天发给你"))
        #expect(due(day(2026, 10, 7), "Ich schicke es morgen"))
        #expect(due(day(2026, 10, 7), "Te lo mando domani"))
    }

    @Test func weekdaysMatchTheDueDateOrTheDayBefore() {
        let friday = day(2026, 10, 9)
        #expect(due(friday, "before Friday please"))
        #expect(due(day(2026, 10, 8), "antes del viernes"))
        #expect(!due(day(2026, 10, 12), "antes del viernes"), "a Monday is not Friday")
        #expect(due(friday, "vendredi au plus tard"))
        #expect(due(friday, "bis Freitag"))
        #expect(due(friday, "entro venerdì"))
        #expect(due(friday, "até sexta"))
        #expect(due(friday, "金曜日までにお願いします"))
        #expect(due(friday, "금요일까지 부탁드려요"))
        #expect(due(friday, "周五之前给我"))
    }

    @Test func morningAndOrdinalsDoNotBackADay() {
        let tomorrow = day(2026, 10, 7), friday = day(2026, 10, 9), monday = day(2026, 10, 12), thursday = day(2026, 10, 8)
        // "Morgen" and "mañana" are also the morning.
        #expect(!due(tomorrow, "Ich habe es heute Morgen geschickt"))
        #expect(!due(tomorrow, "Lo envié esta mañana"))
        #expect(!due(tomorrow, "Lo reviso por la mañana"))
        #expect(!due(tomorrow, "Guten Morgen zusammen"))
        #expect(!due(tomorrow, "Lo tengo pasado mañana"), "the day after tomorrow")
        #expect(!due(tomorrow, "Je l'envoie après-demain"))
        #expect(due(tomorrow, "Lo envío mañana"))
        #expect(due(tomorrow, "Hasta mañana, entonces"))
        #expect(due(tomorrow, "Morgen schicke ich es"))
        #expect(due(tomorrow, "Eu mando amanhã"))
        // Portuguese weekdays are also ordinals.
        #expect(!due(monday, "Usamos a segunda versão do contrato"))
        #expect(!due(thursday, "Esta é a quinta parte do plano"))
        #expect(!due(friday, "Leí la sexta página"))
        #expect(due(monday, "Te mando até segunda-feira"))
        #expect(due(thursday, "Fica pra quinta"))
        #expect(due(friday, "Entrego na sexta"))
        #expect(due(friday, "Entrego sexta-feira"))
    }

    @Test func nextWeekdayAndInTwoWeeksAreAccepted() {
        let nextFriday = day(2026, 10, 16)   // a Tuesday meeting: ten days away
        #expect(due(nextFriday, "I'll have it by next Friday"))
        #expect(due(nextFriday, "lo tengo el próximo viernes"))
        #expect(due(nextFriday, "je l'envoie vendredi prochain"))
        #expect(due(nextFriday, "bis nächsten Freitag"))
        #expect(due(nextFriday, "entro venerdì prossimo"))
        #expect(due(nextFriday, "来週の金曜日までに"))
        #expect(due(day(2026, 10, 20), "en dos semanas lo cerramos"))
        #expect(due(day(2026, 10, 20), "ready in two weeks"))
        #expect(due(day(2026, 10, 20), "两周后交付"))
        #expect(!due(day(2026, 10, 20), "ready in two days"))
        #expect(!due(nextFriday, "I'll have it by Friday"), "a plain Friday is the coming one, not ten days away")
        #expect(!due(day(2026, 10, 17), "by next Friday"), "a Saturday is not that Friday")
        #expect(!due(day(2026, 11, 20), "by next Friday"), "far beyond next week")
    }

    @Test func explicitDatesAreMatchedLiterally() {
        let target = day(2026, 10, 15)
        #expect(due(target, "ship it on October 15"))
        #expect(due(target, "lo entregamos el 15 de octubre"))
        #expect(due(target, "livraison le 15/10"))
        #expect(due(target, "bis zum 15.10."))
        #expect(due(target, "10月15日までに"))
        #expect(due(target, "10월 15일까지"))
        #expect(due(target, "the 15th at the latest"))
        #expect(!due(target, "ship it on October 20"))
        #expect(!due(target, "lo entregamos el 20 de octubre"))
        #expect(!due(target, "we need 15 people"), "a lone number is not a date")
    }

    @Test func periodsAndMissingWordsAreHandledHonestly() {
        #expect(due(day(2026, 10, 30), "we close it by the end of the month"))
        #expect(due(day(2026, 10, 13), "la semana que viene"))
        #expect(due(day(2026, 10, 13), "来週までに"))
        #expect(!due(day(2026, 10, 13), "send the report"), "a date nobody said")
    }

    @Test func everydayWordsDoNotSupportADate() {
        let monday = day(2026, 10, 12)
        #expect(!due(monday, "J'envoie mes notes vendredi."), "a Friday is not a Monday")
        #expect(!due(monday, "Fine, I'll send it on Friday."))
        #expect(!due(day(2026, 12, 25), "Next, I'll send it tomorrow."))
        #expect(!due(day(2026, 10, 30), "Ende gut, alles gut"), "ende is not a period")
        // A weekday far in the future is not the coming one; "on 3 projects" is no day.
        #expect(!due(day(2026, 11, 20), "I'll send it on Friday"))
        #expect(!due(day(2026, 11, 3), "We are working on 3 projects"))
        #expect(!due(day(2026, 10, 30), "next week"), "next week is not the end of the month")
        #expect(!due(day(2027, 10, 15), "ship it on October 15"), "a year away")
        #expect(due(day(2026, 11, 3), "el mes que viene"))
    }

    // MARK: Names

    @Test func peopleNamedInTheTextAreInTheSegment() {
        let people = [CandidateEntity(id: 5, kind: .person, name: "Ana Ruiz", aliases: ["Ana"]),
                      CandidateEntity(id: 6, kind: .person, name: "Bruno", aliases: [])]
        #expect(MinutesVerifier.namedPeopleAreBacked(itemText: "Ana sends the report", people: people, segment: "Ana, can you send it?", speakerEntity: nil))
        #expect(!MinutesVerifier.namedPeopleAreBacked(itemText: "Bruno sends the report", people: people, segment: "Ana, can you send it?", speakerEntity: nil))
        #expect(MinutesVerifier.namedPeopleAreBacked(itemText: "Bruno sends the report", people: people, segment: "I'll send it", speakerEntity: 6),
                "the confident speaker is Bruno")
        #expect(MinutesVerifier.namedPeopleAreBacked(itemText: "Send the report", people: people, segment: "x", speakerEntity: nil))
        #expect(MinutesVerifier.namedPeopleAreBacked(itemText: "Prepare the manana plan", people: [CandidateEntity(id: 7, kind: .person, name: "Ana", aliases: [])],
                                                     segment: "x", speakerEntity: nil), "Ana is not found inside mañana")
    }

    @Test func everydayWordsThatEqualANameAreNotPeople() {
        let people = [CandidateEntity(id: 5, kind: .person, name: "Mark", aliases: []),
                      CandidateEntity(id: 6, kind: .person, name: "Alejandro", aliases: ["Al"]),
                      CandidateEntity(id: 7, kind: .person, name: "Will", aliases: []),
                      CandidateEntity(id: 8, kind: .person, name: "May", aliases: [])]
        func backed(_ item: String, _ segment: String = "send the invoices") -> Bool {
            MinutesVerifier.namedPeopleAreBacked(itemText: item, people: people, segment: segment, speakerEntity: nil)
        }
        #expect(backed("Send them, then mark the invoices as paid"))
        #expect(backed("Enviar al cliente el informe"), "Spanish 'al'")
        #expect(backed("The team will send the invoices in may"))
        // A name with its capitals still has to be in the segment.
        #expect(!backed("Ask Mark to send the invoices"))
        #expect(backed("Ask Mark to send the invoices", "mark, can you send the invoices"), "a lowercase transcript is fine")
        #expect(!backed("Ask Al to send the invoices"))
        #expect(backed("Ask Al to send the invoices", "Al, can you send the invoices"))
        #expect(!backed("Alejandro envía las facturas"))
        #expect(backed("Álejandro envía las facturas", "alejandro, envíalas"), "accents do not matter")
    }

    // MARK: Through validateMinutes

    @Test func mismatchesAreMarkedUnconfirmedNotDropped() throws {
        let segments: [Int64: CitableSegment] = [
            10: CitableSegment(id: 10, channel: .others, start: 60, text: "Ana, can you finish the Kobaltix migration before Friday? It is 40 hours."),
        ]
        let candidates = [CandidateEntity(id: 1, kind: .person, name: "Yo", aliases: []),
                          CandidateEntity(id: 5, kind: .person, name: "Ana", aliases: []),
                          CandidateEntity(id: 6, kind: .person, name: "Bruno", aliases: [])]
        func run(_ text: String, due: String?) throws -> ValidatedMinutes.Task {
            let dueJSON = due.map { "\"\($0)\"" } ?? "null"
            let json = """
                {"decisions": [], "entities": [], "tasks": [{"text": "\(text)", "owner": "Ana", "due": \(dueJSON), "seg": 10, "quote": "finish the Kobaltix migration"}]}
                """
            let minutes = try VautaPrompts.validateMinutes(json, segments: segments, candidates: candidates, selfEntity: 1,
                                                       meetingPeople: [5], reference: meeting, timeZone: utc)
            return try #require(minutes.tasks.first)
        }
        #expect(try run("Ana finishes the migration (40 hours)", due: "2026-10-09").unconfirmed == false)
        #expect(try run("Ana finishes the migration (400 hours)", due: "2026-10-09").unconfirmed, "a figure the segment does not have")
        #expect(try run("Ana finishes the migration", due: "2026-10-20").unconfirmed, "a date the segment does not support")
        #expect(try run("Bruno finishes the migration", due: "2026-10-09").unconfirmed, "a name the segment does not have")
        let kept = try run("Ana finishes the migration (400 hours)", due: nil)
        #expect(kept.owner == 5 && kept.segment == 10, "the item stays, with its owner")
    }

    @Test func decisionsAreVerifiedToo() throws {
        let segments: [Int64: CitableSegment] = [
            11: CitableSegment(id: 11, channel: .me, start: 75, text: "We decided to raise the budget to 20000 euros"),
        ]
        func decision(_ text: String) throws -> ValidatedMinutes.Item {
            let json = """
                {"tasks": [], "entities": [], "decisions": [{"text": "\(text)", "seg": 11, "quote": "raise the budget to 20000"}]}
                """
            return try #require(try VautaPrompts.validateMinutes(json, segments: segments, candidates: [], selfEntity: nil).decisions.first)
        }
        #expect(try decision("Raise the budget to 20,000 euros").unconfirmed == false)
        #expect(try decision("Raise the budget to 30,000 euros").unconfirmed)
    }
}
