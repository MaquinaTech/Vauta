// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AVFoundation
import Foundation

/// Diarizes an audio or video file as fast as it can be read, with the same engine as a live meeting: for imported
/// recordings and for the `diarize` command. The file is only read; audio is decoded in small chunks, held in memory
/// for the current window, and never written anywhere.
public enum OfflineDiarization {
    /// - Parameters:
    ///   - analyzer: the window analyzer; the bundled hash-checked models when nil.
    ///   - progress: the fraction of the file read (0...1).
    /// - Throws: `RecordingImportError` when the file cannot be read, `DiarizationModels.Failure` when the models
    ///   cannot be used, `CancellationError` when the task is cancelled.
    public static func run(url: URL, config: DiarizationConfig = DiarizationConfig(), analyzer: (any WindowAnalyzing)? = nil,
                           progress: (@Sendable (Double) -> Void)? = nil) async throws -> DiarizationRun {
        let decoder = try await AudioFileDecoder(url: url, format: AudioChunkConverter.target)
        let analyzer = try analyzer ?? WindowAnalyzer(models: DiarizationModels.verified(), config: config)
        return try run(chunks: { try decoder.next().map { Array(UnsafeBufferPointer(start: $0.buffer.floatChannelData![0], count: Int($0.buffer.frameLength))) } },
                       analyzer: analyzer, config: config) {
            if decoder.duration > 0 { progress?(min(1, decoder.position / decoder.duration)) }
        }
    }

    /// The same over 16 kHz mono chunks pulled from `chunks` (nil = the end), in order and without gaps.
    public static func run(chunks: () throws -> [Float]?, analyzer: any WindowAnalyzing, config: DiarizationConfig = DiarizationConfig(),
                           afterChunk: () -> Void = {}) throws -> DiarizationRun {
        // Only the windows matter here: no live labels are needed (so no periodic re-clustering), and no window may be
        // skipped however much audio one chunk holds.
        var offline = config
        offline.liveReclusterSeconds = 1e9
        let session = DiarizationSession(analyzer: analyzer, config: offline, maxCatchUpWindows: .max)
        var position = 0
        while let samples = try chunks() {
            try Task.checkCancellation()
            session.append(samples, at: position)
            position += samples.count
            while try session.processNext() != nil {}
            afterChunk()
        }
        return try session.finish()
    }

    /// The analysed windows of a file, not clustered. Runs off the caller's executor like `diarize`.
    public static func analyze(url: URL, config: DiarizationConfig = DiarizationConfig(),
                               progress: (@Sendable (Double) -> Void)? = nil) async throws -> DiarizationRun {
        let work = Task.detached(priority: .utility) { try await run(url: url, config: config, progress: progress) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    /// The speakers of a file, clustered: for an imported recording. Runs off the caller's executor and stops when
    /// the caller's task is cancelled. The window embeddings never leave this function.
    public static func diarize(url: URL, config: DiarizationConfig = DiarizationConfig(),
                               progress: (@Sendable (Double) -> Void)? = nil) async throws -> Diarization {
        let work = Task.detached(priority: .utility) { () throws -> Diarization in
            let result = try await run(url: url, config: config, progress: progress)
            return Reconstruction.diarize(records: result.records, totalSamples: result.totalSamples, config: config)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}
