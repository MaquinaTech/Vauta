// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The words of an Ask answer agree with its shape: `found` true is never an answer that says the material does not specify it, and
/// an answer that reached a length limit is flagged as cut short (a finished sentence, a quote that is not filler).
@Suite("Ask: found agrees with the prose, length cut-offs are flagged")
struct AskAnswerConsistencyTests {
    static let sent: [Int64: CitableSegment] = [
        12: CitableSegment(id: 12, channel: .others, start: 5, text: "We keep the budget as it is for this quarter"),
        13: CitableSegment(id: 13, channel: .me, start: 20, text: "Ana will send the numbers on Friday"),
    ]
    static let unverifiedClaim = #"{"text": "Budget", "citations": [12], "quote": "these words are not in the material at all"}"#
    static let claim = #"{"text": "Budget kept", "citations": [12], "quote": "keep the budget as it is"}"#

    static func reply(found: String = "true", _ answer: String, claims: [String] = [claim]) -> String {
        let escaped = answer.replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"found": \#(found), "answer": "\#(escaped)", "claims": [\#(claims.joined(separator: ","))]}"#
    }

    // MARK: found and the prose

    @Test(arguments: [
        "The material does not specify how many people attended.",
        "The meeting doesn't mention who is responsible for the budget. It is not specified either when it was approved.",
        "El material proporcionado no especifica cuántas personas asistieron a la sesión.",
        "No se menciona el monto. Tampoco se indica la fecha.",
        "Le document ne précise pas le montant du budget.",
        "Das Material nennt den Betrag nicht.",
        "Il materiale non specifica quante persone hanno partecipato.",
        "O material não menciona quem é o responsável.",
        "資料には予算の金額は言及されていません。",
        "자료에는 참석자 수가 언급되어 있지 않습니다.",
        "材料中没有提到预算的具体金额。",
    ])
    func foundTrueWithNoVerifiedClaimAndAnAbsenceIsARefusal(_ prose: String) throws {
        let a = try VautaPrompts.verifyAnswer(Self.reply(prose, claims: [Self.unverifiedClaim]), sent: Self.sent)
        #expect(!a.found && a.claims.isEmpty && a.answer.isEmpty && a.kind == .notFound, "\(prose)")
        #expect(!a.withheldAnAnswer)
    }

    /// With at least one verified claim a negative answer is never turned into a refusal, however the absence is worded.
    @Test(arguments: [
        "The material does not specify how many people attended.",
        "The budget amount was not stated by the vendor.",
        "No, the vendor's price is not indicated in the contract.",
        "Nein, ein Termin ist nicht festgelegt.",
        "No se menciona el monto. Tampoco se indica la fecha.",
        "Le document ne précise pas le montant du budget.",
        "Il materiale non specifica quante persone hanno partecipato.",
        "O material não menciona quem é o responsável.",
        "資料には予算の金額は言及されていません。",
        "자료에는 참석자 수가 언급되어 있지 않습니다.",
        "材料中没有提到预算的具体金额。",
    ])
    func aVerifiedClaimIsNeverTurnedIntoARefusal(_ prose: String) throws {
        let a = try VautaPrompts.verifyAnswer(Self.reply(prose), sent: Self.sent)
        #expect(a.found && a.hasEvidence && a.claims.count == 1 && a.claims[0].verified && a.answer == prose.trimmingCharacters(in: .whitespaces), "\(prose)")
    }

    @Test func foundWithZeroOfTwoVerifiedClaimsAndAnAbsenceIsARefusal() throws {
        let other = #"{"text": "Date", "citations": [13], "quote": "an invented quote that nobody said"}"#
        let a = try VautaPrompts.verifyAnswer(Self.reply("The date is not specified.", claims: [Self.unverifiedClaim, other]), sent: Self.sent)
        #expect(!a.found && a.kind == .notFound)
    }

