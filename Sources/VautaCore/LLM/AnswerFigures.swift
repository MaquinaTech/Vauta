// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The figures of an Ask answer's sentence, checked against what the model was given. Each claim's figures are checked against the
/// segments that hold its quote (`VautaPrompts.verifyAnswer`); the sentence is checked against everything the model read (the passages
/// with their headings and times, the documents, the question): a true figure from another passage is common and no reason to doubt
/// the answer, a figure from none of them is. On 1,749 archived verified answers this flagged 6, half of them wrong figures.
extension VerifiedAnswer {
    /// The same answer with `unbackedFigures` set from `seen` (the text of the request). `languages`: the transcripts' and the answer's,
    /// for figures said in words ("at five" for "5:00").
    public func checkingFigures(against seen: String, languages: [String]) -> VerifiedAnswer {
        guard found, !notYet, !answer.isEmpty else { return self }
        let missing = MinutesVerifier.unbackedFigures(item: AnswerFigures.comparable(answer), segment: seen, spokenIn: languages)
        guard missing != unbackedFigures else { return self }
        return VerifiedAnswer(answer: answer, claims: claims, found: found, withheld: withheld, cutShort: cutShort, notYet: notYet,
                              touchesOnly: touchesOnly, droppedClaims: droppedClaims, unbackedFigures: missing)
    }
}

enum AnswerFigures {
    /// The sentence as its figures are compared: a whole hour loses its ":00" ("at 5:00 PM" is "at five").
    static func comparable(_ text: String) -> String {
        text.replacing(/\b(\d{1,2})[:.]00\b/) { String($0.output.1) }
    }
}

extension MinutesVerifier {
    /// The figures of `item` that `segment` does not hold, compared as `figuresAreInSegment` compares them (digits, Han numerals, and
    /// in `languages` the words that say them), each written as `item` writes it, once.
    static func unbackedFigures(item: String, segment: String, spokenIn languages: [String] = []) -> [String] {
        let text = removingSpeakerLabels(item)
        let wanted = figures(in: text) + hanFigures(in: text, skippingIndefiniteOne: true).sorted()
        guard !wanted.isEmpty else { return [] }
        let have = Set(figures(in: segment)).union(hanFigures(in: segment))
        var missing = wanted.filter { !have.contains($0) }
        if !missing.isEmpty, !languages.isEmpty {
            let words = spelledWords(segment)
            missing = missing.filter { !isSpelled($0, in: words, languages: languages) }
        }
        var seen = Set<String>(), out: [String] = []
        for key in missing where seen.insert(key).inserted { out.append(written(key, in: text)) }
        return out
    }

    /// How `text` writes the figure whose key is `key` ("1,500" for 1500); the key itself when it is not written with digits.
    private static func written(_ key: String, in text: String) -> String {
        let regex = /\d(?:[\d,.'\u{00A0}\u{202F}]*\d)?/
        for match in text.matches(of: regex) where figures(in: String(match.output)) == [key] { return String(match.output) }
        return key
    }
}
