// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
internal import NaturalLanguage

/// How many sentences Vauta checks as possible questions while recording. More means more model checks and more energy.
public enum QuestionSensitivity: String, Sendable, CaseIterable, Codable {
    case low, standard, high

    /// A sentence is a candidate when its cue score is at least this (see `QuestionCues`).
    public var threshold: Double {
        switch self {
        case .low: 0.80
        case .standard: 0.50
        case .high: 0.35
        }
    }
}

/// A sentence that looks like a question, with the cues that made it one.
public struct QuestionCandidate: Sendable, Equatable {
    public let text: String
    public let score: Double
    public let cues: [String]
    /// The language whose cues scored highest.
    public let language: CueLanguage?
    /// The whole utterance the sentence came from (a question is often split between two segments).
    public let utterance: String
    public var channel: Channel
    public var start: Double
    public var end: Double

    public init(text: String, score: Double, cues: [String], language: CueLanguage?, utterance: String, channel: Channel, start: Double, end: Double) {
        self.text = text
        self.score = score
        self.cues = cues
        self.language = language
        self.utterance = utterance
        self.channel = channel
        self.start = start
        self.end = end
    }
}

/// S1 of the live answers: scores each sentence of a final segment for how much it looks like a question, on the CPU, with no
/// model and no network. Pure and deterministic. The cues are the ones the interface languages need (`QuestionCues+Languages`).
public enum QuestionCues {
    /// The weights of the cues (the design's table).
    enum Weight {
        static let questionMark = 0.50, interrogative = 0.35, inversion = 0.25, embedded = 0.30, particle = 0.45
        static let tagOnly = -0.30, social = -0.60, opinion = -0.40, short = -0.30
    }

    /// A previous final segment of the same channel, for joining a question the transcriber split in two.
    public struct Previous: Sendable, Equatable {
        public let text: String
        public let end: Double
        public init(text: String, end: Double) { self.text = text; self.end = end }
    }

    /// A pause shorter than this joins a segment to the one before it when that one did not end a sentence.
    public static let joinGap = 1.5

    /// The best-scoring sentence of the segment (with the previous one joined when the transcriber split a question), or nil when
    /// there is no sentence. The score is not compared with a threshold here: `isCandidate` does that.
    public static func best(text: String, channel: Channel, start: Double, end: Double, previous: Previous?, meetingLocale: String) -> QuestionCandidate? {
        scored(text: text, channel: channel, start: start, end: end, previous: previous, meetingLocale: meetingLocale)
            .reduce(nil as QuestionCandidate?) { best, candidate in best == nil || candidate.score > best!.score ? candidate : best }
    }

    /// Every sentence of the segment (with the previous one joined when the transcriber split a question), each with its score: what
    /// `best` picks from, and what the evaluation labels.
    public static func scored(text: String, channel: Channel, start: Double, end: Double, previous: Previous?, meetingLocale: String) -> [QuestionCandidate] {
        let own = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !own.isEmpty else { return [] }
        var utterance = own
        var ownOffset = 0
        if let previous, start - previous.end < joinGap, start >= previous.end - 0.5, !endsSentence(previous.text) {
            let head = previous.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !head.isEmpty {
                utterance = head + " " + own
                ownOffset = head.count + 1
            }
        }
        let main = CueLanguage(identifier: meetingLocale)
        var out: [QuestionCandidate] = []
        for (sentence, upper) in sentences(of: utterance, language: main) {
            // A sentence that ended in the previous segment was judged then.
            if ownOffset > 0, upper <= ownOffset - 1 { continue }
            // A long run of clauses (speech recognition often leaves out the full stops) is cut to the clause that carries the cue.
            let focused = focus(sentence, main: main)
            let scored = score(sentence: focused, main: main)
            out.append(QuestionCandidate(text: focused, score: scored.score, cues: scored.cues, language: scored.language, utterance: utterance,
                                         channel: channel, start: start, end: end))
        }
        return out
    }

    /// The most a candidate sentence may be: a longer one is cut to the clause that carries the question (see `focus`).
    public static let maxCandidateCharacters = 160

