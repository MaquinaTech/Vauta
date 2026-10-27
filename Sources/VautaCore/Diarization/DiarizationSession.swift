// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What a diarization run leaves for the final clustering: every window analysed and the length of the audio.
/// The records are voice data (see `WindowRecord`).
public struct DiarizationRun: Sendable {
    public var records: [WindowRecord]
    /// Samples of 16 kHz audio the run received, gaps included.
    public var totalSamples: Int
    public var skippedWindows: Int

    public init(records: [WindowRecord], totalSamples: Int, skippedWindows: Int = 0) {
        self.records = records
        self.totalSamples = totalSamples
        self.skippedWindows = skippedWindows
    }
}

/// The window schedule of one diarization: keeps the last seconds of 16 kHz mono audio, analyses a 10 s window
/// every `stepSeconds`, and gives each analysed window its provisional labels (`SpeakerTracker`).
///
/// Samples are placed by their ABSOLUTE index, so audio the caller never delivered (a dropped chunk) is a gap of
/// silence and never shifts what follows: the clock is the capture's own sample counter.
///
/// If the owner cannot keep up, the oldest windows are skipped, never the newest: at most `maxCatchUpWindows`
/// windows wait, and `skippedWindows` counts the rest. Labels degrade, the transcript does not. Audio is held for
/// at most the window plus that backlog and is never written anywhere.
///
/// Not thread-safe: the owner serialises calls (the diarizer's queue, or one offline loop). The one exception is
/// `provisionalLabel`, which any thread may call while the owner works: it reads a snapshot of the records and labels
/// that the owner replaces after every update, under a lock held only for the swap of two array references. The
/// clustering itself runs outside that lock, so a reader never waits for it and always gets an answer.
public final class DiarizationSession {
    public let config: DiarizationConfig
    public let tracker: SpeakerTracker
    public private(set) var skippedWindows = 0
    /// Samples received so far, gaps included.
    public private(set) var totalSamples = 0
    private let analyzer: any WindowAnalyzing
    private let maxCatchUp: Int
    private var buffer: [Float] = []
    private var bufferStart = 0
    private var nextWindowStart = 0
    /// The records and labels as of the last update, for `provisionalLabel`. Held only to swap or copy the references.
    private let snapshotLock = NSLock()
    private var snapshot: (records: [WindowRecord], labels: [[Int]]) = ([], [])

    /// A gap longer than this is not filled with silence: the buffer restarts after it.
    private static let maxFilledGap = SegmentationGeometry.windowSamples

    public init(analyzer: any WindowAnalyzing, config: DiarizationConfig = DiarizationConfig(), maxCatchUpWindows: Int = 15) {
        self.analyzer = analyzer
        self.config = config
        self.maxCatchUp = max(1, maxCatchUpWindows)
        self.tracker = SpeakerTracker(config: config)
    }

    public var records: [WindowRecord] { tracker.records }

    /// Windows that are complete and not analysed yet.
    public var dueWindows: Int {
        let ready = totalSamples - SegmentationGeometry.windowSamples - nextWindowStart
        return ready < 0 ? 0 : ready / config.stepSamples + 1
    }

    /// Adds audio that starts at absolute sample `start`. Never analyses anything.
    public func append(_ samples: [Float], at start: Int) {
        var samples = samples[...]
        var start = start
        let end = bufferStart + buffer.count
        if start < end {
            // a repeated or overlapping chunk: keep only what is new
            samples = samples.dropFirst(end - start)
            start = end
        }
        guard !samples.isEmpty else { return }
        if start > end {
            if start - end <= Self.maxFilledGap {
                buffer.append(contentsOf: repeatElement(0, count: start - end))
            } else {
                buffer.removeAll(keepingCapacity: true)
                bufferStart = start
                nextWindowStart = max(nextWindowStart, start)
            }
        }
        buffer.append(contentsOf: samples)
        totalSamples = bufferStart + buffer.count
        skipBacklog()
    }

    /// Analyses the oldest due window. Returns its index, or nil when none is due.
    @discardableResult
    public func processNext() throws -> Int? {
        guard dueWindows > 0 else { return nil }
        return try process(start: nextWindowStart)
    }

