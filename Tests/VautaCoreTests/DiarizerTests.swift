// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AVFoundation
import Foundation
import Testing
@testable import VautaCore

/// A stand-in for the neural analyzer: no model, a speaker that depends on the window's time, and an optional delay or
/// gate to make the diarizer fall behind on purpose.
final class ScriptedAnalyzer: WindowAnalyzing, @unchecked Sendable {
    private let lock = NSLock()
    private let centres: [[Float]]
    private let speakerAt: @Sendable (Double) -> Int
    private let delay: TimeInterval
    private let gate: DispatchSemaphore?
    private var random = TestRandom(seed: 99)
    private(set) var starts: [Int] = []
    private(set) var windows: [[Float]] = []
    var keepsWindows = false
    private var entered = DispatchSemaphore(value: 0)

    init(speakers: Int = 3, delay: TimeInterval = 0, gate: DispatchSemaphore? = nil, speakerAt: @escaping @Sendable (Double) -> Int = { _ in 0 }) {
        var r = TestRandom(seed: 5)
        centres = (0..<speakers).map { _ in r.unitVector() }
        self.speakerAt = speakerAt
        self.delay = delay
        self.gate = gate
    }

    var analysed: Int { lock.withLock { starts.count } }

    /// Blocks until `analyze` has been entered (the gate then holds it).
    func waitUntilEntered() { entered.wait() }

    func analyze(window: [Float], startSample: Int) throws -> WindowRecord {
        entered.signal()
        gate?.wait()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return lock.withLock {
            starts.append(startSample)
            if keepsWindows { windows.append(window) }
            let speaker = speakerAt(Double(startSample + SegmentationGeometry.windowSamples / 2) / 16_000)
            var embeddings = [[Float]?](repeating: nil, count: 3)
            embeddings[0] = random.around(centres[speaker], noise: 0.03)
            return WindowRecord(startSample: startSample, classes: SyntheticRecords.classes(local: [0]), embeddings: embeddings,
                                usableSeconds: [6, 0, 0])
        }
    }
}

/// 100 ms chunks like the Others pipe makes, in the speech analyzer's usual format (16 kHz, mono, Int16) or any other.
enum ChunkMaker {
    static func format(rate: Double = 16_000, float: Bool = false) -> AVAudioFormat {
        AVAudioFormat(commonFormat: float ? .pcmFormatFloat32 : .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: false)!
    }

    /// `value(i)` is the sample at absolute index `i` of this chunk's rate.
    static func chunk(_ format: AVAudioFormat, from first: Int, frames: Int, value: (Int) -> Float) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            if format.commonFormat == .pcmFormatInt16 {
                buffer.int16ChannelData![0][i] = Int16(max(-1, min(1, value(first + i))) * 32767)
            } else {
                buffer.floatChannelData![0][i] = value(first + i)
            }
        }
        return buffer
    }
}

@Suite("Diarizer")
struct DiarizerTests {
    private func push(_ diarizer: Diarizer, seconds: Int, format: AVAudioFormat = ChunkMaker.format(), skipping: Set<Int> = [],
                      value: (Int) -> Float = { _ in 0.1 }) -> [Double] {
        let frames = Int(format.sampleRate / 10)
        var durations: [Double] = []
        for i in 0..<(seconds * 10) where !skipping.contains(i) {
            let buffer = ChunkMaker.chunk(format, from: i * frames, frames: frames, value: value)
            let began = ContinuousClock.now
            diarizer.push(buffer, startFrame: AVAudioFramePosition(i * frames))
            durations.append(Double((ContinuousClock.now - began).components.attoseconds) / 1e18)
        }
        return durations
    }

    private func waitUntil(timeout: TimeInterval = 240, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    }

    // MARK: Backpressure