    /// A sentence of more than `maxCandidateCharacters` cut to the part that asks: the clause that ends at the last question mark
    /// (from the opening "¿" or the clause break before it), or, with no mark, the first clause that carries an interrogative, embedded or
    /// other question cue (the beginning when none does). A clause
    /// that is still too long loses its first words. Shorter sentences are returned as they are.
    static func focus(_ sentence: String, main: CueLanguage? = nil) -> String {
        guard sentence.count > maxCandidateCharacters else { return sentence }
        let chars = Array(sentence)
        let marks: Set<Character> = ["?", "？", "؟"]
        var piece: [Character]
        if let last = chars.lastIndex(where: { marks.contains($0) }) {
            var start = 0
            var i = last - 1
            while i >= 0 {
                if chars[i] == "¿" { start = i; break }
                if ".!;:¡。！".contains(chars[i]), i < last - 1 { start = i + 1; break }
                i -= 1
            }
            piece = Array(chars[start...last])
            // Still too long: break at the commas, as late as the length allows.
            while piece.count > maxCandidateCharacters, let comma = piece.firstIndex(where: { $0 == "," || $0 == "，" || $0 == "、" }), comma + 1 < piece.count {
                piece = Array(piece[(comma + 1)...])
            }
            if piece.count > maxCandidateCharacters {
                let cut = piece.count - maxCandidateCharacters
                let space = piece[cut...].firstIndex(of: " ") ?? cut
                piece = Array(piece[min(space + 1, piece.count - 1)...])
            }
        } else {
            // No mark: start at the first clause that scores as a question, so a cue late in a long run is not cut off.
            var from = 0
            var offset = 0
            for clause in sentence.split(omittingEmptySubsequences: false, whereSeparator: { ",;:.，、。".contains($0) }) {
                if !Set(score(sentence: String(clause), main: main).cues).isDisjoint(with: ["interrogative", "embedded", "particle"]) { from = offset; break }
                offset += clause.count + 1
            }
            let tail = Array(chars[min(from, chars.count - 1)...])
            let head = Array(tail.prefix(maxCandidateCharacters))
            let space = tail.count > maxCandidateCharacters ? (head.lastIndex(of: " ") ?? head.count) : head.count
            piece = Array(head[0..<max(1, space)])
        }
        let text = String(piece).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? sentence : text
    }

    /// Whether the candidate passes the sensitivity's threshold.
    public static func isCandidate(_ candidate: QuestionCandidate, sensitivity: QuestionSensitivity) -> Bool {
        candidate.score + 1e-9 >= sensitivity.threshold
    }

