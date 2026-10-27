// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Deleting a meeting drops what the model kept of that meeting, and only that.
@Suite("Service: deleting a meeting and the transcripts the model kept")
struct ServiceWarmDeletionTests {
    static let verified = #"{"found": true, "answer": "Kept.", "claims": [{"text": "Kept", "citations": [$ID], "quote": "Fine, we keep the budget as it is"}]}"#

    @Test func deletingAnotherMeetingDuringARecordingLeavesTheLiveMeetingAlone() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let past = try await f.meeting(Array(ServiceWarmTests.lines.prefix(2)), locale: "en-US", outputLocale: "en-US")
        let live = try await f.meeting(Array(ServiceWarmTests.lines.prefix(2)), locale: "en-US", outputLocale: "en-US")
        let pastLines = try await f.store.citableSegments(past)
        let chat = WarmChat { messages, options, _ in
            options.purpose == .ask ? ScriptedChat.reply(Self.verified.replacingOccurrences(of: "$ID", with: "\(pastLines[1].id)")) : ScriptedChat.reply(ScriptedChat.minutesJSON(messages))
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        await service.setWarmCadence(.init(startDelay: 0, minInterval: 0, minCharacters: 1, maxInterval: 0, lowPowerInterval: 0))
        await service.setRecording(true, meetingID: live)
        await service.readMeetingNow(live)
        let readsBefore = chat.reads.count
        let result = try await service.ask("Did we keep the budget?", meetingID: past)
        #expect(result.answer.kind == .verified)
        #expect(chat.calls.last { $0.options.purpose == .ask }?.options.slot == .ask, "a past meeting uses the Ask slot")
        await service.forgetKeptTranscripts(meetingID: past)
        #expect(chat.dropped == [[.ask]], "only the Ask slot is dropped; the live meeting's slot and pin stay")
        #expect(await service.warmMeetingID == live, "the live meeting is still read")
        await service.readMeetingNow(live)
        #expect(chat.reads.count == readsBefore + 1)
        // The meeting being recorded can still be deleted: its own slot goes.
        await service.forgetKeptTranscripts(meetingID: live)
        #expect(chat.dropped.last == [.meeting] && chat.dropped.count == 2)
        #expect(await service.warmMeetingID == nil)
    }

    @Test func deletingAMeetingWhoseMinutesWereJustWrittenDropsTheSlotTheyKept() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(Array(ServiceWarmTests.lines.prefix(2)), locale: "en-US", outputLocale: "en-US")
        let other = try await f.meeting(Array(ServiceWarmTests.lines.prefix(2)), locale: "en-US", outputLocale: "en-US")
        let chat = WarmChat { messages, _, _ in ScriptedChat.reply(ScriptedChat.minutesJSON(messages)) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        let box = ServiceWarmTests.EventBox()
        await service.setJobEventHandler { box.add($0) }
        await service.regenerateMinutes(id)   // nothing is being recorded: the minutes keep the transcript in the meeting slot
        #expect(await ServiceWarmTests.eventually { box.contains(id) })
        await service.forgetKeptTranscripts(meetingID: other)
        #expect(chat.drops == 0, "another meeting's deletion leaves it")
        await service.forgetKeptTranscripts(meetingID: id)
        #expect(chat.dropped == [[.meeting]])
    }

    @Test func aMeetingDeletedWhileTheCallRanLeavesNothingBehind() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(Array(ServiceWarmTests.lines.prefix(2)), locale: "en-US", outputLocale: "en-US")
        let chat = WarmChat { messages, _, _ in ScriptedChat.reply(ScriptedChat.minutesJSON(messages)) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        try await f.store.deleteMeeting(id)
        await service.noteKept(.ask, meetingID: id)
        #expect(chat.dropped == [[.ask]], "the prefix that was written after the deletion is dropped at once")
    }

