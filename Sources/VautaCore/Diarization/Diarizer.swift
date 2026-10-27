// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AVFoundation
import Foundation

/// Speaker separation of the other participants' audio while a meeting is recorded.
///
/// It is fed the same ~100 ms chunks the Others `ChannelTranscriber` gets, with the transcriber's own frame
/// counter, so both share one timebase and nothing drifts. All the work happens on a serial queue of its own:
/// `push` only takes a lock and queues the chunk, so it can never hold up capture or transcription. If the
/// diarizer falls behind it SKIPS windows (`DiarizationSession`), and if even the queue of chunks grows past
/// `maxPendingChunks` it drops chunks: the speaker labels get worse, the transcript does not.
///
/// What it keeps: the last seconds of audio in memory while a window is pending (never written anywhere) and, for
/// each analysed window, its class map and speaker embeddings. Those are voice data: they go to `windowSink` (the
/// encrypted store) and are never logged. `finish()` returns them for the final clustering.
public final class Diarizer: @unchecked Sendable {
    /// Counts for diagnostics and tests. No content.
    public struct Stats: Sendable, Equatable {
        public var windows = 0
        public var skippedWindows = 0
        /// Chunks dropped because too many were waiting.
        public var droppedChunks = 0
        /// The analyzer could not be created or failed (the models did not verify or load): nothing more is analysed.
        public var unavailable = false
    }

    /// One analysed window as the sink receives it.
    public struct SinkWindow: Sendable {
        public let seq: Int
        public let record: WindowRecord
    }

    private struct Chunk {
        let buffer: AVAudioPCMBuffer
        let start: AVAudioFramePosition
    }

    /// 10 minutes of 100 ms chunks.
    public static let defaultMaxPendingChunks = 6_000
    /// Analysed windows are handed to the sink in batches of this many (10 s at the 2 s step).
    static let sinkBatch = 5

    private let queue = DispatchQueue(label: "vauta.diarizer", qos: .utility, autoreleaseFrequency: .workItem)
    private let config: DiarizationConfig
    private let maxPending: Int
    private let maxCatchUp: Int
    private let makeAnalyzer: @Sendable () throws -> any WindowAnalyzing
    private let windowSink: (@Sendable ([SinkWindow]) -> Void)?
    private let onDiagnostic: (@Sendable (String) -> Void)?

    // Guarded by `lock`: `push` runs on capture threads, `provisionalSpeaker` on the caller's.
    private let lock = NSLock()
    private var pending: [Chunk] = []
    private var scheduled = false
    private var closed = false
    /// Set by `cancel()`: the recording was abandoned, so nothing more is analysed or handed to the sink.
    private var cancelled = false
    private var stats = Stats()
    private var published: DiarizationSession?

    // Owned by the queue.
    private var session: DiarizationSession?
    private var converter: AudioChunkConverter?
    private var unsent: [SinkWindow] = []
    private var failed = false
    /// Resampled audio is placed by the converter's own output count (see `ingest`).
    private var resampleNextInput: AVAudioFramePosition?
    private var resamplePosition = 0

    /// - Parameters:
    ///   - makeAnalyzer: builds the analyzer on the diarizer's queue when the first window is due (loading the
    ///     models is slow and must not delay the recording's start). If it throws, the diarizer stays idle.
    ///   - windowSink: called on the queue with each batch of analysed windows; it must return at once.
    ///   - maxPendingChunks: chunks that may wait for the queue before new ones are dropped.
    ///   - maxCatchUpWindows: windows that may wait for the analyzer before the oldest are skipped.
    public init(config: DiarizationConfig = DiarizationConfig(), maxPendingChunks: Int = Diarizer.defaultMaxPendingChunks,
                maxCatchUpWindows: Int = 15, makeAnalyzer: @escaping @Sendable () throws -> any WindowAnalyzing,
                windowSink: (@Sendable ([SinkWindow]) -> Void)? = nil,
                onDiagnostic: (@Sendable (String) -> Void)? = nil) {
        self.config = config
        self.maxPending = max(1, maxPendingChunks)
        self.maxCatchUp = maxCatchUpWindows
        self.makeAnalyzer = makeAnalyzer
        self.windowSink = windowSink
        self.onDiagnostic = onDiagnostic
    }

    /// With the bundled, hash-checked models.
    public convenience init(config: DiarizationConfig = DiarizationConfig(),
                            windowSink: (@Sendable ([SinkWindow]) -> Void)? = nil,
                            onDiagnostic: (@Sendable (String) -> Void)? = nil) {
        self.init(config: config, makeAnalyzer: { try WindowAnalyzer(models: DiarizationModels.verified(), config: config) },
                  windowSink: windowSink, onDiagnostic: onDiagnostic)
    }

    public var currentStats: Stats { lock.withLock { stats } }

