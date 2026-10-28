// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// What a caption's translation and original show together when the translation is cut to `lineLimit` lines: the two
/// start at the same place. Used by the row that draws them and by the stack that reserves their height.
struct CaptionPairLayout {
    var translation: String
    var original: String
    /// The lines the original may take.
    var originalLines: Int
    /// The translation is whole sentences but their original does not fit beside them: no original is shown.
    var dropsOriginal = false
}

enum CaptionPairing {
    struct Context {
        var width: CGFloat
        /// What the translation gives up of the width (the column of a speaker's name); the original has the whole width.
        var inset: CGFloat = 0
        var size: CaptionTextSize
        var isRightToLeft: Bool
        var isOriginalRightToLeft: Bool
        var sourceLanguage: Locale.Language?
        var targetLanguage: Locale.Language?

        /// The width the original has: it starts at the translation's own edge (after the speaker column) when both are
        /// written in the same direction, and has the whole row otherwise.
        var originalWidth: CGFloat { isRightToLeft == isOriginalRightToLeft ? max(1, width - inset) : width }
    }

    /// The most lines an original takes beside whole sentences of the translation (as many as an uncut caption shows).
    static let wholeSentenceLines = 2

    /// What the pair shows. When one of them is cut to its last sentences, the other loses the same number of sentences,
    /// and when the translation is cut under an ellipsis, the original keeps about the same share of its words under an
    /// ellipsis too, so neither carries a sentence the other lacks. A translation that is whole sentences gets as many
    /// lines of original as those sentences need (up to `wholeSentenceLines`); where even that does not fit, the original
    /// is dropped rather than shown as a fragment under whole sentences.
    static func layout(translation fullTranslation: String, original fullOriginal: String, lineLimit: Int?, originalLines: Int,
                       showOriginal: Bool, _ c: Context) -> CaptionPairLayout {
        var translation = fullTranslation
        if let lineLimit, c.width > 0, !c.isRightToLeft {
            translation = CaptionTail.lastLines(of: fullTranslation, lines: lineLimit, width: max(1, c.width - c.inset), points: c.size.points,
                                                language: c.targetLanguage)
        }
        func tail(_ text: String, lines: Int) -> String {
            guard c.width > 0, !c.isOriginalRightToLeft else { return text }
            return CaptionTail.lastLines(of: text, lines: lines, width: c.originalWidth, points: c.size.originalPoints, weight: .regular,
                                         language: c.sourceLanguage)
        }
        guard showOriginal, !fullTranslation.isEmpty, c.width > 0, !c.isRightToLeft, !c.isOriginalRightToLeft else {
            return CaptionPairLayout(translation: translation, original: showOriginal ? tail(fullOriginal, lines: originalLines) : fullOriginal,
                                     originalLines: originalLines)
        }
        var original = fullOriginal
        var wholeSentences = false
        if translation != fullTranslation {
            if translation.hasPrefix("…") {
                let kept = String(translation.dropFirst())
                if let dropped = CaptionTail.sentencesDropped(by: kept, from: fullTranslation) {
                    // The translation starts at a sentence: the original drops the same whole sentences, marked the same way.
                    let rest = CaptionTail.droppingSentences(dropped, of: original)
                    original = rest
                    wholeSentences = true
                } else {
                    original = CaptionTail.keepingShare(of: original, share: Double(translation.count - 1) / Double(max(1, fullTranslation.count)))
                }
            } else {
                let dropped = CaptionTail.sentenceCount(of: fullTranslation) - CaptionTail.sentenceCount(of: translation)
                original = CaptionTail.droppingSentences(dropped, of: original)
                wholeSentences = true
            }
        }
        var lines = originalLines
        if wholeSentences, lineLimit != nil {
            lines = max(originalLines, wholeSentenceLines)
            let needed = CaptionTail.lineCount(of: original, width: c.originalWidth, points: c.size.originalPoints, weight: .regular, language: c.sourceLanguage)
            if needed > lines { return CaptionPairLayout(translation: translation, original: original, originalLines: 0, dropsOriginal: true) }
        }
        let cut = tail(original, lines: lines)
        if translation == fullTranslation, !cut.hasPrefix("…"), cut != original {
            // Only the original was cut, at a sentence: the translation starts at the same sentence.
            let dropped = CaptionTail.sentenceCount(of: original) - CaptionTail.sentenceCount(of: cut)
            translation = CaptionTail.droppingSentences(dropped, of: translation)
        }
        return CaptionPairLayout(translation: translation, original: cut, originalLines: lines)
    }
}

