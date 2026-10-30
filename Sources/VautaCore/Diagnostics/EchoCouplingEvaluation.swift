// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The `echo-coupling` evaluation command: what `EchoCoupling` measures over two files, one as the Me channel and one as the
/// Others channel, fed as a recording feeds it: 10 ms energies, a second of each channel in turn, the windows measured as they
/// fill. For public audio: the files are only read, and nothing is kept but the energies of the windows still open.
public enum EchoCouplingEvaluation {
    /// Seconds of each channel fed before the other's.
    static let step = 1.0

    public static func measure(me: URL, others: URL) async throws -> SpeakerEcho {
        let coupling = EchoCoupling()
        let sources = [(Channel.me, try await Source(url: me)), (Channel.others, try await Source(url: others))]
        var at = 0.0
        while true {
            var fed = false
            for (channel, source) in sources {
                guard let energies = try source.next(seconds: step) else { continue }
                coupling.add(channel, capturedAt: at, meanSquares: energies)
                fed = true
            }
            guard fed else { break }
            _ = coupling.summary()
            at += step
        }
        return coupling.summary()
    }

    /// One file as 16 kHz mono, by 10 ms frames: the mean square of each.
    private final class Source {
        private let decoder: AudioFileDecoder
        private let frame: Int
        private var pending: [Float] = []
        private var ended = false

        init(url: URL) async throws {
            decoder = try await AudioFileDecoder(url: url, format: AudioChunkConverter.target)
            frame = Int((AudioChunkConverter.target.sampleRate * EchoCoupling.frame).rounded())
        }

        func next(seconds: Double) throws -> [Float]? {
            let wanted = Int(seconds * AudioChunkConverter.target.sampleRate)
            while pending.count < wanted, !ended {
                if let chunk = try decoder.next() {
                    pending += UnsafeBufferPointer(start: chunk.buffer.floatChannelData![0], count: Int(chunk.buffer.frameLength))
                } else {
                    ended = true
                }
            }
            guard !pending.isEmpty else { return nil }
            let samples = pending.prefix(wanted)
            pending.removeFirst(samples.count)
            return stride(from: samples.startIndex, to: samples.endIndex, by: frame).map { start in
                let part = samples[start..<min(start + frame, samples.endIndex)]
                return part.reduce(0) { $0 + $1 * $1 } / Float(part.count)
            }
        }
    }
}
