// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Minutes summary: outcome-first digest and checks")
struct MinutesSummaryTests {
    // MARK: Switch

    @Test func theSwitchParsesAndTheAppKeepsTheOldSummary() {
        #expect(MinutesSummary.parse("old") == .legacy && MinutesSummary.parse("new") == .shipped)
        #expect(MinutesSummary.parse("outcomes,checks") == [.outcomes, .checks])
        #expect(MinutesSummary.parse("nonsense") == nil)
        #expect(MinutesSummary.shipped.names == "outcomes+wording+checks" && MinutesSummary.legacy.names == "legacy")
        // The integrated model runs the new summary; Apple's model keeps the old one (by design).
        #expect(MinutesSummaryRelease.summary(integrated: false) == .legacy && MinutesSummaryRelease.summary(integrated: true) == .shipped)
    }

    // MARK: Outcomes

    private func minutes() -> ValidatedMinutes {
        var m = ValidatedMinutes()
        m.decisions = [
            .init(text: "Keep the display.", segment: 10, t: 100),
            .init(text: "Drop speech recognition.", segment: 20, t: 200),
            .init(text: "Maybe use a dynamo", segment: 30, t: 300, unconfirmed: true),
        ]
        m.tasks = [
            .init(text: "Ana sends the report", owner: nil, due: nil, segment: 40, t: 400),
            .init(text: "Look at colours", owner: nil, due: nil, segment: 5, t: 50, unconfirmed: true),
        ]
        return m
    }

    @Test func outcomesCarryTheirStatusAndStayInMeetingOrder() {
        let all = MinutesOutcome.select(from: minutes(), limit: 10)
        #expect(all.map(\.t) == [50, 100, 200, 300, 400])
        #expect(all.map(\.status) == [.proposed, .agreed, .rejected, .proposed, .task])
    }

    @Test func overTheLimitTheConfirmedOnesStayAndTheLaterOfEachRankWins() {
        let kept = MinutesOutcome.select(from: minutes(), limit: 3)
        #expect(Set(kept.map(\.text)) == ["Keep the display.", "Drop speech recognition.", "Ana sends the report"])
        let four = MinutesOutcome.select(from: minutes(), limit: 4)
        #expect(four.contains { $0.text == "Maybe use a dynamo" } && !four.contains { $0.text == "Look at colours" }, "of the proposed ones, the later stays")
    }

    @Test func theSamePointFromTwoBlocksIsOneOutcome() {
        var m = minutes()
        m.decisions.append(.init(text: "We keep the display", segment: 90, t: 900))
        m.tasks.append(.init(text: "Ana sends the report now", owner: nil, due: nil, segment: 95, t: 950))
        let kept = MinutesOutcome.select(from: m, limit: 20)
        #expect(kept.filter { $0.text.lowercased().contains("display") }.count == 1)
        #expect(kept.filter { $0.text.contains("report") }.count == 1)
        #expect(kept.count == 5)
    }