/// The end of a caption that is taller than the room: the last words that fit in `lines` lines. It starts at the
/// beginning of a sentence when the last sentence fits (no ellipsis: it is a clean cut), otherwise at a word, after an
/// ellipsis; never on punctuation ("…? Reportons").
enum CaptionTail {
    /// A word joiner after a leading ellipsis, so the line may not break between "…" and the word: the ellipsis never ends
    /// a line on its own.
    static func joiningEllipsis(_ text: String) -> String {
        text.hasPrefix("…") && !text.hasPrefix("…\u{2060}") ? "…\u{2060}" + text.dropFirst() : text
    }

    /// How many lines `text` takes at `width`, measured in the script of the text.
    static func lineCount(of text: String, width: CGFloat, points: CGFloat, weight: NSFont.Weight = .semibold,
                          language: Locale.Language? = nil) -> Int {
        let font = NSFont.systemFont(ofSize: points, weight: weight)
        let script = language.flatMap(CaptionText.unspacedScript)
        func height(_ string: String) -> CGFloat {
            let laidOut = script?.protecting(string) ?? string
            return (laidOut as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                      options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
        }
        return max(1, Int((height(text) / max(1, height(CaptionText.probe(for: text)))).rounded()))
    }

    static func lastLines(of text: String, lines: Int, width: CGFloat, points: CGFloat, weight: NSFont.Weight = .semibold,
                          language: Locale.Language? = nil) -> String {
        let font = NSFont.systemFont(ofSize: points, weight: weight)
        let script = language.flatMap(CaptionText.unspacedScript)
        func measured(_ string: String) -> CGSize {
            let laidOut = script?.protecting(string) ?? string
            return (laidOut as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                      options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).size
        }
        // The line is measured in the script of the text: Japanese lines are taller than Latin ones.
        let lineHeight = measured(CaptionText.probe(for: text)).height
        func lineCount(_ string: String) -> Int { max(1, Int((measured(string).height / lineHeight).rounded())) }
        guard lineCount(text) > lines else { return text }

        let allStarts = wordStarts(of: text, wholeWordsOnly: false)
        guard !allStarts.isEmpty else { return text }
        // Japanese has no spaces: the tail starts at a word (after a clause mark or a particle), never inside a run of kanji.
        let wordsOnly = wordStarts(of: text, wholeWordsOnly: true)
        let starts = wordsOnly.isEmpty ? allStarts : wordsOnly
        /// The first of `candidates` (the most text kept) whose text, after `prefix`, fits.
        func firstFitting(_ candidates: [String.Index], prefix: String) -> String.Index? {
            guard let last = candidates.last, lineCount(prefix + text[last...]) <= lines else { return nil }
            var low = 0, high = candidates.count - 1
            while low < high {
                let mid = (low + high) / 2
                if lineCount(prefix + text[candidates[mid]...]) <= lines { high = mid } else { low = mid + 1 }
            }
            return candidates[low]
        }
        let sentenceStarts = starts.filter { isSentenceStart($0, in: text) }
        // The tail starts at a sentence whenever the last sentence(s) fit the lines given, with no fragment of the sentence
        // before it; only when even the last sentence is too long does the tail start at a word under an ellipsis.
        if let start = firstFitting(sentenceStarts, prefix: "") { return String(text[start...]) }
        if let start = firstFitting(starts, prefix: "…") ?? firstFitting(allStarts, prefix: "…") { return "…" + text[start...] }
        return "…" + text[starts[starts.count - 1]...]
    }

    /// The positions where a sentence of `text` begins (the first one included): after a full stop, question or
    /// exclamation mark and a space (and not before a lowercase letter, as in "e.g. this"), or right after a
    /// full-width one, which leaves no space.
    static func sentenceStarts(in text: String) -> [String.Index] {
        var out = [text.startIndex]
        let enders: Set<Character> = [".", "?", "!", "。", "？", "！"]
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if enders.contains(character), next < text.endIndex {
                var after = next
                while after < text.endIndex, text[after] == " " || text[after] == "\u{00A0}" { after = text.index(after: after) }
                let fullWidth = "。？！".contains(character)
                if after < text.endIndex, fullWidth || after > next, !text[after].isLowercase { out.append(after) }
            }
            index = next
        }
        return out
    }

    /// How many whole sentences of `full` come before `tail`, when `tail` is its end and starts at a sentence (nil when
    /// it starts inside one, or is not its end).
    static func sentencesDropped(by tail: String, from full: String) -> Int? {
        guard !tail.isEmpty, tail != full, full.hasSuffix(tail) else { return nil }
        let start = full.index(full.endIndex, offsetBy: -tail.count)
        return sentenceStarts(in: full).firstIndex(of: start)
    }

    static func sentenceCount(of text: String) -> Int { sentenceStarts(in: text).count }