    // MARK: Sentences

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return true }
        return ".?!。？！…".contains(last)
    }

    /// The sentences of the text with the character offset where each ends.
    static func sentences(of text: String, language: CueLanguage?) -> [(String, Int)] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        if let language { tokenizer.setLanguage(NLLanguage(rawValue: language.rawValue)) }
        var out: [(String, Int)] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { out.append((sentence, text.distance(from: text.startIndex, to: range.upperBound))) }
            return true
        }
        if out.isEmpty { out = [(text, text.count)] }
        return out
    }

    // MARK: Scoring

    struct Scored { var score: Double; var cues: [String]; var language: CueLanguage? }

    /// The score of one sentence: with the meeting language's cues and, when the sentence is clearly in another supported language,
    /// with that one's too (the higher wins).
    static func score(sentence: String, main: CueLanguage?) -> Scored {
        var result = main.map { score(sentence: sentence, language: $0) } ?? universal(sentence)
        if let other = otherLanguage(of: sentence, main: main) {
            let alternative = score(sentence: sentence, language: other)
            if alternative.score > result.score { result = alternative }
        }
        return result
    }

    /// A supported language other than `main` with confidence of at least 0.8 on a sentence of six words or more.
    static func otherLanguage(of sentence: String, main: CueLanguage?) -> CueLanguage? {
        let words = sentence.split(whereSeparator: { $0.isWhitespace }).count
        let spaceless = sentence.unicodeScalars.contains { TextKeys.isNoSpaceScript($0) }
        guard words >= 6 || (spaceless && sentence.count >= 12) else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sentence)
        guard let dominant = recognizer.dominantLanguage, let language = CueLanguage(identifier: dominant.rawValue), language != main,
              (recognizer.languageHypotheses(withMaximum: 1)[dominant] ?? 0) >= 0.8 else { return nil }
        return language
    }

    /// Only the cues that need no language: the punctuation.
    static func universal(_ sentence: String) -> Scored {
        var s = Scored(score: 0, cues: [], language: nil)
        if endsWithQuestionMark(sentence) { s.score += Weight.questionMark; s.cues.append("mark") }
        if wordCount(sentence, spaceless: false) < 4 { s.score += Weight.short; s.cues.append("short") }
        s.score = min(1, max(0, s.score))
        return s
    }

    static func endsWithQuestionMark(_ sentence: String) -> Bool {
        let trimmed = sentence.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'”’»)」』…")))
        guard let last = trimmed.last else { return false }
        return "?？؟".contains(last)
    }

    static func wordCount(_ text: String, spaceless: Bool) -> Int {
        spaceless ? text.filter { $0.isLetter || $0.isNumber }.count : text.split(whereSeparator: { $0.isWhitespace }).count
    }

    static func score(sentence: String, language: CueLanguage) -> Scored {
        let cues = CueSet.set(for: language)
        let folded = TextKeys.norm(sentence)
        var s = Scored(score: 0, cues: [], language: language)
        func add(_ weight: Double, _ name: String) { s.score += weight; s.cues.append(name) }
        let mark = endsWithQuestionMark(sentence) || (language == .es && sentence.hasPrefix("¿"))
        if mark { add(Weight.questionMark, "mark") }
        let spaceless = language.isSpaceless
        let words = folded.split(separator: " ").map(String.init)
        // Social checks and tags first: they pull the score down whatever else is there.
        let isSocial = cues.social.contains { contains(folded, $0, language: language) }
        if isSocial { add(Weight.social, "social") }
        let isTag = cues.tags.contains(folded) || (words.count <= 2 && words.allSatisfy { cues.tags.contains($0) } && !words.isEmpty)
        let interrogative = hasInterrogative(folded, words: words, cues: cues, language: language)
        let embedded = cues.embedded.contains { contains(folded, $0, language: language) }
        let particle = hasParticle(sentence, folded: folded, cues: cues, language: language, hasInterrogative: interrogative)
        if isTag && !interrogative && !embedded { add(Weight.tagOnly, "tag") }
        if interrogative { add(Weight.interrogative, "interrogative") }
        if embedded { add(Weight.embedded, "embedded") }
        if particle { add(Weight.particle, "particle") }
        if !interrogative, hasInversion(sentence, folded: folded, words: words, cues: cues, language: language) { add(Weight.inversion, "inversion") }
        if cues.opinion.contains(where: { contains(folded, $0, language: language) }) { add(Weight.opinion, "opinion") }
        if wordCount(spaceless || language.isCJK ? folded.replacingOccurrences(of: " ", with: "") : sentence, spaceless: spaceless || language.isCJK) < (language.isCJK ? 6 : 4) {
            add(Weight.short, "short")
        }
        s.score = min(1, max(0, s.score))
        return s
    }

    /// Whether the folded sentence holds the phrase as whole words (spaced scripts) or as a substring (the others).
    static func contains(_ folded: String, _ phrase: String, language: CueLanguage) -> Bool {
        if language.isCJK {
            return folded.replacingOccurrences(of: " ", with: "").contains(phrase.replacingOccurrences(of: " ", with: ""))
        }
        return (" " + folded + " ").contains(" " + phrase + " ")
    }

    /// Spaced scripts: an interrogative opens the sentence, after at most two discourse words. Others: anywhere.
    static func hasInterrogative(_ folded: String, words: [String], cues: CueSet, language: CueLanguage) -> Bool {
        if language.isCJK { return cues.interrogatives.contains { contains(folded, $0, language: language) } }
        var rest = words
        var skipped = 0
        while skipped < 2, let first = rest.first, cues.discourse.contains(first), rest.count > 1 { rest.removeFirst(); skipped += 1 }
        let opening = " " + rest.prefix(5).joined(separator: " ") + " "
        return cues.interrogatives.contains { opening.hasPrefix(" " + $0 + " ") }
    }

    static func hasParticle(_ sentence: String, folded: String, cues: CueSet, language: CueLanguage, hasInterrogative: Bool) -> Bool {
        guard language.isCJK else { return false }
        let compact = folded.replacingOccurrences(of: " ", with: "")
        if cues.particlePhrases.contains(where: { compact.contains($0) }) { return true }
        guard let particle = cues.particles.filter({ compact.hasSuffix($0) }).max(by: { $0.count < $1.count }) else { return false }
        // A bare "の" or "か" ends many statements: it needs the question mark or an interrogative word with it.
        if particle.count == 1, language == .ja { return endsWithQuestionMark(sentence) || hasInterrogative }
        if particle.count == 1, language == .ko, particle != "까" { return endsWithQuestionMark(sentence) || hasInterrogative }
        if particle.count == 1, language == .zh, particle == "吧" { return endsWithQuestionMark(sentence) }
        return true
    }

    /// The sentence opens with an auxiliary (inversion), or a tagger finds a verb first (es, fr, it, pt).
    static func hasInversion(_ sentence: String, folded: String, words: [String], cues: CueSet, language: CueLanguage) -> Bool {
        guard let first = words.first, words.count >= 3 else { return false }
        if cues.inversion.contains(first) {
            // "Have a look" and "Will you" differ: English auxiliaries need a pronoun or article next to count as an inversion.
            if language == .en { return words.count > 1 && ["i", "we", "you", "he", "she", "it", "they", "there", "this", "that", "the", "a", "anyone", "anybody", "everyone", "someone", "my", "our", "your"].contains(words[1]) }
            return true
        }
        guard cues.verbFirstTagger else { return false }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = sentence
        tagger.setLanguage(NLLanguage(rawValue: language.rawValue), range: sentence.startIndex..<sentence.endIndex)
        var firstTag: NLTag?
        tagger.enumerateTags(in: sentence.startIndex..<sentence.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
            firstTag = tag
            return false
        }
        // The verb opens a sentence that ends in a question mark in speech about as often as it opens an order: it only counts with the mark.
        return firstTag == .verb && endsWithQuestionMark(sentence)
    }
}
