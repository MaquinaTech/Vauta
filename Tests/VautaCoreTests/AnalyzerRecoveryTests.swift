// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AVFoundation
import Foundation
import Testing
@testable import VautaCore

/// A channel whose analyzer fails mid-recording is rebuilt and goes on at the same place; it is reported as failed only
/// when the retries run out. The analyzer is a fake: the speech service is never used.
@Suite("Transcription: analyzer recovery")
struct AnalyzerRecoveryTests {
    // MARK: Policy

    @Test func retriesWithGrowingDelaysThenGivesUp() {
        var policy = AnalyzerRetryPolicy(maxAttempts: 3, delays: [1, 3, 10], stableSeconds: 300)
        #expect(policy.failed(at: 10, runningSince: 0) == 1)
        #expect(policy.failed(at: 12, runningSince: 11) == 3)
        #expect(policy.failed(at: 16, runningSince: 15) == 10)
        #expect(policy.failed(at: 30, runningSince: 26) == nil)
    }

    @Test func aSessionThatRanLongEnoughStartsTheCountOver() {
        var policy = AnalyzerRetryPolicy(maxAttempts: 2, delays: [1], stableSeconds: 300)
        #expect(policy.failed(at: 10, runningSince: 0) == 1)
        #expect(policy.failed(at: 20, runningSince: 11) == 1)
        // ran for 10 minutes before failing: a fresh count
        #expect(policy.failed(at: 700, runningSince: 100) == 1)
        #expect(policy.attempts == 1)
    }

    // MARK: Transcriber

    /// The devices start before the analyzers are ready: what they capture meanwhile waits in the session's queue, none of it
    /// is dropped, and the session that starts is the one that holds it.
    @Test func audioFedBeforeTheAnalyzerStartsWaitsForIt() async throws {
        let rig = Rig(retry: AnalyzerRetryPolicy())
        rig.transcriber.open { _ in }
        for _ in 0..<3 { rig.feed() }
        let session = try #require(rig.factory.session(0))
        #expect(session.frames == [0, 1_600, 3_200] && rig.events.health.isEmpty, "queued, not dropped")
        try await rig.transcriber.start()
        rig.feed()
        #expect(rig.factory.count == 1 && session.frames == [0, 1_600, 3_200, 4_800])
        try await rig.transcriber.finish()
        #expect(session.finishes == [false], "finalized with what it queued")
    }

    @Test func aFailedAnalyzerIsRebuiltAndKeepsThePosition() async throws {
        let rig = Rig(retry: AnalyzerRetryPolicy(maxAttempts: 2, delays: [0]))
        try await rig.transcriber.start { _ in }
        for _ in 0..<3 { rig.feed() }
        let first = try #require(rig.factory.session(0))
        #expect(first.frames == [0, 1_600, 3_200])
        first.fail()
        try await eventually { rig.factory.count == 2 && rig.events.health.last == .ok }
        rig.feed()
        let second = try #require(rig.factory.session(1))
        #expect(second.frames == [4_800], "the new analyzer goes on where the timeline is")
        #expect(first.finishes == [true], "the failed one is cancelled")
        #expect(rig.events.failures == 0)
        #expect(rig.events.health == [.lagging, .ok])
        try await rig.transcriber.finish()
        #expect(second.finishes == [false], "the working one is finalized")
    }

    @Test func itReportsFailedOnlyWhenTheRetriesRunOut() async throws {
        let rig = Rig(retry: AnalyzerRetryPolicy(maxAttempts: 2, delays: [0]))
        try await rig.transcriber.start { _ in }
        rig.factory.failingStarts = 2
        try #require(rig.factory.session(0)).fail()
        try await eventually { rig.events.failures == 1 }
        #expect(rig.factory.count == 3, "two rebuilds were tried")
        rig.feed()
        #expect((0..<3).allSatisfy { rig.factory.session($0)?.frames.isEmpty ?? false }, "no analyzer takes audio any more")
        try await rig.transcriber.finish()
        #expect(rig.factory.session(2)?.finishes.last == true)
        #expect(rig.events.failures == 1)
    }

    @Test func anAnalyzerThatNeverStartedIsCancelledNotFinalized() async throws {
        let rig = Rig(retry: AnalyzerRetryPolicy())
        rig.factory.failingStarts = 1
        await #expect(throws: FakeAnalyzerError.self) { try await rig.transcriber.start { _ in } }
        try await rig.transcriber.finish()
        #expect(rig.factory.session(0)?.finishes == [true])
    }

