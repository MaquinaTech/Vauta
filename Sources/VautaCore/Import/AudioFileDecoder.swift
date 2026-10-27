// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AVFoundation
import CoreMedia

/// Reads the audio of any file AVFoundation opens (audio or video; every
/// audio track mixed) as PCM buffers in a given format, one chunk at a time.
/// Pull-based: nothing is decoded ahead of the reader, so long recordings
/// don't pile up in memory. The audio is never written anywhere.
final class AudioFileDecoder: @unchecked Sendable {
    let format: AVAudioFormat
    /// Length of the file in seconds (0 if unknown).
    let duration: Double

    private let reader: AVAssetReader
    private let output: AVAssetReaderAudioMixOutput
    /// The reader delivers interleaved PCM; a converter changes the layout
    /// when `format` is a non-interleaved multi-channel format.
    private let decodeFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let lock = NSLock()
    private var framesRead: AVAudioFramePosition = 0

    init(url: URL, format: AVAudioFormat) async throws {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        let time: CMTime
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
            time = try await asset.load(.duration)
        } catch {
            throw RecordingImportError(.unreadable, detail: error.localizedDescription)
        }
        guard !tracks.isEmpty else { throw RecordingImportError(.noAudio) }
        guard let decodeFormat = AVAudioFormat(commonFormat: format.commonFormat, sampleRate: format.sampleRate,
                                               channels: format.channelCount, interleaved: true) else {
            throw RecordingImportError(.unreadable, detail: "unsupported analyzer format")
        }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch {
            throw RecordingImportError(.unreadable, detail: error.localizedDescription)
        }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: Self.settings(for: decodeFormat))
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw RecordingImportError(.unreadable, detail: "cannot read the audio tracks") }
        reader.add(output)
        guard reader.startReading() else {
            throw RecordingImportError(.unreadable, detail: reader.error?.localizedDescription)
        }
        self.format = format
        self.decodeFormat = decodeFormat
        self.converter = decodeFormat.isEqual(format) ? nil : AVAudioConverter(from: decodeFormat, to: format)
        self.reader = reader
        self.output = output
        self.duration = time.seconds.isFinite ? max(0, time.seconds) : 0
    }

    /// Seconds decoded so far.
    var position: Double { lock.withLock { Double(framesRead) / format.sampleRate } }

    /// The next chunk and its first frame, or nil at the end of the file.
    func next() throws -> (buffer: AVAudioPCMBuffer, start: AVAudioFramePosition)? {
        while let sample = output.copyNextSampleBuffer() {
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0, let decoded = AVAudioPCMBuffer(pcmFormat: decodeFormat, frameCapacity: AVAudioFrameCount(frames)) else {
                continue
            }
            decoded.frameLength = AVAudioFrameCount(frames)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                                      into: decoded.mutableAudioBufferList)
            guard status == noErr else { throw RecordingImportError(.unreadable, detail: "OSStatus \(status)") }
            var buffer = decoded
            if let converter {
                guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: decoded.frameLength) else { continue }
                try converter.convert(to: converted, from: decoded)
                buffer = converted
            }
            let start = lock.withLock {
                defer { framesRead += AVAudioFramePosition(buffer.frameLength) }
                return framesRead
            }
            return (buffer, start)
        }
        if reader.status == .failed {
            throw RecordingImportError(.unreadable, detail: reader.error?.localizedDescription)
        }
        return nil
    }

    /// Stops decoding: the next call to `next()` returns nil.
    func cancel() { reader.cancelReading() }

    static func settings(for format: AVAudioFormat) -> [String: Any] {
        let (bits, isFloat): (Int, Bool) = switch format.commonFormat {
        case .pcmFormatInt16: (16, false)
        case .pcmFormatInt32: (32, false)
        case .pcmFormatFloat64: (64, true)
        default: (32, true)
        }
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: bits,
            AVLinearPCMIsFloatKey: isFloat,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }
}
