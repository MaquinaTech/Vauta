// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The line under an answer over the library (`AskCoverage`): it counts the meetings as `retrieve` searches them, and what it says
/// reached the model is what the request held.
@Suite("Ask: what an answer looked at")
struct AskCoverageTests {
    static let day: TimeInterval = 86_400

    /// The segments of a request, by their `[S…]` lines.
    static func sentSegments(_ call: ScriptedChat.Call) -> Set<Int64> {
        Set(call.messages.flatMap { $0.content.split(separator: "\n") }.compactMap { line -> Int64? in
            guard line.hasPrefix("[S") else { return nil }
            return Int64(line.dropFirst(2).prefix { $0.isNumber })
        })
    }

    static func answering() -> ScriptedChat {
        ScriptedChat { messages, _, _ in
            guard let (id, text) = ScriptedChat.firstSegment(messages) else { return ScriptedChat.reply(#"{"found": false, "answer": "", "claims": []}"#) }
            return ScriptedChat.reply(#"{"found": true, "answer": "x", "claims": [{"text": "x", "citations": [\#(id)], "quote": "\#(text)"}]}"#)
        }
    }

    @Test func theCoverageIsWhatTheRequestHeld() async throws {
        // Two speeds of retention: after 90 days only the transcript goes.
        let f = try KnowledgeFixture(knowledgeRetentionDays: 0)
        ServiceWarmTests.retain(f)
        let now = Date.now
        let a = try await f.meeting(["The Kobaltix budget was approved for the quarter"], locale: "en-US", outputLocale: "en-US", at: now - 3 * Self.day)
        let b = try await f.meeting(["The Kobaltix budget was cut in half by the board"], locale: "en-US", outputLocale: "en-US", at: now - Self.day)
        let c = try await f.meeting(["We talked about the plants in the office"], locale: "en-US", outputLocale: "en-US", at: now - 2 * Self.day)
        let old = try await f.meeting(["The Kobaltix budget of last spring"], locale: "en-US", outputLocale: "en-US", at: now - 120 * Self.day)
        try await f.store.purgeExpired(now: now)
        #expect(try await f.store.citableSegments(old).isEmpty, "the old meeting's transcript is gone")
        var owner: [Int64: Int64] = [:]
        for m in [a, b, c] { for s in try await f.store.citableSegments(m) { owner[s.id] = m } }
        let chat = Self.answering()
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536))
        let question = "What about the Kobaltix budget?"

        let all = try await service.ask(question, meetingID: nil)
        let coverage = try #require(all.coverage)
        let inRequest = Set(Self.sentSegments(try #require(chat.calls.last)).compactMap { owner[$0] })
        #expect(inRequest == [a, b] && coverage.sentMeetings == inRequest.count, "the meetings counted are the ones whose lines the model read")
        #expect(coverage.searched == 3 && coverage.purged == 1 && coverage.keywordsOnly == 0 && coverage.sentDocuments == 0)
        #expect(abs(try #require(coverage.first).timeIntervalSince(now - 3 * Self.day)) < 1, "the purged meeting is not among the days searched")
        #expect(abs(try #require(coverage.last).timeIntervalSince(now - Self.day)) < 1)

        // The time the question names: only its meetings were searched, and nothing older is missing from them.
        let limited = try #require(try await service.ask(question, meetingID: nil, meetings: [b]).coverage)
        #expect(limited.searched == 1 && limited.sentMeetings == 1 && limited.purged == 0)
        #expect(limited.first == limited.last)

        // Nothing there: the whole library was searched, and the line says so.
        let widened = try await service.ask(question, meetingID: nil, meetings: [c])
        #expect(widened.widenedScope && widened.coverage?.searched == 3 && widened.coverage?.purged == 1)

        // Nothing found: the line still tells what was searched.
        let calls = chat.calls.count
        let none = try await service.ask("What about the Zorblat merger?", meetingID: nil)
        #expect(!none.answer.found && chat.calls.count == calls, "no request was made")
        #expect(none.coverage == AskCoverage(searched: 3, first: coverage.first, last: coverage.last, purged: 1))

        // About one meeting, its transcript is read whole: no line.
        #expect(try await service.ask(question, meetingID: a).coverage == nil)
    }

    @Test func meetingsWithoutVectorsInTheSpaceAreSearchedByKeywords() async throws {
        let f = try KnowledgeFixture()
        let a = try await f.meeting(["One"], locale: "en-US")
        let b = try await f.meeting(["Two"], locale: "en-US")
        let c = try await f.meeting(["Three"], locale: "en-US")
        let space = EmbeddingSpace(model: "m", dimensions: 2)
        try await f.store.executeForTest("INSERT INTO chunks(meeting_id, start, end, model, dims, scale, emb) VALUES (?, 0, 5, 'm', 2, 1.0, ?)",
                                         [.integer(a), .blob(Data([1, 2]))])
        // A meeting with chunks of another space too is not covered (as `vectorCoverage` counts it).
        for (meeting, model) in [(b, "m"), (b, "other")] {
            try await f.store.executeForTest("INSERT INTO chunks(meeting_id, start, end, model, dims, scale, emb) VALUES (?, 0, 5, ?, 2, 1.0, ?)",
                                             [.integer(meeting), .text(model), .blob(Data([1, 2]))])
        }
        #expect(try await f.store.askCoverage(meetings: nil, space: space).keywordsOnly == 2)
        #expect(try await f.store.askCoverage(meetings: [a, c], space: space).keywordsOnly == 1)
        #expect(try await f.store.askCoverage(meetings: nil, space: nil).keywordsOnly == 0, "by keywords, no meeting is singled out")
    }

    @Test func theDaysAreOneDateOrARange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Madrid"))
        let en = Locale(identifier: "en_US")
        let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 9)))
        let evening = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 18)))
        let august = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 10)))
        #expect(AskCoverage(searched: 2, first: morning, last: evening).days(calendar: calendar, locale: en) == "Oct 28, 2026")
        let range = try #require(AskCoverage(searched: 9, first: august, last: evening).days(calendar: calendar, locale: en))
        #expect(range.contains("Aug 3") && range.contains("Oct 28") && range.hasSuffix("2026"), "\(range)")
        #expect(AskCoverage(searched: 0).days(calendar: calendar, locale: en) == nil)
    }
}
