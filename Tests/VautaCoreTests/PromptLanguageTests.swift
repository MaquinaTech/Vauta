// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Prompts: output language, templates and dates")
struct PromptLanguageTests {
    static let utcMinus7 = TimeZone(secondsFromGMT: -7 * 3600)!

    @Test(arguments: [
        ("en-US", "Write everything in English (en-US)."),
        ("es-ES", "Write everything in Spanish (es-ES)."),
        ("ja-JP", "Write everything in Japanese (ja-JP)."),
    ])
    func minutesNameTheOutputLanguage(identifier: String, sentence: String) {
        let request = VautaPrompts.MinutesRequest(meetingDate: .now, language: OutputLanguage(Locale(identifier: identifier)))
        let text = VautaPrompts.minutesInstruction(request).content
        #expect(text.contains(sentence))
        // Keys stay English whatever the language.
        #expect(text.contains(#""open_questions""#) && text.contains(#""summary""#))
        #expect(VautaPrompts.blockInstruction(request.language).content.contains(sentence))
        #expect(VautaPrompts.liveInstruction(sinceID: 3, previous: [], language: request.language).content.contains(sentence))
        #expect(VautaPrompts.askInstruction("¿Qué?", language: request.language).content.contains(sentence))
    }

    @Test func meetingLanguageFallsBackToTranscriptionThenLegacy() {
        let legacy = MeetingStore.Meeting(id: 1, startedAt: .now, endedAt: nil, title: nil)
        #expect(OutputLanguage(meeting: legacy).identifier == "es-ES")
        let french = MeetingStore.Meeting(id: 2, startedAt: .now, endedAt: nil, title: nil, locale: "fr-FR")
        #expect(OutputLanguage(meeting: french).identifier == "fr-FR")
        let fixed = MeetingStore.Meeting(id: 3, startedAt: .now, endedAt: nil, title: nil, locale: "fr-FR", outputLocale: "en-GB")
        #expect(OutputLanguage(meeting: fixed).identifier == "en-GB")
    }

    @Test func questionLanguageIsDetected() {
        let spanish = OutputLanguage(Locale(identifier: "es-MX"))
        // Same language as the fallback: the fallback's region is kept.
        #expect(OutputLanguage.detect("¿Cuándo vamos a lanzar la nueva versión del producto?", fallback: spanish) == spanish)
        let english = OutputLanguage.detect("When are we going to launch the new version of the product?", fallback: spanish)
        #expect(english.englishName == "English")
        // Too short to tell: the fallback.
        #expect(OutputLanguage.detect("Q3?", fallback: spanish) == spanish)
    }

    @Test func promptsAreEnglishAndUseEnglishLabels() {
        #expect(!VautaPrompts.system.contains("\"Yo\"") && VautaPrompts.system.contains(#""Me" is the user"#))
        let entities = VautaPrompts.entitiesMessage([
            CandidateEntity(id: 1, kind: .person, name: "Yo", aliases: []),
            CandidateEntity(id: 2, kind: .project, name: "Kobaltix", aliases: ["Kobal"]),
        ], selfEntity: 1).content
        #expect(entities.contains("[E1] person: Me (the user)"))
        #expect(entities.contains("[E2] project: Kobaltix (also: Kobal)"))
        let named = VautaPrompts.entitiesMessage([CandidateEntity(id: 1, kind: .person, name: "Maya", aliases: [])], selfEntity: 1)
        #expect(named.content.contains("[E1] person: Maya (the user)"))
    }

    @Test func templatesChangeTheInstructionOnly() {
        var seen = Set<String>()
        for template in MinutesTemplate.allCases {
            let request = VautaPrompts.MinutesRequest(meetingDate: .now, language: OutputLanguage(Locale(identifier: "en-US")),
                                                     template: template)
            let text = VautaPrompts.minutesInstruction(request).content
            #expect(text.contains(template.promptInstructions))
            #expect(text.contains(VautaPrompts.minutesJSON))   // same JSON shape for every template
            seen.insert(template.promptInstructions)
        }
        #expect(seen.count == MinutesTemplate.allCases.count)
        #expect(MinutesTemplate.standup.promptInstructions.contains("stand-up"))
        #expect(MinutesTemplate.lecture.promptInstructions.lowercased().contains("assignments"))
    }

    @Test func instructionCarriesNotesAndLiveHints() {
        let request = VautaPrompts.MinutesRequest(meetingDate: .now, language: OutputLanguage(Locale(identifier: "en-US")),
                                                 userNotes: ["[01:00] Ask about <<<budget>>>"], liveNotes: ["Decision: ship in Q3"])
        let text = VautaPrompts.minutesInstruction(request).content
        #expect(text.contains("Ask about ‹‹‹budget›››"))   // material cannot close the delimiters
        #expect(text.contains("hints only") && text.contains("- Decision: ship in Q3"))
    }

    @Test func datesUseTheLocalDayWithWeekdayNearMidnight() {
        // 2026-10-07 06:30 UTC is still Tuesday the 6th, 23:30, at UTC-7.
        let late = Date(timeIntervalSince1970: 1_791_354_600)
        #expect(PromptText.day(late, timeZone: Self.utcMinus7) == "2026-10-06 (Tuesday)")
        #expect(PromptText.day(late, timeZone: TimeZone(identifier: "UTC")!) == "2026-10-07 (Wednesday)")
        let request = VautaPrompts.MinutesRequest(meetingDate: late, language: OutputLanguage(Locale(identifier: "en-US")),
                                                 timeZone: Self.utcMinus7)
        #expect(VautaPrompts.minutesInstruction(request).content.contains("date: 2026-10-06 (Tuesday)"))
        // A due date is the start of that day in the same zone.
        let due = PromptText.parseDay("2026-10-09", reference: late, timeZone: Self.utcMinus7)
        #expect(due == Date(timeIntervalSince1970: 1_791_529_200))   // 2026-10-09 07:00 UTC
        #expect(PromptText.parseDay("2031-01-01", reference: late, timeZone: Self.utcMinus7) == nil)
        #expect(PromptText.parseDay("tomorrow", reference: late) == nil)
    }

    /// Days whose midnight does not exist (daylight saving starts at 00:00): the due day is kept, at its first moment.
    @Test(arguments: [("America/Santiago", "2026-09-06"), ("America/Havana", "2026-03-08"), ("Asia/Beirut", "2026-03-29")])
    func dueDayWithoutAMidnightIsKept(zone: String, day: String) throws {
        let timeZone = try #require(TimeZone(identifier: zone))
        let expected = try #require(DueDay(day))
        // The case this guards: the zone really skips that midnight on this system.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        #expect(formatter.date(from: day) == nil)
        let reference = expected.adding(days: -2).startOfDay(in: timeZone)
        let due = try #require(PromptText.parseDay(day, reference: reference, timeZone: timeZone))
        #expect(DueDay.containing(due, in: timeZone) == expected)
        #expect(PromptText.parseDay(" \(day) ", reference: reference, timeZone: timeZone) == due)
        #expect(PromptText.parseDay("2026-3-9", reference: reference, timeZone: timeZone) != nil, "looser forms still read")
    }
}
