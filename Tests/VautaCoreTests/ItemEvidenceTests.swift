// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The filter that drops what is not a task or a decision and marks what lacks a commitment or an agreement "to be confirmed".
@Suite("Minutes: item evidence")
struct ItemEvidenceTests {
    static func line(_ id: Int64, _ text: String, speaker: Int64 = 102, at t: Double? = nil) -> CitableSegment {
        CitableSegment(id: id, channel: .others, start: t ?? Double(id) * 10, text: text, speaker: SpeakerTag(id: speaker, ordinal: Int(speaker - 100) + 1, confidence: 0.9))
    }

    static func decision(_ text: String, seg: Int64, quote: String) -> ValidatedMinutes.Item {
        .init(text: text, segment: seg, t: Double(seg) * 10, unconfirmed: false, quote: quote)
    }

    static func task(_ text: String, seg: Int64, quote: String) -> ValidatedMinutes.Task {
        .init(text: text, owner: nil, due: nil, segment: seg, t: Double(seg) * 10, quote: quote)
    }

    /// Filler lines so that the opening of the meeting (where recaps are) is not where the test items are.
    static func meeting(_ lines: [String], speakers: [Int64]? = nil, gap: Double = 10) -> [CitableSegment] {
        let opening = (1...20).map { line(Int64($0), "Filler line number \($0) about nothing in particular here.", at: Double($0) * gap) }
        let body = lines.enumerated().map { i, text in
            line(Int64(21 + i), text, speaker: speakers.map { $0[i % $0.count] } ?? 102, at: Double(21 + i) * gap)
        }
        return opening + body
    }

    static func apply(_ minutes: ValidatedMinutes, _ segments: [CitableSegment], language: String = "en", _ extraction: MinutesExtraction = .evidence) -> ValidatedMinutes {
        ItemEvidence.apply(minutes, context: .init(segments: segments, language: language), extraction: extraction)
    }

    static func minutes(decisions: [ValidatedMinutes.Item] = [], tasks: [ValidatedMinutes.Task] = []) -> ValidatedMinutes {
        var m = ValidatedMinutes()
        m.decisions = decisions
        m.tasks = tasks
        return m
    }

    @Test func withoutTheSwitchNothingChanges() {
        let segs = Self.meeting(["Last meeting we decided to use plastic."])
        let m = Self.minutes(decisions: [Self.decision("Use plastic", seg: 21, quote: "Last meeting we decided to use plastic")])
        #expect(Self.apply(m, segs, .legacy) == m)
    }

    // MARK: Drops

    @Test func aRecapOfEarlierMinutesIsDropped() {
        let segs = Self.meeting(["At the last meeting we decided to use plastic.", "Okay, agreed, let's go with plastic."])
        let out = Self.apply(Self.minutes(decisions: [Self.decision("Use plastic", seg: 21, quote: "we decided to use plastic")]), segs)
        #expect(out.decisions.isEmpty && out.drops["decision.recap"] == 1)
        let es = Self.meeting(["En la sesión anterior se aprobó el pedido de informe."])
        let outEs = Self.apply(Self.minutes(decisions: [Self.decision("Se aprobó el pedido", seg: 21, quote: "se aprobó el pedido de informe")]), es, language: "es")
        #expect(outEs.decisions.isEmpty && outEs.drops["decision.recap"] == 1)
    }

    @Test func theOpeningOfAMeetingRestatingWhatWasDecidedIsARecap() {
        let early = (1...40).map { Self.line(Int64($0), $0 == 3 ? "So we decided on a flip design and no teletext." : "Filler line number \($0) about nothing in particular.", at: Double($0) * 10) }
        let m = Self.minutes(decisions: [Self.decision("Flip design", seg: 3, quote: "we decided on a flip design and no teletext")])
        #expect(Self.apply(m, early).drops["decision.recap"] == 1)
        let late = (1...40).map { Self.line(Int64($0), $0 == 35 ? "So we decided on a flip design and no teletext." : "Filler line number \($0) about nothing in particular.", at: Double($0) * 10) }
        let kept = Self.apply(Self.minutes(decisions: [Self.decision("Flip design", seg: 35, quote: "we decided on a flip design and no teletext")]), late)
        #expect(kept.decisions.count == 1 && kept.drops["decision.recap"] == nil)
    }

