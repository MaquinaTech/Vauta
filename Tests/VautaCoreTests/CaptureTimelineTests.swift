// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The session clock: both channels and the marks share one origin, and a channel's chunks keep to it across device
/// gaps. Host times are synthetic; no audio device is used.
@Suite("Capture: session clock")
struct CaptureTimelineTests {
    private let rate = 16_000.0
    private let chunk: Int64 = 1_600   // 100 ms

    @Test func chunksFollowEachOtherWhileTheCaptureKeepsUp() {
        var timeline = ChannelTimeline(sampleRate: rate)
        // ±30 ms of jitter around the real capture times is not a gap
        let jitter = [0, 0.03, -0.02, 0.01, -0.03, 0.02, 0, 0.03, -0.01, 0]
        for (i, j) in jitter.enumerated() {
            #expect(timeline.place(frames: chunk, capturedAt: max(0, Double(i) * 0.1 + j)) == Int64(i) * chunk)
        }
    }

    @Test func theFirstChunkIsPlacedAtItsCaptureTime() {
        // The system-audio tap starts 0.8 s after the microphone.
        var others = ChannelTimeline(sampleRate: rate)
        #expect(others.place(frames: chunk, capturedAt: 0.8) == 12_800)
        #expect(others.place(frames: chunk, capturedAt: 0.9) == 14_400)
        // Even a small offset is kept for the first chunk.
        var me = ChannelTimeline(sampleRate: rate)
        #expect(me.place(frames: chunk, capturedAt: 0.2) == 3_200)
    }

    @Test func aGapAdvancesThePositionByTheGap() {
        var timeline = ChannelTimeline(sampleRate: rate)
        for i in 0..<10 { _ = timeline.place(frames: chunk, capturedAt: Double(i) * 0.1) }
        // the device was gone for 8 s: the next chunk was captured at 1.0 + 8 s
        #expect(timeline.place(frames: chunk, capturedAt: 9.0) == 144_000)
        #expect(timeline.place(frames: chunk, capturedAt: 9.1) == 145_600)
    }

    @Test func smallDifferencesAreJitterAndTheCounterNeverGoesBackwards() {
        var timeline = ChannelTimeline(sampleRate: rate)
        _ = timeline.place(frames: chunk, capturedAt: 0)
        // 0.4 s ahead is within the tolerance: no jump
        #expect(timeline.place(frames: chunk, capturedAt: 0.5) == 1_600)
        // a capture time behind the counter never moves it back: chunks never overlap
        #expect(timeline.place(frames: chunk, capturedAt: 0) == 3_200)
        #expect(timeline.place(frames: chunk, capturedAt: nil) == 4_800)
        #expect(timeline.position == 6_400)
    }

    @Test func withoutCaptureTimesTheFramesAreCounted() {
        var timeline = ChannelTimeline(sampleRate: rate)
        for i in 0..<5 { #expect(timeline.place(frames: chunk, capturedAt: nil) == Int64(i) * chunk) }
    }

    @Test func bothChannelsShareTheOriginOfTheFirstAudio() {
        let origin = SessionOrigin()
        #expect(origin.elapsed(atHostSeconds: 500) == nil, "no audio yet")
        #expect(origin.offset(ofHostSeconds: 1_000) == 0)   // the microphone's first buffer
        #expect(abs(origin.offset(ofHostSeconds: 1_000.8) - 0.8) < 1e-9)   // the tap's, later
        #expect(origin.offset(ofHostSeconds: 999.99) == 0, "a buffer captured just before the origin is clamped")
        #expect(origin.elapsed(atHostSeconds: 1_010) == 10)
    }

    @Test func hostTimeIsMonotonicSeconds() {
        let a = HostTime.now
        let b = HostTime.now
        #expect(b >= a)
        #expect(HostTime.seconds(0) == 0)
    }

    // MARK: Live re-clustering cadence

    @Test func shortMeetingsKeepTheFixedReclusterInterval() {
        let config = DiarizationConfig()
        for windows in 0..<230 { #expect(config.liveReclusterInterval(windows: windows) == config.liveReclusterWindows) }
    }

    @Test func longMeetingsReclusterLessOftenUpToACap() {
        let config = DiarizationConfig()
        #expect(config.liveReclusterInterval(windows: 300) == 30)
        #expect(config.liveReclusterInterval(windows: 1_000) == 100)
        #expect(config.liveReclusterInterval(windows: 1_800) == 150, "5 minutes at most")
        #expect(config.liveReclusterInterval(windows: 100_000) == 150)
        var previous = 0
        for windows in stride(from: 0, through: 5_000, by: 50) {
            let interval = config.liveReclusterInterval(windows: windows)
            #expect(interval >= previous)
            previous = interval
        }
    }

    @Test func anOfflineConfigurationNeverReclusters() {
        var config = DiarizationConfig()
        config.liveReclusterSeconds = 1e9
        #expect(config.liveReclusterInterval(windows: 10_000) == config.liveReclusterWindows)
    }
}
