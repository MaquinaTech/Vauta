// SPDX-License-Identifier: Apache-2.0 AND MIT
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
// Portions derived from mlx-lm (https://github.com/ml-explore/mlx-lm, v0.32.0, MIT), Copyright © 2023-2025 Apple Inc.

import Foundation
import MLX
import MLXFast
import MLXNN

/// A 4-bit affine quantised linear layer (group 64): `x @ W.T` on the packed weights.
struct QuantizedLinear {
    let w: MLXArray, scales: MLXArray, biases: MLXArray

    init(_ file: SafetensorsFile, _ path: String) throws {
        w = try file.array(path + ".weight")
        scales = try file.array(path + ".scales")
        biases = try file.array(path + ".biases")
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        quantizedMM(x, w, scales: scales, biases: biases, transpose: true, groupSize: 64, bits: 4)
    }

    var arrays: [MLXArray] { [w, scales, biases] }
}

/// A quantised embedding table kept resident (the token embedding, also the tied output head).
struct QuantizedEmbedding {
    let w: MLXArray, scales: MLXArray, biases: MLXArray

    init(_ file: SafetensorsFile, _ path: String) throws {
        w = try file.array(path + ".weight")
        scales = try file.array(path + ".scales")
        biases = try file.array(path + ".biases")
    }

    /// Rows for `ids` ([n] int32), dequantised to bf16.
    func rows(_ ids: MLXArray) -> MLXArray {
        dequantized(w[ids], scales: scales[ids], biases: biases[ids], groupSize: 64, bits: 4)
    }

    /// The tied head: `x @ E.T`.
    func asLinear(_ x: MLXArray) -> MLXArray {
        quantizedMM(x, w, scales: scales, biases: biases, transpose: true, groupSize: 64, bits: 4)
    }
}

final class Gemma4Layer {
    let index: Int
    let full: Bool, ownsKV: Bool
    let headDim: Int
    let q: QuantizedLinear, o: QuantizedLinear
    let k: QuantizedLinear?, v: QuantizedLinear?
    let gate: QuantizedLinear, up: QuantizedLinear, down: QuantizedLinear
    let pleGate: QuantizedLinear, pleProj: QuantizedLinear
    let inNorm: MLXArray, postAttnNorm: MLXArray, preFfNorm: MLXArray, postFfNorm: MLXArray, qNorm: MLXArray, kNorm: MLXArray?
    let pleNorm: MLXArray, layerScalar: MLXArray
    let ones: MLXArray

    init(_ file: SafetensorsFile, _ cfg: Gemma4TextConfig, _ i: Int) throws {
        index = i
        full = cfg.isFull(i)
        ownsKV = cfg.ownsKV(i)
        headDim = cfg.headDim(i)
        let p = "language_model.model.layers.\(i)."
        q = try QuantizedLinear(file, p + "self_attn.q_proj")
        o = try QuantizedLinear(file, p + "self_attn.o_proj")
        k = ownsKV ? try QuantizedLinear(file, p + "self_attn.k_proj") : nil
        v = ownsKV ? try QuantizedLinear(file, p + "self_attn.v_proj") : nil
        gate = try QuantizedLinear(file, p + "mlp.gate_proj")
        up = try QuantizedLinear(file, p + "mlp.up_proj")
        down = try QuantizedLinear(file, p + "mlp.down_proj")
        pleGate = try QuantizedLinear(file, p + "per_layer_input_gate")
        pleProj = try QuantizedLinear(file, p + "per_layer_projection")
        inNorm = try file.array(p + "input_layernorm.weight")
        postAttnNorm = try file.array(p + "post_attention_layernorm.weight")
        preFfNorm = try file.array(p + "pre_feedforward_layernorm.weight")
        postFfNorm = try file.array(p + "post_feedforward_layernorm.weight")
        qNorm = try file.array(p + "self_attn.q_norm.weight")
        kNorm = ownsKV ? try file.array(p + "self_attn.k_norm.weight") : nil
        pleNorm = try file.array(p + "post_per_layer_input_norm.weight")
        layerScalar = try file.array(p + "layer_scalar")
        ones = MLXArray.ones([headDim]).asType(.bfloat16)
    }