    @Test func aQuestionNobodyAnsweredStaysButIsMarked() {
        let segs = Self.meeting(["Shall we use the rubber case?", "Hmm, I have no idea about that."])
        let out = Self.apply(Self.minutes(decisions: [Self.decision("Use the rubber case", seg: 21, quote: "Shall we use the rubber case")]), segs)
        #expect(out.decisions.count == 1 && out.decisions[0].unconfirmed && out.counts["decision.question"] == 1)
    }

    @Test func aRatingIsNotADecision() {
        let segs = Self.meeting(["I think the upper option is the bomb, it is great."])
        let out = Self.apply(Self.minutes(decisions: [Self.decision("The upper option is the bomb", seg: 21, quote: "the upper option is the bomb")]), segs)
        #expect(out.decisions.isEmpty && out.drops["decision.rating"] == 1)
        let agreed = Self.meeting(["I think the upper option is the bomb. Okay, agreed, we go with the upper option."])
        #expect(Self.apply(Self.minutes(decisions: [Self.decision("Go with the upper option", seg: 21, quote: "the upper option is the bomb")]), agreed).decisions.count == 1)
    }

    @Test func meetingProcedureIsDroppedButCommittingToAPresentationIsATask() {
        let segs = Self.meeting(["Okay go to the next slide please.", "I'll prepare the presentation for Friday."])
        let out = Self.apply(Self.minutes(decisions: [Self.decision("Go to the next slide", seg: 21, quote: "go to the next slide please")],
                                          tasks: [Self.task("Prepare the presentation", seg: 22, quote: "I'll prepare the presentation for Friday")]), segs)
        #expect(out.drops["decision.procedure"] == 1 && out.decisions.isEmpty)
        #expect(out.tasks.count == 1 && !out.tasks[0].unconfirmed)
    }

    @Test func reportedSpeechAndDoneThingsAreDropped() {
        let segs = Self.meeting(["He said that the budget is final.", "I already sent the numbers to Ana yesterday."])
        let out = Self.apply(Self.minutes(decisions: [Self.decision("Speaker 4 noted that the budget is final", seg: 21, quote: "the budget is final")],
                                          tasks: [Self.task("Send the numbers to Ana", seg: 22, quote: "I already sent the numbers to Ana yesterday")]), segs)
        #expect(out.drops["decision.reported"] == 1 && out.drops["task.done"] == 1)
    }

    /// A model asked for the owner as the transcript's label writes the item with it: that is the speaker's item, not a retelling.
    @Test func anItemThatOpensWithTheSpeakersLabelIsNotReportedSpeech() {
        for text in ["Speaker 5 to build a hash table frequency dictionary", "Speaker 2 will send the deck to the board",
                     "Speaker 4 and Speaker 5 to meet on Wednesday afternoon", "Speaker 4 proposed storing the density per topic",
                     "Speaker 2 asked Speaker 3 to send the numbers", "Speaker 3 y Speaker 1 revisan el presupuesto"] {
            #expect(!ItemEvidence.isReported(text), "\(text)")
        }
        for text in ["Speaker 4 noted that the budget is final", "Speaker 3 explained the remote control design",
                     "Speaker 2 and Speaker 4 discussed the colours", "Speaker 1 comentó el calendario", "Ana said that it works"] {
            #expect(ItemEvidence.isReported(text), "\(text)")
        }
        #expect(ItemEvidence.wordAfterLabels("speaker 4") == nil && ItemEvidence.wordAfterLabels("send the deck") == nil)
    }

