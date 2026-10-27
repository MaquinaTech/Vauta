// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The JSON export schema (`vauta.meeting` v1), the store loader and copied answers.
@Suite("Export · JSON, store and answers")
struct ExportJSONTests {
    @Test func jsonGolden() throws {
        let e = MeetingExport(
            title: "会議 \"Q3\"", startedAt: ExportRendererTests.date(2026, 10, 6, 8),
            endedAt: ExportRendererTests.date(2026, 10, 6, 8).addingTimeInterval(90), language: "ja-JP",
            attendees: ["مريم"], summary: "要約", topics: ["予算"], openQuestions: ["¿Quién?"],
            decisions: [.init(text: "決定", time: nil)],
            tasks: [.init(text: "タスク", owner: nil, due: ExportRendererTests.date(2026, 10, 10, 12), status: .done, time: 1.23456)],
            notes: [.init(text: "note/1", time: 7)],
            transcript: [.init(start: 3600.5, end: 3602, channel: .me, text: "テスト")])
        let json = try MeetingExportJSON.encode(e, options: ExportRendererTests.options)
        let expected = """
            {
              "attendees" : [
                "مريم"
              ],
              "decisions" : [
                {
                  "text" : "決定",
                  "time" : null
                }
              ],
              "durationSeconds" : 90,
              "endedAt" : "2026-10-06T08:01:30Z",
              "format" : "vauta.meeting",
              "language" : "ja-JP",
              "notes" : [
                {
                  "expansion" : null,
                  "text" : "note/1",
                  "time" : 7
                }
              ],
              "openQuestions" : [
                "¿Quién?"
              ],
              "participantsInformedAt" : null,
              "startedAt" : "2026-10-06T08:00:00Z",
              "summary" : "要約",
              "tasks" : [
                {
                  "due" : "2026-10-10",
                  "owner" : null,
                  "status" : "done",
                  "text" : "タスク",
                  "time" : 1.235
                }
              ],
              "title" : "会議 \\"Q3\\"",
              "topics" : [
                "予算"
              ],
              "transcript" : [
                {
                  "channel" : "me",
                  "end" : 3602,
                  "name" : null,
                  "speaker" : "Me",
                  "start" : 3600.5,
                  "text" : "テスト"
                }
              ],
              "version" : 1
            }

            """
        #expect(json == expected)
    }

