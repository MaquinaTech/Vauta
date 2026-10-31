// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The deterministic follow-up detector: a cue and a day, resolved from the meeting's own date and zone.
@Suite("Actions: follow-up meetings")
struct FollowUpDetectorTests {
    static let madrid = TimeZone(identifier: "Europe/Madrid")!
    /// Monday 12 October 2026, 10:00 in Madrid.
    static let monday = DueDay(year: 2026, month: 10, day: 12)!.startOfDay(in: madrid).addingTimeInterval(10 * 3600)

    static func detect(_ texts: [String], start: Date = monday, zone: TimeZone = madrid, locale: String? = "en-GB", gap: Double = 2, cited: Set<Int64> = [],
                       tasks: [FollowUpInput.TaskLine] = []) -> [FollowUpCandidate] {
        let lines = texts.enumerated().map { i, text in
            FollowUpInput.Line(id: Int64(i + 1), start: Double(i) * (8 + gap), end: Double(i) * (8 + gap) + 8, text: text)
        }
        return FollowUpDetector.detect(FollowUpInput(lines: lines, citedSegments: cited, tasks: tasks, meetingStart: start, timeZone: zone, locale: locale,
                                                     meetingTitle: "Weekly sync", meetingDuration: 3_000))
    }

    static func one(_ text: String, locale: String? = nil, start: Date = monday) -> FollowUpCandidate? {
        let found = detect([text], start: start, locale: locale)
        return found.first
    }

    func expect(_ text: String, day: String, inferred: Bool, minute: Int?, locale: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
        let found = Self.one(text, locale: locale)
        #expect(found?.day?.string == day, "\(text)", sourceLocation: sourceLocation)
        #expect(found?.dayInferred == inferred, "\(text)", sourceLocation: sourceLocation)
        #expect(found?.minuteOfDay == minute, "\(text)", sourceLocation: sourceLocation)
    }

    // MARK: The nine languages

    @Test func english() {
        expect("Okay, let's meet again next Tuesday at 10.", day: "2026-10-13", inferred: true, minute: 600, locale: "en-US")
        expect("Let's meet again on October 21 at 10:30 am.", day: "2026-10-21", inferred: false, minute: 630, locale: "en-US")
        expect("Let's meet again on the 21st of October at 3 pm.", day: "2026-10-21", inferred: false, minute: 15 * 60, locale: "en-US")
        expect("Same time in two weeks?", day: "2026-10-26", inferred: false, minute: nil)
        expect("Let's catch up again tomorrow at 9:30.", day: "2026-10-13", inferred: false, minute: 570)
        expect("Let's reconvene next week.", day: "2026-10-19", inferred: true, minute: nil)
        expect("Let's pick this up after the holidays on the 3rd.", day: "2026-11-03", inferred: true, minute: nil)
        expect("We'll talk again on 10/21.", day: "2026-10-21", inferred: false, minute: nil, locale: "en-US")
        expect("We'll talk again on 21/10.", day: "2026-10-21", inferred: false, minute: nil, locale: "en-GB")
        expect("Next meeting is on 2026-11-02 at 14:00.", day: "2026-11-02", inferred: false, minute: 14 * 60)
    }

    @Test func spanish() {
        expect("Nos vemos de nuevo el martes a las 10.", day: "2026-10-13", inferred: true, minute: 600)
        expect("Quedamos el 21 de octubre a las 10:30.", day: "2026-10-21", inferred: false, minute: 630)
        expect("La próxima reunión es dentro de dos semanas.", day: "2026-10-26", inferred: false, minute: nil)
        expect("Nos vemos mañana a las 11.", day: "2026-10-13", inferred: false, minute: 660)
    }

    @Test func german() {
        expect("Wir sehen uns am 21. Oktober um 10 Uhr wieder.", day: "2026-10-21", inferred: false, minute: 600)
        expect("Nächstes Treffen am Dienstag um 14:30.", day: "2026-10-13", inferred: true, minute: 14 * 60 + 30)
        expect("Wir treffen uns wieder in zwei Wochen.", day: "2026-10-26", inferred: false, minute: nil)
    }

    @Test func french() {
        expect("On se revoit mardi prochain à 10h.", day: "2026-10-13", inferred: true, minute: 600)
        expect("Prochaine réunion le 21 octobre à 14h30.", day: "2026-10-21", inferred: false, minute: 14 * 60 + 30)
        expect("On se retrouve demain.", day: "2026-10-13", inferred: false, minute: nil)
    }

    @Test func italian() {
        expect("Ci vediamo martedì alle 10.", day: "2026-10-13", inferred: true, minute: 600)
        expect("La prossima riunione è il 21 ottobre.", day: "2026-10-21", inferred: false, minute: nil)
        expect("Ci aggiorniamo tra due settimane.", day: "2026-10-26", inferred: false, minute: nil)
    }

