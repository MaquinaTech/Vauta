// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AVFoundation
import Foundation
import Testing
@testable import VautaCore

@Suite("Capture: channel health")
struct CaptureHealthTests {
    @Test func lagMonitorRecoversAfterTheBacklogDrains() {
        var lag = LagMonitor(capacity: 1200)
        #expect(lag.dropped(at: 10) == .lagging)
        #expect(lag.dropped(at: 11) == nil)              // already lagging: reported once
        #expect(lag.enqueued(remaining: 1199, at: 13) == nil)   // too soon after the last drop
        #expect(lag.enqueued(remaining: 100, at: 20) == nil)    // still a large backlog
        #expect(lag.enqueued(remaining: 1190, at: 20) == .ok)
        #expect(!lag.isLagging)
        #expect(lag.enqueued(remaining: 1199, at: 21) == nil)   // no repeated .ok
        #expect(lag.dropped(at: 30) == .lagging)         // a new lag is reported again
    }

    @Test func healthyQueueNeverReports() {
        var lag = LagMonitor(capacity: 1200)
        for t in 0..<100 { #expect(lag.enqueued(remaining: 1199, at: Double(t)) == nil) }
    }

    @Test func trackerReportsOnlyChangesOfTheWorstState() {
        var tracker = ChannelHealthTracker()
        #expect(tracker.update(.ok, for: .me, from: .device) == nil)
        #expect(tracker.update(.lagging, for: .me, from: .transcriber) == .lagging)
        #expect(tracker.update(.reconnecting, for: .me, from: .device) == .reconnecting)
        // The transcriber recovering doesn't hide the device problem.
        #expect(tracker.update(.ok, for: .me, from: .transcriber) == nil)
        #expect(tracker.update(.ok, for: .me, from: .device) == .ok)
        // Channels are independent.
        #expect(tracker.update(.reconnecting, for: .others, from: .device) == .reconnecting)
        #expect(tracker.update(.lagging, for: .me, from: .transcriber) == .lagging)
        let lost = ChannelHealth.lost(CaptureError(.systemAudioLost))
        #expect(tracker.update(lost, for: .others, from: .device) == lost)
        let failed = ChannelHealth.failed(CaptureError(.transcriptionStopped, detail: "x"))
        #expect(tracker.update(failed, for: .others, from: .transcriber) == failed)
        #expect(tracker.update(.ok, for: .others, from: .device) == nil)   // still failed
    }

    @Test func messagesExistExceptWhenHealthy() {
        let states: [ChannelHealth] = [.lagging, .reconnecting, .lost(CaptureError(.microphoneLost)),
                                       .failed(CaptureError(.transcriptionStopped, detail: "analyzer"))]
        for channel in Channel.allCases {
            #expect(ChannelHealth.ok.message(for: channel) == nil)
            for state in states { #expect(!(state.message(for: channel) ?? "").isEmpty) }
        }
        #expect(ChannelHealth.reconnecting.message(for: .me) != ChannelHealth.reconnecting.message(for: .others))
        #expect(ChannelHealth.failed(CaptureError(.transcriptionStopped, detail: "analyzer")).message(for: .me)?.contains("analyzer") == true)
    }
}

@Suite("Capture: errors")
struct CaptureErrorTests {
    @Test(arguments: CaptureError.Code.allCases)
    func everyCodeHasALocalizedDescription(code: CaptureError.Code) {
        let error = CaptureError(code, localeIdentifier: "es-ES", channels: [.me])
        #expect(!(error.errorDescription ?? "").isEmpty)
        #expect(error.description.hasPrefix(error.errorDescription ?? "-"))
        // LocalizedError: what SwiftUI alerts and `localizedDescription` show.
        #expect((error as Error).localizedDescription == error.errorDescription)
    }

    @Test func codesAreStable() throws {
        #expect(CaptureError.Code.speechModelMissing.rawValue == "speechModelMissing")
        let data = try JSONEncoder().encode(CaptureError.Code.systemAudioTapFailed)
        #expect(try JSONDecoder().decode(CaptureError.Code.self, from: data) == .systemAudioTapFailed)
    }

    @Test func coreAudioStatusIsTheFailureReason() throws {
        do {
            try check(-50, .systemAudioTapFailed)
            Issue.record("check should throw")
        } catch let error as CaptureError {
            #expect(error.code == .systemAudioTapFailed)
            #expect(error.status == -50)
            #expect(error.failureReason?.contains("-50") == true)
        }
        try check(noErr, .systemAudioTapFailed)
    }

    @Test func languageIsNamedNotCoded() {
        let error = CaptureError(.speechModelMissing, localeIdentifier: "es-ES")
        let name = Locale.current.localizedString(forIdentifier: "es-ES") ?? "es-ES"
        #expect(error.errorDescription?.contains(name) == true)
    }

    @Test func finishFailedListsTheChannels() {
        let error = CaptureError(.finishFailed, channels: [.me, .others])
        #expect(error.errorDescription?.contains(Channel.me.displayName) == true)
        #expect(error.errorDescription?.contains(Channel.others.displayName) == true)
    }
}

@Suite("Capture: system tap helpers")
struct CaptureTapHelperTests {
    @Test func rateCorrectionSnapsToAStandardRate() {
        // Bluetooth HFP: declared 48 kHz, 16 kHz really arriving.
        #expect(SystemAudioTap.correctedRate(measured: 16_040, assumed: 48_000) == 16_000)
        #expect(SystemAudioTap.correctedRate(measured: 23_900, assumed: 48_000) == 24_000)
        #expect(SystemAudioTap.correctedRate(measured: 47_100, assumed: 48_000) == nil)   // within 5 %
        #expect(SystemAudioTap.correctedRate(measured: 44_050, assumed: 44_100) == nil)
        #expect(SystemAudioTap.correctedRate(measured: 1000, assumed: 0) == nil)
    }

    /// The corrections the tap makes on a stream of buffers captured at `real` samples per second (`correctRate`: confirm, take the
    /// new rate, reset the probe). Buffers whose capture time falls in `lost` never arrive.
    private func corrections(declared: Double, real: Double, seconds: Double, lost: [ClosedRange<Double>] = [],
                             frames: Int = 512) -> [(at: Double, rate: Double)] {
        let probe = RateProbe()
        var assumed = declared, made: [(at: Double, rate: Double)] = []
        var t = 0.0
        while t < seconds {
            defer { t += Double(frames) / real }
            guard !lost.contains(where: { $0.contains(t) }), let measured = probe.add(frames: frames, at: 5_000 + t),
                  let corrected = probe.confirm(measured: measured, corrected: SystemAudioTap.correctedRate(measured: measured, assumed: assumed))
            else { continue }
            made.append((t, corrected))
            assumed = corrected
            probe.reset()
        }
        return made
    }

    @Test func theRateIsMeasuredOnTheCaptureTimes() {
        let probe = RateProbe()
        var rates: [Double] = []
        for i in 0..<1_000 { if let r = probe.add(frames: 512, at: 50 + Double(i) * 512 / 48_000) { rates.append(r) } }
        #expect(rates.count == 3 && rates.allSatisfy { abs($0 - 48_000) < 1 }, "\(rates)")
        // A buffer captured earlier than the last one (the clock went back) starts a new window instead of closing one.
        #expect(probe.add(frames: 512, at: 40) == nil && probe.add(frames: 512, at: 40 + 512 / 48_000) == nil)
    }

    /// The probe once timed its windows with the wall clock: a stall of 150 ms in a 3 s window read as 45,600 samples/s and the
    /// tap switched 48 kHz to 44.1 kHz. Stalls that lose audio (one alone, or one in each of two windows in a row), the Mac
    /// sleeping and longer gaps now leave the rate alone.
    @Test func stallsAndGapsNeverCorrectTheRate() {
        let lost: [ClosedRange<Double>] = [4.0...4.15, 7.0...7.4, 11.2...11.6, 19.0...21.0, 30.5...31.1, 40.0...40.3, 46.1...46.25]
        #expect(corrections(declared: 48_000, real: 48_000, seconds: 60, lost: lost).isEmpty)
        #expect(corrections(declared: 44_100, real: 44_100, seconds: 60, lost: lost, frames: 470).isEmpty)
    }

    @Test func aWrongRateIsCorrectedWithinTwoWindows() {
        // Bluetooth HFP (16 or 24 kHz) and a 44.1 kHz device, all while the format says 48 kHz.
        for (real, frames) in [(16_000.0, 160), (24_000.0, 256), (44_100.0, 512)] {
            let made = corrections(declared: 48_000, real: real, seconds: 30, frames: frames)
            #expect(made.count == 1 && made.first?.rate == real, "\(real): \(made)")
            #expect((made.first?.at ?? .infinity) <= 2 * RateProbe.window + 0.1, "\(real): \(made)")
        }
    }

    @Test func tapStreamIsFoundAfterTheClockDeviceInputs() {
        // Single stream: always it.
        #expect(TapStream.index(channelCounts: [1], hasData: [true], preferred: 0, tapChannels: 1) == 0)
        // Headset mic (1 ch) + tap (1 ch): the tap is the last stream.
        #expect(TapStream.index(channelCounts: [1, 1], hasData: [true, true], preferred: 1, tapChannels: 1) == 1)
        // Stereo interface input + tap.
        #expect(TapStream.index(channelCounts: [2, 1], hasData: [true, true], preferred: 1, tapChannels: 1) == 1)
        // Preferred index out of range or not matching: the last fitting stream.
        #expect(TapStream.index(channelCounts: [1, 2], hasData: [true, true], preferred: 5, tapChannels: 1) == 0)
        // Disabled streams (no data) are skipped.
        #expect(TapStream.index(channelCounts: [1, 1], hasData: [true, false], preferred: 1, tapChannels: 1) == 0)
        #expect(TapStream.index(channelCounts: [2, 2], hasData: [true, true], preferred: 1, tapChannels: 1) == nil)
        // Layout unknown: never the first (clock device) stream when a later one fits.
        #expect(TapStream.index(channelCounts: [1, 1], hasData: [true, true], preferred: nil, tapChannels: 1) == 1)
    }

    @Test func tapStreamPassesASingleBufferThrough() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        buffer.frameLength = 64
        let stream = TapStream(preferredIndex: 0)
        #expect(stream.list(from: buffer.audioBufferList, channels: 1) == buffer.audioBufferList)
    }

    @Test func tapStreamExtractsTheTapBuffer() throws {
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { list.unsafeMutablePointer.deallocate() }
        var mic = [Float](repeating: 0.1, count: 8), tap = [Float](repeating: 0.9, count: 8)
        mic.withUnsafeMutableBytes { m in
            tap.withUnsafeMutableBytes { t in
                list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 32, mData: m.baseAddress)
                list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 32, mData: t.baseAddress)
                let stream = TapStream(preferredIndex: 1)
                let picked = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: stream.list(from: list.unsafePointer, channels: 1)!))
                #expect(picked.count == 1)
                #expect(picked[0].mData == t.baseAddress)
            }
        }
    }
}