    @Test func textReadAloudNeedsAVote() {
        let reading = Self.meeting(["Visto el expediente y considerando el artículo cuarto de la ordenanza vigente.", "Pasamos al siguiente asunto."])
        let m = Self.minutes(decisions: [Self.decision("Modificar el artículo cuarto de la ordenanza", seg: 21, quote: "considerando el artículo cuarto de la ordenanza vigente")])
        #expect(Self.apply(m, reading, language: "es").drops["decision.reading"] == 1)
        let voted = Self.meeting(["Visto el expediente y considerando el artículo cuarto de la ordenanza vigente.", "Se vota. Aprobado por unanimidad."])
        let kept = Self.apply(m, voted, language: "es")
        #expect(kept.decisions.count == 1 && !kept.decisions[0].unconfirmed)
    }

    @Test func aFragmentIsDropped() {
        let segs = Self.meeting(["Plastic, I guess we use plastic."])
        let out = Self.apply(Self.minutes(decisions: [Self.decision("Plastic", seg: 21, quote: "Plastic")]), segs)
        #expect(out.decisions.isEmpty && out.drops["decision.fragment"] == 1)
    }

    @Test func aRepeatIsDroppedAcrossKindsAndTheTaskWithAnActorStays() {
        let segs = Self.meeting(["I'll send the budget numbers to the whole team.", "Okay."])
        let out = Self.apply(Self.minutes(decisions: [Self.decision("Send the budget numbers to the whole team", seg: 21, quote: "send the budget numbers to the whole team")],
                                          tasks: [Self.task("Send the budget numbers to the team", seg: 21, quote: "I'll send the budget numbers to the whole team")]), segs)
        #expect(out.tasks.count == 1 && out.decisions.isEmpty && out.drops["decision.duplicate"] == 1)
        let twice = Self.apply(Self.minutes(tasks: [Self.task("Send the budget numbers to the whole team", seg: 21, quote: "send the budget numbers"),
                                                    Self.task("Send the budget numbers to the whole team now", seg: 22, quote: "Okay")]), segs)
        #expect(twice.tasks.count == 1 && twice.drops["task.duplicate"] == 1)
    }

    // MARK: Marks

    @Test func aTaskNobodyTookIsToBeConfirmedAndOneSomeoneTookIsNot() {
        let segs = Self.meeting(["We should look at the competitors' logos.", "I'll book the factory visit."])
        let out = Self.apply(Self.minutes(tasks: [Self.task("Look at the competitors' logos", seg: 21, quote: "We should look at the competitors' logos"),
                                                  Self.task("Book the factory visit", seg: 22, quote: "I'll book the factory visit")]), segs)
        #expect(out.tasks.count == 2)
        #expect(out.tasks[0].unconfirmed && out.counts["task.noCommitment"] == 1)
        #expect(!out.tasks[1].unconfirmed)
    }

    @Test func aRequestAnsweredByACommitmentIsConfirmed() {
        let segs = Self.meeting(["Can you look into the company logo?", "Yeah I'll do that."], speakers: [102, 103])
        let out = Self.apply(Self.minutes(tasks: [Self.task("Look into the company logo", seg: 21, quote: "Can you look into the company logo")]), segs)
        #expect(!out.tasks[0].unconfirmed)
        let silent = Self.meeting(["Can you look into the company logo?", "The weather is nice."], speakers: [102, 103])
        #expect(Self.apply(Self.minutes(tasks: [Self.task("Look into the company logo", seg: 21, quote: "Can you look into the company logo")]), silent).tasks[0].unconfirmed)
    }