    /// Takes one chunk in the transcriber's format, starting at `startFrame` of the transcriber's frame counter.
    /// Holds a lock for a few instructions at most; safe from any thread.
    public func push(_ buffer: AVAudioPCMBuffer, startFrame: AVAudioFramePosition) {
        let schedule: Bool = lock.withLock {
            guard !closed, !stats.unavailable else { return false }
            if pending.count >= maxPending {
                stats.droppedChunks += 1
                return false
            }
            pending.append(Chunk(buffer: buffer, start: startFrame))
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        if schedule { queue.async { [self] in drain() } }
    }

    /// The provisional speaker of a finished segment from the windows analysed so far; nil while unknown. The
    /// ordinal is the live label plus one ("Speaker 1" is label 0). Never waits for the analysis.
    public func provisionalSpeaker(start: Double, end: Double) -> SpeakerTag? {
        guard let session = lock.withLock({ published }),
              let found = session.provisionalLabel(start: start, end: end) else { return nil }
        return SpeakerTag(ordinal: found.label + 1, confidence: found.confidence, overlap: found.overlap)
    }

    /// Stops accepting audio, analyses everything pending and the tail, and returns what the final clustering needs.
    /// nil when nothing was analysed (the models are unavailable, or no audio arrived). The diarizer is spent after.
    public func finish() async -> DiarizationRun? {
        lock.withLock { closed = true }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                drain()
                var run: DiarizationRun?
                if let session {
                    let first = session.records.count
                    if !failed {
                        do { run = try session.finish() } catch { analyzerFailed(error) }
                    }
                    if run == nil, !session.records.isEmpty {
                        run = DiarizationRun(records: session.records, totalSamples: session.totalSamples,
                                             skippedWindows: session.skippedWindows)
                    }
                    publish(from: first)
                    flushSink()
                    lock.withLock { stats.skippedWindows = session.skippedWindows }
                }
                release()
                continuation.resume(returning: run?.records.isEmpty == false ? run : nil)
            }
        }
    }

    /// Gives up without producing anything (the recording was abandoned).
    public func cancel() {
        lock.withLock {
            closed = true
            cancelled = true
            pending.removeAll()
        }
        queue.async { [self] in
            unsent.removeAll()
            release()
        }
    }

    private func release() {
        session = nil
        converter = nil
        lock.withLock { published = nil }
    }

    // MARK: On the queue

    /// Moves every pending chunk into the session and analyses the windows that are due, until nothing is pending.
    private func drain() {
        while true {
            let chunks: [Chunk] = lock.withLock {
                defer { pending.removeAll(keepingCapacity: true) }
                if pending.isEmpty { scheduled = false }
                return pending
            }
            if chunks.isEmpty { return }
            if failed || isCancelled { continue }
            ingest(chunks)
            analyzeDue()
        }
    }

    private func ingest(_ chunks: [Chunk]) {
        let session = self.session ?? makeSession()
        for chunk in chunks {
            if converter?.accepts(chunk.buffer.format) != true {
                converter = AudioChunkConverter(chunk.buffer.format)
                resampleNextInput = nil
            }
            guard let samples = converter?.samples(chunk.buffer) else { continue }
            let rate = chunk.buffer.format.sampleRate
            let target = Double(SegmentationGeometry.sampleRate)
            let start: Int
            if rate == target {
                start = Int(chunk.start)
            } else {
                // The converter keeps its filter state between chunks, so a chunk's output is a little shorter or
                // longer than frames x ratio. Consecutive chunks are therefore laid end to end on the converter's
                // own output count (no clicks, no zero gaps); the position is taken from the capture clock again
                // only when the input jumps (a dropped chunk).
                if resampleNextInput != chunk.start { resamplePosition = Int((Double(chunk.start) * target / rate).rounded()) }
                start = resamplePosition
                resamplePosition += samples.count
                resampleNextInput = chunk.start + AVAudioFramePosition(chunk.buffer.frameLength)
            }
            session.append(samples, at: start)
        }
    }

    private func makeSession() -> DiarizationSession {
        // The session exists from the first chunk (audio is kept meanwhile); the models load when the first window is due.
        let session = DiarizationSession(analyzer: LazyAnalyzer(make: makeAnalyzer), config: config, maxCatchUpWindows: maxCatchUp)
        self.session = session
        lock.withLock { published = session }
        return session
    }

    /// Analyses the oldest due window, then looks at the new chunks before the next one: a backlog is then cut by
    /// the session (it skips the oldest windows) instead of being worked through while audio piles up behind it.
    private func analyzeDue() {
        guard let session, !failed, !isCancelled else { return }
        let first = session.records.count
        do {
            while session.dueWindows > 0 {
                try session.processNext()
                if lock.withLock({ !pending.isEmpty || cancelled }) { break }
            }
        } catch {
            analyzerFailed(error)
        }
        publish(from: first)
        lock.withLock { stats.skippedWindows = session.skippedWindows }
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    private func publish(from index: Int) {
        guard let session, !isCancelled else { return }
        let records = session.records
        lock.withLock { stats.windows = records.count }
        guard windowSink != nil, index < records.count else { return }
        for i in index..<records.count { unsent.append(SinkWindow(seq: i, record: records[i])) }
        if unsent.count >= Self.sinkBatch { flushSink() }
    }

    private func flushSink() {
        guard !unsent.isEmpty, !isCancelled else { return }
        let batch = unsent
        unsent.removeAll(keepingCapacity: true)
        windowSink?(batch)
    }

    private func analyzerFailed(_ error: Error) {
        guard !failed else { return }
        failed = true
        lock.withLock {
            stats.unavailable = true
            pending.removeAll()
        }
        // Content-free: the error names a model or a Core ML failure, never audio or text.
        onDiagnostic?("speaker separation is off for this recording: \(error)")
    }
}

/// Builds the real analyzer when the first window is analysed, on the diarizer's queue.
private final class LazyAnalyzer: WindowAnalyzing, @unchecked Sendable {
    private let make: @Sendable () throws -> any WindowAnalyzing
    private var analyzer: (any WindowAnalyzing)?

    init(make: @escaping @Sendable () throws -> any WindowAnalyzing) { self.make = make }

    func analyze(window: [Float], startSample: Int) throws -> WindowRecord {
        if analyzer == nil { analyzer = try make() }
        return try analyzer!.analyze(window: window, startSample: startSample)
    }
}
