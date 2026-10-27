// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The checks of the minutes' open questions: no model, no network.
@Suite("Minutes: open questions")
struct OpenQuestionChecksTests {
    private static func segments(_ lines: [String]) -> [CitableSegment] {
        lines.enumerated().map { CitableSegment(id: Int64($0.offset + 1), channel: .others, start: Double($0.offset) * 10, text: $0.element) }
    }

    private static let transcript = segments([
        "Should we quickly look at the last slide?",
        "The remote will use a kinetic power supply.",
        "We still have to see who pays for the extra audio buttons.",
    ])

    private static func minutes(_ questions: [String], decisions: [String] = [], topics: [String] = []) -> ValidatedMinutes {
        var m = ValidatedMinutes()
        m.openQuestions = questions
        m.topics = topics
        m.decisions = decisions.enumerated().map { ValidatedMinutes.Item(text: $0.element, segment: Int64($0.offset + 1), t: 0, unconfirmed: false, quote: "") }
        return m
    }

    private static func run(_ m: ValidatedMinutes, integrated: Bool = false, _ parts: MinutesQuestions = .shipped) -> ValidatedMinutes {
        OpenQuestionChecks.apply(m, segments: transcript, integrated: integrated, parts: parts)
    }

    @Test func theSwitchParsesAndNamesItsParts() {
        #expect(MinutesQuestions.parse("old") == .legacy && MinutesQuestions.parse("new") == .shipped)
        #expect(MinutesQuestions.parse("copy,cap") == [.copy, .cap] && MinutesQuestions.parse("checks") == .checks)
        #expect(MinutesQuestions.parse("new,lines") == .shipped && MinutesQuestions.parse("new,digest,cap") == MinutesQuestions.shipped.union([.digest, .cap]) && MinutesQuestions.parse("nonsense") == nil)
        #expect(MinutesQuestions.legacy.names == "legacy" && MinutesQuestions.shipped.names == "form+copy+topic+settled+repeats+generic+lines")
        #expect(!MinutesQuestions.shipped.contains(.cap) && !MinutesQuestions.shipped.contains(.digest))
        #expect(MinutesQuestionsRelease.questions(integrated: false) == .shipped && MinutesQuestionsRelease.questions(integrated: true) == .legacy,
                "Apple's model runs the checked open questions; the integrated model keeps the list it had")
    }

    @Test func aTranscriptLineCopiedAsItIsGoes() {
        let out = Self.run(Self.minutes(["Should we quickly look at the last slide?", "Who pays for the extra audio buttons on the remote?"]))
        #expect(out.openQuestions == ["Who pays for the extra audio buttons on the remote?"])
        #expect(out.counts["question.dropped.copy"] == 1)
    }

    @Test func aShortTextOrOneWithoutQuestionFormGoesForApple() {
        let out = Self.run(Self.minutes(["¿No? Se.", "The colour of the buttons", "What colour should the buttons be?", "Whether the logo goes on the front"]))
        #expect(out.openQuestions == ["What colour should the buttons be?", "Whether the logo goes on the front"])
        #expect(out.counts["question.dropped.short"] == 1 && out.counts["question.dropped.form"] == 1)
    }

    @Test func aShortRealQuestionPassesWhenItsWordsAreSaidInTheMeeting() {
        let questions = ["Who pays?", "Who signs?", "Pays?", "Who pays"]
        #expect(Self.run(Self.minutes(questions)).openQuestions.isEmpty, "off in the release: every text under four words goes")
        let out = Self.run(Self.minutes(questions), MinutesQuestions.shipped.union(.short))
        #expect(out.openQuestions == ["Who pays?"], "asked as a question with words the transcript says; \"Who signs?\" is about something nobody said")
        #expect(out.counts["question.dropped.short"] == 3)
    }

    @Test func theIntegratedModelMayWriteAStatementOfWhatIsUnresolved() {
        let statement = "The group needs to decide on the target group for the product."
        #expect(Self.run(Self.minutes([statement]), integrated: true).openQuestions == [statement])
        #expect(Self.run(Self.minutes([statement]), integrated: false).openQuestions == [statement], "the cue 'needs to decide' says it is open")
        #expect(Self.run(Self.minutes(["The target group of the product"]), integrated: true).openQuestions == ["The target group of the product"])
        #expect(Self.run(Self.minutes(["The target group of the product"]), integrated: false).openQuestions.isEmpty)
    }

    @Test func questionFormsAcrossLanguages() {
        let forms = ["¿Qué presupuesto se aprobará para el curso?", "Quel budget sera approuvé pour le cours ?", "Welches Budget wird für den Kurs genehmigt",
                     "Quale budget sarà approvato per il corso", "Qual orçamento será aprovado para o curso", "コースの予算は何ですか", "课程的预算是什么？", "이 과정의 예산은 무엇입니까"]
        for text in forms {
            #expect(OpenQuestionChecks.hasQuestionForm(text, words: OpenQuestionChecks.words(text)), "\(text)")
        }
        let statements = ["The budget of the course was reviewed by the board"]
        for text in statements { #expect(!OpenQuestionChecks.hasQuestionForm(text, words: OpenQuestionChecks.words(text))) }
    }

    @Test func aQuestionThatARestatedTopicOrADecisionAnswersGoes() {
        let m = Self.minutes(["What is the kinetic power supply for the remote?", "Who writes the user manual for the remote?"],
                             decisions: ["The remote will use a kinetic power supply"], topics: ["Kinetic power supply for the remote"])
        // Both checks on: the first question restates the topic and the decision.
        #expect(Self.run(m, integrated: true).openQuestions == ["Who writes the user manual for the remote?"])
        #expect(Self.run(m, integrated: true, [.topic]).openQuestions == ["Who writes the user manual for the remote?"])
        #expect(Self.run(m, integrated: true, [.settled]).openQuestions == ["Who writes the user manual for the remote?"])
        // Apple's decisions are not trusted to answer a question.
        let apple = Self.run(Self.minutes(["What is the kinetic power supply for the remote?"], decisions: ["The remote will use a kinetic power supply"]), integrated: false)
        #expect(apple.openQuestions.count == 1, "settled applies to the integrated model only")
    }

    @Test func aRepeatCollapsesAndStockQuestionsGo() {
        let out = Self.run(Self.minutes(["Who owns the packaging design for the remote?", "Who owns the packaging design for the remote casing?", "What are the next steps for the finder function?",
                                         "¿Qué implica la decisión sobre el cobro de las entradas?"]))
        #expect(out.openQuestions == ["Who owns the packaging design for the remote?"])
        #expect(out.counts["question.dropped.repeat"] == 1 && out.counts["question.dropped.generic"] == 2)
    }

    @Test func appleKeepsThreeAndTheAskedOnesComeFirst() {
        let questions = ["Who owns the first task of the remote project?", "Which supplier makes the casing of the remote?", "Whether the remote needs a battery cover",
                         "When does the team order the prototype parts?", "Where is the prototype tested by the users?"]
        let apple = Self.run(Self.minutes(questions), MinutesQuestions.shipped.union(.cap))
        #expect(apple.openQuestions.count == 3 && apple.counts["question.dropped.cap"] == 2)
        #expect(!apple.openQuestions.contains("Whether the remote needs a battery cover"), "the asked ones, with a question mark, come first")
        #expect(Self.run(Self.minutes(questions), integrated: true, MinutesQuestions.shipped.union(.cap)).openQuestions.count == 5, "the integrated model's list is not capped")
        #expect(Self.run(Self.minutes(questions)).openQuestions.count == 5, "cap is off in the shipped set")
        #expect(Self.run(Self.minutes(questions), .legacy).openQuestions == questions, "switched off, nothing changes")
    }

    @Test func theDigestAsksForTheBlocksOpenLinesOnlyWhenSwitchedOn() {
        var request = VautaPrompts.MinutesRequest(meetingDate: Date(timeIntervalSince1970: 1_104_537_600), language: OutputLanguage(Locale(identifier: "en-US")))
        let plain = VautaPrompts.digestInstruction(request).content
        #expect(plain.contains("up to 5 questions or issues left unresolved") && !plain.contains(#"lines of the notes"#))
        request.wording.openFromNotes = true
        for outcomes in [false, true] {
            let text = VautaPrompts.digestInstruction(request, outcomes: outcomes).content
            #expect(text.contains(#"copied word for word from the "Open" lines of the notes, at most 3"#) && !text.contains("up to 5 questions"), "outcomes: \(outcomes)")
        }
        request.wording.outcomeSummary = true
        #expect(VautaPrompts.digestInstruction(request).content.contains(#"at most 3"#))
    }

    @Test func theDigestShowsTheOpenQuestionsTheBlocksWroteAsObjects() {
        let extract = #"{"summary": "The group met.", "topics": [], "decisions": [], "tasks": [], "entities": [], "open_questions": [{"text": "Who pays for the audio buttons?", "seg": 3, "quote": "who pays"}, "Is the logo final?"]}"#
        let plain = MinutesDigest(extracts: [extract]).message(tokens: 2_000).content
        #expect(plain.contains("Open: Is the logo final?") && !plain.contains("audio buttons"), "as before, only the plain strings")
        let objects = MinutesDigest(extracts: [extract], openObjects: true).message(tokens: 2_000).content
        #expect(objects.contains("Open: Who pays for the audio buttons?; Is the logo final?"))
    }
}