    var arrays: [MLXArray] {
        var a = q.arrays + o.arrays + gate.arrays + up.arrays + down.arrays + pleGate.arrays + pleProj.arrays
        a += [inNorm, postAttnNorm, preFfNorm, postFfNorm, qNorm, pleNorm, layerScalar]
        if let k, let v, let kNorm { a += k.arrays + v.arrays + [kNorm] }
        return a
    }
}

public enum Gemma4Error: Error, Equatable, Sendable {
    case emptyPrompt
    case tooLong(Int)
    case badWeights(String)
    /// Every logit was NaN or infinite with no grammar to blame.
    case noValidToken
}

/// Gemma 4 E4B (text) on MLX, a port of mlx-lm's `gemma4_text.py` for the pinned 4-bit file: 42 layers, per-layer inputs (the
/// 1.6 GB per-layer embedding table is read straight from the memory map, never loaded), shared keys and values for layers
/// 24-41, proportional RoPE on the full-attention layers, tied output head with a soft cap. bf16 activations.
///
/// Not `Sendable` (`MLXArray`): owned by one actor. GPU only.
public final class Gemma4TextModel {
    public let config: Gemma4TextConfig
    let file: SafetensorsFile
    let embed: QuantizedEmbedding
    let layers: [Gemma4Layer]
    let finalNorm: MLXArray
    let pleProjection: QuantizedLinear
    let pleProjectionNorm: MLXArray
    let proportionalFreqs: MLXArray
    let embedScale: MLXArray, pleTokenScale: MLXArray, pleProjectionScale: MLXArray, pleInputScale: MLXArray
    let ones256: MLXArray

    static let pleTable = "language_model.model.embed_tokens_per_layer"

    public init(url: URL, config: Gemma4TextConfig = .pinned) throws {
        self.config = config
        file = try SafetensorsFile(url: url)
        guard file.entries[Self.pleTable + ".weight"]?.shape == [config.vocab, config.layers * config.pleDim * 4 / 32] else {
            throw Gemma4Error.badWeights("per-layer table")
        }
        embed = try QuantizedEmbedding(file, "language_model.model.embed_tokens")
        let fileRef = file, cfg = config
        layers = try (0..<cfg.layers).map { try Gemma4Layer(fileRef, cfg, $0) }
        finalNorm = try file.array("language_model.model.norm.weight")
        pleProjection = try QuantizedLinear(file, "language_model.model.per_layer_model_projection")
        pleProjectionNorm = try file.array("language_model.model.per_layer_projection_norm.weight")
        // freqs = [base^(2i/512) for the 64 rotated pairs] ++ [inf x 192]: the exponent divides by the whole head dimension.
        let rotatedPairs = config.fullRotatedDims / 2
        var f = [Float](repeating: .infinity, count: config.fullHeadDim / 2)
        for i in 0..<rotatedPairs { f[i] = Float(pow(Double(config.fullRopeBase), Double(2 * i) / Double(config.fullHeadDim))) }
        proportionalFreqs = MLXArray(f)
        func scalar(_ x: Double) -> MLXArray { MLXArray(Float(x)).asType(.bfloat16) }
        embedScale = scalar(Double(config.hiddenSize).squareRoot())
        pleTokenScale = scalar(Double(config.pleDim).squareRoot())
        pleProjectionScale = scalar(1 / Double(config.hiddenSize).squareRoot())
        pleInputScale = scalar(1 / 2.0.squareRoot())
        ones256 = MLXArray.ones([config.slidingHeadDim]).asType(.bfloat16)
        eval(layers.flatMap(\.arrays) + [embed.w, embed.scales, embed.biases, finalNorm, pleProjectionNorm] + pleProjection.arrays)
    }

    /// Bytes of the resident weights (what `eval` loaded): the figure to compare with the 2.6 GB estimate.
    public var residentBytes: Int {
        (layers.flatMap(\.arrays) + [embed.w, embed.scales, embed.biases, finalNorm, pleProjectionNorm] + pleProjection.arrays).reduce(0) { $0 + $1.nbytes }
    }