    @Test func portuguese() {
        expect("Nos vemos de novo na terça às 10h.", day: "2026-10-13", inferred: true, minute: 600)
        expect("A próxima reunião é dia 21 de outubro.", day: "2026-10-21", inferred: false, minute: nil)
        expect("Nos falamos em duas semanas.", day: "2026-10-26", inferred: false, minute: nil)
    }

    @Test func japanese() {
        expect("来週の火曜日の10時にまた会いましょう。", day: "2026-10-20", inferred: true, minute: 600)
        expect("次回は10月21日の午後3時です。", day: "2026-10-21", inferred: false, minute: 15 * 60)
        expect("明日またミーティングをしましょう。", day: "2026-10-13", inferred: false, minute: nil)
    }

    @Test func korean() {
        expect("다음 주 화요일 10시에 다시 만나요.", day: "2026-10-20", inferred: true, minute: 600)
        expect("다음 회의는 10월 21일 오후 2시입니다.", day: "2026-10-21", inferred: false, minute: 14 * 60)
    }

    @Test func chinese() {
        expect("下周二上午10点再开会。", day: "2026-10-20", inferred: true, minute: 600)
        expect("下次会议是10月21日下午3点。", day: "2026-10-21", inferred: false, minute: 15 * 60)
        expect("两周后再碰头。", day: "2026-10-26", inferred: false, minute: nil)
    }

    // MARK: Distractors and drops