    @Test func pushNeverWaitsForASlowAnalyzer() async throws {
        let gate = DispatchSemaphore(value: 0)
        let analyzer = ScriptedAnalyzer(gate: gate)
        var config = DiarizationConfig()
        config.stepSeconds = 2
        let diarizer = Diarizer(config: config, maxCatchUpWindows: 3, makeAnalyzer: { analyzer })
        // 60 s of audio handed over in one burst: 26 windows are due while the analyzer is held at the gate (it takes as long as the
        // test wants). Every push returning is the proof that none waited for it.
        _ = push(diarizer, seconds: 60)
        for _ in 0..<100 { gate.signal() }
        let run = try #require(await diarizer.finish())
        let stats = diarizer.currentStats
        #expect(stats.skippedWindows > 0, "it fell behind and skipped windows")
        #expect(stats.droppedChunks == 0)
        #expect(analyzer.analysed < 26 + 5, "it analysed fewer windows than the audio holds")
        #expect(run.skippedWindows == stats.skippedWindows)
        #expect(run.totalSamples == 60 * 16_000, "the clock still covers all the audio")
        #expect(run.records.last!.startSample + SegmentationGeometry.windowSamples >= 59 * 16_000, "the end of the audio was analysed")
    }

    @Test func aFullQueueDropsChunksAndCountsThem() async throws {
        let gate = DispatchSemaphore(value: 0)
        let analyzer = ScriptedAnalyzer(gate: gate)
        let diarizer = Diarizer(maxPendingChunks: 120, makeAnalyzer: { analyzer })
        _ = push(diarizer, seconds: 10)         // exactly one window: the analyzer is entered and held at the gate
        analyzer.waitUntilEntered()
        // the queue is stuck inside the analyzer: 120 chunks wait, the other 30 are dropped, and nobody blocks
        _ = push(diarizer, seconds: 15)   // the analyzer is held at the gate: returning at all is the proof that a full queue never blocks the caller
        #expect(diarizer.currentStats.droppedChunks == 30)
        for _ in 0..<100 { gate.signal() }
        let run = try #require(await diarizer.finish())
        #expect(run.totalSamples > 0)
        #expect(diarizer.currentStats.droppedChunks == 30)
    }

    @Test func afterFinishNothingIsAccepted() async {
        let diarizer = Diarizer(makeAnalyzer: { ScriptedAnalyzer() })
        _ = push(diarizer, seconds: 12)
        _ = await diarizer.finish()
        let before = diarizer.currentStats
        _ = push(diarizer, seconds: 5)
        #expect(diarizer.currentStats == before)
    }

    // MARK: Timebase

    @Test func windowsFollowTheTranscribersFrameCounterAcrossDroppedChunks() async throws {
        let analyzer = ScriptedAnalyzer()
        analyzer.keepsWindows = true
        let diarizer = Diarizer(makeAnalyzer: { analyzer })
        // sample value encodes the absolute index; chunks 40...44 (4.0 s to 4.5 s) never arrive
        let missing = Set(40..<45)
        func value(_ i: Int) -> Float { Float(i % 20_000) / 40_000 }
        _ = push(diarizer, seconds: 14, format: ChunkMaker.format(float: true), skipping: missing, value: value)
        _ = try #require(await diarizer.finish())
        #expect(analyzer.starts.prefix(3) == [0, 32_000, 64_000], "windows start on the 2 s grid of the shared counter")
        for (start, window) in zip(analyzer.starts, analyzer.windows) {
            for k in stride(from: 0, to: window.count, by: 997) {
                let absolute = start + k
                let gap = (64_000..<72_000).contains(absolute)
                let expected: Float = absolute >= 14 * 16_000 ? 0 : gap ? 0 : value(absolute)
                #expect(abs(window[k] - expected) < 1e-6, "sample \(absolute) sits where the counter says")
            }
        }
    }

