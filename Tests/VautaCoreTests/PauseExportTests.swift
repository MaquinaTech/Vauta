// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// A paused recording in its exports: the transcript says where nothing was captured, in every format that has the transcript.
@Suite("Export: where the recording was paused")
struct PauseExportTests {
    static let options = MeetingExportOptions(locale: Locale(identifier: "en_US"), timeZone: ExportRendererTests.utc)

    static func meeting() -> MeetingExport {
        MeetingExport(title: "Weekly sync", startedAt: Date(timeIntervalSince1970: 1_790_000_000), endedAt: Date(timeIntervalSince1970: 1_790_003_000),
                      transcript: [MeetingExport.Line(start: 10, end: 14, channel: .me, text: "Let's start with the budget."),
                                   MeetingExport.Line(start: 900, end: 904, channel: .others, text: "Sorry, I'm back.")],
                      pauses: [MeetingPause(start: 63, end: 482), MeetingPause(start: 2_900, end: nil)])
    }

    @Test func thePauseTextSaysFromWhenToWhenAndHowLong() {
        let pause = MeetingPause(start: 63, end: 482)
        #expect(pause.text() == "Paused 1:03 – 8:02 (7 min)", "the app's clock")
        #expect(pause.text(clock: ExportTimestamp.clock) == "Paused 01:03 – 08:02 (7 min)", "the exports' clock")
        #expect(MeetingPause(start: 63, end: 90).text() == "Paused 1:03 – 1:30")
        #expect(MeetingPause(start: 63, end: nil).text() == "Paused from 1:03 to the end")
    }

    @Test func eachPauseGoesBeforeTheFirstLineAfterIt() {
        let places = MeetingPause.places(of: [MeetingPause(start: 2_900, end: nil), MeetingPause(start: 63, end: 482)], among: [10, 900])
        #expect(places[1] == [MeetingPause(start: 63, end: 482)] && places[2] == [MeetingPause(start: 2_900, end: nil)] && places[0] == nil)
        #expect(MeetingPause.places(of: [MeetingPause(start: 5, end: 8)], among: []) == [0: [MeetingPause(start: 5, end: 8)]])
    }

    @Test func theTextExportsShowThePausesInTheTranscript() throws {
        let markdown = MeetingExportRenderer.markdown(Self.meeting(), options: Self.options)
        let first = try #require(markdown.range(of: "Let's start with the budget."))
        let pause = try #require(markdown.range(of: "*— Paused 01:03 – 08:02 (7 min) —*"))
        let second = try #require(markdown.range(of: "Sorry, I'm back."))
        #expect(first.upperBound <= pause.lowerBound && pause.upperBound <= second.lowerBound)
        #expect(markdown.hasSuffix("*— Paused from 48:20 to the end —*\n"))
        let text = MeetingExportRenderer.plainText(Self.meeting(), options: Self.options)
        #expect(text.contains("— Paused 01:03 – 08:02 (7 min) —\n[15:00]"))
        // Without the transcript there is nowhere to show them.
        let without = MeetingExportOptions(includeTranscript: false, locale: Locale(identifier: "en_US"), timeZone: ExportRendererTests.utc)
        #expect(!MeetingExportRenderer.markdown(Self.meeting(), options: without).contains("Paused"))
    }

    @Test func theJSONListsThePausesWithTheTranscript() throws {
        let json = try MeetingExportJSON.encode(Self.meeting(), options: Self.options)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let pauses = try #require(object["pauses"] as? [[String: Any]])
        #expect(pauses.count == 2 && pauses[0]["start"] as? Double == 63 && pauses[0]["end"] as? Double == 482)
        #expect(pauses[1]["end"] is NSNull, "to the end")
        let without = MeetingExportOptions(includeTranscript: false, locale: Locale(identifier: "en_US"), timeZone: ExportRendererTests.utc)
        let bare = try #require(try JSONSerialization.jsonObject(with: Data(try MeetingExportJSON.encode(Self.meeting(), options: without).utf8)) as? [String: Any])
        #expect(bare["pauses"] == nil)
        var unpaused = Self.meeting()
        unpaused.pauses = []
        let plain = try #require(try JSONSerialization.jsonObject(with: Data(try MeetingExportJSON.encode(unpaused, options: Self.options).utf8)) as? [String: Any])
        #expect(plain["pauses"] == nil, "a meeting never paused exports as before")
    }

    @Test func theStoreGivesTheExportItsPauses() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.store.startMeeting(at: .now)
        try await f.store.append(Segment(channel: .me, start: 10, end: 14, text: "Let's start with the budget.", isFinal: true), to: id)
        try await f.store.beginPause(id, at: 63)
        try await f.store.endPause(id, at: 482)
        try await f.store.endMeeting(id, at: .now + 600)
        #expect(try await f.store.meetingExport(id)?.pauses == [MeetingPause(start: 63, end: 482)])
    }
}