@Suite("Capture: microphone downmix")
struct CaptureDownmixTests {
    private func buffer(channels: AVAudioChannelCount, interleaved: Bool, frames: Int, _ value: (Int, Int) -> Float) throws -> AVAudioPCMBuffer {
        // More than two channels need an explicit layout (an audio interface's discrete inputs).
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: interleaved, channelLayout: layout)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try #require(buffer.floatChannelData)
        for f in 0..<frames {
            for c in 0..<Int(channels) {
                if interleaved { data[0][f * Int(channels) + c] = value(f, c) } else { data[c][f] = value(f, c) }
            }
        }
        return buffer
    }

    @Test(arguments: [false, true])
    func averagesAllChannels(interleaved: Bool) throws {
        // A mic on input 2 of 4: the old path (channel 1 only) heard silence.
        let input = try buffer(channels: 4, interleaved: interleaved, frames: 256) { _, c in c == 1 ? 0.8 : 0 }
        let mono = Downmixer().mono(input)
        #expect(mono.format.channelCount == 1)
        #expect(mono.frameLength == 256)
        let samples = try #require(mono.floatChannelData)[0]
        for i in 0..<256 { #expect(abs(samples[i] - 0.2) < 1e-6) }
    }

    @Test func monoPassesThrough() throws {
        let input = try buffer(channels: 1, interleaved: false, frames: 32) { _, _ in 0.5 }
        #expect(Downmixer().mono(input) === input)
    }

    @Test func outputBufferFollowsFrameCountAndRate() throws {
        let downmixer = Downmixer()
        _ = downmixer.mono(try buffer(channels: 2, interleaved: false, frames: 8192) { _, _ in 1 })
        let small = downmixer.mono(try buffer(channels: 2, interleaved: false, frames: 10) { f, c in c == 0 ? Float(f) : 0 })
        #expect(small.frameLength == 10)
        #expect(small.floatChannelData![0][4] == 2)
    }

    @Test func resamplerMixesChannelsItCannotKeep() throws {
        // Non-float multi-channel input bypasses Downmixer; the converter must mix, not drop.
        let stereo = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true))
        let target = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        var scratch: [Float] = []
        let sine = try #require(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 4800))
        sine.frameLength = 4800
        let s = try #require(sine.int16ChannelData)[0]
        for f in 0..<4800 { s[2 * f] = 0; s[2 * f + 1] = Int16(12000 * sin(Double(f) * 2 * .pi * 440 / 48_000)) }
        let resampler = try #require(Resampler(from: stereo, to: target))
        let mixed = try #require(resampler.convert(sine))
        #expect(meanSquare(mixed, scratch: &scratch) > 1e-4)   // channel 2 is heard
    }
}
