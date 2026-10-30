// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// `AskMeetingPlace`: the meetings a question names by their place ("the last meeting", "前回の会議") in the nine languages, and the
/// questions that only seem to.
@Suite("Ask: the meeting a question names by its place")
struct AskMeetingPlaceTests {
    typealias Case = (question: String, which: AskMeetingPlace.Which, ofNamed: Bool)

    static let golden: [String: [Case]] = [
        "en": [("What did we decide in the last meeting?", .last(1), false), ("Summarize the latest call", .last(1), false),
               ("What came up in the most recent meeting?", .last(1), false), ("What did we agree in the previous meeting?", .last(1), false),
               ("What were the action items of the last three meetings?", .last(3), false), ("Across the last meetings, what did Ana own?", .last(3), false),
               ("What did we decide in the first meeting with Ana?", .first(1), true), ("What happened in the meeting before last?", .beforeLast, false),
               ("What did the second to last meeting decide?", .beforeLast, false), ("What came out of the last meeting we had with Kobaltix?", .last(1), true),
               ("What did we say in the last meeting where we discussed pricing?", .last(1), true), ("What did Ana's last meeting decide?", .last(1), true)],
        "es": [("¿Qué decidimos en la última reunión?", .last(1), false), ("¿Qué se dijo en la reunión anterior?", .last(1), false),
               ("Resume las tres últimas reuniones", .last(3), false), ("¿Qué acordamos en las últimas reuniones?", .last(3), false),
               ("¿Qué se habló en la primera reunión con Ana?", .first(1), true), ("¿Qué salió de la penúltima reunión?", .beforeLast, false),
               ("¿Qué decidimos en la última reunión que tuvimos con Kobaltix?", .last(1), true), ("¿Qué pasó en la reunión pasada?", .last(1), false),
               ("Las tres reuniones anteriores, ¿qué decidieron?", .last(3), false)],
        "fr": [("Qu’avons-nous décidé lors de la dernière réunion ?", .last(1), false), ("Qu’a-t-on dit à la réunion précédente ?", .last(1), false),
               ("Résume les trois dernières réunions", .last(3), false), ("Qu’a-t-on décidé à la première réunion avec Ana ?", .first(1), true),
               ("Qu’est-il ressorti de l’avant-dernière réunion ?", .beforeLast, false), ("Que dit la réunion la plus récente ?", .last(1), false)],
        "de": [("Was haben wir im letzten Meeting beschlossen?", .last(1), false), ("Was wurde in der letzten Besprechung gesagt?", .last(1), false),
               ("Fasse die letzten drei Meetings zusammen", .last(3), false), ("Was kam im ersten Meeting mit Ana heraus?", .first(1), true),
               ("Was hat das vorletzte Meeting entschieden?", .beforeLast, false), ("Was wurde beim vorigen Termin vereinbart?", .last(1), false)],
        "it": [("Cosa abbiamo deciso nell’ultima riunione?", .last(1), false), ("Cosa si è detto nella riunione precedente?", .last(1), false),
               ("Riassumi le ultime tre riunioni", .last(3), false), ("Cosa abbiamo deciso nella prima riunione con Ana?", .first(1), true),
               ("Cosa abbiamo deciso nella riunione scorsa?", .last(1), false), ("Cosa ha deciso la penultima riunione?", .beforeLast, false)],
        "pt-BR": [("O que decidimos na última reunião?", .last(1), false), ("O que foi dito na reunião anterior?", .last(1), false),
                  ("Resuma as últimas três reuniões", .last(3), false), ("O que saiu da primeira reunião com a Ana?", .first(1), true),
                  ("O que decidimos na reunião passada?", .last(1), false), ("O que a penúltima reunião decidiu?", .beforeLast, false)],
        "ja": [("前回の会議で何を決めましたか", .last(1), false), ("前回決めたことは？", .last(1), false), ("直近3回の会議の決定事項は", .last(3), false),
               ("前々回の会議の結論は", .beforeLast, false),
               ("Anaさんとの前回の会議で何を決めましたか", .last(1), true), ("予算を話し合った最後の会議はいつでしたか", .last(1), true)],
        "ko": [("지난 회의에서 무엇을 결정했나요?", .last(1), false), ("지난번 회의에서 나온 이야기는?", .last(1), false),
               ("최근 세 번의 회의를 요약해 줘", .last(3), false), ("지지난 회의의 결론은?", .beforeLast, false), ("Ana와의 지난 회의에서 무엇을 정했나요?", .last(1), true),
               ("예산을 논의한 지난 회의는 언제였나요?", .last(1), true)],
        "zh-Hans": [("上次会议我们决定了什么？", .last(1), false), ("上一次会议说了什么", .last(1), false), ("总结最近三次会议", .last(3), false),
                    ("和Kobaltix的第一次会议定了什么", .first(1), true), ("上上次会议的结论是什么", .beforeLast, false), ("和Ana的上次会议决定了什么", .last(1), true)],
    ]

