// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

public enum AffineQuantizerError: Error, Equatable, Sendable {
    case nonFinite
    case badShape
}

/// Deterministic CPU affine quantizer, 4 or 8 bits, group size 64: the arithmetic of MLX's Metal `affine_quantize` kernel (what
/// `mlx_lm convert` runs on the GPU), so the result is byte-identical to that conversion.
///
/// Per group: the minimum starts at the bf16 maximum and the maximum at 0 (a Metal quirk that is part of the format),
/// `scale = max((max - min) / top, 1e-7)` with `top` 15 or 255, the edge with the larger magnitude is mapped to an exact integer,
/// values are rounded half away from zero and clamped at `top`, and scales and biases are stored as bf16 (round to nearest even).
/// Eight 4-bit or four 8-bit values pack little-endian into a `UInt32`. All arithmetic is IEEE fp32 with no fused operations; the result does
/// not depend on the number of threads or on how rows are chunked.
public enum AffineQuantizer {
    public static let groupSize = 64
    /// The bits of most tensors; `LanguageModelSpec.bits(forOutputStem:)` names the ones kept at 8.
    public static let bits = 4
    static let bfloat16Max = Float(bitPattern: 0x7F7F_0000)

    /// Words of packed values per group of 64.
    public static func wordsPerGroup(bits: Int) -> Int { groupSize * bits / 32 }

    /// Quantizes `rows` rows of `cols` bf16 values (`cols` a multiple of 64) to `bits` (4 or 8). Output buffers hold
    /// `rows * cols * bits / 32` words and `rows * cols / 64` scales and biases (bf16 bit patterns).
    public static func quantize(rows: Int, cols: Int, bits: Int = bits, source: UnsafePointer<UInt16>, weights: UnsafeMutablePointer<UInt32>,
                                scales: UnsafeMutablePointer<UInt16>, biases: UnsafeMutablePointer<UInt16>) throws {
        guard rows >= 0, cols > 0, cols % groupSize == 0, bits == 4 || bits == 8 else { throw AffineQuantizerError.badShape }
        let words = wordsPerGroup(bits: bits)
        if rows == 0 { return }
        let groupsPerRow = cols / groupSize
        let slices = min(rows, max(1, ProcessInfo.processInfo.activeProcessorCount * 4))
        let bad = UnsafeMutablePointer<Bool>.allocate(capacity: slices)
        bad.initialize(repeating: false, count: slices)
        defer { bad.deallocate() }
        let buffers = Buffers(source: source, weights: weights, scales: scales, biases: biases, bad: bad)
        // Row slices are independent: any partition gives the same bytes.
        DispatchQueue.concurrentPerform(iterations: slices) { s in
            let r0 = rows * s / slices, r1 = rows * (s + 1) / slices
            for r in r0..<r1 {
                for g in 0..<groupsPerRow {
                    let gi = r * groupsPerRow + g
                    if !quantizeGroup(buffers.source + gi * groupSize, buffers.weights + gi * words, buffers.scales + gi, buffers.biases + gi, bits: bits) {
                        buffers.bad[s] = true
                    }
                }
            }
        }
        for s in 0..<slices where bad[s] { throw AffineQuantizerError.nonFinite }
    }

    /// Array form of `quantize` (tests and small tensors).
    public static func quantize(rows: Int, cols: Int, bits: Int = bits, source: [UInt16], weights: inout [UInt32], scales: inout [UInt16],
                                biases: inout [UInt16]) throws {
        try source.withUnsafeBufferPointer { src in
            try weights.withUnsafeMutableBufferPointer { w in
                try scales.withUnsafeMutableBufferPointer { s in
                    try biases.withUnsafeMutableBufferPointer { b in
                        try quantize(rows: rows, cols: cols, bits: bits, source: src.baseAddress!, weights: w.baseAddress!, scales: s.baseAddress!,
                                     biases: b.baseAddress!)
                    }
                }
            }
        }
    }

    /// The buffers of one call, shared by the slices (each writes its own rows only).
    private struct Buffers: @unchecked Sendable {
        let source: UnsafePointer<UInt16>
        let weights: UnsafeMutablePointer<UInt32>
        let scales: UnsafeMutablePointer<UInt16>
        let biases: UnsafeMutablePointer<UInt16>
        let bad: UnsafeMutablePointer<Bool>
    }

    @inline(__always) static func bf16ToFloat(_ b: UInt16) -> Float { Float(bitPattern: UInt32(b) << 16) }

    /// Round to nearest even; callers guarantee a finite input.
    @inline(__always) static func floatToBF16(_ f: Float) -> UInt16 {
        let u = f.bitPattern
        if f.isNaN { return 0x7FC0 }
        return UInt16(truncatingIfNeeded: (u &+ 0x7FFF &+ ((u >> 16) & 1)) >> 16)
    }

    /// One group of 64 values. Returns false when a value is NaN or infinite.
    @inline(__always)
    static func quantizeGroup(_ src: UnsafePointer<UInt16>, _ words: UnsafeMutablePointer<UInt32>, _ scaleOut: UnsafeMutablePointer<UInt16>,
                              _ biasOut: UnsafeMutablePointer<UInt16>, bits: Int) -> Bool {
        var ok = true
        let maxBin = Float((1 << bits) - 1), perWord = 32 / bits, wordCount = wordsPerGroup(bits: bits)
        withUnsafeTemporaryAllocation(of: Float.self, capacity: groupSize) { w in
            var lo = bfloat16Max, hi: Float = 0
            var finite = true
            for i in 0..<groupSize {
                let x = bf16ToFloat(src[i])
                if !x.isFinite { finite = false }
                w[i] = x
                lo = min(lo, x)
                hi = max(hi, x)
            }
            if !finite {
                scaleOut.pointee = 0; biasOut.pointee = 0
                for k in 0..<wordCount { words[k] = 0 }
                ok = false
                return
            }
            var scale = max((hi - lo) / maxBin, 1e-7)
            let side = abs(lo) > abs(hi)
            scale = side ? scale : -scale
            let edge = side ? lo : hi
            let q0 = (edge / scale).rounded(.toNearestOrAwayFromZero)
            let atZero = q0 == 0
            if !atZero { scale = edge / q0 }
            let bias: Float = atZero ? 0 : edge
            scaleOut.pointee = floatToBF16(scale)
            biasOut.pointee = floatToBF16(bias)
            for k in 0..<wordCount {
                var word: UInt32 = 0
                for j in 0..<perWord {
                    var q = ((w[k * perWord + j] - bias) / scale).rounded(.toNearestOrAwayFromZero)
                    q = min(max(q, 0), maxBin)
                    word |= UInt32(q) << UInt32(bits * j)
                }
                words[k] = word
            }
        }
        return ok
    }
}