    @Test func otherSampleRatesAreConvertedOnTheSameClock() async throws {
        let analyzer = ScriptedAnalyzer()
        analyzer.keepsWindows = true
        let diarizer = Diarizer(makeAnalyzer: { analyzer })
        _ = push(diarizer, seconds: 25, format: ChunkMaker.format(rate: 48_000, float: true), value: { _ in 0.2 })
        let run = try #require(await diarizer.finish())
        // the converter holds back about 60 ms (its filter delay) at the end and returns its output in uneven blocks
        #expect(abs(run.totalSamples - 25 * 16_000) < 1_200, "48 kHz chunks keep the 16 kHz clock")
        #expect(analyzer.starts.prefix(3) == [0, 32_000, 64_000])
        // converted chunks are laid end to end: a constant signal has no zero-filled gap or click in a full window
        let full = analyzer.windows.dropFirst().prefix(5)
        #expect(!full.isEmpty && full.allSatisfy { $0.allSatisfy { abs($0 - 0.2) < 0.05 } }, "no gaps between resampled chunks")
    }

    // MARK: Labels and sink

    @Test func finalSegmentsGetTheProvisionalLabelOfTheirTime() async throws {
        // speaker 0 until 40 s, speaker 1 after
        let analyzer = ScriptedAnalyzer(speakerAt: { $0 < 40 ? 0 : 1 })
        var config = DiarizationConfig()
        config.liveReclusterSeconds = 10_000   // this test is about the labels, not about re-clustering
        let diarizer = Diarizer(config: config, maxCatchUpWindows: 1_000, makeAnalyzer: { analyzer })
        for second in 0..<80 {
            let format = ChunkMaker.format()
            for tenth in 0..<10 {
                diarizer.push(ChunkMaker.chunk(format, from: 0, frames: 1_600, value: { _ in 0.1 }),
                              startFrame: AVAudioFramePosition((second * 10 + tenth) * 1_600))
            }
        }
        waitUntil { diarizer.currentStats.windows >= 30 }
        let early = try #require(diarizer.provisionalSpeaker(start: 10, end: 14))
        let late = try #require(diarizer.provisionalSpeaker(start: 62, end: 66))
        #expect(early.ordinal == 1 && late.ordinal == 2, "live labels are 'Speaker k' by first appearance")
        #expect(early.id == nil, "a live label is not a stored speaker")
        #expect((early.confidence ?? 0) > 0.9)
        #expect(diarizer.provisionalSpeaker(start: 500, end: 504) == nil, "no window covers a time that has not happened")
        _ = await diarizer.finish()
        #expect(diarizer.provisionalSpeaker(start: 10, end: 14) == nil, "a spent diarizer answers nothing")
    }

    @Test func analysedWindowsReachTheSinkInOrderAndInBatches() async throws {
        let batches = Locked<[[Diarizer.SinkWindow]]>([])
        let diarizer = Diarizer(makeAnalyzer: { ScriptedAnalyzer() }, windowSink: { batch in batches.withLock { $0.append(batch) } })
        _ = push(diarizer, seconds: 40)
        let run = try #require(await diarizer.finish())
        let all = batches.withLock { $0 }
        #expect(all.dropLast().allSatisfy { $0.count >= Diarizer.sinkBatch }, "batches, not one call per window")
        #expect(all.flatMap { $0.map(\.seq) } == Array(0..<run.records.count), "every window exactly once, in order")
        #expect(all.flatMap { $0.map(\.record.startSample) } == run.records.map(\.startSample))
    }

    @Test func modelsThatFailToLoadLeaveTheRecordingUntouched() async {
        struct Broken: Error {}
        let diagnostics = Locked<[String]>([])
        let diarizer = Diarizer(makeAnalyzer: { throw Broken() }, onDiagnostic: { message in diagnostics.withLock { $0.append(message) } })
        _ = push(diarizer, seconds: 30)
        let run = await diarizer.finish()
        #expect(run == nil)
        #expect(diarizer.currentStats.unavailable)
        #expect(diagnostics.withLock { $0.count } == 1, "one content-free notice")
    }

    @Test func aCancelledDiarizerProducesNothing() async {
        let diarizer = Diarizer(makeAnalyzer: { ScriptedAnalyzer() })
        _ = push(diarizer, seconds: 20)
        diarizer.cancel()
        _ = push(diarizer, seconds: 5)
        #expect(await diarizer.finish() == nil)
    }
}

/// A value shared with a closure the diarizer calls from its own queue.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}
