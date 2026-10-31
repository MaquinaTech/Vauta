// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AVFoundation

/// Converts each buffer to the analyzer format and groups it into ~100 ms
/// chunks before handing it over (the IOProc delivers ~10 ms per call: this
/// makes 10 inputs/s per channel instead of ~94). Memory only; released in
/// stop(). The lock guards against the last in-flight callback during flush().
/// With a `diarizer` (the Others channel), every chunk also goes to it with the transcriber's frame counter.
/// Each chunk carries the time it was captured at (from the buffers' host time, against the session `origin`), so
/// the transcriber keeps the channel on the session's clock across device gaps. With `coupling`, each chunk's loudness by
/// 10 ms goes to it at the same time (whether the microphone hears the speakers). While it is closed (a paused recording,
/// `setAccepting`) nothing goes anywhere.
final class ChannelPipe: @unchecked Sendable {
    private let lock = NSLock()
    private let channel: ChannelTranscriber
    private let diarizer: Diarizer?
    private let levels: LevelMeter
    private let origin: SessionOrigin
    private let coupling: EchoCoupling?
    private let couplingFrames: Int
    private let chunkFrames: AVAudioFrameCount
    private let bytesPerFrame: Int
    private var resampler: Resampler?
    private var inputFormat: AVAudioFormat?
    private var chunk: AVAudioPCMBuffer?
    private var chunkCapturedAt: Double?
    private var scratch: [Float] = []
    private var accepting = true

    init(channel: ChannelTranscriber, levels: LevelMeter, origin: SessionOrigin, coupling: EchoCoupling? = nil, diarizer: Diarizer? = nil) {
        self.channel = channel
        self.diarizer = diarizer
        self.levels = levels
        self.origin = origin
        self.coupling = coupling
        couplingFrames = max(1, Int((channel.analyzerFormat.sampleRate * EchoCoupling.frame).rounded()))
        chunkFrames = AVAudioFrameCount(max(channel.analyzerFormat.sampleRate / 10, 160))
        bytesPerFrame = Int(channel.analyzerFormat.streamDescription.pointee.mBytesPerFrame)
    }

    /// `hostTime`: when the buffer's first frame was captured (host clock ticks), nil when the device didn't say.
    func push(_ buffer: AVAudioPCMBuffer, hostTime: UInt64?) {
        let capturedAt = hostTime.map { origin.offset(ofHostSeconds: HostTime.seconds($0)) }
        lock.withLock {
            guard accepting else { return }
            if resampler == nil || inputFormat != buffer.format {
                emitLocked()   // never mix audio of two input formats in one chunk
                resampler = Resampler(from: buffer.format, to: channel.analyzerFormat)
                inputFormat = buffer.format
            }
            guard let converted = resampler?.convert(buffer),
                  let src = converted.audioBufferList.pointee.mBuffers.mData else { return }
            let total = Int(converted.frameLength)
            var offset = 0
            while offset < total {
                if chunk == nil {
                    chunk = AVAudioPCMBuffer(pcmFormat: channel.analyzerFormat, frameCapacity: chunkFrames)
                    chunkCapturedAt = capturedAt.map { $0 + Double(offset) / channel.analyzerFormat.sampleRate }
                }
                guard let chunk, let dst = chunk.mutableAudioBufferList.pointee.mBuffers.mData else { return }
                let n = min(total - offset, Int(chunk.frameCapacity - chunk.frameLength))
                (dst + Int(chunk.frameLength) * bytesPerFrame)
                    .copyMemory(from: src + offset * bytesPerFrame, byteCount: n * bytesPerFrame)
                chunk.frameLength += AVAudioFrameCount(n)
                offset += n
                if chunk.frameLength == chunk.frameCapacity { emitLocked() }
            }
        }
    }

    func flush() { lock.withLock { emitLocked() } }

    /// Closes or opens the pipe. Closed, a buffer that still arrives is dropped, and the chunk being filled goes to the
    /// transcriber at once (it was captured before). Opened again, the next buffer starts a new conversion: the audio before
    /// the gap is not mixed into the audio after it.
    func setAccepting(_ on: Bool) {
        lock.withLock {
            guard on != accepting else { return }
            if !on { emitLocked() }
            resampler = nil
            inputFormat = nil
            accepting = on
        }
    }

    /// AnalyzerInput keeps the buffer, so every chunk is a new one.
    private func emitLocked() {
        guard let chunk, chunk.frameLength > 0 else { return }
        self.chunk = nil
        chunk.mutableAudioBufferList.pointee.mBuffers.mDataByteSize = UInt32(Int(chunk.frameLength) * bytesPerFrame)
        levels.add(channel.channel, meanSquare(chunk, scratch: &scratch))
        if let coupling, let at = chunkCapturedAt {
            coupling.add(channel.channel, capturedAt: at, meanSquares: frameMeanSquares(chunk, frame: couplingFrames, scratch: &scratch))
        }
        let start = channel.feed(chunk, capturedAt: chunkCapturedAt)
        chunkCapturedAt = nil
        diarizer?.push(chunk, startFrame: start)
    }
}

/// Averages ENERGY (not dB) per channel and returns it in dBFS.
final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var sums: [Channel: (Double, Int)] = [:]

    func add(_ channel: Channel, _ meanSquare: Float) {
        lock.withLock {
            let (s, n) = sums[channel] ?? (0, 0)
            sums[channel] = (s + Double(meanSquare), n + 1)
        }
    }

    func drain() -> [Channel: Double] {
        lock.withLock {
            defer { sums.removeAll(keepingCapacity: true) }
            return sums.mapValues { s, n in
                let m = s / Double(max(n, 1))
                return m > 0 ? 10 * log10(m) : -160
            }
        }
    }
}
