// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// What the minutes checks do with the model's lists, and the reasons they log for the items they drop.
@Suite("Minutes: junk strings, topics, drop reasons")
struct MinutesChecksTests {
    static let segments: [Int64: CitableSegment] = [
        1: CitableSegment(id: 1, channel: .others, start: 5, text: "We decided to keep the budget for this quarter"),
        2: CitableSegment(id: 2, channel: .others, start: 30, text: "Ana will send the numbers on Friday the twelfth"),
        3: CitableSegment(id: 3, channel: .me, start: 60, text: "Let us talk about Kobaltix again next time"),
    ]
    static let reference = Date(timeIntervalSince1970: 1_104_537_600)   // 2005-01-01

    static func validate(_ json: String) throws -> ValidatedMinutes {
        try VautaPrompts.validateMinutes(json, segments: segments, candidates: [CandidateEntity(id: 5, kind: .project, name: "Kobaltix", aliases: [])],
                                         selfEntity: nil, reference: reference, timeZone: TimeZone(identifier: "UTC")!)
    }

    // MARK: Junk

    @Test func openQuestionsThatAreLeftoversOfTheJSONOrTheModelTalkingAreRejected() throws {
        let junk = [
            "]}],", "}]}</body></html>", "```json", "]]}*/\n```json\n{", "decisions: [{text:", "\"tasks\": [", "I will now generate the final JSON",
            "I will correct it", "The JSON output below is valid and final", "**I will proceed with the structure now.**", "}", "or", "…", "<br></div>",
        ]
        let good = ["Who signs the contract?", "¿Cuándo se vota el presupuesto?", "Should the export be JSON or CSV?", "What happens to the Q3 numbers?",
                    "Will the Thai team attend, or will Ana?", "[S6] What shape should the remote have?"]
        let reply = try JSONSerialization.data(withJSONObject: ["title": "T", "summary": "S", "topics": [], "decisions": [], "tasks": [], "entities": [],
                                                                "open_questions": junk + good])
        let minutes = try Self.validate(String(decoding: reply, as: UTF8.self))
        #expect(minutes.openQuestions == Array(good.dropLast()) + ["What shape should the remote have?"], "a stray segment tag is taken off, the question stays: \(minutes.openQuestions)")
        #expect(minutes.drops["open_question.junk"] == junk.count)
        #expect(minutes.dropped == 0, "junk is not a dropped item")
    }

    @Test func shortRealQuestionsStayInEveryLanguage() throws {
        let questions = ["Budget?", "誰が署名する？", "予算は？", "谁来签字？", "누가 서명하나요?", "¿Quién firma?", "Who owns the rollout?", "Open tasks: who owns the rollout?",
                         "Summary: do we ship Friday?", "Topics: which ones are left?"]
        let reply = try JSONSerialization.data(withJSONObject: ["title": "T", "summary": "S", "topics": [], "decisions": [], "tasks": [], "entities": [], "open_questions": questions])
        let minutes = try Self.validate(String(decoding: reply, as: UTF8.self))
        #expect(minutes.openQuestions == questions, "\(minutes.openQuestions)")
        #expect(minutes.drops["open_question.junk"] == nil)
    }

    @Test func aKeyThatOpensAListIsStillJunkAndSoIsMetaTextInOtherLanguages() {
        for junk in ["decisions: [", "tasks: {\"text\"", "\"open_questions\": ", "\"summary\":", "Voy a generar el JSON final", "Je vais écrire le JSON", "Ich werde das JSON erzeugen",
                     "Aquí está el JSON válido", "questions or issues left unresolved", "3 to 6 topics of a few words each", "Up to 5 questions or issues left unresolved, one sentence each"] {
            #expect(MinutesText.isJunk(junk), "\(junk)")
        }
        for fine in ["Voy a necesitar acceso, ¿quién lo da?", "Should the JSON export stay?", "Open tasks: who owns the rollout?", "Summary: do we ship Friday?"] {
            #expect(!MinutesText.isJunk(fine), "\(fine)")
        }
    }

    @Test func theMinutesShapesShowNoSampleTextOrNumbers() {
        for shape in [VautaPrompts.minutesJSON, VautaPrompts.extractJSON, VautaPrompts.digestJSON] {
            for sample in ["questions or issues", "short topics", "short, specific", "what was decided", "what has to be done", "sentences", "123", "45", "Me | name", "YYYY-MM-DD"] {
                #expect(!shape.contains(sample), "\(sample) in \(shape)")
            }
            #expect((try? JSONSerialization.jsonObject(with: Data(shape.utf8))) is [String: Any], "the shape is valid JSON")
        }
        // What each field holds is said in words next to the shape.
        #expect(VautaPrompts.minutesRules.contains("\"open_questions\" are questions or issues left unresolved") && VautaPrompts.digestRules.contains("\"open_questions\""))
        #expect(VautaPrompts.blockInstruction(OutputLanguage(Locale(identifier: "en-US"))).content.contains("\"topics\" are up to 4 short topics"))
        // A reply that copies the old sample text is not content; the shapes' zeros cite nothing.
        let copied = #"{"title": "", "summary": "", "topics": ["3 to 8 short topics", ""], "decisions": [{"text": "", "seg": 0, "quote": ""}], "tasks": [], "entities": [{"mention": "", "id": 0, "seg": 0}], "open_questions": ["questions or issues left unresolved", ""]}"#
        let minutes = try? Self.validate(copied)
        #expect(minutes?.topics.isEmpty == true && minutes?.openQuestions.isEmpty == true && minutes?.decisions.isEmpty == true && minutes?.mentions.isEmpty == true)
    }