    @Test func thePastAndDeadlinesAreNotMeetings() {
        let none = [
            "We met last Tuesday to go over the budget.",
            "Let's meet again, like we did last Tuesday.",
            "El martes pasado nos vemos en la oficina.",
            "Mardi dernier, on se revoit chez le client.",
            "Wir haben uns letzten Dienstag gesehen und treffen uns wieder zum Kaffee.",
            "Send the report by Friday. Let's meet again.",
            "先週の火曜日にまた会いました。",
            "上周二我们再开会讨论过了。",
            "We spoke two days ago and we'll talk again.",
        ]
        for text in none { #expect(Self.one(text) == nil, "\(text)") }
    }

    @Test func aCueWithoutADayIsDropped() {
        for text in ["Let's meet again soon.", "Nos vemos pronto.", "We should reconvene at some point after the holidays.", "次回またお会いしましょう。"] {
            #expect(Self.one(text) == nil, "\(text)")
        }
    }

    @Test func aDayWithoutACueIsNotAMeeting() {
        #expect(Self.one("The budget is due on Friday at 10.") == nil)
        #expect(Self.one("The launch is on October 21.") == nil)
    }

    @Test func theDayMayBeInTheNextSegmentOnlyWhenItFollowsClosely() {
        let near = Self.detect(["Let's meet again.", "Tuesday at ten works for me."], gap: 2, cited: [1])
        #expect(near.first?.day?.string == "2026-10-13" && near.first?.minuteOfDay == 600)
        let far = Self.detect(["Let's meet again.", "Tuesday at ten works for me."], gap: 60, cited: [1])
        #expect(far.isEmpty)
    }

    // MARK: Which passages are read

    @Test func onlyCitedPassagesAndTheLastTenthAreRead() {
        var texts = Array(repeating: "We went through the agenda items one by one.", count: 30)
        texts[10] = "Let's meet again on October 21."
        #expect(Self.detect(texts).isEmpty, "a cue in the middle that nothing cites is not read")
        #expect(Self.detect(texts, cited: [11]).first?.day?.string == "2026-10-21", "a passage the minutes cite is read")
        texts[29] = "Let's meet again on October 22."
        #expect(Self.detect(texts).first?.day?.string == "2026-10-22", "the last tenth is read")
    }

    @Test func candidatesOnTheSameDayMergeAndAtMostTwoAreKept() {
        let texts = ["Let's meet again on October 21.", "Yes, October 21 at 10:00.", "And let's meet again on October 28.", "Also catch up again on November 4.", "Okay."]
        let found = Self.detect(texts, cited: [1, 2, 3, 4])
        #expect(found.count == 2)
        #expect(found.map { $0.day!.string }.contains("2026-10-21"))
        #expect(found.filter { $0.day!.string == "2026-10-21" }.count == 1)
    }

    @Test func theCapMatchesTheSheetsCaption() {
        // The follow-up sheet's caption says "at most two follow-up meetings" and shows when this many are listed; change both together.
        #expect(FollowUpDetector.maximumPerMeeting == 2)
    }

    @Test func anUnconfirmedOrImplausibleTaskDayIsNotACandidate() {
        let invented = FollowUpInput.TaskLine(segmentID: 1, text: "Schedule the follow up meeting", dueDay: DueDay("2026-10-30"), unconfirmed: true)
        #expect(Self.detect(["Let's meet again soon."], tasks: [invented]).isEmpty, "a day the model computed is not a day that was said")
        let far = FollowUpInput.TaskLine(segmentID: 1, text: "Schedule the follow up meeting", dueDay: DueDay("2030-10-30"))
        #expect(Self.detect(["Okay."], tasks: [far]).isEmpty)
    }

    @Test func aTaskLeftOutOfTheMainItemsStillCountsWhenItsPassageSaysTheDay() {
        // The ranking of Apple's items marks every item past the limit "to be confirmed", whatever its day: the passage decides.
        var texts = Array(repeating: "We went through the agenda items one by one.", count: 30)
        texts[10] = "Let's meet again on October 21."
        let ranked = FollowUpInput.TaskLine(segmentID: 11, text: "Schedule the follow up meeting", dueDay: DueDay("2026-10-21"), unconfirmed: true)
        #expect(Self.detect(texts, tasks: [ranked]).first?.day?.string == "2026-10-21")
        let computed = FollowUpInput.TaskLine(segmentID: 11, text: "Schedule the follow up meeting", dueDay: DueDay("2026-10-22"), unconfirmed: true)
        #expect(Self.detect(texts, tasks: [computed]).isEmpty, "another day than the one said")
    }

    @Test func anUnconfirmedTaskWhosePassageAsksOrHedgesTheDayIsNotACandidate() {
        // The passage is in the middle of the meeting and cited by nothing but the task, so only the task can make the candidate.
        func found(_ sentence: String) -> [FollowUpCandidate] {
            var texts = Array(repeating: "We went through the agenda items one by one.", count: 30)
            texts[10] = sentence
            let task = FollowUpInput.TaskLine(segmentID: 11, text: "Schedule the follow up meeting", dueDay: DueDay("2026-10-21"), unconfirmed: true)
            return Self.detect(texts, tasks: [task])
        }
        #expect(found("Let's meet again on October 21.").first?.day?.string == "2026-10-21", "a plain statement of the day")
        #expect(found("Should we meet again on October 21?").isEmpty, "a question")
        #expect(found("Maybe we could meet again on October 21.").isEmpty, "a hedge")
    }

    @Test func aSchedulingTaskWithADueDayBecomesACandidateWithoutATime() {
        let task = FollowUpInput.TaskLine(segmentID: 1, text: "Schedule the follow up meeting", dueDay: DueDay("2026-10-30"))
        let found = Self.detect(["Okay."], tasks: [task])
        #expect(found.first?.day?.string == "2026-10-30" && found.first?.minuteOfDay == nil && found.first?.dayInferred == false)
        #expect(Self.detect(["Okay."], tasks: [.init(segmentID: 1, text: "Schedule the follow up meeting", dueDay: nil)]).isEmpty)
    }

    // MARK: Calendar arithmetic and zones

    @Test func weekdaysResolveAcrossMonthAndYearEnds() {
        let friday = DueDay(year: 2026, month: 10, day: 30)!.startOfDay(in: Self.madrid).addingTimeInterval(10 * 3600)
        #expect(Self.one("Let's meet again on Tuesday.", start: friday)?.day?.string == "2026-11-03")
        let tuesday = DueDay(year: 2026, month: 12, day: 29)!.startOfDay(in: Self.madrid).addingTimeInterval(10 * 3600)
        #expect(Self.one("Let's meet again on Monday.", start: tuesday)?.day?.string == "2027-01-04")
        #expect(Self.one("Let's meet again on the 4th of January.", start: tuesday)?.day?.string == "2027-01-04")
        #expect(Self.one("Let's meet again on February 29.", start: tuesday)?.day == nil, "2027 has no 29 February, and the next one is a year later")
        #expect(Self.one("Let's meet again on Monday.", start: DueDay(year: 2026, month: 10, day: 12)!.startOfDay(in: Self.madrid).addingTimeInterval(3600))?.day?.string == "2026-10-19",
                "the same weekday is a week later, never the meeting's own day")
    }

    @Test func theMeetingsZoneDecidesWhichDayItWas() {
        // 01:30 on Tuesday 13 October in Madrid is 19:30 on Monday 12 October in New York.
        let instant = DueDay(year: 2026, month: 10, day: 13)!.startOfDay(in: Self.madrid).addingTimeInterval(1.5 * 3600)
        let ny = TimeZone(identifier: "America/New_York")!
        let inMadrid = Self.detect(["Let's meet again tomorrow."], start: instant, zone: Self.madrid)
        let inNewYork = Self.detect(["Let's meet again tomorrow."], start: instant, zone: ny)
        #expect(inMadrid.first?.day?.string == "2026-10-14")
        #expect(inNewYork.first?.day?.string == "2026-10-13", "the zone the meeting was recorded in decides, not the Mac's")
    }