    @Test(arguments: [
        "The budget stays as it is. The amount of the Kobaltix line is not specified.",
        "Although the exact value is not mentioned, the participants agreed to keep the budget.",
        "El presupuesto se mantiene, aunque no se especifica el monto.",
        "No se menciona el monto, pero se acordó mantener el presupuesto.",
        "The material does not say who approved it, but it was sent to the committee.",
        "The material does not say who approved it: it only says it was sent on.",
        "Ana will send the numbers on Friday.",
        "The budget stays; nothing is said about the date.",
    ])
    func aPartialOrPositiveAnswerStaysFound(_ prose: String) throws {
        let a = try VautaPrompts.verifyAnswer(Self.reply(prose), sent: Self.sent)
        #expect(a.found && a.hasEvidence && a.claims.count == 1, "\(prose)")
        #expect(!a.cutShort || prose.isEmpty)
    }

    /// Ordinary negative facts, said in the meeting and backed by a quote that was found, are answers in the nine languages.
    @Test(arguments: [
        "No, the client did not provide the files.",
        "The vendor didn't give a date, so the launch moves to the third quarter.",
        "Ana said the new plan is not clear to the team.",
        "The budget does not include travel.",
        "He was not given the contract.",
        "The budget was not given to marketing.",
        "The vendor did not mention a date for the launch.",
        "Pedro no sabe si podrá venir el lunes.",
        "El proveedor no da garantía para las baterías.",
        "El presupuesto no incluye viajes.",
        "Pedro no menciona la fecha del lanzamiento.",
        "Non, le client n'a pas donné son accord.",
        "Le fournisseur ne mentionne pas la date du lancement.",
        "Sie geben das Projekt nicht auf.",
        "Der Lieferant nennt das Datum nicht.",
        "No, il cliente non ha dato l'approvazione.",
        "Il fornitore non menziona la data del lancio.",
        "Não, o cliente não deu a aprovação.",
        "O fornecedor não menciona a data do lançamento.",
        "いいえ、顧客は承認を出していません。",
        "아니요, 고객은 승인을 주지 않았습니다.",
        "不是，客户没有给出批准。",
        "供应商没有提到发布日期。",
    ])
    func aNegativeFactWithAVerifiedQuoteStaysFound(_ prose: String) throws {
        let a = try VautaPrompts.verifyAnswer(Self.reply(prose), sent: Self.sent)
        #expect(a.found && a.hasEvidence && a.claims.count == 1 && a.claims[0].verified, "\(prose)")
    }

    @Test(arguments: [
        "The exact date is not specified, only that it is next week.",
        "La fecha exacta no se menciona, solo que será en marzo.",
        "Le montant n'est pas précisé, seulement qu'il est élevé.",
        "Das Datum ist nicht angegeben, nur dass es nächste Woche ist.",
        "La data non è specificata, soltanto che è la prossima settimana.",
        "A data não é mencionada, somente que será em março.",
        "金額は言及されていませんが、来週だとだけ述べられています。",
        "날짜는 언급되어 있지 않고 다만 다음 주라고만 나와 있습니다。",
        "没有提到具体日期，只是说下周。",
    ])
    func aPartialAnswerJoinedWithOnlyStaysFound(_ prose: String) throws {
        let a = try VautaPrompts.verifyAnswer(Self.reply(prose), sent: Self.sent)
        #expect(a.found && a.hasEvidence, "\(prose)")
    }

    @Test func aSpeechVerbAbsenceIsARefusalOnlyWhenNoQuoteWasFound() throws {
        let unverifiedClaim = #"{"text": "Budget", "citations": [12], "quote": "these words are not in the material at all"}"#
        let prose = "The vendor did not mention a date for the launch."
        let a = try VautaPrompts.verifyAnswer(Self.reply(prose, claims: [unverifiedClaim]), sent: Self.sent)
        #expect(!a.found && a.kind == .notFound)
        #expect(try VautaPrompts.verifyAnswer(Self.reply(prose), sent: Self.sent).found)
    }

