// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AVFoundation
import Testing
@testable import VautaCore

/// `EchoCoupling` on simulated calls (10 ms energies, no audio): the microphone hears the others over speakers, at the
/// lag they come back with, and never over headphones, whoever talks more.
@Suite("Capture: whether the microphone hears the speakers")
struct EchoCouplingTests {
    /// A call at 10 ms frames: turns of speech of 0.5–3 s with gaps between syllables, the others talking `othersShare` of
    /// the turns and the user the rest.
    private struct Call {
        var others: [Float]
        var user: [Float]

        init(seconds: Int, othersShare: Double = 0.7, seed: UInt64) {
            var rng = EchoEvaluation.Generator(seed: seed)
            let n = seconds * 100
            others = [Float](repeating: 1e-9, count: n)
            user = [Float](repeating: 0, count: n)
            var i = 0
            while i < n {
                let othersTurn = rng.chance(othersShare)
                let length = 50 + rng.index(250)
                for k in i..<min(n, i + length) where rng.chance(0.75) {
                    let level = Float(pow(10, (-22 + (rng.unit() * 2 - 1) * 8) / 10))
                    if othersTurn { others[k] = level } else { user[k] = level }
                }
                i += length + rng.index(40)
            }
        }

        /// What the microphone hears: its noise floor, the user and, over speakers, the others `delay` frames later at `gain` dB.
        func microphone(speakers delay: Int? = nil, gain: Double = -20, noise: Float = 1e-7) -> [Float] {
            user.indices.map { k in
                var ms = noise * Float(1 + 0.1 * sin(Double(k) / 37)) + user[k]
                if let delay, k >= delay { ms += others[k - delay] * Float(pow(10, gain / 10)) }
                return ms
            }
        }
    }

    /// Both channels in 100 ms chunks, as the pipes hand them over, measured every second as the panel's clock does.
    private func measure(others: [Float], me: [Float]) -> SpeakerEcho {
        let coupling = EchoCoupling()
        for start in stride(from: 0, to: others.count, by: 10) {
            let t = Double(start) * EchoCoupling.frame
            coupling.add(.others, capturedAt: t, meanSquares: Array(others[start..<min(others.count, start + 10)]))
            coupling.add(.me, capturedAt: t, meanSquares: Array(me[start..<min(me.count, start + 10)]))
            if start % 100 == 0 { _ = coupling.summary() }
        }
        return coupling.summary()
    }

    @Test func overSpeakersTheMicrophoneHearsTheOthersAtTheirLag() {
        let call = Call(seconds: 180, seed: 1)
        let room = measure(others: call.others, me: call.microphone(speakers: 3))
        #expect(room.windows >= 12 && room.heard * 10 >= room.windows * 9, "\(room)")
        #expect(room.delay == 0.03 && !room.neverHeard && room.heardLately)
        // Bluetooth comes back later, and quieter speakers are still heard.
        let bluetooth = measure(others: call.others, me: call.microphone(speakers: 30, gain: -30))
        #expect(bluetooth.heard * 10 >= bluetooth.windows * 9 && bluetooth.delay == 0.3, "\(bluetooth)")
    }

    @Test func overHeadphonesItNeverDoes() {
        for seed: UInt64 in 1...5 {
            let call = Call(seconds: 180, seed: seed)
            let s = measure(others: call.others, me: call.microphone())
            #expect(s.windows >= 12 && s.heard == 0 && s.neverHeard && !s.heardLately, "seed \(seed): \(s)")
        }
    }

    /// The user's own turns don't hide the echo: in a call the user leads, the others' turns still tell.
    @Test func theUserTalkingMostDoesNotHideIt() {
        let call = Call(seconds: 300, othersShare: 0.35, seed: 3)
        let speakers = measure(others: call.others, me: call.microphone(speakers: 5))
        #expect(speakers.windows >= 6 && speakers.heard * 10 >= speakers.windows * 8, "\(speakers)")
        let headphones = measure(others: call.others, me: call.microphone())
        #expect(headphones.heard == 0, "\(headphones)")
    }

    /// Speakers, then headphones: the meeting was heard, but not lately.
    @Test func switchingToHeadphonesIsSeenWithinAMinute() {
        let call = Call(seconds: 240, seed: 6)
        let speakers = call.microphone(speakers: 3), headphones = call.microphone()
        let s = measure(others: call.others, me: Array(speakers.prefix(12_000) + headphones.dropFirst(12_000)))
        #expect(s.heard >= 6 && !s.neverHeard && !s.heardLately, "\(s)")
    }

    @Test func withoutTheOthersSpeakingNothingIsDecided() {
        let call = Call(seconds: 120, othersShare: 0, seed: 4)
        let s = measure(others: call.others, me: call.microphone(speakers: 3))
        #expect(s.windows == 0 && !s.neverHeard)
    }

    @Test func aMutedMicrophoneHearsNothing() {
        let call = Call(seconds: 120, seed: 5)
        let s = measure(others: call.others, me: [Float](repeating: 0, count: call.others.count))
        #expect(s.windows >= 6 && s.heard == 0)
    }

    /// The pipes' 100 ms chunks become ten 10 ms energies, in either analyzer format.
    @Test func aChunkIsMeasuredBy10Milliseconds() throws {
        for common in [AVAudioCommonFormat.pcmFormatInt16, .pcmFormatFloat32] {
            let format = try #require(AVAudioFormat(commonFormat: common, sampleRate: 16_000, channels: 1, interleaved: false))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
            buffer.frameLength = 1_600
            // Silence, then a half-scale square wave from the sixth frame on.
            for i in 0..<1_600 {
                let v: Float = i < 800 ? 0 : (i % 2 == 0 ? 0.5 : -0.5)
                if let p = buffer.int16ChannelData?[0] { p[i] = Int16(v * 32767) } else { buffer.floatChannelData![0][i] = v }
            }
            var scratch: [Float] = []
            let frames = frameMeanSquares(buffer, frame: 160, scratch: &scratch)
            #expect(frames.count == 10)
            #expect(frames.prefix(5).allSatisfy { $0 == 0 } && frames.suffix(5).allSatisfy { abs($0 - 0.25) < 0.001 }, "\(common): \(frames)")
        }
    }

    /// No system audio at all, and nobody measuring: the microphone's frames are not kept beyond a minute.
    @Test func oneChannelAloneKeepsLittle() {
        let coupling = EchoCoupling()
        for second in 0..<600 {
            for tenth in 0..<10 {
                coupling.add(.me, capturedAt: Double(second) + Double(tenth) / 10, meanSquares: [Float](repeating: 1e-5, count: 10))
            }
        }
        #expect(coupling.summary().windows == 0)
        #expect(coupling.storedFrames <= 6 * EchoCoupling.windowFrames)
    }
}