    @Test func aWeekdayIsAlwaysInferredAndAnExplicitDateNever() {
        #expect(Self.one("Let's meet again on Wednesday.")?.dayInferred == true)
        #expect(Self.one("Let's meet again next Wednesday.")?.dayInferred == true)
        #expect(Self.one("Let's meet again on 21 October.")?.dayInferred == false)
        #expect(Self.one("Let's meet again next week, Wednesday.")?.day?.string == "2026-10-21", "next week's Wednesday")
    }

    @Test func detectionNeverRunsWhileTheMeetingIsBeingRecorded() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.store.startMeeting(at: Self.monday, timeZone: Self.madrid)
        _ = try await f.store.append(Segment(channel: .others, start: 0, end: 8, text: "Let's meet again on October 21.", isFinal: true), to: id)
        #expect(try await f.store.detectFollowUps(id).isEmpty, "still recording")
        try await f.store.endMeeting(id, at: Self.monday.addingTimeInterval(600))
        let found = try await f.store.detectFollowUps(id)
        #expect(found.first?.day?.string == "2026-10-21")
        #expect(try await f.store.followUps(id).count == 1)
        _ = try await f.store.detectFollowUps(id)
        #expect(try await f.store.followUps(id).count == 1, "detecting twice does not duplicate")
    }

    @Test func aCorrectedLineIsLookedAtAgain() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.store.startMeeting(at: Self.monday, timeZone: Self.madrid)
        let line = try await f.store.append(Segment(channel: .others, start: 0, end: 8, text: "Let's meet again on October 21.", isFinal: true), to: id)
        try await f.store.endMeeting(id, at: Self.monday.addingTimeInterval(600))
        #expect(try await !f.store.redetectFollowUps(id), "never looked for: nothing to look at again")
        _ = try await f.store.detectFollowUps(id)
        try await f.store.correctSegment(line, text: "Let's meet again on October 23.")
        #expect(try await f.store.redetectFollowUps(id))
        #expect(try await f.store.followUps(id).map { $0.day?.string } == ["2026-10-23"])
    }

    @Test func theDetectorIsDeterministic() {
        let texts = ["Let's meet again next Tuesday at 10.", "Same time in two weeks?"]
        #expect(Self.detect(texts, cited: [1, 2]) == Self.detect(texts, cited: [1, 2]))
    }

    // MARK: Judged-evaluation fixes

    @Test func aDateTheTalkLooksBackAtIsNotAMeeting() {
        #expect(Self.detect(["Last time we spoke on the 3rd we should meet again."], cited: [1]).isEmpty)
        #expect(Self.detect(["La última vez, el 30 de agosto, quedamos."], cited: [1], ).isEmpty)
        #expect(Self.detect(["Let's meet again on the 20th."], cited: [1]).first?.day?.string == "2026-10-20", "a plan still counts")
    }

    /// The one-year rule of due days (docs/ACTIONS.md) holds for days read from the transcript too.
    @Test func aDayMoreThanAYearAwayIsNotAMeeting() {
        #expect(Self.one("Let's meet again on 2028-03-01.") == nil)
        #expect(Self.one("Let's meet again on 1 March 2028.", locale: "en-GB") == nil)
        #expect(Self.one("We'll talk again on 01/03/2029.", locale: "en-GB") == nil)
        #expect(Self.one("Let's meet again in 400 days.") == nil)
        #expect(Self.one("Let's meet again on 2027-10-12.")?.day?.string == "2027-10-12", "a year to the day still counts")
    }

    @Test func aRejectedDateDoesNotHideALaterOneInTheSameSentence() {
        expect("After the 2026-03-01 launch, let's meet again on 2026-11-02.", day: "2026-11-02", inferred: false, minute: nil)
        expect("We met on 03/01/2026, let's meet again on 21/10/2026.", day: "2026-10-21", inferred: false, minute: nil, locale: "en-GB")
        expect("Let's meet again on 2031-01-01, no, on 2026-11-02.", day: "2026-11-02", inferred: false, minute: nil)
        expect("Since 1 March 2025 we meet, let's meet again on 21 October 2026.", day: "2026-10-21", inferred: false, minute: nil, locale: "en-GB")
    }

    @Test func aTimeBelongsToTheDayItIsNextTo() {
        let found = Self.detect(["Let's meet again next Wednesday, 8:45.", "Or the 18th around one o'clock."], cited: [1, 2])
        #expect(found.first { $0.day?.string == "2026-10-14" }?.minuteOfDay == 8 * 60 + 45)
        #expect(found.first { $0.day?.string == "2026-10-18" }?.minuteOfDay != 8 * 60 + 45, "not the other day's time")
        #expect(FollowUpDateResolver.minuteOfDay(in: "10 o'clock works for me") == 10 * 60)
    }
}
