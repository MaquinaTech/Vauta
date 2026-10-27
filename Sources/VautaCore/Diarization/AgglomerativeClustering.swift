// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Accelerate
import Foundation

/// Centroid-linkage agglomerative clustering on Euclidean distance, equivalent to
/// `scipy.cluster.hierarchy.linkage(X, "centroid")` followed by `fcluster(t, "distance")` (what pyannote uses).
///
/// Memory is n(n-1)/2 Float32 squared distances (n = 3000 is 18 MB, n = 6000 is 72 MB), freed after the call.
/// It uses the nearest-neighbour-cache "generic" algorithm (as fastcluster does): O(n^2) in practice.
enum AgglomerativeClustering {
    /// - Parameters:
    ///   - vectors: `n` vectors of equal dimension (normally L2-normalised).
    ///   - sizes: how many points each vector stands for (1 each when nil); used by the second stage of the
    ///     two-stage clustering, where a vector is the mean of a first-stage cluster.
    ///   - threshold: cut height (Euclidean distance between centroids).
    ///   - establishedSize: two clusters that each stand for at least this many points (established speakers) merge
    ///     only up to `threshold - establishedMargin`; fragments still merge up to `threshold`. A refused pair is
    ///     kept apart for good (its distance becomes infinite, and so does that of anything they grow into), while
    ///     everything else goes on merging, so a fragment close to one of them still joins it. The default (no
    ///     limit) is scipy's plain cut.
    /// - Returns: dense cluster labels `0..<k`, numbered by first appearance.
    static func cluster(vectors: [[Float]], sizes: [Float]? = nil, threshold: Float,
                        establishedSize: Float = .infinity, establishedMargin: Float = 0) -> [Int] {
        dendrogram(vectors: vectors, sizes: sizes, threshold: threshold, establishedSize: establishedSize,
                   establishedMargin: establishedMargin).labels(threshold: threshold)
    }

    /// The merges of a dendrogram, from which any cut at or below the `threshold` it was built for can be read.
    struct Dendrogram {
        let count: Int
        let merges: [(a: Int, b: Int, height: Float)]

        /// scipy's `fcluster(distance)`: a merge is kept when its height and every height below it are <= threshold.
        /// Dense labels `0..<k`, numbered by first appearance.
        func labels(threshold: Float) -> [Int] {
            let n = count
            var parent = Array(0..<(n + merges.count))
            func find(_ x: Int) -> Int {
                var x = x
                while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
                return x
            }
            var highest = [Float](repeating: 0, count: n + merges.count)
            for (m, merge) in merges.enumerated() {
                let h = max(merge.height, highest[merge.a], highest[merge.b])
                highest[n + m] = h
                if h <= threshold {
                    parent[find(merge.a)] = n + m
                    parent[find(merge.b)] = n + m
                }
            }
            var labelOfRoot: [Int: Int] = [:]
            var labels = [Int](repeating: 0, count: n)
            for i in 0..<n {
                let root = find(i)
                if let label = labelOfRoot[root] {
                    labels[i] = label
                } else {
                    labelOfRoot[root] = labelOfRoot.count
                    labels[i] = labelOfRoot.count - 1
                }
            }
            return labels
        }
    }

    /// Builds the dendrogram up to heights of `threshold * 1.25` (nothing above the cut can matter).
    static func dendrogram(vectors: [[Float]], sizes: [Float]? = nil, threshold: Float,
                           establishedSize: Float = .infinity, establishedMargin: Float = 0) -> Dendrogram {
        let n = vectors.count
        if n <= 1 { return Dendrogram(count: n, merges: []) }
        let d = vectors[0].count
        // squared distances in condensed upper-triangular form
        @inline(__always) func index(_ i: Int, _ j: Int) -> Int { n * i - i * (i + 1) / 2 + (j - i - 1) } // i < j
        var distance = [Float](repeating: 0, count: n * (n - 1) / 2)
        var flat = [Float]()
        flat.reserveCapacity(n * d)
        for v in vectors { flat.append(contentsOf: v) }
        let squares = vectors.map { VectorMath.dot($0, $0) }
        // ||a-b||^2 = |a|^2 + |b|^2 - 2 a.b, one matrix-vector product per row
        var row = [Float](repeating: 0, count: n)
        for i in 0..<(n - 1) {
            let m = n - i - 1
            flat.withUnsafeBufferPointer { fp in
                // row = rows(i+1...) . row(i): [m x d] * [d x 1]
                vDSP_mmul(fp.baseAddress! + (i + 1) * d, 1, fp.baseAddress! + i * d, 1, &row, 1, vDSP_Length(m), 1, vDSP_Length(d))
            }
            let base = index(i, i + 1)
            for k in 0..<m { distance[base + k] = max(0, squares[i] + squares[i + 1 + k] - 2 * row[k]) }
        }
        var active = [Bool](repeating: true, count: n)
        var size = sizes ?? [Float](repeating: 1, count: n)
        var nearestDistance = [Float](repeating: .infinity, count: n)
        var nearest = [Int](repeating: -1, count: n)
        func rescan(_ i: Int) {
            var best = Float.infinity, bestJ = -1
            if i + 1 < n { for j in (i + 1)..<n where active[j] { let v = distance[index(i, j)]; if v < best { best = v; bestJ = j } } }
            nearestDistance[i] = best
            nearest[i] = bestJ
        }
        for i in 0..<n { rescan(i) }

        // slot -> current node id; leaves are 0..<n and merge m creates node n + m
        var node = Array(0..<n)
        var merges: [(a: Int, b: Int, height: Float)] = []
        let stopSquared = (threshold * 1.25) * (threshold * 1.25) // no merge above the cut can matter
        let refuseHeight = threshold - establishedMargin
        while merges.count < n - 1 {
            var bi = -1, best = Float.infinity
            for i in 0..<n where active[i] && nearestDistance[i] < best { best = nearestDistance[i]; bi = i }
            if bi < 0 || best > stopSquared { break }
            let i = bi, j = nearest[i]
            if size[i] >= establishedSize && size[j] >= establishedSize && sqrtf(best) > refuseHeight {
                // two established speakers this close to the cut are more likely two people than one
                distance[index(i, j)] = .infinity
                rescan(i)
                continue
            }
            merges.append((node[i], node[j], sqrtf(best)))
            let ni = size[i], nj = size[j], total = ni + nj
            // the merged cluster lives in slot j; slot i dies
            active[i] = false
            for k in 0..<n where active[k] && k != j {
                let dik = k < i ? distance[index(k, i)] : distance[index(i, k)]
                let djk = k < j ? distance[index(k, j)] : distance[index(j, k)]
                let updated = max(0, (ni * dik + nj * djk) / total - ni * nj * best / (total * total)) // Lance-Williams, centroid, squared
                if k < j { distance[index(k, j)] = updated } else { distance[index(j, k)] = updated }
            }
            size[j] = total
            node[j] = n + merges.count - 1
            for k in 0..<n where active[k] && k != j {
                if k < j {
                    let v = distance[index(k, j)]
                    if nearest[k] == i || nearest[k] == j { rescan(k) } else if v < nearestDistance[k] { nearestDistance[k] = v; nearest[k] = j }
                } else if nearest[k] == i || nearest[k] == j { rescan(k) }
            }
            rescan(j)
        }
        return Dendrogram(count: n, merges: merges)
    }
}