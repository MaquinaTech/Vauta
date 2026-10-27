// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AVFoundation
import CoreMedia
import Speech

/// Transcribes a recording the user chose (audio or video file) on device,
/// with progress and cancellation. Nothing is copied: the file is read in
/// place and its audio only goes to the system speech service.
public enum RecordingTranscriber {
    public struct FileInfo: Sendable, Equatable {
        public let fileName: String
        /// Seconds (0 if unknown).
        public let duration: Double
        /// When the recording started: the file's creation-date metadata, else
        /// the file system's creation date.
        public let recordedAt: Date?

        public init(fileName: String, duration: Double, recordedAt: Date?) {
            self.fileName = fileName
            self.duration = duration
            self.recordedAt = recordedAt
        }
    }

    /// Reads the file's length and date. Throws if it has no readable audio.
    public static func inspect(_ url: URL) async throws -> FileInfo {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        let time: CMTime
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
            time = try await asset.load(.duration)
        } catch {
            throw RecordingImportError(.unreadable, detail: error.localizedDescription)
        }
        guard !tracks.isEmpty else { throw RecordingImportError(.noAudio) }
        var recordedAt: Date?
        if let item = try? await asset.load(.creationDate) {
            recordedAt = try? await item.load(.dateValue)
        }
        if recordedAt == nil {
            recordedAt = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
        }
        return FileInfo(fileName: url.lastPathComponent, duration: time.seconds.isFinite ? max(0, time.seconds) : 0,
                        recordedAt: recordedAt)
    }

    /// Transcribes the file. `progress` gets the fraction of the audio read
    /// (0…1). Cancelling the task stops it and throws `CancellationError`.
    /// `collectWords` keeps each segment's word times, for splitting it where the speaker changes.
    ///
    /// - Throws: `CaptureError` when the language's model isn't installed,
    ///   `RecordingImportError` when the file can't be read.
    public static func transcribe(_ url: URL, locale: Locale, engine: SpeechEngineKind, collectWords: Bool = false,
                                  progress: @escaping @Sendable (Double) -> Void) async throws -> [Segment] {
        try await SpeechAssets.requireInstalled(locale, engine: engine)
        let module = SpeechAssets.module(locale, engine)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw CaptureError(.analyzerFormatUnavailable, locale: locale)
        }
        let decoder = try await AudioFileDecoder(url: url, format: format)
        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.prepareToAnalyze(in: format)
        let collector = Task {
            var out: [Segment] = []
            func add(_ text: AttributedString, _ range: CMTimeRange, _ isFinal: Bool) {
                guard isFinal else { return }
                let plain = String(text.characters)
                let words = collectWords ? SpeechWordTimes.runs(in: text, trimmedTo: plain.trimmingCharacters(in: .whitespacesAndNewlines)) : []
                out.append(Segment(channel: .others, start: range.start.seconds, end: range.end.seconds, text: plain, isFinal: true,
                                   words: words))
            }
            if let speech = module as? SpeechTranscriber {
                for try await r in speech.results { add(r.text, r.range, r.isFinal) }
            } else if let dictation = module as? DictationTranscriber {
                for try await r in dictation.results { add(r.text, r.range, r.isFinal) }
            }
            return out
        }
        do {
            try await withTaskCancellationHandler {
                if let end = try await analyzer.analyzeSequence(DecodedAudio(decoder: decoder, progress: progress)) {
                    try Task.checkCancellation()
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                decoder.cancel()
            }
            try Task.checkCancellation()
        } catch {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }
        progress(1)
        return RecordingImportPlan.transcript(from: try await collector.value, duration: decoder.duration)
    }
}

/// The decoder's chunks as analyzer input, read only when the analyzer asks.
struct DecodedAudio: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput
    let decoder: AudioFileDecoder
    let progress: @Sendable (Double) -> Void

    struct AsyncIterator: AsyncIteratorProtocol {
        let decoder: AudioFileDecoder
        let progress: @Sendable (Double) -> Void

        mutating func next() async throws -> AnalyzerInput? {
            try Task.checkCancellation()
            guard let (buffer, start) = try decoder.next() else { return nil }
            if decoder.duration > 0 { progress(Swift.min(1, decoder.position / decoder.duration)) }
            return AnalyzerInput(buffer: buffer, bufferStartTime: CMTime(value: start, timescale: CMTimeScale(decoder.format.sampleRate)))
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(decoder: decoder, progress: progress) }
}