    @Test func aHedgeInTheClauseMakesItTentativeButAHedgeInAnotherClauseDoesNot() {
        let segs = Self.meeting(["Maybe I'll send the report.", "Maybe it rains tomorrow. I'll send the report."])
        let hedged = Self.apply(Self.minutes(tasks: [Self.task("Send the report", seg: 21, quote: "Maybe I'll send the report")]), segs)
        #expect(hedged.tasks[0].unconfirmed && hedged.counts["task.tentative"] == 1, "a hedged commitment is kept, to be confirmed")
        let decisions = Self.meeting(["Maybe we could use plastic.", "Maybe it rains. Agreed, we use plastic."])
        let tentative = Self.apply(Self.minutes(decisions: [Self.decision("Use plastic", seg: 21, quote: "Maybe we could use plastic")]), decisions)
        #expect(tentative.decisions[0].unconfirmed && tentative.counts["decision.tentative"] == 1)
        let other = Self.apply(Self.minutes(decisions: [Self.decision("Use plastic", seg: 22, quote: "Agreed, we use plastic")]), decisions)
        #expect(!other.decisions[0].unconfirmed, "the hedge is in another clause")
    }

    @Test func aDecisionNeedsAnAgreementWithinThreeSegments() {
        let near = Self.meeting(["The case is hard plastic.", "Mm.", "Mm.", "Okay, agreed."])
        let kept = Self.apply(Self.minutes(decisions: [Self.decision("Use hard plastic for the case", seg: 21, quote: "The case is hard plastic")]), near)
        #expect(!kept.decisions[0].unconfirmed, "the agreement is on the third segment after")
        let far = Self.meeting(["The case is hard plastic.", "Mm.", "Mm.", "Mm.", "Okay, agreed."])
        let marked = Self.apply(Self.minutes(decisions: [Self.decision("Use hard plastic for the case", seg: 21, quote: "The case is hard plastic")]), far)
        #expect(marked.decisions[0].unconfirmed && marked.counts["decision.noAgreement"] == 1)
        let gap = Self.meeting(["The case is hard plastic.", "Okay, agreed."], gap: 200)
        #expect(Self.apply(Self.minutes(decisions: [Self.decision("Use hard plastic for the case", seg: 21, quote: "The case is hard plastic")]), gap).decisions[0].unconfirmed,
                "a gap ends the window")
    }

    @Test func theMarksAreCountsOnlyAndExplainIsOptIn() {
        let segs = Self.meeting(["The case is hard plastic."])
        let m = Self.minutes(decisions: [Self.decision("Use hard plastic for the case", seg: 21, quote: "The case is hard plastic")])
        let plain = Self.apply(m, segs)
        #expect(plain.counts.keys.allSatisfy { !$0.contains("plastic") }, "no text in the counts")
        let explained = Self.apply(m, segs, [.evidence, .explain])
        #expect(explained.counts.keys.contains { $0.hasPrefix("explain|decision|21|") })
    }

    @Test func theStrictSwitchDropsWhatWouldBeMarked() {
        let segs = Self.meeting(["The case is hard plastic."])
        let m = Self.minutes(decisions: [Self.decision("Use hard plastic for the case", seg: 21, quote: "The case is hard plastic")])
        let out = Self.apply(m, segs, [.evidence, .dropUnconfirmed])
        #expect(out.decisions.isEmpty && out.drops["decision.noAgreement"] == 1)
    }

    @Test func itemsKeepTheirOrderAndNothingIsInvented() {
        let segs = Self.meeting(["I'll send the budget.", "I'll book the room for Monday."])
        let m = Self.minutes(tasks: [Self.task("Send the budget", seg: 21, quote: "I'll send the budget"), Self.task("Book the room for Monday", seg: 22, quote: "I'll book the room for Monday")])
        let out = Self.apply(m, segs)
        #expect(out.tasks.map(\.text) == ["Send the budget", "Book the room for Monday"])
        #expect(out.title == m.title && out.summary == m.summary && out.topics == m.topics && out.openQuestions == m.openQuestions)
    }

    @Test func aLongMeetingIsFilteredAndItsOwnersFoundInAFewMilliseconds() throws {
        let texts = (0..<400).map { i in
            i % 7 == 0 ? "Can you look into the item number \(i) of the plan?" : i % 7 == 1 ? "Yeah I'll do that for item \(i). Then we agreed on the budget." : "Filler line number \(i) about the plan and the budget of the quarter."
        }
        let segs = texts.enumerated().map { Self.line(Int64($0 + 1), $1, speaker: Int64(100 + $0 % 3), at: Double($0) * 10) }
        var tasks: [ValidatedMinutes.Task] = [], decisions: [ValidatedMinutes.Item] = []
        for i in stride(from: 0, to: 400, by: 7) {
            tasks.append(Self.task("Look into item number \(i) of the plan", seg: Int64(i + 1), quote: "look into the item number \(i)"))
            decisions.append(Self.decision("Agree on the budget for item \(i + 1)", seg: Int64(i + 2), quote: "we agreed on the budget"))
        }
        // CPU time of this thread: the work is synchronous, and a busy machine must not fail a budget on speed.
        var out: ValidatedMinutes!
        let elapsed = try cpuSeconds {
            out = Self.apply(Self.minutes(decisions: decisions, tasks: tasks), segs, .shipped)
            let order = SegmentOrder(segs)
            let directory = SpeakerDirectory(speakers: [MeetingSpeaker(id: 100, meetingID: 1, channel: .others, ordinal: 1), MeetingSpeaker(id: 101, meetingID: 1, channel: .others, ordinal: 2),
                                                        MeetingSpeaker(id: 102, meetingID: 1, channel: .others, ordinal: 3)], selfEntity: 1)
            for t in tasks {
                let seg = try #require(order.segment(t.segment))
                _ = OwnerInference.infer(text: t.text, quote: t.quote, segment: seg, order: order, directory: directory, selfEntity: 1, people: [], meetingPeople: [], hint: .init(), language: "en")
            }
        } * 1000
        #expect(out.tasks.count + out.decisions.count > 0)
        #expect(elapsed < 250, "\(Int(elapsed)) ms for \(tasks.count + decisions.count) items in a debug build (the design budget is 50 ms in release)")
    }

    // MARK: Review fixes

    @Test func aTaskToSendTheMinutesIsNotARecap() {
        let cases: [(String, String, String, String)] = [
            ("Send the minutes of the meeting to everyone", "Send the minutes of the meeting to everyone", "Please send the minutes of the meeting to everyone.", "en"),
            ("Circulate the minutes from today", "I'll circulate the minutes from today", "I'll circulate the minutes from today.", "en"),
            ("議事録を送る", "議事録を送ります", "議事録を送ります。", "ja"),
            ("Enviar el acta de la sesión", "Enviar el acta de la sesión", "Te pido enviar el acta de la sesión.", "es"),
            ("Ana will book the room", "Like last time, Ana will book the room", "Like last time, Ana will book the room.", "en"),
        ]
        for (text, quote, line, lang) in cases {
            let out = Self.apply(Self.minutes(tasks: [Self.task(text, seg: 21, quote: quote)]), Self.meeting([line]), language: lang)
            #expect(out.tasks.count == 1 && out.drops["task.recap"] == nil, "\(line)")
        }
    }

    @Test func aRequestAfterARecapInTheSameTurnIsKept() {
        let early = (1...40).map { Self.line(Int64($0), $0 == 3 ? "So we agreed to start with the budget. Ana, can you send the figures?" : "Filler line number \($0) about nothing in particular.", at: Double($0) * 10) }
        let out = Self.apply(Self.minutes(tasks: [Self.task("Send the figures", seg: 3, quote: "Ana, can you send the figures")]), early)
        #expect(out.tasks.count == 1 && out.drops["task.recap"] == nil)
    }

    @Test func anAgreedDecisionAboutSlidesIsKept() {
        let segs = Self.meeting(["Agreed: the slides go to the client on Friday.", "The final presentation is on Monday, agreed."])
        let out = Self.apply(Self.minutes(decisions: [Self.decision("Slides go to the client on Friday", seg: 21, quote: "the slides go to the client on Friday"),
                                                      Self.decision("Final presentation on Monday", seg: 22, quote: "The final presentation is on Monday")]), segs)
        #expect(out.decisions.count == 2 && out.drops["decision.procedure"] == nil)
    }

    @Test func aRoleAssignedToPrepareAPresentationIsKept() {
        let segs = Self.meeting(["The Industrial Designer will prepare a presentation on the components."])
        let out = Self.apply(Self.minutes(tasks: [Self.task("Prepare a presentation on the components", seg: 21, quote: "The Industrial Designer will prepare a presentation on the components")]), segs)
        #expect(out.tasks.count == 1 && out.drops["task.procedure"] == nil)
        let talk = Self.meeting(["Okay, next slide."])
        #expect(Self.apply(Self.minutes(decisions: [Self.decision("Go to the next slide", seg: 21, quote: "next slide")]), talk).drops["decision.procedure"] == 1)
    }

    @Test func anEnumeratedAssignmentKeepsOneTaskPerRole() {
        let segs = Self.meeting(["Industrial Designer: components concept. User Interface Designer: user interface concept. Marketing: trend watching."])
        let out = Self.apply(Self.minutes(tasks: [Self.task("Industrial Designer to prepare the components concept", seg: 21, quote: "Industrial Designer: components concept"),
                                                  Self.task("User Interface Designer to prepare the user interface concept", seg: 21, quote: "User Interface Designer: user interface concept"),
                                                  Self.task("Marketing to do trend watching", seg: 21, quote: "Marketing: trend watching")]), segs)
        #expect(out.tasks.count == 3 && out.drops["task.duplicate"] == nil)
    }

    @Test func undecidedTalkIsNotAnAgreement() {
        for line in ["We haven't decided on the colour yet.", "We need to decide on the colour.", "Queda pendiente para la próxima sesión.", "No está aprobado todavía."] {
            let lang = line.hasPrefix("Queda") || line.hasPrefix("No est") ? "es" : "en"
            let out = Self.apply(Self.minutes(decisions: [Self.decision("Choose the colour", seg: 21, quote: line.replacingOccurrences(of: ".", with: ""))]), Self.meeting([line, "Okay."]), language: lang)
            #expect(out.decisions.first?.unconfirmed == true, "\(line)")
        }
        let agreed = Self.apply(Self.minutes(decisions: [Self.decision("Choose blue", seg: 21, quote: "we go blue")]), Self.meeting(["We go blue.", "Agreed, no objections."]))
        #expect(agreed.decisions.first?.unconfirmed == false)
    }

    // MARK: Who answered

    @Test func aRefusedRequestIsToBeConfirmedEvenWhenItNamesSomeone() {
        let segs = Self.meeting(["Ana, can you send the budget?", "Sorry, I can't this week."], speakers: [102, 103])
        let out = Self.apply(Self.minutes(tasks: [Self.task("Send the budget", seg: 21, quote: "Ana, can you send the budget")]), segs)
        #expect(out.tasks.count == 1 && out.tasks[0].unconfirmed)
        let accepted = Self.apply(Self.minutes(tasks: [Self.task("Send the budget", seg: 21, quote: "Ana, can you send the budget")]),
                                  Self.meeting(["Ana, can you send the budget?", "Sure, I'll send it."], speakers: [102, 103]))
        #expect(accepted.tasks.count == 1 && !accepted.tasks[0].unconfirmed)
    }

    @Test func theAskerAnsweringTheirOwnRequestConfirmsNothing() {
        let segs = Self.meeting(["Can you check the supplier prices?", "I'll send the agenda tonight."], speakers: [102, 102])
        let out = Self.apply(Self.minutes(tasks: [Self.task("Check the supplier prices", seg: 21, quote: "Can you check the supplier prices")]), segs)
        #expect(out.tasks.count == 1 && out.tasks[0].unconfirmed, "an unaccepted request is not an agreed task")
        let answered = Self.apply(Self.minutes(tasks: [Self.task("Check the supplier prices", seg: 21, quote: "Can you check the supplier prices")]),
                                  Self.meeting(["Can you check the supplier prices?", "Yeah, I'll check them."], speakers: [102, 103]))
        #expect(answered.tasks.first?.unconfirmed == false)
    }

    @Test func aCommitmentToAnotherActionDoesNotConfirmTheRequest() {
        let task = Self.task("Look into the company logo", seg: 21, quote: "Can you look into the company logo")
        let unrelated = Self.apply(Self.minutes(tasks: [task]), Self.meeting(["Can you look into the company logo?", "I'll send the minutes tonight."], speakers: [102, 103]))
        #expect(unrelated.tasks.count == 1 && unrelated.tasks[0].unconfirmed, "somebody else's I'll is not the answer")
        // A weak yes from the addressee next to an unrelated I'll from a third speaker is still no commitment.
        let weakAndUnrelated = Self.apply(Self.minutes(tasks: [task]), Self.meeting(["Can you look into the company logo?", "Yeah.", "I'll send the minutes tonight."], speakers: [102, 103, 104]))
        #expect(weakAndUnrelated.tasks.first?.unconfirmed == true)
        for reply in ["I'll do that.", "Will do.", "Sure, I'll look into the logo."] {
            let answered = Self.apply(Self.minutes(tasks: [task]), Self.meeting(["Can you look into the company logo?", reply], speakers: [102, 103]))
            #expect(answered.tasks.first?.unconfirmed == false, "\(reply)")
        }
    }

    @Test func aQuestionToANamedPersonIsFirmOnlyOnceSomebodyAccepts() {
        let task = Self.task("Send the deck", seg: 21, quote: "Ana, can you send the deck")
        let silent = Self.apply(Self.minutes(tasks: [task]), Self.meeting(["Ana, can you send the deck?", "Now, about the budget for next year."], speakers: [102, 103]))
        #expect(silent.tasks.count == 1 && silent.tasks[0].unconfirmed, "silence is not acceptance")
        let alone = Self.apply(Self.minutes(tasks: [task]), Self.meeting(["Ana, can you send the deck?"], speakers: [102]))
        #expect(alone.tasks.first?.unconfirmed == true)
        let yes = Self.apply(Self.minutes(tasks: [task]), Self.meeting(["Ana, can you send the deck?", "Sure."], speakers: [102, 103]))
        #expect(yes.tasks.first?.unconfirmed == false)
        // A directive is firm as said.
        let order = Self.task("Send the deck", seg: 21, quote: "Ana, please send the deck by Friday")
        let directive = Self.apply(Self.minutes(tasks: [order]), Self.meeting(["Ana, please send the deck by Friday.", "Now, about the budget for next year."], speakers: [102, 103]))
        #expect(directive.tasks.first?.unconfirmed == false)
    }

    @Test func ofTwoCopiesTheConfirmedOneStays() {
        let segs = Self.meeting(["We should send the budget numbers to the whole team.", "I'll send the budget numbers to the whole team."])
        let out = Self.apply(Self.minutes(tasks: [Self.task("Send the budget numbers to the whole team", seg: 21, quote: "We should send the budget numbers"),
                                                  Self.task("Send the budget numbers to the whole team", seg: 22, quote: "I'll send the budget numbers to the whole team")]), segs)
        #expect(out.tasks.count == 1 && !out.tasks[0].unconfirmed && out.tasks[0].segment == 22)
        #expect(out.drops["task.duplicate"] == 1 && out.counts["task.noCommitment"] == 0)
    }
}
