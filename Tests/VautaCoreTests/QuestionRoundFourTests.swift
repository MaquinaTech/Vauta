// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// What the first evaluation of live answers found, as tests: long Spanish segments, the opinion penalty, the check's prompt and
/// reply, the lines after a question, non-answers, the embedding limit and the defaults per backend.
@Suite("Live answers: findings of the first evaluation")
struct QuestionRoundFourTests {
    // MARK: S1

    static let monologue = "Señor presidente, yo quiero dejar constancia de que el expediente llegó a esta comisión sin los informes técnicos que correspondían "
        + "y sin que nadie lo hubiera advertido durante la reunión anterior, por lo que le pregunto cuándo se va a presentar el informe del área de hacienda sobre el presupuesto? "
        + "Además, quiero agregar que el resto de los puntos del orden del día se votaron sin discusión."

    @Test func aLongSegmentWithAQuestionInsideIsCutToTheClauseThatAsks() throws {
        let found = QuestionCues.scored(text: Self.monologue, channel: .others, start: 0, end: 20, previous: nil, meetingLocale: "es-ES")
        let asking = try #require(found.first { $0.cues.contains("mark") })
        #expect(asking.text.count <= QuestionCues.maxCandidateCharacters)
        #expect(asking.text.hasSuffix("?") && asking.text.contains("informe del área de hacienda"))
        #expect(!asking.text.contains("Señor presidente"), "the start of the speech is not the question")
        #expect(found.allSatisfy { $0.text.count <= QuestionCues.maxCandidateCharacters || !$0.cues.contains("mark") })
    }

    @Test func aShortSentenceAndAnOpeningMarkAreLeftAlone() {
        let text = "¿Cuándo se presenta el informe?"
        #expect(QuestionCues.focus(text) == text)
        let long = "Ayer revisamos todo el expediente con calma y sin prisa, y antes de cerrar la sesión quiero preguntar a todos los presentes, ¿cuándo se presenta el informe de la auditoría externa sobre las cuentas de dos mil veinte, que todavía no tenemos?"
        let focused = QuestionCues.focus(long)
        #expect(focused.hasPrefix("¿cuándo") && focused.hasSuffix("?") && focused.count <= QuestionCues.maxCandidateCharacters)
    }

    @Test func aShortRewriteWithNoMarkIsJudgedInTheMeetingsLanguage() throws {
        for (text, language) in [("Cuánto costó la obra", CueLanguage.es), ("Quanto costa il lavoro", .it)] {
            let reply = #"{"kind": "information", "question": "\#(text)", "answered_aloud": false}"#
            let check = try #require(QuestionCheck.parse(reply, language: language))
            #expect(check.question == text)
        }
    }

    @Test func aVeryShortRewriteWithNoMarkIsStillAQuestion() throws {
        for (text, language) in [("Quién lo firmó", CueLanguage.es), ("Wann ist Abgabe", .de), ("Cuánto costó", .es)] {
            let reply = #"{"kind": "information", "question": "\#(text)", "answered_aloud": false}"#
            let check = try #require(QuestionCheck.parse(reply, language: language))
            #expect(check.question == text, "\(text)")
        }
    }

    @Test func aDescriptionThatQuotesAQuestionIsNotAQuestion() throws {
        for text in [#"The speaker asks "how much did it cost?""#, "El hablante pregunta: ¿cuánto costó?", "The speaker is asking what it cost."] {
            let reply = #"{"kind": "information", "question": "\#(text.replacingOccurrences(of: "\"", with: "\\\""))", "answered_aloud": false}"#
            let check = try #require(QuestionCheck.parse(reply, language: nil))
            #expect(check.question.isEmpty, "\(text)")
        }
    }

    @Test func aLongUnpunctuatedMonologueKeepsTheClauseThatSaysIPutTheQuestion() {
        let long = "Señor presidente, ayer revisamos todo el expediente con calma y sin prisa y hablamos de la obra de la plaza y de los vecinos del barrio norte y de los comerciantes de la zona, por lo que le pregunto cuándo se va a presentar el informe de la auditoría externa"
        let focused = QuestionCues.focus(long, main: .es)
        #expect(focused.contains("le pregunto cuándo") && focused.count <= QuestionCues.maxCandidateCharacters, "\(focused)")
    }