    /// `text` without its first `count` sentences (all of it when it has fewer than that many plus one).
    static func droppingSentences(_ count: Int, of text: String) -> String {
        let starts = sentenceStarts(in: text)
        guard count > 0, count < starts.count else { return text }
        return String(text[starts[count]...])
    }

    /// About `share` of the end of `text`, from a word, under an ellipsis (the whole text when the share is nearly all of it).
    static func keepingShare(of text: String, share: Double) -> String {
        guard share < 0.95 else { return text }
        let target = Int((Double(text.count) * (1 - share)).rounded())
        let starts = wordStarts(of: text, wholeWordsOnly: true)
        let candidates = starts.isEmpty ? wordStarts(of: text, wholeWordsOnly: false) : starts
        guard let start = candidates.first(where: { text.distance(from: text.startIndex, to: $0) >= target }) else { return text }
        return "…" + text[start...]
    }

    private static let closing: Set<Character> = Set("?!.,;:)]}»”’…、。，．！？；：）］｝」』〉》%")
    private static let sentenceEnd: Set<Character> = Set(".?!。？！…")

    /// Where the shown part may begin: after a space (or at any character when the text has no spaces), never on
    /// closing punctuation or a character that may not start a line.
    private static func wordStarts(of text: String, wholeWordsOnly: Bool) -> [String.Index] {
        let spaced = text.contains(" ")
        let japanese = wholeWordsOnly && text.unicodeScalars.contains { (0x3040...0x309F).contains($0.value) }
        func isKana(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { (0x3040...0x309F).contains($0.value) } }
        func isHan(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { (0x30A0...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) } }
        var out: [String.Index] = []
        for index in text.indices.dropFirst() {
            let character = text[index]
            if spaced {
                guard text[text.index(before: index)] == " ", character != " " else { continue }
            }
            if closing.contains(character) || CaptionText.UnspacedScript.japanese.cannotStartLine(character) { continue }
            if japanese {
                let previous = text[text.index(before: index)]
                // Inside a run of kanji or katakana ("金|曜日") or of hiragana, a start would cut a word.
                if isHan(character), isHan(previous) { continue }
                if isKana(character), isKana(previous) { continue }
                if isKana(character), isHan(previous), !"、。，".contains(previous) { continue }
            }
            out.append(index)
        }
        return out
    }

    /// The start of a sentence: the character before it (ignoring spaces) ends one.
    private static func isSentenceStart(_ index: String.Index, in text: String) -> Bool {
        var before = index
        while before > text.startIndex {
            before = text.index(before: before)
            if text[before] == " " || text[before] == "\u{00A0}" { continue }
            return sentenceEnd.contains(text[before])
        }
        return false
    }
}

/// Caption text tagged with the language it is written in, so lines break by that language's rules: Japanese and
/// Chinese text is laid out by the language of the caption, not by the language of the app. Latin text is left
/// untagged (a tag would also switch hyphenation on).
enum CaptionText {
    static func view(_ string: String, language: Locale.Language?) -> Text {
        guard let language, Self.unspacedScript(language) != nil else { return Text(verbatim: string) }
        return Text(attributed(string, language: language))
    }

    /// The same text as an attributed string, to put something before it in the same line.
    static func attributed(_ string: String, language: Locale.Language?) -> AttributedString {
        guard let language, let script = Self.unspacedScript(language) else { return AttributedString(string) }
        var text = AttributedString(script.protecting(string))
        text.languageIdentifier = language.minimalIdentifier
        return text
    }

    /// What one line is measured with: "Ag" and, for text in another script, its first character, so the line has
    /// the height of that script's lines (Japanese, Chinese and Korean fall back to a taller font).
    static func probe(for text: String) -> String {
        let other = text.first { character in character.unicodeScalars.contains { $0.value >= 0x2E80 } }
        return "Ag" + (other.map(String.init) ?? "")
    }

    enum UnspacedScript {
        case japanese, chinese, korean

        /// A small kana, the long-vowel mark or the iteration mark: a line never starts with it.
        func cannotStartLine(_ character: Character) -> Bool { Self.noLineStart.contains(character) }

        /// Word joiners where a line must not break: before a small kana, the long-vowel mark and the iteration mark
        /// (Japanese), and after a demonstrative (这, 那, 每, 该) so it stays with its measure word (Chinese).
        func protecting(_ string: String) -> String {
            let joiner: Character = "\u{2060}"
            if self == .korean { return Self.tyingBoundNouns(string) }
            let characters = Array(string)
            guard characters.count > 1 else { return string }
            let tiedEnding = self == .japanese ? Self.sentenceEndings(in: characters).union(Self.inflections(in: characters)) : []
            var out = ""
            for (index, character) in characters.enumerated() {
                if index > 0, tiedEnding.contains(index) || needsJoinerBefore(character, after: characters[index - 1]) {
                    out.append(joiner)
                }
                out.append(character)
            }
            return out
        }