    @Test func rejectionWordsInSeveralLanguages() {
        for text in ["Rejected the two-button layout", "Drop speech recognition", "Se rechazó la moción", "No se aprobó el subsidio", "Descartar la opción"] {
            #expect(MinutesOutcome.isRejection(text), "\(text)")
        }
        for text in ["Keep the display", "Se aprobó el presupuesto"] { #expect(!MinutesOutcome.isRejection(text), "\(text)") }
    }

    // MARK: Digest

    private func extract(_ summary: String, decisions: [String] = [], topics: [String] = ["a topic"]) -> String {
        let items = decisions.map { #"{"text": "\#($0)", "seg": 1, "quote": "x"}"# }.joined(separator: ",")
        let t = topics.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"summary": "\#(summary)", "topics": [\#(t)], "decisions": [\#(items)], "tasks": [], "entities": [], "open_questions": []}"#
    }

    private func digest(blocks: Int, outcomes: [MinutesOutcome]) -> MinutesDigest {
        var d = MinutesDigest(extracts: (1...blocks).map { extract("Block \($0) summary " + String(repeating: "filler ", count: 60), decisions: ["raw decision \($0)"]) })
        d.outcomes = outcomes
        return d
    }

    private let sample = [
        MinutesOutcome(status: .agreed, text: "Keep the display.", segment: 1, t: 1),
        MinutesOutcome(status: .rejected, text: "Drop speech recognition.", segment: 2, t: 2),
        MinutesOutcome(status: .proposed, text: "Maybe a dynamo.", segment: 3, t: 3),
    ]

    @Test func theDigestLeadsWithTheOutcomesAndLeavesOutTheUncheckedLists() {
        let text = digest(blocks: 3, outcomes: sample).message(tokens: 4_000).content
        let outcomes = try! #require(text.range(of: "- Agreed: Keep the display."))
        let background = try! #require(text.range(of: "Background, in order:"))
        #expect(outcomes.lowerBound < background.lowerBound)
        #expect(text.contains("- Rejected: Drop speech recognition.") && text.contains("- Proposed only: Maybe a dynamo."))
        #expect(!text.contains("Decided:") && !text.contains("raw decision"), "the blocks' own unchecked lists are replaced by the outcomes")
    }

    @Test func withoutOutcomesTheDigestIsAsBefore() {
        let plain = digest(blocks: 3, outcomes: [])
        #expect(plain.message(tokens: 4_000).content.contains("Decided: raw decision 1"))
    }

    @Test func underBudgetTheNarrativeGoesBeforeTheOutcomesAndEarlierBlocksBeforeLaterOnes() {
        let d = digest(blocks: 9, outcomes: sample)
        var previous = Int.max
        for budget in [4_000, 1_400, 1_000, 700, 500, 350] {
            let text = d.message(tokens: budget).content
            #expect(PromptText.tokens(text) <= budget || text.hasSuffix("\n>>>"), "budget \(budget)")
            #expect(text.contains("- Agreed: Keep the display."), "the outcomes stay while the narrative shrinks (budget \(budget))")
            previous = min(previous, text.count)
        }
        let tight = d.message(tokens: 500).content
        // The last third of the blocks keeps more of its summary than the first blocks: block 9 is there while block 1 is not.
        #expect(tight.contains("Block 9 summary") && !tight.contains("Block 1 summary"), "\(tight)")
    }

    @Test func aSummaryIsCutAtTheEndOfAWord() {
        let cut = MinutesDigest.clipped("The group discusses redesigning the device and its buttons", 30)
        #expect(cut.hasSuffix(" …") && !cut.contains("buttons") && cut.count <= 34, "\(cut)")
        #expect(MinutesDigest.clipped("short", 30) == "short")
    }

    @Test func theLastResortStillClosesTheDelimiter() {
        let many = (1...30).map { MinutesOutcome(status: .agreed, text: "Outcome number \($0) " + String(repeating: "word ", count: 20), segment: Int64($0), t: Double($0)) }
        let text = digest(blocks: 4, outcomes: many).message(tokens: 40).content
        #expect(text.hasPrefix("<<<") && text.hasSuffix("\n>>>"))
    }

    // MARK: Prompts

    @Test func theBlockSummaryRuleStatesResultsOnlyWhenSwitchedOn() {
        let language = OutputLanguage(Locale(identifier: "en-US"))
        let legacy = VautaPrompts.blockInstruction(language).content
        var wording = VautaPrompts.ItemWording()
        wording.outcomeSummary = true
        let new = VautaPrompts.blockInstruction(language, wording: wording).content
        #expect(legacy.contains("2 to 4 sentences with the essentials") && !legacy.contains("not what was discussed"))
        #expect(new.contains("what was decided, rejected or left open") && new.contains("not what was discussed") && !new.contains("with the essentials"))
        // Also in the definitions' wording of the block.
        var defined = wording
        defined.definitions = true
        defined.blockDefinitions = true
        #expect(VautaPrompts.blockInstruction(language, wording: defined).content.contains("not what was discussed"))
    }

    @Test func theDigestRulesNameStatusesAndForbidLeaks() {
        let request = VautaPrompts.MinutesRequest(meetingDate: Date(timeIntervalSince1970: 0), language: OutputLanguage(Locale(identifier: "en-US")))
        let outcome = VautaPrompts.digestInstruction(request, outcomes: true).content
        #expect(outcome.contains("Proposed only") && outcome.contains("final figures"))
        #expect(outcome.contains("segment numbers") && outcome.contains("date of the meeting"))
        #expect(!VautaPrompts.digestInstruction(request).content.contains("Proposed only"), "the old digest asks as before")
    }

    // MARK: Checks

    private func segments(_ texts: [String]) -> [CitableSegment] {
        texts.enumerated().map { CitableSegment(id: Int64($0.offset + 1), channel: .others, start: Double($0.offset), text: $0.element) }
    }

    private func check(_ summary: String, transcript: [String] = ["we keep the display"], language: String = "en-US", settled: [String] = [],
                       questions: [String] = []) -> ValidatedMinutes {
        var m = ValidatedMinutes()
        m.summary = summary
        m.openQuestions = questions
        let date = Date(timeIntervalSince1970: 1_104_537_600)   // 2005-01-01
        return SummaryChecks.apply(m, segments: segments(transcript), meetingDate: date, timeZone: TimeZone(identifier: "UTC")!, proseLanguage: language, settled: settled)
    }

    @Test func segmentAttributionsGoAndTheSentenceStays() {
        #expect(check("The display stays, according to segment 23. The budget is approved.").summary == "The display stays. The budget is approved.")
        let es = check("Se aprobó el proyecto, como indica el segmento 23. Se votó cinco a dos, según los segmentos 24 y 26.", language: "es-ES")
        #expect(es.summary == "Se aprobó el proyecto. Se votó cinco a dos.", "\(es.summary)")
        #expect(check("The display stays [S12]. Next point.").summary == "The display stays. Next point.")
    }

    @Test func aSentenceThatStillNamesASegmentIsDropped() {
        let m = check("Segment 7 settled everything about the meeting. The display stays.")
        #expect(m.summary == "The display stays." && m.counts["summary.droppedSegment"] == 1)
        // Customer segments are not transcript segments.
        #expect(check("Marketing targets customer segments of young people.").summary == "Marketing targets customer segments of young people.")
    }

    @Test func labelsAndBlockNumbersOfTheNotesDoNotReachThePerson() {
        #expect(check("Agreed: eight buttons will be used. Proposed only: a dynamo.").summary == "Eight buttons will be used. A dynamo.")
        let m = check("Block 15 covered the redesign. The display stays.")
        #expect(m.summary == "The display stays." && m.counts["summary.droppedBlock"] == 1)
        #expect(check("The background covered the redesign. The display stays.").summary == "The display stays.")
        // Ordinary words are not labels.
        #expect(check("Tasks were assigned to everyone.").summary == "Tasks were assigned to everyone.")
    }

    @Test func aSegmentWithItsTagIsCutFromTheSentence() {
        #expect(check("Se aprobó el proyecto por seis votos en el segmento [S22]. Se leyó la correspondencia en el segmento 33.", language: "es-ES").summary == "Se aprobó el proyecto por seis votos. Se leyó la correspondencia.")
    }

    @Test func aBlockSummaryLosesSegmentsAndTheSentencesThatSayNothingWasSettled() {
        let raw = "No decisions or tasks were assigned in this block. The display was kept, as stated in segment 12. No se tomaron decisiones en este bloque."
        #expect(SummaryChecks.cleaningBlockSummary(raw) == "The display was kept.")
        let extract = #"{"summary": "\#(raw)", "topics": [], "decisions": [], "tasks": [], "entities": [], "open_questions": []}"#
        var cleaned = MinutesDigest(extracts: [extract], cleanSummaries: true)
        cleaned.outcomes = sample
        #expect(cleaned.message(tokens: 4_000).content.contains("The display was kept.") && !cleaned.message(tokens: 4_000).content.contains("segment 12"))
        #expect(MinutesDigest(extracts: [extract]).message(tokens: 4_000).content.contains("segment 12"), "off, the summary is as the model wrote it")
    }

    @Test func aSummaryPastTheCapKeepsItsFirstSentences() {
        let long = (1...12).map { "Result number \($0) was reached by the group today." }.joined(separator: " ")
        let m = check(long)
        #expect(m.summary.hasSuffix("Result number 9 was reached by the group today.") && m.counts["summary.droppedExtra"] == 3)
    }

    @Test func aBlockOrAPlaceholderDateIsNotAResult() {
        #expect(check("El bloque abordó la intervención del secretario. Se aprobó el presupuesto.", language: "es-ES").summary == "Se aprobó el presupuesto.")
        #expect(check("The block also covered the schedule. The display stays.").summary == "The display stays.")
        let m = check("A meeting on YYYY-MM-DD at 18:00 was proposed. The display stays.")
        #expect(m.summary == "The display stays." && m.counts["summary.droppedPlaceholder"] == 1)
        #expect(check("Design a new remote control (Me). The display stays.").summary == "Design a new remote control. The display stays.")
        // A word that merely starts like block stays.
        #expect(check("Blocking the road was refused. The display stays.").summary == "Blocking the road was refused. The display stays.")
    }

    @Test func aRepeatedSentenceGoes() {
        let m = check("The group approved the hospital project with five votes. The budget was raised. The group approved the hospital project with five votes.")
        #expect(m.summary == "The group approved the hospital project with five votes. The budget was raised." && m.counts["summary.droppedRepeat"] == 1)
        // Two different short sentences are not repeats.
        #expect(check("The display stays. The display goes.").summary == "The display stays. The display goes.")
    }

    @Test func theLabelOfTheUsersChannelIsNotASubject() {
        let m = check("Me discussed the budget. The display stays.")
        #expect(m.summary == "The display stays." && m.counts["summary.droppedLabelSubject"] == 1)
        // In Spanish "Me" is a pronoun.
        #expect(check("Me parece que se aprobó el proyecto.", language: "es-ES").summary == "Me parece que se aprobó el proyecto.")
        #expect(check("We agreed on the display. We need more time.").summary == "The group agreed on the display. We need more time.")
    }

    @Test func theMeetingDateGoesUnlessTheTranscriptSaysIt() {
        #expect(check("In the meeting on 2005-01-01, the group chose the display.").summary == "In the meeting, the group chose the display.")
        #expect(check("The review was set for January 1, 2005.").summary.isEmpty == false, "a lone sentence is never emptied")
        #expect(check("The display stays. The next session is January 1, 2005.").summary == "The display stays.")
        // The transcript says the year: the date may stay.
        #expect(check("In the meeting on 2005-01-01, the group chose the display.", transcript: ["it is the first of January 2005"]).summary.contains("2005-01-01"))
    }

    @Test func aDueDateInTheMeetingsYearKeepsItsSentenceAndLosesOnlyTheYear() {
        // The meeting is on 2005-01-01 and the transcript never writes 2005 in digits; the model added the year to a date the speakers said without one.
        let m = check("The group approved the display. The report is due on November 3, 2005. The fee applies from 15 de marzo de 2005.", language: "en-US")
        #expect(m.summary == "The group approved the display. The report is due on November 3. The fee applies from 15 de marzo." && m.counts["summary.yearRemoved"] == 2,
                Comment(rawValue: m.summary))
        #expect(check("The group approved the display. The review is on 03/11/2005.").summary == "The group approved the display. The review is on 03/11.")
        #expect(check("The group approved the display. The session was held on 1 January 2005.").summary == "The group approved the display.",
                "the meeting's own day, written as a date, goes with its sentence")
        #expect(check("The group approved the display. Phase 2 2005 was cancelled by the board.").summary.contains("Phase 2"), "a number before the year is not a date")
    }

    @Test func anIsoDueDateAndAFigureThatEqualsTheYearAreLeftAlone() {
        #expect(check("The group approved the display. The report is due by 2005-11-03.").summary == "The group approved the display. The report is due by 2005-11-03.")
        #expect(check("The group approved the display. The budget of 2005 euros was approved.").summary == "The group approved the display. The budget of 2005 euros was approved.")
        #expect(check("The group approved the display. The fee is $2005 per seat.").summary.contains("$2005"))
        // The bare year still goes with its preposition.
        #expect(check("The group approved the display. The budget for 2005 was approved by the board.").summary == "The group approved the display. The budget was approved by the board.")
    }

    @Test func aNumberedFrenchSessionIsNotASegmentCitation() {
        let fr = check("Le procès-verbal de la séance 12 a été approuvé. L'écran reste.", language: "fr-FR")
        #expect(fr.summary == "Le procès-verbal de la séance 12 a été approuvé. L'écran reste." && fr.counts["summary.droppedSegment"] == nil, Comment(rawValue: fr.summary))
        #expect(check("Le budget est voté, selon le segment 12. L'écran reste.", language: "fr-FR").summary == "Le budget est voté. L'écran reste.")
    }

    @Test func anEmptySummaryStillLosesItsRestatedQuestions() {
        let m = check("", settled: ["Keep the display on the table"], questions: ["Keep the display on the table?", "Who pays the fee for the venue?"])
        #expect(m.openQuestions == ["Who pays the fee for the venue?"], "\(m.openQuestions)")
    }

    @Test func theNotesLabelsAreOnlyDroppedWhenTheSummaryWasWrittenFromTheDigest() {
        var m = ValidatedMinutes()
        m.summary = "Background checks will be required for every volunteer. Notes from the last session were approved. The display stays."
        let segs = segments(["we keep the display"])
        let date = Date(timeIntervalSince1970: 1_104_537_600)
        let integrated = SummaryChecks.apply(m, segments: segs, meetingDate: date, timeZone: TimeZone(identifier: "UTC")!, proseLanguage: "en-US", maxSentences: nil, fromDigest: false)
        #expect(integrated.summary == m.summary)
        let apple = SummaryChecks.apply(m, segments: segs, meetingDate: date, timeZone: TimeZone(identifier: "UTC")!, proseLanguage: "en-US")
        #expect(apple.summary == "The display stays.")
        // A numbered block is never a result, from either source.
        m.summary = "Block 4 covered the budget. The display stays."
        #expect(SummaryChecks.apply(m, segments: segs, meetingDate: date, timeZone: TimeZone(identifier: "UTC")!, proseLanguage: "en-US", fromDigest: false).summary == "The display stays.")
    }

    @Test func aSummaryTheChecksWouldEmptyIsLeftAsWritten() {
        let m = check("Me discussed it.")
        #expect(m.summary == "Me discussed it." && m.counts["summary.checksEmptied"] == 1)
    }

    @Test func figuresTheTranscriptNeverSaysAreCounted() {
        let m = check("The cost is 25 euros and the limit 12.5 euros.", transcript: ["the limit is twelve fifty", "it costs 25 euros"])
        #expect(m.counts["summary.figureNotInTranscript"] == 1, "12.5 is not in the transcript, 25 is")
        #expect(m.summary == "The cost is 25 euros and the limit 12.5 euros.", "counted, never removed")
    }

    @Test func anOpenQuestionThatRepeatsAnOutcomeIsNotOpen() {
        let m = check("The display stays.", settled: ["Use a large LCD screen for the remote"], questions: ["Use a large LCD screen for the remote.", "Who pays for the dynamo?"])
        #expect(m.openQuestions == ["Who pays for the dynamo?"] && m.counts["summary.droppedRestatedQuestion"] == 1)
    }
}
