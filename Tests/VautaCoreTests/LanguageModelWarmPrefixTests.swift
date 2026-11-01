// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Synchronization
import Testing
@testable import VautaMLX
@testable import VautaCore

/// Reading a meeting's transcript into the kept prefix while it is recorded (the tiny model): the same text as a cold run, only the
/// new lines read at the end, and a stopped or rewound reading leaves a state that is still exact.
@Suite("Language model: reading the meeting as it is recorded", .serialized, .gpuExclusive)
struct LanguageModelWarmPrefixTests {
    /// The transcript's closing marker and the minutes instruction, as ids.
    static let closing: [Int32] = [11, 12, 13, 14, 15, 16]
    static let instruction: [Int32] = (0..<40).map { Int32(100 + $0) }

    static func transcript(_ n: Int) -> [Int32] { Array(LanguageModelGenerationTests.prompt(700, seed: 21).prefix(n)) }

    static func engine() throws -> Gemma4Engine {
        let e = try LanguageModelEngineTests.engine()
        e.fixedChunk = 64
        return e
    }

    static func cold(_ engine: Gemma4Engine, _ prompt: [Int32]) async throws -> GenerationResult {
        engine.dropKeptPrefix()
        return try await engine.generate(GenerationRequest(prompt: prompt, maxTokens: 6, sharedPrefix: nil))
    }

    @Test func fiveTicksThenTheMinutesPromptReadsOnlyTheEnd() async throws {
        let engine = try Self.engine()
        let full = Self.transcript(600) + Self.closing
        for tick in 1...5 {
            let p = Self.transcript(200 + tick * 80) + Self.closing
            let reused = try await engine.prefillPrefix(p, prefixLength: p.count, slot: .meeting)
            // From the last chunk boundary before the previous tick's end, where a cold reading also stops.
            let previous = 200 + (tick - 1) * 80 + Self.closing.count - 16
            if tick > 1 { #expect(reused > previous - 64 && reused <= previous && reused % 64 == 0, "tick \(tick) continued from the last one: \(reused)") }
        }
        #expect(engine.keptPrefixTokens(.meeting) == full.count - 16)
        let prompt = full + Self.instruction
        let warm = try await engine.generate(GenerationRequest(prompt: prompt, maxTokens: 6, sharedPrefix: full.count, slot: .meeting))
        #expect(warm.reusedTokens >= full.count - 32, "reused \(warm.reusedTokens) of \(full.count)")
        let coldRun = try await Self.cold(engine, prompt)
        #expect(warm.tokens == coldRun.tokens, "the same text as a cold run")
    }

    @Test func ticksAndQuestionsInBetweenLeaveTheKeysAndValuesOfOneColdReading() async throws {
        let engine = try Self.engine()
        for tick in 1...5 {
            let p = Self.transcript(200 + tick * 80) + Self.closing
            try await engine.prefillPrefix(p, prefixLength: p.count, slot: .meeting)
            // A question in between: its own lines and its answer are read past the prefix, which is then cut back.
            _ = try await engine.generate(GenerationRequest(prompt: p + Self.instruction, maxTokens: 30, sharedPrefix: p.count, slot: .meeting))
        }
        let warm = engine.keptValues(.meeting)
        engine.dropKeptPrefix()
        let full = Self.transcript(600) + Self.closing
        try await engine.prefillPrefix(full, prefixLength: full.count, slot: .meeting)
        #expect(!warm.isEmpty && engine.keptValues(.meeting) == warm, "the same chunks, so the same bits")
    }

    @Test func aChangeNearTheEndOrEarlyRewindsAndStillEqualsACold() async throws {
        let engine = try Self.engine()
        let full = Self.transcript(500) + Self.closing
        try await engine.prefillPrefix(full, prefixLength: full.count, slot: .meeting)
        // A late edit (the last segment finalised with other words) and an early one (a relabelled speaker).
        for position in [full.count - 40, 60] {
            var edited = full
            edited[position] = edited[position] % 300 + 3
            let prompt = edited + Self.instruction
            let warm = try await engine.generate(GenerationRequest(prompt: prompt, maxTokens: 6, sharedPrefix: edited.count, slot: .meeting))
            let coldRun = try await Self.cold(engine, prompt)
            #expect(warm.tokens == coldRun.tokens, "edit at \(position)")
            try await engine.prefillPrefix(full, prefixLength: full.count, slot: .meeting)
        }
    }

    @Test func aReadingThatIsStoppedKeepsWhatItDidAndTheNextOneIsExact() async throws {
        let engine = try Self.engine()
        engine.checkpointNearSpacing = 64
        let full = Self.transcript(500) + Self.closing
        struct Stop: Error {}
        let chunks = Mutex(0)
        await #expect(throws: Stop.self) {
            try await engine.prefillPrefix(full, prefixLength: full.count, slot: .meeting, checkpoint: {
                if chunks.withLock({ $0 += 1; return $0 }) > 4 { throw Stop() }
            })
        }
        let kept = engine.keptPrefixTokens(.meeting)
        #expect(kept > 0 && kept < full.count, "what was read before the stop is kept: \(kept)")
        let prompt = full + Self.instruction
        let warm = try await engine.generate(GenerationRequest(prompt: prompt, maxTokens: 6, sharedPrefix: full.count, slot: .meeting))
        #expect(warm.reusedTokens > 0, "the next request continued from it")
        #expect(warm.tokens == (try await Self.cold(engine, prompt)).tokens)
    }

