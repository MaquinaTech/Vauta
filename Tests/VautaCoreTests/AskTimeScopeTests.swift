// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The time of a question, in the nine languages: what it names (from a fixed Thursday, 29 October 2026, in a calendar whose
/// weeks start on Monday) and whether Ask applies it or only offers it.
@Suite("Ask: the time a question names")
struct AskTimeScopeTests {
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Madrid")!
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        c.locale = Locale(identifier: "en_GB")
        return c
    }()
    private static let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 15))!

    /// "10-28..10-29" (2026 unless a year is written: "2025-07-01..2025-10-01"), then "applies" or "offered"; "-" for none.
    private typealias Case = (question: String, expected: String)

    private static func day(_ text: Substring) -> Date {
        let parts = text.split(separator: "-").map { Int($0)! }
        let (y, m, d) = parts.count == 3 ? (parts[0], parts[1], parts[2]) : (2026, parts[0], parts[1])
        return calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func check(_ language: String, _ cases: [Case], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(cases.count >= 15, "at least 15 phrases per language", sourceLocation: sourceLocation)
        for (question, expected) in cases {
            let scope = AskTimeScope.read(question, languages: [language], now: Self.now, calendar: Self.calendar)
            guard expected != "-" else {
                #expect(scope == nil, "\(question): \(String(describing: scope))", sourceLocation: sourceLocation)
                continue
            }
            let parts = expected.split(separator: " ")
            let bounds = parts[0].split(separator: ".", omittingEmptySubsequences: true)
            let want = DateInterval(start: Self.day(bounds[0]), end: Self.day(bounds[1]))
            #expect(scope?.interval == want, "\(question): \(String(describing: scope?.interval)) instead of \(want)", sourceLocation: sourceLocation)
            #expect(scope?.applies == (parts[1] == "applies"), "\(question): applies \(String(describing: scope?.applies))", sourceLocation: sourceLocation)
        }
    }

    @Test func english() {
        check("en", [
            ("What did we decide yesterday?", "10-28..10-29 applies"),
            ("What did Ana say the day before yesterday?", "10-27..10-28 applies"),
            ("What did we agree on last week?", "10-19..10-26 applies"),
            ("Summarize last week's meetings", "10-19..10-26 applies"),
            ("What were last week's numbers?", "10-19..10-26 offered"),
            ("What is due this week?", "-"),
            ("What did we discuss in today’s meeting?", "10-29..10-30 applies"),
            ("What do I have to do today?", "10-29..10-30 offered"),
            ("Who spoke two days ago?", "10-26..10-29 applies"),
            ("What was decided three weeks ago?", "10-05..10-12 applies"),
            ("What did we decide in the last two weeks?", "10-15..10-30 applies"),
            ("What did we decide last Monday?", "10-26..10-27 applies"),
            ("What happened in September?", "09-01..10-01 offered"),
            ("What did we decide in October?", "10-01..10-30 offered"),
            ("What's the plan for December?", "-"),
            ("What did we decide on October 3?", "10-03..10-04 applies"),
            ("What happened in Q3?", "07-01..10-01 offered"),
            ("What are the Q3 targets?", "-"),
            ("What changed since last month?", "09-01..10-30 applies"),
            ("What did we decide this morning?", "10-29..10-30 applies"),
            ("Who took over in the meeting on October 3rd, 2025?", "2025-10-03..2025-10-04 applies"),
            ("What do we know about the launch?", "-"),
        ])
    }

    @Test func spanish() {
        check("es", [
            ("¿Qué decidimos ayer?", "10-28..10-29 applies"),
            ("¿Qué se dijo anteayer?", "10-27..10-28 applies"),
            ("¿De qué se habló antes de ayer?", "10-27..10-28 applies"),
            ("¿Qué acordamos la semana pasada?", "10-19..10-26 applies"),
            ("Resume la reunión de la semana pasada", "10-19..10-26 applies"),
            ("¿Cuáles fueron las ventas del mes pasado?", "09-01..10-01 offered"),
            ("¿Qué hay que entregar para esta semana?", "-"),
            ("¿Qué tengo que hacer hoy?", "10-29..10-30 offered"),
            ("¿Qué se decidió en la reunión de hoy?", "10-29..10-30 applies"),
            ("¿Qué dijo Marta hace dos semanas?", "10-12..10-19 applies"),
            ("¿Qué hemos decidido en las últimas dos semanas?", "10-15..10-30 applies"),
            ("¿Qué se acordó el lunes pasado?", "10-26..10-27 applies"),
            ("¿Qué pasó en septiembre?", "09-01..10-01 offered"),
            ("¿Qué se decidió el 3 de octubre?", "10-03..10-04 applies"),
            ("¿Qué planes hay para diciembre?", "-"),
            ("¿Qué decidimos en el tercer trimestre?", "07-01..10-01 offered"),
            ("Hoy en día, ¿quién lleva el proyecto?", "-"),
            ("¿Qué ha cambiado desde el mes pasado?", "09-01..10-30 applies"),
            ("¿Qué se dijo hace quince días?", "10-13..10-16 applies"),
            ("¿Quién lleva el marco legal?", "-"),
        ])
    }

    @Test func french() {
        check("fr", [
            ("Qu'avons-nous décidé hier ?", "10-28..10-29 applies"),
            ("Qu’est-ce qui s’est dit avant-hier ?", "10-27..10-28 applies"),
            ("Qu'avons-nous décidé la semaine dernière ?", "10-19..10-26 applies"),
            ("Résume la réunion de la semaine dernière", "10-19..10-26 applies"),
            ("Quels étaient les chiffres du mois dernier ?", "09-01..10-01 offered"),
            ("Qu'est-ce que je dois faire aujourd'hui ?", "10-29..10-30 offered"),
            ("Qu'a-t-on dit lors de la réunion d'aujourd'hui ?", "10-29..10-30 applies"),
            ("Qu'a dit Paul il y a deux semaines ?", "10-12..10-19 applies"),
            ("Qu'avons-nous décidé ces trois derniers jours ?", "10-26..10-30 applies"),
            ("Qu'avons-nous convenu lundi dernier ?", "10-26..10-27 applies"),
            ("Que s'est-il passé en septembre ?", "09-01..10-01 offered"),
            ("Qu'avons-nous décidé le 3 octobre ?", "10-03..10-04 applies"),
            ("Quel est le plan pour décembre ?", "-"),
            ("Que faut-il finir pour cette semaine ?", "-"),
            ("Qu'est-ce qui a changé depuis le mois dernier ?", "09-01..10-30 applies"),
            ("Qu'avons-nous décidé au troisième trimestre ?", "07-01..10-01 offered"),
        ])
    }

    @Test func german() {
        check("de", [
            ("Was haben wir gestern beschlossen?", "10-28..10-29 applies"),
            ("Was wurde vorgestern gesagt?", "10-27..10-28 applies"),
            ("Was haben wir letzte Woche entschieden?", "10-19..10-26 applies"),
            ("Fasse die Besprechung der letzten Woche zusammen", "10-19..10-26 applies"),
            ("Wie waren die Zahlen des letzten Monats?", "09-01..10-01 offered"),
            ("Was muss ich heute erledigen?", "10-29..10-30 offered"),
            ("Was wurde im gestrigen Meeting besprochen?", "10-28..10-29 applies"),
            ("Wie waren die gestrigen Zahlen?", "10-28..10-29 offered"),
            ("Was sagte Anna vor zwei Wochen?", "10-12..10-19 applies"),
            ("Was haben wir in den letzten drei Tagen beschlossen?", "10-26..10-30 applies"),
            ("Was haben wir letzten Montag vereinbart?", "10-26..10-27 applies"),
            ("Was ist im September passiert?", "09-01..10-01 offered"),
            ("Was haben wir am 3. Oktober beschlossen?", "10-03..10-04 applies"),
            ("Was ist bis Dezember geplant?", "-"),
            ("Was ist für diese Woche zu tun?", "-"),
            ("Was hat sich seit letztem Monat geändert?", "09-01..10-30 applies"),
            ("Was haben wir im dritten Quartal entschieden?", "07-01..10-01 offered"),
            ("Was haben wir hier besprochen?", "-"),
        ])
    }

    @Test func italian() {
        check("it", [
            ("Cosa abbiamo deciso ieri?", "10-28..10-29 applies"),
            ("Cosa si è detto l'altro ieri?", "10-27..10-28 applies"),
            ("Cosa abbiamo deciso la settimana scorsa?", "10-19..10-26 applies"),
            ("Riassumi la riunione della settimana scorsa", "10-19..10-26 applies"),
            ("Quali erano i numeri del mese scorso?", "09-01..10-01 offered"),
            ("Cosa devo fare oggi?", "10-29..10-30 offered"),
            ("Cosa ha detto Luca due settimane fa?", "10-12..10-19 applies"),
            ("Cosa abbiamo deciso negli ultimi tre giorni?", "10-26..10-30 applies"),
            ("Cosa abbiamo concordato lunedì scorso?", "10-26..10-27 applies"),
            ("Cosa è successo a settembre?", "09-01..10-01 offered"),
            ("Cosa abbiamo deciso il 3 ottobre?", "10-03..10-04 applies"),
            ("Cosa c'è in programma per dicembre?", "-"),
            ("Cosa c'è da fare entro questa settimana?", "-"),
            ("Cosa è cambiato dal mese scorso?", "09-01..10-30 applies"),
            ("Cosa abbiamo deciso nel terzo trimestre?", "07-01..10-01 offered"),
            ("Cosa si è deciso nella riunione di oggi?", "10-29..10-30 applies"),
        ])
    }

    @Test func portuguese() {
        check("pt-BR", [
            ("O que decidimos ontem?", "10-28..10-29 applies"),
            ("O que foi dito anteontem?", "10-27..10-28 applies"),
            ("O que combinamos na semana passada?", "10-19..10-26 applies"),
            ("Resuma a reunião da semana passada", "10-19..10-26 applies"),
            ("Quais foram as vendas do mês passado?", "09-01..10-01 offered"),
            ("O que tenho que fazer hoje?", "10-29..10-30 offered"),
            ("O que a Ana disse há duas semanas?", "10-12..10-19 applies"),
            ("O que decidimos nos últimos três dias?", "10-26..10-30 applies"),
            ("O que combinamos na segunda-feira passada?", "10-26..10-27 applies"),
            ("O que aconteceu em setembro?", "09-01..10-01 offered"),
            ("O que decidimos em 3 de outubro?", "10-03..10-04 applies"),
            ("Qual é o plano para dezembro?", "-"),
            ("O que precisa ser feito até esta semana?", "-"),
            ("O que mudou desde o mês passado?", "09-01..10-30 applies"),
            ("O que decidimos no terceiro trimestre?", "07-01..10-01 offered"),
            ("Hoje em dia, quem cuida do projeto?", "-"),
        ])
    }

    @Test func japanese() {
        check("ja", [
            ("昨日何を決めましたか", "10-28..10-29 applies"),
            ("一昨日の会議で何が話されましたか", "10-27..10-28 applies"),
            ("先週何を決めましたか", "10-19..10-26 applies"),
            ("先週の売上はどうでしたか", "10-19..10-26 offered"),
            ("今日やることは何ですか", "10-29..10-30 offered"),
            ("今日の会議で何を決めましたか", "10-29..10-30 applies"),
            ("2週間前に何を決めましたか", "10-12..10-19 applies"),
            ("過去3日間で何を決めましたか", "10-26..10-30 applies"),
            ("先週の月曜日に何を決めましたか", "10-19..10-20 applies"),
            ("9月に何がありましたか", "09-01..10-01 offered"),
            ("10月3日に何を決めましたか", "10-03..10-04 applies"),
            ("12月の計画は何ですか", "-"),
            ("今週中にやることは", "-"),
            ("先月から何が変わりましたか", "09-01..10-30 applies"),
            ("第3四半期に何を決めましたか", "07-01..10-01 offered"),
            ("去年は何を決めましたか", "2025-01-01..2026-01-01 applies"),
        ])
    }

    @Test func korean() {
        check("ko", [
            ("어제 무엇을 결정했나요?", "10-28..10-29 applies"),
            ("그저께 회의에서 무슨 얘기를 했나요?", "10-27..10-28 applies"),
            ("지난주에 무엇을 결정했나요?", "10-19..10-26 applies"),
            ("지난주의 매출은 어땠나요?", "10-19..10-26 offered"),
            ("오늘 할 일이 뭐예요?", "10-29..10-30 offered"),
            ("오늘 회의에서 무엇을 결정했나요?", "10-29..10-30 applies"),
            ("2주 전에 무엇을 결정했나요?", "10-12..10-19 applies"),
            ("지난 3일 동안 무엇을 결정했나요?", "10-26..10-30 applies"),
            ("지난 월요일에 무엇을 결정했나요?", "10-26..10-27 applies"),
            ("지난주 월요일에 무엇을 결정했나요?", "10-19..10-20 applies"),
            ("9월에 무슨 일이 있었나요?", "09-01..10-01 offered"),
            ("10월 3일에 무엇을 결정했나요?", "10-03..10-04 applies"),
            ("12월 계획은 뭐예요?", "-"),
            ("이번 주까지 해야 할 일", "-"),
            ("지난달부터 무엇이 바뀌었나요?", "09-01..10-30 applies"),
            ("3분기에 무엇을 결정했나요?", "07-01..10-01 offered"),
        ])
    }

    @Test func chinese() {
        check("zh-Hans", [
            ("我们昨天决定了什么？", "10-28..10-29 applies"),
            ("前天的会议上说了什么？", "10-27..10-28 applies"),
            ("上周我们决定了什么？", "10-19..10-26 applies"),
            ("上周的销售额怎么样？", "10-19..10-26 offered"),
            ("今天要做什么？", "10-29..10-30 offered"),
            ("今天的会议决定了什么？", "10-29..10-30 applies"),
            ("两周前我们决定了什么？", "10-12..10-19 applies"),
            ("过去三天我们决定了什么？", "10-26..10-30 applies"),
            ("上周一我们决定了什么？", "10-19..10-20 applies"),
            ("在九月发生了什么？", "09-01..10-01 offered"),
            ("10月3日我们决定了什么？", "10-03..10-04 offered"),
            ("十二月的计划是什么？", "-"),
            ("本周之前要完成什么？", "-"),
            ("从上个月开始有什么变化？", "09-01..10-30 applies"),
            ("在第三季度我们决定了什么？", "07-01..10-01 offered"),
            ("上个月我们决定了什么？", "09-01..10-01 applies"),
        ])
    }

    /// A time that is what the question is about, or still to come, never narrows the meetings by itself.
    @Test func aTopicOrAPlanIsNotWhenTheMeetingsWere() {
        let offered = ["What was the revenue in 2025?", "What did we say about last year's budget?", "Who presents the results from last quarter?",
                       "What were the sales in September?", "¿Qué dijimos del presupuesto del año pasado?", "¿Cuáles fueron las ventas en septiembre?"]
        let none = ["When is the next meeting?", "Did we agree to meet again next week?", "What do we need before Friday?", "What is due on Monday?",
                    "¿Cuándo es la próxima reunión?", "¿Quedamos en vernos la semana que viene?", "¿Qué hay que tener antes del viernes?",
                    "¿Qué tareas vencen hasta mañana?", "Quels sont les objectifs du T3 ?"]
        for question in offered {
            let scope = AskTimeScope.read(question, languages: ["en", "es"], now: Self.now, calendar: Self.calendar)
            #expect(scope != nil && scope?.applies == false, "\(question): \(String(describing: scope))")
        }
        for question in none {
            #expect(AskTimeScope.read(question, languages: ["en", "es", "fr"], now: Self.now, calendar: Self.calendar) == nil, "\(question)")
        }
    }

    @Test func aQuestionIsReadInItsOwnLanguage() {
        // German "hier" is "here"; French "hier" is yesterday.
        #expect(AskTimeScope.read("Was haben wir hier besprochen?", languages: ["de"], now: Self.now, calendar: Self.calendar) == nil)
        #expect(AskTimeScope.read("Qu'avons-nous décidé hier ?", languages: ["fr"], now: Self.now, calendar: Self.calendar)?.applies == true)
        #expect(AskTimeScope.read("Qu'avons-nous décidé hier ?", languages: ["nl"], now: Self.now, calendar: Self.calendar) == nil)
        // Two languages at once: the person's own when the question's cannot be told.
        #expect(AskTimeScope.read("¿Y ayer?", languages: ["en-US", "es-ES"], now: Self.now, calendar: Self.calendar) != nil)
    }

    @Test func twoTimesMakeOneStretch() throws {
        let both = try #require(AskTimeScope.read("What did we decide this week and last week?", languages: ["en"], now: Self.now, calendar: Self.calendar))
        #expect(both.interval == DateInterval(start: Self.day("10-19"), end: Self.day("10-30")))
        #expect(!both.applies, "this week alone is only offered, so the two together are too")
        #expect(both.span == .range)
    }

    @Test func labelsNameTheInterval() throws {
        let en = Locale(identifier: "en_US")
        func label(_ question: String) throws -> String {
            try #require(AskTimeScope.read(question, languages: ["en"], now: Self.now, calendar: Self.calendar)).label(calendar: Self.calendar, locale: en)
        }
        #expect(try label("What did we decide yesterday?") == "Oct 28, 2026")
        #expect(try label("What happened in September?") == "September 2026")
        #expect(try label("What happened in Q3?") == "Q3 2026")
        #expect(try label("What did we decide in 2025?") == "2025")
        let week = try label("What did we agree on last week?")
        let days = week.replacingOccurrences(of: "2026", with: "")
        #expect(week.contains("Oct") && days.contains("19") && days.contains("25") && !days.contains("26"), "the last day shown is Sunday: \(week)")
    }

    @Test func futureAndImpossibleDatesNameNothing() {
        for question in ["What did we decide on November 5?", "What did we decide on February 30?", "What happened in Q4 2027?",
                         "What did we decide next week?"] {
            #expect(AskTimeScope.read(question, languages: ["en"], now: Self.now, calendar: Self.calendar) == nil, "\(question)")
        }
    }
}
