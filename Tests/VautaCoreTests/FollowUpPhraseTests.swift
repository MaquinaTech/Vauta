// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The words that say the day, for the line that asks the person to check an inferred day; and the drafts' small details.
@Suite("Actions: date phrase and draft details")
struct FollowUpPhraseTests {
    static let zone = TimeZone(identifier: "UTC")!
    /// Monday 2026-10-05.
    static let start = Date(timeIntervalSince1970: 1_791_194_400)

    @Test func theClauseThatSaysTheDayIsQuotedNotTheStartOfTheLine() {
        let line = "One risk is the sync service and it still needs work, so let's meet again next Tuesday at ten. Thanks everyone."
        let phrase = FollowUpPhrase.phrase(in: line, meetingStart: Self.start, timeZone: Self.zone, locale: "en-US")
        #expect(phrase == "so let's meet again next Tuesday at ten", "\(phrase ?? "nil")")
    }

    @Test func aNumberWithADotOrAColonDoesNotSplitTheClause() {
        let phrase = FollowUpPhrase.phrase(in: "Sync at 10:30 on 21.10.2026 works for me.", meetingStart: Self.start, timeZone: Self.zone, locale: "de-DE")
        #expect(phrase == "Sync at 10:30 on 21.10.2026 works for me", "\(phrase ?? "nil")")
    }

    @Test func theDayItHasNowPicksTheRightClauseWhenALineSaysTwo() {
        let line = "Tomorrow is the review, and the next meeting is on 21 October."
        let tomorrow = FollowUpPhrase.phrase(in: line, meetingStart: Self.start, timeZone: Self.zone, locale: "en-US", day: DueDay("2026-10-06"))
        let october = FollowUpPhrase.phrase(in: line, meetingStart: Self.start, timeZone: Self.zone, locale: "en-US", day: DueDay("2026-10-21"))
        #expect(tomorrow == "Tomorrow is the review")
        #expect(october == "and the next meeting is on 21 October")
    }

    @Test func aLineWithNoDayGivesNoPhrase() {
        #expect(FollowUpPhrase.phrase(in: "We should keep talking about the budget.", meetingStart: Self.start, timeZone: Self.zone, locale: "en-US") == nil)
    }

    @Test func shorteningCutsAtAWordNeverInsideOne() {
        let text = "Wir treffen uns wieder in fünfhundert Jahren um über alles zu sprechen und mehr"
        for limit in 20...60 {
            let cut = FollowUpPhrase.shorten(text, limit: limit)
            let words = Set(text.split(separator: " ").map(String.init))
            for word in cut.dropLast().split(separator: " ") { #expect(words.contains(String(word)), "limit \(limit): \(cut)") }
        }
    }

    @Test func anEllipsisNeverFollowsASentenceMark() {
        let text = "One risk is the sync service. It still drops writes under load and nobody owns it yet."
        for limit in 20...60 {
            let cut = FollowUpPhrase.shorten(text, limit: limit)
            #expect(!cut.contains(".…") && !cut.contains(",…") && cut.hasSuffix("…"), "limit \(limit): \(cut)")
        }
        #expect(FollowUpPhrase.shorten("Podemos limitar a sincronização. E depois falamos mais disso hoje", limit: 33) == "Podemos limitar a sincronização…")
        #expect(FollowUpPhrase.withoutTrailingMarks("até lá。 ") == "até lá")
    }

    @Test func anImplausibleDueDayIsLeftOutOfTheDraftAndRemembered() {
        let task = TaskItem(id: 1, meetingID: 1, segmentID: nil, t: nil, text: "Send it", ownerID: nil, ownerName: nil, due: nil, status: .open, source: "llm",
                            createdAt: .now, meetingTitle: nil, dueDay: DueDay("2005-01-03"))
        let draft = ReminderDraft.make(task: task, selfEntityID: nil, containerID: "L", meetingTitle: "Sync", meetingDate: Self.start, meetingTimeZone: Self.zone)
        #expect(draft.dueDay == nil && draft.skippedDueDay == DueDay("2005-01-03"))
        var fine = task
        fine.dueDay = DueDay("2026-10-12")
        let ok = ReminderDraft.make(task: fine, selfEntityID: nil, containerID: "L", meetingTitle: "Sync", meetingDate: Self.start, meetingTimeZone: Self.zone)
        #expect(ok.dueDay == DueDay("2026-10-12") && ok.skippedDueDay == nil)
    }

    @Test func anEventFoundInTheCalendarCarriesItsStartTime() async throws {
        let writer = FakeActionWriter()
        _ = writer.seedEvent("Weekly sync follow-up", on: DueDay("2026-10-21")!, at: 600)
        let found = await writer.events(around: DueDay("2026-10-21")!, in: "cal-work", timeZone: Self.zone)
        #expect(found.first?.minuteOfDay == 600)
        let saved = try await writer.addEvent(EventWrite(title: "A", containerID: "cal-work", day: DueDay("2026-10-22")!, minuteOfDay: 840, durationMinutes: 30, timeZone: Self.zone, notes: nil))
        #expect(await writer.item(.event, itemID: saved.itemID, externalID: nil, containerID: nil)?.minuteOfDay == 840)
    }
}
