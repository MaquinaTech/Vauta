// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Live answers: question cues (S1)")
struct QuestionCuesTests {
    static func candidate(_ text: String, locale: String, previous: QuestionCues.Previous? = nil, start: Double = 100) -> QuestionCandidate? {
        QuestionCues.best(text: text, channel: .others, start: start, end: start + 4, previous: previous, meetingLocale: locale)
    }

    static func passes(_ text: String, locale: String, _ sensitivity: QuestionSensitivity) -> Bool {
        candidate(text, locale: locale).map { QuestionCues.isCandidate($0, sensitivity: sensitivity) } ?? false
    }

    @Test(arguments: CueGoldens.all.map(\.locale))
    func questionsWithAMarkAreCandidatesAtStandard(locale: String) throws {
        let golden = try #require(CueGoldens.all.first { $0.locale == locale })
        let missed = golden.asked.filter { !Self.passes($0, locale: locale, .standard) }
        #expect(missed.isEmpty, "missed: \(missed)")
    }

    @Test(arguments: CueGoldens.all.map(\.locale))
    func questionsWithoutAMarkAreCandidatesAtHigh(locale: String) throws {
        let golden = try #require(CueGoldens.all.first { $0.locale == locale })
        let missed = golden.unpunctuated.filter { !Self.passes($0, locale: locale, .high) }
        #expect(missed.isEmpty, "missed: \(missed)")
    }

    @Test(arguments: CueGoldens.all.map(\.locale))
    func statementsAreNotCandidatesAtStandard(locale: String) throws {
        let golden = try #require(CueGoldens.all.first { $0.locale == locale })
        let wrong = golden.statements.filter { Self.passes($0, locale: locale, .standard) }
        #expect(wrong.isEmpty, "wrongly kept: \(wrong)")
    }

    @Test(arguments: CueGoldens.all.map(\.locale))
    func tagsAudioChecksAndGreetingsAreNeverCandidatesAtStandard(locale: String) throws {
        let golden = try #require(CueGoldens.all.first { $0.locale == locale })
        let wrong = golden.chatter.filter { Self.passes($0, locale: locale, .standard) }
        #expect(wrong.isEmpty, "wrongly kept: \(wrong)")
    }

    @Test(arguments: CueGoldens.all.map(\.locale))
    func opinionsCarryTheOpinionPenalty(locale: String) throws {
        let golden = try #require(CueGoldens.all.first { $0.locale == locale })
        for sentence in golden.opinions {
            let c = try #require(Self.candidate(sentence, locale: locale))
            #expect(c.cues.contains("opinion"), "\(sentence) -> \(c.cues)")
        }
    }

    @Test func goldensHaveTheDesignSizeForEnglishAndSpanish() {
        for golden in [CueGoldens.english, CueGoldens.spanish] {
            #expect(golden.asked.count + golden.unpunctuated.count >= 25)
            #expect(golden.statements.count + golden.chatter.count >= 25)
        }
        #expect(CueGoldens.all.count == 9)
        #expect(Set(CueGoldens.all.compactMap { CueLanguage(identifier: $0.locale) }) == Set(CueLanguage.allCases))
    }

    // MARK: Sensitivity

    @Test func thresholdsFollowTheDesign() {
        #expect(QuestionSensitivity.low.threshold == 0.80)
        #expect(QuestionSensitivity.standard.threshold == 0.50)
        #expect(QuestionSensitivity.high.threshold == 0.35)
    }

    @Test func sensitivityOrdersTheCandidates() {
        // A mark alone (0.50): Standard and More answers, not Fewer answers.
        let markOnly = "Did the committee approve the revised proposal?"
        #expect(Self.passes(markOnly, locale: "en-US", .standard))
        #expect(Self.passes(markOnly, locale: "en-US", .high))
        #expect(!Self.passes(markOnly, locale: "en-US", .low) || Self.candidate(markOnly, locale: "en-US")!.score >= 0.8)
        // Mark and an interrogative word (0.85): all three.
        let strong = "What was the budget we agreed for the second quarter?"
        #expect(QuestionSensitivity.allCases.allSatisfy { Self.passes(strong, locale: "en-US", $0) })
        // An interrogative word with no mark (0.35): only More answers.
        let bare = "what was the final number for the budget"
        #expect(Self.passes(bare, locale: "en-US", .high))
        #expect(!Self.passes(bare, locale: "en-US", .standard))
        #expect(!Self.passes(bare, locale: "en-US", .low))
        // Fewer answers needs the mark and a cue of its own kind.
        #expect(!Self.passes("Maybe we could go with the second option here?", locale: "en-US", .low))
    }

