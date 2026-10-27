// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CoreMedia
import Foundation
import Speech

/// The word times the speech recognizers attach to a result (`attributeOptions: [.audioTimeRange]`).
enum SpeechWordTimes {
    /// One run per recognised word or phrase that has a time range, with its place in `trimmed` (the result's text
    /// without the whitespace around it) in Characters. Runs outside the trimmed text or without time are dropped.
    static func runs(in text: AttributedString, trimmedTo trimmed: String) -> [AlignableSegment.Run] {
        let full = String(text.characters)
        let lead = full.count - full.drop(while: \.isWhitespace).count
        let limit = trimmed.count
        var out: [AlignableSegment.Run] = []
        for run in text.runs {
            guard let range = run.audioTimeRange, range.start.isNumeric, range.end.isNumeric else { continue }
            let lo = max(0, text.characters.distance(from: text.startIndex, to: run.range.lowerBound) - lead)
            let hi = min(limit, text.characters.distance(from: text.startIndex, to: run.range.upperBound) - lead)
            guard lo < hi, range.end.seconds >= range.start.seconds else { continue }
            out.append(AlignableSegment.Run(range: lo..<hi, start: range.start.seconds, end: range.end.seconds))
        }
        return out
    }
}
