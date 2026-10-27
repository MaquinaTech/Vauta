// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Optimal one-to-one assignment (Hungarian method, O(n^3)).
enum Hungarian {
    /// For a `rows x columns` matrix of weights, picks at most one column per row and one row per column so the
    /// total weight is the largest. Returns the column of each row, nil where the row got none (more rows than
    /// columns, or only zero weight left).
    static func maximize(_ weights: [[Int]]) -> [Int?] {
        let rows = weights.count
        let columns = weights.first?.count ?? 0
        guard rows > 0, columns > 0 else { return [Int?](repeating: nil, count: rows) }
        let size = max(rows, columns)
        let peak = weights.joined().max() ?? 0
        // minimise (peak - weight) on a square matrix padded with the worst cost
        func cost(_ r: Int, _ c: Int) -> Int { r < rows && c < columns ? peak - weights[r][c] : peak }
        var u = [Int](repeating: 0, count: size + 1), v = [Int](repeating: 0, count: size + 1)
        var assigned = [Int](repeating: 0, count: size + 1)  // assigned[column] = row (1-based), 0 = free
        var way = [Int](repeating: 0, count: size + 1)
        for r in 1...size {
            assigned[0] = r
            var column0 = 0
            var minimum = [Int](repeating: Int.max, count: size + 1)
            var used = [Bool](repeating: false, count: size + 1)
            repeat {
                used[column0] = true
                let row0 = assigned[column0]
                var delta = Int.max, column1 = 0
                for c in 1...size where !used[c] {
                    let current = cost(row0 - 1, c - 1) - u[row0] - v[c]
                    if current < minimum[c] { minimum[c] = current; way[c] = column0 }
                    if minimum[c] < delta { delta = minimum[c]; column1 = c }
                }
                for c in 0...size {
                    if used[c] { u[assigned[c]] += delta; v[c] -= delta } else { minimum[c] -= delta }
                }
                column0 = column1
            } while assigned[column0] != 0
            repeat {
                let column1 = way[column0]
                assigned[column0] = assigned[column1]
                column0 = column1
            } while column0 != 0
        }
        var out = [Int?](repeating: nil, count: rows)
        for c in 1...size where assigned[c] != 0 {
            let r = assigned[c] - 1
            if r < rows && c - 1 < columns && weights[r][c - 1] > 0 { out[r] = c - 1 }
        }
        return out
    }
}

/// Live speaker labels that stay stable while they get better.
///
/// Each analysed window is labelled at once by the cheap online clusterer. That drifts (it over-segments: 6 to 11
/// live speakers against about 4 real ones in the first evaluation), so every `liveReclusterSeconds` all the
/// embeddings so far are clustered again exactly as at the end of the meeting, and the new clusters are mapped back
/// onto the labels already shown with the Hungarian method (most shared embeddings wins). A speaker therefore
/// keeps its label unless it really was merged into another; labels of merged speakers are retired and never
/// reused, and a speaker the global clustering finds anew gets a fresh label.
///
/// Not thread-safe: the owner (the diarizer's queue) serialises calls.
public final class SpeakerTracker {
    public let config: DiarizationConfig
    /// Every window analysed so far. Window embeddings are voice data: the owner deletes them at finalization.
    public private(set) var records: [WindowRecord] = []
    /// Current label of each local speaker of each window, -1 where it has no embedding.
    public private(set) var labels: [[Int]] = []
    private let online: OnlineClusterer
    private var windowsSinceRecluster = 0

    public init(config: DiarizationConfig = DiarizationConfig()) {
        self.config = config
        self.online = OnlineClusterer(config: config)
    }

    /// Labels in use right now.
    public var speakerCount: Int { online.activeCount }

    /// True when `recluster()` is due.
    public var isReclusterDue: Bool { windowsSinceRecluster >= config.liveReclusterWindows }

    /// Adds a window and returns its provisional labels (one per local speaker, -1 = none).
    @discardableResult
    public func add(_ record: WindowRecord) -> [Int] {
        let live = online.assign(embeddings: record.embeddings, usable: record.usableSeconds)
        records.append(record)
        labels.append(live)
        windowsSinceRecluster += 1
        return live
    }

    /// Clusters everything again and maps the result onto the existing labels. Returns the indices of the windows
    /// whose labels changed.
    @discardableResult
    public func recluster() -> [Int] {
        windowsSinceRecluster = 0
        // A speaker who joined a few seconds ago must not be folded into another and lose the label already shown.
        var live = config
        live.minClusterSeconds = config.liveMinClusterSeconds
        live.foldDurationShare = 0   // the live fold keeps its fixed size
        let result = FinalClusterer.cluster(records: records, config: live)
        guard result.speakerCount > 0 else { return [] }
        // how many embeddings each (old label, new cluster) pair shares
        var shared = [[Int]](repeating: [Int](repeating: 0, count: result.speakerCount), count: online.labelCount)
        for w in records.indices {
            for s in labels[w].indices where labels[w][s] >= 0 && result.mapping[w][s] >= 0 {
                shared[labels[w][s]][result.mapping[w][s]] += 1
            }
        }
        // the new cluster of each old label; clusters nobody claimed get fresh labels
        let claimed = Hungarian.maximize(shared)
        var labelOfCluster = [Int](repeating: -1, count: result.speakerCount)
        for (old, cluster) in claimed.enumerated() { if let cluster { labelOfCluster[cluster] = old } }
        var fresh = online.labelCount
        for cluster in labelOfCluster.indices where labelOfCluster[cluster] < 0 {
            labelOfCluster[cluster] = fresh
            fresh += 1
        }
        var changed: [Int] = []
        var sums = [[Float]?](repeating: nil, count: fresh)
        for w in records.indices {
            var next = labels[w]
            for s in next.indices {
                let cluster = result.mapping[w][s]
                next[s] = cluster >= 0 ? labelOfCluster[cluster] : -1
                if let embedding = records[w].embeddings[s], cluster >= 0 {
                    let label = next[s]
                    sums[label] = sums[label].map { zip($0, embedding).map(+) } ?? embedding
                }
            }
            if next != labels[w] { changed.append(w); labels[w] = next }
        }
        online.reset(sums: sums)
        return changed
    }
}