    private func rms(_ x: MLXArray, _ w: MLXArray) -> MLXArray { MLXFast.rmsNorm(x, weight: w, eps: config.eps) }

    func newCaches() -> LayerCaches { LayerCaches(config: config) }

    /// Per-layer token inputs: the dequantised rows of the memory-mapped table for the ids, x16, [1, n, 42, 256].
    private func pleTokens(_ ids: [Int32]) throws -> MLXArray {
        let w = try file.gatherRows(Self.pleTable + ".weight", ids: ids)
        let s = try file.gatherRows(Self.pleTable + ".scales", ids: ids)
        let b = try file.gatherRows(Self.pleTable + ".biases", ids: ids)
        let rows = dequantized(w, scales: s, biases: b, groupSize: 64, bits: 4) * pleTokenScale
        return rows.reshaped([1, ids.count, config.layers, config.pleDim])
    }

    /// What `forward` computes once the last layer that owns keys and values has written them. The layers from
    /// `firstSharedLayer` on read those keys and values and write no cache, so a position whose hidden state nobody reads needs
    /// nothing after that write (in the pinned model, layers 24-41 and most of layer 23: about 45% of a prefill chunk's matrix
    /// products).
    enum ForwardOutput {
        /// The caches only: stops at the last cache write (a prefill chunk whose hidden states are thrown away).
        case cachesOnly
        /// The final-normalised hidden state of the last position [1, 1, 2560]: after the last cache write only that position is
        /// computed (logits are only ever needed for the last position of a chunk).
        case lastHidden
        /// The final-normalised hidden states of every position [1, n, 2560], every position through every layer, as before the
        /// cut: the reference the parity tests compare with (`Gemma4Engine.cutsSharedLayers = false`).
        case allHidden
    }

    /// Test hook: called for every layer that runs its queries, with the layer's index and the positions it runs them for. A
    /// `.cachesOnly` run stops once layer `firstSharedLayer - 1` has written its keys and values, so it reports the layers before.
    var layerProbe: ((_ layer: Int, _ positions: Int) -> Void)?

