// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The template a meeting's title suggests, in the nine languages, and the titles that must suggest nothing.
@Suite("Minutes templates · what the title suggests")
struct MinutesTemplateTitleTests {
    @Test(arguments: [
        ("1:1 with Ana", MinutesTemplate.oneOnOne), ("Ana / Luis 1-1", .oneOnOne), ("1on1 Kenji", .oneOnOne), ("Weekly one-on-one", .oneOnOne),
        ("Skip-level with Marta", .oneOnOne), ("Reunión uno a uno", .oneOnOne), ("Point individuel avec Claire", .oneOnOne),
        ("Entretien annuel 2026", .oneOnOne), ("Einzelgespräch mit Jonas", .oneOnOne), ("Colloquio individuale", .oneOnOne),
        ("Reunião individual com Ana", .oneOnOne), ("田中さんと1on1", .oneOnOne), ("個人面談", .oneOnOne), ("민수와 일대일", .oneOnOne),
        ("和王伟一对一", .oneOnOne), ("1 a 1 con Ana", .oneOnOne), ("1対1", .oneOnOne),

        ("Daily stand-up", .standup), ("Team standup", .standup), ("Daily", .standup), ("Daily scrum", .standup),
        ("Reunión diaria del equipo", .standup), ("Point quotidien", .standup), ("Tägliches Meeting", .standup),
        ("Riunione quotidiana", .standup), ("Reunião diária", .standup), ("開発チーム朝会", .standup), ("데일리 스탠드업", .standup),
        ("产品站会", .standup),

        ("Interview: backend engineer", .interview), ("Phone screen with Jane", .interview), ("Entrevista con candidata", .interview),
        ("Entretien d’embauche", .interview), ("Vorstellungsgespräch Frau Weber", .interview), ("Colloquio di lavoro", .interview),
        ("Entrevista de emprego", .interview), ("一次面接", .interview), ("개발자 면접", .interview), ("产品经理面试", .interview),

        ("Lecture 4: entropy", .lecture), ("Webinar: new pricing", .lecture), ("Tech talk on Swift 6", .lecture), ("Clase de historia", .lecture),
        ("Séminaire produit", .lecture), ("Vorlesung Statistik", .lecture), ("Lezione di fisica", .lecture), ("Aula de matemática", .lecture),
        ("新人研修", .lecture), ("데이터 강의", .lecture), ("机器学习讲座", .lecture),

        ("Client call — Acme", .clientCall), ("Customer kickoff", .clientCall), ("Llamada con el cliente", .clientCall),
        ("Rendez-vous client Dupont", .clientCall), ("Kundentermin Müller", .clientCall), ("Incontro con i clienti", .clientCall),
        ("顧客との商談", .clientCall), ("고객사 미팅", .clientCall), ("客户会议", .clientCall),
    ])
    func aTitleSuggestsItsTemplate(_ title: String, _ template: MinutesTemplate) {
        #expect(MinutesTemplate.suggested(forTitle: title) == template, "\(title)")
    }

    @Test(arguments: [
        "Weekly sync", "Conference call with the team", "Projets en cours", "Progetti in corso", "Proyectos en curso", "Charla con Ana",
        "Sales team weekly", "Sprint demo", "Scrum retro", "Lessons learned", "Talk with Ana about the roadmap", "11:15 sync", "Sprint 21-1",
        "Q1 planning", "Budget 1/1", "Budget 2026", "Équipe", "", "   ", "週次定例", "주간 회의", "周会",
    ])
    func aTitleWithoutAKindSuggestsNothing(_ title: String) {
        #expect(MinutesTemplate.suggested(forTitle: title) == nil, "\(title)")
    }

    @Test func theMostSpecificKindWins() {
        #expect(MinutesTemplate.suggested(forTitle: "1:1 with a candidate") == .interview)
        #expect(MinutesTemplate.suggested(forTitle: "Daily client standup") == .standup)
        #expect(MinutesTemplate.suggested(forTitle: "Customer webinar") == .lecture)
    }
}
