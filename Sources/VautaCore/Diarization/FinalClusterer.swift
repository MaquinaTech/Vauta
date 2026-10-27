// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Accelerate
import Foundation

/// Global clustering over ALL stored window embeddings (no audio needed). Runs at the end of a meeting, and
/// periodically while recording through `SpeakerTracker`.
enum FinalClusterer {
    struct Result {
        /// `[window][localSpeaker]` -> speaker index (0-based, numbered by first appearance in time), -1 when the
        /// local speaker has no embedding.
        var mapping: [[Int]]
        var speakerCount: Int
        var embeddingCount: Int
    }

    /// Lowest cut the over-merge guard goes down to.
    static let guardFloor: Float = 0.40
    static let guardStep: Float = 0.05

    /// Length of the recording the records cover, for the fold that scales with it: the caller's own total when it has
    /// one (the offline path knows how many samples it read), else the end of the last window.
    static func durationSeconds(records: [WindowRecord], totalSamples: Int? = nil) -> Double {
        let samples = totalSamples ?? ((records.last?.startSample ?? 0) + SegmentationGeometry.windowSamples)
        return Double(samples) / Double(SegmentationGeometry.sampleRate)
    }

    static func cluster(records: [WindowRecord], config: DiarizationConfig, totalSamples: Int? = nil) -> Result {
        // 1. the embedded (window, local speaker) pairs
        var refs: [(window: Int, speaker: Int)] = []
        var vectors: [[Float]] = []
        for (w, record) in records.enumerated() {
            for s in 0..<record.embeddings.count { if let e = record.embeddings[s] { refs.append((w, s)); vectors.append(e) } }
        }
        var mapping = [[Int]](repeating: [Int](repeating: -1, count: SegmentationGeometry.localSpeakers), count: records.count)
        guard !vectors.isEmpty else { return Result(mapping: mapping, speakerCount: 0, embeddingCount: 0) }

        // 2. agglomerative clustering (centroid linkage), in two stages when there are too many embeddings
        var labels = agglomerate(vectors, config: config)

        // 3. over-merge guard, then fold tiny clusters into the nearest large one
        labels = splitOverMerged(labels: labels, refs: refs, vectors: vectors, config: config)
        let duration = durationSeconds(records: records, totalSamples: totalSamples)
        labels = foldSmall(labels: labels, vectors: vectors, minSize: config.foldMinSize(durationSeconds: duration))

        // 4. re-assign every embedding to its nearest centroid, one-to-one within a window
        if config.reassignToCentroids {
            // only labels that still have members: a folded or split-away label must not come back as a phantom speaker
            let candidates = Set(labels).sorted()
            let centroids = centroids(labels: labels, vectors: vectors)
            var byWindow: [Int: [Int]] = [:]
            for (i, ref) in refs.enumerated() { byWindow[ref.window, default: []].append(i) }
            for (_, indices) in byWindow {
                let distance = indices.map { i in candidates.map { VectorMath.unitDistance(VectorMath.dot(vectors[i], centroids[$0])) } }
                var pick = VectorMath.greedyDistinct(distance: distance, limit: .infinity)
                // more embeddings than speakers in this window: the extra ones take their nearest speaker
                for k in indices.indices where pick[k] == nil { pick[k] = distance[k].indices.min { distance[k][$0] < distance[k][$1] } }
                for k in indices.indices { labels[indices[k]] = candidates[pick[k]!] }
            }
        }

        // 5. number the speakers by first appearance in time ("Speaker 1, 2, ...")
        var renumber: [Int: Int] = [:]
        for (i, ref) in refs.enumerated() {
            if renumber[labels[i]] == nil { renumber[labels[i]] = renumber.count }
            mapping[ref.window][ref.speaker] = renumber[labels[i]]!
        }
        return Result(mapping: mapping, speakerCount: renumber.count, embeddingCount: vectors.count)
    }

    // MARK: - Steps

    /// One dendrogram over everything when it fits (`maxDirectEmbeddings`); otherwise a first dendrogram per
    /// consecutive chunk, then a second one over the chunk clusters' means weighted by their sizes.
    static func agglomerate(_ vectors: [[Float]], config: DiarizationConfig) -> [Int] {
        let n = vectors.count
        guard n > config.maxDirectEmbeddings else {
            return AgglomerativeClustering.cluster(vectors: vectors, threshold: config.finalThreshold,
                                                   establishedSize: Float(config.establishedEmbeddings), establishedMargin: config.establishedMargin)
        }
        let chunkCount = (n + config.stageChunkSize - 1) / config.stageChunkSize
        let chunkSize = (n + chunkCount - 1) / chunkCount
        var stageOne = [Int](repeating: 0, count: n)   // first-stage cluster id of every embedding
        var sums: [[Float]] = [], counts: [Float] = []
        var start = 0
        while start < n {
            let end = min(n, start + chunkSize)
            // the same guard as the second stage: two established speakers inside one chunk must stay apart here too
            let local = AgglomerativeClustering.cluster(vectors: Array(vectors[start..<end]), threshold: config.finalThreshold,
                                                        establishedSize: Float(config.establishedEmbeddings), establishedMargin: config.establishedMargin)
            let base = sums.count
            let k = (local.max() ?? -1) + 1
            sums.append(contentsOf: [[Float]](repeating: [Float](repeating: 0, count: vectors[0].count), count: k))
            counts.append(contentsOf: [Float](repeating: 0, count: k))
            for (offset, l) in local.enumerated() {
                vDSP.add(sums[base + l], vectors[start + offset], result: &sums[base + l])
                counts[base + l] += 1
                stageOne[start + offset] = base + l
            }
            start = end
        }
        let means = zip(sums, counts).map { sum, count in sum.map { $0 / count } }
        let stageTwo = AgglomerativeClustering.cluster(vectors: means, sizes: counts, threshold: config.finalThreshold,
                                                       establishedSize: Float(config.establishedEmbeddings), establishedMargin: config.establishedMargin)
        // renumber by first appearance, like the single-stage result
        var renumber: [Int: Int] = [:]
        return stageOne.map { id in
            let l = stageTwo[id]
            if renumber[l] == nil { renumber[l] = renumber.count }
            return renumber[l]!
        }
    }

