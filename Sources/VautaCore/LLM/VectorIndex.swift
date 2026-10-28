// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Accelerate
import Foundation

/// int8 vectors (one per 90–120 s chunk) of one embedding space, in
/// contiguous memory that is zeroed when released. Exact brute-force search
/// with Accelerate: a few thousand chunks take milliseconds, no ANN needed.
struct VectorIndex: @unchecked Sendable {
    /// Vector length of every row (`chunks.dims`).
    let dims: Int
    let ids: [Int64]
    let scales: [Float]
    let buffer: SecretBuffer

    var count: Int { ids.count }

    /// A stored row with this scale is not a vector: it says the search model looked at the item and could not embed it (text
    /// that is only whitespace, or a result that stayed NaN after the fp32 retry). Without it the item would be tried again on
    /// every pass and coverage would never be complete. Index builders skip such rows; coverage counts them as covered, and
    /// they are counted apart.
    static let unembeddableScale: Float = 0

    /// The zeroed row of `dims` bytes that stands for an item the model cannot embed.
    static func unembeddableMarker(dims: Int) -> (q: Data, scale: Float) { (Data(count: dims), unembeddableScale) }

    /// L2-normalizes and quantizes to symmetric int8: v ≈ q · scale. The
    /// stored length is the vector's own length.
    static func quantize(_ v: [Float]) -> (q: Data, scale: Float)? {
        guard let unit = normalized(v) else { return nil }
        let maxAbs = vDSP.maximumMagnitude(unit)
        guard maxAbs > 0 else { return nil }
        let scale = maxAbs / 127
        let scaled = vDSP.divide(unit, scale)
        var q = Data(count: v.count)
        q.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int8.self)
            for i in 0..<scaled.count { p[i] = Int8(max(-127, min(127, scaled[i].rounded()))) }
        }
        return (q, scale)
    }

    /// The vector as the index holds it after `quantize` (q · scale), for a score that must be on the scale of the stored ones.
    static func asStored(_ v: [Float]) -> [Float]? {
        guard let (q, scale) = quantize(v) else { return nil }
        return q.map { Float(Int8(bitPattern: $0)) * scale }
    }

    static func normalized(_ v: [Float]) -> [Float]? {
        guard !v.isEmpty else { return nil }
        let norm = sqrt(vDSP.sumOfSquares(v))
        guard norm > 0, norm.isFinite else { return nil }
        return vDSP.divide(v, norm)
    }

    /// The cosine of the query to each of `ids` that this index holds (ids it does not hold are left out). `ids` of the index are
    /// ascending, so each is found by binary search.
    func score(_ query: [Float], ids wanted: [Int64]) -> [Int64: Float] {
        guard query.count == dims, let q = Self.normalized(query), count > 0 else { return [:] }
        let base = buffer.base.assumingMemoryBound(to: Int8.self)
        var out: [Int64: Float] = [:]
        for id in wanted where out[id] == nil {
            var lo = 0, hi = count - 1, row = -1
            while lo <= hi {
                let mid = (lo + hi) / 2
                if ids[mid] == id { row = mid; break }
                if ids[mid] < id { lo = mid + 1 } else { hi = mid - 1 }
            }
            guard row >= 0 else { continue }
            var dot: Float = 0
            let r = base + row * dims
            for d in 0..<dims { dot += Float(r[d]) * q[d] }
            out[id] = dot * scales[row]
        }
        return out
    }

    /// The `k` of `ids` most similar to the query, best first (ids it does not hold are left out). A search within a scope (one
    /// meeting, some files) ranks the scope's own vectors this way: a top K of the whole index, filtered by the scope afterwards,
    /// loses them whenever more than K vectors elsewhere are closer.
    func search(_ query: [Float], k: Int, among wanted: [Int64]) -> [(id: Int64, score: Float)] {
        guard k > 0 else { return [] }
        return score(query, ids: wanted).sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(k).map { (id: $0.key, score: $0.value) }
    }

    /// The `k` chunks most similar (approximate cosine) to the query. A query
    /// of another length (another space) finds nothing.
    func search(_ query: [Float], k: Int) -> [(id: Int64, score: Float)] {
        guard query.count == dims, let q = Self.normalized(query), count > 0, k > 0 else { return [] }
        let block = 256
        var scores = [Float](repeating: 0, count: count)
        // Dequantized vectors in owned memory that is zeroed when released.
        let work = SecretBuffer(capacity: block * dims * MemoryLayout<Float>.stride)
        let floats = work.base.assumingMemoryBound(to: Float.self)
        let base = buffer.base.assumingMemoryBound(to: Int8.self)
        var row = 0
        while row < count {
            let n = min(block, count - row)
            // int8 → float for the block, then a matrix-vector product:
            // (n × dims) · (dims × 1) → n scores.
            vDSP_vflt8(base + row * dims, 1, floats, 1, vDSP_Length(n * dims))
            scores.withUnsafeMutableBufferPointer { out in
                vDSP_mmul(floats, 1, q, 1, out.baseAddress! + row, 1, vDSP_Length(n), 1, vDSP_Length(dims))
            }
            row += n
        }
        for i in 0..<count { scores[i] *= scales[i] }
        // Top k without sorting everything.
        var top: [(Int64, Float)] = []
        top.reserveCapacity(k + 1)
        for i in 0..<count {
            let s = scores[i]
            if top.count < k { top.append((ids[i], s)); if top.count == k { top.sort { $0.1 > $1.1 } } }
            else if s > top[k - 1].1 {
                top[k - 1] = (ids[i], s)
                var j = k - 1
                while j > 0 && top[j].1 > top[j - 1].1 { top.swapAt(j, j - 1); j -= 1 }
            }
        }
        if top.count < k { top.sort { $0.1 > $1.1 } }
        return top.map { (id: $0.0, score: $0.1) }
    }
}
