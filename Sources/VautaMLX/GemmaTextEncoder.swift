// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import MLX
import MLXFast
import MLXNN

public enum ComputeType: String, Sendable {
    case fp32, bf16, fp16
    var dtype: DType {
        switch self {
        case .fp32: .float32
        case .bf16: .bfloat16
        case .fp16: .float16
        }
    }
}

/// One batch of vectors: `dims` floats per input, row-major, and which rows contain a NaN or infinity.
public struct EncodedBatch: Sendable {
    public let dims: Int
    public let vectors: [Float]
    public let nonFinite: [Bool]
}

/// The EmbeddingGemma 2 text tower on MLX, from the text-only safetensors file (spike 9c: cosine >= 0.9999 against fp32).
///
/// Not `Sendable`: `MLXArray` is not. Owned by one actor (`SearchModelEngine`). GPU only. The sliding-window attention mask
/// is not implemented, so a sequence is at most `maxSequence` tokens (the window is 512).
public final class GemmaTextEncoder {
    struct Layer {
        var inNorm, postAttnNorm, preFfNorm, postFfNorm, qNorm, kNorm: MLXArray
        var q, k, v, o, gate, up, down, pleGate, pleProj: MLXArray   // stored transposed ([in, out]) for x @ W
        var pleNorm, layerScalar: MLXArray
        var headDim: Int, kvHeads: Int, ropeBase: Float
    }

    public static let maxSequence = 512
    public static let outputDimensions = 768
    public static let vocabularySize = 262_144

    public let compute: ComputeType
    private let nLayers = 24, nHeads = 4, hidden = 512, pleDim = 512
    private let eps: Float = 1e-6
    private let file: SafetensorsFile
    private var layers: [Layer] = []
    private var finalNorm: MLXArray, pleProjW: MLXArray, pleNorm: MLXArray, embProj: MLXArray
    private let ones256: MLXArray, ones512: MLXArray
    private let embedScale: Float

    public init(url: URL, compute: ComputeType) throws {
        self.compute = compute
        let dt = compute.dtype
        file = try SafetensorsFile(url: url)
        let f = file
        func vec(_ k: String) throws -> MLXArray { try f.array(k).asType(dt) }
        func lin(_ k: String) throws -> MLXArray { try f.array(k).asType(dt).transposed() }
        // HF multiplies by embed_scale cast to the weight dtype: fp32 -> 22.627417, bf16 -> 22.625.
        embedScale = compute == .bf16 ? Self.roundToBFloat16(Float(512).squareRoot()) : Float(512).squareRoot()
        finalNorm = try vec("norm.weight")
        pleProjW = try lin("ple.per_layer_model_projection.weight")
        pleNorm = try vec("ple.per_layer_projection_norm.weight")
        embProj = try lin("embedding_projection.weight")
        ones256 = MLXArray.ones([256]).asType(dt)
        ones512 = MLXArray.ones([512]).asType(dt)
        for i in 0..<nLayers {
            let p = "layers.\(i)."
            let full = (i % 6 == 5)  // every sixth layer is full attention (5, 11, 17, 23)
            layers.append(Layer(
                inNorm: try vec(p + "input_layernorm.weight"), postAttnNorm: try vec(p + "post_attention_layernorm.weight"),
                preFfNorm: try vec(p + "pre_feedforward_layernorm.weight"), postFfNorm: try vec(p + "post_feedforward_layernorm.weight"),
                qNorm: try vec(p + "self_attn.q_norm.weight"), kNorm: try vec(p + "self_attn.k_norm.weight"),
                q: try lin(p + "self_attn.q_proj.weight"), k: try lin(p + "self_attn.k_proj.weight"),
                v: try lin(p + "self_attn.v_proj.weight"), o: try lin(p + "self_attn.o_proj.weight"),
                gate: try lin(p + "mlp.gate_proj.weight"), up: try lin(p + "mlp.up_proj.weight"), down: try lin(p + "mlp.down_proj.weight"),
                pleGate: try lin(p + "ple_block.per_layer_input_gate.weight"), pleProj: try lin(p + "ple_block.per_layer_projection.weight"),
                pleNorm: try vec(p + "ple_block.post_per_layer_input_norm.weight"), layerScalar: try vec(p + "layer_scalar"),
                headDim: full ? 512 : 256, kvHeads: full ? 1 : 2, ropeBase: full ? 1_000_000 : 10_000))
        }
        guard let table = file.entries["embed_tokens.weight"], table.shape == [Self.vocabularySize, hidden] else {
            throw SafetensorsError.shapeMismatch("embed_tokens.weight")
        }
        eval(layers.flatMap { [$0.q, $0.k, $0.v, $0.o, $0.gate, $0.up, $0.down] } + [embProj, pleProjW])
    }

    private func rms(_ x: MLXArray, _ w: MLXArray) -> MLXArray { MLXFast.rmsNorm(x, weight: w, eps: eps) }

