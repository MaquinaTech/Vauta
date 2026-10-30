// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Reading the meeting while it is recorded (the integrated model), through the service with a model that records what it was asked to read.
@Suite("Service: reading the meeting as it is recorded")
struct ServiceWarmTests {
    static let lines = ["We reviewed the Kobaltix budget for the quarter", "Fine, we keep the budget as it is",
                        "Ana will send the numbers on Friday", "Then we close the meeting early today"]

    /// Fixtures stay alive for the whole test run: a store whose folder is removed fails every write of a background job.
    static let kept = Locked([KnowledgeFixture]())
    static func retain(_ f: KnowledgeFixture) { kept.withLock { $0.append(f) } }

    static func rig(integrated: Bool = true, room: Bool = true) async throws -> (LLMService, WarmChat, KnowledgeFixture, Int64) {
        let f = try KnowledgeFixture()
        Self.retain(f)
        let id = try await f.meeting(Array(lines.prefix(2)), locale: "en-US", outputLocale: "en-US")
        let chat = WarmChat { messages, _, _ in ScriptedChat.reply(ScriptedChat.minutesJSON(messages)) }
        chat.hasRoom = room
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: integrated))
        await service.setWarmCadence(.init(startDelay: 0, minInterval: 0, minCharacters: 1, maxInterval: 0, lowPowerInterval: 0))
        await service.setRecording(true, meetingID: id)
        return (service, chat, f, id)
    }

    /// Polls until `condition` holds; the limit only bounds a hang (a loaded Mac can starve the whole suite for a long time).
    static func eventually(_ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline { if await condition() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
        return await condition()
    }

    /// Since 2026-10-15: with "While recording" on Apple Intelligence the integrated model stays idle until the recording ends.
    @Test func theIntegratedModelStaysIdleWhileRecordingWhenLiveWorkGoesToApple() async throws {
        let f = try KnowledgeFixture()
        Self.retain(f)
        let id = try await f.meeting(Array(Self.lines.prefix(2)), locale: "en-US", outputLocale: "en-US")
        let chat = WarmChat { messages, _, _ in ScriptedChat.reply(ScriptedChat.minutesJSON(messages)) }
        let providers = TestProviders(chat: chat, contextTokens: 65_536, integrated: true)
        providers.liveModel = ScriptedChat { _, _, _ in ScriptedChat.reply("{}") }
        let service = LLMService(store: f.store, providers: providers)
        await service.setWarmCadence(.init(startDelay: 0, minInterval: 0, minCharacters: 1, maxInterval: 0, lowPowerInterval: 0))
        await service.setRecording(true, meetingID: id)
        await service.readMeetingNow(id)
        await service.segmentSaved(meetingID: id, characters: 5_000)
        try await Task.sleep(for: .milliseconds(200))
        #expect(chat.reads.isEmpty && chat.calls.isEmpty, "no reading and no model call while recording")
        await service.setRecording(false, meetingID: id)
        #expect(chat.pins == 0 && chat.reads.isEmpty && chat.calls.isEmpty, "nothing was read, so nothing is pinned")
        #expect(await service.warmMeetingID == nil)
        // The minutes read the transcript cold, in the meeting slot.
        let events = EventBox()
        await service.setJobEventHandler { events.add($0) }
        await service.regenerateMinutes(id)
        #expect(await Self.eventually { events.contains(id) })
        let minutes = try #require(chat.calls.first { $0.options.purpose == .minutes })
        #expect(minutes.options.slot == .meeting && minutes.messages.count == 4)
        #expect(chat.reads.isEmpty)
    }

    @Test func theIntegratedModelStillReadsWhileRecordingWhenLiveWorkUsesIt() async throws {
        let (service, chat, _, id) = try await Self.rig()
        await service.readMeetingNow(id)
        #expect(chat.reads.count == 1)
    }

    @Test func aTickReadsSystemPeopleAndTheTranscriptSoFarAndNothingElse() async throws {
        let (service, chat, _, id) = try await Self.rig()
        await service.readMeetingNow(id)
        let reads = chat.reads
        #expect(reads.count == 1)
        let messages = try #require(reads.first)
        #expect(messages.count == 3 && messages[0].role == "system" && messages[2].content.hasPrefix("<<<TRANSCRIPT\n") && messages[2].content.hasSuffix("\n>>>"))
        #expect(messages[1].content.contains("Rules:"), "the rules of a live answer sit before the transcript, so a transcript that grows never rereads them")
        #expect(messages[2].content.contains("Kobaltix budget") && !messages[2].content.contains("Others]") || messages[2].content.contains("Others"))
    }

    @Test func eachTickExtendsTheLastOneAtItsEnd() async throws {
        let (service, chat, f, id) = try await Self.rig()
        await service.readMeetingNow(id)
        for (i, line) in Self.lines.dropFirst(2).enumerated() {
            _ = try await f.store.append(Segment(channel: .others, start: 100 + Double(i) * 10, end: 105 + Double(i) * 10, text: line, isFinal: true), to: id)
            await service.readMeetingNow(id)
        }
        let transcripts = chat.reads.map { $0[2].content }
        #expect(transcripts.count == 3)
        for (a, b) in zip(transcripts, transcripts.dropFirst()) {
            let head = String(a.dropLast(4))   // without "\n>>>"
            #expect(b.hasPrefix(head), "the new transcript starts with the old one up to its closing marker")
        }
    }

    @Test func nothingIsReadWithoutTheIntegratedModelOrRoomOrARecording() async throws {
        let (apple, appleChat, _, id1) = try await Self.rig(integrated: false)
        await apple.readMeetingNow(id1)
        #expect(appleChat.reads.isEmpty)
        let (full, fullChat, _, id2) = try await Self.rig(room: false)
        await full.readMeetingNow(id2)
        #expect(fullChat.reads.isEmpty, "the kept prefix has no room")
        let (stopped, stoppedChat, _, id3) = try await Self.rig()
        await stopped.setRecording(false, meetingID: id3)
        await stopped.readMeetingNow(id3)
        #expect(stoppedChat.reads.isEmpty)
    }

    @Test func theDebounceWaitsForThirtySecondsAndForEnoughSpeech() async throws {
        let (service, chat, _, id) = try await Self.rig()
        await service.setWarmCadence(LLMService.WarmCadence())   // the real rules
        for _ in 0..<5 { await service.segmentSaved(meetingID: id, characters: 800) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(chat.reads.isEmpty, "not in the first 30 seconds of the recording")
        await service.setWarmCadence(.init(startDelay: 0, minInterval: 20, minCharacters: 600, maxInterval: 120, lowPowerInterval: 180))
        await service.segmentSaved(meetingID: id, characters: 100)   // 4,100 characters have arrived by now
        #expect(await Self.eventually { chat.reads.count == 1 })
        // Right after a tick: 20 seconds have not passed, and a few characters are not enough.
        await service.segmentSaved(meetingID: id, characters: 700)
        try await Task.sleep(for: .milliseconds(100))
        #expect(chat.reads.count == 1)
    }

    @Test func neverTwoReadsAtOnce() async throws {
        let (service, chat, _, id) = try await Self.rig()
        chat.readDelay = .milliseconds(150)
        for _ in 0..<6 { await service.segmentSaved(meetingID: id, characters: 700) }
        #expect(await Self.eventually { !chat.reads.isEmpty })
        try await Task.sleep(for: .milliseconds(400))
        #expect(chat.maxConcurrentReads == 1)
    }

    @Test func theMeetingIsPinnedWhenTheRecordingStopsAndReleasedWithTheMinutes() async throws {
        let (service, chat, _, id) = try await Self.rig()
        await service.readMeetingNow(id)
        await service.setRecording(false, meetingID: id)
        #expect(chat.pins == 1 && chat.unpins == 0)
        #expect(await service.warmMeetingID == id, "requests about it still use the meeting's prefix")
        let events = EventBox()
        await service.setJobEventHandler { events.add($0) }
        await service.regenerateMinutes(id)
        _ = await Self.eventually { events.contains(id) }
        let lastError = String(describing: await service.status.lastError)
        #expect(events.contains(id), "\(events.outcomes) \(lastError)")
        #expect(chat.unpins == 1, "\(lastError) the minutes are written: the prefix goes back to the idle rules")
        #expect(await service.warmMeetingID == nil)
        // The minutes of the warm meeting keep the prefix and share it with the transcript that was read.
        let minutes = chat.calls.first { $0.options.purpose == .minutes }
        #expect(minutes?.options.reusePrefix == true && minutes?.options.slot == .meeting)
        #expect(minutes?.messages.count == 4 && minutes?.messages[2].content.hasPrefix("<<<TRANSCRIPT\n") == true)
    }

    @Test func deletingTheMeetingOrErasingDropsWhatTheModelKeptOfIt() async throws {
        let (service, chat, _, id) = try await Self.rig()
        await service.readMeetingNow(id)
        await service.setRecording(false, meetingID: id)
        // Another meeting's deletion leaves it alone.
        await service.forgetKeptTranscripts(meetingID: id + 100)
        #expect(chat.drops == 0 && chat.pins == 1)
        await service.forgetKeptTranscripts(meetingID: id)
        #expect(chat.drops == 1, "the pinned transcript is dropped with its meeting")
        #expect(await service.warmMeetingID == nil)
        let (second, chat2, _, id2) = try await Self.rig()
        await second.readMeetingNow(id2)
        await second.forgetKeptTranscripts()
        #expect(chat2.drops == 1, "erasing everything drops it whichever meeting it was")
    }

    @Test func aRecordingWhereNothingWasReadPinsNothing() async throws {
        let (service, chat, _, id) = try await Self.rig()
        await service.setRecording(false, meetingID: id)
        #expect(chat.pins == 0)
        #expect(await service.warmMeetingID == nil)
    }

    final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [Int64] = []
        func add(_ e: LLMService.JobEvent) { if e.kind == .minutes { lock.withLock { ids.append(e.meetingID); outcomes.append("\(e.outcome)") } } }
        var outcomes: [String] = []
        func contains(_ id: Int64) -> Bool { lock.withLock { ids.contains(id) } }
    }
}

