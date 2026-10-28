// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AVFoundation
import CoreMedia
import Speech

/// What happened to a chunk handed to an analyzer session.
enum AnalyzerYield: Sendable, Equatable {
    case enqueued(remaining: Int)
    /// The queue was full: the chunk was dropped.
    case dropped
    /// The session's input is closed (it failed or is finishing).
    case terminated
}

/// One recognition run of a channel: an analyzer, its module and its bounded input queue. `ChannelTranscriber`
/// replaces a session that fails mid-recording with a new one, so the protocol exists for that and for tests.
protocol AnalyzerSession: AnyObject, Sendable {
    /// Prepares and starts the analysis. `onFailure` is called at most once, if the analysis fails afterwards.
    func start(onSegment: @escaping @Sendable (Segment) -> Void, onFailure: @escaping @Sendable (Error) -> Void) async throws
    /// Queues a chunk that starts at frame `startFrame` of the channel's timeline.
    func yield(_ buffer: AVAudioPCMBuffer, startFrame: AVAudioFramePosition) -> AnalyzerYield
    /// Closes the input and waits for the last results; `cancel` (or a failed session) drops what is pending instead.
    func finish(cancel: Bool) async throws
}

/// A session on Apple's SpeechAnalyzer with an on-device transcriber.
///
/// Privacy: audio is not processed in this process but in system XPC services (localspeechrecognition), which don't
/// inherit Vauta's sandbox. That nothing leaves the Mac is guaranteed by Apple (these modules only run on device).
final class SpeechAnalyzerSession: AnalyzerSession, @unchecked Sendable {
    /// Finalizing the queued audio may take this long (up to two minutes of backlog) before it is cancelled.
    static let finalizeSeconds = 60.0
    /// After finalizing (or cancelling), the last results may take this long to arrive.
    static let resultsSeconds = 15.0

    private let channel: Channel
    private let module: any SpeechModule
    private let vocabulary: [String]
    private let format: AVAudioFormat
    private let collectsWords: Bool
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let inputStream: AsyncStream<AnalyzerInput>
    private let lock = NSLock()
    private var resultsTask: Task<Void, Error>?
    private var failed = false

    init(channel: Channel, module: any SpeechModule, vocabulary: [String], format: AVAudioFormat, collectsWords: Bool,
         capacity: Int) {
        self.channel = channel
        self.module = module
        self.vocabulary = vocabulary
        self.format = format
        self.collectsWords = collectsWords
        analyzer = SpeechAnalyzer(modules: [module])
        // Bounded queue: if the analyzer stalls or falls behind, audio doesn't
        // pile up in RAM. .bufferingOldest keeps the order of what is already
        // queued and drops the newest.
        (inputStream, input) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingOldest(capacity))
    }

    func start(onSegment: @escaping @Sendable (Segment) -> Void, onFailure: @escaping @Sendable (Error) -> Void) async throws {
        do {
            try await analyzer.prepareToAnalyze(in: format)
            if !vocabulary.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = vocabulary
                try await analyzer.setContext(context)
            }
        } catch {
            markFailed()
            throw error
        }
        let channel = channel
        let module = module
        let input = input
        let collectsWords = collectsWords
        @Sendable func emit(_ attributed: AttributedString, _ range: CMTimeRange, _ isFinal: Bool) {
            let text = String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let words = collectsWords && isFinal ? SpeechWordTimes.runs(in: attributed, trimmedTo: text) : []
            onSegment(Segment(channel: channel, start: range.start.seconds, end: range.end.seconds, text: text, isFinal: isFinal,
                              words: words))
        }
        let task = Task { [weak self] in
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
                self?.markFailed()
                onFailure(error)
                throw error
            }
        }
        lock.withLock { resultsTask = task }
        do {
            try await analyzer.start(inputSequence: inputStream)
        } catch {
            // Never started: finishing must cancel, not wait for the end of an input it never read.
            markFailed()
            task.cancel()
            throw error
        }
    }

    /// Each chunk carries its explicit start time, so a dropped chunk or a gap doesn't shift the following ones.
    func yield(_ buffer: AVAudioPCMBuffer, startFrame: AVAudioFramePosition) -> AnalyzerYield {
        let time = CMTime(value: startFrame, timescale: CMTimeScale(format.sampleRate))
        switch input.yield(AnalyzerInput(buffer: buffer, bufferStartTime: time)) {
        case .dropped: return .dropped
        case .enqueued(let remaining): return .enqueued(remaining: remaining)
        case .terminated: return .terminated
        @unknown default: return .terminated
        }
    }

    /// Always waits for the results task (with a deadline), even if finalizing fails. A finalization that takes longer
    /// than `finalizeSeconds` is cancelled: stopping never hangs on the speech service.
    func finish(cancel: Bool) async throws {
        input.finish()
        var firstError: Error?
        let analyzer = analyzer
        if cancel || lock.withLock({ failed }) {
            await Self.cancelNow(analyzer)
        } else {
            do {
                try await withDeadline(seconds: Self.finalizeSeconds) { try await analyzer.finalizeAndFinishThroughEndOfInput() }
            } catch {
                firstError = Self.captureError(error)
                await Self.cancelNow(analyzer)
            }
        }
        let task = lock.withLock {
            defer { resultsTask = nil }
            return resultsTask
        }
        if let task {
            do {
                try await withDeadline(seconds: Self.resultsSeconds) { try await task.value }
            } catch is CancellationError {
            } catch {
                task.cancel()
                firstError = firstError ?? Self.captureError(error)
            }
        }
        if let firstError { throw firstError }
    }

    private func markFailed() {
        input.finish()
        lock.withLock { failed = true }
    }

    private static func cancelNow(_ analyzer: SpeechAnalyzer) async {
        try? await withDeadline(seconds: resultsSeconds) { await analyzer.cancelAndFinishNow() }
    }

    /// A deadline that ran out reads as "transcription stopped", not as the document reader's timeout.
    private static func captureError(_ error: Error) -> Error {
        error is DocumentExtractionError ? CaptureError(.transcriptionStopped) : error
    }
}
