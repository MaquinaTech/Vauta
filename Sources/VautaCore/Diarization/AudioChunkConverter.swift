// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AVFoundation

/// Turns audio chunks of any PCM format into 16 kHz mono Float samples for the diarizer. Memory only.
/// A chunk that is already 16 kHz mono (what the speech analyzer asks for) is copied straight; anything else goes
/// through one `AVAudioConverter` (the channels are mixed down). Not thread-safe: one owner.
final class AudioChunkConverter {
    static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(SegmentationGeometry.sampleRate),
                                      channels: 1, interleaved: false)!

    private let format: AVAudioFormat
    private let converter: AVAudioConverter?
    private var output: AVAudioPCMBuffer?

    init?(_ format: AVAudioFormat) {
        self.format = format
        if Self.isDirect(format) {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: format, to: Self.target) else { return nil }
            if format.channelCount > 1 { converter.downmix = true }
            self.converter = converter
        }
    }

    func accepts(_ other: AVAudioFormat) -> Bool { other == format }

    private static func isDirect(_ format: AVAudioFormat) -> Bool {
        format.sampleRate == Double(SegmentationGeometry.sampleRate) && format.channelCount == 1
            && (format.commonFormat == .pcmFormatFloat32 || format.commonFormat == .pcmFormatInt16)
    }

    func samples(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return [] }
        if converter == nil {
            switch buffer.format.commonFormat {
            case .pcmFormatFloat32:
                guard let data = buffer.floatChannelData else { return nil }
                return Array(UnsafeBufferPointer(start: data[0], count: frames))
            default:
                guard let data = buffer.int16ChannelData else { return nil }
                return UnsafeBufferPointer(start: data[0], count: frames).map { Float($0) / 32768 }
            }
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(frames) * Self.target.sampleRate / buffer.format.sampleRate) + 64
        if output == nil || output!.frameCapacity < capacity { output = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: max(capacity, 4096)) }
        guard let output else { return nil }
        output.frameLength = 0
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let data = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
}
