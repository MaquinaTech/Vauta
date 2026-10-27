// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// A transcript segment as the aligner sees it.
public struct AlignableSegment: Sendable {
    /// One recognised word or phrase: where it is in the segment's text and when it was spoken.
    public struct Run: Sendable, Equatable {
        /// Offsets in Characters into `text`.
        public var range: Range<Int>
        public var start: Double
        public var end: Double

        public init(range: Range<Int>, start: Double, end: Double) {
            self.range = range
            self.start = start
            self.end = end
        }
    }

    public var id: Int64
    public var start: Double
    public var end: Double
    public var text: String
    /// Word or phrase times in text order, when the recogniser gave them. Splits then fall between words at the
    /// time the speaker really changed; without them the text is cut in proportion to the time.
    public var runs: [Run]

    public init(id: Int64, start: Double, end: Double, text: String, runs: [Run] = []) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.runs = runs
    }
}

/// Who speaks one stretch of a segment.
public struct AlignedPart: Sendable, Equatable {
    /// 0-based speaker index (the ordinal is this plus one); nil when nobody speaks there.
    public var speaker: Int?
    /// The share of the part during which that speaker is active (0...1).
    public var confidence: Double
    /// The part lies in crosstalk: no name should be guessed there.
    public var overlap: Bool
    /// Characters of the segment's ORIGINAL text before this part (0 for the first part).
    public var offset: Int
    /// When the part starts, for a part after a split (nil for the first part).
    public var time: Double?
}

/// The speakers of one segment, in text order. One part means no split; each further part is a split of the
/// original segment at `offset` / `time` (a `SegmentSplitRequest` per part after the first, all against the
/// original text).
public struct SegmentAlignment: Sendable, Equatable {
    public var segmentID: Int64
    public var parts: [AlignedPart]
}

/// Gives the transcript segments their speakers from the diarization turns.
///
/// A segment goes to the speaker who covers most of it. Where the speaker changes inside a segment (any number of
/// times: A, B, A, or three people in one sentence group) the segment is split at the changes, at the word
/// boundary when word times are known. A stretch shorter than `minPartSeconds` is never split off: a "yes" or a
/// cough inside someone else's sentence stays with them. Crosstalk (two speakers at once) sets `overlap`.
public struct SpeakerAligner: Sendable {
    public struct Config: Sendable, Equatable {
        /// Shortest stretch that becomes a part of its own.
        public var minPartSeconds = 1.0
        /// A part is crosstalk when this share of it has two or more speakers.
        public var overlapFraction = 0.5
        /// A part covered by its speaker less than this share gets no speaker.
        public var minCoverage = 0.1

        public init() {}
    }

    public let config: Config
    private let turns: [SpeakerTurn]
    private let latestEnd: [Double]   // latestEnd[i] = max end of turns[0...i]

    public init(turns: [SpeakerTurn], config: Config = Config()) {
        self.config = config
        let sorted = turns.filter { $0.end > $0.start }.sorted { ($0.start, $0.speaker) < ($1.start, $1.speaker) }
        self.turns = sorted
        var latest = -Double.infinity
        self.latestEnd = sorted.map { latest = max(latest, $0.end); return latest }
    }

    public func align(_ segments: [AlignableSegment]) -> [SegmentAlignment] {
        segments.map(align)
    }

