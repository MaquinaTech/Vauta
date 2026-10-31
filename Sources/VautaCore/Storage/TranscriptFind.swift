// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Find in a meeting (⌘F, ⌘G): the places of a text in a transcript, in order, and the moves between them. As a Mac app's Find does it:
/// the text as typed, anywhere in a word ("presup" finds "presupuesto"), case, accents and width ignored, so it also finds what the
/// meeting search would not (a function word, part of a code). Pure: the window draws the marks and scrolls.
public enum TranscriptFind {
    public struct Match: Sendable, Hashable {
        public let segment: Int64
        public let range: Range<String.Index>
    }

    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// The places of `query` (trimmed) in the lines, in their order and within each line, at most `limit`; none for an empty query.
    public static func matches(of query: String, in lines: [(id: Int64, text: String)], limit: Int = 5_000) -> [Match] {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return [] }
        var out: [Match] = []
        for line in lines {
            var from = line.text.startIndex
            while from < line.text.endIndex, let found = line.text.range(of: wanted, options: options, range: from..<line.text.endIndex) {
                out.append(Match(segment: line.id, range: found))
                if out.count == limit { return out }
                // A match never overlaps the one before it ("aa" in "aaa" is found once).
                from = found.upperBound > found.lowerBound ? found.upperBound : line.text.index(after: found.lowerBound)
            }
        }
        return out
    }

    /// The ranges of one line among `matches`, for its marks.
    public static func ranges(of segment: Int64, in matches: [Match]) -> [Range<String.Index>] {
        matches.filter { $0.segment == segment }.map(\.range)
    }

    /// The match to go to from `current` (nil: none chosen yet), forward (⌘G) or back (⇧⌘G), wrapping around at either end. With none
    /// chosen, forward starts at the first match of `from` or after it in `order` (the passage highlighted, so finding goes on from
    /// where the person is), back at the last one before it. nil when there are no matches.
    public static func step(from current: Int?, forward: Bool, in matches: [Match], from segment: Int64? = nil, order: [Int64] = []) -> Int? {
        guard !matches.isEmpty else { return nil }
        if let current, matches.indices.contains(current) {
            return forward ? (current + 1) % matches.count : (current - 1 + matches.count) % matches.count
        }
        guard let segment, let here = order.firstIndex(of: segment) else { return forward ? 0 : matches.count - 1 }
        let place = Dictionary(order.enumerated().map { ($1, $0) }) { a, _ in a }
        if forward { return matches.firstIndex { (place[$0.segment] ?? .max) >= here } ?? 0 }
        return matches.lastIndex { (place[$0.segment] ?? .min) < here } ?? matches.count - 1
    }
}
