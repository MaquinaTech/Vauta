// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// English model output, legacy Spanish output, owners and word boundaries.
/// The Spanish fixture in `ModelsMinutesValidationTests` covers the legacy keys in depth.
@Suite("Prompts: validation of model output")
struct PromptValidationTests {
    let segments: [Int64: CitableSegment] = [
        10: CitableSegment(id: 10, channel: .others, start: 60, text: "Ana, can you take care of the Kobaltix migration before Friday?"),
        11: CitableSegment(id: 11, channel: .me, start: 75, text: "Sure, and we decided to postpone the launch to December"),
        12: CitableSegment(id: 12, channel: .others, start: 90, text: "Lo vemos mañana con calma"),
    ]
    let candidates = [CandidateEntity(id: 1, kind: .person, name: "Yo", aliases: []),
                      CandidateEntity(id: 5, kind: .person, name: "Ana Ruiz", aliases: ["Ana"]),
                      CandidateEntity(id: 7, kind: .project, name: "Kobaltix", aliases: [])]

    @Test func englishMinutesParse() throws {
        let json = """
            {"title": "Kobaltix plan", "summary": "Migration and launch.", "topics": ["migration", "launch"],
             "decisions": [{"text": "The launch is postponed to December", "seg": 11, "quote": "postpone the launch to December"}],
             "tasks": [{"text": "Migrate Kobaltix", "owner": "Ana", "owner_id": null, "due": "2026-10-09", "seg": 10, "quote": "take care of the Kobaltix migration"},
                       {"text": "Tell the client", "owner": "Me", "owner_id": null, "due": null, "seg": 11, "quote": "we decided to postpone"}],
             "entities": [{"mention": "Kobaltix", "id": 7, "seg": 10}],
             "open_questions": ["Who signs the contract?"]}
            """
        let minutes = try VautaPrompts.validateMinutes(json, segments: segments, candidates: candidates, selfEntity: 1,
                                                   reference: Date(timeIntervalSince1970: 1_791_354_600))
        #expect(minutes.title == "Kobaltix plan" && minutes.topics == ["migration", "launch"])
        #expect(minutes.decisions.map(\.segment) == [11])
        #expect(minutes.tasks.map(\.owner) == [5, 1] && minutes.tasks[0].due != nil)
        #expect(minutes.mentions.map(\.entity) == [7])
        #expect(minutes.openQuestions == ["Who signs the contract?"] && minutes.dropped == 0)
    }

    @Test func legacySpanishMinutesStillParse() throws {
        let json = """
            {"titulo": "Plan", "resumen": "Se habló.", "temas": ["plan"],
             "decisiones": [{"texto": "Posponer el lanzamiento", "seg": 11, "cita": "postpone the launch to December"}],
             "tareas": [{"texto": "Migrar", "responsable": "Yo", "responsable_id": null, "fecha": null, "seg": 11, "cita": "we decided to postpone the launch"}],
             "entidades": [], "abiertas": ["¿Quién firma?"]}
            """
        let minutes = try VautaPrompts.validateMinutes(json, segments: segments, candidates: candidates, selfEntity: 1)
        #expect(minutes.title == "Plan" && minutes.summary == "Se habló." && minutes.topics == ["plan"])
        #expect(minutes.decisions.count == 1 && minutes.tasks.first?.owner == 1 && minutes.openQuestions == ["¿Quién firma?"])
    }

    @Test(arguments: ["Me", "me", "I", "Yo", "the user", "Maya", "Me (the user)", "Maya (the user)"])
    func theUserIsRecognizedAsOwner(owner: String) {
        let people = [CandidateEntity(id: 1, kind: .person, name: "Maya", aliases: []),
                      CandidateEntity(id: 5, kind: .person, name: "Ana Ruiz", aliases: ["Ana"])]
        #expect(VautaPrompts.resolvePerson(owner, people: people, selfEntity: 1, selfNames: [TextKeys.norm("Maya")]) == 1)
        #expect(VautaPrompts.resolvePerson("Ana", people: people, selfEntity: 1) == 5)
        #expect(VautaPrompts.resolvePerson("null", people: people, selfEntity: 1) == nil)
    }