    public func align(_ segment: AlignableSegment) -> SegmentAlignment {
        let none = SegmentAlignment(segmentID: segment.id, parts: [AlignedPart(speaker: nil, confidence: 0, overlap: false, offset: 0, time: nil)])
        let (start, end) = (segment.start, segment.end)
        guard end > start else { return none }

        // The turns inside the segment, cut at its edges, and the pieces they divide it into.
        let inside = overlapping(start, end).map { SpeakerTurn(start: max($0.start, start), end: min($0.end, end), speaker: $0.speaker) }
            .filter { $0.end > $0.start }
        guard !inside.isEmpty else { return none }
        let cuts = Array(Set([start, end] + inside.flatMap { [$0.start, $0.end] })).sorted()
        var pieces: [Piece] = []
        for (a, b) in zip(cuts, cuts.dropFirst()) where b > a {
            let middle = (a + b) / 2
            pieces.append(Piece(start: a, end: b, active: Set(inside.filter { $0.start <= middle && middle < $0.end }.map(\.speaker)).sorted()))
        }
        var total: [Int: Double] = [:]
        for piece in pieces { for s in piece.active { total[s, default: 0] += piece.end - piece.start } }

        // Who is speaking in each piece: the only one; in crosstalk the one who was already speaking, else the one
        // with more speech in the segment.
        var stretches: [Stretch] = []
        var previous: Int?
        for piece in pieces {
            var speaker: Int?
            if piece.active.count == 1 {
                speaker = piece.active[0]
            } else if piece.active.count > 1 {
                speaker = previous.flatMap { piece.active.contains($0) ? $0 : nil }
                    ?? piece.active.max { (total[$0] ?? 0, -$0) < (total[$1] ?? 0, -$1) }
            }
            if speaker != nil { previous = speaker }
            stretches.append(Stretch(start: piece.start, end: piece.end, speaker: speaker))
        }
        stretches = settleSilences(stretches, from: start, to: end)
        stretches = absorbShort(stretches)
        guard !stretches.isEmpty else { return none }

        // Where each change falls in the text.
        var parts: [(stretch: Stretch, offset: Int, time: Double?)] = [(stretches[0], 0, nil)]
        let characters = Array(segment.text)
        for stretch in stretches.dropFirst() {
            if let cut = cutPoint(at: stretch.start, segment: segment, characters: characters, after: parts.last!) {
                parts.append((stretch, cut.offset, cut.time))
            } else {
                // no valid place to cut: the stretch stays with the part before it, whoever has more of the two
                var last = parts.removeLast()
                last.stretch = merged(last.stretch, stretch)
                parts.append(last)
            }
        }
        // merging can leave neighbours with the same speaker
        var final: [(stretch: Stretch, offset: Int, time: Double?)] = []
        for part in parts {
            if var last = final.last, last.stretch.speaker == part.stretch.speaker {
                last.stretch.end = part.stretch.end
                final[final.count - 1] = last
            } else {
                final.append(part)
            }
        }
        return SegmentAlignment(segmentID: segment.id, parts: final.map { part in
            let measured = measure(part.stretch, pieces: pieces)
            let speaker = measured.coverage >= config.minCoverage ? part.stretch.speaker : nil
            return AlignedPart(speaker: speaker, confidence: speaker == nil ? 0 : measured.coverage, overlap: measured.overlap,
                               offset: part.offset, time: part.time)
        })
    }

    // MARK: - Working types

    private struct Piece {
        var start: Double
        var end: Double
        var active: [Int]
    }

    private struct Stretch {
        var start: Double
        var end: Double
        var speaker: Int?
        var duration: Double { end - start }
    }

    // MARK: - Steps

    /// Turns overlapping [start, end).
    private func overlapping(_ start: Double, _ end: Double) -> [SpeakerTurn] {
        // first turn that could still be running at `start`: latestEnd is non-decreasing
        var low = 0, high = turns.count
        while low < high {
            let mid = (low + high) / 2
            if latestEnd[mid] > start { high = mid } else { low = mid + 1 }
        }
        var stop = low
        while stop < turns.count && turns[stop].start < end { stop += 1 }
        return turns[low..<stop].filter { $0.end > start }
    }

    /// Gives stretches where nobody speaks to their neighbours (a gap between two speakers is split in the
    /// middle) and joins neighbours with the same speaker. Returns nothing when nobody speaks at all.
    private func settleSilences(_ input: [Stretch], from start: Double, to end: Double) -> [Stretch] {
        var spoken: [Stretch] = []
        for stretch in input where stretch.speaker != nil {
            if let last = spoken.last, last.speaker == stretch.speaker {
                spoken[spoken.count - 1].end = stretch.end   // includes a silence inside one speaker's speech
            } else {
                spoken.append(stretch)
            }
        }
        guard !spoken.isEmpty else { return [] }
        spoken[0].start = start
        spoken[spoken.count - 1].end = end
        for i in 1..<max(1, spoken.count) where spoken[i - 1].end != spoken[i].start {
            let middle = (spoken[i - 1].end + spoken[i].start) / 2
            spoken[i - 1].end = middle
            spoken[i].start = middle
        }
        return spoken
    }

