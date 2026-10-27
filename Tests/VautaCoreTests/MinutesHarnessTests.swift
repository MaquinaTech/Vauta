// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The integrated model's minutes request with the items before the summary: the switch, the wording, the grammar and the sampling.
@Suite("Minutes: items-first request")
struct MinutesHarnessTests {
    static func request(_ wording: VautaPrompts.ItemWording, recall: Bool = false) -> VautaPrompts.MinutesRequest {
        var r = VautaPrompts.MinutesRequest(meetingDate: Date(timeIntervalSince1970: 1_104_537_600), language: OutputLanguage(Locale(identifier: "en-US")), recall: recall)
        r.wording = wording
        return r
    }

    static func keys(_ shape: String) throws -> [String] {
        // The top-level keys of the shape, in order.
        let data = Data(shape.utf8)
        var depth = 0, keys: [String] = [], current = "", inString = false, expectKey = true, escaped = false
        for byte in String(decoding: data, as: UTF8.self) {
            if inString {
                if escaped { escaped = false; current.append(byte); continue }
                if byte == "\\" { escaped = true; continue }
                if byte == "\"" { inString = false; if depth == 1, expectKey { keys.append(current); expectKey = false }; continue }
                current.append(byte)
                continue
            }
            switch byte {
            case "\"": inString = true; current = ""
            case "{", "[": depth += 1
            case "}", "]": depth -= 1
            case ",": if depth == 1 { expectKey = true }
            default: break
            }
        }
        return keys
    }

    @Test func theSwitchParsesAndNamesItsParts() {
        #expect(MinutesHarness.parse("old") == .legacy && MinutesHarness.parse("new") == .shipped)
        #expect(MinutesHarness.parse("items,rule") == [.itemsFirst, .outcomeRule])
        #expect(MinutesHarness.parse("new,t03") == MinutesHarness.shipped.union(.cool) && MinutesHarness.parse("new,t03")?.temperature == 0, "greedy wins over 0.3")
        #expect(MinutesHarness.parse("nonsense") == nil)
        #expect(MinutesHarness.legacy.names == "legacy" && MinutesHarness.shipped.names == "items+rule+recall+greedy+count")
        #expect(MinutesHarness.legacy.temperature == nil && MinutesHarness.shipped.temperature == 0, "the new request decodes greedily")
        #expect(MinutesHarness.parse("items,rule,recall,count")?.temperature == nil)
        #expect(MinutesHarness.greedy.temperature == 0 && MinutesHarness.cool.temperature == 0.3)
    }

    @Test func theAppRunsTheWholeJudgedRequestOnTheIntegratedModelOnly() {
        #expect(MinutesHarnessRelease.harness(integrated: true) == .shipped && MinutesHarnessRelease.harness(integrated: false) == .legacy)
        #expect(MinutesHarnessRelease.harness(integrated: true) == [.itemsFirst, .outcomeRule, .recall, .count, .greedy], "the request the blind judge measured, with the expected counts and greedy decoding")
        #expect(!MinutesHarnessRelease.harness(integrated: true).contains(.cool), "the evaluation-only temperature is never shipped")
    }

    @Test func theReleasedRequestAsksForTheExpectedItemsAndDecodesGreedily() async throws {
        let (_, chat, _) = try await Self.rig(MinutesHarnessRelease.released)
        let call = try #require(Self.firstMinutesCall(chat))
        guard case .object(let props)? = call.options.outputSchema,
              case .array(_, let dmin, _)? = props.first(where: { $0.name == "decisions" })?.schema,
              case .array(_, let tmin, _)? = props.first(where: { $0.name == "tasks" })?.schema else { Issue.record("no arrays"); return }
        #expect(dmin >= 1 && tmin >= 0 && call.text.contains("usually has about") && call.options.temperature == 0)
    }

    @Test func theItemsComeBeforeTheSummaryAndTheKeysAreTheSame() throws {
        let old = try Self.keys(VautaPrompts.minutesJSON), new = try Self.keys(VautaPrompts.minutesJSONItemsFirst)
        #expect(old == ["title", "summary", "topics", "decisions", "tasks", "entities", "open_questions"])
        #expect(new == ["title", "topics", "decisions", "tasks", "entities", "open_questions", "summary"])
        #expect(Set(old) == Set(new), "the stored keys do not change")
        let plain = VautaPrompts.minutesInstruction(Self.request(.init())).content
        let first = VautaPrompts.minutesInstruction(Self.request(.init(itemsFirst: true))).content
        #expect(plain.contains(VautaPrompts.minutesJSON) && !plain.contains(VautaPrompts.minutesJSONItemsFirst))
        #expect(first.contains(VautaPrompts.minutesJSONItemsFirst) && !first.contains(VautaPrompts.minutesJSON))
    }

