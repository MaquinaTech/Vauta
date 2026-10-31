// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// A question that goes on from the one before: when it reads so, in the nine languages, and what search and the model read then.
@Suite("Ask: a question that follows up")
struct AskFollowUpTests {
    /// Questions that go on from the one before (a word that continues, or short and pointing back).
    static let continuing: [(String, String)] = [
        ("en", "And who owns it?"), ("en", "What about the budget?"), ("en", "When is that due?"), ("en", "But why?"),
        ("es", "¿Y quién lo lleva?"), ("es", "¿Qué hay del presupuesto?"), ("es", "¿Cuándo vence eso?"), ("es", "Pero ¿por qué?"),
        ("fr", "Et qui s'en occupe ?"), ("fr", "Qu'en est-il du budget ?"), ("fr", "Quand est-ce que ça doit être fini ?"),
        ("de", "Und wer kümmert sich darum?"), ("de", "Was ist mit dem Budget?"), ("de", "Wer macht das?"),
        ("it", "E chi se ne occupa?"), ("it", "Ma perché?"), ("it", "Chi fa questo?"),
        ("pt", "E quem cuida disso?"), ("pt", "E quanto ao orçamento?"), ("pt", "Quando vence isso?"),
        ("ja", "それで、誰が担当しますか？"), ("ja", "その期限はいつ？"), ("ja", "それは誰？"),
        ("ko", "그럼 누가 담당해요?"), ("ko", "그건 언제까지예요?"), ("ko", "그리고 예산은요?"),
        ("zh", "那谁负责？"), ("zh", "还有预算呢？"), ("zh", "它什么时候到期？"),
    ]

    /// Questions that stand on their own: a subject of their own, at length, and no word that continues.
    static let standalone: [(String, String)] = [
        ("en", "What did we decide about the launch budget in the weekly sync?"), ("en", "Who is handling the vendor contract renewal?"),
        ("es", "¿Qué decidimos sobre el presupuesto del lanzamiento en la reunión semanal?"), ("es", "¿Quién se encarga de la renovación del contrato?"),
        ("fr", "Qu'avons-nous décidé pour le budget du lancement la semaine dernière ?"),
        ("de", "Was haben wir beim wöchentlichen Treffen über das Budget für den Launch entschieden?"),
        ("it", "Cosa abbiamo deciso sul budget del lancio nella riunione settimanale?"),
        ("pt", "O que decidimos sobre o orçamento do lançamento na reunião semanal?"),
        ("ja", "週次ミーティングでローンチ予算について何を決めましたか？"),
        ("ko", "주간 회의에서 출시 예산에 대해 무엇을 결정했나요?"),
        ("zh", "我们在周会上关于发布预算做了什么决定？"),
    ]

    @Test(arguments: continuing)
    func aQuestionThatGoesOnIsReadSo(language: String, question: String) {
        #expect(AskFollowUp.continues(question, languages: [language]), "\(language): \(question)")
    }

    @Test(arguments: standalone)
    func aQuestionOfItsOwnIsNot(language: String, question: String) {
        #expect(!AskFollowUp.continues(question, languages: [language]), "\(language): \(question)")
    }

    @Test func onlyTheLanguagesOfTheQuestionAreRead() {
        // Spanish "y" or German "es" mean nothing in English: an English question is not read with them.
        #expect(!AskFollowUp.continues("Y axis values for the chart we showed the client", languages: ["en"]))
        #expect(AskFollowUp.continues("Y axis values?", languages: ["es"]), "short and starting with Spanish \"y\"")
        #expect(!AskFollowUp.continues("", languages: ["en"]) && !AskFollowUp.continues("  ¿? ", languages: ["es"]))
        // German "das" is an article inside a question, a pronoun as its last word.
        #expect(!AskFollowUp.continues("Wann ist das Meeting?", languages: ["de"]))
    }

    @Test func theEarlierQuestionsAreReadFirstAndAtMostTwo() {
        let first = AskFollowUp.after("What did we decide about the launch?", previous: nil)
        #expect(first.reading("And who owns it?") == "What did we decide about the launch? And who owns it?")
        #expect(first.last == "What did we decide about the launch?" && first.context == first.last)
        let second = AskFollowUp.after("And who owns it?", previous: first)
        let third = AskFollowUp.after("When is it due?", previous: second)
        #expect(third.questions == ["And who owns it?", "When is it due?"], "the oldest drops out")
        #expect(AskFollowUp.after("Something else entirely", previous: nil).questions == ["Something else entirely"], "asked on its own: a new thread")
    }
}
