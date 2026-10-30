// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CoreMedia
import Foundation
import Speech
import Testing
@testable import VautaCore

/// The word times and confidences read from a recognizer's result, built here by hand (no audio, no recognizer).
@Suite("Transcription: word times and confidence of a result")
struct SpeechWordTimesTests {
    private static func time(_ a: Double, _ b: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: a, preferredTimescale: 1000), end: CMTime(seconds: b, preferredTimescale: 1000))
    }

    /// " Send the deck." with "Send" and "deck." timed and scored, "the" timed only, the spaces untimed.
    private static func result() -> AttributedString {
        var text = AttributedString(" Send the deck.")
        let send = text.range(of: "Send")!, the = text.range(of: "the")!, deck = text.range(of: "deck.")!
        text[send].audioTimeRange = time(0.10, 0.42)
        text[send].transcriptionConfidence = 0.93
        text[the].audioTimeRange = time(0.42, 0.55)
        text[deck].audioTimeRange = time(0.55, 0.98)
        text[deck].transcriptionConfidence = 1.7
        return text
    }

    @Test func wordsCarryTheirTimeAndConfidence() {
        let words = SpeechWordTimes.words(in: Self.result())
        #expect(words.map(\.text) == ["Send", "the", "deck."])
        #expect(words.map(\.confidence) == [0.93, nil, 1], "a missing score stays missing; an impossible one is clamped")
        #expect(abs(words[0].start - 0.10) < 1e-9 && abs(words[2].end - 0.98) < 1e-9)
    }

    @Test func theRunsForTheAlignerAreUnchanged() {
        let runs = SpeechWordTimes.runs(in: Self.result(), trimmedTo: "Send the deck.")
        #expect(runs.map(\.range) == [0..<4, 5..<8, 9..<14])
    }

    @Test func aWordEncodesWithStableKeys() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let line = String(decoding: try encoder.encode(RecognizedWord(text: "deck", start: 0.5, end: 1, confidence: 0.25)), as: UTF8.self)
        #expect(line == #"{"confidence":0.25,"end":1,"start":0.5,"text":"deck"}"#)
    }
}