    @Test func retentionDropsPastTranscriptsButNotTheMeetingBeingRecorded() async throws {
        let (service, chat, _, id) = try await ServiceWarmTests.rig()
        await service.readMeetingNow(id)
        await service.forgetPastTranscripts()
        #expect(chat.dropped == [[.ask]], "the live meeting's slot stays")
        #expect(await service.warmMeetingID == id)
        await service.setRecording(false, meetingID: id)   // pinned for its minutes
        await service.forgetPastTranscripts()
        #expect(chat.dropped.last == [.ask])
        let (idle, idleChat, _, _) = try await ServiceWarmTests.rig()
        await idle.setRecording(false, meetingID: 0)
        await idle.forgetPastTranscripts()
        #expect(idleChat.dropped.last == [.ask, .meeting], "nothing is recorded or waiting: both slots go")
    }

    // MARK: A call that wrote the prefix and then failed still leaves it behind

    @Test func anAskWhoseReplyWasInvalidStillLetsTheDeletionDropTheTranscript() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(Array(ServiceWarmTests.lines.prefix(2)), locale: "en-US", outputLocale: "en-US")
        let chat = WarmChat { _, _, _ in ScriptedChat.reply("this is not an answer") }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        await #expect(throws: LLMError.self) { try await service.ask("Did we keep the budget?", meetingID: id) }
        #expect(chat.calls.contains { $0.options.slot == .ask }, "the call kept the transcript in the Ask slot")
        await service.forgetKeptTranscripts(meetingID: id)
        #expect(chat.dropped == [[.ask]])
    }

    @Test func anAskThatWasCutAtTheLengthLimitStillLetsTheDeletionDropTheTranscript() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(Array(ServiceWarmTests.lines.prefix(2)), locale: "en-US", outputLocale: "en-US")
        let chat = WarmChat { _, _, _ in throw LLMError.outputTruncated }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        await #expect(throws: LLMError.self) { try await service.ask("Did we keep the budget?", meetingID: id) }
        await service.forgetKeptTranscripts(meetingID: id)
        #expect(chat.dropped == [[.ask]])
    }

    @Test func aCancelledAskStillLetsTheDeletionDropTheTranscript() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(Array(ServiceWarmTests.lines.prefix(2)), locale: "en-US", outputLocale: "en-US")
        let chat = WarmChat { _, _, _ in try await Task.sleep(for: .seconds(60)); return ScriptedChat.reply("") }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        let task = Task { try await service.ask("Did we keep the budget?", meetingID: id) }
        #expect(await ServiceWarmTests.eventually { chat.calls.contains { $0.options.purpose == .ask } })
        task.cancel()
        _ = await task.result
        await service.forgetKeptTranscripts(meetingID: id)
        #expect(chat.dropped == [[.ask]], "the meeting was not deleted by the cancel, and its prefix is dropped when it is")
    }

    @Test func minutesThatFailedAfterReadingStillLetTheDeletionDropTheTranscript() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(Array(ServiceWarmTests.lines.prefix(2)), locale: "en-US", outputLocale: "en-US")
        let chat = WarmChat { _, _, _ in throw LLMError.http(400, message: "bad") }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        let box = ServiceWarmTests.EventBox()
        await service.setJobEventHandler { box.add($0) }
        await service.regenerateMinutes(id)
        #expect(await ServiceWarmTests.eventually { box.contains(id) }, "the job ended in failure")
        await service.forgetKeptTranscripts(meetingID: id)
        #expect(chat.dropped == [[.meeting]])
    }

    @Test func aFailedCallForAnotherMeetingDoesNotHideTheFirstOnesTranscript() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let first = try await f.meeting(Array(ServiceWarmTests.lines.prefix(2)), locale: "en-US", outputLocale: "en-US")
        let second = try await f.meeting(Array(ServiceWarmTests.lines.prefix(2)), locale: "en-US", outputLocale: "en-US")
        let chat = WarmChat { _, _, _ in ScriptedChat.reply("this is not an answer") }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        await #expect(throws: LLMError.self) { try await service.ask("Q?", meetingID: first) }
        await #expect(throws: LLMError.self) { try await service.ask("Q?", meetingID: second) }
        await service.forgetKeptTranscripts(meetingID: first)
        #expect(chat.dropped == [[.ask]], "the slot may still hold the first meeting: it is dropped")
    }
}
