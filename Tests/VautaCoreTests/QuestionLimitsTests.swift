// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Live answers: settle, duplicates and rate limits (S2, S3)")
struct QuestionLimitsTests {
    static func line(_ id: Int64, _ start: Double, _ text: String, channel: Channel = .others) -> QuestionLine {
        QuestionLine(segmentID: id, channel: channel, start: start, end: start + 3, text: text)
    }

    // MARK: Settle

    @Test func aCandidateWaitsForTheNextTwoLinesOfEitherChannel() {
        var flow = QuestionFlow(meetingLocale: "en-US")
        #expect(flow.ingest(Self.line(1, 0, "Thanks for joining everybody today."), now: 3).isEmpty)
        #expect(flow.ingest(Self.line(2, 4, "What was the budget we agreed for the second quarter?"), now: 7).isEmpty, "the question waits")
        #expect(flow.nextDeadline == 11)
        // One line is not enough to judge an answer that takes two ("Hmm, let me think. It was 50k.").
        #expect(flow.ingest(Self.line(3, 8, "Hmm, let me think.", channel: .me), now: 9).isEmpty)
        // The second line, from the same or the other channel, settles it; both become its context.
        let settled = flow.ingest(Self.line(4, 9, "I think it was fifty thousand euros.", channel: .me), now: 11)
        #expect(settled.count == 1)
        #expect(settled[0].candidate.text == "What was the budget we agreed for the second quarter?")
        #expect(settled[0].before.map(\.segmentID) == [1])
        #expect(settled[0].after.map(\.segmentID) == [3, 4])
        #expect(flow.nextDeadline == nil)
    }

    @Test func aCandidateSettlesAfterFourSecondsWhenNobodySpeaks() {
        var flow = QuestionFlow(meetingLocale: "en-US")
        _ = flow.ingest(Self.line(1, 0, "Who is responsible for the vendor contract?"), now: 3)
        #expect(flow.expire(now: 6.9).isEmpty)
        let settled = flow.expire(now: 7)
        #expect(settled.count == 1 && settled[0].after.isEmpty && settled[0].settledAt == 7)
        #expect(flow.expire(now: 20).isEmpty, "settled once")
    }

    @Test func aNewerQuestionFromTheSameSpeakerReplacesTheOlderAndKeepsItAsContext() {
        var flow = QuestionFlow(meetingLocale: "en-US")
        _ = flow.ingest(Self.line(1, 0, "When is the deadline for the design review?"), now: 3)
        let none = flow.ingest(Self.line(2, 3.5, "I mean when do we need the final design review done?"), now: 6.5)
        #expect(none.isEmpty, "the older one did not settle")
        let settled = flow.expire(now: 20)
        #expect(settled.count == 1)
        #expect(settled[0].candidate.text.contains("final design review"))
        #expect(settled[0].rephrased == ["When is the deadline for the design review?"])
    }

    @Test func aStatementFromTheSameSpeakerSettlesTheQuestionAndIsItsContext() {
        var flow = QuestionFlow(meetingLocale: "en-US")
        _ = flow.ingest(Self.line(1, 0, "What does that mean for the schedule?"), now: 3)
        #expect(flow.ingest(Self.line(2, 3.5, "It means we ship one week later than planned."), now: 6.5).isEmpty)
        let settled = flow.ingest(Self.line(3, 7, "Because the vendor is late."), now: 9)
        #expect(settled.count == 1 && settled[0].after.map(\.text) == ["It means we ship one week later than planned.", "Because the vendor is late."])
    }

    @Test func aCandidateWithOneLineAfterItSettlesAtItsDeadline() {
        var flow = QuestionFlow(meetingLocale: "en-US")
        _ = flow.ingest(Self.line(1, 0, "What does that mean for the schedule?"), now: 3)
        #expect(flow.ingest(Self.line(2, 3.5, "It means we ship one week later than planned."), now: 6.5).isEmpty)
        let settled = flow.expire(now: 7)
        #expect(settled.count == 1 && settled[0].after.count == 1)
    }

    @Test func theSegmentsThatMakeTheQuestionAreRecorded() {
        var flow = QuestionFlow(meetingLocale: "en-US")
        _ = flow.ingest(Self.line(1, 0, "We looked at the numbers."), now: 3)
        // The transcriber split the question in two segments of the same speaker.
        _ = flow.ingest(QuestionLine(segmentID: 2, channel: .others, start: 4, end: 6, text: "Didn't we agree to ship"), now: 6)
        _ = flow.ingest(QuestionLine(segmentID: 3, channel: .others, start: 6.3, end: 8, text: "on Friday?"), now: 8)
        let settled = flow.expire(now: 20)
        #expect(settled.count == 1)
        #expect(Set(settled[0].ownSegments) == [2, 3], "the question's own words are not evidence for its answer")
    }

    @Test func questionsFromMeCanBeLeftOut() {
        var flow = QuestionFlow(meetingLocale: "en-US", speakers: .othersOnly)
        _ = flow.ingest(Self.line(1, 0, "When does the contract expire exactly?", channel: .me), now: 3)
        #expect(flow.nextDeadline == nil, "no candidate")
        var everyone = QuestionFlow(meetingLocale: "en-US", speakers: .everyone)
        _ = everyone.ingest(Self.line(1, 0, "When does the contract expire exactly?", channel: .me), now: 3)
        #expect(everyone.nextDeadline != nil)
    }

