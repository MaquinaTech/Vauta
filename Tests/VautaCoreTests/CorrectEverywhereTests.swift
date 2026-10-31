// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// `correctEverywhereOffer` and `correctEverywhere`: the words a correction replaced, corrected in the rest of the meeting when the
/// person says so, with one Undo.
@Suite("Storage: correcting the same words in the whole meeting")
struct CorrectEverywhereTests {
    private let english = LanguageProfile(locale: Locale(identifier: "en-US"))

    private func meeting(_ store: MeetingStore, _ texts: [String]) async throws -> (id: Int64, lines: [Int64]) {
        let id = try await store.startMeeting(at: .now, locale: Locale(identifier: "en-US"))
        var lines: [Int64] = []
        for (i, text) in texts.enumerated() {
            let start = Double(i * 10)
            lines.append(try await store.append(Segment(channel: .others, start: start, end: start + 8, text: text, isFinal: true), to: id))
        }
        _ = try await store.endMeeting(id, at: .now + 120)
        return (id, lines)
    }

    private func decision(_ store: MeetingStore, _ meeting: Int64, _ segment: Int64, _ text: String, source: String = "llm") async throws -> Int64 {
        try await store.execForTests("INSERT INTO decisions(meeting_id, segment_id, t, text, source, created_at) VALUES (?, ?, 0, ?, ?, 1000)",
                                     [.integer(meeting), .integer(segment), .text(text), .text(source)])
        return try #require(try await store.intsForTests("SELECT max(id) FROM decisions").first)
    }

    @Test func aReplacementIsTheWordsPutInPlaceOfOthers() {
        let c = TranscriptCorrection(from: "so the cubernetes cluster is ready and Ana will deploy",
                                     to: "so the Kubernetes cluster is ready, and Anna will deploy it", profile: english)
        #expect(c.replacements().map { "\($0.from)→\($0.to)" } == ["cubernetes→Kubernetes", "Ana→Anna"], "an added word is no replacement")
        #expect(TranscriptCorrection(from: "we ship the beta", to: "we ship a beta", profile: english).replacements().isEmpty,
                "a function word is not a misheard name")
    }

    @Test func replacingFindsWholeWordsOnly() {
        #expect(TranscriptCorrection.replacing("Ana", with: "Anna", in: "Ana and ANA, not Anabel", profile: english) == "Anna and Anna, not Anabel")
        #expect(TranscriptCorrection.replacing("Ana", with: "Ana María", in: "Ana María and Ana", profile: english) == "Ana María and Ana María",
                "a place that already reads the new words")
        #expect(TranscriptCorrection.replacing("Ana", with: "Anna", in: "Nothing here", profile: english) == nil)
    }

    @Test func theRestOfTheMeetingIsCorrectedWhenThePersonSaysSo() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await meeting(store, ["Ana will send the report tomorrow", "I asked Ana about it", "The budget is set"])
        let named = try await decision(store, m.id, m.lines[0], "Ana sends the report")
        let elsewhere = try await decision(store, m.id, m.lines[1], "Ask Ana about the report")
        let mine = try await decision(store, m.id, m.lines[2], "Ana owns the budget", source: "user")
        try await store.saveCard(MeetingCard(summary: "Ana will send the report.", topics: ["Report for Ana"]), of: m.id)

        let c = try #require(try await store.correctSegment(m.lines[0], text: "Anna will send the report tomorrow"))
        #expect(try await store.decisions(m.id).first { $0.id == named }?.unconfirmedReason == UnconfirmedReason.edited)
        let offer = try #require(try await store.correctEverywhereOffer(after: c))
        #expect(offer.replacements == [.init(from: "Ana", to: "Anna")])
        #expect(offer.lines == 1 && offer.items == 4, "one other line, three decisions and the summary")

        let undo = try #require(try await store.correctEverywhere(offer))
        let lines = try await store.segments(of: m.id)
        #expect(lines.map(\.text) == ["Anna will send the report tomorrow", "I asked Anna about it", "The budget is set"])
        #expect(lines[1].originalText == "I asked Ana about it", "each line keeps what was transcribed")
        let decisions = try await store.decisions(m.id)
        #expect(decisions.map(\.text) == ["Anna sends the report", "Ask Anna about the report", "Anna owns the budget"])
        #expect(decisions.first { $0.id == named }?.unconfirmed == false, "it says what its line says now")
        #expect(decisions.first { $0.id == elsewhere }?.unconfirmed == false)
        #expect(decisions.first { $0.id == named }?.source == "llm" && decisions.first { $0.id == mine }?.source == "user", "who wrote it stays")
        let card = try #require(try await store.card(m.id))
        #expect(card.summary == "Anna will send the report." && card.topics == ["Report for Anna"])
        #expect(try await store.correctEverywhere(offer) == nil, "nothing left to correct")

        try await store.undoCorrectEverywhere(undo)
        #expect(try await store.segments(of: m.id).map(\.text) == ["Anna will send the report tomorrow", "I asked Ana about it", "The budget is set"],
                "the line the person corrected stays corrected")
        let back = try await store.decisions(m.id)
        #expect(back.map(\.text) == ["Ana sends the report", "Ask Ana about the report", "Ana owns the budget"])
        #expect(back.first { $0.id == named }?.unconfirmedReason == UnconfirmedReason.edited)
        #expect(try await store.card(m.id)?.summary == "Ana will send the report.")
    }

    @Test func aMarkForAnotherChangeOfTheLineStays() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await meeting(store, ["Ana will ship the beta on Friday", "Ana agreed"])
        let named = try await decision(store, m.id, m.lines[0], "Ana ships the beta on Friday")
        // A name and a "not": the name is answered by correcting it everywhere, the "not" is not.
        let c = try #require(try await store.correctSegment(m.lines[0], text: "Anna will not ship the beta on Friday"))
        let offer = try #require(try await store.correctEverywhereOffer(after: c))
        try await store.correctEverywhere(offer)
        let d = try #require(try await store.decisions(m.id).first { $0.id == named })
        #expect(d.text == "Anna ships the beta on Friday" && d.unconfirmedReason == UnconfirmedReason.edited)
    }

    @Test func nothingIsOfferedWhenNothingElseHasTheWords() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await meeting(store, ["Ana will send the report", "The budget is set"])
        let c = try #require(try await store.correctSegment(m.lines[0], text: "Anna will send the report"))
        #expect(try await store.correctEverywhereOffer(after: c) == nil)
        let added = try #require(try await store.correctSegment(m.lines[1], text: "The budget is set for March"))
        #expect(try await store.correctEverywhereOffer(after: added) == nil, "words added replace nothing")
    }

    @Test func anUndoAfterTheLinesMovedOnChangesNothing() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await meeting(store, ["Ana will send it", "Ana agreed", "Ana left"])
        let c = try #require(try await store.correctSegment(m.lines[0], text: "Anna will send it"))
        let offer = try #require(try await store.correctEverywhereOffer(after: c))
        let undo = try #require(try await store.correctEverywhere(offer))
        try await store.correctSegment(m.lines[2], text: "Anna left early")
        await #expect(throws: StoreError.self) { try await store.undoCorrectEverywhere(undo) }
        #expect(try await store.segments(of: m.id).map(\.text) == ["Anna will send it", "Anna agreed", "Anna left early"])
    }
}
