// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// A question that goes on from the one answered before it ("And who owns it?", "¿Y para cuándo?"): Ask reads it together with the
/// earlier question, so search finds the passages the two are about, and the time or meetings the earlier one named carry over when the
/// new one names none. The answer is still written and checked for this one request (no conversation is sent); the context lives in
/// memory for the next question only and is never stored.
public struct AskFollowUp: Sendable, Equatable {
    /// The earlier questions, oldest first: at most `depth`, so a long thread does not drown the new question.
    public let questions: [String]

    public static let depth = 2

    public init(questions: [String]) {
        self.questions = Array(questions.suffix(Self.depth))
    }

    /// The context for the question after `question`, which was read with `previous` when it followed up.
    public static func after(_ question: String, previous: AskFollowUp?) -> AskFollowUp {
        AskFollowUp(questions: (previous?.questions ?? []) + [question])
    }

    /// The question before this one, for the control under the question.
    public var last: String { questions.last ?? "" }

    /// What search and the model read: the earlier questions, then this one.
    public func reading(_ question: String) -> String {
        (questions + [question]).joined(separator: " ")
    }

    /// The earlier questions alone, where a time or a place the new question does not name is read.
    public var context: String { questions.joined(separator: " ") }

    /// Whether a question reads as going on from the one before: it starts with a word that continues ("and…", "¿y…", "et…",
    /// "und…", "それで…", "그럼…", "那…"), or it is short and points back ("Who owns it?", "¿Quién lo lleva?", "Wer macht das?").
    /// Only the words of `languages` are looked for. A question that names its own subject at length is asked on its own.
    public static func continues(_ question: String, languages: [String]) -> Bool {
        let text = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "¿¡\"“”«»'‘’")))
        guard !text.isEmpty else { return false }
        let lexicons = languages.compactMap { Locale(identifier: $0).language.languageCode?.identifier }.compactMap { words[$0] }
        if text.contains(where: TextKeys.isNoSpaceScript) {
            // Japanese, Korean and Chinese: by the start of the question, and short questions by a word that points back.
            let cjk = lexicons.filter(\.noSpaces)
            if cjk.contains(where: { lexicon in lexicon.starts.contains { text.hasPrefix($0) } }) { return true }
            return text.count <= 14 && cjk.contains { lexicon in lexicon.pointers.contains { text.contains($0) } }
        }
        let tokens = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" }).map(String.init)
        guard let first = tokens.first else { return false }
        let opening = tokens.prefix(3).joined(separator: " ")
        for lexicon in lexicons where !lexicon.noSpaces {
            if lexicon.starts.contains(first) || lexicon.openings.contains(where: { opening.hasPrefix($0) })
                || lexicon.startStems.contains(where: { first.hasPrefix($0) }) { return true }
            if tokens.count <= 7 {
                if tokens.contains(where: lexicon.pointers.contains) { return true }
                if tokens.contains(where: { token in lexicon.pointerStems.contains { token.hasPrefix($0) } }) { return true }
                if let last = tokens.last, lexicon.lastPointers.contains(last) { return true }
            }
        }
        return false
    }

    struct Lexicon {
        /// A first word that continues the question before ("and", "but").
        var starts: Set<String> = []
        /// The first words of a continuation that is a phrase ("what about"), as the question is split into words ("qu en est-il").
        var openings: [String] = []
        /// A word that points back, anywhere in a short question ("it", "eso").
        var pointers: Set<String> = []
        /// A word that points back only as the last word, because elsewhere it is an article ("das", "la").
        var lastPointers: Set<String> = []
        /// Korean: the stems of those words, which carry their particle ("그것은", "거기서").
        var startStems: [String] = []
        var pointerStems: [String] = []
        var noSpaces = false
    }

    static let words: [String: Lexicon] = [
        "en": Lexicon(starts: ["and", "but", "also", "so", "then", "plus"],
                      openings: ["what about", "how about", "what else"],
                      pointers: ["it", "that", "this", "they", "them", "those", "these", "he", "she", "him", "her", "there"]),
        "es": Lexicon(starts: ["y", "e", "pero", "también", "entonces", "además"],
                      openings: ["qué hay de", "qué pasa con", "y qué", "algo más"],
                      pointers: ["eso", "esto", "ello", "él", "ella", "ellos", "ellas", "lo", "le", "les", "ahí", "allí"],
                      lastPointers: ["la", "las", "los"]),
        "fr": Lexicon(starts: ["et", "mais", "aussi", "alors", "donc", "puis"],
                      openings: ["et pour", "qu en est-il", "quoi d autre"],
                      pointers: ["ça", "cela", "ceci", "il", "elle", "ils", "elles", "lui", "leur"],
                      lastPointers: ["le", "la", "les"]),
        "de": Lexicon(starts: ["und", "aber", "auch", "also", "dann", "außerdem"],
                      openings: ["was ist mit", "wie ist es mit", "was noch"],
                      pointers: ["es", "er", "ihn", "ihm", "dies", "dafür", "davon", "darüber", "dazu", "dort"],
                      lastPointers: ["das", "sie", "die"]),
        "it": Lexicon(starts: ["e", "ed", "ma", "anche", "allora", "quindi", "poi"],
                      openings: ["e per", "che mi dici di", "cos altro"],
                      pointers: ["questo", "quello", "ciò", "lui", "lei", "loro", "lì"],
                      lastPointers: ["lo", "la", "li", "le"]),
        "pt": Lexicon(starts: ["e", "mas", "também", "então", "além"],
                      openings: ["e quanto", "e sobre", "que mais"],
                      pointers: ["isso", "isto", "aquilo", "ele", "ela", "eles", "elas", "lá", "dele", "dela"],
                      lastPointers: ["o", "a", "os", "as"]),
        "ja": Lexicon(starts: ["それで", "それでは", "では", "じゃあ", "あと", "それと", "それから", "ほかに", "他に", "その"],
                      pointers: ["それ", "その", "そこ", "あれ", "彼", "彼女"], noSpaces: true),
        "ko": Lexicon(starts: ["또", "그"],
                      startStems: ["그럼", "그러면", "그리고", "그래서", "그런데", "그건", "그것", "그거", "그분", "거기"],
                      pointerStems: ["그것", "그거", "거기", "그분", "그건"]),
        "zh": Lexicon(starts: ["那", "那么", "还有", "另外", "此外", "而且", "它"],
                      pointers: ["它", "那个", "这个", "那里", "他们", "她", "他"], noSpaces: true),
    ]
}
