// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The words of `Vauta attribute-file`: each one with the speaker of its part, split as the store splits the lines.
@Suite("Speakers: the words of each speaker, for the attributed error rates")
struct SpeakerAttributionTests {
    /// A line said word by word, `step` seconds a word from `start`, with the word times a recogniser gives.
    static func line(_ id: Int64, _ text: String, start: Double, step: Double = 0.5) -> AlignableSegment {
        var runs: [AlignableSegment.Run] = []
        var offset = 0
        for (k, word) in text.split(separator: " ").enumerated() {
            runs.append(.init(range: offset..<(offset + word.count), start: start + Double(k) * step, end: start + Double(k + 1) * step))
            offset += word.count + 1
        }
        return AlignableSegment(id: id, start: start, end: start + Double(runs.count) * step, text: text, runs: runs)
    }

    static let turns = [SpeakerTurn(start: 0, end: 2.5, speaker: 0), SpeakerTurn(start: 2.5, end: 9, speaker: 1)]

    @Test func eachWordHasTheSpeakerOfItsPartAndItsOwnTime() {
        // "We keep the budget" until 2.5 s is speaker 0; "yes I agree with that" after it, speaker 1.
        let segment = Self.line(1, "We keep the budget fine yes I agree with that", start: 0, step: 0.5)
        let aligned = SpeakerAligner(turns: Self.turns).align([segment])
        let words = SpeakerAttribution.words(of: [segment], alignments: aligned)
        #expect(words.map(\.text) == segment.text.split(separator: " ").map(String.init))
        #expect(words.prefix(5).allSatisfy { $0.speaker == 0 } && words.dropFirst(5).allSatisfy { $0.speaker == 1 })
        #expect(words[5].start == 2.5 && words[5].end == 3, "a recognised word keeps its time")
    }

    @Test func theWordsAreSplitAsTheStoreSplitsTheLines() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.store.startMeeting(at: .now)
        let texts = ["We keep the budget fine yes I agree with that", "Then we close the call"]
        var rows: [Int64] = []
        for (k, text) in texts.enumerated() {
            rows.append(try await f.store.append(Segment(channel: .others, start: Double(k) * 6, end: Double(k) * 6 + 5, text: text, isFinal: true), to: id))
        }
        try await f.store.endMeeting(id, at: .now.addingTimeInterval(60))
        let segments = zip(rows, texts).enumerated().map { k, row in Self.line(row.0, row.1, start: Double(k) * 6) }
        let runs = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0.runs) })
        let diarization = Diarization(turns: Self.turns + [SpeakerTurn(start: 9, end: 12, speaker: 0)], speakerCount: 2, mapping: [], centroids: [])
        _ = try await f.store.applyDiarization(diarization, to: id, wordRuns: runs)
        let stored = try await f.store.segments(of: id).filter { $0.channel == .others }
        // The store's lines, and the words grouped the same way: who says each stretch, in order.
        let lines = stored.map { ($0.speaker?.ordinal, $0.text.split(separator: " ").joined(separator: " ")) }
        let words = SpeakerAttribution.words(of: segments, alignments: SpeakerAligner(turns: diarization.turns).align(segments))
        var ordinal: [Int: Int] = [:]
        var groups: [(Int?, String)] = []
        var segmentOfWord = 0, wordsLeft = texts[0].split(separator: " ").count
        for word in words {
            if wordsLeft == 0 { segmentOfWord += 1; wordsLeft = texts[segmentOfWord].split(separator: " ").count; groups.append((-1, "")) }
            wordsLeft -= 1
            let label = word.speaker.map { s in ordinal[s] ?? { ordinal[s] = ordinal.count + 1; return ordinal[s]! }() }
            if let last = groups.last, last.0 == label { groups[groups.count - 1].1 += " " + word.text } else { groups.append((label, word.text)) }
        }
        let parts = groups.filter { $0.0 != -1 }
        #expect(parts.map(\.0) == lines.map(\.0), "the same speakers, numbered by first appearance as the store does")
        #expect(parts.map(\.1) == lines.map(\.1), "the same split of the text")
        #expect(lines.count == 3, "the first line was split once")
    }

    @Test func aCutThatIsNotInsideTheTextLeavesTheWordsWithThePartBefore() {
        let segment = Self.line(1, "one two three", start: 0)
        let parts = [AlignedPart(speaker: 0, confidence: 1, overlap: false, offset: 0, time: nil),
                     AlignedPart(speaker: 1, confidence: 1, overlap: false, offset: 13, time: 1.5)]
        let words = SpeakerAttribution.words(of: [segment], alignments: [SegmentAlignment(segmentID: 1, parts: parts)])
        #expect(words.map(\.speaker) == [0, 0, 0], "a cut at the end of the text is not made, as in the store")
    }

    @Test func textWithoutWordTimesIsSpreadOverItsPart() {
        let plain = AlignableSegment(id: 1, start: 10, end: 14, text: "alpha beta gamma delta")
        let parts = [AlignedPart(speaker: 0, confidence: 1, overlap: false, offset: 0, time: nil),
                     AlignedPart(speaker: 1, confidence: 1, overlap: false, offset: 11, time: 12)]
        let words = SpeakerAttribution.words(of: [plain], alignments: [SegmentAlignment(segmentID: 1, parts: parts)])
        #expect(words.map(\.text) == ["alpha", "beta", "gamma", "delta"] && words.map(\.speaker) == [0, 0, 1, 1])
        #expect(words[0].start == 10 && words[2].start == 12 && words[3].end == 14)
        #expect(words.allSatisfy { $0.end >= $0.start })
        // A segment the aligner gave no parts keeps its words, with no speaker.
        let lone = SpeakerAttribution.words(of: [plain], alignments: [])
        #expect(lone.count == 4 && lone.allSatisfy { $0.speaker == nil })
    }

    @Test func wordsTheRecogniserLeftWithoutATimeAreKept() {
        var segment = Self.line(1, "we keep it", start: 0)
        segment.runs.remove(at: 1)
        let words = SpeakerAttribution.words(of: [segment], alignments: [])
        #expect(words.map(\.text) == ["we", "keep", "it"], "no text is lost")
        #expect(words[1].start >= words[0].start && words[1].start <= words[2].start)
    }
}
