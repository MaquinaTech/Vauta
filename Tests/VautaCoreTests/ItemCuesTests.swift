// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The phrase lists that tell a task or a decision from talk about one, in the nine languages of the interface.
@Suite("Minutes: item cues in nine languages")
struct ItemCuesTests {
    struct Sample: Sendable {
        let language: String
        let commit: String, request: String, acceptance: String, agreement: String, hedge: String, recap: String
    }

    static let samples: [Sample] = [
        Sample(language: "en", commit: "I'll send the report.", request: "Can you send the report?", acceptance: "Sure, no problem.", agreement: "We agreed to go with option B.",
               hedge: "Maybe we could do that.", recap: "At the last meeting we looked at it."),
        Sample(language: "es", commit: "Yo me encargo del informe.", request: "¿Puedes enviar el informe?", acceptance: "Claro, con gusto.", agreement: "Queda aprobado por unanimidad.",
               hedge: "Quizás mañana.", recap: "En la sesión anterior lo vimos."),
        Sample(language: "fr", commit: "Je m'en occupe.", request: "Peux-tu envoyer le rapport ?", acceptance: "Pas de problème.", agreement: "On est d'accord.",
               hedge: "Peut-être demain.", recap: "À la dernière réunion on l'a vu."),
        Sample(language: "de", commit: "Ich übernehme das.", request: "Kannst du den Bericht schicken?", acceptance: "Kein Problem.", agreement: "Wir sind einverstanden.",
               hedge: "Vielleicht morgen.", recap: "In der letzten Sitzung haben wir es gesehen."),
        Sample(language: "it", commit: "Me ne occupo io.", request: "Puoi inviare il rapporto?", acceptance: "Nessun problema.", agreement: "È stato approvato.",
               hedge: "Forse domani.", recap: "Nella riunione precedente lo abbiamo visto."),
        Sample(language: "pt", commit: "Eu cuido disso.", request: "Você pode enviar o relatório?", acceptance: "Sem problema.", agreement: "Ficou combinado.",
               hedge: "Talvez amanhã.", recap: "Na reunião anterior nós vimos isso."),
        Sample(language: "ja", commit: "私が担当します。", request: "送付をお願いします。", acceptance: "問題ありません。", agreement: "この案を承認しました。",
               hedge: "多分明日です。", recap: "前回の会議で見ました。"),
        Sample(language: "ko", commit: "제가 하겠습니다.", request: "보고서를 보내 부탁드립니다.", acceptance: "문제없습니다.", agreement: "그렇게 합의했습니다.",
               hedge: "아마 내일입니다.", recap: "지난 회의에서 봤습니다."),
        Sample(language: "zh", commit: "我来处理。", request: "请你发送报告。", acceptance: "没问题。", agreement: "大家同意这个方案。",
               hedge: "也许明天。", recap: "上次会议看过了。"),
    ]

    @Test(arguments: samples)
    func everyLanguageHasACueOfEachKind(_ s: Sample) {
        #expect(ItemCues.commits(s.commit), "\(s.language) commit")
        #expect(ItemCues.Text(s.request).has(ItemCues.request), "\(s.language) request")
        #expect(ItemCues.commits(s.acceptance, cues: ItemCues.committingAcceptance), "\(s.language) acceptance")
        #expect(ItemCues.Text(s.agreement).has(ItemCues.agreement), "\(s.language) agreement")
        #expect(ItemCues.hedged(s.hedge), "\(s.language) hedge")
        #expect(ItemCues.Text(s.recap).has(ItemCues.recap), "\(s.language) recap")
    }

    @Test func aQuestionOrANegationInsideTheClauseCancelsACommitment() {
        #expect(!ItemCues.commits("I'll send the report?"))
        #expect(!ItemCues.commits("I won't send the report."))
        #expect(!ItemCues.commits("¿Yo me encargo del informe?"))
        #expect(!ItemCues.commits("私が担当しません。"))
        #expect(!ItemCues.commits("我不会处理。"))
        #expect(!ItemCues.commits("Yo no me encargo."))
    }