    static let negatives: [String: [String]] = [
        "en": ["What changed since the last meeting?", "What should we prepare before the first call?", "What did we decide last week?",
               "Who spoke last in the meeting?", "What is the last item on the list?", "When is the next meeting?",
               "First, what did we decide in the meeting?", "What did we decide in the first and the last meeting?", "What did we do after the last meeting?",
               // The first of something (a project, a series), not the first ever recorded; and questions that compare meetings.
               "What did we cover in the first two sessions?", "How did the base station develop between the third and the last meeting?",
               "What happened to speech recognition from the second to the fourth meeting?",
               "How did the ball-shaped idea evolve from the first meeting to the final prototype?",
               "How does the cost given in the kick-off meeting compare with the estimates in the last meeting?"],
        "es": ["¿Qué cambió desde la última reunión?", "¿Qué hay que preparar antes de la próxima reunión?", "¿Cuál es la última tarea de la lista?",
               "¿Qué hicimos después de la última reunión?", "¿Qué se decidió en la reunión del lunes?"],
        "fr": ["Qu’est-ce qui a changé depuis la dernière réunion ?", "Que faut-il faire avant la prochaine réunion ?"],
        "de": ["Was hat sich seit dem letzten Meeting geändert?", "Was müssen wir vor dem nächsten Meeting vorbereiten?", "Was war das letzte Thema?"],
        // "dall’ultima riunione" is since the last meeting as often as out of it ("cosa è emerso dall’ultima riunione"): not read.
        "it": ["Cosa è cambiato dall’ultima riunione?", "Cosa è emerso dall’ultima riunione?", "Cosa dobbiamo fare prima della riunione?"],
        "pt-BR": ["O que mudou desde a última reunião?", "O que fazer antes da próxima reunião?"],
        "ja": ["前回の会議から何が変わりましたか", "最初の打ち合わせで何を話しましたか", "3回目と最後の会議で何が変わりましたか", "先週の会議で何を決めましたか", "次の会議はいつですか"],
        "ko": ["지난 회의 이후 무엇이 바뀌었나요?", "첫 회의에서 무엇을 정했나요?", "지난주 회의에서 무엇을 정했나요?", "다음 회의는 언제인가요?"],
        "zh-Hans": ["上次会议以来有什么变化？", "第一次会议定了什么", "第二次和最后一次会议有什么不同", "自从上次会议，进展如何", "上周的会议决定了什么", "下次会议是什么时候"],
    ]

    @Test(arguments: Array(golden.keys).sorted())
    func goldenPhrases(language: String) {
        for (question, which, ofNamed) in Self.golden[language] ?? [] {
            #expect(AskMeetingPlace.read(question, languages: [language]) == AskMeetingPlace(which: which, ofNamed: ofNamed), "\(question)")
        }
    }

    @Test(arguments: Array(negatives.keys).sorted())
    func questionsThatOnlySeemToNameAPlace(language: String) {
        for question in Self.negatives[language] ?? [] {
            #expect(AskMeetingPlace.read(question, languages: [language]) == nil, "\(question)")
        }
    }

    @Test func onlyTheQuestionsLanguagesAreRead() {
        // German "letzte" is not read in an English question, nor "last" in a Spanish one.
        #expect(AskMeetingPlace.read("Was haben wir im letzten Meeting beschlossen?", languages: ["en"]) == nil)
        #expect(AskMeetingPlace.read("¿Qué decidimos en la última reunión?", languages: ["en", "es"]) == AskMeetingPlace(which: .last(1), ofNamed: false))
    }

    @Test func theStoreFindsTheMeetingsAtThePlace() async throws {
        let f = try KnowledgeFixture()
        let kobaltix = try await f.store.saveEntity(EntityDraft(kind: .project, name: "Kobaltix"))
        let now = Date.now, day: TimeInterval = 86_400
        let first = try await f.meeting(["The kickoff with Kobaltix went well"], at: now - 9 * day)
        let second = try await f.meeting(["The budget for the quarter"], at: now - 5 * day)
        let third = try await f.meeting(["Kobaltix asked for the pricing again"], at: now - 2 * day)
        let latest = try await f.meeting(["The plants in the office"], at: now - day)
        // Being recorded: never "the last meeting".
        _ = try await f.store.startMeeting(at: now)
        #expect(try await f.store.meetingIDs(at: .last(1)) == [latest])
        #expect(try await f.store.meetingIDs(at: .last(3)) == [latest, third, second])
        #expect(try await f.store.meetingIDs(at: .first(1)) == [first])
        #expect(try await f.store.meetingIDs(at: .beforeLast) == [third])
        #expect(try await f.store.meetingIDs(at: .last(1), from: now - 6 * day, to: now - 3 * day) == [second])
        #expect(try await f.store.entitiesNamed(in: "the last meeting about Kobaltix", locale: Locale(identifier: "en")) == [kobaltix])
        #expect(try await f.store.meetingIDs(at: .last(1), entities: [kobaltix]) == [third])
        #expect(try await f.store.meetingIDs(at: .first(1), entities: [kobaltix]) == [first])
    }
}
