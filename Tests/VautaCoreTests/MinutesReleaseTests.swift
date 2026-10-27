// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// What the app runs for each backend with no override: Apple's model (and what stands in for it) gets the harness phase's choices,
/// the integrated model its subset, and a model server keeps the request, the checks and the notes it had.
@Suite("Minutes: release choice per backend")
struct MinutesReleaseTests {
    private func provider(context: Int, onDevice: Bool, integrated: Bool = false) -> ChatProvider {
        ChatProvider(model: ScriptedChat { _, _, _ in ScriptedChat.reply("{}") }, contextTokens: context, onDevice: onDevice, supports: nil, integrated: integrated)
    }

    @Test func onlyOnDeviceBackendsAreMeasured() {
        #expect(provider(context: 4_096, onDevice: true).releasedHarness, "Apple's model")
        #expect(provider(context: 65_536, onDevice: true, integrated: true).releasedHarness, "the integrated model")
        #expect(!provider(context: 8_192, onDevice: false).releasedHarness, "a server loaded with a small context is still a server")
        #expect(!provider(context: 32_768, onDevice: false).releasedHarness)
    }

    @Test func aServerWithASmallContextKeepsTheOldAskAndNotepadWhateverTheReleaseSays() async throws {
        let f = try KnowledgeFixture()
        let service = LLMService(store: f.store, providers: TestProviders(chat: ScriptedChat { _, _, _ in ScriptedChat.reply("{}") }, contextTokens: 8_192, onDevice: false))
        let small = ContextBudget(contextTokens: 4_096)
        let server = provider(context: 4_096, onDevice: false)
        let apple = provider(context: 4_096, onDevice: true)
        #expect(await service.askHarness(for: server, release: .shipped) == .legacy)
        #expect(await service.noteHarness(for: server, budget: small, release: .shipped) == .legacy)
        #expect(await service.askHarness(for: apple, release: .shipped) == .shipped, "Apple's model reads the release")
        #expect(await service.noteHarness(for: apple, budget: small, release: .shipped) == .shipped)
    }