        /// Positions that get a joiner before them so a Japanese sentence never ends with a stray run of kana: the
        /// last hiragana before 。！？ (up to five) stay together, so the verb ending "しましょう。" moves as one unit.
        private static func sentenceEndings(in characters: [Character]) -> Set<Int> {
            func isHiragana(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { (0x3041...0x309F).contains($0.value) } }
            var positions = Set<Int>()
            for (index, character) in characters.enumerated() where "。！？".contains(character) && index > 0 {
                var start = index
                while start > 0, index - start < 5, isHiragana(characters[start - 1]) { start -= 1 }
                guard start < index else { continue }
                // The kanji stem before them ("延期" of "延期しましょう") stays too, so the verb is never cut.
                var stem = start
                while stem > 0, start - stem < 3, (0x3400...0x9FFF).contains(characters[stem - 1].unicodeScalars.first?.value ?? 0) { stem -= 1 }
                start = stem
                // A particle before the stem ("に延期") stays with the word before it (a line never starts with a particle);
                // the line may still break after it, so a long phrase never becomes one chunk too wide for the line.
                if start > 0, "でをにがはもと".contains(characters[start - 1]) { positions.insert(start - 1) }
                for position in (start + 1)...index { positions.insert(position) }
            }
            return positions
        }

        /// Hiragana that follow a kanji (okurigana and inflection: "確認する", "延期し") stay with it, up to three, so a
        /// line never starts with "る" or "し". A particle after a kanji is tied the same way.
        private static func inflections(in characters: [Character]) -> Set<Int> {
            func isHiragana(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { (0x3041...0x309F).contains($0.value) } }
            func isKanji(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains($0.value) } }
            var positions = Set<Int>()
            for index in characters.indices where isKanji(characters[index]) {
                guard index + 1 < characters.count, isHiragana(characters[index + 1]) else { continue }
                // The kanji stem before the hiragana (up to three) is one word with them: "確認する" is never cut.
                var stem = index
                while stem > 0, index - stem < 2, isKanji(characters[stem - 1]) { stem -= 1 }
                for position in stem..<index { positions.insert(position + 1) }
                var next = index + 1
                while next < characters.count, next - index <= 3, isHiragana(characters[next]) {
                    positions.insert(next)
                    next += 1
                }
            }
            return positions
        }

        /// Korean bound nouns (수, 것, 때, 줄, 데) stay with the word before them, and 있다/없다 after 수 with 수:
        /// "주실 수 있나요?" is not split. The spaces become no-break spaces.
        private static func tyingBoundNouns(_ string: String) -> String {
            let bound: Set<String> = ["수", "것", "때", "줄", "데"]
            let words = string.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard words.count > 1 else { return string }
            var out = words[0]
            for index in 1..<words.count {
                let word = words[index]
                let core = word.trimmingCharacters(in: .punctuationCharacters)
                let previousCore = words[index - 1].trimmingCharacters(in: .punctuationCharacters)
                let tied = !out.isEmpty && !word.isEmpty
                    && (bound.contains(core) || (previousCore == "수" && (word.hasPrefix("있") || word.hasPrefix("없"))))
                out += (tied ? "\u{00A0}" : " ") + word
            }
            return out
        }

        private func needsJoinerBefore(_ character: Character, after previous: Character) -> Bool {
            if previous == " " || previous == "\u{00A0}" || previous == "\u{2060}" { return false }
            switch self {
            case .japanese: return Self.noLineStart.contains(character) || Self.numberWithCounter(character, after: previous)
            case .chinese:
                return (Self.demonstratives.contains(previous) && character.unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains($0.value) })
                    || Self.numberWithCounter(character, after: previous)
            case .korean: return false
            }
        }

        /// A number stays with its counter ("3分", "2週") and with the ordinal mark before it ("第2").
        private static func numberWithCounter(_ character: Character, after previous: Character) -> Bool {
            if previous.isASCII, previous.isNumber {
                return character.unicodeScalars.allSatisfy { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) }
            }
            return previous == "第" && character.isASCII && character.isNumber
        }

        private static let noLineStart: Set<Character> = Set("ぁぃぅぇぉっゃゅょゎゕゖァィゥェォッャュョヮヵヶー々ゝゞヽヾ")
        private static let demonstratives: Set<Character> = Set("这那每该")
    }

    static func unspacedScript(_ language: Locale.Language) -> UnspacedScript? {
        switch language.languageCode?.identifier {
        case "ja": .japanese
        case "zh": .chinese
        case "ko": .korean
        default: nil
        }
    }
}