    /// Analyses what is left at the end of the audio (windows padded with silence) so every part of it is covered.
    public func finish() throws -> DiarizationRun {
        while dueWindows > 0 { try process(start: nextWindowStart) }
        let W = SegmentationGeometry.windowSamples, step = config.stepSamples
        if totalSamples > 0 {
            while tracker.records.isEmpty || tracker.records.last!.startSample + (W + step) / 2 < totalSamples {
                try process(start: nextWindowStart)
            }
        }
        return DiarizationRun(records: tracker.records, totalSamples: totalSamples, skippedWindows: skippedWindows)
    }

    @discardableResult
    private func process(start: Int) throws -> Int {
        let W = SegmentationGeometry.windowSamples
        var window = [Float](repeating: 0, count: W)
        let offset = start - bufferStart
        let available = max(0, min(W, buffer.count - offset))
        if available > 0, offset >= 0 {
            window.replaceSubrange(0..<available, with: buffer[offset..<(offset + available)])
        }
        // Core ML and MLMultiArray temporaries are autoreleased; a long loop on one thread (an import, a backlog)
        // never returns to a run loop that would drain them, so each window gets its own pool.
        let record = try autoreleasepool { try analyzer.analyze(window: window, startSample: start) }
        tracker.add(record)
        if tracker.isReclusterDue { tracker.recluster() }
        let published = (tracker.records, tracker.labels)
        snapshotLock.withLock { snapshot = published }
        nextWindowStart += config.stepSamples
        trim()
        return tracker.records.count - 1
    }

    /// Drops the oldest due windows beyond the allowed backlog.
    private func skipBacklog() {
        let due = dueWindows
        if due > maxCatchUp {
            skippedWindows += due - maxCatchUp
            nextWindowStart += (due - maxCatchUp) * config.stepSamples
        }
        trim()
    }

    private func trim() {
        let drop = min(buffer.count, max(0, nextWindowStart - bufferStart))
        if drop > 0 {
            buffer.removeFirst(drop)
            bufferStart += drop
        }
    }

    // MARK: Provisional labels

    /// Who spoke between `start` and `end` seconds, as far as the windows analysed so far tell: the live label
    /// that is active for most of the speech there. nil when no analysed window covers that time (it is not
    /// analysed yet, or it was skipped). Each frame is decided by one window only, like the live turns.
    public func provisionalLabel(start: Double, end: Double) -> (label: Int, confidence: Double, overlap: Bool)? {
        let frameStep = SegmentationGeometry.frameStepSamples
        let first = SegmentationGeometry.frameIndex(atSeconds: start), last = max(first, SegmentationGeometry.frameIndex(atSeconds: end))
        let W = SegmentationGeometry.windowSamples, step = config.stepSamples
        let (records, labels) = snapshotLock.withLock { snapshot }
        var counts: [Int: Int] = [:]
        var speech = 0, crosstalk = 0
        var index = records.count - 1
        while index >= 0 {
            let record = records[index]
            // the part of the timeline this window decides: its centre (the head for the first, the tail for the last)
            let lo = index == 0 ? 0 : (record.startSample + (W - step) / 2) / frameStep
            let hi = index == records.count - 1 ? Int.max : (record.startSample + (W + step) / 2) / frameStep
            if hi < first { break }
            let origin = Int((Double(record.startSample) / Double(frameStep)).rounded())
            let from = max(lo, first, origin), to = min(hi, last + 1, origin + SegmentationGeometry.frames)
            if from < to {
                for g in from..<to {
                    let mask = record.activity(frame: g - origin)
                    var present: [Int] = []
                    for s in 0..<SegmentationGeometry.localSpeakers where mask & (1 << s) != 0 {
                        let label = labels[index][s]
                        if label >= 0, !present.contains(label) { present.append(label) }
                    }
                    guard !present.isEmpty else { continue }
                    speech += 1
                    if present.count > 1 { crosstalk += 1 }
                    for label in present { counts[label, default: 0] += 1 }
                }
            }
            index -= 1
        }
        guard speech > 0, let best = counts.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) }) else { return nil }
        return (best.key, Double(best.value) / Double(speech), Double(crosstalk) / Double(speech) >= 0.5)
    }
}
