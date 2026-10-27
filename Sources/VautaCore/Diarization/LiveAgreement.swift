// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// How well the live speaker labels of a recording agree with the final ones: an evaluation tool (`Vauta diarize
/// --live-agreement`), never used while recording.
///
/// The stored windows are fed through a `SpeakerTracker` in order, exactly as `DiarizationSession` does, and each
/// window keeps the labels it had when it completed (a later re-clustering renames them, which is what the user
/// would have seen by then). Every speech frame is decided by one window only, as in `liveTurns`. The live labels
/// are then matched one-to-one with the final speakers (Hungarian, most shared frames wins) and the agreement is
/// the share of labelled speaker-frames that the matching gets right.
public enum LiveAgreement {
    public struct Result: Sendable, Equatable {
        /// Share (0...1) of labelled speaker-frames whose live label maps to their final speaker.
        public var agreement: Double
        /// Speaker-frames that had a live label and a final speaker.
        public var labelledFrames: Int
        /// Speaker-frames of speech in total (labelled or not).
        public var speechFrames: Int
        public var liveLabels: Int
        public var finalSpeakers: Int
    }

    public static func measure(records: [WindowRecord], totalSamples: Int? = nil, config: DiarizationConfig = DiarizationConfig()) -> Result {
        let tracker = SpeakerTracker(config: config)
        var atCompletion: [[Int]] = []
        for record in records {
            tracker.add(record)
            if tracker.isReclusterDue { tracker.recluster() }
            atCompletion.append(tracker.labels[tracker.labels.count - 1])
        }
        let final = FinalClusterer.cluster(records: records, config: config, totalSamples: totalSamples)
        let liveCount = (atCompletion.joined().max() ?? -1) + 1
        guard liveCount > 0, final.speakerCount > 0 else {
            return Result(agreement: 0, labelledFrames: 0, speechFrames: 0, liveLabels: liveCount, finalSpeakers: final.speakerCount)
        }
        var shared = [[Int]](repeating: [Int](repeating: 0, count: final.speakerCount), count: liveCount)
        var labelled = 0, speech = 0
        let W = SegmentationGeometry.windowSamples, step = config.stepSamples, frameStep = SegmentationGeometry.frameStepSamples
        for (w, record) in records.enumerated() {
            // the part of the timeline this window decides (the head for the first, the tail for the last)
            let lo = w == 0 ? 0 : max(0, (record.startSample + (W - step) / 2) / frameStep)
            let hi = w == records.count - 1 ? Int.max : (record.startSample + (W + step) / 2) / frameStep
            let origin = Int((Double(record.startSample) / Double(frameStep)).rounded())
            let from = max(lo, origin), to = min(hi, origin + SegmentationGeometry.frames)
            guard from < to else { continue }
            for g in from..<to {
                let mask = record.activity(frame: g - origin)
                for s in 0..<SegmentationGeometry.localSpeakers where mask & (1 << s) != 0 {
                    speech += 1
                    let live = atCompletion[w][s], fin = final.mapping[w][s]
                    if live >= 0 && fin >= 0 {
                        shared[live][fin] += 1
                        labelled += 1
                    }
                }
            }
        }
        let matched = Hungarian.maximize(shared).enumerated().reduce(0) { total, pair in
            total + (pair.element.map { shared[pair.offset][$0] } ?? 0)
        }
        return Result(agreement: labelled > 0 ? Double(matched) / Double(labelled) : 0, labelledFrames: labelled,
                      speechFrames: speech, liveLabels: liveCount, finalSpeakers: final.speakerCount)
    }
}