    /// ids: [B, T] int32 (right padded), valid: [B, T] bool (nil for B = 1). Returns L2-normalised [B, dims] float32.
    private func forward(ids: [Int32], B: Int, T: Int, valid: MLXArray?, matryoshka: Int?) throws -> MLXArray {
        let dt = compute.dtype
        var h = try file.gatherRowsBF16("embed_tokens.weight", ids: ids).reshaped([B, T, hidden]).asType(dt) * MLXArray(embedScale).asType(dt)
        // Projection-only per-layer inputs.
        var ple = matmul(h, pleProjW) * MLXArray(Float(1) / Float(512).squareRoot()).asType(dt)
        ple = ple.reshaped([B, T, nLayers, pleDim])
        ple = rms(ple, pleNorm)
        var mask: MLXArray?
        if let valid { mask = valid.reshaped([B, 1, 1, T]) }
        for (li, L) in layers.enumerated() {
            var x = rms(h, L.inNorm)
            var q = matmul(x, L.q).reshaped([B, T, nHeads, L.headDim]).transposed(0, 2, 1, 3)
            var k = matmul(x, L.k).reshaped([B, T, L.kvHeads, L.headDim]).transposed(0, 2, 1, 3)
            var v = matmul(x, L.v).reshaped([B, T, L.kvHeads, L.headDim]).transposed(0, 2, 1, 3)
            q = rms(q, L.qNorm)
            k = rms(k, L.kNorm)
            v = rms(v, L.headDim == 256 ? ones256 : ones512)
            q = MLXFast.RoPE(q, dimensions: L.headDim, traditional: false, base: L.ropeBase, scale: 1, offset: 0)
            k = MLXFast.RoPE(k, dimensions: L.headDim, traditional: false, base: L.ropeBase, scale: 1, offset: 0)
            var a = MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale: 1.0, mask: mask)
            a = a.transposed(0, 2, 1, 3).reshaped([B, T, nHeads * L.headDim])
            a = rms(matmul(a, L.o), L.postAttnNorm)
            h = h + a
            x = rms(h, L.preFfNorm)
            let m = matmul(geluApproximate(matmul(x, L.gate)) * matmul(x, L.up), L.down)
            h = h + rms(m, L.postFfNorm)
            var g = geluApproximate(matmul(h, L.pleGate)) * ple[0..., 0..., li, 0...]
            g = rms(matmul(g, L.pleProj), L.pleNorm)
            h = (h + g) * L.layerScalar
        }
        h = rms(h, finalNorm).asType(.float32)
        // Mean pooling (prompt tokens included), then the 512 -> 768 projection (linear, so equal to projecting per token).
        var pooled: MLXArray
        if let valid {
            let mf = valid.asType(.float32).reshaped([B, T, 1])
            pooled = (h * mf).sum(axis: 1) / mf.sum(axis: 1)
        } else {
            pooled = h.mean(axis: 1)
        }
        var e = matmul(pooled, embProj.asType(.float32))
        e = e / sqrt((e * e).sum(axis: -1, keepDims: true))
        if let d = matryoshka {
            e = e[0..., 0..<d]
            e = e / sqrt((e * e).sum(axis: -1, keepDims: true))
        }
        return e
    }

    /// Embeds one batch of tokenised sequences (each includes bos and eos). One `eval`: it cannot be interrupted, so
    /// callers keep batches small (see `SearchModelEngine`).
    public func embedBatch(tokens: [[Int32]], matryoshka: Int? = nil, padID: Int32 = 0) throws -> EncodedBatch {
        guard !tokens.isEmpty else { return EncodedBatch(dims: matryoshka ?? Self.outputDimensions, vectors: [], nonFinite: []) }
        if let matryoshka, matryoshka <= 0 || matryoshka > Self.outputDimensions { throw SafetensorsError.shapeMismatch("matryoshka") }
        let dims = matryoshka ?? Self.outputDimensions
        for t in tokens {
            if t.isEmpty || t.count > Self.maxSequence { throw SafetensorsError.emptySequence }
            for id in t where id < 0 || Int(id) >= Self.vocabularySize { throw SafetensorsError.tokenOutOfRange(id) }
        }
        let B = tokens.count
        let T = tokens.map(\.count).max()!
        var flat = [Int32](repeating: padID, count: B * T)
        var vm = [Bool](repeating: false, count: B * T)
        for (r, row) in tokens.enumerated() {
            for (c, t) in row.enumerated() {
                flat[r * T + c] = t
                vm[r * T + c] = true
            }
        }
        let valid: MLXArray? = B == 1 ? nil : MLXArray(vm, [B, T])
        return try Device.withDefaultDevice(.gpu) {
            let e = try forward(ids: flat, B: B, T: T, valid: valid, matryoshka: matryoshka)
            let bad = logicalOr(isNaN(e), isInf(e)).any(axis: -1)
            eval(e, bad)
            return EncodedBatch(dims: dims, vectors: e.asArray(Float.self), nonFinite: bad.asArray(Bool.self))
        }
    }

    static func roundToBFloat16(_ f: Float) -> Float {
        var bits = f.bitPattern
        bits = (bits &+ 0x7FFF &+ ((bits >> 16) & 1)) & 0xFFFF0000
        return Float(bitPattern: bits)
    }
}