/// What happens to a warm meeting once its recording ends.
@Suite("Service: the warm meeting after the recording")
struct ServiceWarmAfterStopTests {
    static let verified = #"{"found": true, "answer": "Kept.", "claims": [{"text": "Kept", "citations": [$ID], "quote": "Fine, we keep the budget as it is"}]}"#

    @Test func aQuestionAfterTheRecordingGetsTheFinishedRulesAndTheBooleanWhileThePrefixIsStillKept() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(Array(ServiceWarmTests.lines.prefix(2)), locale: "en-US", outputLocale: "en-US")
        let segments = try await f.store.citableSegments(id)
        let chat = WarmChat { messages, options, _ in
            options.purpose == .ask ? ScriptedChat.reply(Self.verified.replacingOccurrences(of: "$ID", with: "\(segments[1].id)")) : ScriptedChat.reply(ScriptedChat.minutesJSON(messages))
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        await service.setAnswerGuards(.all)
        await service.setRecording(true, meetingID: id)
        await service.readMeetingNow(id)
        await service.setRecording(false, meetingID: id)
        #expect(await service.warmMeetingID == id, "the prefix is kept for the minutes")
        let result = try await service.ask("Did we keep the budget?", meetingID: id)
        #expect(result.answer.kind == .verified)
        let call = try #require(chat.calls.last { $0.options.purpose == .ask })
        guard case .tagged(_, let cases)? = call.options.outputSchema else { Issue.record("not tagged"); return }
        #expect(cases.map(\.value) == ["true", "false"], "never the three words of a live answer")
        #expect(!call.text.contains("Only what has been said up to now counts") && call.text.contains("The material is complete"))
        try #require(!chat.reads.isEmpty)
        #expect(call.options.slot == .meeting && call.messages[1].content == chat.reads[0][1].content, "the rules of the prefix are the ones it was read with")
    }

