// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AVFoundation
import CoreMedia
import Speech

/// A piece of one channel's transcript. `isFinal == false` is a provisional
/// (volatile) result that the final one for the same range will replace.
public struct Segment: Sendable {
    public let channel: Channel
    public let start: Double
    public let end: Double
    public let text: String
    public let isFinal: Bool
    /// Who said it, when speaker separation has labelled the segment (a provisional label
    /// while recording). nil = no speaker data.
    public let speaker: SpeakerTag?
    /// When each word or phrase was spoken, in text order (offsets in Characters of `text`), when speaker
    /// separation asked for it: the aligner then splits a segment between words at the time the speaker changed.
    /// Empty otherwise. Kept in memory until the speakers are finalized; never stored.
    public let words: [AlignableSegment.Run]

    public init(channel: Channel, start: Double, end: Double, text: String, isFinal: Bool, speaker: SpeakerTag? = nil,
                words: [AlignableSegment.Run] = []) {
        self.channel = channel
        self.start = start
        self.end = end
        self.text = text
        self.isFinal = isFinal
        self.speaker = speaker
        self.words = words
    }

    /// The same segment with a (provisional) speaker.
    public func with(speaker: SpeakerTag?) -> Segment {
        Segment(channel: channel, start: start, end: end, text: text, isFinal: isFinal, speaker: speaker, words: words)
    }
}

/// Recognition engine of a channel (all on-device).
public enum TranscriptionEngine: Sendable, Equatable {
    /// SpeechTranscriber: the best general quality. Ignores the vocabulary.
    case speech
    /// DictationTranscriber with custom vocabulary (at most 100 short phrases:
    /// attendees, series entities, pinned glossary). It is also the engine for
    /// languages SpeechTranscriber doesn't support (with an empty vocabulary).
    case dictation(vocabulary: [String])

    public static let maxVocabulary = 100

    public var kind: SpeechEngineKind {
        switch self {
        case .speech: .speech
        case .dictation: .dictation
        }
    }
}

/// The transcription of one audio channel: places each chunk on the channel's timeline (`ChannelTimeline`) and hands
/// it to an analyzer session (SpeechAnalyzer with an on-device transcriber, see `SpeechAnalyzerSession`).
///
/// If the analyzer fails mid-recording, the session is rebuilt and the channel goes on at the same place of the
/// timeline (what arrives meanwhile is lost, shown as lagging). Only when `AnalyzerRetryPolicy` gives up is the channel
/// reported as failed.
final class ChannelTranscriber: @unchecked Sendable {
    /// Maximum pending audio if the analyzer falls behind (chunks are ~100 ms).
    static let maxPendingSeconds = 120.0
    static var capacity: Int { Int(maxPendingSeconds * 10) }
    /// How long stopping waits for a rebuild in progress.
    static let recoveryWaitSeconds = 15.0

    let channel: Channel
    let analyzerFormat: AVAudioFormat
    private let makeSession: @Sendable (_ collectsWords: Bool) -> any AnalyzerSession

    private let lock = NSLock()
    private var session: (any AnalyzerSession)?
    private var sessionStarted: TimeInterval = 0
    private var onSegment: (@Sendable (Segment) -> Void)?
    private var recovery: Task<Void, Never>?
    private var retry: AnalyzerRetryPolicy
    private var timeline: ChannelTimeline
    private var dropped = 0
    /// No session transcribes any more (it never started, or the retries ran out).
    private var failed = false
    private var stopping = false
    private var collectsWords = false
    private var lag = LagMonitor(capacity: ChannelTranscriber.capacity)

    /// Content-free notices (audio dropped because of lag, analyzer restarts).
    var onDiagnostic: (@Sendable (String) -> Void)?
    /// `.lagging` when audio starts being dropped (or the analyzer is being restarted), `.ok` once it caught up.
    var onHealth: (@Sendable (ChannelHealth) -> Void)?
    /// The analyzer failed mid-recording and could not be restarted: the channel stops transcribing.
    var onFailure: (@Sendable (Channel, Error) -> Void)?

    init(channel: Channel, format: AVAudioFormat, retry: AnalyzerRetryPolicy = AnalyzerRetryPolicy(),
         makeSession: @escaping @Sendable (_ collectsWords: Bool) -> any AnalyzerSession) {
        self.channel = channel
        analyzerFormat = format
        self.retry = retry
        self.makeSession = makeSession
        timeline = ChannelTimeline(sampleRate: format.sampleRate)
    }