    @Test func shortAndSocialSentencesLoseScore() throws {
        let hear = try #require(Self.candidate("Can you hear me?", locale: "en-US"))
        #expect(hear.cues.contains("social"))
        #expect(hear.score < QuestionSensitivity.high.threshold)
        let why = try #require(Self.candidate("Why?", locale: "en-US"))
        #expect(why.cues.contains("short"))
    }

    // MARK: Joining and sentence choice

    @Test func aQuestionSplitBetweenTwoSegmentsIsScoredWhole() throws {
        let previous = QuestionCues.Previous(text: "¿Y cuánto fue lo que", end: 99.0)
        let c = try #require(Self.candidate("votaron al final de la sesión?", locale: "es-ES", previous: previous))
        #expect(c.text.contains("cuánto") && c.text.contains("sesión"))
        #expect(QuestionCues.isCandidate(c, sensitivity: .standard))
        // The same second half alone is not a question.
        let alone = try #require(Self.candidate("votaron al final de la sesión", locale: "es-ES"))
        #expect(!QuestionCues.isCandidate(alone, sensitivity: .standard))
    }

    @Test func aPreviousSentenceThatEndedIsNotJoined() throws {
        let previous = QuestionCues.Previous(text: "Ya terminamos con eso.", end: 99.5)
        let c = try #require(Self.candidate("Pasemos al siguiente punto", locale: "es-ES", previous: previous))
        #expect(!c.utterance.contains("terminamos"))
    }

    @Test func aLongPauseDoesNotJoin() throws {
        let previous = QuestionCues.Previous(text: "And how many people", end: 90)
        let c = try #require(Self.candidate("came to the workshop?", locale: "en-US", previous: previous))
        #expect(!c.utterance.contains("how many"))
    }

    @Test func theQuestionSentenceIsPickedFromSeveral() throws {
        let c = try #require(Self.candidate("Thanks for the update. When does the contract expire? I will write it down.", locale: "en-US"))
        #expect(c.text == "When does the contract expire?")
    }

    @Test func aQuestionAlreadyJudgedInThePreviousSegmentIsNotJudgedAgain() throws {
        let previous = QuestionCues.Previous(text: "When does the contract expire? Because I", end: 99.0)
        let c = try #require(Self.candidate("need to tell legal about it", locale: "en-US", previous: previous))
        #expect(!c.text.contains("expire"))
    }

    // MARK: Languages

    @Test func aSecondLanguageSetIsUsedForClearlyForeignSentences() throws {
        // A Spanish meeting where someone asks in English, with no mark: only the English cue set sees the question word.
        let sentence = "what was the final number for the marketing budget last quarter"
        let c = try #require(Self.candidate(sentence, locale: "es-ES"))
        #expect(c.language == .en)
        #expect(c.cues.contains("interrogative"))
    }

    @Test func shortForeignSentencesKeepTheMeetingLanguage() throws {
        let c = try #require(Self.candidate("what was it?", locale: "es-ES"))
        #expect(c.language == .es)
    }

    @Test func unknownMeetingLanguagesUseOnlyTheUniversalCues() throws {
        let c = try #require(Self.candidate("Kedy je termín odovzdania projektu?", locale: "sk-SK"))
        #expect(c.cues == ["mark"])
        #expect(c.language == nil)
    }

    @Test func localeIdentifiersMapToCueLanguages() {
        #expect(CueLanguage(identifier: "pt_BR") == .pt)
        #expect(CueLanguage(identifier: "zh-Hans-CN") == .zh)
        #expect(CueLanguage(identifier: "en") == .en)
        #expect(CueLanguage(identifier: "sk-SK") == nil)
    }

    @Test func scoringIsFastEnough() {
        // CPU time of this thread, not the wall clock: a busy Mac does not make the scoring slower.
        let cpu = cpuSeconds {
            for _ in 0..<200 {
                _ = Self.candidate("When did the committee approve the revised proposal for the second quarter?", locale: "en-US")
                _ = Self.candidate("¿Cuándo aprobó la comisión la propuesta revisada del segundo trimestre?", locale: "es-ES")
            }
        }
        let perCall = cpu / 400
        #expect(!TestTiming.holdsBudgets || perCall < 0.005, "\(perCall) s per segment")
    }
}