    @Test func theKeptMeetingIsReleasedWhenTheMinutesFailForGoodOrAreCancelled() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(Array(ServiceWarmTests.lines.prefix(2)), locale: "en-US", outputLocale: "en-US")
        let chat = WarmChat { _, _, _ in throw LLMError.http(400, message: "bad") }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        await service.setRecording(true, meetingID: id)
        await service.readMeetingNow(id)
        await service.setRecording(false, meetingID: id)
        #expect(await service.warmMeetingID == id && chat.pins == 1)
        let box = ServiceWarmTests.EventBox()
        await service.setJobEventHandler { box.add($0) }
        await service.regenerateMinutes(id)
        #expect(await ServiceWarmTests.eventually { box.contains(id) })
        #expect(await service.warmMeetingID == nil && chat.unpins == 1, "a failure that will not be retried gives the prefix back to the idle rules")
    }

    @Test func cancellingTheQueuedMinutesReleasesTheKeptMeeting() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(Array(ServiceWarmTests.lines.prefix(2)), locale: "en-US", outputLocale: "en-US")
        let chat = WarmChat { messages, _, _ in ScriptedChat.reply(ScriptedChat.minutesJSON(messages)) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 65_536, integrated: true))
        await service.setRecording(true, meetingID: id)
        await service.readMeetingNow(id)
        await service.setRecording(false, meetingID: id)
        await service.setExternalBusy(true)   // the job waits in the queue
        await service.regenerateMinutes(id)
        #expect(await service.warmMeetingID == id)
        await service.cancel(meetingID: id, kind: .minutes)
        #expect(await service.warmMeetingID == nil && chat.unpins == 1)
    }

    @Test func switchingTheMinutesToAnotherProviderReleasesTheKeptMeeting() async throws {
        let f = try KnowledgeFixture()
        ServiceWarmTests.retain(f)
        let id = try await f.meeting(Array(ServiceWarmTests.lines.prefix(2)), locale: "en-US", outputLocale: "en-US")
        let chat = WarmChat { messages, _, _ in ScriptedChat.reply(ScriptedChat.minutesJSON(messages)) }
        let providers = TestProviders(chat: chat, contextTokens: 65_536, integrated: true)
        let service = LLMService(store: f.store, providers: providers)
        await service.setRecording(true, meetingID: id)
        await service.readMeetingNow(id)
        await service.setRecording(false, meetingID: id)
        #expect(await service.warmMeetingID == id)
        providers.integrated = false
        await service.configurationChanged()
        #expect(await service.warmMeetingID == nil)
    }
}

