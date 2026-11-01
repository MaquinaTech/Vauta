// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The words of a transcript with the speaker each one got, split and assigned as `MeetingStore.applyDiarization` does with
/// the aligner's parts. For the speaker-attributed error rates of the evaluation (`Vauta attribute-file`, on public audio):
/// the app itself keeps the parts as lines, never words.
public enum SpeakerAttribution {
    public struct Word: Sendable, Equatable, Codable {
        /// The aligner's 0-based speaker; nil where it gave none.
        public var speaker: Int?
        public var start: Double
        public var end: Double
        public var text: String

        public init(speaker: Int?, start: Double, end: Double, text: String) {
            self.speaker = speaker
            self.start = start
            self.end = end
            self.text = text
        }
    }

    /// The words of each segment in order. A recognised word keeps its time; text that no word time covers is spread over
    /// its part in proportion to its place in it.
    public static func words(of segments: [AlignableSegment], alignments: [SegmentAlignment]) -> [Word] {
        let byID = Dictionary(alignments.map { ($0.segmentID, $0) }, uniquingKeysWith: { first, _ in first })
        return segments.flatMap { segment in
            words(of: segment, alignment: byID[segment.id] ?? SegmentAlignment(segmentID: segment.id, parts: []))
        }
    }

    static func words(of segment: AlignableSegment, alignment: SegmentAlignment) -> [Word] {
        let characters = Array(segment.text)
        // The parts the store keeps: a cut must fall strictly inside the text and after the one before it, or the text stays
        // with the part before (and so does its speaker), as in `applyDiarization`.
        var parts: [(offset: Int, time: Double?, speaker: Int?)] = []
        for (index, part) in alignment.parts.enumerated() {
            if index == 0 {
                parts.append((0, nil, part.speaker))
            } else if part.offset > (parts.last?.offset ?? 0), part.offset < characters.count {
                parts.append((part.offset, part.time, part.speaker))
            }
        }
        if parts.isEmpty { parts = [(0, nil, nil)] }
        let span = max(0, segment.end - segment.start)
        func proportional(_ offset: Int) -> Double {
            segment.start + span * Double(offset) / Double(max(1, characters.count))
        }
        let runs = segment.runs.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var out: [Word] = []
        for (k, part) in parts.enumerated() {
            let lo = part.offset
            let hi = k + 1 < parts.count ? parts[k + 1].offset : characters.count
            let start = k == 0 ? segment.start : (part.time ?? proportional(lo))
            let end = k + 1 < parts.count ? (parts[k + 1].time ?? proportional(hi)) : segment.end
            func time(_ offset: Int) -> Double { start + max(0, end - start) * Double(offset - lo) / Double(max(1, hi - lo)) }
            var cursor = lo
            // The words between `cursor` and `limit` that no word time covers.
            func uncovered(upTo limit: Int) {
                var wordStart: Int?
                for i in cursor...limit {
                    let blank = i == limit || characters[i].isWhitespace
                    if blank, let from = wordStart {
                        out.append(Word(speaker: part.speaker, start: time(from), end: time(i), text: String(characters[from..<i])))
                        wordStart = nil
                    } else if !blank, wordStart == nil {
                        wordStart = i
                    }
                }
                cursor = max(cursor, limit)
            }
            for run in runs where run.range.lowerBound >= lo && run.range.lowerBound < hi && run.range.lowerBound >= cursor {
                uncovered(upTo: run.range.lowerBound)
                let upper = min(run.range.upperBound, hi)
                guard upper > run.range.lowerBound else { continue }
                out.append(Word(speaker: part.speaker, start: run.start, end: run.end, text: String(characters[run.range.lowerBound..<upper])))
                cursor = upper
            }
            uncovered(upTo: hi)
        }
        return out
    }
}
