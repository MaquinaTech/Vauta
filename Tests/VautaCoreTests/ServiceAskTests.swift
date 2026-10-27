// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Service: Ask, live notes and embeddings")
struct ServiceAskTests {
    static let lines = ["We reviewed the Kobaltix budget for the quarter", "Fine, we keep the budget as it is",
                        "Ana will send the numbers on Friday"]

    static func answer(_ messages: [ChatMessage]) -> String {
        guard let (id, text) = ScriptedChat.firstSegment(messages) else { return #"{"found": false, "answer": "Not found.", "claims": []}"# }
        return #"{"answer": "It stays.", "claims": [{"text": "Budget kept", "citations": [\#(id)], "quote": "\#(text.prefix(30))"}]}"#
    }

    @Test func askAnswersInTheQuestionsLanguage() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(Self.lines, locale: "en-US", outputLocale: "en-US")
        let chat = ScriptedChat { messages, _, _ in ScriptedChat.reply(Self.answer(messages)) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat))
        let result = try await service.ask("¿Qué decidimos sobre el presupuesto de Kobaltix este trimestre?", meetingID: id)
        #expect(result.answer.hasEvidence)
        #expect(chat.calls.last?.text.contains("Write everything in Spanish") == true)
        _ = try await service.ask("What did we decide about the Kobaltix budget this quarter?", meetingID: id)
        #expect(chat.calls.last?.text.contains("Write everything in English (en-US).") == true)
    }

    @Test func askWorksWhenEmbeddingsFail() async throws {
        let f = try KnowledgeFixture()
        _ = try await f.meeting(Self.lines)
        let chat = ScriptedChat { messages, _, _ in ScriptedChat.reply(Self.answer(messages)) }
        let providers = TestProviders(chat: chat, embedder: FakeEmbedder(space: EmbeddingSpace(model: "e", dimensions: 8), fails: true))
        let service = LLMService(store: f.store, providers: providers)
        let result = try await service.ask("Kobaltix budget", meetingID: nil)
        #expect(!result.passages.isEmpty && result.answer.hasEvidence)
        #expect(chat.calls.last?.text.contains("<<<EXCERPTS FROM YOUR MEETINGS") == true)
    }

    @Test func cancellingAnAskStopsWhileWaitingForTheLane() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(Self.lines)
        let gate = Gate(), started = Gate()
        let chat = ScriptedChat { messages, _, _ in
            if messages.last?.content.contains("Take notes ONLY") == true {
                await started.release()
                await gate.wait()   // live notes hold the lane
                return ScriptedChat.reply(#"{"points": [], "decisions": [], "tasks": []}"#)
            }
            return ScriptedChat.reply(Self.answer(messages))
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat))
        await service.setRecording(true, meetingID: id)
        let live = Task { try await service.liveNotes(meetingID: id, at: 30) }
        await started.wait()
        let ask = Task { try await service.ask("Kobaltix budget?", meetingID: id) }
        // The ask is in the lane's queue behind the live notes (observed, not timed).
        #expect(await eventually { await service.waiters.count == 1 })
        ask.cancel()
        // It ends while the live notes still hold the lane: the gate is only released afterwards, so a wait for the lane would never end.
        await #expect(throws: CancellationError.self) { try await ask.value }
        let leftTheQueue = await service.waiters.isEmpty, laneHeld = await service.laneBusy
        #expect(leftTheQueue && laneHeld, "it left the queue and the lane stayed with the live notes")
        await gate.release()
        _ = try await live.value
        // The lane is free again.
        let after = try await service.ask("Kobaltix budget?", meetingID: id)
        #expect(after.answer.hasEvidence)
    }

    @Test func liveNotesAreStoredAndReturned() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(Self.lines, locale: "en-US")
        let chat = ScriptedChat { messages, _, _ in
            guard let (seg, _) = ScriptedChat.firstSegment(messages) else { return ScriptedChat.reply("{}") }
            return ScriptedChat.reply(#"{"points": [{"text": "Budget stays", "seg": \#(seg)}], "decisions": [], "tasks": [{"text": "Send numbers", "owner": "Ana", "seg": \#(seg)}]}"#)
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat))
        await service.setRecording(true, meetingID: id)
        let notes = try #require(try await service.liveNotes(meetingID: id, at: 42))
        #expect(notes.points.map(\.text) == ["Budget stays"] && notes.tasks.first?.owner == "Ana" && notes.t == 42)
        #expect(chat.calls.last?.text.contains("Write everything in English (en-US).") == true)
        let stored = try await f.store.liveNotes(id)
        #expect(stored.count == 1 && stored[0].points == notes.points && stored[0].t == 42)
        // Nothing new since: no request.
        #expect(try await service.liveNotes(meetingID: id, at: 50) == nil)
        #expect(chat.calls.count == 1)
    }

    @Test func embeddingsUseTheCurrentSpaceAndReembedOnChange() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(Self.lines)
        let chat = ScriptedChat { messages, _, _ in
            // A question gets a refusal (the minutes JSON has no `found`); the meeting's minutes job gets minutes.
            ScriptedChat.reply(messages.contains { $0.content.contains("<<<QUESTION") } ? #"{"found": false, "answer": "", "claims": []}"# : ScriptedChat.minutesJSON(messages))
        }
        let old = EmbeddingSpace(model: "old-model", dimensions: 6)
        let providers = TestProviders(chat: chat, embedder: FakeEmbedder(space: old))
        let service = LLMService(store: f.store, providers: providers)
        let events = EventLog()
        await service.setJobEventHandler { events.append($0) }
        await service.meetingEnded(id)
        #expect(await eventually { events.events.contains(.init(meetingID: id, kind: .embed, outcome: .succeeded)) })
        #expect(try await f.store.chunkSpaces()[id] == [old])

        // Another model in Settings: the meeting is embedded again in the new space.
        let new = EmbeddingSpace(model: "new-model", dimensions: 10)
        providers.embedder = FakeEmbedder(space: new)
        await service.configurationChanged()
        #expect(await eventually { try await f.store.chunkSpaces()[id] == [new] })

        // Same model name, other size (e.g. a new truncation setting): seen on
        // the first query, and the stored chunks are embedded again.
        let resized = EmbeddingSpace(model: "new-model", dimensions: 4)
        providers.embedder = FakeEmbedder(space: resized)
        let result = try await service.ask("Kobaltix budget", meetingID: nil)
        #expect(!result.passages.isEmpty)
        #expect(await eventually { try await f.store.chunkSpaces()[id] == [resized] })

        // Retrieval only compares vectors of the query's space.
        let vector = try await FakeEmbedder(space: resized).embed(["Kobaltix budget"], purpose: .query).vectors[0]
        #expect(try await !f.store.retrieve("zzz", queryVector: vector, space: resized).isEmpty)
        #expect(try await f.store.retrieve("zzz", queryVector: vector, space: old).isEmpty)
    }
}