    /// The share of a cluster's windows in which two of its embeddings belong to different local speakers. The
    /// segmentation network says those two are different people, so a high share means the cut merged speakers.
    static func conflictRatio(of members: [Int], refs: [(window: Int, speaker: Int)]) -> Double {
        var perWindow: [Int: Int] = [:]
        for i in members { perWindow[refs[i].window, default: 0] += 1 }
        guard !perWindow.isEmpty else { return 0 }
        return Double(perWindow.values.filter { $0 > 1 }.count) / Double(perWindow.count)
    }

    /// Over-merge guard. A cluster whose conflict ratio is above `maxSameWindowConflict` is clustered again with
    /// a lower cut (down to `guardFloor`) until it splits into at least two parts of `minClusterSize` or more; the
    /// parts are checked in turn. Clusters too small to give two such parts, and clusters that never split into two
    /// (one voice that the segmentation opened twice per window), are left alone.
    static func splitOverMerged(labels: [Int], refs: [(window: Int, speaker: Int)], vectors: [[Float]], config: DiarizationConfig) -> [Int] {
        guard config.maxSameWindowConflict < 1, let top = labels.max() else { return labels }
        var labels = labels
        var next = top + 1
        var pending = Array(0...top)
        while let cluster = pending.popLast() {
            let members = labels.indices.filter { labels[$0] == cluster }
            guard members.count >= 2 * config.minClusterSize,
                  conflictRatio(of: members, refs: refs) > config.maxSameWindowConflict else { continue }
            // One dendrogram of the cluster serves every lower cut (no guard 1 here: it is about merging, and this
            // cluster is being split). A cluster too big for one distance matrix is clustered per cut, in stages,
            // also without guard 1.
            let points = members.map { vectors[$0] }
            var staged = config
            staged.establishedMargin = 0
            let tree = points.count <= config.maxDirectEmbeddings
                ? AgglomerativeClustering.dendrogram(vectors: points, threshold: config.finalThreshold) : nil
            var cut = config.finalThreshold - guardStep
            while cut >= guardFloor {
                let parts = tree?.labels(threshold: cut) ?? agglomerate(points, config: { var c = staged; c.finalThreshold = cut; return c }())
                // a cut counts only if it gives at least two parts that can stand as speakers: peeling off a few stray
                // points (or shattering a voice that the segmentation merely opened twice per window) is no split
                var sizes = [Int](repeating: 0, count: (parts.max() ?? 0) + 1)
                for part in parts { sizes[part] += 1 }
                if sizes.filter({ $0 >= config.minClusterSize }).count >= 2 {
                    var ids: [Int: Int] = [0: cluster]
                    for (position, part) in parts.enumerated() {
                        if ids[part] == nil { ids[part] = next; next += 1 }
                        labels[members[position]] = ids[part]!
                    }
                    pending.append(contentsOf: ids.values)
                    break
                }
                cut -= guardStep
            }
        }
        return labels
    }

    /// Folds clusters with fewer than `minSize` embeddings into the nearest cluster that has enough. If no cluster
    /// is large enough (a short meeting) nothing is folded.
    static func foldSmall(labels: [Int], vectors: [[Float]], minSize: Int) -> [Int] {
        guard let top = labels.max() else { return labels }
        var counts = [Int](repeating: 0, count: top + 1)
        for l in labels { counts[l] += 1 }
        let large = (0...top).filter { counts[$0] >= minSize }
        guard !large.isEmpty, large.count < counts.filter({ $0 > 0 }).count else { return labels }
        let means = centroids(labels: labels, vectors: vectors)
        var out = labels
        for (i, l) in labels.enumerated() where counts[l] < minSize {
            out[i] = large.max { VectorMath.dot(vectors[i], means[$0]) < VectorMath.dot(vectors[i], means[$1]) }!
        }
        return out
    }

    /// L2-normalised mean of every label's members (zeros for a label with no member).
    static func centroids(labels: [Int], vectors: [[Float]]) -> [[Float]] {
        let k = (labels.max() ?? -1) + 1
        var sums = [[Float]](repeating: [Float](repeating: 0, count: vectors[0].count), count: k)
        var counts = [Int](repeating: 0, count: k)
        for (i, l) in labels.enumerated() {
            vDSP.add(sums[l], vectors[i], result: &sums[l])
            counts[l] += 1
        }
        return sums.indices.map { counts[$0] > 0 ? VectorMath.normalised(sums[$0]) : sums[$0] }
    }
}