    @Test func theRulesTellTheModelNotToAnswerFoundWithAnAbsence() {
        for laterGuard in [false, true] {
            let rules = VautaPrompts.askRulesBody(documents: false, live: false, laterGuard: laterGuard)
            #expect(rules.contains("does not specify, mention or say it is a refusal"))
            #expect(rules.contains(laterGuard ? #""found" is "no""# : #""found" is false"#))
        }
    }

    // MARK: Length cut-offs

    @Test func aDegenerateQuoteIsNeverACitation() throws {
        for filler in ["........", "...", ". . . .", "…", "—-—-—-", "  "] {
            let json = #"{"found": true, "answer": "The budget stays as it is for this quarter.", "claims": [{"text": "Budget kept", "citations": [12], "quote": "\#(filler)"}]}"#
            let a = try VautaPrompts.verifyAnswer(json, sent: Self.sent, keepCutAnswer: true)
            #expect(a.found && a.claims.isEmpty && a.cutShort && a.isUnverified, "\(filler)")
            #expect(throws: LLMError.self, "\(filler)") { try VautaPrompts.verifyAnswer(json, sent: Self.sent) }
        }
        // The same filler as the sentence of a claim.
        let text = #"{"found": true, "answer": "Stays.", "claims": [{"text": "........", "citations": [12], "quote": "keep the budget as it is"}]}"#
        let b = try VautaPrompts.verifyAnswer(text, sent: Self.sent, keepCutAnswer: true)
        #expect(b.claims.isEmpty && b.cutShort && b.isUnverified)
        #expect(throws: LLMError.self) { try VautaPrompts.verifyAnswer(text, sent: Self.sent) }
    }

    @Test func aFinishedClaimDoesNotHideACutOneAfterIt() throws {
        let cut = #"{"text": "Ana sends...", "citations": [13], "quote": "........"}"#
        let json = Self.reply("The budget stays and Ana sends the numbers.", claims: [Self.claim, cut])
        let a = try VautaPrompts.verifyAnswer(json, sent: Self.sent, keepCutAnswer: true)
        #expect(a.found && a.hasEvidence && a.claims.count == 1 && a.cutShort && a.endsIncomplete)
        #expect(a.kind == .verified, "the quote that was finished is verified; the note says the text may be incomplete")
        // Without the integrated model's flag nothing changes.
        #expect(try !VautaPrompts.verifyAnswer(json, sent: Self.sent).cutShort)
    }

    @Test func aLongAnswerThatStopsInTheMiddleOfASentenceIsCutShort() throws {
        let sentence = "The team reviewed the Kobaltix budget for the quarter and agreed that it stays as it is. "
        let whole = String(repeating: sentence, count: 5)
        let stopped = whole + "Ana will send the numbers on Friday as soon as the review goes bien en"
        let a = try VautaPrompts.verifyAnswer(Self.reply(stopped), sent: Self.sent, keepCutAnswer: true, answerCapBytes: 500)
        #expect(a.found && a.cutShort && a.endsIncomplete && a.kind == .verified)
        // The same text is far from the cap of a non-live answer: it finished.
        #expect(try !VautaPrompts.verifyAnswer(Self.reply(stopped), sent: Self.sent, keepCutAnswer: true).cutShort)
        // A long answer that ends on a figure, a percent sign or a list item without a stop finished when it is nowhere near the cap.
        let figures = String(repeating: sentence, count: 3) + "The total cost of the quarter is 5.000 €"
        #expect(try !VautaPrompts.verifyAnswer(Self.reply(figures), sent: Self.sent, keepCutAnswer: true).cutShort)
        let ended = try VautaPrompts.verifyAnswer(Self.reply(whole), sent: Self.sent, keepCutAnswer: true)
        #expect(!ended.cutShort, "a finished sentence is not cut short")
        // Short answers without a full stop (a figure, a name) are not judged, and other backends are not asked.
        #expect(try !VautaPrompts.verifyAnswer(Self.reply("The budget is 5000"), sent: Self.sent, keepCutAnswer: true).cutShort)
        #expect(try !VautaPrompts.verifyAnswer(Self.reply(stopped), sent: Self.sent).cutShort)
    }