    @Test func topicsLoseTheirListMarkersAndJunk() throws {
        let topics = ["]", "- ", "- Detailed design review", "-\n-\n- Evaluation of the design", "* Costs", "• Team", "1. Next steps", "2) Risks", "– Budget",
                      "Plain topic", "plain topic"]
        let reply = try JSONSerialization.data(withJSONObject: ["title": "T", "summary": "S", "topics": topics, "decisions": [], "tasks": [], "entities": [], "open_questions": []])
        let minutes = try Self.validate(String(decoding: reply, as: UTF8.self))
        #expect(minutes.topics == ["Detailed design review", "Evaluation of the design", "Costs", "Team", "Next steps", "Risks", "Budget", "Plain topic"])
        #expect(minutes.drops["topic.junk"] == 2, "the bracket and the bare dash; the repeat of 'Plain topic' is dropped without being junk")
    }

    // MARK: Drop reasons

    @Test func everyDroppedItemHasAReasonAndTheyAddUp() throws {
        let json = """
            {"title": "T", "summary": "S", "topics": [], "open_questions": [],
             "decisions": [
               {"text": "Keep the budget", "seg": 1, "quote": "keep the budget for this quarter"},
               {"text": "", "seg": 1, "quote": "keep the budget for this quarter"},
               {"text": "Nowhere", "seg": 99, "quote": "keep the budget for this quarter"},
               {"text": "No segment", "quote": "keep the budget for this quarter"},
               {"text": "Short quote", "seg": 1, "quote": "keep"},
               {"text": "Invented", "seg": 1, "quote": "we triple the budget next year"},
               {"text": "Wrong number was cited", "seg": 3, "quote": "keep the budget for this quarter"},
               {"text": "Keep the budget", "seg": 1, "quote": "keep the budget for this quarter"}],
             "tasks": [{"text": "Send numbers", "owner": null, "owner_id": null, "due": null, "seg": 2, "quote": "send the numbers on Friday"},
                       {"text": "Send numbers 2", "owner": null, "owner_id": null, "due": null, "seg": 2, "quote": "not said at all in here"}],
             "entities": [{"mention": "Kobaltix", "id": 5, "seg": 3}, {"mention": "Kobaltix", "id": 6, "seg": 3}, {"mention": "Kobaltix", "id": 5, "seg": 1},
                          {"mention": "Other", "id": 5, "seg": 3}, {"mention": "talk", "id": 5, "seg": 3}, {"mention": "", "id": 5, "seg": 3}, {"mention": "Kobaltix", "id": 5, "seg": 77}, {"mention": "Kobaltix", "seg": 3}]}
            """
        let m = try Self.validate(json)
        #expect(m.decisions.count == 2 && m.tasks.count == 1 && m.mentions.count == 1, "the wrong segment number is moved to the right segment (11b)")
        #expect(m.counts == ["decision.reanchored": 1])
        #expect(m.drops == [
            "decision.emptyText": 1, "decision.unknownSegment": 1, "decision.noSegment": 1, "decision.quoteTooShort": 1, "decision.quoteNotFound": 1,
            "decision.duplicate": 1, "task.quoteNotFound": 1,
            "entity.unknownEntity": 1, "entity.mentionNotInSegment": 2, "entity.mentionNotAlias": 1, "entity.emptyText": 1, "entity.unknownSegment": 1, "entity.noID": 1,
        ], "\(m.drops.sorted { $0.key < $1.key })")
        #expect(m.dropped == m.drops.values.reduce(0, +) && m.proposed == 8 + 2 + 8)
        let d = MinutesDiagnostics(m)
        #expect(d.kept == 4 && d.dropped == m.dropped && d.line.contains("decision.reanchored 1"))
        #expect(!d.line.contains("Kobaltix") && !d.line.contains("budget"), "counts and reasons only: no transcript text in the log line")
    }

    @Test func dueDatesAreCountedByKind() throws {
        var items: [String] = []
        for (i, due) in ["2005-01-01", "2005-01-02", "2005-01-12", "sometime", "null"].enumerated() {
            items.append(#"{"text": "Send numbers \#(i)", "owner": null, "owner_id": null, "due": "\#(due)", "seg": 2, "quote": "send the numbers on Friday"}"#)
        }
        let json = #"{"title": "T", "summary": "S", "topics": [], "decisions": [], "entities": [], "open_questions": [], "tasks": [\#(items.joined(separator: ","))]}"#
        let m = try Self.validate(json)
        #expect(m.tasks.count == 5)
        #expect(m.dueGiven == 4, "'null' is no date")
        #expect(m.dueUnreadable == 1, "'sometime'")
        #expect(m.dueRuleViolations == 2, "the meeting's day and the day after: removed, and counted")
        #expect(m.tasks.filter { $0.due == nil }.count == 4 && m.tasks.filter { $0.due != nil }.count == 1)
    }

    @Test func emptyStringsFromTheShapeAreSkippedWithoutBeingCountedAsJunk() throws {
        let reply = try JSONSerialization.data(withJSONObject: ["title": "T", "summary": "S", "topics": ["", "  "], "decisions": [], "tasks": [], "entities": [],
                                                                "open_questions": ["", "Who signs?", "\n"]])
        let minutes = try Self.validate(String(decoding: reply, as: UTF8.self))
        #expect(minutes.openQuestions == ["Who signs?"] && minutes.topics.isEmpty)
        #expect(minutes.drops["open_question.junk"] == nil && minutes.drops["topic.junk"] == nil)
    }
}
