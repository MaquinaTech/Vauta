// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// int8 vectors and brute-force search (moved from the former `Vauta store-selftest`).
@Suite("Models: vector index")
struct ModelsVectorIndexTests {
    @Test func int8SearchFindsTheRightVector() async throws {
        let top = try await offPool { () -> [(id: Int64, score: Float)] in
            var x: UInt64 = 0x9E3779B97F4A7C15
            func random() -> Float { x ^= x << 13; x ^= x >> 7; x ^= x << 17; return Float(Int64(bitPattern: x % 2001) - 1000) / 1000 }
            let n = 20_000
            let dims = 1024
            let buffer = SecretBuffer(capacity: n * dims)
            var ids: [Int64] = [], scales: [Float] = []
            var target: [Float] = []
            for i in 0..<n {
                let v = (0..<dims).map { _ in random() }
                if i == 12_345 { target = v }
                let (q, s) = VectorIndex.quantize(v)!
                q.withUnsafeBytes { (buffer.base + buffer.count).copyMemory(from: $0.baseAddress!, byteCount: dims) }
                buffer.count += dims
                ids.append(Int64(i))
                scales.append(s)
            }
            let index = VectorIndex(dims: dims, ids: ids, scales: scales, buffer: buffer)
            let noisy = target.map { $0 + random() * 0.2 }
            let top = index.search(noisy, k: 10)
            return top
        }
        #expect(top.first?.id == 12_345)
        #expect((top.first?.score ?? 0) > 0.9)
    }

    @Test func aSearchAmongSomeIdsRanksExactlyThoseTheIndexHolds() {
        let dims = 8
        // Vector i is the first axis plus i on axis i + 1: the larger i, the further from the first axis.
        let vectors: [[Float]] = (0..<6).map { i in (0..<dims).map { d in d == 0 ? 1 : (d == i + 1 ? Float(i) : 0) } }
        let buffer = SecretBuffer(capacity: vectors.count * dims)
        var scales: [Float] = []
        for v in vectors {
            let (q, s) = VectorIndex.quantize(v)!
            q.withUnsafeBytes { (buffer.base + buffer.count).copyMemory(from: $0.baseAddress!, byteCount: dims) }
            buffer.count += dims
            scales.append(s)
        }
        let index = VectorIndex(dims: dims, ids: [10, 11, 12, 13, 14, 15], scales: scales, buffer: buffer)
        let query: [Float] = [1, 0, 0, 0, 0, 0, 0, 0]
        // The whole index's top 2 is 10 and 11; among 15, 13 and 99 (not held) it is 13 then 15, each with its own cosine.
        #expect(index.search(query, k: 2).map(\.id) == [10, 11])
        let among = index.search(query, k: 5, among: [15, 99, 13, 13])
        #expect(among.map(\.id) == [13, 15])
        let own = index.score(query, ids: [13, 15])
        #expect(own.count == 2 && among.map(\.score) == [13, 15].compactMap { own[$0] })
        #expect(index.search(query, k: 1, among: [15, 13]).map(\.id) == [13])
        #expect(index.search(query, k: 0, among: [13]).isEmpty && index.search(query, k: 3, among: []).isEmpty)
    }

    @Test func quantizeKeepsAnySizeAndRejectsZeroVectors() {
        #expect(VectorIndex.quantize([Float](repeating: 1, count: 768))?.q.count == 768)
        #expect(VectorIndex.quantize([Float](repeating: 0, count: 1024)) == nil)
        #expect(VectorIndex.quantize([]) == nil)
    }
}