    /// A Latin-script after-meeting answer reaches 90% of its 3000-byte cap well above the 2000 characters the shown text is clipped to.
    @Test func anAnswerLongerThanTheClipStillMeetsTheByteCheck() throws {
        let sentence = "The team reviewed the Kobaltix budget for the quarter and agreed that it stays as it is. "
        let stopped = String(repeating: sentence, count: 31) + "Ana will send the numbers on Friday as soon as the review goes bien en"
        #expect(stopped.utf8.count > 2_700 && stopped.utf8.count < 3_000)
        let a = try VautaPrompts.verifyAnswer(Self.reply(stopped), sent: Self.sent, keepCutAnswer: true)
        #expect(a.found && a.cutShort && a.endsIncomplete)
        let finished = String(repeating: sentence, count: 31)
        #expect(try !VautaPrompts.verifyAnswer(Self.reply(finished), sent: Self.sent, keepCutAnswer: true).cutShort)
    }

    @Test func theCopiedAnswerCarriesTheIncompleteNote() throws {
        let note = "The answer reached its length limit, so its last sentence may be incomplete."
        let cut = try VautaPrompts.verifyAnswer(Self.reply("Stays."), sent: Self.sent).markedCutShort()
        let export = AnswerExport(question: "Q?", answer: cut, endsIncompleteNote: note, source: { _ in "0:10" })
        #expect(export.markdown().contains(note) && export.plainText().contains(note))
        #expect(String(decoding: export.json(), as: UTF8.self).contains("\"incompleteNote\""))
        let whole = AnswerExport(question: "Q?", answer: try VautaPrompts.verifyAnswer(Self.reply("Stays."), sent: Self.sent), endsIncompleteNote: note, source: { _ in "0:10" })
        #expect(!whole.markdown().contains(note) && !String(decoding: whole.json(), as: UTF8.self).contains("incompleteNote"))
    }

    @Test func aCutShortAnswerWithoutCheckedClaimsIsShownAsCutShort() throws {
        let a = VerifiedAnswer(answer: "x", claims: [], found: true, cutShort: true)
        #expect(a.kind == .cutShort && !a.endsIncomplete)
        let verified = try VautaPrompts.verifyAnswer(Self.reply("Stays."), sent: Self.sent).markedCutShort()
        #expect(verified.kind == .verified && verified.cutShort && verified.endsIncomplete)
        #expect(VerifiedAnswer(answer: "", claims: [], found: false).markedCutShort().cutShort == false, "a refusal is not cut short")
    }

    @Test func aLengthLimitOnTheIntegratedModelFlagsTheAnswer() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["We reviewed the Kobaltix budget for the quarter", "Fine, we keep the budget as it is",
                                      "Ana will send the numbers on Friday"], locale: "en-US", outputLocale: "en-US")
        let segment = try #require(try await f.store.citableSegments(id).first { $0.text.contains("keep the budget") })
        let json = #"{"found": true, "answer": "The budget stays as it is for this quarter.", "claims": [{"text": "Budget kept", "citations": [\#(segment.id)], "quote": "keep the budget as it is"}]}"#
        for (finish, flagged) in [(FinishReason.length, true), (.stop, false)] {
            let chat = ScriptedChat { _, _, _ in ScriptedChat.reply(json, finish: finish) }
            let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
            let result = try await service.ask("What did we decide about the Kobaltix budget?", meetingID: id)
            #expect(result.answer.found && result.answer.hasEvidence && result.answer.cutShort == flagged, "\(finish)")
        }
    }
}