    convenience init(channel: Channel, locale: Locale, engine: TranscriptionEngine = .speech) async throws {
        let vocabulary: [String]
        let makeModule: @Sendable () -> any SpeechModule
        switch engine {
        case .speech:
            makeModule = { SpeechAssets.speechModule(locale) }
            vocabulary = []
        case .dictation(let words):
            makeModule = { SpeechAssets.dictationModule(locale) }
            vocabulary = Array(words.prefix(TranscriptionEngine.maxVocabulary))
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [makeModule()]) else {
            throw CaptureError(.analyzerFormatUnavailable, locale: locale)
        }
        self.init(channel: channel, format: format) { collectsWords in
            SpeechAnalyzerSession(channel: channel, module: makeModule(), vocabulary: vocabulary, format: format,
                                  collectsWords: collectsWords, capacity: ChannelTranscriber.capacity)
        }
    }

    /// Keep the word times of final results (for splitting segments at speaker changes). Set before `open`.
    func collectWordTimes(_ collect: Bool) { lock.withLock { collectsWords = collect } }

    /// Makes the first session current, with its queue, before it starts: the devices can start at once, and what they capture
    /// waits in the queue (up to `maxPendingSeconds`) while the analyzer prepares instead of being lost. `start()` starts it.
    func open(onSegment: @escaping @Sendable (Segment) -> Void) {
        lock.withLock {
            self.onSegment = onSegment
            if session == nil { _ = installSession() }
        }
    }

    func start(onSegment: @escaping @Sendable (Segment) -> Void) async throws {
        open(onSegment: onSegment)
        try await start()
    }

    /// Starts the session `open` made current.
    func start() async throws {
        let (session, onSegment) = lock.withLock { (self.session ?? installSession(), self.onSegment) }
        do {
            try await run(session, onSegment: onSegment)
        } catch {
            // A session that never started is cancelled when finishing, never finalized.
            lock.withLock { failed = true }
            throw error
        }
    }

    /// Takes audio already converted to `analyzerFormat`, captured `offset` seconds after the session origin (nil:
    /// right after the previous chunk). Returns the chunk's first frame, the counter the speaker diarizer shares.
    @discardableResult
    func feed(_ buffer: AVAudioPCMBuffer, capturedAt offset: Double? = nil) -> AVAudioFramePosition {
        let (start, session) = lock.withLock {
            (timeline.place(frames: Int64(buffer.frameLength), capturedAt: offset), failed ? nil : self.session)
        }
        let now = ProcessInfo.processInfo.systemUptime
        switch session?.yield(buffer, startFrame: start) ?? .terminated {
        case .dropped:
            let (n, change) = lock.withLock {
                dropped += 1
                return (dropped, lag.dropped(at: now))
            }
            if n == 1 || n % 100 == 0 {
                onDiagnostic?("\(channel.rawValue): transcription is lagging, \(n) audio chunk(s) dropped")
            }
            if let change { onHealth?(change) }
        case .enqueued(let remaining):
            if let change = lock.withLock({ lag.enqueued(remaining: remaining, at: now) }) { onHealth?(change) }
        case .terminated:
            break
        }
        return start
    }

    /// Closes the input and waits for the last final results. Every step has a deadline: stopping never hangs.
    func finish() async throws {
        let recovery = lock.withLock {
            stopping = true
            return self.recovery
        }
        recovery?.cancel()
        _ = await waitForTask(recovery, seconds: Self.recoveryWaitSeconds)
        let (session, failed) = lock.withLock { (self.session, self.failed) }
        try await session?.finish(cancel: failed)
    }

    // MARK: Sessions

    /// A new session, made current. Call it under the lock.
    private func installSession() -> any AnalyzerSession {
        let session = makeSession(collectsWords)
        self.session = session
        sessionStarted = ProcessInfo.processInfo.systemUptime
        return session
    }

    private func run(_ session: any AnalyzerSession, onSegment: (@Sendable (Segment) -> Void)?) async throws {
        try await session.start(onSegment: onSegment ?? { _ in }) { [weak self, weak session] error in
            guard let self, let session else { return }
            self.sessionFailed(session, error)
        }
    }

