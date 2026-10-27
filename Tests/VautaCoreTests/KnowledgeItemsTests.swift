// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Decisions, tasks, cards, minutes from the model, live notes and search.
@Suite("Knowledge · items and minutes")
struct KnowledgeItemsTests {
    @Test func decisionsAndTasksBuildTheGraph() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let juan = try await s.saveEntity(EntityDraft(kind: .person, name: "Juan Martín"))
        let kob = try await s.saveEntity(EntityDraft(kind: .project, name: "Kobaltix"))
        let client = try await s.saveEntity(EntityDraft(kind: .client, name: "Telefónica"))
        try await s.addRelation(NodeRef(.entity, juan), .worksOn, NodeRef(.entity, kob))
        try await s.addRelation(NodeRef(.entity, kob), .forClient, NodeRef(.entity, client))
        let m = try await f.meeting(["Hoy revisamos Kobaltix", "Juan Martín prepara la migración"])
        let segs = try await s.segments(of: m)
        let decision = try await s.addDecision(m, text: "Kobaltix sale en noviembre", segmentID: segs[0].id, t: segs[0].start)
        let task = try await s.addTask(m, text: "Preparar la migración de datos", ownerID: juan, due: .now + 7 * 86_400,
                                       segmentID: segs[1].id, t: segs[1].start)
        let reached = Set(try await s.impact(NodeRef(.entity, kob), depth: 2).map(\.ref))
        #expect(reached.isSuperset(of: [NodeRef(.decision, decision), NodeRef(.entity, juan), NodeRef(.entity, client), NodeRef(.task, task)]))
        #expect(try await s.openTasks(owner: juan).map(\.id) == [task])
        #expect(try await s.openTasksPlan().contains("tasks_open"))
        #expect(try await s.searchKnowledge("migracion").contains { $0.kind == .task && $0.refID == task })
        try await s.setTaskStatus(task, .done)
        #expect(try await s.openTasks().isEmpty)
        try await s.updateDecision(decision, text: "Kobaltix sale en diciembre")
        #expect(try await s.searchKnowledge("noviembre").isEmpty)
        #expect(try await s.searchKnowledge("diciembre").count == 1)
        await #expect(throws: KnowledgeError.emptyTask) { try await s.addTask(m, text: "  \u{7} ") }

