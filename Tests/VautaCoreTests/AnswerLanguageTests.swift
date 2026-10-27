// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The answer follows the language of the question: the English questions that got Spanish answers (a model check that translated
/// the rewrite) must not any more.
@Suite("Answer language follows the question")
struct AnswerLanguageTests {
    static func settled(_ text: String, language: CueLanguage) -> SettledQuestion {
        let line = QuestionLine(segmentID: 7, channel: .others, start: 723, end: 726, text: text)
        let candidate = QuestionCandidate(text: text, score: 0.85, cues: ["mark"], language: language, utterance: text, channel: .others, start: 723, end: 726)
        return SettledQuestion(candidate: candidate, line: line, before: [], after: [], rephrased: [], settledAt: 730, arrivedAt: 726)
    }

    // MARK: The check

    @Test func aTranslatedRewriteIsReplacedByTheSentence() throws {
        let said = "What new functions are there on the remote control?"
        let reply = #"{"kind": "information", "question": "¿Qué nuevas funciones hay en el mando a distancia?", "answered_aloud": false}"#
        let check = try #require(QuestionCheck.parse(reply, candidate: said, language: .en))
        #expect(check.question == said)
    }

    @Test func aRewriteInTheSentencesLanguageIsKept() throws {
        let said = "And what did they decide about that?"
        let reply = #"{"kind": "information", "question": "What did the team decide about the logo?", "answered_aloud": false}"#
        #expect(try #require(QuestionCheck.parse(reply, candidate: said, language: .en)).question == "What did the team decide about the logo?")
        let es = "¿Y qué decidieron sobre el presupuesto de la obra?"
        let rewrite = #"{"kind": "information", "question": "¿Qué decidieron sobre el presupuesto de la obra?", "answered_aloud": false}"#
        #expect(try #require(QuestionCheck.parse(rewrite, candidate: es, language: .es)).question == "¿Qué decidieron sobre el presupuesto de la obra?")
    }

    @Test(arguments: [
        ("今回の予算はいくらでしたか？", "What was the budget this time?"),
        ("这次的预算是多少？", "How much was the budget this time?"),
    ])
    func aCJKSentenceIsNotAnsweredInEnglish(said: String, translated: String) throws {
        let reply = #"{"kind": "information", "question": "\#(translated)", "answered_aloud": false}"#
        let check = try #require(QuestionCheck.parse(reply, candidate: said, language: said.hasPrefix("今") ? .ja : .zh))
        #expect(check.question == said)
    }

    @Test(arguments: [("Did we keep the budget for the second quarter?", CueLanguage.en, "English"),
                      ("¿Mantuvimos el presupuesto del segundo trimestre?", .es, "Spanish"),
                      ("今回の予算はいくらでしたか？", .ja, "Japanese"),
                      ("这次的预算是多少？", .zh, "Chinese")])
    func bothInstructionsNameTheLanguageOfTheLine(text: String, language: CueLanguage, name: String) {
        let question = Self.settled(text, language: language)
        for compact in [false, true] {
            let prompt = QuestionCheck.instruction(for: question, compact: compact)
            #expect(prompt.contains("in \(name), the language of the marked line, without translating it"), "compact: \(compact)")
        }
    }

    @Test func anAmbiguousLineNamesTheMeetingsLanguage() {
        let prompt = QuestionCheck.instruction(for: Self.settled("Okay?", language: .es), compact: true)
        #expect(prompt.contains("in Spanish, the language of the marked line"))
    }

    // MARK: The language chosen

    @Test func whatWasSaidWinsOverTheRewrite() {
        let meeting = OutputLanguage(Locale(identifier: "en-US"))
        let chosen = OutputLanguage.detect(["Who is going to send the final report to the client tomorrow?", "¿Quién enviará el informe?"], fallback: meeting)
        #expect(chosen == meeting)
        let spanish = OutputLanguage.detect(["¿Quién va a enviar el informe final al cliente mañana?"], fallback: meeting)
        #expect(spanish.englishName == "Spanish")
    }

    @Test func anAmbiguousQuestionTakesTheFallback() {
        #expect(OutputLanguage.detect(["Okay?"], fallback: OutputLanguage(Locale(identifier: "ja-JP"))).identifier == "ja-JP")
        #expect(OutputLanguage.detect([], fallback: OutputLanguage(Locale(identifier: "es-MX"))).identifier == "es-MX")
    }

    @Test func aSpanishMeetingAndAnEnglishQuestionAreAnsweredInEnglish() {
        let spanishMeeting = OutputLanguage(Locale(identifier: "es-ES"))
        let chosen = OutputLanguage.detect("What was the total cost of the project for the second quarter?", fallback: spanishMeeting)
        #expect(chosen.englishName == "English")
        #expect(VautaPrompts.askInstruction("What was the total cost of the project?", language: chosen).content.contains("Write everything in English (en)."))
    }

    @Test(arguments: [("今回のプロジェクトの総費用はいくらでしたか？", "Japanese"), ("这个项目第二季度的总费用是多少？", "Chinese")])
    func cjkQuestionsAreAnsweredInTheirLanguage(question: String, name: String) {
        let chosen = OutputLanguage.detect(question, fallback: OutputLanguage(Locale(identifier: "en-US")))
        #expect(chosen.englishName == name)
        #expect(VautaPrompts.askInstruction(question, language: chosen).content.contains("Write everything in \(name)"))
    }

    // MARK: Through the service

    @Test func aQuestionHeardInEnglishIsAskedInEnglishWhateverTheRewriteSays() async throws {
        let id = Locked<Int64>(0)
        let r = try await AutoAnswerTests.rig { _, _, _ in ScriptedChat.reply(AutoAnswerTests.reply([("Budget kept", id.withLock { $0 }, "we keep the budget as it is")])) }
        id.withLock { $0 = r.segments[1].id }
        let heard = "Um, so did we keep the budget for the quarter, or not?"
        _ = try await r.service.autoAnswer("¿Mantuvimos el presupuesto del trimestre?", meetingID: r.meeting,
                                           request: AutoAskRequest(segmentID: r.segments[2].id, sources: .all, heard: [heard], locale: "en-US"))
        let text = try #require(AutoAnswerTests.autoCalls(r.chat).last).text
        #expect(text.contains("Write everything in English (en-US)."))
        #expect(!text.contains("Write everything in Spanish"))
    }

    @Test func anAnswerInAnotherLanguageThanTheQuestionIsNotShown() async throws {
        let id = Locked<Int64>(0)
        let spanish = "El presupuesto se mantiene tal como está, según lo que se dijo en la reunión de ayer."
        let r = try await AutoAnswerTests.rig { _, _, _ in
            ScriptedChat.reply(AutoAnswerTests.reply([("Presupuesto mantenido", id.withLock { $0 }, "we keep the budget as it is")], answer: spanish))
        }
        id.withLock { $0 = r.segments[1].id }
        let outcome = try await r.service.autoAnswer("Did we keep the budget for the quarter?", meetingID: r.meeting,
                                                     request: AutoAskRequest(segmentID: r.segments[2].id, sources: .all,
                                                                             heard: ["Did we keep the budget for the quarter?"], locale: "en-US"))
        #expect(outcome == .noAnswer)
    }
}
