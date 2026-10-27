// SPDX-License-Identifier: Apache-2.0 AND MIT
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
// Portions derived from mlx-lm (https://github.com/ml-explore/mlx-lm, v0.32.0, MIT), Copyright © 2023-2025 Apple Inc.

import Foundation
import MLX

/// What the next token may be, from a grammar.
public enum LogitMask: Sendable {
    /// Any token.
    case free
    /// Exactly this token (no sampling needed).
    case forced(Int32)
    /// Several tokens, one after the other, with no sampling (the grammar has only one way to go on).
    case forcedSequence([Int32])
    /// Bit `i` of word `i / 64` set means token `i` is allowed.
    case allowed([UInt64])
}

/// How to end a constrained output early, as valid text.
public enum LogitClosing: Sendable, Equatable {
    /// Tokens (possibly none) that complete the value in the fewest bytes.
    case tokens([Int32])
    /// In the middle of a character or an escape: a few more sampled tokens come first.
    case notYet
    /// The constraint cannot close a value early.
    case unsupported
}

/// A grammar that constrains decoding. `nextMask` is asked before every token; `accept` is told which one was chosen.
public protocol LogitConstraint: AnyObject, Sendable {
    func nextMask() -> LogitMask
    func accept(_ token: Int32)
    /// The shortest valid ending from the current state (used when the token limit or the loop guard ends decoding).
    func closing() -> LogitClosing
}

public extension LogitConstraint {
    func closing() -> LogitClosing { .unsupported }
}

public struct DecodingParameters: Sendable, Equatable {
    /// 0 = greedy.
    public var temperature: Float
    public var topK: Int
    public var topP: Float
    public var seed: UInt64

    public init(temperature: Float = 0, topK: Int = 64, topP: Float = 0.95, seed: UInt64 = 0) {
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.seed = seed
    }

    public static let greedy = DecodingParameters()
    /// The model card's settings (temperature 1.0, top-k 64, top-p 0.95).
    public static func card(seed: UInt64) -> DecodingParameters { DecodingParameters(temperature: 1.0, topK: 64, topP: 0.95, seed: seed) }
}

/// SplitMix64: a small, fixed generator, so a seed always gives the same text on every Mac.
struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// Greedy and top-k / top-p sampling over the logits of one position, in the order of the model's generation config and of
/// Hugging Face transformers (temperature, then top-k, then top-p over the k survivors; the model card follows it). mlx-lm
/// applies top-p to the untempered distribution first, so at a temperature other than 1 its support can differ slightly; at the
/// card's temperature of 1.0 top-p keeps the same tokens in both orders (a test pins this down on fixed logits).
struct Sampler {
    let params: DecodingParameters
    var rng: SplitMix64
    private let vocab: Int
    /// The additive mask, reused from step to step: only the entries that changed are written.
    private var maskValues: [Float]
    private var maskAllowed: [Int] = []

    init(params: DecodingParameters, vocab: Int) {
        self.params = params
        self.vocab = vocab
        rng = SplitMix64(state: params.seed &+ 0x1234_5678)
        maskValues = [Float](repeating: -.infinity, count: vocab)
    }

    /// The additive mask [vocab] (0 or -inf) for a set of allowed tokens.
    mutating func additiveMask(_ bits: [UInt64]) -> MLXArray {
        for id in maskAllowed { maskValues[id] = -.infinity }
        maskAllowed.removeAll(keepingCapacity: true)
        for w in 0..<bits.count where bits[w] != 0 {
            var word = bits[w]
            while word != 0 {
                let id = w * 64 + word.trailingZeroBitCount
                if id < vocab { maskValues[id] = 0; maskAllowed.append(id) }
                word &= word - 1
            }
        }
        return MLXArray(maskValues)
    }

    /// The tokens that can be sampled from the `k` best logits `values` (descending, with their ids) and their probabilities: the
    /// softmax at the temperature, cut to the smallest prefix whose mass reaches top-p. nil when no candidate is finite.
    static func candidates(ids: [Int32], values v: [Float], params: DecodingParameters) -> (ids: [Int32], probs: [Double])? {
        guard let maxV = v.first else { return nil }
        // -inf (masked) ones get zero.
        var probs = v.map { $0 == -.infinity ? 0 : Double(exp((($0 - maxV) / params.temperature))) }
        let total = probs.reduce(0, +)
        guard total > 0, total.isFinite else { return nil }
        probs = probs.map { $0 / total }
        var keep = probs.count
        if params.topP > 0, params.topP < 1 {
            var cum = 0.0
            for (i, p) in probs.enumerated() {
                cum += p
                if cum >= Double(params.topP) { keep = i + 1; break }
            }
        }
        let kept = probs[0..<keep]
        let s = kept.reduce(0, +)
        return (Array(ids[0..<keep]), kept.map { $0 / s })
    }

    /// Chooses the next token from `logits` [1, 1, vocab] (any float type). nil when no allowed token has a finite logit (an empty
    /// allowed set, or logits that are all NaN or infinite): the caller must end the output, not take a masked token.
    mutating func sample(_ logits: MLXArray, mask: MLXArray?) -> Int32? {
        var l = logits.reshaped([-1]).asType(.float32)
        if let mask { l = l + mask }
        if params.temperature <= 0 || params.topK == 1 {
            let best = argMax(l).item(Int.self)
            let value = l[best].item(Float.self)
            return value.isFinite ? Int32(best) : nil
        }
        let k = max(1, min(params.topK > 0 ? params.topK : vocab, vocab))
        // The k largest logits and their ids, in descending order.
        let part = argPartition(-l, kth: k - 1)[0..<k]
        let vals = l[part]
        let order = argSort(-vals)
        let ids = part[order].asArray(Int32.self)
        let v = vals[order].asArray(Float.self)
        guard let c = Self.candidates(ids: ids, values: v, params: params) else { return nil }
        return Self.pick(c, r: rng.unit())
    }

    /// The candidate whose slice of the cumulative probability holds `r` (0 <= r < 1). If rounding leaves the sum below `r`, the
    /// last candidate that has probability: a masked one (probability 0) is never returned.
    static func pick(_ c: (ids: [Int32], probs: [Double]), r: Double) -> Int32? {
        var acc = 0.0
        for (i, p) in c.probs.enumerated() {
            acc += p
            if r < acc, p > 0 { return c.ids[i] }
        }
        return c.probs.lastIndex { $0 > 0 }.map { c.ids[$0] }
    }
}