    @Test func theGrammarFollowsTheSameOrder() {
        func names(_ schema: OutputSchema) -> [String] {
            guard case .object(let props) = schema else { return [] }
            return props.map(\.name)
        }
        #expect(names(OutputSchemas.minutes()) == ["title", "summary", "topics", "decisions", "tasks", "entities", "open_questions"])
        #expect(names(OutputSchemas.minutes(itemsFirst: true)) == ["title", "topics", "decisions", "tasks", "entities", "open_questions", "summary"])
    }

    @Test func theOutcomeRuleReplacesTheSummaryClauseOnEveryWordingAndOnlyWhenOn() {
        for definitions in [false, true] {
            for recall in [false, true] {
                let off = VautaPrompts.minutesInstruction(Self.request(.init(definitions: definitions), recall: recall)).content
                #expect(off.contains("with the essentials") && !off.contains("ending with the outcomes"), "definitions \(definitions) recall \(recall)")
                let on = VautaPrompts.minutesInstruction(Self.request(.init(definitions: definitions, outcomeRule: true), recall: recall)).content
                #expect(on.contains("ending with the outcomes") && !on.contains("with the essentials"), "definitions \(definitions) recall \(recall)")
                #expect(on.contains("with the vote") && on.contains("previous session's minutes") && on.contains("unless the speakers said so"))
                #expect(!on.contains("written after the lists above"), "the plain order does not point at lists above")
                let both = VautaPrompts.minutesInstruction(Self.request(.init(definitions: definitions, itemsFirst: true, outcomeRule: true), recall: recall)).content
                #expect(both.contains("written after the lists above"))
            }
        }
    }

    @Test func theRecallWordingKeepsItsCue() {
        for definitions in [false, true] {
            let on = VautaPrompts.minutesInstruction(Self.request(.init(definitions: definitions), recall: true)).content
            #expect(on.contains("List each one separately"), "definitions \(definitions)")
            let off = VautaPrompts.minutesInstruction(Self.request(.init(definitions: definitions), recall: false)).content
            #expect(!off.contains("List each one separately"), "definitions \(definitions)")
        }
    }

    @Test func minutesWrittenInEitherOrderAreValidatedAlike() throws {
        let segments: [Int64: CitableSegment] = [5: CitableSegment(id: 5, channel: .others, start: 12, text: "We agreed to approve the budget of twelve thousand euros.")]
        let item = #""decisions": [{"text": "Approve the budget", "seg": 5, "quote": "agreed to approve the budget"}], "tasks": [], "entities": [], "open_questions": ["Who signs?"]"#
        let old = "{\"title\": \"Budget\", \"summary\": \"The budget was approved.\", \"topics\": [\"budget\"], \(item)}"
        let new = "{\"title\": \"Budget\", \"topics\": [\"budget\"], \(item), \"summary\": \"The budget was approved.\"}"
        func run(_ json: String) throws -> ValidatedMinutes {
            try VautaPrompts.validateMinutes(json, segments: segments, candidates: [], selfEntity: nil, language: "en")
        }
        let a = try run(old), b = try run(new)
        #expect(a.summary == b.summary && a.title == b.title && a.topics == b.topics && a.openQuestions == b.openQuestions)
        #expect(a.decisions.map(\.text) == b.decisions.map(\.text) && b.decisions.count == 1)
    }

    @Test func theExpectedCountFollowsTheLengthOfTheMeetingWithinBounds() {
        func meeting(minutes: Double) -> [CitableSegment] {
            [CitableSegment(id: 1, channel: .others, start: 100, text: "a"), CitableSegment(id: 2, channel: .others, start: 100 + minutes * 60, text: "b")]
        }
        #expect(MinutesHarness.expected(segments: []) == .init(decisions: 2, tasks: 1) && MinutesHarness.expected(segments: meeting(minutes: 5)) == .init(decisions: 2, tasks: 1))
        #expect(MinutesHarness.expected(segments: meeting(minutes: 40)) == .init(decisions: 4, tasks: 3))
        #expect(MinutesHarness.expected(segments: meeting(minutes: 300)) == .init(decisions: 6, tasks: 4), "capped")
        #expect(MinutesHarness.parse("items,count") == [.itemsFirst, .count] && MinutesHarness.count.names == "count")
    }

