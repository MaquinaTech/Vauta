// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The second pass of the integrated minutes: windows of the meeting, the grammar of each, the merge with the first pass and the
/// time cap.
@Suite("Minutes: the second pass over decisions and tasks")
struct MinutesRecallPassTests {
    static func segments(_ n: Int, step: Double = 10, words: Int = 8) -> [CitableSegment] {
        (0..<n).map { i in
            CitableSegment(id: Int64(100 + i), channel: .others, start: Double(i) * step, text: (0..<words).map { "word\(i)x\($0)" }.joined(separator: " "))
        }
    }

    // MARK: Windows

    @Test func windowsCoverTheMeetingInOrderAndCutAtTwelveMinutes() {
        let all = Self.segments(200, step: 10)   // 33 minutes
        let windows = MinutesWindows.plan(all)
        #expect(windows.flatMap(\.segments).map(\.id) == all.map(\.id), "every segment is in exactly one window, in order")
        #expect(windows.count == 3, "33 minutes in windows of at most 12: \(windows.count)")
        for w in windows { #expect((w.segments.last!.start - w.segments.first!.start) < 12 * 60) }
        #expect(MinutesWindows.plan([]).isEmpty && MinutesWindows.plan(Self.segments(1)).count == 1)
    }

    @Test func windowsAlsoCutAtThreeThousandTokens() {
        let long = Self.segments(60, step: 1, words: 120)   // dense: 3,000 tokens come before 12 minutes
        let windows = MinutesWindows.plan(long)
        #expect(windows.count > 1)
        for w in windows { #expect(PromptText.tokens(w.segments.map(VautaPrompts.streamingLine).joined(separator: "\n")) <= 3_400) }
    }

    // MARK: Merge

    @Test func theFirstPassWinsAndFarOrDifferentItemsAreAdded() {
        func minutes(_ decisions: [(String, Int64)], tasks: [(String, Int64)] = []) -> ValidatedMinutes {
            var m = ValidatedMinutes()
            m.decisions = decisions.map { .init(text: $0.0, segment: $0.1, t: Double($0.1)) }
            m.tasks = tasks.map { .init(text: $0.0, owner: nil, due: nil, segment: $0.1, t: Double($0.1)) }
            return m
        }
        let order = Dictionary(uniqueKeysWithValues: (0..<100).map { (Int64($0), $0) })
        let base = minutes([("Keep the budget for this quarter", 5)], tasks: [("Send the numbers to the board", 8)])
        let extra = minutes([("We keep the budget for this quarter", 7),            // same words, two segments away: the same item
                             ("We keep the budget for this quarter", 40),            // same words, far away: another item
                             ("Postpone the launch to December", 6)],                // near but different words
                            tasks: [("Send the numbers to the board on Friday", 9), ("Book the room", 60)])
        let merged = MinutesWindows.merge(base, with: extra, order: order)
        #expect(merged.minutes.decisions.map(\.text) == ["Keep the budget for this quarter", "Postpone the launch to December", "We keep the budget for this quarter"])
        #expect(merged.minutes.tasks.map(\.text) == ["Send the numbers to the board", "Book the room"])
        #expect(merged.addedDecisions == 2 && merged.addedTasks == 1)
        #expect(MinutesWindows.jaccard("Keep the budget", "keep THE budget!") == 1 && MinutesWindows.jaccard("", "x") == 0)
    }

    // MARK: Through the service

    static let items = #"{"decisions": [{"text": "The board moves the vote to March", "seg": $SEG, "quote": "$QUOTE"}], "tasks": []}"#

    static func rig(lines: Int, itemsFor window: @escaping @Sendable (Set<Int>) -> String, budget: (Double, Double)? = nil) async throws -> (LLMService, WarmChat, Int64, [CitableSegment]) {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let text = (0..<lines).map { "Line \($0) of the meeting about the budget and the vote of the board number \($0)" }
        let id = try await f.meeting(text, locale: "en-US", outputLocale: "en-US")
        let segs = try await f.store.citableSegments(id)
        let chat = WarmChat { messages, options, _ in
            if messages.last?.content.contains("List the decisions and tasks of segments") == true {
                guard case .object(let props)? = options.outputSchema, case .array(let decision, _, _)? = props.first?.schema,
                      case .object(let fields) = decision, case .integers(let ids)? = fields.first(where: { $0.name == "seg" })?.schema else { return ScriptedChat.reply("{}") }
                return ScriptedChat.reply(window(ids))
            }
            return ScriptedChat.reply(ScriptedChat.minutesJSON(messages))
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        await service.setMinutesArms(.all)   // the second pass is behind the evaluation switch
        if let budget { await service.setItemsPassBudget(floor: budget.0, share: budget.1) }
        return (service, chat, id, segs)
    }

    static func finish(_ service: LLMService, _ id: Int64) async throws {
        let box = ServiceWarmTests.EventBox()
        await service.setJobEventHandler { box.add($0) }
        await service.regenerateMinutes(id)
        #expect(await ServiceWarmTests.eventually { box.contains(id) })
        await service.waitUntilQueueIdle()
    }

    @Test func eachWindowGetsItsOwnGrammarAndTheItemsJoinTheMinutes() async throws {
        let (service, chat, id, segs) = try await Self.rig(lines: 100) { ids in
            let seg = ids.min()!
            return Self.items.replacingOccurrences(of: "$SEG", with: "\(seg)").replacingOccurrences(of: "$QUOTE", with: "Line \(seg - 0) of the meeting")
        }
        try await Self.finish(service, id)
        let itemCalls = chat.calls.filter { $0.messages.last?.content.contains("List the decisions and tasks of segments") == true }
        #expect(itemCalls.count == 2, "100 lines of 10 s: two windows of at most 12 minutes")
        var covered = Set<Int>()
        for call in itemCalls {
            guard case .object(let props)? = call.options.outputSchema, case .array(let decision, _, let max)? = props.first?.schema, case .object(let fields) = decision,
                  case .integers(let ids)? = fields.first(where: { $0.name == "seg" })?.schema else { Issue.record("no seg restriction"); continue }
            #expect(max == 8, "at most 8 of each")
            #expect(covered.isDisjoint(with: ids)); covered.formUnion(ids)
            #expect(call.options.reusePrefix, "every call shares the meeting's prefix")
            #expect((call.options.maxSeconds ?? .infinity) <= LLMService.itemsPassFloor, "a window never runs past the cap of the whole pass: \(String(describing: call.options.maxSeconds))")
        }
        #expect(covered == Set(segs.map { Int($0.id) }))
        // The first window's message lists nothing it did not keep and names its range.
        try #require(!itemCalls.isEmpty, "the second pass ran")
        #expect(itemCalls[0].messages.last?.content.contains("segments S\(segs[0].id) to S") == true)
        let decisions = try await Self.storedDecisions(service, id)
        #expect(decisions.contains { $0.contains("moves the vote to March") })
    }

    static func storedDecisions(_ service: LLMService, _ id: Int64) async throws -> [String] {
        try await service.store.decisions(id).map(\.text)
    }

    @Test func theTimeCapSkipsTheRestAndSaysSo() async throws {
        let (service, chat, id, _) = try await Self.rig(lines: 100, itemsFor: { _ in "{}" }, budget: (0, 0))
        try await Self.finish(service, id)
        let itemCalls = chat.calls.filter { $0.messages.last?.content.contains("List the decisions and tasks of segments") == true }
        #expect(itemCalls.isEmpty, "no time at all: every window is skipped")
        let diagnostics = await service.lastMinutesDiagnostics
        #expect(diagnostics?.counts["items.windowsSkipped"] == 2)
    }

    @Test func theOtherProvidersAndTheBaselineNeverRunThePass() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting((0..<20).map { "Line \($0) of the meeting about the budget" }, locale: "en-US", outputLocale: "en-US")
        let apple = WarmChat { messages, _, _ in ScriptedChat.reply(ScriptedChat.minutesJSON(messages)) }
        let appleService = LLMService(store: f.store, providers: TestProviders(chat: apple, contextTokens: 65_536, integrated: false))
        try await Self.finish(appleService, id)
        #expect(!apple.calls.contains { $0.messages.last?.content.contains("List the decisions and tasks of segments") == true })
        let baseline = WarmChat { messages, _, _ in ScriptedChat.reply(ScriptedChat.minutesJSON(messages)) }
        let baselineService = LLMService(store: f.store, providers: TestProviders(chat: baseline, contextTokens: 65_536, integrated: true))
        await baselineService.setMinutesArms(.baseline)
        try await Self.finish(baselineService, id)
        let calls = baseline.calls
        try #require(calls.count == 1, "A0: one call")
        #expect(calls[0].messages[2].content.hasPrefix("<<<TRANSCRIPT\n") && !calls[0].messages[2].content.contains("· Speaker"), "A0: the standard layout, one call")
        #expect(!calls[0].messages.last!.content.contains("every point the group settled"))
    }

    @Test func armsParse() {
        #expect(MinutesArms.parse("a0") == [] && MinutesArms.parse("a3") == .all && MinutesArms.parse("a1") == [.streamingLayout, .recallPrompt])
        #expect(MinutesArms.parse("streaming,items") == [.streamingLayout, .itemsPass] && MinutesArms.parse("nonsense") == nil)
        #expect(AnswerGuards.parse("g1+g2") == .all && AnswerGuards.parse("none") == [] && AnswerGuards.parse("g1") == .threeWay)
    }
}
