// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The closing pass: one more request over the last stretch of the meeting, so the tasks agreed at the end are not lost.
@Suite("Minutes: the closing pass")
struct MinutesClosingPassTests {
    static func segments(_ n: Int, step: Double = 10, speaker: (Int) -> Int64? = { _ in nil }) -> [CitableSegment] {
        (0..<n).map { i in
            CitableSegment(id: Int64(100 + i), channel: .others, start: Double(i) * step, text: "Line \(i) of the meeting about the budget",
                           speaker: speaker(i).map { SpeakerTag(id: $0, ordinal: 1, confidence: 0.9) })
        }
    }

    // MARK: The window

    @Test func theClosingStretchIsTheLongerOfTwelvePercentAndSixMinutes() {
        let line: (CitableSegment) -> String = VautaPrompts.streamingLine
        // 45 minutes: 12% is 5.4 minutes, so the last 6 minutes (36 segments of 10 s, plus the one at the threshold).
        let short = try! #require(MinutesWindows.closing(Self.segments(270), tokens: 100_000, line: line))
        #expect(short.segments.count == 37 && short.last == 269 + 100)
        // Two hours: 12% is 14.4 minutes.
        let long = try! #require(MinutesWindows.closing(Self.segments(720), tokens: 100_000, line: line))
        #expect(long.segments.count == 87 && long.segments.last!.start - long.segments.first!.start <= 14.4 * 60)
    }

    @Test func theWindowStartsAtTheBeginningOfTheSpeakersTurn() {
        // Everyone speaks as speaker 7 from segment 200 on: the window reaches back to where that turn began.
        let segs = Self.segments(270) { $0 >= 200 ? 7 : Int64($0 % 2 + 1) }
        let window = try! #require(MinutesWindows.closing(segs, tokens: 100_000, line: VautaPrompts.streamingLine))
        #expect(window.first == 300, "the turn began at segment index 200: \(window.first)")
    }

    @Test func theWindowIsCutFromTheFrontToFitTheRoom() {
        let window = try! #require(MinutesWindows.closing(Self.segments(270), tokens: 200, line: VautaPrompts.streamingLine))
        #expect(PromptText.tokens(window.segments.map(VautaPrompts.streamingLine).joined(separator: "\n")) <= 260)
        #expect(window.last == 369 && window.segments.count < 37, "it keeps the end")
    }

    @Test func aMeetingTooShortHasNoClosingStretch() {
        #expect(MinutesWindows.closing(Self.segments(5), tokens: 3_000, line: VautaPrompts.streamingLine) == nil)
    }

    // MARK: Integrated model

    /// A closing reply with one task that cites the last segment of the window it was asked about.
    static func task(_ ids: Set<Int>, _ segs: [CitableSegment]) -> String {
        let seg = segs.first { Int($0.id) == ids.max() }!
        return #"{"decisions": [], "tasks": [{"text": "Send the minutes to the board", "owner": null, "owner_id": null, "due": null, "seg": \#(seg.id), "quote": "\#(seg.text.prefix(30))"}]}"#
    }

