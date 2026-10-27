// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Synchronization
import Testing
@testable import VautaMLX
@testable import VautaCore

/// The engine's rules for reading a meeting while it is recorded, on the installed model (`VAUTA_LLM_MODEL_DIR`): a question steps in
/// front of a reading, a memory warning drops the Ask prefix and pauses reading, and a stopped recording pins the prefix for its minutes.
@Suite("Language model: reading the meeting, pre-emption, memory warning, pin", .serialized, .gpuExclusive,
       .enabled(if: ProcessInfo.processInfo.environment["VAUTA_LLM_MODEL_DIR"] != nil, "needs the installed model"))
struct LanguageModelWarmingEngineTests {
    static func lines(_ count: Int) -> [ChatMessage] {
        [.system("You write the minutes of meetings."),
         .user((0..<count).map { "[S\($0)] Line \($0) of the meeting about the roadmap, the hiring plan and the budget number \($0)." }.joined(separator: "\n"))]
    }

    @Test(.timeLimit(.minutes(5))) func aQuestionForTheSamePrefixStepsInFrontOfTheReadingAndWhatWasReadStays() async throws {
        let engine = LanguageModelEngine(store: LanguageModelSelfTest.store())
        try await engine.load()
        await engine.setPrefillChunk(128)
        let messages = Self.lines(500)
        let reading = Task { try await engine.prefillPrefix(messages, slot: .meeting) }
        // Wait until the reading is under way, then ask for the same prefix.
        _ = await LanguageModelSchedulingTests.eventually { await engine.keptMeetingTokens() > 0 }
        let question = Task { try await engine.generate(messages + [.user("What is the budget number?")], maxTokens: 4, sampling: DecodingSettings(), priority: .interactive, sharedPrefix: true, slot: .meeting) }
        let result = await reading.result
        guard case .failure(let error) = result else { Issue.record("the reading finished before the question arrived"); _ = try? await question.value; await engine.unload(); return }
        #expect(error is GenerationPreempted, "\(error)")
        #expect(await engine.keptMeetingTokens() > 0, "what it had read stays")
        let answer = try await question.value
        #expect(answer.reusedTokens > 0, "the question used what the reading had kept")
        await engine.unload()
    }

    @Test(.timeLimit(.minutes(5))) func aMemoryWarningDropsTheAskPrefixKeepsTheMeetingAndPausesReading() async throws {
        let engine = LanguageModelEngine(store: LanguageModelSelfTest.store())
        try await engine.load()
        try await engine.prefillPrefix(Self.lines(20), slot: .meeting)
        try await engine.prefillPrefix(Self.lines(30), slot: .ask)
        let meetingBefore = await engine.keptMeetingTokens(), askBefore = await engine.keptAskTokens()
        #expect(meetingBefore > 0 && askBefore > 0)
        await engine.memoryWarning()
        let meetingAfter = await engine.keptMeetingTokens(), askAfter = await engine.keptAskTokens()
        #expect(askAfter == 0 && meetingAfter > 0)
        #expect(await engine.isWarmingPaused)
        await #expect(throws: GenerationPreempted.self) { try await engine.prefillPrefix(Self.lines(40), slot: .meeting) }
        await engine.unload()
    }

    @Test(.timeLimit(.minutes(5))) func onlyTheServicePinsTheMeetingPrefixAndItIsKeptUntilReleased() async throws {
        let engine = LanguageModelEngine(store: LanguageModelSelfTest.store())
        try await engine.load()
        await engine.setKeepWarm(true)
        try await engine.prefillPrefix(Self.lines(20), slot: .meeting)
        #expect(await !engine.isMeetingPinned)
        await engine.setKeepWarm(false)
        #expect(await !engine.isMeetingPinned, "the engine does not pin what it cannot know the minutes will use: a short recording, another job's prefix")
        await engine.pinMeetingPrefix()
        #expect(await engine.isMeetingPinned, "the service that read the meeting keeps it for the minutes")
        await engine.unpinMeetingPrefix()
        #expect(await !engine.isMeetingPinned)
        await engine.unload()
    }
}

@Suite("Gate: who may pre-empt a reading")
struct WorkGateWaiterTests {
    @Test func onlyAJobAboveAPriorityIsAWaiterAboveIt() async throws {
        let gate = MLXWorkGate()
        // The holder keeps the gate until the test lets go: no fixed delay decides when the waiters have registered.
        let release = Mutex(false), holding = Mutex(false)
        let holder = Task {
            try await gate.run(.warm) {
                holding.withLock { $0 = true }
                while !release.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
            }
        }
        #expect(await LanguageModelSchedulingTests.eventually { holding.withLock { $0 } })
        #expect(!gate.hasWaiter(above: .warm))
        let interactive = Task { try await gate.run(.interactive) {} }
        let bulk = Task { try await gate.run(.bulk) {} }
        #expect(await LanguageModelSchedulingTests.eventually { gate.waiting == 2 }, "both are queued behind the holder")
        #expect(gate.hasWaiter(above: .warm), "a question is waiting for what the reading holds")
        #expect(gate.hasWaiter(above: .bulk))
        #expect(!gate.hasWaiter(above: .interactive))
        release.withLock { $0 = true }
        _ = try await (holder.value, interactive.value, bulk.value)
        #expect(!gate.hasWaiter(above: .warm))
    }
}
