// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Speaker aligner")
struct DiarizationAlignerTests {
    typealias Run = AlignableSegment.Run

    /// Words of `text` separated by single spaces, each lasting `step` seconds from `start`.
    private func runs(of text: String, start: Double, step: Double) -> [Run] {
        var out: [Run] = []
        var offset = 0
        for (i, word) in text.split(separator: " ", omittingEmptySubsequences: true).enumerated() {
            out.append(Run(range: offset..<(offset + word.count), start: start + Double(i) * step, end: start + Double(i + 1) * step))
            offset += word.count + 1
        }
        return out
    }

    private func segment(_ text: String, from start: Double, step: Double, id: Int64 = 1) -> AlignableSegment {
        let words = runs(of: text, start: start, step: step)
        return AlignableSegment(id: id, start: start, end: words.last!.end, text: text, runs: words)
    }

    private func turn(_ speaker: Int, _ start: Double, _ end: Double) -> SpeakerTurn { SpeakerTurn(start: start, end: end, speaker: speaker) }

    private let ten = "one two three four five six seven eight nine ten"

    // MARK: - Whole segments

    @Test func aSegmentGoesToTheSpeakerWhoCoversMostOfIt() {
        // 0.8 s of the next speaker is too short to be a part of its own
        let result = SpeakerAligner(turns: [turn(0, 0, 9.2), turn(1, 9.2, 20)]).align(segment(ten, from: 0, step: 1))
        #expect(result.parts.map(\.speaker) == [0])
        #expect(result.parts[0].offset == 0 && result.parts[0].time == nil)
        #expect(abs(result.parts[0].confidence - 0.92) < 1e-9)
        // 1 s is enough
        #expect(SpeakerAligner(turns: [turn(0, 0, 9), turn(1, 9, 20)]).align(segment(ten, from: 0, step: 1)).parts.map(\.speaker) == [0, 1])
    }

    @Test func noSpeechNoSpeaker() {
        let none = SpeakerAligner(turns: []).align(segment(ten, from: 0, step: 1))
        #expect(none.parts == [AlignedPart(speaker: nil, confidence: 0, overlap: false, offset: 0, time: nil)])
        let far = SpeakerAligner(turns: [turn(0, 50, 60)]).align(segment(ten, from: 0, step: 1))
        #expect(far.parts.map(\.speaker) == [nil])
        let empty = SpeakerAligner(turns: [turn(0, 0, 10)]).align(AlignableSegment(id: 3, start: 5, end: 5, text: "x"))
        #expect(empty.parts.map(\.speaker) == [nil])
    }

    @Test func aBarelyCoveredSegmentGetsNoSpeaker() {
        let result = SpeakerAligner(turns: [turn(0, 9.5, 30)]).align(segment(ten, from: 0, step: 1))
        #expect(result.parts.map(\.speaker) == [nil])   // 5% covered
    }

    // MARK: - Splitting

    @Test func aChangeOfSpeakerSplitsAtTheWordBoundary() {
        let result = SpeakerAligner(turns: [turn(0, 0, 5), turn(1, 5, 10)]).align(segment(ten, from: 0, step: 1))
        #expect(result.parts.map(\.speaker) == [0, 1])
        let second = result.parts[1]
        #expect(second.offset == "one two three four five ".count)
        #expect(second.time == 5)
        #expect(second.confidence == 1)
    }

    @Test func threeSpeakersInOneSegment() {
        let text = "alpha beta gamma delta epsilon zeta eta theta iota"
        let result = SpeakerAligner(turns: [turn(0, 0, 3), turn(1, 3, 6), turn(2, 6, 9)]).align(segment(text, from: 0, step: 1))
        #expect(result.parts.map(\.speaker) == [0, 1, 2])
        #expect(result.parts.map(\.offset) == [0, "alpha beta gamma ".count, "alpha beta gamma delta epsilon zeta ".count])
        #expect(result.parts.map(\.time) == [nil, 3, 6])
    }

    @Test func speakersMayComeBack() {
        let result = SpeakerAligner(turns: [turn(0, 0, 3), turn(1, 3, 6), turn(0, 6, 10)]).align(segment(ten, from: 0, step: 1))
        #expect(result.parts.map(\.speaker) == [0, 1, 0])
        #expect(result.parts.map(\.offset) == [0, "one two three ".count, "one two three four five six ".count])
    }

    @Test func aShortInterjectionStaysInsideTheLongSentence() {
        let result = SpeakerAligner(turns: [turn(0, 0, 4), turn(1, 4, 4.7), turn(0, 4.7, 10)]).align(segment(ten, from: 0, step: 1))
        #expect(result.parts.map(\.speaker) == [0])
    }

    @Test func aGapBetweenSpeakersIsSplitInTheMiddle() {
        let result = SpeakerAligner(turns: [turn(0, 0, 4), turn(1, 6, 10)]).align(segment(ten, from: 0, step: 1))
        #expect(result.parts.map(\.speaker) == [0, 1])
        #expect(result.parts[1].time == 5)
        #expect(result.parts[1].offset == "one two three four five ".count)
        // each speaker covers 4 of the 5 seconds of their part
        #expect(result.parts.allSatisfy { abs($0.confidence - 0.8) < 1e-9 })
    }