    @Test func aServerWithASmallContextKeepsEveryOldChoiceThroughTheService() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting((0..<12).map { "Line \($0) of the meeting about the budget" }, locale: "en-US", outputLocale: "en-US")
        let chat = ScriptedChat { messages, _, _ in ScriptedChat.reply(ScriptedChat.minutesJSON(messages)) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 8_192, onDevice: false))
        let events = EventLog()
        await service.setJobEventHandler { events.append($0) }
        await service.regenerateMinutes(id)
        #expect(await eventually { events.events.contains { $0.meetingID == id && $0.kind == .minutes } })
        await service.waitUntilQueueIdle()
        let counts = await service.lastMinutesDiagnostics?.counts ?? [:]
        #expect(counts.keys.allSatisfy { !$0.hasPrefix("rank.") && !$0.hasPrefix("timing.evidence") && !$0.hasPrefix("timing.rank") }, "no evidence filter, no ranking: \(counts.keys.sorted())")
        let call = try #require(chat.calls.first { $0.options.purpose == .minutes })
        guard case .object(let props)? = call.options.outputSchema else { Issue.record("no schema"); return }
        #expect(props.prefix(2).map(\.name) == ["title", "summary"], "the old order")
        let liveChat = provider(context: 8_192, onDevice: false)
        #expect(await service.liveHarness(for: liveChat) == .legacy)
        #expect(try await f.store.card(id)?.openQuestions == ["Who signs?"], "the open question is as the model wrote it")
    }

    @Test func appleOnItsSmallWindowRunsTheRankedExtractionAndTheCheckedQuestionsWithTheLeanBlockShape() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting((0..<260).map { "\(MinutesSmallWindowTests.sentence) item \($0)" })
        let chat = ScriptedChat { messages, options, _ in
            #expect(PromptText.tokens(messages) + options.maxTokens <= 4_096)
            if messages.last?.content.contains("ONLY one block") == true { return ScriptedChat.reply(MinutesSmallWindowTests.extract(messages)) }
            return ScriptedChat.reply(MinutesSmallWindowTests.finalReply)
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 4_096, onDevice: true))
        let events = EventLog()
        await service.setJobEventHandler { events.append($0) }
        await service.regenerateMinutes(id)
        #expect(await eventually { events.events.contains { $0.meetingID == id && $0.kind == .minutes } })
        await service.waitUntilQueueIdle()
        #expect(events.events.last?.outcome == .succeeded)
        let counts = await service.lastMinutesDiagnostics?.counts ?? [:]
        let proposed = try #require(counts["rank.proposed"], "the ranking ran: \(counts.keys.sorted())")
        let limit = try #require(counts["rank.limit"])
        #expect(proposed >= 4 && (counts["rank.shown"] ?? 0) <= limit)
        let decisions = try await f.store.decisions(id)
        #expect(decisions.filter { !$0.unconfirmed }.count <= limit && decisions.count + (counts["item.nearCopy"] ?? 0) >= 1)
        let blocks = chat.calls.filter { $0.text.contains("<<<BLOCK") }
        #expect(blocks.count >= 4)
        #expect(blocks.allSatisfy { !$0.text.contains("\"entities\"") }, "the lean block shape has no entities key when the meeting offers nobody to link")
        let card = try await f.store.card(id)
        #expect((card?.openQuestions ?? ["missing"]).isEmpty, "\"Who signs?\" is under four words and asks about something the meeting never says: the open-question checks drop it")
    }

    @Test func theSummaryChecksKeepAllTenSentencesOfAnIntegratedSummaryAndTheDigestCapStaysOnApple() {
        let sentences = (1...10).map { "Point number \($0) was settled by the whole group today." }
        var m = ValidatedMinutes()
        m.summary = sentences.joined(separator: " ")
        let segs = [CitableSegment(id: 1, channel: .others, start: 0, text: "we keep the display")]
        let date = Date(timeIntervalSince1970: 1_104_537_600)
        let integrated = SummaryChecks.apply(m, segments: segs, meetingDate: date, timeZone: TimeZone(identifier: "UTC")!, proseLanguage: "en-US", maxSentences: nil)
        #expect(integrated.summary == m.summary, "the last sentence is the outcome the integrated rule asks for")
        let apple = SummaryChecks.apply(m, segments: segs, meetingDate: date, timeZone: TimeZone(identifier: "UTC")!, proseLanguage: "en-US")
        #expect(apple.counts["summary.droppedExtra"] == 1)
    }

    @Test func aYearTheTranscriptWritesInWordsLosesTheYearAndNotTheSentence() {
        var m = ValidatedMinutes()
        m.summary = "The council approved the budget for 2005 after a long vote. The display stays."
        let segs = [CitableSegment(id: 1, channel: .others, start: 0, text: "we approved the budget for two thousand five")]
        let out = SummaryChecks.apply(m, segments: segs, meetingDate: Date(timeIntervalSince1970: 1_104_537_600), timeZone: TimeZone(identifier: "UTC")!, proseLanguage: "en-US")
        #expect(out.summary == "The council approved the budget after a long vote. The display stays." && out.counts["summary.yearRemoved"] == 1, Comment(rawValue: out.summary))
    }

    @Test func restatedOpenQuestionsAreDroppedOnlyWhenTheQuestionChecksAreOn() {
        var m = ValidatedMinutes()
        m.summary = "The display stays."
        m.openQuestions = ["Which display will the team keep for the product?"]
        m.decisions = [.init(text: "The team keeps the display for the product", segment: 1, t: 0, unconfirmed: false, quote: "")]
        let segs = [CitableSegment(id: 1, channel: .others, start: 0, text: "we keep the display")]
        let args = (segs, Date(timeIntervalSince1970: 1_104_537_600), TimeZone(identifier: "UTC")!)
        let held = SummaryChecks.apply(m, segments: args.0, meetingDate: args.1, timeZone: args.2, proseLanguage: "en-US", restatedQuestions: false)
        #expect(held.openQuestions == m.openQuestions, "held means unchanged")
    }
}
