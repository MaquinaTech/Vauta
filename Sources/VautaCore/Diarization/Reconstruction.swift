// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// One stretch of one speaker's speech, in seconds from the start of the recording. Turns of different speakers
/// may overlap (crosstalk).
public struct SpeakerTurn: Sendable, Equatable {
    public var start: Double
    public var end: Double
    /// 0-based speaker index (the meeting's ordinal is this plus one).
    public var speaker: Int

    public init(start: Double, end: Double, speaker: Int) {
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

/// The outcome of diarizing a whole recording.
public struct Diarization: Sendable {
    public var turns: [SpeakerTurn]
    public var speakerCount: Int
    /// `[window][localSpeaker]` -> speaker index, -1 where there is no embedding.
    public var mapping: [[Int]]
    /// The voice vector of each final speaker (`SpeakerCentroids`). Voice data: held in memory for the finalization
    /// that follows, never logged, stored or exported by itself.
    public var centroids: [SpeakerCentroid] = []
}

public enum Reconstruction {
    private static let frames = SegmentationGeometry.frames
    private static let hamming: [Float] = (0..<frames).map { Float(0.54 - 0.46 * cos(2 * Double.pi * Double($0) / Double(frames - 1))) }

    /// The whole recording, offline: clusters every stored window embedding (`FinalClusterer`) and builds the turns.
    /// Cost is dominated by the clustering: 33 to 66 ms for 43 to 60 minutes of real audio at the 2 s step (the
    /// acceptance budget is 15 s for 60 minutes). Speakers with less speech than `minSpeakerSeconds` are dropped and
    /// the rest renumbered by first appearance.
    public static func diarize(records: [WindowRecord], totalSamples: Int, config: DiarizationConfig = DiarizationConfig()) -> Diarization {
        var result = FinalClusterer.cluster(records: records, config: config, totalSamples: totalSamples)
        var turns = dropShortSpeakers(finalTurns(records: records, mapping: result.mapping, speakerCount: result.speakerCount,
                                                 totalSamples: totalSamples, config: config), minSeconds: config.minSpeakerSeconds)
        // speakers dropped for speaking too little leave no hole in the numbering ("Speaker 1, 2, ...")
        var renumber: [Int: Int] = [:]
        for turn in turns where renumber[turn.speaker] == nil { renumber[turn.speaker] = renumber.count }
        if renumber.count != result.speakerCount {
            for i in turns.indices { turns[i].speaker = renumber[turns[i].speaker]! }
            result.mapping = result.mapping.map { $0.map { renumber[$0] ?? -1 } }
            result.speakerCount = renumber.count
        }
        return Diarization(turns: turns, speakerCount: result.speakerCount, mapping: result.mapping,
                           centroids: SpeakerCentroids.compute(records: records, mapping: result.mapping, turns: turns, config: config))
    }

    static func globalFrameCount(totalSamples: Int) -> Int { totalSamples / SegmentationGeometry.frameStepSamples + 2 }

    /// Global frame index of local frame `t` of a window starting at `startSample`.
    @inline(__always) static func globalFrame(start: Int, t: Int) -> Int {
        Int((Double(start) / Double(SegmentationGeometry.frameStepSamples)).rounded()) + t
    }

    /// FINAL reconstruction (pyannote `to_diarization` style): every frame is covered by several windows; each
    /// speaker's score is a Hamming-weighted vote, the speaker count is the weighted mean of the local counts, and
    /// the top-N speakers are kept. Overlapping speech is preserved.
    static func finalTurns(records: [WindowRecord], mapping: [[Int]], speakerCount K: Int, totalSamples: Int,
                           config: DiarizationConfig) -> [SpeakerTurn] {
        guard K > 0 else { return [] }
        let G = globalFrameCount(totalSamples: totalSamples)
        var score = [Float](repeating: 0, count: K * G)
        var weightSum = [Float](repeating: 0, count: G)
        var countSum = [Float](repeating: 0, count: G)
        for (w, record) in records.enumerated() {
            for t in 0..<frames {
                let g = globalFrame(start: record.startSample, t: t)
                if g >= G { break }
                let mask = record.activity(frame: t)
                let weight = config.hammingFrameWeights ? hamming[t] : 1
                weightSum[g] += weight
                countSum[g] += weight * Float(mask.nonzeroBitCount)
                if mask == 0 { continue }
                var seen: UInt32 = 0
                for s in 0..<SegmentationGeometry.localSpeakers where mask & (1 << s) != 0 {
                    let c = mapping[w][s]
                    if c >= 0 && seen & (1 << UInt32(c)) == 0 { seen |= 1 << UInt32(c); score[c * G + g] += weight }
                }
            }
        }
        var active = [[Bool]](repeating: [Bool](repeating: false, count: G), count: K)
        for g in 0..<G where weightSum[g] > 0 {
            let count = min(K, Int((countSum[g] / weightSum[g]).rounded()))
            if count == 0 { continue }
            let order = (0..<K).sorted { score[$0 * G + g] > score[$1 * G + g] }
            for c in order.prefix(count) where score[c * G + g] > 0 { active[c][g] = true }
        }
        return turns(from: active, config: config)
    }

    /// LIVE reconstruction: each frame is labelled once, by the window whose centre region contains it, with the
    /// labels in force for that window. A frame gets its label when its window completes, (10 s - step) / 2 = 4 s
    /// after it was spoken at the 2 s step; the first window also labels the head and the last one the tail.
    static func liveTurns(records: [WindowRecord], labels: [[Int]], totalSamples: Int, config: DiarizationConfig) -> [SpeakerTurn] {
        let K = (labels.joined().max() ?? -1) + 1
        guard K > 0 else { return [] }
        let G = globalFrameCount(totalSamples: totalSamples)
        var active = [[Bool]](repeating: [Bool](repeating: false, count: G), count: K)
        let W = SegmentationGeometry.windowSamples, step = config.stepSamples, frameStep = SegmentationGeometry.frameStepSamples
        for (w, record) in records.enumerated() {
            let lo = w == 0 ? 0 : max(0, (record.startSample + (W - step) / 2) / frameStep)
            let hi = w == records.count - 1 ? G : min(G, (record.startSample + (W + step) / 2) / frameStep)
            if lo >= hi { continue }
            let first = Int((Double(record.startSample) / Double(frameStep)).rounded())
            for g in lo..<hi {
                let t = g - first
                if t < 0 || t >= frames { continue }
                let mask = record.activity(frame: t)
                for s in 0..<SegmentationGeometry.localSpeakers where mask & (1 << s) != 0 {
                    let c = labels[w][s]
                    if c >= 0 { active[c][g] = true }
                }
            }
        }
        return turns(from: active, config: config)
    }

    static func turns(from active: [[Bool]], config: DiarizationConfig) -> [SpeakerTurn] {
        let step = SegmentationGeometry.frameStepSeconds
        // a frame's time is that of its receptive field's centre, from the middle of the previous step
        let offset = SegmentationGeometry.frameOffsetSeconds
        var out: [SpeakerTurn] = []
        for (speaker, flags) in active.enumerated() {
            var merged: [(start: Double, end: Double)] = []
            var g = 0
            while g < flags.count {
                guard flags[g] else { g += 1; continue }
                var e = g
                while e < flags.count && flags[e] { e += 1 }
                let start = Double(g) * step + offset, end = Double(e) * step + offset
                if let last = merged.last, start - last.end < config.minGapSeconds {
                    merged[merged.count - 1].end = end
                } else {
                    merged.append((start, end))
                }
                g = e
            }
            for run in merged where run.end - run.start >= config.minTurnSeconds {
                out.append(SpeakerTurn(start: max(0, run.start), end: run.end, speaker: speaker))
            }
        }
        return out.sorted { ($0.start, $0.speaker) < ($1.start, $1.speaker) }
    }

    /// Removes speakers whose total speech is below `minSeconds`.
    static func dropShortSpeakers(_ turns: [SpeakerTurn], minSeconds: Double) -> [SpeakerTurn] {
        guard minSeconds > 0 else { return turns }
        var total: [Int: Double] = [:]
        for t in turns { total[t.speaker, default: 0] += t.end - t.start }
        return turns.filter { total[$0.speaker, default: 0] >= minSeconds }
    }

    /// RTTM text of turns (for evaluation tools).
    public static func rttm(_ turns: [SpeakerTurn], fileID: String) -> String {
        turns.map { String(format: "SPEAKER %@ 1 %.3f %.3f <NA> <NA> spk%d <NA> <NA>\n", fileID, $0.start, $0.end - $0.start, $0.speaker + 1) }.joined()
    }
}
