// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Fixed geometry of the segmentation network (pyannote community-1 family) and of the embedding front end.
public enum SegmentationGeometry {
    public static let sampleRate = 16_000
    public static let windowSamples = 160_000          // 10 s
    public static let frames = 589                     // output frames per window
    public static let frameStepSamples = 270           // 16.875 ms between frame starts
    public static let frameReceptiveSamples = 991      // receptive field of one frame (as pyannote); centre = start + 495
    public static let localSpeakers = 3
    public static let frameStepSeconds = Double(frameStepSamples) / Double(sampleRate)
    /// Where frame `g` begins on the timeline: `g * frameStepSeconds + frameOffsetSeconds`. A frame is placed at the
    /// centre of its receptive field, measured from the middle of the previous step.
    public static let frameOffsetSeconds = Double(frameReceptiveSamples / 2) / Double(sampleRate) - frameStepSeconds / 2
    /// The frame that holds `seconds` on the timeline (never negative): the inverse of `frameOffsetSeconds`.
    public static func frameIndex(atSeconds seconds: Double) -> Int {
        max(0, Int(((seconds - frameOffsetSeconds) / frameStepSeconds).rounded(.down)))
    }
    public static let embeddingDimension = 256
    public static let fbankFrames = 998                // Kaldi frames of a 10 s window (snip edges)
}

/// Every tunable of the diarization pipeline in one place. The defaults are the operating point validated on the
/// the first evaluation sets (10 s windows every 2 s, centroid AHC at 0.70): change them only with a new evaluation.
public struct DiarizationConfig: Sendable, Equatable {
    /// Distance between window starts, in seconds (the window itself is 10 s, fixed by the model).
    public var stepSeconds: Double = 2.0
    /// A (window, local speaker) pair is embedded only with at least this many seconds of usable speech.
    public var minEmbeddingSeconds: Double = 1.0
    /// Embed only the frames where the speaker is alone (falls back to all their active frames when too short).
    public var excludeOverlap = true

    /// Live clustering: the largest Euclidean distance (between L2-normalised vectors) to join a live speaker.
    public var onlineAssignDistance: Float = 1.1
    /// Live clustering: seconds of usable speech needed to open a NEW live speaker.
    public var onlineNewClusterSeconds: Double = 4.0
    /// Live labels are re-clustered globally this often (seconds of audio) and mapped back onto the old labels.
    public var liveReclusterSeconds: Double = 45

    /// Final clustering: cut height of the centroid-linkage dendrogram (Euclidean, L2-normalised embeddings).
    /// 0.75 is a cliff on some recordings (speakers merge), so the default sits one notch below it.
    public var finalThreshold: Float = 0.70
    /// Final clustering: clusters with less speech than this are folded into the nearest large cluster. 20 s is
    /// 10 embeddings at the 2 s step; it scales with `stepSeconds`.
    public var minClusterSeconds: Double = 20
    /// Final clustering: the fold above scales with the length of the recording: a cluster must hold at least this
    /// share of the recording (clamped to `foldFloorSeconds`...`foldCeilingSeconds`) of speech, measured in window
    /// starts. 0 disables the scaling (`minClusterSeconds` then applies). Measured (docs/BENCHMARKS.md): 18 tuning files,
    /// count within 1 of the truth 18/18 (was 17/18); 12 synthetic Spanish files exact 10/12 (was 9/12). The 30 s ceiling
    /// applies above 33 minutes; it was evaluated on recordings of up to 49.5 minutes and on two joined recordings of 72 and
    /// 117 minutes, an ad-hoc check outside the harness (docs/BENCHMARKS.md#long-recordings).
    public var foldDurationShare: Double = 0.015
    public var foldFloorSeconds: Double = 12
    public var foldCeilingSeconds: Double = 30
    /// Final clustering: re-assign every embedding to its nearest centroid after the cut, one-to-one per window.
    public var reassignToCentroids = true
    /// Live re-clustering: the same fold, but a speaker who joined recently needs only this much speech to keep a
    /// label of their own (6 embeddings at the 2 s step; measured on the 18 eval files: 12 s gives 92.3% live agreement, 20 s 91.9%, 8 s 88.4%), so labels do not churn while a newcomer is still under
    /// `minClusterSeconds`.
    public var liveMinClusterSeconds: Double = 12
    /// Final clustering: above this many embeddings (1 to 3 hours at the 2 s step, depending on how many local
    /// speakers each window embeds: 1.5 to 3 of them at 1800 windows an hour) the dendrogram is built in
    /// two stages so the O(n^2) distance matrix stays small (6000 embeddings = 72 MB).
    public var maxDirectEmbeddings = 6_000
    /// Two-stage clustering: embeddings per first-stage chunk (at most; chunks are equal and consecutive in time).
    public var stageChunkSize = 3_000
    /// Over-merge guard 1: two clusters that each hold at least this many seconds of window starts (30 embeddings at
    /// the 2 s step) merge only up to `finalThreshold - establishedMargin`. At 0.75 two long-speaking people of one
    /// recording (210 and 216 embeddings, merge height 0.725) become one speaker; at 0.70 they stay two.
    public var establishedSeconds: Double = 60
    public var establishedMargin: Float = 0.05
    /// Over-merge guard 2: a final cluster in which two different local speakers of the same window land in more
    /// than this fraction of its windows is split again with a lower cut. 1 disables the guard.
    public var maxSameWindowConflict: Double = 0.25

    /// Output: speech of one speaker separated by less than this is one turn. 0.5 s lowers DER on every evaluated set,
    /// with the 0.25 s collar and without it (docs/BENCHMARKS.md); 0.8 s is better only with the collar.
    public var minGapSeconds: Double = 0.5
    /// Output: turns shorter than this are dropped.
    public var minTurnSeconds: Double = 0
    /// Output: speakers with less total speech than this are dropped (0 = keep everyone). A stray cluster of a few
    /// seconds is far more often a cough or a cut-off word than a person.
    public var minSpeakerSeconds: Double = 5

    public init() {}

    public var stepSamples: Int { max(1, Int((stepSeconds * Double(SegmentationGeometry.sampleRate)).rounded())) }
    /// Fold threshold of the final clustering for a recording of `durationSeconds`.
    public func foldMinSize(durationSeconds: Double) -> Int {
        guard foldDurationShare > 0 else { return minClusterSize }
        let seconds = min(foldCeilingSeconds, max(foldFloorSeconds, foldDurationShare * durationSeconds))
        return max(2, Int((seconds / stepSeconds).rounded()))
    }
    /// Reconstruction: every window votes with the same weight (false) or with a Hamming weight centred on the window (true).
    public var hammingFrameWeights = false
    public var minClusterSize: Int { max(2, Int((minClusterSeconds / stepSeconds).rounded())) }
    public var establishedEmbeddings: Int { max(2, Int((establishedSeconds / stepSeconds).rounded())) }
    public var liveReclusterWindows: Int { max(1, Int((liveReclusterSeconds / stepSeconds).rounded())) }
}
