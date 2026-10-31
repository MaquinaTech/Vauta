// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The record of consent in the exports ("Participants informed"), and the import that will not keep the file's date.
@Suite("Export · participants informed, and import · redating")
struct ExportConsentTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let options = MeetingExportOptions(locale: Locale(identifier: "en_US"), timeZone: utc)
    static let started = ExportRendererTests.date(2026, 10, 6, 8)

    static func export(informedAt: Date?) -> MeetingExport {
        MeetingExport(title: "Sync", startedAt: started, endedAt: started + 1_800, participantsInformedAt: informedAt,
                      attendees: ["Ana"], summary: "We agreed.")
    }

    /// The formatter's narrow and no-break spaces ("8:02\u{202F}AM") as plain ones.
    static func spaced(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    @Test func theTimeTheParticipantsWereInformedIsInEveryFormat() throws {
        let e = Self.export(informedAt: Self.started + 125)
        let time = try #require(MeetingExportRenderer.informedTime(e, options: Self.options))
        #expect(Self.spaced(time) == "8:02 AM", "the day is the meeting's: the time alone")
        let markdown = Self.spaced(MeetingExportRenderer.markdown(e, options: Self.options))
        #expect(markdown.contains("- **Attendees:** Ana\n- **Participants informed:** 8:02 AM\n"))
        #expect(Self.spaced(MeetingExportRenderer.plainText(e, options: Self.options)).contains("Attendees: Ana\nParticipants informed: 8:02 AM\n"))
        let json = try MeetingExportJSON.encode(e, options: Self.options)
        #expect(json.contains("\"participantsInformedAt\" : \"2026-10-06T08:02:05Z\""))
    }

    @Test func leftOutWhenNotMarkedOrWhenTheOptionIsOff() throws {
        var off = Self.options
        off.includeParticipantsInformed = false
        for (e, options) in [(Self.export(informedAt: nil), Self.options), (Self.export(informedAt: Self.started + 60), off)] {
            #expect(MeetingExportRenderer.informedTime(e, options: options) == nil)
            #expect(!MeetingExportRenderer.markdown(e, options: options).contains("Participants informed"))
            #expect(!MeetingExportRenderer.plainText(e, options: options).contains("Participants informed"))
            let json = try MeetingExportJSON.encode(e, options: options)
            #expect(json.contains("\"participantsInformedAt\" : null"), "the key is always there")
        }
    }

    @Test func anotherDayCarriesItsDate() {
        let e = Self.export(informedAt: ExportRendererTests.date(2026, 10, 7, 0, 10))
        let shown = Self.spaced(MeetingExportRenderer.informedTime(e, options: Self.options) ?? "")
        #expect(shown.contains("Oct 7, 2026") && shown.hasSuffix("12:10 AM"), "\(shown)")
    }

    @Test func theSheetKnowsBeforeImportingWhenTheFilesDateIsNotKept() {
        let now = ExportRendererTests.date(2026, 10, 31, 12)
        let day = 86_400.0
        #expect(RecordingImportPlan.redating(recordedAt: nil, duration: 600, now: now) == nil, "no date: dated now, as always")
        #expect(RecordingImportPlan.redating(recordedAt: now - 10 * day, duration: 600, now: now) == nil)
        let old = now - 200 * day
        #expect(RecordingImportPlan.redating(recordedAt: old, duration: 600, now: now) == .tooOld(old))
        #expect(RecordingImportPlan.redating(recordedAt: now - 85 * day, duration: 600, now: now) == .tooOld(now - 85 * day),
                "within the margin before the retention limit")
        let later = now + 2 * day
        #expect(RecordingImportPlan.redating(recordedAt: later, duration: 600, now: now) == .future(later))
        // The sheet and the import agree.
        for recordedAt in [old, now - 85 * day, later, now - 10 * day] {
            let plan = RecordingImportPlan(fileName: "a.m4a", recordedAt: recordedAt, duration: 600, now: now)
            #expect(plan.redated == (RecordingImportPlan.redating(recordedAt: recordedAt, duration: 600, now: now) != nil))
        }
    }
}
