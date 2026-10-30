// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AVFoundation
import Foundation
import Testing
@testable import VautaCore

/// `echo-coupling` over two files measures what a recording's two channels would: synthetic speech-like noise, written to a
/// temporary folder (no microphone involved).
@Suite("Evaluation: whether the microphone heard the others, over two files")
struct EchoCouplingEvaluationTests {
    static let rate = 16_000.0

    /// Turns of noise shaped like speech at 10 ms frames, the others talking 70 % of the turns: (others, user) mean squares.
    static func turns(seconds: Int, seed: UInt64) -> (others: [Float], user: [Float]) {
        var rng = EchoEvaluation.Generator(seed: seed)
        let n = seconds * 100
        var others = [Float](repeating: 1e-9, count: n), user = [Float](repeating: 1e-9, count: n)
        var i = 0
        while i < n {
            let othersTurn = rng.chance(0.7)
            let length = 50 + rng.index(250)
            for k in i..<min(n, i + length) where rng.chance(0.75) {
                let level = Float(pow(10, (-22 + (rng.unit() * 2 - 1) * 8) / 10))
                if othersTurn { others[k] = level } else { user[k] = level }
            }
            i += length + rng.index(40)
        }
        return (others, user)
    }

    /// 16 kHz mono float samples whose 10 ms frames have the given mean squares.
    static func samples(_ frames: [Float], seed: UInt64) -> [Float] {
        var rng = EchoEvaluation.Generator(seed: seed)
        return frames.flatMap { ms in (0..<160).map { _ in Float(rng.unit() * 2 - 1) * (3 * ms).squareRoot() } }
    }

    static func write(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }

    @Test func overSpeakersItHearsTheOthersAtTheirDelayAndOverHeadphonesItNeverDoes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let call = Self.turns(seconds: 120, seed: 7)
        let others = Self.samples(call.others, seed: 1), user = Self.samples(call.user, seed: 2)
        let lag = Int(0.2 * Self.rate)
        // Speakers: the others come back 20 dB lower and 200 ms later, over the user's own voice.
        let speakers = user.indices.map { i in user[i] + (i >= lag ? 0.1 * others[i - lag] : 0) }
        let urls = ["others", "speakers", "headphones"].map { dir.appendingPathComponent("\($0).wav") }
        for (samples, url) in zip([others, speakers, user], urls) { try Self.write(samples, to: url) }

        let heard = try await EchoCouplingEvaluation.measure(me: urls[1], others: urls[0])
        #expect(heard.windows >= 9 && heard.heard * 10 >= heard.windows * 9, "\(heard)")
        #expect(abs((heard.delay ?? 0) - 0.2) <= 0.02 && !heard.neverHeard && heard.heardLately, "\(heard)")
        let never = try await EchoCouplingEvaluation.measure(me: urls[2], others: urls[0])
        #expect(never.windows >= 9 && never.neverHeard && !never.heardLately, "\(never)")
    }
}
