// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
internal import NaturalLanguage

/// Spots translations that went into a loop. Apple's high-fidelity models
/// sometimes end a longer English → Spanish text with a run of "¡¡¡¡…" or
/// "¿¿¿¿…" and drop the rest (4 of 40 conversational segments in our
/// benchmark); a caption must never show that, and it must never be stored.
enum TranslationOutputCheck {
    /// A run of one character at least this long, and longer than any run in
    /// the source, is a loop. Digits and spaces don't count ("1000000").
    static let characterRun = 6
    /// The same word this many times in a row, more than in the source.
    static let wordRun = 4

    /// Whether `output` looks like a loop rather than a translation of `source`.
    static func isDegenerate(_ output: String, source: String) -> Bool {
        let chars = longestCharacterRun(output)
        if chars.length >= characterRun, chars.length > longestCharacterRun(source).length + 2 { return true }
        let words = longestWordRun(output)
        if words.length >= wordRun, words.length > longestWordRun(source).length { return true }
        // A runaway: far longer than any language pair expands a text.
        return output.count > source.count * 6 + 40
    }

    /// `output` without its loop: cut where the repetition starts, and drop the
    /// opening marks left dangling ("¡", "¿", quotes, brackets).
    static func trimmed(_ output: String, source: String) -> String {
        var cut = output.endIndex
        let chars = longestCharacterRun(output)
        if chars.length >= characterRun, chars.length > longestCharacterRun(source).length + 2 { cut = min(cut, chars.start) }
        let words = longestWordRun(output)
        if words.length >= wordRun, words.length > longestWordRun(source).length { cut = min(cut, words.secondStart) }
        var text = String(output[..<cut])
        let dangling = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "¡¿«‹“‘\"'([{「『（"))
        while let last = text.unicodeScalars.last, dangling.contains(last) { text.unicodeScalars.removeLast() }
        return text
    }

    /// The sentences of `text`, for translating them one by one.
    static func sentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { out.append(sentence) }
            return true
        }
        return out
    }

    private static func longestCharacterRun(_ text: String) -> (length: Int, start: String.Index) {
        var best = (length: 0, start: text.endIndex)
        var current = (length: 0, start: text.startIndex)
        var previous: Character?
        for index in text.indices {
            let character = text[index]
            if character == previous {
                current.length += 1
            } else {
                current = (1, index)
                previous = character
            }
            let counts = !character.isWhitespace && !character.isNumber
            if counts, current.length > best.length { best = current }
        }
        return best
    }

    /// The longest run of one word repeated, and where its second occurrence
    /// starts (the first one is kept when trimming).
    private static func longestWordRun(_ text: String) -> (length: Int, secondStart: String.Index) {
        var best = (length: 0, secondStart: text.endIndex)
        var run = 0
        var previous: Substring?
        var secondStart = text.endIndex
        var searchFrom = text.startIndex
        for raw in text.split(whereSeparator: \.isWhitespace) {
            let word = raw.trimmingCharacters(in: .punctuationCharacters).lowercased()
            let start = text.range(of: raw, range: searchFrom..<text.endIndex)?.lowerBound ?? searchFrom
            searchFrom = text.index(start, offsetBy: raw.count, limitedBy: text.endIndex) ?? text.endIndex
            if !word.isEmpty, let previous, word == previous {
                run += 1
                if run == 2 { secondStart = start }
            } else {
                run = 1
                secondStart = text.endIndex
            }
            previous = word.isEmpty ? nil : Substring(word)
            if run > best.length { best = (run, run >= 2 ? secondStart : text.endIndex) }
        }
        return best
    }
}

/// Wraps a translator so a looping output is repaired before anyone sees it:
/// the text is translated again sentence by sentence (the loops come with
/// longer, multi-sentence texts), and whatever still loops is cut where the
/// loop starts. An output with nothing usable left comes back empty, which the
/// live translator neither shows as a translation nor stores.
struct GuardedTranslator: Translator {
    let inner: any Translator
    /// Joins sentences translated one by one: no space for Chinese and Japanese.
    let joiner: String

    init(_ inner: any Translator, target: Locale.Language) {
        self.inner = inner
        let code = target.languageCode?.identifier
        joiner = (code == "zh" || code == "ja") ? "" : " "
    }

    func translate(_ text: String) async throws -> String {
        let output = try await inner.translate(text)
        return try await repaired(output, source: text)
    }

    func translate(batch: [String]) async throws -> [String] {
        let outputs = try await inner.translate(batch: batch)
        var repairedOutputs: [String] = []
        repairedOutputs.reserveCapacity(outputs.count)
        for (source, output) in zip(batch, outputs) {
            repairedOutputs.append(try await repaired(output, source: source))
        }
        return repairedOutputs
    }

    private func repaired(_ output: String, source: String) async throws -> String {
        guard TranslationOutputCheck.isDegenerate(output, source: source) else { return output }
        let sentences = TranslationOutputCheck.sentences(source)
        guard sentences.count > 1 else { return TranslationOutputCheck.trimmed(output, source: source) }
        var parts: [String] = []
        for sentence in sentences {
            try Task.checkCancellation()
            let part = try await inner.translate(sentence)
            let clean = TranslationOutputCheck.isDegenerate(part, source: sentence)
                ? TranslationOutputCheck.trimmed(part, source: sentence) : part
            if !clean.isEmpty { parts.append(clean) }
        }
        return parts.joined(separator: joiner)
    }
}