        try await s.deleteMeeting(m)
        #expect(try await s.decisions(m).isEmpty)
        #expect(try await s.tasks(m).isEmpty)
        #expect(try await s.searchKnowledge("diciembre").isEmpty)
        #expect(!(try await s.impact(NodeRef(.entity, kob), depth: 1).contains { $0.ref.kind == .decision }))
        #expect(!(try await s.imageContains("diciembre")))
    }

    @Test func scopedKnowledgeSearchFiltersInSQL() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let a = try await f.meeting(["uno"]), b = try await f.meeting(["dos"])
        for i in 0..<30 { try await s.addDecision(a, text: "Presupuesto revisado \(i)") }
        try await s.addDecision(b, text: "Presupuesto aprobado")
        let scoped = try await s.searchKnowledge("presupuesto", in: [b], limit: 5)
        #expect(scoped.count == 1 && scoped[0].meetingID == b)
        #expect(scoped[0].snippet.contains(KnowledgeHit.highlightStart))
        #expect(SearchHighlight.runs(in: scoped[0].snippet).filter(\.isMatch).map(\.text) == ["Presupuesto"],
                "knowledge snippets use the same markers as transcript search")
        #expect(try await s.searchKnowledge("presupuesto", in: [], limit: 5).isEmpty)
        #expect(try await s.searchKnowledge("presupuesto", limit: 5).count == 5)
    }

    private func minutes(_ segs: [MeetingStore.StoredSegment], decisions: [String], tasks: [(String, Int)],
                      openQuestions: [String] = []) -> ValidatedMinutes {
        var minutes = ValidatedMinutes()
        minutes.title = "Plan"
        minutes.summary = "Resumen del modelo"
        minutes.topics = ["plan"]
        minutes.decisions = decisions.map { .init(text: $0, segment: segs[0].id, t: segs[0].start) }
        minutes.tasks = tasks.map { .init(text: $0.0, owner: nil, due: nil, segment: segs[$0.1].id, t: segs[$0.1].start) }
        minutes.openQuestions = openQuestions
        return minutes
    }

    @Test func regeneratingMinutesKeepsUserEdits() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let m = try await f.meeting(["Decidimos lanzar en junio", "Ana prepara la demo", "Luis revisa el contrato"])
        let segs = try await s.segments(of: m)
        try await s.applyMinutes(minutes(segs, decisions: ["Lanzar en junio"], tasks: [("Preparar la demo", 1), ("Revisar el contrato", 2)]), to: m)
        let decision = try #require(try await s.decisions(m).first)
        var tasks = try await s.tasks(m)
        #expect(decision.source == "llm" && tasks.allSatisfy { $0.source == "llm" })

        // The user edits one decision and one task, and closes the other task.
        try await s.updateDecision(decision.id, text: "Lanzar el 15 de junio")
        var demo = try #require(tasks.first { $0.text == "Preparar la demo" })
        demo.text = "Preparar la demo para el cliente"
        try await s.updateTask(demo)
        let contract = try #require(tasks.first { $0.text == "Revisar el contrato" })
        try await s.setTaskStatus(contract.id, .done)
        tasks = try await s.tasks(m)
        #expect(try await s.decisions(m).first?.source == "user")
        #expect(tasks.first { $0.id == demo.id }?.source == "user")
        #expect(tasks.first { $0.id == contract.id }?.source == "llm")

        // Regenerate: the model proposes the same items, worded as before.
        try await s.applyMinutes(minutes(segs, decisions: ["Lanzar en junio"], tasks: [("Preparar la demo", 1), ("Revisar el contrato", 2)]), to: m)
        let decisions = try await s.decisions(m)
        tasks = try await s.tasks(m)
        #expect(decisions.map(\.text) == ["Lanzar el 15 de junio"] && decisions[0].source == "user")
        #expect(tasks.count == 2, "no duplicates of the edited or the closed task")
        #expect(tasks.contains { $0.id == demo.id && $0.text == "Preparar la demo para el cliente" })
        #expect(tasks.contains { $0.id == contract.id && $0.status == .done })
    }

    @Test func statusChangesAloneKeepTheModelSource() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let m = try await f.meeting(["Ana prepara la demo"])
        let segs = try await s.segments(of: m)
        try await s.applyMinutes(minutes(segs, decisions: [], tasks: [("Preparar la demo", 0)]), to: m)
        var task = try #require(try await s.tasks(m).first)
        task.status = .dropped
        try await s.updateTask(task)
        #expect(try await s.tasks(m).first?.source == "llm")
    }

    @Test func openQuestionsArePersistedInTheCard() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let m = try await f.meeting(["¿Quién paga la licencia?"])
        let segs = try await s.segments(of: m)
        try await s.applyMinutes(minutes(segs, decisions: [], tasks: [], openQuestions: ["Quién paga la licencia"]), to: m)
        #expect(try await s.card(m)?.openQuestions == ["Quién paga la licencia"])
        #expect(try await s.card(m)?.summary == "Resumen del modelo")

        // The user's card: summary kept on regeneration, open questions refreshed.
        try await s.saveCard(MeetingCard(summary: "Mi resumen", topics: ["licencias"]), of: m)
        #expect(try await s.card(m)?.openQuestions == ["Quién paga la licencia"], "nil open questions keep the stored ones")
        try await s.applyMinutes(minutes(segs, decisions: [], tasks: [], openQuestions: ["Fecha de renovación"]), to: m)
        let card = try await s.card(m)
        #expect(card?.summary == "Mi resumen" && card?.openQuestions == ["Fecha de renovación"])
        #expect(try await s.cardSource(m) == "user")
        #expect(try await s.searchKnowledge("resumen").contains { $0.kind == .summary && $0.meetingID == m })
    }

    @Test func cardJSONKeepsTheFrozenKeys() throws {
        let legacy = #"{"resumen":"Se acordó el calendario","temas":["despliegue","pagos"]}"#
        let card = try JSONDecoder().decode(MeetingCard.self, from: Data(legacy.utf8))
        #expect(card == MeetingCard(summary: "Se acordó el calendario", topics: ["despliegue", "pagos"]))
        let json = try card.json()
        #expect(json.contains("\"resumen\"") && json.contains("\"temas\"") && !json.contains("open_questions"))
        let withQuestions = try MeetingCard(summary: "x", openQuestions: ["y"]).json()
        #expect(withQuestions.contains("\"open_questions\":[\"y\"]"))
        #expect(try JSONDecoder().decode(MeetingCard.self, from: Data("{}".utf8)) == MeetingCard())
    }

    @Test func liveNotesAreReadBackFromTheLegacyFormat() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let m = try await f.meeting(["hola"])
        let legacy = #"{"puntos":[{"texto":"Plan de junio","seg":1}],"decisiones":[],"tareas":[{"texto":"Llamar a Ana","responsable":"Yo","seg":1}]}"#
        try await s.addLiveNotes(m, at: 30, json: legacy)
        try await s.addLiveNotes(m, at: 60, json: #"{"puntos":[{"texto":"Cierre","seg":null}]}"#)
        let notes = try await s.liveNotes(m)
        #expect(notes.count == 2)
        #expect(notes[0].t == 30 && notes[0].points == [.init(text: "Plan de junio", segment: 1)])
        #expect(notes[0].tasks == [.init(text: "Llamar a Ana", owner: "Yo", segment: 1)])
        #expect(notes[1].decisions.isEmpty && notes[1].points.first?.segment == nil)
        // What the app writes today (the prompt's JSON) decodes the same way.
        let written = try JSONEncoder().encode(LiveNotesBatch(points: [.init(text: "a", segment: 2)]))
        #expect(try JSONDecoder().decode(LiveNotesBatch.self, from: written).points == [.init(text: "a", segment: 2)])
    }

    @Test func retrievalWorksWithoutAServer() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let kob = try await s.saveEntity(EntityDraft(kind: .project, name: "Kobaltix"))
        let m = try await f.meeting(["Hablamos del presupuesto de Kobaltix para el año que viene",
                                     "La API v2 sale en el Q3", "Hay que renovar el contrato del proveedor de nube"])
        let plan = try await s.chunkPlan(m)
        #expect(!plan.isEmpty && plan.allSatisfy { $0.end > $0.start })
        let passages = try await s.retrieve("¿Qué pasa con el presupuesto de Kobaltix?", queryVector: nil)
        #expect(passages.first?.meeting.id == m)
        #expect(passages.first?.segments.contains { $0.text.contains("presupuesto") } == true)
        #expect(try await s.entitiesNamed(in: "¿Y lo de kobaltix?") == [kob])
        let short = try await s.retrieve("When does the API ship, Q3?", queryVector: nil, locale: Locale(identifier: "en-US"))
        #expect(short.first?.segments.contains { $0.text.contains("Q3") } == true)
    }

    @Test func chineseQuestionsFindChineseTranscripts() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let m = try await f.meeting(["我们今天讨论了预算", "下周再开会"])
        let passages = try await s.retrieve("预算是多少?", queryVector: nil)
        #expect(passages.first?.meeting.id == m)
    }

    @Test func koreanQuestionsFindKoreanTranscripts() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let m = try await f.meeting(["베타에 대한 출시 일정을 논의했습니다", "다음 주에 다시 회의합니다"])
        let ko = Locale(identifier: "ko-KR")
        #expect(try await s.retrieve("베타는 언제 출시되나요?", queryVector: nil, locale: ko).first?.meeting.id == m)
        #expect(MeetingStore.queryTerms("베타는 회의에서", profile: LanguageProfile(identifier: "ko")) == ["베타", "회의"])
    }

    /// Every query that returns meetings loads their language and source app.
    @Test func knowledgeQueriesLoadTheMeetingLanguage() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let kob = try await s.saveEntity(EntityDraft(kind: .project, name: "Kobaltix"))
        let id = try await s.startMeeting(at: .now, locale: Locale(identifier: "en-US"), outputLocale: Locale(identifier: "fr-FR"),
                                          sourceApp: "zoom")
        try await s.append(segment(.others, 0, "The Kobaltix budget is due on Friday"), to: id)
        try await s.endMeeting(id, at: .now + 60)
        let loaded: @Sendable (MeetingStore.Meeting?) -> Bool = {
            $0?.id == id && $0?.locale == "en-US" && $0?.outputLocale == "fr-FR" && $0?.sourceApp == "zoom"
        }
        #expect(loaded(try await s.refs(kob).first?.meeting))
        #expect(loaded(try await s.timeline(kob).first?.meeting))
        #expect(loaded(try await s.retrieve("Kobaltix budget", queryVector: nil, locale: Locale(identifier: "en-US")).first?.meeting))
        #expect(loaded(try await s.search("budget").first?.meeting))
        #expect(loaded(try await s.meeting(id)))
    }
}
