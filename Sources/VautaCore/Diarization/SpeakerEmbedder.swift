// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CoreML
import Foundation

/// The per-local-speaker frame masks fed to the embedding model, built from the segmentation of one window.
enum MaskBuilder {
    /// Three masks of 589 values (0 or 1) and the seconds of usable speech behind each.
    ///
    /// With `excludeOverlap`, frames shared with another speaker are dropped from a speaker's mask, unless that
    /// leaves less than `minSeconds` of speech: then all of the speaker's active frames are used (pyannote's
    /// fallback), so a speaker who is mostly interrupted still gets an embedding.
    static func masks(classes: [UInt8], excludeOverlap: Bool, minSeconds: Double) -> (masks: [[Float]], seconds: [Float]) {
        let frames = SegmentationGeometry.frames, speakers = SegmentationGeometry.localSpeakers
        var active = [[Float]](repeating: [Float](repeating: 0, count: frames), count: speakers)
        var alone = active
        for t in 0..<frames {
            let c = Int(classes[t])
            let mask = Powerset.speakerMask[c]
            let isAlone = Powerset.activeCount[c] == 1
            for s in 0..<speakers where mask & (1 << s) != 0 {
                active[s][t] = 1
                if isAlone { alone[s][t] = 1 }
            }
        }
        let step = Float(SegmentationGeometry.frameStepSeconds)
        var masks: [[Float]] = [], seconds: [Float] = []
        for s in 0..<speakers {
            let activeFrames = active[s].reduce(0, +), aloneFrames = alone[s].reduce(0, +)
            if excludeOverlap && Double(aloneFrames * step) >= minSeconds {
                masks.append(alone[s])
                seconds.append(aloneFrames * step)
            } else {
                masks.append(active[s])
                seconds.append(activeFrames * step)
            }
        }
        return (masks, seconds)
    }
}

/// The WeSpeaker ResNet34-LM speaker embedding network (masked statistics pooling inside the model):
/// the window's Kaldi fbank `[998 x 80]` and three `[589]` masks in, three 256-d embeddings out.
/// Use one instance from one queue at a time.
public final class SpeakerEmbedder: @unchecked Sendable {
    public static let dimension = SegmentationGeometry.embeddingDimension
    private let model: MLModel

    init(model: MLModel) {
        self.model = model
    }

    /// Raw (not normalised) embeddings, one per mask. A mask with no weight gives a zero-statistics embedding
    /// that the caller must not use.
    func embed(fbank: [Float], masks: [[Float]]) throws -> [[Float]] {
        let frames = SegmentationGeometry.fbankFrames, bins = Fbank.melBins
        let speakers = SegmentationGeometry.localSpeakers, maskFrames = SegmentationGeometry.frames
        precondition(fbank.count == frames * bins && masks.count == speakers, "wrong embedding input shape")
        let raw: [Float] = try autoreleasepool {
            let features = try MLMultiArray(shape: [1, NSNumber(value: frames), NSNumber(value: bins)], dataType: .float32)
            fbank.withUnsafeBufferPointer { src in
                features.dataPointer.copyMemory(from: src.baseAddress!, byteCount: src.count * MemoryLayout<Float>.size)
            }
            let weights = try MLMultiArray(shape: [NSNumber(value: speakers), NSNumber(value: maskFrames)], dataType: .float32)
            let target = weights.dataPointer.assumingMemoryBound(to: Float.self)
            for s in 0..<speakers { for t in 0..<maskFrames { target[s * maskFrames + t] = masks[s][t] } }
            let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["fbank": features, "masks": weights]))
            guard let array = out.featureValue(for: "embeddings")?.multiArrayValue else {
                throw DiarizationModels.Failure.badOutput("embeddings")
            }
            return array.denseFloats()
        }
        guard raw.count == speakers * Self.dimension else { throw DiarizationModels.Failure.badOutput("embeddings") }
        return (0..<speakers).map { Array(raw[($0 * Self.dimension)..<(($0 + 1) * Self.dimension)]) }
    }
}
