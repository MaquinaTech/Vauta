// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
@testable import VautaCore

/// Fixtures written by tools/convert-diarization-models/export_fixtures.py: a 12 s excerpt of an AMI Meeting Corpus
/// recording (CC BY 4.0) and references computed by independent code (NumPy fbank, pyannote.audio in PyTorch FP32,
/// scipy). About 0.7 MB in all.
enum DiarizationFixtures {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true).appendingPathComponent("Diarization", isDirectory: true)

    struct Window: Decodable {
        let startSeconds: Double
        let classes: [Int]
        let usableSeconds: [Double]
        let embeddings: [[Double]?]
        enum CodingKeys: String, CodingKey { case startSeconds = "start_s", classes, usableSeconds = "usable_seconds", embeddings }
    }

    struct FbankReference: Decodable {
        let file: String
        let scale: Double
        let frames: Int
        let bins: Int
    }

    struct Reference: Decodable {
        let fbank: FbankReference
        let windows: [Window]
    }

    struct AHCLabels: Decodable {
        let dimension: Int
        let count: Int
        let labels: [String: [Int]]
    }

    /// The 12 s clip as Float samples in [-1, 1).
    static func clip() throws -> [Float] {
        let data = try Data(contentsOf: folder.appendingPathComponent("clip.i16"))
        return int16s(data).map { Float($0) / 32768 }
    }

    /// The 10 s window starting `seconds` into the clip.
    static func window(_ clip: [Float], at seconds: Double) -> [Float] {
        let start = Int(seconds * 16_000)
        return Array(clip[start..<(start + SegmentationGeometry.windowSamples)])
    }

    static func reference() throws -> Reference {
        try JSONDecoder().decode(Reference.self, from: Data(contentsOf: folder.appendingPathComponent("reference.json")))
    }

    static func referenceFbank(_ reference: Reference) throws -> [Float] {
        let data = try Data(contentsOf: folder.appendingPathComponent(reference.fbank.file))
        return int16s(data).map { Float(Double($0) / reference.fbank.scale) }
    }

    static func ahcVectors() throws -> (vectors: [[Float]], labels: AHCLabels) {
        let labels = try JSONDecoder().decode(AHCLabels.self, from: Data(contentsOf: folder.appendingPathComponent("ahc_labels.json")))
        let data = try Data(contentsOf: folder.appendingPathComponent("ahc_vectors.f32"))
        let flat = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return ((0..<labels.count).map { Array(flat[($0 * labels.dimension)..<(($0 + 1) * labels.dimension)]) }, labels)
    }

    private static func int16s(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Int16(littleEndian: $0) }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        let dot = zip(a, b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        let na = a.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        let nb = b.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        return dot / (na * nb)
    }
}

/// Deterministic pseudo-random numbers for synthetic data (no Foundation randomness in tests).
struct TestRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var x = state
        x ^= x >> 33; x = x &* 0xff51_afd7_ed55_8ccd; x ^= x >> 33
        return x
    }

    /// Uniform in [0, 1).
    mutating func uniform() -> Float { Float(next() >> 40) / Float(1 << 24) }

    /// Standard normal (Box-Muller).
    mutating func gaussian() -> Float {
        let u1 = max(uniform(), 1e-7), u2 = uniform()
        return sqrtf(-2 * logf(u1)) * cosf(2 * .pi * u2)
    }

    mutating func unitVector(dimension: Int = 256) -> [Float] {
        VectorMath.normalised((0..<dimension).map { _ in gaussian() })
    }

    /// `center` plus Gaussian noise of per-dimension deviation `noise`, L2-normalised.
    mutating func around(_ center: [Float], noise: Float) -> [Float] {
        VectorMath.normalised(center.map { $0 + noise * gaussian() })
    }
}

/// A two-speaker-per-window recording made of synthetic window records, for the clustering tests.
enum SyntheticRecords {
    /// Powerset classes of a window in which `speakers` (local indices) talk in turn, each for a third of the window.
    static func classes(local speakers: [Int]) -> [UInt8] {
        let single: [Int: UInt8] = [0: 1, 1: 2, 2: 3]
        var out = [UInt8](repeating: 0, count: SegmentationGeometry.frames)
        for t in out.indices {
            out[t] = speakers.isEmpty ? 0 : single[speakers[min(speakers.count - 1, t * speakers.count / SegmentationGeometry.frames)]]!
        }
        return out
    }

    /// One record per window: `plan[w]` lists the (centre index, usable seconds) of the speakers talking in window w, in
    /// local-speaker order.
    static func records(plan: [[Int]], centres: [[Float]], noise: Float, step: Int = 32_000, seed: UInt64 = 7,
                        usable: Float = 6) -> [WindowRecord] {
        var random = TestRandom(seed: seed)
        return plan.enumerated().map { w, speakers in
            var embeddings = [[Float]?](repeating: nil, count: 3)
            var seconds = [Float](repeating: 0, count: 3)
            for (local, centre) in speakers.enumerated() {
                embeddings[local] = random.around(centres[centre], noise: noise)
                seconds[local] = usable
            }
            return WindowRecord(startSample: w * step, classes: classes(local: Array(speakers.indices)), embeddings: embeddings,
                                usableSeconds: seconds)
        }
    }

    /// Cluster labels as a partition: two labelings are equal when they group the points identically.
    static func samePartition(_ a: [Int], _ b: [Int]) -> Bool {
        guard a.count == b.count else { return false }
        var forward: [Int: Int] = [:], backward: [Int: Int] = [:]
        for (x, y) in zip(a, b) {
            if let known = forward[x], known != y { return false }
            if let known = backward[y], known != x { return false }
            forward[x] = y
            backward[y] = x
        }
        return true
    }
}
