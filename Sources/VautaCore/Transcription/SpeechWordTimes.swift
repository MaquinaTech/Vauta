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

    /// Every run with a time range and some text, with the recognizer's confidence when it was asked for it
    /// (`.transcriptionConfidence`). For the evaluation of public audio (`transcribeFileScored`).
    static func words(in text: AttributedString) -> [RecognizedWord] {
        text.runs.compactMap { run in
            guard let range = run.audioTimeRange, range.start.isNumeric, range.end.isNumeric, range.end.seconds >= range.start.seconds else { return nil }
            let word = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { return nil }
            return RecognizedWord(text: word, start: range.start.seconds, end: range.end.seconds,
                                  confidence: run.transcriptionConfidence.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil })
        }
    }
}

/// A word (or phrase) of a final result with its time and the recognizer's confidence (0...1, nil when not asked for or not
/// given). Evaluation only: the app does not ask the recognizer for confidence, and nothing stores it.
public struct RecognizedWord: Sendable, Equatable, Codable {
    public var text: String
    public var start: Double
    public var end: Double
    public var confidence: Double?

    public init(text: String, start: Double, end: Double, confidence: Double?) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}
