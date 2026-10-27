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

/// One SpeechAnalyzer plus on-device transcriber per audio channel.
///
/// Privacy: audio is not processed in this process but in system XPC services
/// (localspeechrecognition), which don't inherit Vauta's sandbox. That nothing
/// leaves the Mac is guaranteed by Apple (these modules only run on device).
final class ChannelTranscriber: @unchecked Sendable {
    /// Maximum pending audio if the analyzer falls behind (chunks are ~100 ms).
    static let maxPendingSeconds = 120.0
    static var capacity: Int { Int(maxPendingSeconds * 10) }

    let channel: Channel
    let analyzerFormat: AVAudioFormat
    private let module: any SpeechModule
    private let vocabulary: [String]
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let inputStream: AsyncStream<AnalyzerInput>
    private var resultsTask: Task<Void, Error>?

    private let lock = NSLock()
    private var framePosition: AVAudioFramePosition = 0
    private var dropped = 0
    private var failed = false
    private var collectsWords = false
    private var lag = LagMonitor(capacity: ChannelTranscriber.capacity)

    /// Content-free notices (audio dropped because of lag).
    var onDiagnostic: (@Sendable (String) -> Void)?
    /// `.lagging` when audio starts being dropped, `.ok` once it caught up.
    var onHealth: (@Sendable (ChannelHealth) -> Void)?
    /// The analyzer failed mid-recording: the channel stops transcribing.
    var onFailure: (@Sendable (Channel, Error) -> Void)?

    init(channel: Channel, locale: Locale, engine: TranscriptionEngine = .speech) async throws {
        self.channel = channel
        switch engine {
        case .speech:
            module = SpeechAssets.speechModule(locale)
            vocabulary = []
        case .dictation(let words):
            module = SpeechAssets.dictationModule(locale)
            vocabulary = Array(words.prefix(TranscriptionEngine.maxVocabulary))
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw CaptureError(.analyzerFormatUnavailable, locale: locale)
        }
        analyzerFormat = format
        analyzer = SpeechAnalyzer(modules: [module])
        // Bounded queue: if the analyzer stalls or falls behind, audio doesn't
        // pile up in RAM. .bufferingOldest keeps the order of what is already
        // queued and drops the newest.
        (inputStream, input) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingOldest(Self.capacity))
    }

    /// Keep the word times of final results (for splitting segments at speaker changes). Set before `start`.
    func collectWordTimes(_ collect: Bool) { lock.withLock { collectsWords = collect } }

    func start(onSegment: @escaping @Sendable (Segment) -> Void) async throws {
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try await analyzer.setContext(context)
        }
        let channel = channel
        let module = module
        let input = input
        let collectsWords = lock.withLock { self.collectsWords }
        @Sendable func emit(_ attributed: AttributedString, _ range: CMTimeRange, _ isFinal: Bool) {
            let text = String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let words = collectsWords && isFinal ? SpeechWordTimes.runs(in: attributed, trimmedTo: text) : []
            onSegment(Segment(channel: channel, start: range.start.seconds, end: range.end.seconds, text: text, isFinal: isFinal,
                              words: words))
        }
        resultsTask = Task { [weak self] in
            do {
                if let speech = module as? SpeechTranscriber {
                    for try await r in speech.results { emit(r.text, r.range, r.isFinal) }
                } else if let dictation = module as? DictationTranscriber {
                    for try await r in dictation.results { emit(r.text, r.range, r.isFinal) }
                }
            } catch is CancellationError {
            } catch {
                // Without an analyzer, later yields are discarded: no audio piles up.
                input.finish()
                self?.lock.withLock { self?.failed = true }
                self?.onFailure?(channel, error)
                throw error
            }
        }
        do {
            try await analyzer.start(inputSequence: inputStream)
        } catch {
            input.finish()
            resultsTask?.cancel()
            throw error
        }
    }

    /// Takes audio already converted to `analyzerFormat`. Each chunk carries its
    /// explicit start time, so a dropped chunk doesn't shift the following ones.
    /// Returns the chunk's first frame, the counter the speaker diarizer shares.
    @discardableResult
    func feed(_ buffer: AVAudioPCMBuffer) -> AVAudioFramePosition {
        let start = lock.withLock {
            defer { framePosition += AVAudioFramePosition(buffer.frameLength) }
            return framePosition
        }
        let time = CMTime(value: start, timescale: CMTimeScale(analyzerFormat.sampleRate))
        let now = ProcessInfo.processInfo.systemUptime
        switch input.yield(AnalyzerInput(buffer: buffer, bufferStartTime: time)) {
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
        @unknown default:
            break
        }
        return start
    }

    /// Closes the input and waits for the last final results. It always waits
    /// for `resultsTask`, even if finalizing fails.
    func finish() async throws {
        input.finish()
        var firstError: Error?
        if lock.withLock({ failed }) {
            await analyzer.cancelAndFinishNow()
        } else {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                firstError = error
                await analyzer.cancelAndFinishNow()
            }
        }
        do { try await resultsTask?.value } catch is CancellationError {} catch { firstError = firstError ?? error }
        resultsTask = nil
        if let firstError { throw firstError }
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
