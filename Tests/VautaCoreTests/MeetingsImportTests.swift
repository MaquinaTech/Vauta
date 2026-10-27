// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AVFoundation
import Foundation
import Testing
@testable import VautaCore

/// Importing a recording as a new meeting: dating, naming, cleaning the
/// transcription, storing it and decoding the audio (no speech recognition:
/// that needs the system models).
@Suite("Meetings · import a recording")
struct MeetingsImportTests {
    static let now = ExportRendererTests.date(2026, 10, 7, 12)

    @Test func planUsesTheRecordingDateAndFileName() {
        let recorded = Self.now.addingTimeInterval(-3 * 86_400)
        let p = RecordingImportPlan(fileName: "Client call 2026-10-04.m4a", recordedAt: recorded, duration: 1800, now: Self.now)
        #expect(p.title == "Client call 2026-10-04")
        #expect(p.startedAt == recorded && p.endedAt == recorded.addingTimeInterval(1800))
        #expect(!p.redated)
    }

    @Test func planRedatesRecordingsThatWouldExpireAtOnce() {
        let old = Self.now.addingTimeInterval(-200 * 86_400)
        let p = RecordingImportPlan(fileName: "old.wav", recordedAt: old, duration: 600, now: Self.now)
        #expect(p.redated)
        #expect(p.endedAt == Self.now && p.startedAt == Self.now.addingTimeInterval(-600))
        let future = RecordingImportPlan(fileName: "x.wav", recordedAt: Self.now + 86_400, duration: 60, now: Self.now)
        #expect(future.redated && future.endedAt == Self.now)
    }

    @Test func planWithoutDateEndsNow() {
        let p = RecordingImportPlan(fileName: "  .m4a", recordedAt: nil, duration: .nan, now: Self.now)
        #expect(p.title == nil, "no usable name: the automatic title")
        #expect(!p.redated && p.startedAt == Self.now && p.endedAt == Self.now)
    }

    @Test func transcriptKeepsFinalTextInOrder() {
        let raw = [
            Segment(channel: .me, start: 12, end: 15, text: "  second  ", isFinal: true),
            Segment(channel: .me, start: 2, end: 4, text: "volatile", isFinal: false),
            Segment(channel: .others, start: 1, end: 3, text: "first", isFinal: true),
            Segment(channel: .others, start: 20, end: 22, text: "   ", isFinal: true),
            Segment(channel: .others, start: -1, end: 99, text: "clamped", isFinal: true),
        ]
        let out = RecordingImportPlan.transcript(from: raw, duration: 30)
        #expect(out.map(\.text) == ["clamped", "first", "second"])
        #expect(out.allSatisfy { $0.channel == .others && $0.isFinal })
        #expect(out[0].start == 0 && out[0].end == 30)
    }

    @Test func importStoresAFinishedMeetingWithoutBecomingActive() async throws {
        let f = try KnowledgeFixture()
        let recording = try await f.store.startMeeting(at: .now)   // a live recording in progress
        let plan = RecordingImportPlan(fileName: "Interview.m4a", recordedAt: Self.now - 3600, duration: 120, now: Self.now)
        let segments = RecordingImportPlan.transcript(from: [
            Segment(channel: .others, start: 0, end: 4, text: "Hello and welcome", isFinal: true),
            Segment(channel: .others, start: 5, end: 9, text: "Thanks for having me", isFinal: true),
        ])
        let id = try await f.store.importMeeting(plan, segments: segments, locale: Locale(identifier: "en-US"))
        #expect(await f.store.activeMeetingID == recording)
        try await f.reopen()
        let reopened = f.store!
        let meeting = try #require(try await reopened.meeting(id))
        #expect(meeting.title == "Interview")
        #expect(meeting.startedAt == plan.startedAt && meeting.endedAt == plan.endedAt)
        #expect(meeting.locale == "en-US")
        #expect(try await reopened.segments(of: id).map(\.text) == ["Hello and welcome", "Thanks for having me"])
    }

    @Test func importWithoutSpeechCreatesNothing() async throws {
        let f = try KnowledgeFixture()
        let plan = RecordingImportPlan(fileName: "silence.wav", recordedAt: nil, duration: 5, now: Self.now)
        await #expect(throws: RecordingImportError(.noSpeech)) {
            try await f.store.importMeeting(plan, segments: [], locale: nil)
        }
        #expect(try await f.store.meetings().isEmpty)
    }

    @Test func decoderMixesAndResamplesAFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tone.wav")
        try Self.writeTone(to: url, seconds: 1.5, sampleRate: 44_100, channels: 2)

        let info = try await RecordingTranscriber.inspect(url)
        #expect(abs(info.duration - 1.5) < 0.01 && info.fileName == "tone.wav")

        let target = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false))
        let decoder = try await AudioFileDecoder(url: url, format: target)
        var frames: AVAudioFramePosition = 0
        var peak: Int16 = 0
        while let (buffer, start) = try decoder.next() {
            #expect(start == frames, "chunks are contiguous")
            #expect(buffer.format.isEqual(target))
            let samples = UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength))
            peak = max(peak, samples.max() ?? 0)
            frames += AVAudioFramePosition(buffer.frameLength)
        }
        #expect(abs(Int(frames) - 24_000) < 200)
        #expect(peak > 1000, "the tone survives the conversion")
        #expect(abs(decoder.position - 1.5) < 0.02)
    }

    @Test func nonAudioFilesAreRejected() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("notes.txt")
        try Data("not audio".utf8).write(to: url)
        do {
            _ = try await RecordingTranscriber.inspect(url)
            Issue.record("a text file must not be accepted")
        } catch let e as RecordingImportError {
            #expect(e.code == .noAudio || e.code == .unreadable)
            #expect(e.errorDescription != nil && e.recoverySuggestion != nil)
        }
    }

    /// A sine tone as 32-bit float PCM (no microphone involved).
    static func writeTone(to url: URL, seconds: Double, sampleRate: Double, channels: AVAudioChannelCount) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<Int(channels) {
            let data = buffer.floatChannelData![c]
            for i in 0..<Int(frames) { data[i] = Float(0.5 * sin(2 * .pi * 440 * Double(i) / sampleRate)) }
        }
        try file.write(from: buffer)
    }
}