    @Test func theCountArmSaysTheNumbersAndAsksForOneFewerInTheGrammar() {
        let off = VautaPrompts.minutesInstruction(Self.request(.init())).content
        #expect(!off.contains("usually has about"))
        var wording = VautaPrompts.ItemWording()
        wording.expected = .init(decisions: 4, tasks: 3)
        #expect(VautaPrompts.minutesInstruction(Self.request(wording)).content.contains("usually has about 4 decisions and 3 tasks"))
        guard case .object(let props) = OutputSchemas.minutes(itemsFirst: true, atLeast: (3, 2)),
              case .array(_, let dmin, _)? = props.first(where: { $0.name == "decisions" })?.schema,
              case .array(_, let tmin, _)? = props.first(where: { $0.name == "tasks" })?.schema else { Issue.record("no arrays"); return }
        #expect(dmin == 3 && tmin == 2)
        guard case .object(let plain) = OutputSchemas.minutes(), case .array(_, let zero, _)? = plain.first(where: { $0.name == "decisions" })?.schema else { Issue.record("no array"); return }
        #expect(zero == 0)
    }

    // MARK: Through the service

    static func rig(_ harness: MinutesHarness?, integrated: Bool = true) async throws -> (LLMService, WarmChat, Int64) {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting((0..<12).map { "Line \($0) of the meeting about the budget" }, locale: "en-US", outputLocale: "en-US")
        let chat = WarmChat { messages, _, _ in ScriptedChat.reply(ScriptedChat.minutesJSON(messages)) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: integrated))
        if let harness { await service.setMinutesHarness(harness) }
        let box = ServiceWarmTests.EventBox()
        await service.setJobEventHandler { box.add($0) }
        await service.regenerateMinutes(id)
        #expect(await ServiceWarmTests.eventually { box.contains(id) })
        await service.waitUntilQueueIdle()
        return (service, chat, id)
    }

    static func firstMinutesCall(_ chat: WarmChat) -> ScriptedChat.Call? {
        chat.calls.first { $0.options.purpose == .minutes && $0.messages.last?.content.contains("Return exactly this JSON") == true }
    }

    static func order(_ call: ScriptedChat.Call?) -> [String] {
        guard case .object(let props)? = call?.options.outputSchema else { return [] }
        return props.map(\.name)
    }

    @Test func theIntegratedModelGetsTheItemsFirstRequestByDefault() async throws {
        let (_, chat, _) = try await Self.rig(nil)
        let call = try #require(Self.firstMinutesCall(chat))
        #expect(Self.order(call).last == "summary" || Self.order(call).firstIndex(of: "summary")! > Self.order(call).firstIndex(of: "decisions")!)
    }

    @Test func theLegacyRequestStaysAvailableToTheEvaluation() async throws {
        let (service, chat, id) = try await Self.rig(.legacy)
        let call = try #require(Self.firstMinutesCall(chat))
        #expect(Self.order(call).prefix(2) == ["title", "summary"])
        #expect(call.options.temperature == nil)
        #expect(!call.text.contains("ending with the outcomes") && !call.text.contains("List each one separately"))
        #expect(try await service.store.decisions(id).count == 1)
    }

    @Test func theNewRequestSendsTheItemsFirstGrammarTheRuleTheRecallCueAndStoresTheSameMinutes() async throws {
        let (service, chat, id) = try await Self.rig(.shipped)
        let call = try #require(Self.firstMinutesCall(chat))
        #expect(Self.order(call) == ["title", "topics", "decisions", "tasks", "entities", "open_questions", "summary"])
        #expect(call.text.contains(VautaPrompts.minutesJSONItemsFirst) && call.text.contains("ending with the outcomes") && call.text.contains("List each one separately"))
        #expect(call.options.temperature == 0, "greedy decoding")
        #expect(call.text.contains("usually has about"))
        #expect(try await service.store.decisions(id).count == 1)
    }

    @Test func theCountArmReachesTheRequestAndTheGrammar() async throws {
        let (_, chat, _) = try await Self.rig([.itemsFirst, .count])
        let call = try #require(Self.firstMinutesCall(chat))
        #expect(call.text.contains("usually has about 2 decisions and 1 tasks"))
        guard case .object(let props)? = call.options.outputSchema, case .array(_, let dmin, _)? = props.first(where: { $0.name == "decisions" })?.schema else { Issue.record("no array"); return }
        #expect(dmin == 1)
    }

    @Test func theTemperatureArmsReachTheRequestAndOnlyTheRequestOfTheIntegratedModel() async throws {
        let (_, card, _) = try await Self.rig([.itemsFirst, .outcomeRule, .recall])
        #expect(Self.firstMinutesCall(card)?.options.temperature == nil)
        let (_, greedy, _) = try await Self.rig([.itemsFirst, .greedy])
        #expect(Self.firstMinutesCall(greedy)?.options.temperature == 0)
        let (_, cool, _) = try await Self.rig([.itemsFirst, .cool])
        #expect(Self.firstMinutesCall(cool)?.options.temperature == 0.3)
        let (_, other, _) = try await Self.rig(.shipped, integrated: false)
        let call = try #require(Self.firstMinutesCall(other))
        #expect(call.options.temperature == nil && Self.order(call).prefix(2) == ["title", "summary"], "a backend that is not the integrated model keeps its request")
    }
}
