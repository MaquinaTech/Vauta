// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Ask over meetings whose transcript retention deleted: the minutes' decisions, tasks and summary that match are sent as lines of their
/// own, a claim is checked against the item it cites, and it says it comes from the minutes.
@Suite("Ask: the minutes of meetings whose transcript is gone")
struct MinutesEvidenceTests {
    static let day: TimeInterval = 86_400

    /// An old meeting whose transcript is purged (its minutes say "teletext"), and a recent one with a decision on it too.
    static func library() async throws -> (f: KnowledgeFixture, old: Int64, recent: Int64) {
        let f = try KnowledgeFixture(knowledgeRetentionDays: 0)
        let old = try await f.meeting(["We went through the remote design", "Yeah, let's drop it, nobody uses it"], locale: "en-US", outputLocale: "en-US",
                                      at: .now - 120 * day)
        let said = try #require(try await f.store.citableSegments(old).last)
        var minutes = ValidatedMinutes()
        minutes.decisions = [.init(text: "Remove the teletext button from the remote.", segment: said.id, t: said.start)]
        minutes.tasks = [.init(text: "Ana updates the remote drawings.", owner: nil, due: nil, segment: said.id, t: said.start)]
        try await f.store.applyMinutes(minutes, to: old)
        try await f.store.saveCard(MeetingCard(summary: "The team reviewed the remote and dropped the teletext button."), of: old)
        let recent = try await f.meeting(["The plants on the fourth floor need water"], locale: "en-US", outputLocale: "en-US", at: .now - day)
        let line = try #require(try await f.store.citableSegments(recent).first)
        var other = ValidatedMinutes()
        other.decisions = [.init(text: "Keep the teletext button on the old remotes.", segment: line.id, t: line.start)]
        try await f.store.applyMinutes(other, to: recent)
        try await f.store.purgeExpired(now: .now)
        let oldLines = try await f.store.citableSegments(old), recentLines = try await f.store.citableSegments(recent)
        #expect(oldLines.isEmpty && !recentLines.isEmpty, "only the old meeting's transcript is gone")
        return (f, old, recent)
    }

    @Test func onlyTheMeetingsWhoseTranscriptIsGoneGiveTheirMinutes() async throws {
        let (f, old, recent) = try await Self.library()
        let found = try await f.store.minutesPassages("What did we decide about the teletext button?", scope: nil, locale: Locale(identifier: "en"))
        #expect(found.map(\.meeting.id) == [old], "the recent meeting has its transcript: it is searched as such")
        let lines = try #require(found.first).segments
        #expect(lines.allSatisfy { MinutesEvidence.isMinutes($0.id) })
        #expect(Set(lines.compactMap { MinutesEvidence.kind(of: $0.id) }) == [.decision, .summary])
        #expect(lines.contains { $0.text == "Remove the teletext button from the remote." })
        #expect(try await f.store.minutesPassages("teletext", scope: [recent]).isEmpty, "in the scope only")
        #expect(try await f.store.minutesPassages("drawings", scope: [old]).first?.segments.map(\.text) == ["Ana updates the remote drawings."])
    }

    /// A model that cites the first line of the minutes (`id` its number as it is, or `garbled`) with `quote`.
    static func citingMinutes(quote: String? = nil, garbled: Bool = false) -> ScriptedChat {
        ScriptedChat { messages, _, _ in
            let line = messages.flatMap { $0.content.split(separator: "\n") }.first { $0.contains("from the minutes · decision") }
            guard let line, let close = line.firstIndex(of: "]"), let id = Int64(line.dropFirst(2).prefix { $0.isNumber }) else {
                return ScriptedChat.reply(#"{"found": false, "answer": "", "claims": []}"#)
            }
            let text = quote ?? String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            return ScriptedChat.reply(#"{"found": true, "answer": "It was removed.", "claims": [{"text": "It was removed.", "citations": [\#(garbled ? id + 7 : id)], "quote": "\#(text)"}]}"#)
        }
    }

    @Test func aClaimFromTheMinutesIsCheckedAndSaysSo() async throws {
        let (f, _, _) = try await Self.library()
        ServiceWarmTests.retain(f)
        let question = "What did we decide about the teletext button?"
        let chat = Self.citingMinutes()
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536))
        let answer = try await service.ask(question, meetingID: nil).answer
        let claim = try #require(answer.claims.first)
        #expect(claim.verified && claim.isFromMinutes)
        let request = try #require(chat.calls.last).text
        #expect(request.contains(MinutesEvidence.headingNote) && request.contains("from the minutes · decision"))

        // A number the model mistyped still finds its line by the quote, in the minutes of the same meeting.
        let garbled = LLMService(store: f.store, providers: TestProviders(chat: Self.citingMinutes(garbled: true), contextTokens: 65_536))
        let rescued = try #require(try await garbled.ask(question, meetingID: nil).answer.claims.first)
        #expect(rescued.verified && rescued.isFromMinutes)

        // Words the minutes do not hold are not verified.
        let wrong = LLMService(store: f.store, providers: TestProviders(chat: Self.citingMinutes(quote: "We kept the teletext button forever"), contextTokens: 65_536))
        #expect(try await wrong.ask(question, meetingID: nil).answer.claims.allSatisfy { !$0.verified })
    }

    @Test func aTimeWhoseMeetingsOnlyHaveMinutesIsNotWidened() async throws {
        let (f, old, _) = try await Self.library()
        ServiceWarmTests.retain(f)
        let service = LLMService(store: f.store, providers: TestProviders(chat: Self.citingMinutes(), contextTokens: 65_536))
        let result = try await service.ask("What did we decide about the teletext button?", meetingID: nil, meetings: [old])
        #expect(!result.widenedScope && result.passages.map(\.meeting.id) == [old])
        #expect(result.answer.claims.first?.isFromMinutes == true)
    }
}