    @Test func jsonWithoutTranscriptHasNullTranscript() throws {
        var o = ExportRendererTests.options
        o.includeTranscript = false
        let json = try MeetingExportJSON.encode(ExportRendererTests.sample, options: o)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["transcript"] is NSNull)
        #expect(object["version"] as? Int == MeetingExportJSON.version)
        #expect(object["endedAt"] as? String == "2026-10-06T09:15:00Z")
        let tasks = try #require(object["tasks"] as? [[String: Any]])
        #expect(tasks.map { $0["status"] as? String } == ["open", "done", "dropped"])
        #expect(tasks[1]["due"] is NSNull)
    }

    @Test func storeLoaderReadsTheWholeMeeting() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let ana = try await s.saveEntity(EntityDraft(kind: .person, name: "Ana García"))
        let m = try await f.meeting(["Hola a todos", "Revisamos el presupuesto", "Ana prepara el informe"])
        try await s.setMeetingEntities(m, role: .attendee, [ana])
        try await s.setMeetingEntities(m, role: .others, [ana])
        let segs = try await s.segments(of: m)
        try await s.addDecision(m, text: "Presupuesto aprobado", segmentID: segs[1].id, t: segs[1].start)
        let me = try await s.selfEntity()
        try await s.addTask(m, text: "Enviar el informe", ownerID: me, segmentID: segs[2].id, t: segs[2].start)
        try await s.addNote(m, at: 12, text: "Llamar a legal")
        try await s.saveCard(MeetingCard(summary: "Resumen", topics: ["Presupuesto"]), of: m)

        let e = try #require(try await s.meetingExport(m))
        #expect(e.summary == "Resumen" && e.topics == ["Presupuesto"])
        #expect(e.attendees == ["Ana García"])
        #expect(e.decisions.map(\.text) == ["Presupuesto aprobado"])
        #expect(e.tasks.first?.owner == Channel.me.displayName, "the self entity shows as “Me” until renamed")
        #expect(e.notes == [.init(text: "Llamar a legal", time: 12)])
        #expect(e.transcript.count == 3)
        #expect(e.transcript.filter { $0.channel == .others }.allSatisfy { $0.name == "Ana García" })
        #expect(e.transcript.filter { $0.channel == .me }.allSatisfy { $0.name == nil })
        #expect(try await s.meetingExport(9_999) == nil)
    }

    @Test func aNoteCarriesItsExpansionAndOldReadersKeepTheirFields() throws {
        let e = MeetingExport(title: "T", startedAt: ExportRendererTests.date(2026, 10, 6, 8), notes: [
            .init(text: "Q3 budget", time: 312, expansion: [.init(text: "Ana proposed it.", times: [310.0004, 311], segmentIDs: [4, 5], unconfirmed: true)],
                  editedByUser: true),
            .init(text: "plain", time: nil)])
        let object = try #require(JSONSerialization.jsonObject(with: Data(try MeetingExportJSON.encode(e, options: ExportRendererTests.options).utf8)) as? [String: Any])
        let notes = try #require(object["notes"] as? [[String: Any]])
        #expect(notes[0]["text"] as? String == "Q3 budget" && notes[0]["time"] as? Double == 312)
        let expansion = try #require(notes[0]["expansion"] as? [String: Any])
        #expect(expansion["editedByUser"] as? Bool == true)
        let sentence = try #require((expansion["sentences"] as? [[String: Any]])?.first)
        #expect(sentence["text"] as? String == "Ana proposed it." && sentence["times"] as? [Double] == [310, 311])
        #expect(sentence["segmentIds"] as? [Int] == [4, 5] && sentence["unconfirmed"] as? Bool == true && sentence["differs"] as? Bool == false)
        #expect(notes[1]["expansion"] is NSNull, "no expansion is null, the key is always there")
    }

    @Test func theStoreExportsTheExpansionOfANoteUnlessItIsOutOfDate() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["Ana said the budget goes up ten percent", "Fine"])
        let seg = try #require(try await f.store.segments(of: id).first)
        let fresh = try await f.store.addNote(id, at: 5, text: "budget")
        let old = try await f.store.addNote(id, at: 6, text: "second note")
        let sentence = NoteExpansion.Sentence(text: "The budget rises.", cites: [.init(seg: seg.id, t: seg.start)], quote: "the budget goes up")
        try await f.store.saveExpansion(noteID: fresh, pass: .closing, outcome: .sentences([sentence]), sourceKey: TextKeys.norm("budget"))
        try await f.store.saveExpansion(noteID: old, pass: .closing, outcome: .sentences([sentence]), sourceKey: TextKeys.norm("second note"))
        try await f.store.updateNote(old, text: "second note, changed")
        let notes = try #require(try await f.store.meetingExport(id)).notes
        #expect(notes.map(\.text) == ["budget", "second note, changed"])
        #expect(notes[0].expansion.map(\.text) == ["The budget rises."] && notes[0].expansion[0].segmentIDs == [seg.id])
        #expect(notes[1].expansion.isEmpty, "an expansion written from older words is not exported")
    }

    @Test func copiedAnswerListsClaimsWithSources() {
        let a = AnswerExport(question: "What did we decide?", answer: "We ship on Friday.",
                             claims: [.init(text: "Ship on Friday", verified: true, sources: ["Weekly sync · 01:05", "Retro · 12:00"]),
                                      .init(text: "Budget *grows*", verified: false, sources: [])])
        #expect(a.plainText() == """
            What did we decide?

            We ship on Friday.

            - Ship on Friday (verified: Weekly sync · 01:05; Retro · 12:00)
            - Budget *grows* (not verified)

            """)
        #expect(a.markdown() == """
            **What did we decide?**

            We ship on Friday.

            - Ship on Friday (verified: Weekly sync · 01:05; Retro · 12:00)
            - Budget \\*grows\\* (not verified)

            """)
    }

    @Test func anUnverifiedAnswerCarriesTheNoteInEveryCopyAndInTheJSON() throws {
        let note = "Check them before relying on this answer."
        let a = AnswerExport(question: "Q?", answer: "It stays.", claims: [], unverifiedNote: note)
        #expect(a.plainText().contains(note) && a.markdown().contains(note))
        let json = try #require(JSONSerialization.jsonObject(with: a.json()) as? [String: Any])
        #expect(json["verified"] as? Bool == false && json["note"] as? String == note)
        let plain = AnswerExport(question: "Q?", answer: "It stays.", claims: [])
        let object = try #require(JSONSerialization.jsonObject(with: plain.json()) as? [String: Any])
        #expect(object["verified"] == nil && object["note"] == nil && !plain.plainText().contains(note))
    }
}