    /// Joins stretches shorter than `minPartSeconds` to the longer neighbour, shortest first.
    private func absorbShort(_ input: [Stretch]) -> [Stretch] {
        var stretches = input
        while stretches.count > 1, let index = stretches.indices.filter({ stretches[$0].duration < config.minPartSeconds })
            .min(by: { stretches[$0].duration < stretches[$1].duration }) {
            let left = index > 0 ? stretches[index - 1] : nil, right = index + 1 < stretches.count ? stretches[index + 1] : nil
            let intoLeft = right == nil || (left != nil && left!.duration >= right!.duration)
            if intoLeft {
                stretches[index - 1].end = stretches[index].end
            } else {
                stretches[index + 1].start = stretches[index].start
            }
            stretches.remove(at: index)
            var joined: [Stretch] = []
            for stretch in stretches {
                if let last = joined.last, last.speaker == stretch.speaker { joined[joined.count - 1].end = stretch.end } else { joined.append(stretch) }
            }
            stretches = joined
        }
        return stretches
    }

    private func merged(_ a: Stretch, _ b: Stretch) -> Stretch {
        Stretch(start: a.start, end: b.end, speaker: a.duration >= b.duration ? a.speaker : b.speaker)
    }

    /// Where to cut the text for a speaker change at time `t`: before the first word that is mostly after `t`
    /// (word times), or in proportion to the time at the nearest space. nil when the cut would leave a side empty
    /// or the time outside the segment.
    private func cutPoint(at t: Double, segment: AlignableSegment, characters: [Character],
                          after previous: (stretch: Stretch, offset: Int, time: Double?)) -> (offset: Int, time: Double)? {
        var offset: Int
        var time = t
        let runs = segment.runs.sorted { $0.range.lowerBound < $1.range.lowerBound }
        if !runs.isEmpty {
            guard let index = runs.firstIndex(where: { ($0.start + $0.end) / 2 >= t }) else { return nil }
            offset = runs[index].range.lowerBound
            let floor = index > 0 ? runs[index - 1].end : segment.start
            time = min(runs[index].start, max(t, floor))
        } else {
            let share = (t - segment.start) / (segment.end - segment.start)
            let guess = min(characters.count - 1, max(1, Int((Double(characters.count) * share).rounded())))
            let spaces = characters.indices.filter { characters[$0].isWhitespace && $0 > 0 && $0 < characters.count - 1 }
            offset = spaces.min { abs($0 - guess) < abs($1 - guess) } ?? guess
        }
        let earliest = max(segment.start, previous.time ?? segment.start)
        guard offset > previous.offset, offset < characters.count, segment.end > time, time > earliest else { return nil }
        let left = String(characters[previous.offset..<offset]).trimmingCharacters(in: .whitespacesAndNewlines)
        let right = String(characters[offset...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty, !right.isEmpty else { return nil }
        return (offset, time)
    }

    /// The share of a stretch covered by its speaker, and whether crosstalk fills more than `overlapFraction`.
    private func measure(_ stretch: Stretch, pieces: [Piece]) -> (coverage: Double, overlap: Bool) {
        var covered = 0.0, crosstalk = 0.0
        for piece in pieces {
            let length = min(piece.end, stretch.end) - max(piece.start, stretch.start)
            guard length > 0 else { continue }
            if let speaker = stretch.speaker, piece.active.contains(speaker) { covered += length }
            if piece.active.count > 1 { crosstalk += length }
        }
        guard stretch.duration > 0 else { return (0, false) }
        return (min(1, covered / stretch.duration), crosstalk / stretch.duration >= config.overlapFraction)
    }
}
