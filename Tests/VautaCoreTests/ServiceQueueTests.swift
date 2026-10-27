// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Service: background queue, cancel and events")
struct ServiceQueueTests {
    static let lines = ["We reviewed the Kobaltix budget for the quarter", "Fine, we keep the budget as it is",
                        "Ana will send the numbers on Friday"]

    private func service(_ f: KnowledgeFixture, chat: ScriptedChat, events: EventLog) async -> LLMService {
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat))
        await service.setJobEventHandler { events.append($0) }
        return service
    }

    @Test func finishedMinutesEmitSuccess() async throws {
        let f = try KnowledgeFixture()
        let chat = ScriptedChat { messages, _, _ in ScriptedChat.reply(ScriptedChat.minutesJSON(messages)) }
        let events = EventLog()
        let service = await service(f, chat: chat, events: events)
        let id = try await f.meeting(Self.lines)
        await service.meetingEnded(id, template: .standup)
        #expect(await eventually { events.events.contains(.init(meetingID: id, kind: .minutes, outcome: .succeeded)) })
        #expect(try await f.store.cardSource(id) == "llm")
        #expect(try await f.store.minutesTemplate(id) == .standup)
        #expect(chat.calls.last?.text.contains(MinutesTemplate.standup.promptInstructions) == true)
        // Embeddings are off with these providers: no embed job was queued.
        #expect(!events.events.contains { $0.kind == .embed })
    }

    @Test func permanentFailureEmitsFailedAndStoresACode() async throws {
        let f = try KnowledgeFixture()
        let chat = ScriptedChat { _, _, _ in throw LLMError.refused }
        let events = EventLog()
        let service = await service(f, chat: chat, events: events)
        let id = try await f.meeting(Self.lines)
        await service.regenerateMinutes(id)
        #expect(await eventually { events.events.contains { $0.meetingID == id && $0.outcome == .failed(JobErrorCode.refused.localizedDescription) } })
        let job = try #require(try await f.store.jobs(for: id).first)
        #expect(job.state == .failed && job.errorCode == .refused && job.lastError == JobErrorCode.refused.localizedDescription)
        #expect(try await f.store.stringsForTest("SELECT last_error_code FROM llm_jobs WHERE meeting_id = ?", [.integer(id)]) == ["refused"])
    }

    @Test func legacyErrorTextIsShownAsItIs() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(Self.lines)
        try await f.store.executeForTest("""
            INSERT INTO llm_jobs(meeting_id, kind, state, attempts, last_error, created_at) VALUES (?, 'acta', 'failed', 6, 'HTTP 500: algo falló', 0)
            """, [.integer(id)])
        let job = try #require(try await f.store.jobs(for: id).first)
        #expect(job.errorCode == nil && job.lastError == "HTTP 500: algo falló")
    }

    @Test func busyDoesNotUseUpAttempts() async throws {
        let f = try KnowledgeFixture()
        let chat = ScriptedChat { _, _, _ in throw LLMError.busy(retryAfter: 120) }
        let events = EventLog()
        let service = await service(f, chat: chat, events: events)
        let id = try await f.meeting(Self.lines)
        await service.regenerateMinutes(id)
        #expect(await eventually { try await f.store.jobs(for: id).first?.errorCode == .busy })
        let job = try #require(try await f.store.jobs(for: id).first)
        #expect(job.state == .queued && job.attempts == 0)
        #expect(await service.status.busyUntil != nil)
        #expect(events.events.isEmpty)
    }

    @Test func cancellingAQueuedJobRemovesIt() async throws {
        let f = try KnowledgeFixture()
        let chat = ScriptedChat { messages, _, _ in ScriptedChat.reply(ScriptedChat.minutesJSON(messages)) }
        let events = EventLog()
        let service = await service(f, chat: chat, events: events)
        let id = try await f.meeting(Self.lines)
        await service.setRecording(true, meetingID: nil)   // the queue waits while recording
        await service.regenerateMinutes(id)
        await service.cancel(meetingID: id, kind: .minutes)
        #expect(events.events == [.init(meetingID: id, kind: .minutes, outcome: .cancelled)])
        #expect(try await f.store.jobs(for: id).isEmpty)
        #expect(chat.calls.isEmpty)
        // Nothing to cancel: no event.
        await service.cancel(meetingID: id, kind: .minutes)
        #expect(events.events.count == 1)
    }

    @Test func cancellingARunningJobStopsTheRequest() async throws {
        let f = try KnowledgeFixture()
        let started = Gate()
        let chat = ScriptedChat { _, _, _ in
            await started.release()
            try await Task.sleep(for: .seconds(3_600))   // a long request; cancellation ends it
            return ScriptedChat.reply("{}")
        }
        let events = EventLog()
        let service = await service(f, chat: chat, events: events)
        let id = try await f.meeting(Self.lines)
        await service.regenerateMinutes(id)
        await started.wait()
        await service.cancel(meetingID: id, kind: .minutes)
        // The request lasts an hour: the job can only end because cancelling stopped it.
        #expect(await eventually { events.events.contains(.init(meetingID: id, kind: .minutes, outcome: .cancelled)) })
        #expect(try await f.store.jobs(for: id).isEmpty)
        #expect(try await f.store.cardSource(id) == nil)
    }
}