    @Test func theRecordingStoppingDropsWhatWaits() {
        var flow = QuestionFlow(meetingLocale: "en-US")
        _ = flow.ingest(Self.line(1, 0, "Who owns the integration with payroll?"), now: 3)
        #expect(flow.stop() == 1)
        #expect(flow.expire(now: 100).isEmpty)
    }

    // MARK: Rate limits

    @Test func modelChecksAreOnePerTenSecondsAndTwentyPerTenMinutes() {
        var limiter = QuestionLimiter()
        #expect(limiter.checkWait(now: 0) == 0)
        limiter.recordCheck(now: 0)
        #expect(limiter.checkWait(now: 4) == 6)
        #expect(limiter.checkWait(now: 10) == 0)
        var t = 10.0
        for _ in 0..<19 { limiter.recordCheck(now: t); t += 10 }
        // Twenty calls in 200 seconds: the window of ten minutes is full until the first one leaves.
        #expect(limiter.checkCount == 20)
        #expect(limiter.checkWait(now: 200) > 0)
        #expect(abs(limiter.checkWait(now: 205) - (0 + 600 - 205)) < 0.001)
        #expect(limiter.checkWait(now: 601) == 0 || limiter.checkWait(now: 601) <= 9)
    }

    @Test func cardsAreOnePerFortyFiveSecondsAndSixPerTenMinutes() {
        var limiter = QuestionLimiter()
        limiter.recordCard(now: 0)
        #expect(limiter.cardWait(now: 10, lowPowerMode: false) == 35)
        #expect(limiter.cardWait(now: 45, lowPowerMode: false) == 0)
        #expect(limiter.cardWait(now: 45, lowPowerMode: true) == 135, "one per three minutes in Low Power Mode")
        for i in 1..<6 { limiter.recordCard(now: Double(i) * 50) }
        // Six cards in 250 seconds: the seventh waits for the first to leave the window.
        #expect(limiter.cardWait(now: 300, lowPowerMode: false) == 300)
        #expect(limiter.cardWait(now: 600, lowPowerMode: false) == 0)
    }

    @Test func stalenessIsFortyFiveAndOneHundredTwentySeconds() {
        let timing = QuestionTiming()
        #expect(QuestionStaleness.classify(age: 10, timing: timing) == .fresh)
        #expect(QuestionStaleness.classify(age: 45, timing: timing) == .fresh)
        #expect(QuestionStaleness.classify(age: 46, timing: timing) == .late)
        #expect(QuestionStaleness.classify(age: 120, timing: timing) == .late)
        #expect(QuestionStaleness.classify(age: 121, timing: timing) == .dropped)
    }

    @Test func theQueueHoldsTwoAndTheNewestWins() {
        var queue = QuestionQueue<String>(capacity: 2, staleAfter: 45)
        #expect(queue.push("a", at: 0).isEmpty)
        #expect(queue.push("b", at: 1).isEmpty)
        #expect(queue.push("c", at: 2) == ["a"])
        let first = queue.pop(now: 3)
        #expect(first.item == "b" && first.stale.isEmpty)
        #expect(queue.pop(now: 3).item == "c")
        #expect(queue.pop(now: 3).item == nil)
    }

    @Test func aQueuedItemOlderThanFortyFiveSecondsIsDroppedAsStale() {
        var queue = QuestionQueue<String>(capacity: 2, staleAfter: 45)
        queue.push("old", at: 0)
        queue.push("fresh", at: 40)
        let popped = queue.pop(now: 50)
        #expect(popped.stale == ["old"] && popped.item == "fresh")
    }

    // MARK: Duplicates

    @Test func theSameQuestionPhrasedAgainIsADuplicate() {
        var dedup = QuestionDedup()
        dedup.remember(text: "What was the budget we agreed for the second quarter?", locale: "en-US", now: 0)
        #expect(dedup.isDuplicate(text: "What was the budget agreed for the second quarter?", locale: "en-US", now: 30))
        #expect(!dedup.isDuplicate(text: "Who is responsible for the vendor contract?", locale: "en-US", now: 30))
        #expect(!dedup.isDuplicate(text: "What was the budget we agreed for the second quarter?", locale: "en-US", now: 700), "forgotten after ten minutes")
    }

    @Test func aQuestionTypedInAskCountsAsAskedAlready() {
        var dedup = QuestionDedup()
        dedup.remember(text: "¿Cuál fue el presupuesto del segundo trimestre?", locale: "es-ES", now: 0)
        #expect(dedup.isDuplicate(text: "¿Cuál fue el presupuesto acordado para el segundo trimestre?", locale: "es-ES", now: 100))
    }

    @Test func vectorsCountWhenTheyExist() {
        var dedup = QuestionDedup()
        dedup.remember(text: "totally different words here", vector: [1, 0, 0], locale: "en-US", now: 0)
        #expect(dedup.isDuplicate(text: "nothing in common whatsoever", vector: [0.99, 0.05, 0], locale: "en-US", now: 5))
        #expect(!dedup.isDuplicate(text: "nothing in common whatsoever", vector: [0, 1, 0], locale: "en-US", now: 5))
    }

    @Test func japaneseQuestionsAreComparedByCharacterPairs() {
        var dedup = QuestionDedup()
        dedup.remember(text: "第2四半期に合意した予算はいくらでしたか？", locale: "ja-JP", now: 0)
        #expect(dedup.isDuplicate(text: "第2四半期に合意した予算はいくらでしたっけ？", locale: "ja-JP", now: 10))
        #expect(!dedup.isDuplicate(text: "デザインレビューの締め切りはいつですか？", locale: "ja-JP", now: 10))
    }
}
