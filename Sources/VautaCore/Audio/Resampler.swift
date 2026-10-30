// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Accelerate
import AVFoundation

/// Converts capture buffers (e.g. 48 kHz Float32) to the format SpeechAnalyzer
/// asks for (e.g. 16 kHz mono Int16). The output buffer is reused between
/// calls: callers copy what they need before the next conversion.
final class Resampler {
    private let converter: AVAudioConverter
    private let output: AVAudioFormat
    private var out: AVAudioPCMBuffer?

    init?(from input: AVAudioFormat, to output: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
        // Mix the channels instead of keeping only the first one.
        if input.channelCount > output.channelCount { converter.downmix = true }
        self.converter = converter
        self.output = output
    }

    /// Returns the internal buffer (valid until the next call).
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        if out == nil || out!.frameCapacity < capacity {
            out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: max(capacity, 4096))
        }
        guard let out else { return nil }
        out.frameLength = 0
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }
}

/// Averages the channels of a multi-channel Float32 buffer into mono, so a
/// microphone wired to any input of an audio interface is heard. Other
/// buffers pass through unchanged (the resampler then mixes them). The output
/// buffer is reused: it is valid until the next call. Not thread-safe; each
/// capture callback owns one.
final class Downmixer: @unchecked Sendable {
    private var out: AVAudioPCMBuffer?

    func mono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let format = buffer.format
        let channels = Int(format.channelCount)
        guard channels > 1, format.commonFormat == .pcmFormatFloat32, let src = buffer.floatChannelData else { return buffer }
        if out == nil || out!.format.sampleRate != format.sampleRate || out!.frameCapacity < buffer.frameLength {
            guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
                  let fresh = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: max(buffer.frameLength, 4096)) else { return buffer }
            out = fresh
        }
        guard let out, let dst = out.floatChannelData?[0] else { return buffer }
        let n = vDSP_Length(buffer.frameLength)
        vDSP_vclr(dst, 1, n)
        for c in 0..<channels {
            // Interleaved: one pointer, samples `channels` apart.
            if format.isInterleaved {
                vDSP_vadd(src[0] + c, vDSP_Stride(channels), dst, 1, dst, 1, n)
            } else {
                vDSP_vadd(src[c], 1, dst, 1, dst, 1, n)
            }
        }
        var scale = 1 / Float(channels)
        vDSP_vsmul(dst, 1, &scale, dst, 1, n)
        out.frameLength = buffer.frameLength
        return out
    }
}

/// Mean energy (RMS², 0…1) of a mono Int16 or Float32 buffer, with vDSP.
/// `scratch` is reused between calls of the same channel.
func meanSquare(_ buffer: AVAudioPCMBuffer, scratch: inout [Float]) -> Float {
    let n = Int(buffer.frameLength)
    guard n > 0 else { return 0 }
    var ms: Float = 0
    if let samples = buffer.int16ChannelData?[0] {
        if scratch.count < n { scratch = [Float](repeating: 0, count: n) }
        vDSP_vflt16(samples, 1, &scratch, 1, vDSP_Length(n))
        vDSP_measqv(scratch, 1, &ms, vDSP_Length(n))
        return ms / (32767 * 32767)
    }
    if let samples = buffer.floatChannelData?[0] {
        vDSP_measqv(samples, 1, &ms, vDSP_Length(n))
        return ms
    }
    return 0
}

/// The mean energy of each `frame` samples of a mono Int16 or Float32 buffer (the last may be shorter), with vDSP.
func frameMeanSquares(_ buffer: AVAudioPCMBuffer, frame: Int, scratch: inout [Float]) -> [Float] {
    let n = Int(buffer.frameLength)
    guard n > 0, frame > 0 else { return [] }
    func measure(_ samples: UnsafePointer<Float>, scale: Float) -> [Float] {
        stride(from: 0, to: n, by: frame).map { start in
            var ms: Float = 0
            vDSP_measqv(samples + start, 1, &ms, vDSP_Length(min(frame, n - start)))
            return ms * scale
        }
    }
    if let samples = buffer.int16ChannelData?[0] {
        if scratch.count < n { scratch = [Float](repeating: 0, count: n) }
        vDSP_vflt16(samples, 1, &scratch, 1, vDSP_Length(n))
        return scratch.withUnsafeBufferPointer { measure($0.baseAddress!, scale: 1 / (32767 * 32767)) }
    }
    if let samples = buffer.floatChannelData?[0] { return measure(samples, scale: 1) }
    return []
}
