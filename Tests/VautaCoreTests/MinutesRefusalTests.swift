// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// A request the model declines (Apple's guardrails) or that does not fit the server's real window no longer fails the minutes: the
/// block, merge or final request that met it takes another way, and the diagnostics count it.
@Suite("Minutes: declined and oversized requests")
struct MinutesRefusalTests {
    static let sentence = MinutesSmallWindowTests.sentence

    private struct Run {
        let outcome: LLMService.JobEvent.Outcome?
        let diagnostics: MinutesDiagnostics?
    }

    /// `legacy`: the old extraction and questions, whose items and questions the tests can count exactly (Apple's release choices rank
    /// the items and check the questions).
    private func run(_ f: KnowledgeFixture, _ id: Int64, chat: ScriptedChat, contextTokens: Int = 4_096, onDevice: Bool = true, legacy: Bool = false) async throws -> Run {
        let events = EventLog()
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: contextTokens, onDevice: onDevice))
        if legacy { await service.setMinutesExtraction(.legacy); await service.setMinutesQuestions(.legacy) }
        await service.setJobEventHandler { events.append($0) }
        await service.regenerateMinutes(id)
        #expect(await eventually { events.events.contains { $0.meetingID == id && $0.kind == .minutes } })
        let outcome = events.events.last { $0.kind == .minutes }?.outcome
        await service.waitUntilQueueIdle()
        return Run(outcome: outcome, diagnostics: await service.lastMinutesDiagnostics)
    }

    private static func isBlock(_ messages: [ChatMessage]) -> Bool { messages.last?.content.contains("ONLY one block") == true }
    private static func isDigest(_ messages: [ChatMessage]) -> Bool { messages.last?.content.contains("Above are notes on consecutive blocks") == true }

    @Test func aBlockTheModelDeclinesIsLeftOutAndTheRestOfTheMinutesAreWritten() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting((0..<120).map { "\(Self.sentence) item \($0)" })
        let chat = ScriptedChat { messages, _, _ in
            if Self.isBlock(messages) {
                if messages.map(\.content).joined().contains("item 0\n") { throw LLMError.refused }
                return ScriptedChat.reply(MinutesSmallWindowTests.extract(messages))
            }
            return ScriptedChat.reply(MinutesSmallWindowTests.finalReply)
        }
        let result = try await run(f, id, chat: chat, legacy: true)
        #expect(result.outcome == .succeeded)
        let d = try #require(result.diagnostics)
        #expect(d.counts["blocks.declined"] == 1 && d.blocksOmitted == 1 && d.blocks >= 4, "\(d.line)")
        let blocks = chat.calls.filter { Self.isBlock($0.messages) }.count
        #expect(chat.calls.filter { Self.isBlock($0.messages) && $0.text.contains("item 0\n") }.count == 1, "a declined block is not split and asked again")
        #expect(try await f.store.decisions(id).count == blocks - 1, "every other block's decision is in the minutes")
        #expect(try await f.store.card(id)?.summary == "The team went through the whole budget.")
    }

    @Test func aMeetingDeclinedInOneRequestGoesByBlocks() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting((0..<12).map { "\(Self.sentence) item \($0)" })
        let chat = ScriptedChat { messages, _, call in
            if call == 1 { throw LLMError.refused }
            if Self.isBlock(messages) { return ScriptedChat.reply(MinutesSmallWindowTests.extract(messages)) }
            return ScriptedChat.reply(MinutesSmallWindowTests.finalReply)
        }
        let result = try await run(f, id, chat: chat)
        #expect(result.outcome == .succeeded)
        #expect(result.diagnostics?.counts["minutes.declined"] == 1)
        #expect(chat.calls.contains { Self.isBlock($0.messages) } && chat.calls.contains { Self.isDigest($0.messages) })
        #expect(try await f.store.decisions(id).isEmpty == false)
    }

    @Test func aMeetingWhoseEveryBlockIsDeclinedFailsAsDeclined() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting((0..<120).map { "\(Self.sentence) item \($0)" })
        let chat = ScriptedChat { _, _, _ in throw LLMError.refused }
        let result = try await run(f, id, chat: chat)
        guard case .failed(let message)? = result.outcome else { Issue.record("expected a failure, got \(String(describing: result.outcome))"); return }
        #expect(message == JobErrorCode.refused.localizedDescription, "the job says the model declined, not that the answer was cut off")
        #expect(!chat.calls.contains { Self.isDigest($0.messages) }, "no digest is asked of nothing")
    }

    @Test func aDeclinedDigestIsAskedOnceMoreWithoutTheBlockSummaries() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting((0..<120).map { "\(Self.sentence) item \($0)" })
        let chat = ScriptedChat { messages, _, _ in
            if Self.isBlock(messages) { return ScriptedChat.reply(MinutesSmallWindowTests.extract(messages)) }
            if Self.isDigest(messages), messages.map(\.content).joined().contains("The block covers") { throw LLMError.refused }
            return ScriptedChat.reply(MinutesSmallWindowTests.finalReply)
        }
        let result = try await run(f, id, chat: chat)
        #expect(result.outcome == .succeeded)
        let digests = chat.calls.filter { Self.isDigest($0.messages) }
        #expect(digests.count == 2 && digests[0].text.contains("The block covers") && !digests[1].text.contains("The block covers"))
        #expect(PromptText.tokens(digests[1].messages) <= PromptText.tokens(digests[0].messages))
        let d = try #require(result.diagnostics)
        #expect(d.counts["digest.withoutSummaries"] == 1 && !d.isIncomplete, "\(d.line)")
        #expect(try await f.store.card(id)?.summary == "The team went through the whole budget.")
    }

    @Test func aDigestDeclinedTwiceKeepsTheItemsWithoutATitleOrASummary() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting((0..<120).map { "\(Self.sentence) item \($0)" })
        let chat = ScriptedChat { messages, _, _ in
            if Self.isBlock(messages) { return ScriptedChat.reply(MinutesSmallWindowTests.extract(messages)) }
            if Self.isDigest(messages) { throw LLMError.refused }
            return ScriptedChat.reply(MinutesSmallWindowTests.finalReply)
        }
        let result = try await run(f, id, chat: chat, legacy: true)
        #expect(result.outcome == .succeeded)
        #expect(chat.calls.filter { Self.isDigest($0.messages) }.count == 2)
        let d = try #require(result.diagnostics)
        #expect(d.counts[MinutesDiagnostics.withoutLanguageParts] == 1 && d.isIncomplete, "\(d.line)")
        let blocks = chat.calls.filter { Self.isBlock($0.messages) }.count
        #expect(try await f.store.decisions(id).count == blocks, "the items come from the extracts, checked as always")
        #expect(try await f.store.tasks(id).count == blocks)
        let card = try #require(try await f.store.card(id))
        #expect(card.summary.isEmpty, "no summary is made up")
        #expect(card.topics.first == "budget 1" && card.topics.count <= 8, "the blocks' topics, in order: \(card.topics)")
        #expect(card.openQuestions?.isEmpty == false)
        #expect(try await f.store.meeting(id)?.title == nil, "no title is made up either")
    }

    @Test func aReduceThatDoesNotFitTheServerGoesByTheDigest() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting((0..<12).map { "\(Self.sentence) item \($0)" })
        let chat = ScriptedChat { messages, _, call in
            if call == 1 { throw LLMError.contextLengthExceeded(message: "n_ctx") }
            if messages.last?.content.contains("Combine them into a single set of minutes") == true { throw LLMError.contextLengthExceeded(message: "n_ctx") }
            if messages.map(\.content).joined().contains("<<<BLOCK") { return ScriptedChat.reply(MinutesSmallWindowTests.extract(messages)) }
            return ScriptedChat.reply(MinutesSmallWindowTests.finalReply)
        }
        let result = try await run(f, id, chat: chat, contextTokens: 32_768, onDevice: false)
        #expect(result.outcome == .succeeded)
        #expect(result.diagnostics?.counts["reduce.contextLength"] == 1)
        #expect(chat.calls.contains { Self.isDigest($0.messages) })
        #expect(try await f.store.decisions(id).isEmpty == false)
        #expect(try await f.store.card(id)?.summary == "The team went through the whole budget.")
    }

    // MARK: Merges

    /// A server window small enough that the extracts of a long meeting are merged before the final request.
    private func mergingMeeting() async throws -> (KnowledgeFixture, Int64) {
        let f = try KnowledgeFixture()
        let id = try await f.meeting((0..<2_000).map { "\(Self.sentence) item \($0)" })
        return (f, id)
    }

    /// A long extract, so that the extracts of every block together do not fit the final request.
    private static func longExtract(_ messages: [ChatMessage]) -> String {
        let one = MinutesSmallWindowTests.extract(messages)
        return one.replacingOccurrences(of: "The block covers", with: String(repeating: "The block went through the figures at length. ", count: 60) + "The block covers")
    }

    private static func isMerge(_ messages: [ChatMessage]) -> Bool { messages.last?.content.contains("ONE compact extract") == true }

    @Test func aDeclinedMergeKeepsItsGroupAsItWas() async throws {
        let (f, id) = try await mergingMeeting()
        let chat = ScriptedChat { messages, _, call in
            if call == 1 { throw LLMError.contextLengthExceeded(message: "n_ctx") }
            if Self.isBlock(messages) { return ScriptedChat.reply(Self.longExtract(messages)) }
            if Self.isMerge(messages) { throw LLMError.refused }
            return ScriptedChat.reply(ScriptedChat.minutesJSON(messages))
        }
        let result = try await run(f, id, chat: chat, contextTokens: 16_384, onDevice: false)
        #expect(result.outcome == .succeeded)
        let merges = chat.calls.filter { Self.isMerge($0.messages) }.count
        #expect(merges > 0 && result.diagnostics?.counts["merge.declined"] == merges, "\(String(describing: result.diagnostics?.line))")
    }

    @Test func aMergeThatDoesNotFitIsTriedAgainInHalves() async throws {
        let (f, id) = try await mergingMeeting()
        let groupSizes = Locked<[Int]>([])
        let chat = ScriptedChat { messages, _, call in
            if call == 1 { throw LLMError.contextLengthExceeded(message: "n_ctx") }
            if Self.isBlock(messages) { return ScriptedChat.reply(Self.longExtract(messages)) }
            if Self.isMerge(messages) {
                let size = messages.map(\.content).joined().components(separatedBy: "The block covers").count - 1
                groupSizes.withLock { $0.append(size) }
                // The first merge of the meeting does not fit after all.
                if groupSizes.withLock({ $0.count }) == 1 { throw LLMError.contextLengthExceeded(message: "n_ctx") }
                return ScriptedChat.reply(MinutesSmallWindowTests.extract(messages))
            }
            return ScriptedChat.reply(ScriptedChat.minutesJSON(messages))
        }
        let result = try await run(f, id, chat: chat, contextTokens: 16_384, onDevice: false)
        #expect(result.outcome == .succeeded)
        let sizes = groupSizes.withLock { $0 }
        #expect(sizes.count >= 3 && sizes[0] >= 4, "\(sizes)")
        if sizes.count >= 3 { #expect(sizes[1] == sizes[0] / 2 && sizes[2] == sizes[0] - sizes[0] / 2, "the group is merged again in halves: \(sizes)") }
    }

    // MARK: The digest without the model

    @Test func theDigestWithoutSummariesLeavesThemOutAndStillFits() {
        let extracts = (0..<20).map { i in
            #"{"summary": "Summary of block \#(i).", "topics": ["topic \#(i)", "topic 0"], "decisions": [{"text": "Decision \#(i)", "seg": \#(i), "quote": "quote \#(i)"}], "open_questions": ["Question \#(i)?"]}"#
        }
        var digest = MinutesDigest(extracts: extracts)
        for budget in [3_000, 400, 120] {
            let text = digest.message(tokens: budget, summaries: false).content
            #expect(PromptText.tokens(text) <= budget && !text.contains("Summary of block"), "\(budget)")
        }
        #expect(digest.message(tokens: 3_000).content.contains("Summary of block 0"))
        digest.outcomes = [MinutesOutcome(status: .agreed, text: "Decision 1", segment: 1, t: 0)]
        let outcomes = digest.message(tokens: 3_000, summaries: false).content
        #expect(outcomes.contains("Decision 1") && !outcomes.contains("Summary of block"))

        let object = try? JSONSerialization.jsonObject(with: Data(digest.withoutModel.utf8)) as? [String: Any]
        #expect(object?["title"] as? String == "" && object?["summary"] as? String == "")
        let topics = object?["topics"] as? [String] ?? []
        #expect(topics.first == "topic 0" && topics.count == 8 && Set(topics).count == topics.count, "each topic once, in order: \(topics)")
        #expect((object?["open_questions"] as? [String])?.count == 10)
    }
}
