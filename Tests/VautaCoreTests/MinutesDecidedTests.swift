// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Apple's decisions are read once more for "was it decided?": a joke or a proposal nobody accepted is dropped; an unreadable reply keeps
/// everything; the integrated model and the servers are not asked.
@Suite("Minutes: the must-be-a-decision check of Apple's model")
struct MinutesDecidedTests {
    static let lines = ["We approve the new budget for the next quarter", "Maybe we could paint the office orange someday",
                        "Fine, the launch moves to March then", "Ha ha, the cat should sign the contract"]

    static let texts = ["Budget approved for next quarter", "Office to be painted orange", "Launch moved to March", "Cat to sign the contract"]

    /// Minutes JSON with one decision per line, citing it by its real number.
    static func minutes(_ segments: [CitableSegment]) -> String {
        let decisions = zip(segments, texts).map { s, text in
            #"{"text": "\#(text)", "seg": \#(s.id), "quote": "\#(String(s.text.prefix(30)))"}"#
        }.joined(separator: ",")
        return #"{"title": "T", "summary": "S", "topics": [], "decisions": [\#(decisions)], "tasks": [], "entities": [], "open_questions": []}"#
    }

    static func run(onDevice: Bool, integrated: Bool = false, filterOn: Bool = true, decided: @escaping @Sendable (String) -> String?) async throws -> (decisions: [String], calls: [ScriptedChat.Call], drops: [String]) {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(lines, locale: "en-US", outputLocale: "en-US")
        let segments = try await f.store.citableSegments(id)
        let chat = ScriptedChat { messages, _, _ in
            let last = messages.last?.content ?? ""
            if last.contains("was it actually decided") || last.contains("actually decided in the transcript") {
                return ScriptedChat.reply(decided(last) ?? "I cannot say")
            }
            return ScriptedChat.reply(minutes(segments))
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 32_768, onDevice: onDevice, integrated: integrated))
        await service.setDecidedFilter(filterOn)
        let events = EventLog()
        await service.setJobEventHandler { events.append($0) }
        await service.regenerateMinutes(id)
        #expect(await eventually { events.events.contains { $0.meetingID == id && $0.kind == .minutes } })
        let decisions = try await f.store.decisions(id).map(\.text)
        let drops = await service.lastDecidedDrops
        return (decisions, chat.calls, drops)
    }

    @Test func onlyWhatTheModelSaysWasDecidedIsKept() async throws {
        let r = try await Self.run(onDevice: true) { _ in
            #"{"results": [{"n": 1, "decided": true}, {"n": 2, "decided": false}, {"n": 3, "decided": true}, {"n": 4, "decided": "false"}]}"#
        }
        #expect(r.decisions.count == 2, "\(r.decisions)")
        #expect(r.drops.count == 2 && r.drops.contains { $0.contains("orange") })
        let check = r.calls.filter { $0.text.contains("actually decided in the transcript") }
        try #require(check.count == 1, "four decisions fit one batch")
        // The item shown to the model carries the line it cites, marked, and its neighbours.
        let asked = check[0].messages.last?.content ?? ""
        #expect(asked.contains("> [") && asked.contains("DECISION:"))
        #expect(check[0].options.maxTokens <= 200 && PromptText.tokens(check[0].messages) < 1_500, "it has to fit Apple's 4K window with room to spare")
    }

    /// Since 2026-10-15: the filter is off unless it is switched on (`llm-eval --decided on`).
    @Test func theFilterIsOffByDefault() async throws {
        let r = try await Self.run(onDevice: true, filterOn: false) { _ in #"{"results": [{"n": 1, "decided": false}, {"n": 2, "decided": false}]}"# }
        #expect(r.decisions.count == 4 && r.drops.isEmpty, "\(r.decisions)")
        #expect(r.calls.allSatisfy { !$0.text.contains("actually decided in the transcript") })
        let service = LLMService(store: try KnowledgeFixture().store, providers: TestProviders(chat: ScriptedChat { _, _, _ in ScriptedChat.reply("") }, contextTokens: 32_768, onDevice: true))
        #expect(await service.decidedFilter == false)
    }

    @Test func anUnreadableOrMissingAnswerKeepsEverything() async throws {
        let garbage = try await Self.run(onDevice: true) { _ in "I think the second one is a joke." }
        #expect(garbage.decisions.count == 4 && garbage.drops.isEmpty)
        let partial = try await Self.run(onDevice: true) { _ in #"{"results": [{"n": 2, "decided": false}]}"# }
        #expect(partial.decisions.count == 3, "items the reply does not mention stay: \(partial.decisions)")
    }

    @Test func theIntegratedModelAndServersAreNotAsked() async throws {
        let server = try await Self.run(onDevice: false) { _ in #"{"results": [{"n": 1, "decided": false}]}"# }
        #expect(server.decisions.count == 4 && server.calls.allSatisfy { !$0.text.contains("actually decided in the transcript") })
        let gemma = try await Self.run(onDevice: true, integrated: true) { _ in #"{"results": [{"n": 1, "decided": false}]}"# }
        #expect(gemma.calls.allSatisfy { !$0.text.contains("actually decided in the transcript") })
    }

    @Test func theBatchesStayWithinFiveItems() {
        let rows = (1...5).map { (n: $0, text: "Decision \($0)", context: "> [00:10 · Me] line") }
        let text = LLMService.decidedInstruction(rows).content
        #expect((1...5).allSatisfy { text.contains("[\($0)] DECISION: Decision \($0)") })
        #expect(LLMService.decidedBatch == 5)
    }
}
