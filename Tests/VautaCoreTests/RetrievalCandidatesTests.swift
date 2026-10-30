// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Ask's candidate passages, read a query per list instead of one per passage: the chunks that hold each keyword hit, and what the
/// context graph says about each passage. The edges of a range count, as they did with one query per passage.
@Suite("Ranking: candidates in one query")
struct RetrievalCandidatesTests {
    private let space = EmbeddingSpace(model: "m", dimensions: 4)
    private let other = EmbeddingSpace(model: "other", dimensions: 4)

    /// An ended meeting whose lines start at the given times, alternating "others" and "me".
    private func meeting(_ fx: KnowledgeFixture, _ lines: [(Double, String)]) async throws -> (id: Int64, segments: [Int64]) {
        let id = try await fx.store.startMeeting(at: .now)
        var segments: [Int64] = []
        for (i, (t, text)) in lines.enumerated() {
            segments.append(try await fx.store.append(Segment(channel: i % 2 == 0 ? .others : .me, start: t, end: t + 5, text: text, isFinal: true),
                                                      to: id))
        }
        try await fx.store.endMeeting(id, at: .now + 600)
        return (id, segments)
    }

    /// Chunks with the given ranges (their vectors do not matter here), by start.
    private func chunks(_ fx: KnowledgeFixture, _ meeting: Int64, _ ranges: [(Double, Double)], space: EmbeddingSpace) async throws -> [Int64] {
        try await fx.store.replaceChunks(meeting, ranges.map { ($0.0, $0.1, Data(repeating: 1, count: space.dimensions), 1, "k") }, space: space)
        return try await fx.store.intsForTest("SELECT id FROM chunks WHERE meeting_id = ? ORDER BY start", [.integer(meeting)])
    }

    @Test func aHitOnTheOverlapOfTwoChunksIsInBothInOrder() async throws {
        let fx = try KnowledgeFixture()
        let m = try await meeting(fx, [(0, "one"), (10, "two"), (20, "three"), (30, "four")])
        let c = try await chunks(fx, m.id, [(0, 21), (20, 40)], space: space)
        let found = try await fx.store.chunksHolding([m.segments[2], m.segments[0], m.segments[3]], space: space).mapValues { $0.map(\.id) }
        #expect(found == [m.segments[2]: c, m.segments[0]: [c[0]], m.segments[3]: [c[1]]])
        #expect(try await fx.store.chunksHolding([m.segments[2]], space: other).isEmpty, "only the chunks of the space asked")
        #expect(try await fx.store.chunksHolding([m.segments[2]], space: nil).mapValues { $0.map(\.id) } == [m.segments[2]: c], "any space")
        #expect(try await fx.store.chunks(holding: 20, in: m.id, space: space).map(\.id) == c)
        #expect(try await fx.store.chunks(holding: 20, in: m.id, space: other).isEmpty)
    }

    @Test func theGraphCountsAMentionOrANamedSpeakerOnTheEdgesOfARange() async throws {
        let fx = try KnowledgeFixture()
        let priya = try await fx.store.saveEntity(EntityDraft(kind: .person, name: "Priya"))
        let m = try await meeting(fx, [(0, "Priya opens the review"), (10, "The budget is late"), (20, "Priya closes it"), (30, "Thanks")])
        // The "others" lines (0 and 20) are said by a speaker the user named Priya.
        try await fx.store.finalizeSpeakers(meetingID: m.id, speakers: [SpeakerDraft(channel: .others, ordinal: 1)], assignments: [
            SegmentSpeakerAssignment(segmentID: m.segments[0], channel: .others, ordinal: 1, confidence: 0.9),
            SegmentSpeakerAssignment(segmentID: m.segments[2], channel: .others, ordinal: 1, confidence: 0.9)])
        _ = try await fx.store.assignSpeaker(try #require(try await fx.store.speakers(of: m.id).first).id, toEntity: priya)
        let c = try await chunks(fx, m.id, [(0, 10), (5, 9), (10, 20)], space: space)
        // A meeting without chunks: its lines are in time buckets.
        let n = try await meeting(fx, [(5, "Hello"), (130, "Priya joined late"), (131, "Priya again")])
        let bucket = MeetingStore.Located(bucketOf: 5, meeting: n.id)
        #expect(bucket.key == "m\(n.id)@0" && bucket.start == 0 && bucket.end == 130)
        let ranges: [String: (meeting: Int64, start: Double, end: Double)] = [
            "c\(c[0])": (m.id, 0, 10), "c\(c[1])": (m.id, 5, 9), "c\(c[2])": (m.id, 10, 20), bucket.key: (n.id, bucket.start, bucket.end)]
        let signals = try await fx.store.graphSignals(ranges, entities: [priya])
        #expect(signals.count == 4)
        #expect(signals["c\(c[0])"]! == (1, true), "the mention and the line at the chunk's start")
        #expect(signals["c\(c[1])"]! == (0, false))
        #expect(signals["c\(c[2])"]! == (1, true), "the mention and the line at the chunk's end")
        #expect(signals[bucket.key]! == (1, false), "the mention at 130 s is the bucket's last second; the one at 131 s is not in it")
    }

    @Test func aKeywordHitLandsInItsMeetingsChunkWhateverItsSpace() async throws {
        let fx = try KnowledgeFixture()
        let m = try await meeting(fx, [(0, "Opening"), (10, "Agenda"), (30, "The kobaltix contract"), (40, "Closing")])
        let en = Locale(identifier: "en")
        func passages() async throws -> [String] {
            try await fx.store.retrieve("kobaltix", queryVector: nil, locale: en, mode: .keyword).map { "\($0.meeting.id) \($0.start)-\($0.end)" }
        }
        #expect(try await passages() == ["\(m.id) 0.0-130.0"], "no chunk yet: the hit's time bucket")
        _ = try await chunks(fx, m.id, [(0, 21), (25, 45)], space: other)
        #expect(try await passages() == ["\(m.id) 25.0-45.0"], "the chunk that holds the hit, of whatever space")
    }
}
