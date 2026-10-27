// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Accelerate
import Foundation

/// Small vector helpers shared by the clusterers (Accelerate).
enum VectorMath {
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }

    static func normalised(_ v: [Float]) -> [Float] {
        let norm = sqrtf(max(dot(v, v), 1e-20))
        return v.map { $0 / norm }
    }

    /// Euclidean distance of two L2-normalised vectors from their dot product: sqrt(2 - 2 cos).
    static func unitDistance(_ cosine: Float) -> Float { sqrtf(max(0, 2 - 2 * cosine)) }

    /// Greedy one-to-one assignment: repeatedly takes the closest (row, column) pair, so two speakers of the
    /// same window never share a cluster. `distance[row][column]`; a row whose best free column is farther than
    /// `limit` gets nil.
    static func greedyDistinct(distance: [[Float]], limit: Float) -> [Int?] {
        var out = [Int?](repeating: nil, count: distance.count)
        var used = Set<Int>()
        var pairs: [(distance: Float, row: Int, column: Int)] = []
        for r in distance.indices { for c in distance[r].indices where distance[r][c] <= limit { pairs.append((distance[r][c], r, c)) } }
        pairs.sort { $0.distance < $1.distance }
        for pair in pairs where out[pair.row] == nil && !used.contains(pair.column) {
            out[pair.row] = pair.column
            used.insert(pair.column)
        }
        return out
    }
}

/// Incremental clustering behind the provisional (live) speaker labels. One `assign` per analysed window.
/// Not thread-safe: the owner serialises calls.
final class OnlineClusterer {
    private struct Cluster {
        var sum: [Float]
        var centroid: [Float]
    }

    private let config: DiarizationConfig
    /// Indexed by label. A retired label (merged away by a re-clustering) is nil and never matches again.
    private var clusters: [Cluster?] = []

    init(config: DiarizationConfig) {
        self.config = config
    }

    /// Labels handed out so far (retired ones included): the next new label is this number.
    var labelCount: Int { clusters.count }

    /// Labels in use.
    var activeCount: Int { clusters.reduce(0) { $0 + ($1 == nil ? 0 : 1) } }

    /// Labels the local speakers of one window. `usable[s]` is the seconds of speech behind speaker `s`.
    /// Returns a label per local speaker, -1 when the speaker has no embedding.
    func assign(embeddings: [[Float]?], usable: [Float]) -> [Int] {
        var out = [Int](repeating: -1, count: embeddings.count)
        let speakers = embeddings.indices.filter { embeddings[$0] != nil }
        guard !speakers.isEmpty else { return out }
        let live = clusters.indices.filter { clusters[$0] != nil }
        let distance: [[Float]] = speakers.map { s in live.map { VectorMath.unitDistance(VectorMath.dot(embeddings[s]!, clusters[$0]!.centroid)) } }
        let match = VectorMath.greedyDistinct(distance: distance, limit: config.onlineAssignDistance)
        for (i, s) in speakers.enumerated() {
            let embedding = embeddings[s]!
            if let m = match[i] {
                out[s] = live[m]
                absorb(live[m], embedding)
            } else if Double(usable[s]) >= config.onlineNewClusterSeconds || live.isEmpty {
                clusters.append(Cluster(sum: embedding, centroid: embedding))
                out[s] = clusters.count - 1
            } else if let nearest = distance[i].indices.min(by: { distance[i][$0] < distance[i][$1] }) {
                out[s] = live[nearest] // weak evidence: take the nearest label but do not move it
            }
        }
        return out
    }

    /// Replaces the clusters after a global re-clustering: `sums[label]` is the sum of the members' embeddings,
    /// nil for a label that no longer exists.
    func reset(sums: [[Float]?]) {
        clusters = sums.map { $0.map { Cluster(sum: $0, centroid: VectorMath.normalised($0)) } }
    }

    private func absorb(_ label: Int, _ embedding: [Float]) {
        guard var cluster = clusters[label] else { return }
        vDSP.add(cluster.sum, embedding, result: &cluster.sum)
        cluster.centroid = VectorMath.normalised(cluster.sum)
        clusters[label] = cluster
    }
}