    /// Makes a new session current and starts it. It is current before it starts, so audio queues meanwhile and a
    /// failure right after the start is not missed.
    private func startSession() async throws {
        let (session, onSegment) = lock.withLock { (installSession(), self.onSegment) }
        try await run(session, onSegment: onSegment)
    }

    private enum Decision { case ignore, retry(after: Double, attempt: Int), giveUp }

    private func sessionFailed(_ failedSession: any AnalyzerSession, _ error: Error) {
        let now = ProcessInfo.processInfo.systemUptime
        let decision: Decision = lock.withLock {
            guard !stopping, !failed, recovery == nil, session === failedSession else { return .ignore }
            guard let delay = retry.failed(at: now, runningSince: sessionStarted) else {
                failed = true
                return .giveUp
            }
            recovery = Task { [weak self] in await self?.recover(after: delay) }
            return .retry(after: delay, attempt: retry.attempts)
        }
        switch decision {
        case .ignore:
            break
        case .giveUp:
            onFailure?(channel, error)
        case .retry(let delay, let attempt):
            onDiagnostic?("\(channel.rawValue): analyzer failed: \(error); restarting in \(delay) s (attempt \(attempt))")
            onHealth?(.lagging)
        }
    }

    /// Replaces the failed session after `delay`, again while the policy allows. Stopping cancels it.
    private func recover(after delay: Double) async {
        var delay = delay
        while true {
            if let old = lock.withLock({ session }) { try? await old.finish(cancel: true) }
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, !lock.withLock({ stopping }) else { break }
            do {
                try await startSession()
                lock.withLock { recovery = nil }
                onDiagnostic?("\(channel.rawValue): analyzer restarted")
                onHealth?(.ok)
                return
            } catch {
                let now = ProcessInfo.processInfo.systemUptime
                let next: Double? = lock.withLock { retry.failed(at: now, runningSince: now) }
                guard let next else {
                    let report = lock.withLock {
                        failed = true
                        recovery = nil
                        return !stopping
                    }
                    if report { onFailure?(channel, error) }
                    return
                }
                delay = next
            }
        }
        lock.withLock { recovery = nil }
    }
}

/// How often a channel's analyzer is rebuilt after it fails: up to `maxAttempts` times in a row, waiting longer each
/// time. A session that ran for `stableSeconds` before it failed starts the count over.
struct AnalyzerRetryPolicy: Sendable {
    var maxAttempts: Int
    var delays: [Double]
    var stableSeconds: TimeInterval
    private(set) var attempts = 0

    init(maxAttempts: Int = 3, delays: [Double] = [1, 3, 10], stableSeconds: TimeInterval = 300) {
        self.maxAttempts = maxAttempts
        self.delays = delays
        self.stableSeconds = stableSeconds
    }

    /// A session that started at `start` failed at `now`: the delay before the next one, or nil to give up.
    mutating func failed(at now: TimeInterval, runningSince start: TimeInterval) -> Double? {
        if now - start >= stableSeconds { attempts = 0 }
        attempts += 1
        guard attempts <= maxAttempts, !delays.isEmpty else { return nil }
        return delays[min(attempts - 1, delays.count - 1)]
    }
}

/// Decides when a channel is lagging (the analyzer queue dropped audio) and
/// when it has recovered: no drops for `quietPeriod` seconds and a backlog of
/// at most `drainedPending` chunks.
struct LagMonitor {
    let capacity: Int
    var quietPeriod: TimeInterval = 5
    var drainedPending = 20
    private(set) var isLagging = false
    private var lastDrop: TimeInterval = 0

    init(capacity: Int) { self.capacity = capacity }

    /// A chunk was dropped at `now`. Returns `.lagging` on the transition.
    mutating func dropped(at now: TimeInterval) -> ChannelHealth? {
        lastDrop = now
        guard !isLagging else { return nil }
        isLagging = true
        return .lagging
    }

    /// A chunk was queued with `remaining` free slots. Returns `.ok` on recovery.
    mutating func enqueued(remaining: Int, at now: TimeInterval) -> ChannelHealth? {
        guard isLagging, now - lastDrop >= quietPeriod, capacity - remaining <= drainedPending else { return nil }
        isLagging = false
        return .ok
    }
}