    static func rig(lines: Int = 100, integrated: Bool = true, forced: Bool = true, reply: @escaping @Sendable (Set<Int>, [CitableSegment]) -> String) async throws -> (LLMService, WarmChat, Int64, [CitableSegment]) {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let text = (0..<lines).map { "Line \($0) of the meeting about the budget and the vote of the board number \($0)" }
        let id = try await f.meeting(text, locale: "en-US", outputLocale: "en-US")
        let segs = try await f.store.citableSegments(id)
        let chat = WarmChat { messages, options, _ in
            if messages.last?.content.contains("The meeting ends with segments") == true {
                guard case .object(let props)? = options.outputSchema, case .array(let decision, _, _)? = props.first?.schema,
                      case .object(let fields) = decision, case .integers(let ids)? = fields.first(where: { $0.name == "seg" })?.schema else { return ScriptedChat.reply("{}") }
                return ScriptedChat.reply(reply(ids, segs))
            }
            return ScriptedChat.reply(ScriptedChat.minutesJSON(messages))
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: integrated))
        if forced { await service.setMinutesExtraction(.shipped) }
        return (service, chat, id, segs)
    }

    static func closingCalls(_ chat: WarmChat) -> [ScriptedChat.Call] {
        chat.calls.filter { $0.messages.last?.content.contains("The meeting ends with segments") == true }
    }

    @Test func theIntegratedModelRunsOneWindowOnTheKeptPrefixAndItsTaskJoinsTheMinutes() async throws {
        let (service, chat, id, segs) = try await Self.rig(reply: Self.task)
        try await MinutesRecallPassTests.finish(service, id)
        let calls = Self.closingCalls(chat)
        try #require(calls.count == 1, "one request, however long the meeting")
        let call = calls[0]
        #expect(call.options.reusePrefix, "it shares the meeting's kept prefix")
        #expect((call.options.maxSeconds ?? .infinity) <= max(LLMService.closingFloor, 1), "capped: \(String(describing: call.options.maxSeconds))")
        #expect(call.messages.last?.content.contains("what people agreed to do next") == true)
        guard case .object(let props)? = call.options.outputSchema, case .array(let decision, _, _)? = props.first?.schema, case .object(let fields) = decision,
              case .integers(let allowed)? = fields.first(where: { $0.name == "seg" })?.schema else { Issue.record("no seg restriction"); return }
        #expect(allowed.count < segs.count && allowed.contains(Int(segs.last!.id)) && !allowed.contains(Int(segs.first!.id)), "only the end of the meeting")
        let tasks = try await service.store.tasks(id)
        #expect(tasks.contains { $0.text == "Send the minutes to the board" })
        let diagnostics = await service.lastMinutesDiagnostics
        #expect(diagnostics?.counts["closing.addedTasks"] == 1)
    }

    @Test func anUnreadableClosingReplyAddsNothingAndTheMinutesAreStillWritten() async throws {
        let (service, chat, id, _) = try await Self.rig { _, _ in "I could not find anything." }
        try await MinutesRecallPassTests.finish(service, id)
        #expect(Self.closingCalls(chat).count == 1)
        #expect(try await service.store.decisions(id).isEmpty == false, "the first pass's decision is there")
        #expect(try await service.store.tasks(id).isEmpty)
    }

    @Test func theClosingPassIsOffWithoutItsArmOrItsExtraction() async throws {
        let (service, chat, id, _) = try await Self.rig { _, _ in "{}" }
        await service.setMinutesArms([.streamingLayout])
        try await MinutesRecallPassTests.finish(service, id)
        #expect(Self.closingCalls(chat).isEmpty, "the arm is off")
        let (legacy, legacyChat, legacyID, _) = try await Self.rig { _, _ in "{}" }
        await legacy.setMinutesExtraction(.legacy)
        try await MinutesRecallPassTests.finish(legacy, legacyID)
        #expect(Self.closingCalls(legacyChat).isEmpty, "the old extraction never had it")
    }

    @Test func theReleaseChoiceRunsTheClosingPassOnTheIntegratedModelOnly() async throws {
        // No forced extraction: the app's own choice per backend (MinutesRelease).
        let (integrated, integratedChat, integratedID, _) = try await Self.rig(forced: false, reply: Self.task)
        try await MinutesRecallPassTests.finish(integrated, integratedID)
        #expect(Self.closingCalls(integratedChat).count == 1, "the integrated model runs the new extraction")
        #expect(try await integrated.store.tasks(integratedID).contains { $0.text == "Send the minutes to the board" })
        let (server, serverChat, serverID, _) = try await Self.rig(integrated: false, forced: false, reply: Self.task)
        try await MinutesRecallPassTests.finish(server, serverID)
        #expect(Self.closingCalls(serverChat).isEmpty, "a model that is not the integrated one keeps the old extraction")
    }

    // MARK: Apple's window (map-reduce)

    static let sentence = "We went through the quarterly budget of the Kobaltix project line by line and agreed on the next steps for"

    @Test func appleRunsItAfterTheBlocksAndValidatesItsItemsDirectly() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting((0..<260).map { "\(Self.sentence) item \($0)" })
        let chat = ScriptedChat { messages, _, _ in
            let last = messages.last?.content ?? ""
            if last.contains("ONLY one block") { return ScriptedChat.reply(MinutesSmallWindowTests.extract(messages)) }
            if last.contains("This is the end of the meeting") {
                guard let (seg, text) = ScriptedChat.firstSegment(messages) else { return ScriptedChat.reply("{}") }
                return ScriptedChat.reply(#"{"decisions": [], "tasks": [{"text": "Send the closing numbers", "owner": null, "owner_id": null, "due": null, "seg": \#(seg), "quote": "\#(text.prefix(40))"}]}"#)
            }
            return ScriptedChat.reply(MinutesSmallWindowTests.finalReply)
        }
        let events = EventLog()
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 4_096, onDevice: true))
        await service.setMinutesExtraction(.shipped)
        await service.setJobEventHandler { events.append($0) }
        await service.regenerateMinutes(id)
        #expect(await eventually { events.events.contains { $0.meetingID == id && $0.kind == .minutes } })
        #expect(events.events.last?.outcome == .succeeded)
        await service.waitUntilQueueIdle()
        let closing = chat.calls.filter { $0.text.contains("This is the end of the meeting") }
        try #require(closing.count == 1)
        #expect(PromptText.tokens(closing[0].messages) + closing[0].options.maxTokens <= 4_096, "it fits the window with its answer")
        #expect(closing[0].text.contains("<<<TRANSCRIPT") && !closing[0].text.contains("<<<NOTES ON THE BLOCKS"), "the closing stretch itself, not the digest")
        let blocks = chat.calls.filter { $0.text.contains("<<<BLOCK") }.count
        let tasks = try await f.store.tasks(id)
        #expect(tasks.contains { $0.text == "Send the closing numbers" }, "the closing task is there: \(tasks.map(\.text).suffix(3))")
        #expect(tasks.count == blocks + 1, "the blocks' tasks, and the closing one added: \(tasks.count) tasks, \(blocks) blocks")
        // The digest still wrote the language parts only.
        #expect(try await f.store.card(id)?.summary == "The team went through the whole budget.")
    }

    @Test func appleSkipsItWhenTheMeetingFitOneRequest() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting((0..<10).map { "\(Self.sentence) item \($0)" })
        let chat = ScriptedChat { messages, _, _ in ScriptedChat.reply(ScriptedChat.minutesJSON(messages)) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 4_096, onDevice: true))
        await service.setMinutesExtraction(.shipped)
        let events = EventLog()
        await service.setJobEventHandler { events.append($0) }
        await service.regenerateMinutes(id)
        #expect(await eventually { events.events.contains { $0.meetingID == id && $0.kind == .minutes } })
        await service.waitUntilQueueIdle()
        #expect(!chat.calls.contains { $0.text.contains("This is the end of the meeting") })
    }

    @Test func appleFailsOpenOnAnUnreadableClosingReply() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting((0..<260).map { "\(Self.sentence) item \($0)" })
        let chat = ScriptedChat { messages, _, _ in
            let last = messages.last?.content ?? ""
            if last.contains("ONLY one block") { return ScriptedChat.reply(MinutesSmallWindowTests.extract(messages)) }
            if last.contains("This is the end of the meeting") { return ScriptedChat.reply("no json at all", finish: .length) }
            return ScriptedChat.reply(MinutesSmallWindowTests.finalReply)
        }
        let events = EventLog()
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 4_096, onDevice: true))
        await service.setMinutesExtraction(.shipped)
        await service.setJobEventHandler { events.append($0) }
        await service.regenerateMinutes(id)
        #expect(await eventually { events.events.contains { $0.meetingID == id && $0.kind == .minutes } })
        #expect(events.events.last?.outcome == .succeeded)
        await service.waitUntilQueueIdle()
        #expect(try await f.store.tasks(id).isEmpty == false)
    }
}