    @Test func theTwoSlotsAreIndependent() async throws {
        let engine = try Self.engine()
        let a = Self.transcript(300) + Self.closing
        let b = Array(LanguageModelGenerationTests.prompt(300, seed: 5)) + Self.closing
        try await engine.prefillPrefix(a, prefixLength: a.count, slot: .meeting)
        try await engine.prefillPrefix(b, prefixLength: b.count, slot: .ask)
        #expect(engine.keptPrefixTokens(.meeting) == a.count - 16 && engine.keptPrefixTokens(.ask) == b.count - 16)
        engine.dropKeptPrefix(.ask)
        #expect(engine.keptPrefixTokens(.meeting) == a.count - 16, "dropping the Ask prefix leaves the meeting's")
    }

    @Test func prefillProgressCountsTheKeptTokensAndReachesTheTotal() async throws {
        let engine = try Self.engine()
        let first = Self.transcript(300) + Self.closing
        try await engine.prefillPrefix(first, prefixLength: first.count, slot: .meeting)
        let seen = Mutex<[(Int, Int)]>([])
        let prompt = Self.transcript(400) + Self.closing + Self.instruction
        _ = try await engine.generate(GenerationRequest(prompt: prompt, maxTokens: 3, sharedPrefix: prompt.count - Self.instruction.count, slot: .meeting,
                                                        onPrefill: { done, total in seen.withLock { $0.append((done, total)) } }))
        let values = seen.withLock { $0 }
        #expect(values.first.map { $0.0 > first.count - 16 - 64 } == true, "the bar starts high with a warm prefix: \(values.first.map { "\($0)" } ?? "")")
        #expect(zip(values, values.dropFirst()).allSatisfy { $0.0 <= $1.0 }, "monotone")
        #expect(values.last?.0 == prompt.count && values.allSatisfy { $0.1 == prompt.count })
    }

    @Test func theWarmPriorityIsBetweenBulkAndMinutes() {
        typealias P = MLXWorkGate.Priority
        #expect(P.bulk < .warm && .warm < .minutes && .minutes < .live && .live < .interactive)
        #expect(ThermalPolicy.action(for: .warm, .nominal) == .run && ThermalPolicy.action(for: .warm, .serious) == .wait)
    }

    @Test func theMeetingSlotIsKeptByEverythingThatKeepsAPrefixAndTheAskSlotGoesFirst() {
        let kept = LanguageModelEngine.trimPolicy(keepsPrefix: true, priority: .minutes, slot: .meeting)
        #expect(kept.keeping == .meeting && kept.budget == LanguageModelEngine.totalBudget)
        let expansion = LanguageModelEngine.trimPolicy(keepsPrefix: false, priority: .minutes, slot: .meeting, meetingProtected: true)
        #expect(expansion.keeping == .meeting, "a note expansion before the minutes does not throw the meeting's prefix away")
        let askWhileRecording = LanguageModelEngine.trimPolicy(keepsPrefix: true, priority: .interactive, slot: .ask, meetingProtected: true)
        #expect(askWhileRecording.keeping == .meeting, "a cold read of a past meeting while recording never evicts the live meeting's prefix")
        #expect(LanguageModelEngine.trimPolicy(keepsPrefix: true, priority: .interactive, slot: .ask).keeping == .ask)
        let bulk = LanguageModelEngine.trimPolicy(keepsPrefix: false, priority: .bulk, slot: .ask)
        #expect(bulk.keeping == nil && bulk.budget == LanguageModelEngine.minutesBudget)
        #expect(LanguageModelEngine.isSmallMac(16 << 30) && !LanguageModelEngine.isSmallMac(24 << 30))
    }

    @Test func enforcingTheBudgetDropsTheAskPrefixBeforeTheMeetings() async throws {
        let engine = try Self.engine()
        let a = Self.transcript(300) + Self.closing
        try await engine.prefillPrefix(a, prefixLength: a.count, slot: .meeting)
        try await engine.prefillPrefix(a, prefixLength: a.count, slot: .ask)
        let dropped = engine.enforceBudget(engine.cacheBytes(.meeting) + 1, keeping: .meeting)
        #expect(dropped == [.ask] && engine.keptPrefixTokens(.meeting) > 0 && engine.keptPrefixTokens(.ask) == 0)
    }
}