    @Test func aLongSentenceWithNoMarkKeepsTheClauseWithALateQuestionCue() {
        let long = "Ayer revisamos todo el expediente con calma y sin prisa y hablamos de la obra de la plaza y de los vecinos del barrio norte y de los comerciantes de la zona, y me pregunto cuándo se va a presentar el informe de la auditoría externa"
        let focused = QuestionCues.focus(long, main: .es)
        #expect(focused.hasPrefix("y me pregunto") && focused.count <= QuestionCues.maxCandidateCharacters)
        let found = QuestionCues.scored(text: long, channel: .others, start: 0, end: 20, previous: nil, meetingLocale: "es")
        #expect(found.contains { $0.cues.contains("embedded") || $0.cues.contains("interrogative") })
    }

    @Test func aLongSentenceWithNoMarkKeepsItsBeginning() {
        let long = "Cuánto costó la obra de la plaza central según el informe que presentó la empresa constructora en la reunión de la semana pasada con todos los vecinos y las vecinas del barrio y los comerciantes de la zona norte de la ciudad"
        let focused = QuestionCues.focus(long)
        #expect(focused.hasPrefix("Cuánto costó la obra") && focused.count <= QuestionCues.maxCandidateCharacters)
    }

    @Test func aQuestionThatAsksForAnOpinionDoesNotReachTheStandardThreshold() {
        for text in ["What do you think about the new pricing for the second quarter?", "¿Qué opináis del presupuesto para el segundo trimestre?"] {
            let best = QuestionCues.best(text: text, channel: .others, start: 0, end: 3, previous: nil, meetingLocale: text.hasPrefix("¿") ? "es-ES" : "en-US")
            #expect(best.map { !QuestionCues.isCandidate($0, sensitivity: .standard) } == true, "\(text) \(String(describing: best?.score)) \(String(describing: best?.cues))")
            #expect(best.map { QuestionCues.isCandidate($0, sensitivity: .high) } == true, "More answers still checks it")
        }
        let fact = QuestionCues.best(text: "What was the budget we agreed for the second quarter?", channel: .others, start: 0, end: 3, previous: nil, meetingLocale: "en-US")
        #expect(fact.map { QuestionCues.isCandidate($0, sensitivity: .standard) } == true)
    }

    // MARK: S5

    @Test(arguments: [
        #"{"kind": "information", "question": "The marked line asks about incorporating the company logo.", "answered_aloud": false}"#,
        #"{"kind": "information", "question": "The speaker wants to know the budget.", "answered_aloud": false}"#,
        #"{"kind": "information", "question": "El hablante pregunta por el presupuesto del proyecto.", "answered_aloud": false}"#,
    ])
    func aRewriteThatIsNotAQuestionIsDropped(reply: String) throws {
        let check = try #require(QuestionCheck.parse(reply))
        #expect(check.kind == .information && check.question.isEmpty && !check.proceeds(hideWhenAnsweredAloud: false))
    }

    @Test(arguments: [
        #"{"kind": "information", "question": "¿Cuánto costó la obra de la plaza?", "answered_aloud": false}"#,
        #"{"kind": "information", "question": "Cuánto costó la obra de la plaza central", "answered_aloud": false}"#,
        #"{"kind": "information", "question": "What is the budget for the project?", "answered_aloud": false}"#,
        #"{"kind": "information", "question": "What was the budget for the project", "answered_aloud": false}"#,
    ])
    func aRewriteThatIsAQuestionIsKept(reply: String) throws {
        let check = try #require(QuestionCheck.parse(reply))
        #expect(!check.question.isEmpty && check.proceeds(hideWhenAnsweredAloud: false), "\(check)")
    }

    @Test func anEmptyRewriteMeansTheSentenceStandsAloneButOnlyForAnInformationQuestion() throws {
        let info = try #require(QuestionCheck.parse(#"{"kind": "information", "question": "", "answered_aloud": false}"#, candidate: "What was the budget for the project?"))
        #expect(info.question == "What was the budget for the project?" && info.proceeds(hideWhenAnsweredAloud: true))
        let opinion = try #require(QuestionCheck.parse(#"{"kind": "opinion", "question": "", "answered_aloud": false}"#, candidate: "What do you think?"))
        #expect(opinion.question.isEmpty)
        let noCandidate = try #require(QuestionCheck.parse(#"{"kind": "information", "question": "", "answered_aloud": false}"#))
        #expect(!noCandidate.proceeds(hideWhenAnsweredAloud: false))
        let notAQuestion = try #require(QuestionCheck.parse(#"{"kind": "information", "question": "", "answered_aloud": false}"#, candidate: "We agreed on the budget."))
        #expect(!notAQuestion.proceeds(hideWhenAnsweredAloud: false), "a candidate that does not read as a question is not looked up")
    }

