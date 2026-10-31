// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AVFoundation
import Foundation
import Testing
@testable import VautaCore

/// A paused recording: no audio reaches the transcriber while the pipe is closed, the time paused stays a gap on the channel's
/// clock, and the pauses are stored with the meeting. Synthetic buffers and host times; no audio device is used.
@Suite("Recording: pause and resume")
struct RecordingPauseTests {
    static let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    /// Host clock ticks for `seconds`, as the devices stamp their buffers.
    static func ticks(_ seconds: Double) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return UInt64(seconds * 1e9 * Double(info.denom) / Double(info.numer))
    }

    static func buffer(frames: AVAudioFrameCount = 1_600) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        return buffer
    }

    @Test func nothingReachesTheTranscriberWhilePausedAndThePauseStaysAGap() async throws {
        let factory = FakeAnalyzerFactory()
        let transcriber = ChannelTranscriber(channel: .me, format: Self.format) { _ in factory.make() }
        transcriber.open { _ in }
        let pipe = ChannelPipe(channel: transcriber, levels: LevelMeter(), origin: SessionOrigin())
        let session = try #require(factory.session(0))
        let base = 1_000.0
        for i in 0..<3 { pipe.push(Self.buffer(), hostTime: Self.ticks(base + Double(i) * 0.1)) }
        // Half a chunk captured before the pause: closing the pipe sends it on, it was said before.
        pipe.push(Self.buffer(frames: 800), hostTime: Self.ticks(base + 0.3))
        let beforePause = session.frames.count
        pipe.setAccepting(false)
        let atPause = session.frames
        #expect(atPause.count == beforePause + 1, "the chunk being filled goes to the transcriber at the pause")
        // Whatever a device still delivers after the pause is dropped.
        for i in 0..<5 { pipe.push(Self.buffer(), hostTime: Self.ticks(base + 0.4 + Double(i) * 0.1)) }
        pipe.flush()
        #expect(session.frames == atPause, "nothing reaches the transcriber while paused")
        // Resumed ten seconds after the start: the time paused stays a gap.
        pipe.setAccepting(true)
        pipe.push(Self.buffer(), hostTime: Self.ticks(base + 10))
        pipe.push(Self.buffer(), hostTime: Self.ticks(base + 10.1))
        let resumed = Array(session.frames.dropFirst(atPause.count))
        #expect(resumed == [160_000, 161_600], "after the pause the channel is back on the session's clock")
        #expect(atPause.allSatisfy { $0 < 8_000 })
        try await transcriber.finish()
    }

    @Test func closingTwiceOrOpeningAnOpenPipeChangesNothing() async throws {
        let factory = FakeAnalyzerFactory()
        let transcriber = ChannelTranscriber(channel: .others, format: Self.format) { _ in factory.make() }
        transcriber.open { _ in }
        let pipe = ChannelPipe(channel: transcriber, levels: LevelMeter(), origin: SessionOrigin())
        let session = try #require(factory.session(0))
        pipe.setAccepting(true)
        pipe.push(Self.buffer(), hostTime: Self.ticks(50))
        pipe.setAccepting(false)
        pipe.setAccepting(false)
        pipe.push(Self.buffer(), hostTime: Self.ticks(50.1))
        #expect(session.frames == [0])
        try await transcriber.finish()
    }

    @Test func thePausesAreStoredWithTheMeetingOneOpenAtATime() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.store.startMeeting(at: .now)
        try await f.store.beginPause(id, at: 63)
        #expect(try await f.store.pauses(of: id) == [MeetingPause(start: 63, end: nil)], "open while it lasts")
        try await f.store.endPause(id, at: 482)
        try await f.store.beginPause(id, at: 900)
        // A second start closes the one still open there: one pause at a time.
        try await f.store.beginPause(id, at: 950)
        try await f.store.endPause(id, at: 1_000)
        // An end before its start (a clock that moved back) is the start.
        try await f.store.beginPause(id, at: 1_200)
        try await f.store.endPause(id, at: 1_100)
        #expect(try await f.store.pauses(of: id) == [MeetingPause(start: 63, end: 482), MeetingPause(start: 900, end: 950),
                                                      MeetingPause(start: 950, end: 1_000), MeetingPause(start: 1_200, end: 1_200)])
        try await f.store.endMeeting(id, at: .now)
        let other = try await f.meeting(["A meeting that was never paused"])
        #expect(try await f.store.pauses(of: other).isEmpty, "each meeting has its own")
        try await f.store.deleteMeeting(id)
        #expect(try await f.store.pauses(of: id).isEmpty, "deleted with the meeting")
    }
}
