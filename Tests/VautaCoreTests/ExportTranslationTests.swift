// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// "Include translation": off by default, and when on, the stored translation
/// follows each translated passage in every format that has a transcript.
@Suite("Export · translation")
struct ExportTranslationTests {
    static let export = MeetingExport(
        title: "Sync", startedAt: Date(timeIntervalSince1970: 0),
        transcript: [.init(start: 1, end: 2, channel: .others, text: "Hello", translation: "Hola"),
                     .init(start: 3, end: 4, channel: .me, text: "Bye")])
    static let off = MeetingExportOptions(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
    static let on = MeetingExportOptions(includeTranslation: true, locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)

    @Test func offByDefault() {
        #expect(!Self.off.includeTranslation)
        for format in [MeetingExportFormat.markdown, .plainText, .srt, .webVTT, .json] {
            #expect(format.render(Self.export, options: Self.off)?.contains("Hola") == false)
        }
    }

    @Test func writtenWhenOn() {
        for format in [MeetingExportFormat.markdown, .plainText, .srt, .webVTT, .json] {
            let text = format.render(Self.export, options: Self.on) ?? ""
            #expect(text.contains("Hola"))
        }
        #expect(Self.export.hasTranslation)
    }

    @Test func jsonKeyOnlyWhenIncluded() throws {
        let off = try MeetingExportJSON.encode(Self.export, options: Self.off)
        let on = try MeetingExportJSON.encode(Self.export, options: Self.on)
        #expect(!off.contains("\"translation\""))
        #expect(on.contains("\"translation\""))
    }
}