    @Test func stoppingDuringARebuildDoesNotWaitForIt() async throws {
        let rig = Rig(retry: AnalyzerRetryPolicy(maxAttempts: 3, delays: [0.5]))
        try await rig.transcriber.start { _ in }
        try #require(rig.factory.session(0)).fail()
        try await eventually { rig.events.health == [.lagging] }
        try await rig.transcriber.finish()
        // the rebuild was cancelled: past its delay, still no new analyzer
        try await Task.sleep(for: .seconds(1))
        #expect(rig.factory.count == 1, "no analyzer is started after the stop")
        #expect(rig.events.failures == 0)
    }

    @Test func failuresAfterTheStopAreIgnored() async throws {
        let rig = Rig(retry: AnalyzerRetryPolicy(maxAttempts: 3, delays: [0]))
        try await rig.transcriber.start { _ in }
        try await rig.transcriber.finish()
        try #require(rig.factory.session(0)).fail()
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.factory.count == 1)
        #expect(rig.events.failures == 0)
    }
}

// MARK: Fakes

struct FakeAnalyzerError: Error {}

final class FakeAnalyzerSession: AnalyzerSession, @unchecked Sendable {
    private let lock = NSLock()
    private let startFails: Bool
    private var onFailure: (@Sendable (Error) -> Void)?
    private var closed = false
    private var _frames: [AVAudioFramePosition] = []
    private var _finishes: [Bool] = []

    init(startFails: Bool) { self.startFails = startFails }

    var frames: [AVAudioFramePosition] { lock.withLock { _frames } }
    var finishes: [Bool] { lock.withLock { _finishes } }

    func start(onSegment: @escaping @Sendable (Segment) -> Void, onFailure: @escaping @Sendable (Error) -> Void) async throws {
        if startFails {
            lock.withLock { closed = true }
            throw FakeAnalyzerError()
        }
        lock.withLock { self.onFailure = onFailure }
    }

    func yield(_ buffer: AVAudioPCMBuffer, startFrame: AVAudioFramePosition) -> AnalyzerYield {
        lock.withLock {
            guard !closed else { return .terminated }
            _frames.append(startFrame)
            return .enqueued(remaining: 100)
        }
    }

    func finish(cancel: Bool) async throws {
        lock.withLock {
            closed = true
            _finishes.append(cancel)
        }
    }

    /// The analysis fails, as the speech service would mid-recording.
    func fail() {
        let report = lock.withLock {
            closed = true
            return onFailure
        }
        report?(FakeAnalyzerError())
    }
}

final class FakeAnalyzerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [FakeAnalyzerSession] = []
    private var _failingStarts = 0

    /// How many of the next sessions fail to start.
    var failingStarts: Int {
        get { lock.withLock { _failingStarts } }
        set { lock.withLock { _failingStarts = newValue } }
    }

    var count: Int { lock.withLock { sessions.count } }
    func session(_ index: Int) -> FakeAnalyzerSession? { lock.withLock { sessions.indices.contains(index) ? sessions[index] : nil } }

    func make() -> any AnalyzerSession {
        lock.withLock {
            let session = FakeAnalyzerSession(startFails: _failingStarts > 0)
            _failingStarts = max(0, _failingStarts - 1)
            sessions.append(session)
            return session
        }
    }
}

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var _health: [ChannelHealth] = []
    private var _failures = 0

    var health: [ChannelHealth] { lock.withLock { _health } }
    var failures: Int { lock.withLock { _failures } }
    func add(_ health: ChannelHealth) { lock.withLock { _health.append(health) } }
    func failed() { lock.withLock { _failures += 1 } }
}

private struct Rig {
    let factory = FakeAnalyzerFactory()
    let events = Events()
    let transcriber: ChannelTranscriber
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    init(retry: AnalyzerRetryPolicy) {
        let factory = factory
        let events = events
        transcriber = ChannelTranscriber(channel: .others, format: format, retry: retry) { _ in factory.make() }
        transcriber.onHealth = { events.add($0) }
        transcriber.onFailure = { _, _ in events.failed() }
    }

    func feed() {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
        buffer.frameLength = 1_600
        transcriber.feed(buffer)
    }
}

private func eventually(_ condition: () -> Bool) async throws {
    // generous: the whole suite runs in parallel and may keep the cooperative pool busy for a while
    let deadline = ContinuousClock.now + .seconds(600)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("the condition was not met in time")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
