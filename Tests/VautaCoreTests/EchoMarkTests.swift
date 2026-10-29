// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// `segments.echo`: the speakers' echo is marked on the Me lines of a finished meeting, kept and shown, and left out of whatever
/// reads the transcript as what was said. The person's word on a line wins and is never overridden.
@Suite("Storage: the speakers' echo in the microphone")
struct EchoMarkTests {
    private static let said = "We should move the launch of Kobaltix to the second week of March"
    private static let reply = "I think that is too late for the supplier of the shell"

    /// A meeting in which the microphone heard the other side (line 2) and the user then answered (line 3).
    private func meeting(_ f: KnowledgeFixture) async throws -> (id: Int64, others: Int64, echo: Int64, reply: Int64) {
        let s = f.store!
        let id = try await s.startMeeting(at: .now, locale: Locale(identifier: "en-US"))
        let others = try await s.append(Segment(channel: .others, start: 10, end: 14, text: Self.said, isFinal: true), to: id)
        let echo = try await s.append(Segment(channel: .me, start: 10.3, end: 14.2, text: Self.said.lowercased(), isFinal: true), to: id)
        let reply = try await s.append(Segment(channel: .me, start: 15, end: 19, text: Self.reply, isFinal: true), to: id)
        try await s.endMeeting(id, at: .now + 60)
        return (id, others, echo, reply)
    }

    @Test func theReleaseDoesNotMarkYet() async throws {
        #expect(!EchoRelease.marksAfterRecording)
        let f = try KnowledgeFixture()
        let m = try await meeting(f)
        #expect(try await f.store.echoes(of: m.id).isEmpty)
    }

    @Test func anEchoIsKeptButLeftOutOfWhatWasSaid() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let m = try await meeting(f)
        #expect(try await s.markEchoes(m.id) == 1)
        #expect(try await s.echoes(of: m.id) == [m.echo])

        // The transcript shows it, marked; the rest leaves it out.
        let all = try await s.segments(of: m.id, echoes: true)
        #expect(all.map(\.id) == [m.others, m.echo, m.reply] && all.map(\.isEcho) == [false, true, false])
        #expect(try await s.segments(of: m.id).map(\.id) == [m.others, m.reply])
        #expect(try await s.citableSegments(m.id).map(\.id) == [m.others, m.reply], "the minutes, notes and answers")
        #expect(try await s.search("launch").map(\.segment.id) == [m.others], "search finds the words once, where they were said")
        let export = try #require(try await s.meetingExport(m.id))
        #expect(export.transcript.count == 2 && export.transcript.allSatisfy { $0.channel == .others || $0.text == Self.reply })
        #expect(try await s.markEchoes(m.id) == 0, "marking again changes nothing")
    }

    @Test func thePersonsWordOnALineWins() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let m = try await meeting(f)
        try await s.markEchoes(m.id)
        try await s.setEcho(m.echo, false)
        #expect(try await s.echoes(of: m.id).isEmpty)
        #expect(try await s.citableSegments(m.id).map(\.id) == [m.others, m.echo, m.reply])
        #expect(try await s.markEchoes(m.id) == 0, "a line the person said is theirs is never marked again")
        try await s.setEcho(m.echo, true)
        #expect(try await s.echoes(of: m.id) == [m.echo])
        // Only a Me line can be an echo.
        try await s.setEcho(m.others, true)
        #expect(try await s.echoes(of: m.id) == [m.echo])
    }

    @Test func anEchoIsNotTheUserTalking() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let m = try await meeting(f)
        try await s.finalizeSpeakers(meetingID: m.id, speakers: [SpeakerDraft(channel: .me, ordinal: 1), SpeakerDraft(channel: .others, ordinal: 1)],
                                     assignments: [SegmentSpeakerAssignment(segmentID: m.echo, channel: .me, ordinal: 1),
                                                   SegmentSpeakerAssignment(segmentID: m.reply, channel: .me, ordinal: 1),
                                                   SegmentSpeakerAssignment(segmentID: m.others, channel: .others, ordinal: 1)])
        func myTalk() async throws -> Double { try #require(try await s.speakers(of: m.id).first { $0.channel == .me }).talkSeconds }
        #expect(abs(try await myTalk() - 7.9) < 0.01)
        try await s.markEchoes(m.id)
        #expect(abs(try await myTalk() - 4) < 0.01, "only the reply")
        try await s.setEcho(m.echo, false)
        #expect(abs(try await myTalk() - 7.9) < 0.01)
    }

    @Test func aMeetingWithoutTheOtherChannelHasNoEchoes() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let id = try await s.startMeeting(at: .now, locale: Locale(identifier: "en-US"))
        try await s.append(Segment(channel: .me, start: 10, end: 14, text: Self.said, isFinal: true), to: id)
        try await s.endMeeting(id, at: .now + 60)
        #expect(try await s.markEchoes(id) == 0)
    }
}
