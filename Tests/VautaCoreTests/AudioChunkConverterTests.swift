// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AVFoundation
import Testing
@testable import VautaCore

@Suite("Diarization: 16-bit chunks become the same Float samples")
struct AudioChunkConverterTests {
    /// The direct 16 kHz Int16 path is vectorized; every possible sample must come out exactly as `Float(x) / 32768`.
    @Test func everyInt16SampleConvertsExactly() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(SegmentationGeometry.sampleRate),
                                                channels: 1, interleaved: false))
        let all = Array(Int16.min...Int16.max)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(all.count)))
        buffer.frameLength = AVAudioFrameCount(all.count)
        let data = try #require(buffer.int16ChannelData)
        all.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: all.count) }
        let converter = try #require(AudioChunkConverter(format))
        let samples = try #require(converter.samples(buffer))
        #expect(samples.count == all.count)
        #expect(samples.elementsEqual(all.map { Float($0) / 32768 }) { $0.bitPattern == $1.bitPattern })
    }
}