    @Test func aWordOnTheBoundaryGoesToTheSideWhereMostOfItIs() {
        // the change at 4.4 s falls inside word "five" (4...5), mostly after the change point's side? midpoint 4.5 >= 4.4
        let result = SpeakerAligner(turns: [turn(0, 0, 4.4), turn(1, 4.4, 10)]).align(segment(ten, from: 0, step: 1))
        #expect(result.parts.map(\.speaker) == [0, 1])
        #expect(result.parts[1].offset == "one two three four ".count)   // "five" belongs to the new speaker
        #expect(result.parts[1].time == 4)
        let late = SpeakerAligner(turns: [turn(0, 0, 4.6), turn(1, 4.6, 10)]).align(segment(ten, from: 0, step: 1))
        #expect(late.parts[1].offset == "one two three four five ".count)   // "five" stays with the old one
        #expect(late.parts[1].time == 5)
    }

    @Test func withoutWordTimesTheTextIsCutInProportionAtASpace() {
        let text = "one two three four five six seven eight nine ten"
        let result = SpeakerAligner(turns: [turn(0, 0, 5), turn(1, 5, 10)]).align(AlignableSegment(id: 1, start: 0, end: 10, text: text))
        #expect(result.parts.map(\.speaker) == [0, 1])
        let offset = result.parts[1].offset
        #expect(Array(text)[offset] == " ")
        #expect(abs(offset - text.count / 2) <= 4)
        #expect(result.parts[1].time == 5)
    }

    @Test func textWithoutSpacesIsCutByCharacter() {
        let text = "今日はいい天気ですね散歩に行きましょう"
        let result = SpeakerAligner(turns: [turn(0, 0, 5), turn(1, 5, 10)]).align(AlignableSegment(id: 1, start: 0, end: 10, text: text))
        #expect(result.parts.map(\.speaker) == [0, 1])
        #expect(result.parts[1].offset == Int((Double(text.count) / 2).rounded()))
    }

    @Test func aSplitThatWouldLeaveASideWithoutTextIsNotMade() {
        // the new speaker only starts after the last word
        let words = [Run(range: 0..<3, start: 0, end: 3), Run(range: 4..<7, start: 3, end: 6)]
        let result = SpeakerAligner(turns: [turn(0, 0, 8), turn(1, 8, 10)]).align(AlignableSegment(id: 1, start: 0, end: 10, text: "one two", runs: words))
        #expect(result.parts.map(\.speaker) == [0])
    }

    @Test func partsAlwaysHaveIncreasingOffsetsAndTimesInsideTheSegment() {
        var random = TestRandom(seed: 123)
        for round in 0..<200 {
            var turns: [SpeakerTurn] = []
            var t = 0.0
            while t < 30 {
                let length = Double(random.uniform()) * 4 + 0.2
                if random.uniform() < 0.85 { turns.append(turn(Int(random.next() % 4), t, t + length)) }
                if random.uniform() < 0.3 { turns.append(turn(Int(random.next() % 4), t + length / 3, t + length * 1.4)) }
                t += length
            }
            let aligner = SpeakerAligner(turns: turns)
            let start = Double(random.uniform()) * 10
            let words = Int(random.next() % 25) + 3
            let text = (0..<words).map { _ in "w" + String(random.next() % 100) }.joined(separator: " ")
            let segments = [segment(text, from: start, step: 0.3 + Double(random.uniform())),
                            AlignableSegment(id: 2, start: start, end: start + 6, text: text)]
            for s in segments {
                let parts = aligner.align(s).parts
                #expect(!parts.isEmpty)
                #expect(parts[0].offset == 0 && parts[0].time == nil, "round \(round)")
                for (a, b) in zip(parts, parts.dropFirst()) {
                    #expect(b.offset > a.offset && b.time! > (a.time ?? s.start), "round \(round)")
                    #expect(b.time! < s.end)
                    #expect(b.offset < text.count)
                    if let x = a.speaker, let y = b.speaker { #expect(x != y, "neighbours with the same speaker would not be split") }
                }
                #expect(parts.allSatisfy { $0.confidence >= 0 && $0.confidence <= 1 })
            }
        }
    }

    // MARK: - Overlap

    @Test func crosstalkSetsTheOverlapFlagAndKeepsTheSpeakerWhoWasTalking() {
        let result = SpeakerAligner(turns: [turn(0, 0, 10), turn(1, 2, 9)]).align(segment(ten, from: 0, step: 1))
        #expect(result.parts.map(\.speaker) == [0])
        #expect(result.parts[0].overlap)
        let brief = SpeakerAligner(turns: [turn(0, 0, 10), turn(1, 2, 4)]).align(segment(ten, from: 0, step: 1))
        #expect(brief.parts.map(\.overlap) == [false])
    }

    @Test func crosstalkInOnePartOnlyMarksThatPart() {
        let turns = [turn(0, 0, 5), turn(1, 5, 10), turn(2, 5.5, 9.8)]
        let result = SpeakerAligner(turns: turns).align(segment(ten, from: 0, step: 1))
        #expect(result.parts.map(\.speaker) == [0, 1])
        #expect(result.parts.map(\.overlap) == [false, true])
    }

    // MARK: - Many turns

    @Test func longRecordingsAlignQuickly() {
        let turns = (0..<20_000).map { turn($0 % 5, Double($0) * 1.5, Double($0) * 1.5 + 1.4) }
        let aligner = SpeakerAligner(turns: turns)
        let segments = (0..<5_000).map { i in AlignableSegment(id: Int64(i), start: Double(i) * 6, end: Double(i) * 6 + 5, text: "some words here") }
        var aligned: [SegmentAlignment] = []
        let cpu = cpuSeconds { aligned = aligner.align(segments) }
        #expect(aligned.count == 5_000)
        #expect(!TestTiming.holdsBudgets || cpu < 5, "aligning took \(cpu) s of CPU")
    }
}
