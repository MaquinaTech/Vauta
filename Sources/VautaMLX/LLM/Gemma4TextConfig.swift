// SPDX-License-Identifier: Apache-2.0 AND MIT
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
// Portions derived from mlx-lm (https://github.com/ml-explore/mlx-lm, v0.32.0, MIT), Copyright © 2023-2025 Apple Inc.

import Foundation

/// The text tower of `google/gemma-4-E4B-it` at revision ee0ef602, pinned (the values of its `config.json`, `text_config`).
/// The model is not configurable: these are constants, so a different checkpoint cannot be loaded by accident.
public struct Gemma4TextConfig: Sendable, Equatable {
    public var hiddenSize = 2560
    public var layers = 42
    public var heads = 8
    public var kvHeads = 2
    public var slidingHeadDim = 256
    public var fullHeadDim = 512
    public var intermediate = 10240
    public var vocab = 262_144
    public var pleDim = 256
    public var slidingWindow = 512
    public var firstSharedLayer = 24
    public var eps: Float = 1e-6
    public var softcap: Float = 30
    public var slidingRopeBase: Float = 10_000
    public var fullRopeBase: Float = 1_000_000
    /// 0.25 of the 512-dimension head is rotated (proportional RoPE).
    public var fullRotatedDims = 128
    public var groupSize = 64
    public var bits = 4
    /// The full-attention layers (every sixth, from the sixth).
    public var fullLayers: Set<Int> = [5, 11, 17, 23, 29, 35, 41]
    public var stopIDs: Set<Int32> = [1, 106, 50]
    public var bosID: Int32 = 2

    public init() {}

    public static let pinned = Gemma4TextConfig()

    /// A tiny configuration for tests (9 layers, 3 of them sharing keys and values, a window of 16).
    public static let tiny: Gemma4TextConfig = {
        var c = Gemma4TextConfig()
        c.hiddenSize = 128; c.layers = 9; c.heads = 4; c.kvHeads = 2; c.slidingHeadDim = 64; c.fullHeadDim = 128; c.intermediate = 256
        c.vocab = 512; c.pleDim = 64; c.slidingWindow = 16; c.firstSharedLayer = 6; c.fullRotatedDims = 32; c.fullLayers = [2, 5, 8]
        c.stopIDs = [1]
        return c
    }()

    public func isFull(_ layer: Int) -> Bool { fullLayers.contains(layer) }
    public func headDim(_ layer: Int) -> Int { isFull(layer) ? fullHeadDim : slidingHeadDim }
    public func ownsKV(_ layer: Int) -> Bool { layer < firstSharedLayer }

    /// The layer whose keys and values layer `layer` reads: itself, or the last owner of the same attention type.
    public func kvSource(_ layer: Int) -> Int {
        guard !ownsKV(layer) else { return layer }
        var last = 0
        for i in 0..<firstSharedLayer where isFull(i) == isFull(layer) { last = i }
        return last
    }

    /// Layers that own a cache, in order.
    public var cacheOwners: [Int] { Array(0..<firstSharedLayer) }
}
