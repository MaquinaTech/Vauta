// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CoreML
import Foundation

/// Powerset decoding for the 3-local-speaker, at-most-2-simultaneous segmentation model.
/// Class order (pyannote): none, {0}, {1}, {2}, {0,1}, {0,2}, {1,2}.
enum Powerset {
    static let classes = 7
    /// Bit mask of the active local speakers of each class.
    static let speakerMask: [UInt8] = [0b000, 0b001, 0b010, 0b100, 0b011, 0b101, 0b110]
    static let activeCount: [Int] = speakerMask.map { $0.nonzeroBitCount }

    /// Numerically stable log-softmax over the 7 classes of every frame, in Float. (Done here and not in the
    /// model: log-softmax underflows in FP16 on the Neural Engine.)
    static func logSoftmax(_ logits: [Float], frames: Int) -> [Float] {
        var out = logits
        for t in 0..<frames {
            let base = t * classes
            var peak = logits[base]
            for c in 1..<classes where logits[base + c] > peak { peak = logits[base + c] }
            var sum: Float = 0
            for c in 0..<classes { sum += expf(logits[base + c] - peak) }
            let shift = peak + logf(sum)
            for c in 0..<classes { out[base + c] = logits[base + c] - shift }
        }
        return out
    }

    /// Hard decode: the most likely class of every frame of a [frames x 7] score array.
    static func argmaxClasses(_ scores: [Float], frames: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: frames)
        for t in 0..<frames {
            var best = 0
            var bestValue = scores[t * classes]
            for c in 1..<classes where scores[t * classes + c] > bestValue { bestValue = scores[t * classes + c]; best = c }
            out[t] = UInt8(best)
        }
        return out
    }
}

extension MLMultiArray {
    /// Stride-aware copy into a dense row-major Float array (the Neural Engine pads the last dimension).
    func denseFloats() -> [Float] {
        let shape = self.shape.map(\.intValue), strides = self.strides.map(\.intValue)
        let count = shape.reduce(1, *)
        var out = [Float](repeating: 0, count: count)
        var contiguous = true
        var expected = 1
        for d in stride(from: shape.count - 1, through: 0, by: -1) {
            if strides[d] != expected { contiguous = false }
            expected *= shape[d]
        }
        func copy<T: BinaryFloatingPoint>(_ p: UnsafePointer<T>) {
            if contiguous {
                for i in 0..<count { out[i] = Float(p[i]) }
                return
            }
            var index = [Int](repeating: 0, count: shape.count)
            for i in 0..<count {
                var offset = 0
                for d in 0..<shape.count { offset += index[d] * strides[d] }
                out[i] = Float(p[offset])
                var d = shape.count - 1
                while d >= 0 {
                    index[d] += 1
                    if index[d] < shape[d] { break }
                    index[d] = 0
                    d -= 1
                }
            }
        }
        switch dataType {
        case .float32: copy(dataPointer.assumingMemoryBound(to: Float.self))
        case .float16: copy(dataPointer.assumingMemoryBound(to: Float16.self))
        case .double: copy(dataPointer.assumingMemoryBound(to: Double.self))
        default: break
        }
        return out
    }
}

/// The segmentation network: 10 s of 16 kHz mono audio in, 589 frames of 7 powerset scores out.
/// Use one instance from one queue at a time; Core ML itself serialises predictions.
public final class Segmenter: @unchecked Sendable {
    private let model: MLModel

    init(model: MLModel) {
        self.model = model
    }

    /// Log-probabilities `[589 x 7]` row-major for one window of exactly `windowSamples` samples.
    func logProbabilities(window: [Float]) throws -> [Float] {
        precondition(window.count == SegmentationGeometry.windowSamples, "a segmentation window is exactly 10 s")
        let logits: [Float] = try autoreleasepool {
            let input = try MLMultiArray(shape: [1, 1, NSNumber(value: SegmentationGeometry.windowSamples)], dataType: .float32)
            window.withUnsafeBufferPointer { src in
                input.dataPointer.copyMemory(from: src.baseAddress!, byteCount: src.count * MemoryLayout<Float>.size)
            }
            let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": input]))
            guard let array = out.featureValue(for: "logits")?.multiArrayValue else {
                throw DiarizationModels.Failure.badOutput("logits")
            }
            return array.denseFloats()
        }
        guard logits.count == SegmentationGeometry.frames * Powerset.classes else {
            throw DiarizationModels.Failure.badOutput("logits")
        }
        return Powerset.logSoftmax(logits, frames: SegmentationGeometry.frames)
    }

    /// The powerset class of each of the 589 frames (0...6).
    public func classes(window: [Float]) throws -> [UInt8] {
        Powerset.argmaxClasses(try logProbabilities(window: window), frames: SegmentationGeometry.frames)
    }
}
