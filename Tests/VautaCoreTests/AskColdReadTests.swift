// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// A question about a meeting the model has not read yet gets the whole visible transcript, however slow the reading is: it never
/// answers from a short excerpt because it would take too long (blind run 4 of the integrated model: 59 of 156 cold questions answered from about
/// 2,000 tokens scored 0.52 against 0.78 with the whole transcript). A reading in flight is joined, never waited behind.
@Suite("Ask: a cold meeting is read whole")
struct AskColdReadTests {
    /// A meeting of about 6,000 tokens with one line the questions are about.
    /// `seconds`: instead of a `rate`, the speed at which reading the whole meeting takes this long.
    static func rig(rate: Double = 150, seconds: Double? = nil, recording: Bool) async throws -> (LLMService, WarmChat, KnowledgeFixture, Int64) {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        var lines = (0..<300).map { "Line \($0) of the long meeting about the roadmap and the hiring plan for the next quarter, number \($0)" }
        lines[150] = "The Kobaltix budget was approved for the quarter after a long review"
        let id = try await f.meeting(lines, locale: "en-US", outputLocale: "en-US")
        let chat = WarmChat { _, _, _ in ScriptedChat.reply(#"{"found": false, "answer": "", "claims": []}"#) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        if let seconds {
            // What Ask measures: the system message, the people with the rules, and the transcript.
            let segments = try await f.store.citableSegments(id)
            let people = await service.streamingPeople(meetingID: id, entities: [], selfEntity: nil, documents: false)
            let tokens = PromptText.tokens([.system(VautaPrompts.system), people, VautaPrompts.streamingTranscriptMessage(segments)])
            chat.rate = Double(tokens) / seconds
        } else {
            chat.rate = rate
        }
        await service.setWarmCadence(.init(startDelay: 0, minInterval: 0, minCharacters: 1, maxInterval: 0, lowPowerInterval: 0))
        if recording { await service.setRecording(true, meetingID: id) }
        return (service, chat, f, id)
    }

    static func ask(_ chat: WarmChat) -> ScriptedChat.Call? { chat.calls.last { $0.options.purpose == .ask } }

    /// Since 2026-10-15: a cold question waits for the whole read with no time limit, and the Ask card says it is reading.
    @Test func aColdQuestionReportsTheReadingStageWhileItWaits() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting((0..<40).map { "Line \($0) of the meeting about the roadmap" }, locale: "en-US", outputLocale: "en-US")
        let chat = WarmChat { _, options, _ in
            options.onPrefill?(2_000, 6_000)
            try await Task.sleep(for: .milliseconds(400))
            return ScriptedChat.reply(#"{"found": false, "answer": "", "claims": []}"#)
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        let seen = Locked([(stage: LLMService.Stage?, ask: Bool, fraction: Double?)]())
        await service.setStatusHandler { status in seen.withLock { $0.append((status.stage, status.activityIsAsk, status.prefill?.fraction)) } }
        _ = try await service.ask("What happened?", meetingID: id)
        let reading = seen.withLock { $0 }.filter { $0.stage == .readingTranscript && $0.ask }
        #expect(!reading.isEmpty, "the Ask card shows the reading while the question waits")
        #expect(reading.contains { ($0.fraction ?? 0) > 0.3 && ($0.fraction ?? 1) < 0.4 })
    }

    @Test func aSlowColdReadAfterTheMeetingStillSendsTheWholeMeeting() async throws {
        let (service, chat, _, id) = try await Self.rig(rate: 150, recording: false)
        _ = try await service.ask("What happened with the Kobaltix budget?", meetingID: id)
        let call = try #require(Self.ask(chat))
        #expect(call.text.contains("<<<TRANSCRIPT\n") && !call.text.contains("<<<EXCERPTS FROM YOUR MEETINGS"), "the whole transcript, not an excerpt")
        #expect(call.options.slot == .ask && call.options.reusePrefix, "its prefix is kept for the next question")
        #expect(PromptText.tokens(call.messages) > 4_000, "the whole meeting: \(PromptText.tokens(call.messages))")
    }

    @Test func aSlowColdReadWhileRecordingSendsTheWholeMeetingAndKeepsTheMeetingPrefix() async throws {
        // Even at a speed where reading takes minutes: no excerpt, and no background reading started in its place.
        let (service, chat, _, id) = try await Self.rig(seconds: 120, recording: true)
        _ = try await service.ask("What happened with the Kobaltix budget?", meetingID: id)
        let call = try #require(Self.ask(chat))
        #expect(call.text.contains("<<<TRANSCRIPT\n") && !call.text.contains("<<<EXCERPTS FROM YOUR MEETINGS"))
        #expect(call.options.slot == .meeting && call.options.reusePrefix)
        try await Task.sleep(for: .milliseconds(200))
        #expect(chat.reads.isEmpty, "the question reads the meeting itself; it does not queue a reading for the next question")
    }

    @Test func aFastReaderSendsTheWholeMeetingAndKeepsItsPrefix() async throws {
        let (service, chat, _, id) = try await Self.rig(rate: 1_000_000, recording: false)
        _ = try await service.ask("What happened with the Kobaltix budget?", meetingID: id)
        let call = try #require(Self.ask(chat))
        #expect(call.text.contains("<<<TRANSCRIPT\n") && !call.text.contains("<<<EXCERPTS FROM YOUR MEETINGS"))
        #expect(call.options.slot == .ask && call.options.reusePrefix)
    }

    @Test func aReadingInFlightIsJoinedNotWaitedFor() async throws {
        // A reading of this meeting is running (slow); the question goes to the model with the whole transcript and the meeting's
        // prefix at once, and does not wait for the reading to end (the engine makes the reading step aside and continues from it).
        let (service, chat, _, id) = try await Self.rig(rate: 150, recording: true)
        chat.readDelay = .seconds(3_600)
        let reading = Task { await service.readMeetingNow(id) }
        #expect(await ServiceWarmTests.eventually { !chat.reads.isEmpty }, "the reading started")
        // The reading lasts an hour: the question coming back at all is the proof that it did not wait for it.
        _ = try await service.ask("What happened with the Kobaltix budget?", meetingID: id)
        let call = try #require(Self.ask(chat))
        #expect(call.text.contains("<<<TRANSCRIPT\n") && !call.text.contains("<<<EXCERPTS FROM YOUR MEETINGS"))
        #expect(call.options.slot == .meeting && call.options.reusePrefix)
        reading.cancel()
    }

    @Test func aWarmMeetingCostsOnlyWhatWasAddedSinceTheLastReading() async throws {
        let (service, chat, _, id) = try await Self.rig(rate: 150, recording: true)
        chat.kept = 8_000
        await service.readMeetingNow(id)
        #expect(chat.reads.count == 1)
        _ = try await service.ask("What happened with the Kobaltix budget?", meetingID: id)
        let call = try #require(Self.ask(chat))
        #expect(call.text.contains("<<<TRANSCRIPT\n") && call.options.slot == .meeting, "read already: nothing to wait for")
    }
}