    @Test func wordBoundariesKeepAnaOutOfManana() throws {
        #expect(!PromptText.containsWords("Lo vemos mañana con calma", "Ana"))
        #expect(PromptText.containsWords("Ana, can you take care of it?", "ana"))
        #expect(PromptText.containsWords("Hablé con José Luis ayer", "jose luis"))
        #expect(PromptText.containsWords("请王伟明天发报告", "王伟"))   // no spaces in Chinese: substring
        let json = """
            {"tasks": [{"text": "Review it", "owner": null, "owner_id": 5, "seg": 12, "quote": "lo vemos mañana con calma"}],
             "entities": [{"mention": "Ana", "id": 5, "seg": 12}]}
            """
        let minutes = try VautaPrompts.validateMinutes(json, segments: segments, candidates: candidates, selfEntity: 1)
        // "Ana" is not in "mañana": no mention, and the task is not assigned to her.
        #expect(minutes.mentions.isEmpty && minutes.tasks.first?.owner == nil)
    }

    @Test func theUsersPronounIsNeverAMention() throws {
        let segs: [Int64: CitableSegment] = [3: CitableSegment(id: 3, channel: .me, start: 0, text: "Yo me encargo del informe")]
        let json = #"{"entities": [{"mention": "Yo", "id": 1, "seg": 3}]}"#
        let minutes = try VautaPrompts.validateMinutes(json, segments: segs, candidates: candidates, selfEntity: 1)
        #expect(minutes.mentions.isEmpty && minutes.dropped == 1)
    }

    @Test func idsWrittenAsStringsAreAccepted() throws {
        let json = #"{"decisions": [{"text": "The launch is postponed", "seg": "S11", "quote": "postpone the launch"}], "tasks": "none"}"#
        let minutes = try VautaPrompts.validateMinutes(json, segments: segments, candidates: candidates, selfEntity: 1)
        #expect(minutes.decisions.map(\.segment) == [11] && minutes.tasks.isEmpty)
    }

    @Test func answersInEnglishAndSpanishHaveUniqueClaimIDs() throws {
        let english = try VautaPrompts.verifyAnswer("""
            {"answer": "December.", "claims": [{"text": "Launch in December", "citations": [11], "quote": "postpone the launch to December"},
                                              {"text": "Launch in December", "citations": ["11"], "quote": "not in the transcript at all"}]}
            """, sent: segments)
        #expect(english.answer == "December." && english.claims.map(\.verified) == [true, false])
        #expect(Set(english.claims.map(\.id)).count == 2)
        let spanish = try VautaPrompts.verifyAnswer("""
            {"respuesta": "En diciembre.", "afirmaciones": [{"texto": "Diciembre", "citas": [11], "cita_literal": "postpone the launch to December"}]}
            """, sent: segments)
        #expect(spanish.answer == "En diciembre." && spanish.hasEvidence)
    }

    @Test func liveNotesInEnglishAndSpanish() throws {
        let english = try VautaPrompts.validateLive("""
            {"points": [{"text": "Migration", "seg": 10}, {"text": "Ghost", "seg": 99}], "decisions": [],
             "tasks": [{"text": "Call Ana", "owner": "Me", "seg": 11}, {"text": "Nobody", "owner": "null", "seg": 10}]}
            """, segments: Set(segments.keys))
        #expect(english.points == [.init(text: "Migration", segment: 10)])
        #expect(english.tasks == [.init(text: "Call Ana", owner: "Me", segment: 11), .init(text: "Nobody", owner: nil, segment: 10)])
        let spanish = try VautaPrompts.validateLive(#"{"puntos":[{"texto":"Migración","seg":10}],"decisiones":[],"tareas":[]}"#,
                                                   segments: Set(segments.keys))
        #expect(spanish.points.map(\.text) == ["Migración"])
        // Stored with the frozen keys.
        let stored = String(decoding: try JSONEncoder().encode(english), as: UTF8.self)
        #expect(stored.contains(#""puntos""#) && stored.contains(#""responsable""#) && !stored.contains(#""points""#))
        #expect(VautaPrompts.liveNoteLines(english) == ["Migration", "Task: Call Ana (owner: Me)", "Task: Nobody"])
    }
}
