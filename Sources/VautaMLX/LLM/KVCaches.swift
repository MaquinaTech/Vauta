// SPDX-License-Identifier: Apache-2.0 AND MIT
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
// Portions derived from mlx-lm (https://github.com/ml-explore/mlx-lm, v0.32.0, MIT), Copyright © 2023-2025 Apple Inc.

import Foundation
import MLX

/// Keys and values of a full-attention layer: a buffer that grows in steps of 1,024 tokens (never preallocated to the whole
/// context), shaped [1, kvHeads, tokens, headDim] in bf16.
final class FullKVCache {
    static let step = 1024
    private(set) var keys: MLXArray?
    private(set) var values: MLXArray?
    private(set) var offset = 0

    /// Appends the new keys and values and returns all of them.
    func update(_ k: MLXArray, _ v: MLXArray) -> (MLXArray, MLXArray) {
        let prev = offset
        let n = k.dim(2)
        if keys == nil || prev + n > keys!.dim(2) {
            let steps = (n + Self.step - 1) / Self.step
            let newK = MLXArray.zeros([k.dim(0), k.dim(1), steps * Self.step, k.dim(3)], dtype: k.dtype)
            let newV = MLXArray.zeros([v.dim(0), v.dim(1), steps * Self.step, v.dim(3)], dtype: v.dtype)
            if let ks = keys, let vs = values {
                let usedK = prev < ks.dim(2) ? ks[0..., 0..., 0..<prev, 0...] : ks
                let usedV = prev < vs.dim(2) ? vs[0..., 0..., 0..<prev, 0...] : vs
                keys = concatenated([usedK, newK], axis: 2)
                values = concatenated([usedV, newV], axis: 2)
            } else {
                keys = newK
                values = newV
            }
        }
        offset += n
        keys![0..., 0..., prev..<offset, 0...] = k
        values![0..., 0..., prev..<offset, 0...] = v
        return (keys![0..., 0..., 0..<offset, 0...], values![0..., 0..., 0..<offset, 0...])
    }

    /// Forgets everything after `length` tokens (the suffix of a prompt that is not reused).
    func truncate(to length: Int) { offset = min(offset, max(0, length)) }

    var arrays: [MLXArray] { [keys, values].compactMap { $0 } }
    var byteCount: Int { arrays.reduce(0) { $0 + $1.nbytes } }
}

/// Keys and values of a sliding-window layer (window 512): only the most recent `window - 1` tokens before a chunk are kept.
/// Attention for a chunk of `n` tokens runs over those and the new ones with a windowed causal mask, so every token sees
/// exactly the previous `window` tokens (itself included). Numerically the same as mlx-lm's rotating cache.
final class SlidingKVCache {
    let window: Int
    private(set) var keys: MLXArray?
    private(set) var values: MLXArray?
    private(set) var offset = 0

    init(window: Int) { self.window = window }

    /// Tokens held before the next update.
    var held: Int { keys?.dim(2) ?? 0 }

    /// Returns the keys and values to attend over (held plus new) and stores the last `window - 1` of them.
    func update(_ k: MLXArray, _ v: MLXArray) -> (MLXArray, MLXArray) {
        let fullK = keys.map { concatenated([$0, k], axis: 2) } ?? k
        let fullV = values.map { concatenated([$0, v], axis: 2) } ?? v
        offset += k.dim(2)
        let n = fullK.dim(2)
        if n > window - 1 {
            keys = fullK[0..., 0..., (n - (window - 1))..., 0...]
            values = fullV[0..., 0..., (n - (window - 1))..., 0...]
        } else {
            keys = fullK
            values = fullV
        }
        return (fullK, fullV)
    }

    /// Replaces the state (a prefix snapshot being restored).
    func restore(keys: MLXArray?, values: MLXArray?, offset: Int) {
        self.keys = keys
        self.values = values
        self.offset = offset
    }

    var arrays: [MLXArray] { [keys, values].compactMap { $0 } }
}

/// The caches of the 24 layers that own keys and values (layers 24-41 read those of layers 22 and 23).
final class LayerCaches {
    let config: Gemma4TextConfig
    var full: [Int: FullKVCache] = [:]
    var sliding: [Int: SlidingKVCache] = [:]

    init(config: Gemma4TextConfig) {
        self.config = config
        for i in config.cacheOwners {
            if config.isFull(i) { full[i] = FullKVCache() } else { sliding[i] = SlidingKVCache(window: config.slidingWindow) }
        }
    }

    /// Tokens processed so far (identical in every layer).
    var offset: Int { config.cacheOwners.first.flatMap { sliding[$0]?.offset ?? full[$0]?.offset } ?? 0 }

    var arrays: [MLXArray] { full.values.flatMap(\.arrays) + sliding.values.flatMap(\.arrays) }
    var byteCount: Int { arrays.reduce(0) { $0 + $1.nbytes } }

    /// What is needed to continue from `length` tokens later: the full layers are truncated, the sliding windows saved.
    struct Snapshot {
        var length: Int
        var sliding: [Int: (MLXArray?, MLXArray?)]

        var arrays: [MLXArray] { sliding.values.flatMap { [$0.0, $0.1].compactMap { $0 } } }
        var byteCount: Int { arrays.reduce(0) { $0 + $1.nbytes } }
    }

    func snapshot() -> Snapshot {
        Snapshot(length: offset, sliding: sliding.mapValues { ($0.keys, $0.values) })
    }

    /// A snapshot that owns its own (evaluated) copy of the windows, so it does not keep the larger buffers they were cut from alive.
    /// Used for the checkpoints a kept prefix can be rewound to.
    func compactSnapshot() -> Snapshot {
        let s = Snapshot(length: offset, sliding: sliding.mapValues { ($0.keys.map { contiguous($0) }, $0.values.map { contiguous($0) }) })
        eval(s.arrays)
        return s
    }

    /// Back to a snapshot taken at `s.length` tokens: the full layers drop what came after, the sliding layers get their window back.
    func restore(_ s: Snapshot) {
        for (_, c) in full { c.truncate(to: s.length) }
        for (i, c) in sliding { c.restore(keys: s.sliding[i]?.0, values: s.sliding[i]?.1, offset: s.length) }
    }
}
