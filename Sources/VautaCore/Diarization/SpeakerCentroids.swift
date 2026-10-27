// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The voice vector of each final speaker of a diarized recording: the L2-normalised mean of every window embedding
/// the final clustering assigned to that speaker. This is what one voice-profile embedding is (one per confirmed
/// speaker per meeting), and what a new speaker is compared with.
///
/// Voice data: never logged, exported, indexed or sent anywhere.
public struct SpeakerCentroid: Sendable {
    /// 0-based final speaker index (the same numbering as `SpeakerTurn.speaker`).
    public var speaker: Int
    /// How many window embeddings the mean covers.
    public var embeddingCount: Int
    /// Sum of the usable seconds of every window embedding. Windows are 10 s long and start every `stepSeconds`, so
    /// one second of speech is counted up to five times: do not read this as a duration (use `speechSeconds`).
    public var usableSeconds: Double
    /// Real seconds of clean speech behind the centroid: `usableSeconds` divided by how many windows cover each
    /// second. This is what the "30 s of clean speech" gate counts.
    public var speechSeconds: Double
    /// Share (0...1) of the speaker's turn time during which another speaker also speaks.
    public var overlapShare: Double
    /// Mean cosine of the window embeddings to the centroid (1: a tight voice; low: two voices may be merged).
    public var spread: Float
    /// 256 floats, L2-normalised.
    public var vector: [Float]

    public init(speaker: Int, embeddingCount: Int, usableSeconds: Double, speechSeconds: Double? = nil,
                overlapShare: Double = 0, spread: Float = 1, vector: [Float]) {
        self.speaker = speaker
        self.embeddingCount = embeddingCount
        self.usableSeconds = usableSeconds
        self.speechSeconds = speechSeconds ?? usableSeconds
        self.overlapShare = overlapShare
        self.spread = spread
        self.vector = vector
    }
}

extension SpeakerCentroid: CustomStringConvertible, CustomDebugStringConvertible {
    /// Never prints the vector.
    public var description: String { "SpeakerCentroid(speaker: \(speaker), embeddings: \(embeddingCount))" }
    public var debugDescription: String { description }
}

public enum SpeakerCentroids {
    /// One centroid per final speaker that has at least one embedding, in speaker order.
    ///
    /// - `turns`: the final turns, to measure how much of each speaker's time is shared with another speaker.
    /// - `config`: gives how many windows cover each second (window length over `stepSeconds`).
    public static func compute(records: [WindowRecord], mapping: [[Int]], turns: [SpeakerTurn] = [],
                               config: DiarizationConfig = DiarizationConfig()) -> [SpeakerCentroid] {
        var sums: [Int: [Float]] = [:]
        var counts: [Int: Int] = [:]
        var seconds: [Int: Double] = [:]
        for (w, record) in records.enumerated() where w < mapping.count {
            for s in 0..<record.embeddings.count {
                guard let e = record.embeddings[s], s < mapping[w].count, mapping[w][s] >= 0 else { continue }
                let speaker = mapping[w][s]
                if sums[speaker] == nil { sums[speaker] = [Float](repeating: 0, count: e.count) }
                for i in e.indices { sums[speaker]![i] += e[i] }
                counts[speaker, default: 0] += 1
                seconds[speaker, default: 0] += Double(record.usableSeconds[s])
            }
        }
        let coverage = max(1, Double(SegmentationGeometry.windowSamples) / Double(SegmentationGeometry.sampleRate) / config.stepSeconds)
        let overlaps = overlapShares(turns)
        return sums.keys.sorted().map { speaker in
            let vector = VectorMath.normalised(sums[speaker]!)
            var dots: Float = 0
            for (w, record) in records.enumerated() where w < mapping.count {
                for s in 0..<record.embeddings.count {
                    guard let e = record.embeddings[s], s < mapping[w].count, mapping[w][s] == speaker, e.count == vector.count else { continue }
                    dots += VectorMath.dot(VectorMath.normalised(e), vector)
                }
            }
            let n = counts[speaker] ?? 0
            return SpeakerCentroid(speaker: speaker, embeddingCount: n, usableSeconds: seconds[speaker] ?? 0,
                                   speechSeconds: (seconds[speaker] ?? 0) / coverage, overlapShare: overlaps[speaker] ?? 0,
                                   spread: n > 0 ? dots / Float(n) : 0, vector: vector)
        }
    }

    /// For each speaker, the share of their turn time that another speaker's turn also covers.
    static func overlapShares(_ turns: [SpeakerTurn]) -> [Int: Double] {
        var total: [Int: Double] = [:], shared: [Int: Double] = [:]
        let sorted = turns.sorted { $0.start < $1.start }
        let longest = sorted.map { $0.end - $0.start }.max() ?? 0
        for (i, t) in sorted.enumerated() {
            total[t.speaker, default: 0] += max(0, t.end - t.start)
            // Other speakers' stretches that cut this turn, merged so that a stretch is counted once.
            var cuts: [(Double, Double)] = []
            var j = i - 1
            while j >= 0, sorted[j].start > t.start - longest { j -= 1 }
            for o in sorted[max(0, j)...] {
                if o.start >= t.end { break }
                if o.speaker != t.speaker, o.end > t.start { cuts.append((max(o.start, t.start), min(o.end, t.end))) }
            }
            cuts.sort { $0.0 < $1.0 }
            var covered = 0.0, edge = -Double.infinity
            for (a, b) in cuts {
                let from = max(a, edge)
                if b > from { covered += b - from; edge = b }
            }
            shared[t.speaker, default: 0] += covered
        }
        return total.reduce(into: [:]) { out, kv in out[kv.key] = kv.value > 0 ? min(1, (shared[kv.key] ?? 0) / kv.value) : 0 }
    }

    /// Cosine similarity of two L2-normalised vectors.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        a.count == b.count ? VectorMath.dot(a, b) : -1
    }
}
