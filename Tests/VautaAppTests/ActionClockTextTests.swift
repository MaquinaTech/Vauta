// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

/// The small texts of the Follow-up sheet: quotes cut at words, a day that never breaks in a narrow cell, the phrase that names the day.
@Suite("Actions: sheet texts")
struct ActionClockTextTests {
    @Test func aQuoteIsShortenedBetweenWordsInEveryLength() {
        let text = "Wir treffen uns wieder in fünfhundert Jahren um über alles zu sprechen und noch viel mehr zu klären bevor es Winter wird"
        let words = Set(text.split(separator: " ").map(String.init))
        for limit in 30...100 {
            let cut = ActionClock.shortQuote(text, limit: limit)
            for part in cut.split(separator: "…") { for word in part.split(separator: " ") { #expect(words.contains(String(word)), "limit \(limit): \(cut)") } }
        }
        #expect(ActionClock.shortQuote("short", limit: 90) == "short")
    }

    @Test func aLeadingQuoteIsCutAtAWord() {
        let cut = ActionClock.leadingQuote("One risk is the sync service. It still takes too long to start", limit: 40)
        #expect(cut.hasSuffix("…") && !cut.hasSuffix(" …"))
        #expect(!cut.dropLast().contains("sta"), "no cut inside 'start': \(cut)")
    }

    @Test func theShortDayHasNoBreakableSpace() {
        let text = ActionClock.shortDayText(DueDay(year: 2026, month: 10, day: 21)!)
        #expect(!text.contains(" "), "only no-break spaces: \(text)")
    }

    @Test @MainActor func theDayPhraseNamesTheDateNotTheStartOfTheLine() {
        let facts = ActionsModel.MeetingFacts(id: 1, title: "Weekly sync", start: Date(timeIntervalSince1970: 1_791_194_400), end: nil,
                                              zone: TimeZone(identifier: "UTC")!, minutesLocale: Locale(identifier: "en-US"))
        let line = "One risk is the sync service and it still needs work, so let's meet again next Tuesday at ten."
        #expect(ActionClock.datePhrase(in: line, meeting: facts, day: nil) == "so let's meet again next Tuesday at ten")
        #expect(ActionClock.datePhrase(in: "Nothing about a day in this one, truly.", meeting: facts, day: nil).hasPrefix("Nothing about"))
    }
}
