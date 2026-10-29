// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// A model server's minutes and live notes ask for their shape as `response_format`, and a server that rejects it (400, 415, 422) is
/// asked once more without it, by the one retry every caller shares.
@Suite("Model server: structured output in the minutes and the live notes")
struct ServerStructuredOutputTests {
    private static func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Every key anywhere in a JSON value.
    private static func keys(_ value: Any) -> Set<String> {
        if let d = value as? [String: Any] { return Set(d.keys).union(d.values.flatMap { keys($0) }) }
        if let a = value as? [Any] { return a.reduce(into: Set<String>()) { $0.formUnion(keys($1)) } }
        return []
    }

    private static func schemaName(_ options: ChatOptions) -> String? {
        if case .jsonSchema(let name, _)? = options.responseFormat { return name }
        return nil
    }

    private func run(_ f: KnowledgeFixture, _ id: Int64, chat: ScriptedChat, contextTokens: Int, onDevice: Bool) async throws -> LLMService.JobEvent.Outcome? {
        let events = EventLog()
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: contextTokens, onDevice: onDevice))
        await service.setMinutesExtraction(.legacy)
        await service.setMinutesQuestions(.legacy)
        await service.setJobEventHandler { events.append($0) }
        await service.regenerateMinutes(id)
        #expect(await eventually { events.events.contains { $0.meetingID == id && $0.kind == .minutes } })
        let outcome = events.events.last?.outcome
        await service.waitUntilQueueIdle()
        return outcome
    }

    private static func blocksThenFinal() -> ScriptedChat {
        ScriptedChat { messages, _, _ in
            messages.last?.content.contains("ONLY one block") == true
                ? ScriptedChat.reply(MinutesSmallWindowTests.extract(messages)) : ScriptedChat.reply(MinutesSmallWindowTests.finalReply)
        }
    }

    @Test func theServerSchemaKeepsTheShapeAndDropsWhatOnlyTheGrammarNeeds() throws {
        let schema = OutputSchemas.minutesExtract(.init(segments: [1, 2, 3], entities: [7]))
        let data = schema.serverJSONSchemaData()
        let root = try Self.json(data)
        #expect(Self.keys(root).isDisjoint(with: ["maxLength", "minLength", "pattern", "minItems"]))
        #expect(root["required"] as? [String] == ["summary", "topics", "decisions", "tasks", "entities", "open_questions"])
        #expect(root["additionalProperties"] as? Bool == false)
        // The keys reach the server in the order the model writes them.
        let text = String(decoding: data, as: UTF8.self)
        let order = ["\"summary\":", "\"topics\":", "\"decisions\":", "\"tasks\":", "\"entities\":", "\"open_questions\":"].map { text.range(of: $0)!.lowerBound }
        #expect(order == order.sorted())
        let decisions = try #require((root["properties"] as? [String: Any])?["decisions"] as? [String: Any])
        #expect(decisions["maxItems"] as? Int == 30)
        let seg = try #require(((decisions["items"] as? [String: Any])?["properties"] as? [String: Any])?["seg"] as? [String: Any])
        #expect(seg["type"] as? String == "integer" && seg["enum"] == nil, "no closed set of segment numbers")
        // A nullable date is a nullable string.
        let task = try #require(((root["properties"] as? [String: Any])?["tasks"] as? [String: Any])?["items"] as? [String: Any])
        let due = try #require((task["properties"] as? [String: Any])?["due"] as? [String: Any])
        #expect((due["anyOf"] as? [[String: Any]])?.compactMap { $0["type"] as? String } == ["string", "null"])
    }

    @Test func theSchemaReachesTheServerInTheProfilesDialect() throws {
        let schema = OutputSchemas.liveNotes().serverJSONSchemaData()
        var options = ChatOptions(model: .fast, maxTokens: 300, responseFormat: .jsonSchema(name: "live_notes", schema: schema))
        let body = try Self.json(ServerRequests.chatBody(model: "m", messages: [.user("x")], options: options, profile: .defaults(for: .ollama)))
        let format = try #require(body["response_format"] as? [String: Any])
        let named = try #require(format["json_schema"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema" && named["name"] as? String == "live_notes")
        #expect(NSDictionary(dictionary: try #require(named["schema"] as? [String: Any])).isEqual(to: try Self.json(schema)))
        // A server whose profile takes no structured output gets none.
        options.maxTokens = 301
        #expect(try Self.json(ServerRequests.chatBody(model: "m", messages: [.user("x")], options: options, profile: .defaults(for: .mlx)))["response_format"] == nil)
    }

    @Test func aServersBlocksAskForTheirShapeAndTheReasoningRequestsDoNot() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting((0..<260).map { "\(MinutesSmallWindowTests.sentence) item \($0)" })
        let chat = Self.blocksThenFinal()
        #expect(try await run(f, id, chat: chat, contextTokens: 8_192, onDevice: false) == .succeeded)
        let blocks = chat.calls.filter { $0.text.contains("<<<BLOCK") }
        #expect(blocks.count >= 2)
        #expect(blocks.allSatisfy { Self.schemaName($0.options) == "minutes" && !$0.options.thinking })
        let reasoning = chat.calls.filter(\.options.thinking)
        #expect(!reasoning.isEmpty && reasoning.allSatisfy { $0.options.responseFormat == nil })
    }

    @Test func aModelOnThisMacNeverGetsAResponseFormat() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting((0..<260).map { "\(MinutesSmallWindowTests.sentence) item \($0)" })
        let chat = Self.blocksThenFinal()
        #expect(try await run(f, id, chat: chat, contextTokens: 4_096, onDevice: true) == .succeeded)
        #expect(chat.calls.count > 2 && chat.calls.allSatisfy { $0.options.responseFormat == nil })
    }

    @Test func aServerThatRejectsTheSchemaIsAskedWithoutItForTheRestOfTheMinutes() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting((0..<260).map { "\(MinutesSmallWindowTests.sentence) item \($0)" })
        let chat = ScriptedChat { messages, options, _ in
            if options.responseFormat != nil { throw LLMError.http(422, message: "response_format is not supported") }
            return messages.last?.content.contains("ONLY one block") == true
                ? ScriptedChat.reply(MinutesSmallWindowTests.extract(messages)) : ScriptedChat.reply(MinutesSmallWindowTests.finalReply)
        }
        #expect(try await run(f, id, chat: chat, contextTokens: 8_192, onDevice: false) == .succeeded)
        #expect(chat.calls.filter { $0.options.responseFormat != nil }.count == 1, "one rejection, then no schema for the rest of the job")
        #expect(try await f.store.decisions(id).count == chat.calls.filter { $0.text.contains("<<<BLOCK") && $0.options.responseFormat == nil }.count)
    }

    @Test func aServersLiveNotesAskForTheirShapeAndRetryWithoutIt() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["We reviewed the Kobaltix budget for the quarter", "Ana sends the numbers on Friday"], locale: "en-US", outputLocale: "en-US")
        let chat = ScriptedChat { _, options, call in
            if call == 1, options.responseFormat != nil { throw LLMError.http(400, message: "bad response_format") }
            return ScriptedChat.reply(#"{"points": [], "decisions": [], "tasks": []}"#)
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat))
        await service.setRecording(true, meetingID: id)
        _ = try await service.liveNotes(meetingID: id, at: 10)
        #expect(chat.calls.count == 2)
        #expect(Self.schemaName(chat.calls[0].options) == "live_notes" && chat.calls[1].options.responseFormat == nil)
    }

    @Test func onlyARejectedSchemaIsRetried() {
        let with = ChatOptions(model: .deep, maxTokens: 10, responseFormat: .jsonObject)
        let without = ChatOptions(model: .deep, maxTokens: 10)
        for status in [400, 415, 422] { #expect(StructuredOutputRetry.rejects(LLMError.http(status, message: nil), with)) }
        #expect(!StructuredOutputRetry.rejects(LLMError.http(500, message: nil), with))
        #expect(!StructuredOutputRetry.rejects(LLMError.http(400, message: nil), without))
        #expect(!StructuredOutputRetry.rejects(LLMError.contextLengthExceeded(message: nil), with))
    }
}