    @Test func thePromptTeachesTheCasesThatWereMissedInBothLanguages() {
        let text = QuestionCheck.instruction(for: QuestionCheckTests.settled("What would single curved mean?", before: ["a", "b", "c"], after: ["x", "y", "z"]))
        #expect(text.contains("What would X mean?") && text.contains("How is X organised?") && text.contains("are information"))
        #expect(text.contains("3 lines before") && text.contains("repeats or confirms"), "echo questions are answered aloud")
        #expect(text.contains("Never describe") && text.contains("stands alone"))
        #expect(text.contains("¿Cuánto costó la obra?") && text.contains("¿Qué significa doble curvatura?") && text.contains("¿Qué os parece?"))
        for line in ["[11:40", "[11:41", "[11:42"] { #expect(text.contains(line)) }
        let compact = QuestionCheck.instruction(for: QuestionCheckTests.settled("What would single curved mean?", after: ["x"]), compact: true)
        #expect(compact.contains("¿Cuánto costó la obra?") && compact.contains("3 lines before") && compact.contains("is still a question") && compact.count < text.count)
        let after = QuestionCheck.instruction(for: QuestionCheckTests.settled("What would single curved mean?", after: ["x", "y", "z"]), afterOnly: true)
        #expect(after.contains("The transcript above holds the lines before it."))
    }

    @Test func theChecksOutputRoomHoldsAWholeReplyOnEveryBackend() {
        #expect(LLMService.checkOtherTokens >= 160, "Apple's 96 tokens cut 63 replies in the first replay")
        #expect(LLMService.checkGemmaTokens <= 160)
        // A kind, a 160-character Spanish rewrite and the flag: about a hundred tokens at 2.5 characters a token.
        let reply = #"{"kind": "information", "question": "\#(String(repeating: "ñ", count: 160))?", "answered_aloud": false}"#
        let tokens = Int((Double(reply.count) / 2.5).rounded(.up))
        #expect(tokens < LLMService.checkOtherTokens)
        // The integrated model's grammar keeps 64 tokens back to close the JSON: the reply must fit in what is left.
        #expect(tokens <= LLMService.checkGemmaTokens - 64, "the whole reply fits the integrated model's budget")
        // The grammar's byte cap holds the longest rewrite in any script inside the 96 tokens of text: Latin at 2.5 characters a token,
        // Japanese, Korean and Chinese at one character (three bytes) a token, an estimate, not the tokenizer.
        let cap = QuestionCheck.maxQuestionBytes
        #expect(Int((Double(cap) / 2.5).rounded(.up)) <= LLMService.checkGemmaTokens - 64)
        #expect(cap / 3 <= LLMService.checkGemmaTokens - 64)
        #expect(cap >= QuestionCheck.maxQuestionCharacters, "a 160-character Latin rewrite still fits")
    }

    // MARK: The lines after the question

    @Test func theCheckReadsTheLinesThatCameInWhileTheQuestionWaited() {
        let q = QuestionCheckTests.settled("What was the budget?", before: ["a"], after: ["one"])
        let heard = [q.line] + ["one", "two", "three", "four"].enumerated().map { QuestionLine(segmentID: Int64(20 + $0.offset), channel: .me, start: 730 + Double($0.offset), end: 731 + Double($0.offset), text: $0.element) }
        let read = q.reading(after: heard, limit: 3)
        #expect(read.after.map(\.text) == ["one", "two", "three"], "up to three, in order")
        #expect(q.reading(after: [q.line, heard[1]], limit: 3).after.map(\.text) == ["one"], "never fewer than it settled with")
        #expect(q.reading(after: [], limit: 3) == q, "a line the buffer no longer has leaves it as it was")
    }

    @Test func theDetectorGivesTheCheckTheLinesAfterTheQuestionEvenWhenTheyCameLate() async throws {
        let backend = FakeAnswerBackend()
        backend.check = .checked(QuestionCheck(kind: .notQuestion, question: "", answeredAloud: false))
        var timing = QuestionDetectorTests.fast
        timing.settle = 0.05
        let r = try await QuestionDetectorTests.rig(timing: timing, backend: backend)
        await QuestionDetectorTests.ask(r, "What was the budget we agreed for the second quarter?", at: 700)
        for (i, text) in ["Hmm.", "Let me think.", "Fifty thousand.", "Yes."].enumerated() {
            await r.detector.ingest(QuestionLine(segmentID: Int64(2 + i), channel: .me, start: 704 + Double(i), end: 705 + Double(i), text: text))
        }
        #expect(await settle { !backend.checked.isEmpty })
        let question = try #require(backend.checked.first)
        #expect(question.after.count == 3 && question.after.map(\.text).contains("Fifty thousand."))
        await r.detector.stop()
    }

    // MARK: Answers that say nothing

    @Test func anAnswerThatRepeatsTheQuestionOrOnlyHedgesIsNotAnAnswer() {
        let asked = ["So Bruno is not on the project and he's sharing an office?"]
        #expect(AnswerQuality.repeats("Bruno is not on the project and he's sharing an office", questions: asked, locale: "en"))
        #expect(!AnswerQuality.repeats("Yes, they share an office.", questions: asked, locale: "en"))
        #expect(!AnswerQuality.repeats("Pilot", questions: ["What was the pilot budget?"], locale: "en"), "a label is too short to repeat anything")
        #expect(AnswerQuality.isVague("There might be something else, but it was not fully discussed."))
        #expect(AnswerQuality.isVague("No queda claro cuándo se vota, quizás el martes."))
        #expect(!AnswerQuality.isVague("The budget is fifty thousand euros."))
        #expect(!AnswerQuality.isVague("El presupuesto final fue algo más de 40.000 euros."))
        #expect(!AnswerQuality.isVague("O orçamento foi algo mais de 3 mil euros."))
        #expect(!AnswerQuality.isVague("Se aprobó el presupuesto de la obra."))
        for text in ["They chose something else: the steel frame, at 40,000 euros.", "The contract is not clear on dates; the deadline agreed was 3 March.",
                     "It was not clear until the vendor confirmed 3 sites.", "Le paiement peut être fait en deux fois en mars.",
                     "Puede haber hasta 20 asistentes.", "Pode haver até 20 participantes.", "Ils ont choisi autre chose : la charpente, à 40 000 euros.",
                     "Sie wählten etwas anderes: den Stahlbau für 40.000 Euro."] {
            #expect(!AnswerQuality.isVague(text), "\(text)")
        }
    }

    @Test func aVerifiedAnswerThatRepeatsTheQuestionIsNoAnswer() async throws {
        let ids = Locked<[Int64]>([])
        let r = try await AutoAnswerTests.rig(lines: AutoAnswerTests.withQuestion) { _, _, _ in
            ScriptedChat.reply(AutoAnswerTests.reply([("We reviewed the Kobaltix budget for the quarter", ids.withLock { $0[0] }, "We reviewed the Kobaltix budget")]))
        }
        ids.withLock { $0 = [r.segments[0].id] }
        let request = AutoAskRequest(segmentID: r.segments[2].id, sources: .all, heard: ["Did we review the Kobaltix budget for the quarter?"])
        let outcome = try await r.service.autoAnswer("Did we review the Kobaltix budget for the quarter?", meetingID: r.meeting, request: request)
        #expect(outcome == .noAnswer)
    }

    @Test func aVerifiedHedgeIsNoAnswer() async throws {
        let ids = Locked<[Int64]>([])
        let r = try await AutoAnswerTests.rig(lines: AutoAnswerTests.withQuestion) { _, _, _ in
            ScriptedChat.reply(AutoAnswerTests.reply([("There might be something else that was not fully discussed.", ids.withLock { $0[0] }, "we keep the budget as it is")]))
        }
        ids.withLock { $0 = [r.segments[1].id] }
        let outcome = try await r.service.autoAnswer("Did we keep the budget?", meetingID: r.meeting, request: AutoAskRequest(segmentID: r.segments[2].id, sources: .all))
        #expect(outcome == .noAnswer)
    }

    @Test func anAnswerThatCitesOnlyTheQuestionsOwnLineIsNeverShown() async throws {
        let ids = Locked<[Int64]>([])
        let r = try await AutoAnswerTests.rig(lines: AutoAnswerTests.withQuestion) { _, _, _ in
            ScriptedChat.reply(AutoAnswerTests.reply([("Kept", ids.withLock { $0[0] }, "Did we keep the budget?")], answer: "The budget was kept."))
        }
        ids.withLock { $0 = [r.segments[2].id] }
        let outcome = try await r.service.autoAnswer("Did we keep the budget?", meetingID: r.meeting,
                                                     request: AutoAskRequest(segmentID: r.segments[2].id, questionSegments: [r.segments[2].id], sources: .all))
        #expect(outcome == .noAnswer)
    }

    // MARK: Embeddings, heat, defaults

    @Test func theSearchModelEmbedsAtMostEmbedMaxQuestionsPerWindow() async throws {
        var timing = QuestionDetectorTests.fast
        timing.embedMax = 2
        timing.checkInterval = 0.01
        timing.checkWindow = 3_600
        timing.dedupWindow = 3_600
        let backend = FakeAnswerBackend()
        backend.queryVector = [1, 0]
        let r = try await QuestionDetectorTests.rig(timing: timing, backend: backend)
        let questions = ["Who is responsible for the vendor contract?", "When is the deadline for the design review?", "How much did the Berlin pilot cost us last year?", "Where will the next offsite be held?"]
        for (i, text) in questions.enumerated() {
            await QuestionDetectorTests.ask(r, text, at: 700 + Double(i) * 20, segment: Int64(i + 1))
            #expect(await settle { r.backend.evidenceCalls == i + 1 })
        }
        #expect(backend.embedFlags == [true, true, false, false])
        await r.detector.stop()
    }

    @Test func limiterCountsEmbeddingsInTheWindowOnly() {
        var t = QuestionTiming()
        t.embedMax = 2
        t.checkWindow = 100
        var limiter = QuestionLimiter(timing: t)
        limiter.recordEmbed(now: 0); limiter.recordEmbed(now: 10)
        #expect(!limiter.embedAllowed(now: 20) && limiter.embedAllowed(now: 105) && limiter.embedAllowed(now: 111))
    }

    @Test func noBackendStartsOnUntilTheMeasurementSaysItPasses() {
        #expect(LiveAnswerBackendKind.allCases.allSatisfy { !LiveAnswerDefaults.onByDefault($0) && LiveAnswerDefaults.verdicts[$0] != nil })
        #expect(!LiveAnswerDefaults.onByDefault(nil), "a model that is not known yet: off")
        #expect(LiveAnswerDefaults.verdicts[.server]?.note.hasPrefix("not measured") == true, "the server was never measured: off")
        #expect(LiveAnswerDefaults.verdicts[.apple]?.note.contains("fails the D12 gates") == true)
        #expect(LiveAnswerDefaults.verdicts[.apple]?.note.hasPrefix("not offered") == true, "Apple's verdict says why it is not offered")
        #expect(LiveAnswerDefaults.verdicts[.apple]?.offered == false && LiveAnswerDefaults.verdicts[.server]?.offered == true && LiveAnswerDefaults.verdicts[.integrated]?.offered == true)
        #expect(!LiveAnswerDefaults.offered(.apple) && LiveAnswerDefaults.offered(.server) && LiveAnswerDefaults.offered(.integrated) && LiveAnswerDefaults.offered(nil))
        #expect(LiveAnswerDefaults.verdicts[.integrated]?.note.contains("fails the D12 gates") == true)
        #expect(LiveAnswerBackendKind.current(chat: .onDevice, liveTasks: .integrated) == .apple)
        #expect(LiveAnswerBackendKind.current(chat: .server, liveTasks: .integrated) == .server)
        #expect(LiveAnswerBackendKind.current(chat: .integrated, liveTasks: .integrated) == .integrated)
        #expect(LiveAnswerBackendKind.current(chat: .integrated, liveTasks: .apple) == .apple, "the live tasks go to Apple's model")
    }
}

@Suite struct ClaimProseTests {
    @Test func claimsAreJoinedWithASpaceExceptAfterCJKPunctuation() {
        #expect(ClaimProse.join(["First.", "Second."]) == "First. Second.")
        #expect(ClaimProse.join(["最初のベータは28日です。", "次は来月です。"]) == "最初のベータは28日です。次は来月です。")
        #expect(ClaimProse.join(["28日のままです", "次は"]) == "28日のままです。次は")
        #expect(ClaimProse.join(["Reciben el portátil el primer día", "La beta sigue el 28"]) == "Reciben el portátil el primer día. La beta sigue el 28")
        #expect(ClaimProse.join(["Is it Tuesday?", "Yes", "He said “ok”"]) == "Is it Tuesday? Yes. He said “ok”")
        #expect(ClaimProse.join(["ベータは28日", "次は来月です。"]) == "ベータは28日。次は来月です。")
        #expect(ClaimProse.join(["Single claim without a stop"]) == "Single claim without a stop")
        #expect(ClaimProse.join([]) == "")
    }
}