    /// Runs `ids` through the network, appending to `caches`, and returns the hidden states `output` asks for (nil for
    /// `.cachesOnly`).
    func forward(_ ids: [Int32], caches: LayerCaches, output: ForwardOutput) throws -> MLXArray? {
        guard !ids.isEmpty else { throw Gemma4Error.emptyPrompt }
        let n = ids.count
        let idArray = MLXArray(ids)
        var h = embed.rows(idArray).reshaped([1, n, config.hiddenSize]) * embedScale
        var ple = pleProjection(h) * pleProjectionScale
        ple = ple.reshaped([1, n, config.layers, config.pleDim])
        ple = rms(ple, pleProjectionNorm)
        ple = (ple + (try pleTokens(ids))) * pleInputScale

        // Masks are shared by the layers of one type; they depend on the owner cache state before the update.
        let slidingHeld = caches.sliding.values.first?.held ?? 0
        let fullMask: MLXFast.ScaledDotProductAttentionMaskMode = n == 1 ? .none : .causal
        let slidingMask: MLXFast.ScaledDotProductAttentionMaskMode = {
            guard n > 1 else { return .none }
            let w = config.slidingWindow
            if slidingHeld + n <= w { return .causal }
            let rows = (MLXArray(0..<Int32(n)) + Int32(slidingHeld)).reshaped([n, 1])
            let cols = MLXArray(0..<Int32(slidingHeld + n)).reshaped([1, slidingHeld + n])
            return .array(logicalAnd(rows .>= cols, (rows - cols) .< Int32(w)))
        }()
        // The last position alone sees every key of a full layer, and the keys of its window in a sliding one: the last row of the
        // windowed mask (with no mask it would also see the keys before its window).
        let lastSlidingMask: MLXFast.ScaledDotProductAttentionMaskMode = {
            if case .array(let m) = slidingMask { return .array(m[(n - 1)..., 0...]) }
            return .none
        }()

        // After the keys and values of this layer, only the last position is computed (or nothing, for `.cachesOnly`).
        let cutLayer = output == .allHidden ? nil : config.firstSharedLayer - 1
        // The positions of the chunk that `h` holds: `rows` of them from position `first` (all of them, or the last one after the cut).
        var rows = n, first = 0
        var shared: [Int: (MLXArray, MLXArray, Int)] = [:]
        for L in layers {
            let i = L.index
            var x = rms(h, L.inNorm)
            let keys: MLXArray, values: MLXArray, offset: Int
            if L.ownsKV, let kp = L.k, let vp = L.v, let kn = L.kNorm {
                var k = kp(x).reshaped([1, n, config.kvHeads, L.headDim])
                var v = vp(x).reshaped([1, n, config.kvHeads, L.headDim])
                k = rms(k, kn).transposed(0, 2, 1, 3)
                v = rms(v, L.ones).transposed(0, 2, 1, 3)
                offset = L.full ? (caches.full[i]?.offset ?? 0) : (caches.sliding[i]?.offset ?? 0)
                k = rope(k, L, offset: offset)
                (keys, values) = L.full ? caches.full[i]!.update(k, v) : caches.sliding[i]!.update(k, v)
                shared[i] = (keys, values, offset)
            } else {
                let src = config.kvSource(i)
                (keys, values, offset) = shared[src]!
            }
            if i == cutLayer {
                if output == .cachesOnly { return nil }
                if n > 1 {
                    h = h[0..., (n - 1)..., 0...]
                    x = x[0..., (n - 1)..., 0...]
                    ple = ple[0..., (n - 1)..., 0..., 0...]
                    (rows, first) = (1, n - 1)
                }
            }
            layerProbe?(i, rows)
            var queries = L.q(x).reshaped([1, rows, config.heads, L.headDim])
            queries = rms(queries, L.qNorm).transposed(0, 2, 1, 3)
            // A query's position is the cache offset plus its place in the chunk.
            queries = rope(queries, L, offset: offset + first)
            let cutMask: MLXFast.ScaledDotProductAttentionMaskMode = L.full ? .none : lastSlidingMask
            let mask: MLXFast.ScaledDotProductAttentionMaskMode = rows == n ? (L.full ? fullMask : slidingMask) : cutMask
            var a = MLXFast.scaledDotProductAttention(queries: queries, keys: keys, values: values, scale: 1.0, mask: mask)
            a = a.transposed(0, 2, 1, 3).reshaped([1, rows, config.heads * L.headDim])
            h = h + rms(L.o(a), L.postAttnNorm)
            x = rms(h, L.preFfNorm)
            let m = L.down(geluApproximate(L.gate(x)) * L.up(x))
            h = h + rms(m, L.postFfNorm)
            var g = geluApproximate(L.pleGate(h)) * ple[0..., 0..., i, 0...]
            g = rms(L.pleProj(g), L.pleNorm)
            h = (h + g) * L.layerScalar
        }
        switch output {
        case .cachesOnly: return nil
        case .allHidden: return rms(h, finalNorm)
        case .lastHidden: return rms(rows == 1 ? h : h[0..., (n - 1)..., 0...], finalNorm)
        }
    }

    private func rope(_ x: MLXArray, _ L: Gemma4Layer, offset: Int) -> MLXArray {
        if L.full {
            return MLXFast.RoPE(x, dimensions: config.fullHeadDim, traditional: false, base: nil, scale: 1.0, offset: offset, freqs: proportionalFreqs)
        }
        return MLXFast.RoPE(x, dimensions: config.slidingHeadDim, traditional: false, base: config.slidingRopeBase, scale: 1.0, offset: offset)
    }

    /// Logits [1, 1, vocab] for a hidden state: the tied head and `tanh(x / 30) * 30`.
    func logits(_ hidden: MLXArray) -> MLXArray {
        let out = embed.asLinear(hidden)
        let cap = MLXArray(config.softcap).asType(out.dtype)
        return tanh(out / cap) * cap
    }
}