    @Test func anObligationOrAPlanCommitsOnlyWithAnActionVerb() {
        for text in ["I have to leave at three.", "I need to understand the costs first.", "Voy a decir una cosa.", "Tengo que irme a las tres.", "Je dois partir à trois heures.",
                     "Ich muss gehen.", "Devo andare.", "Tenho que sair.", "Preciso entender os custos.", "Voy a hacer una pregunta.", "Tengo que hacer una pausa.",
                     "Je dois faire une remarque.", "Devo fare una domanda.", "Tenho que fazer uma pausa."] {
            #expect(!ItemCues.commits(text), "\(text)")
            #expect(ItemCues.Text(text).has(ItemCues.obligation) || !ItemCues.Text(text).has(ItemCues.selfCommit), "\(text)")
        }
        for text in ["I have to send the minutes.", "I need to prepare the budget.", "Voy a enviar el informe.", "Tengo que revisar el presupuesto.", "Je dois envoyer le rapport.",
                     "Devo inviare il rapporto.", "Tenho que enviar o relatório."] {
            #expect(ItemCues.commits(text), "\(text)")
        }
    }

    @Test func aYesAcceptsTheRequestOnlyWhenItAddsNothingElse() {
        let deck = ItemCues.contentWords("Send the deck", language: "en")
        for reply in ["Yes.", "Sure.", "Okay, yeah."] { #expect(ItemCues.acceptsRequest(reply, reference: deck, language: "en"), "\(reply)") }
        #expect(!ItemCues.acceptsRequest("Yes, and the budget is fine.", reference: deck, language: "en"))
    }

    @Test func aCommitmentAnswersARequestOnlyWhenItIsBareOrAboutTheItem() {
        let logo = ItemCues.contentWords("Look into the company logo", language: "en")
        for reply in ["Yeah I'll do that.", "Will do.", "Sure, I can.", "I'll do it tomorrow.", "No problem."] {
            #expect(ItemCues.answersRequest(reply, reference: logo, language: "en"), "\(reply)")
        }
        #expect(!ItemCues.answersRequest("I'll send the minutes tonight.", reference: logo, language: "en"))
        #expect(!ItemCues.answersRequest("Sure, I'll book the room for Monday.", reference: logo, language: "en"))
        #expect(ItemCues.answersRequest("Sure, I'll look into the logo.", reference: logo, language: "en"))
        let informe = ItemCues.contentWords("Revisar el informe", language: "es")
        #expect(ItemCues.answersRequest("Me encargo.", reference: informe, language: "es"))
        #expect(ItemCues.answersRequest("Lo hago yo.", reference: informe, language: "es"))
        #expect(!ItemCues.answersRequest("Yo me encargo de reservar la sala.", reference: informe, language: "es"))
        for (reply, item) in [("はい、やります。", "報告書を確認する"), ("제가 하겠습니다.", "보고서 확인"), ("我来处理。", "检查报告")] {
            #expect(ItemCues.answersRequest(reply, reference: ItemCues.contentWords(item, language: nil), language: nil), "\(reply)")
        }
    }

    @Test func everyLanguageHasANegatedOrQuestionFormThatDoesNotCommit() {
        for text in ["Je ne m'en occupe pas.", "Est-ce que je m'en occupe ?", "Ich übernehme das nicht.", "Übernehme ich das?", "Non me ne occupo io.", "Me ne occupo io?",
                     "Eu não cuido disso.", "Eu cuido disso?", "제가 하지 않겠습니다.", "제가 하겠습니까?"] {
            #expect(!ItemCues.commits(text), "\(text)")
        }
        #expect(ItemCues.commits("Je m'en occupe.") && ItemCues.commits("Ich übernehme das.") && ItemCues.commits("Me ne occupo io.") && ItemCues.commits("Eu cuido disso."))
    }

    @Test func aWeakYesIsNotFoundInsideOtherWords() {
        for text in ["네트워크를 확인할게요", "好像不行", "你可以发给我吗", "si no llego, aviso", "最好明天", "不好"] {
            #expect(!ItemCues.isWeakYes(text), "\(text)")
        }
        for text in ["Yeah.", "Sí.", "Si, claro.", "네.", "네, 알겠습니다.", "好的。", "好。", "はい。", "可以。", "Dale."] {
            #expect(ItemCues.isWeakYes(text), "\(text)")
        }
        #expect(!ItemCues.isWeakYes("Yeah, no, I can't do that.") && !ItemCues.isWeakYes("Sorry, I can't this week."))
        #expect(ItemCues.refuses("Lo siento, no puedo.") && ItemCues.refuses("申し訳ありませんが、できません。") && !ItemCues.refuses("Sorry, I'll do it.") && !ItemCues.refuses("No worries, I'll send it."))
    }

    @Test func askingForSomethingIsNotCommittingToIt() {
        #expect(!ItemCues.commits("Well I will need your snippets of code by tomorrow evening."))
        #expect(!ItemCues.commits("Well I will I will need your snippets of code or it'd be good if I had them by tomorrow evening."))
        #expect(!ItemCues.commits("I'd like the numbers by Friday."))
        #expect(ItemCues.commits("I'll need to send the numbers by Friday."))
        #expect(ItemCues.commits("I'll have to ask the manufacturing department."))
    }

    @Test func aRequestIsNotAHedge() {
        #expect(!ItemCues.hedged("Could you send the report?"))
        #expect(ItemCues.hedged("We could send the report."))
        #expect(!ItemCues.hedged("Would you mind sending it"))
    }

    @Test func clausesAreSplitOnSentenceEndsAndKeepTheirTerminators() {
        let clauses = ItemCues.clauses("But yeah I'll work on it. Um I was wondering? Okay; fine")
        #expect(clauses == ["But yeah I'll work on it.", " Um I was wondering?", " Okay;", " fine"])
        #expect(ItemCues.clauses("我来处理。你呢？好") == ["我来处理。", "你呢？", "好"])
    }

    @Test func theClauseThatCarriesTheItemIsFoundByItsWords() {
        let text = "Well I was struggling with the build. But yeah I will write the report. Um I was wondering about the budget?"
        let (index, clauses) = ItemCues.evidenceClause(item: "Write the report", quote: "I will write the report", in: text, language: "en")
        #expect(clauses[index].contains("write the report"))
        // The user's cue clause wins a tie.
        let tie = ItemCues.evidenceClause(item: "Work on it", quote: "", in: "We talked about work. I'll work on it.", language: "en")
        #expect(tie.clauses[tie.index].contains("I'll"))
    }

    @Test func aRoleOrAThirdPartyIsNotTheSpeakerOrTheAddressee() {
        #expect(ItemCues.thirdPartySubject("The Industrial Designer will do the components concept."))
        #expect(ItemCues.thirdPartySubject("Que el ejecutivo envíe un informe."))
        #expect(ItemCues.thirdPartySubject("They will send it tomorrow."))
        #expect(!ItemCues.thirdPartySubject("I will send it tomorrow."))
        #expect(!ItemCues.thirdPartySubject("You will send it tomorrow."))
        #expect(!ItemCues.thirdPartySubject("We will send it tomorrow."))
    }

    @Test func thePhraseSetsAnswerLikeTheWordMatcherTheyReplace() {
        let lists: [(String, PhraseSet)] = [("selfCommit", ItemCues.selfCommit), ("committingAcceptance", ItemCues.committingAcceptance), ("weakAcceptance", ItemCues.weakAcceptance),
                                            ("request", ItemCues.request), ("volunteerCall", ItemCues.volunteerCall), ("groupObligation", ItemCues.groupObligation),
                                            ("agreement", ItemCues.agreement), ("groupDecision", ItemCues.groupDecision), ("hedge", ItemCues.hedge), ("recap", ItemCues.recap),
                                            ("reading", ItemCues.reading), ("procedure", ItemCues.procedure), ("speakerProcedure", ItemCues.speakerProcedure),
                                            ("rating", ItemCues.rating), ("done", ItemCues.done), ("modalFuture", ItemCues.modalFuture)]
        var texts = Self.samples.flatMap { [$0.commit, $0.request, $0.acceptance, $0.agreement, $0.hedge, $0.recap] }
        texts += ["We'll go with option B and I'll send it", "Okay, let's go through the slides; I'll start off", "so the upper option is the bomb", "tenemos que revisar el acta anterior",
                  "nothing to see here", "Who wants to take the notes?", "no problem, will do", "approved by unanimity", "ya lo hice ayer", "もし明日なら私が担当します"]
        for text in texts {
            let norm = TextKeys.norm(text)
            for (name, list) in lists {
                #expect(list.matches(in: norm) == DateWords.contains(norm, list.phrases), "\(name): \(text)")
            }
        }
    }
}