@Suite("Service: reading while recording, Low Power Mode and one reading at a time")
struct ServiceWarmPowerTests {
    @Test func lowPowerModeNeverLoadsTheModelButKeepsReadingOnceItIsLoaded() async throws {
        let (service, chat, _, id) = try await ServiceWarmTests.rig()
        let flag = Locked(true)
        await service.setEnvironmentProvider { IndexerEnvironment(lowPowerMode: flag.withLock { $0 }) }
        await service.segmentSaved(meetingID: id, characters: 700)
        try await Task.sleep(for: .milliseconds(150))
        #expect(chat.reads.isEmpty, "a Mac saving energy does not load the model for the first reading")
        flag.withLock { $0 = false }
        await service.setWarmCadence(.init(startDelay: 0, minInterval: 0, minCharacters: 1, maxInterval: 0, lowPowerInterval: 0))
        await service.readMeetingNow(id)
        #expect(chat.reads.count == 1)
        flag.withLock { $0 = true }
        await service.readMeetingNow(id)
        #expect(chat.reads.count == 2, "once loaded, a reading goes on in Low Power Mode")
    }

    @Test func aQuestionAndATickShareOneGateSoOnlyOneReadingRuns() async throws {
        let (service, chat, _, id) = try await ServiceWarmTests.rig()
        chat.readDelay = .milliseconds(200)
        #expect(await service.startWarmReading(id))
        #expect(await service.startWarmReading(id) == false, "a reading is already running")
        _ = await ServiceWarmTests.eventually { !chat.reads.isEmpty }
        try await Task.sleep(for: .milliseconds(350))
        #expect(chat.reads.count == 1 && chat.maxConcurrentReads == 1)
        #expect(await service.startWarmReading(id), "the flag of the finished reading is clear")
    }
}

@Suite("Service: provisional speaker numbers and the final speakers")
struct ServiceWarmSpeakersTests {
    @Test func finalSpeakersReplaceTheProvisionalNumbersInTheMinutes() async throws {
        let (service, chat, f, id) = try await ServiceWarmTests.rig()
        let segments = try await f.store.citableSegments(id)
        await service.segmentSaved(meetingID: id, segmentID: segments[0].id, speaker: 3, characters: 10)
        await service.readMeetingNow(id)
        #expect(chat.reads.first?[2].content.contains("Speaker 3") == false && chat.reads.first?[2].content.contains("Others]") == true,
                "while recording, the line carries the channel only: a live number never enters the kept prefix")
        // Diarization ran: one final speaker (the second line, the user's), and the first line was left without one.
        try await f.store.finalizeSpeakers(meetingID: id, speakers: [SpeakerDraft(channel: .me, ordinal: 1)],
                                           assignments: [SegmentSpeakerAssignment(segmentID: segments[1].id, channel: .me, ordinal: 1)], splits: [])
        await service.setRecording(false, meetingID: id)
        let box = ServiceWarmTests.EventBox()
        await service.setJobEventHandler { box.add($0) }
        await service.regenerateMinutes(id)
        #expect(await ServiceWarmTests.eventually { box.contains(id) })
        let minutes = try #require(chat.calls.first { $0.options.purpose == .minutes })
        #expect(!minutes.text.contains("Speaker 3"), "a live number is never mixed with the final speaker list")
    }
}
