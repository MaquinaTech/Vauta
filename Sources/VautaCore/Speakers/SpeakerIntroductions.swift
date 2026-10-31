// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// A speaker who says who they are ("Hi, I'm Ana", "Soy Ana, de Kobaltix", "私はアナです"): the name they give, read without a model in
/// the nine languages. It only proposes candidates: `MeetingStore.suggestSpeakersFromIntroductions` keeps a name only when it is a
/// person of Context, and then only suggests it ("Is this Ana?"); it never names a speaker.
///
/// Read only at the start of a clause, so "they told me I'm Ana's backup" or "what I am sure of" say nothing. A Latin-script name is the
/// capitalized words right after the cue (one to three, never a possessive: "I'm Ana's manager" is not Ana). "This is …" and "it's …"
/// introduce someone else as often as oneself, so they count only right after a greeting, as on a call ("Hi, this is Ana").
public enum SpeakerIntroductions {
    public struct Cue: Sendable, Equatable {
        /// The names it may give, longest first ("Ana García", "Ana").
        public let candidates: [String]
        /// The clause that says it, as the transcript has it.
        public let quote: String
    }

    /// The introductions in one line, in the languages given (BCP-47 or language codes).
    public static func cues(in text: String, languages: [String]) -> [Cue] {
        let codes = Set(languages.compactMap { Locale(identifier: $0).language.languageCode?.identifier })
        var out: [Cue] = []
        for clause in clauses(of: text) {
            let lowered = clause.lowercased()
            for code in codes.sorted() {
                guard let lexicon = lexicons[code] else { continue }
                if let cue = lexicon.spaced ? latin(clause, lowered: lowered, lexicon) : dense(clause, lexicon), !cue.candidates.isEmpty {
                    out.append(cue)
                    break
                }
            }
        }
        return out
    }

    // MARK: Clauses

    /// A line cut where a clause ends; the greeting that opens one stays with it ("Hi, I'm Ana" is one clause).
    static func clauses(of text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for ch in text {
            if ".;:!?¿¡。！？；：…".contains(ch) {
                let part = current.trimmingCharacters(in: .whitespaces)
                if !part.isEmpty { parts.append(part) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }
        return parts
    }

    // MARK: Latin scripts

    private static func latin(_ clause: String, lowered: String, _ lexicon: Lexicon) -> Cue? {
        // Words with their position in the clause: the name is read from the original capitals.
        let words = clause.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\u{00A0}" }).map(String.init)
        let lowerWords = words.map { $0.lowercased() }
        var start = 0
        var greeted = false
        // A greeting first: "hi", "hello", "hola", "bonjour", "buongiorno a tutti".
        while start < lowerWords.count, lexicon.greetings.contains(lowerWords[start].trimmingCharacters(in: .punctuationCharacters)) {
            start += 1
            greeted = true
        }
        for (cue, needsGreeting) in lexicon.cues {
            let cueWords = cue.split(separator: " ").map(String.init)
            guard start + cueWords.count < lowerWords.count, Array(lowerWords[start..<(start + cueWords.count)]) == cueWords else { continue }
            if needsGreeting && !greeted { continue }
            let names = name(after: start + cueWords.count, in: words, lexicon: lexicon)
            if !names.isEmpty { return Cue(candidates: names, quote: clause) }
        }
        // "Ana here", "Ana speaking", "Ana hier": the name opens the clause and the word follows it at once.
        let names = name(after: start, in: words, lexicon: lexicon)
        if let longest = names.first {
            let next = start + longest.split(separator: " ").count
            if next < lowerWords.count, lexicon.trailing.contains(lowerWords[next]) { return Cue(candidates: names, quote: clause) }
        }
        return nil
    }

    /// One to three capitalized words from `index` (particles such as "de" or "van" may sit between them), longest first.
    private static func name(after index: Int, in words: [String], lexicon: Lexicon, upTo limit: Int? = nil) -> [String] {
        let end = min(limit ?? words.count, words.count)
        var parts: [String] = []
        var i = index
        while i < end, parts.count < 3 {
            let word = words[i].trimmingCharacters(in: CharacterSet(charactersIn: "\"“”«»'‘’()"))
            // "Ana's", "Ana’s": someone else's.
            if word.hasSuffix("'s") || word.hasSuffix("’s") { return [] }
            if let first = word.first, first.isUppercase, word.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" || $0 == "’" }) {
                parts.append(word)
            } else if !parts.isEmpty, lexicon.particles.contains(word), i + 1 < end, words[i + 1].first?.isUppercase == true {
                parts.append(word)
            } else {
                break
            }
            i += 1
        }
        while let last = parts.last, lexicon.particles.contains(last) { parts.removeLast() }
        return (1...max(1, parts.count)).reversed().compactMap { n in parts.count >= n ? parts.prefix(n).joined(separator: " ") : nil }
    }

    // MARK: Japanese, Korean, Chinese

    private static func dense(_ clause: String, _ lexicon: Lexicon) -> Cue? {
        for (before, after) in lexicon.frames {
            guard let open = before.isEmpty ? clause.startIndex : clause.range(of: before)?.upperBound else { continue }
            // The frame opens the clause (a greeting may come first): "皆さん、私はアナです".
            let lead = clause[clause.startIndex..<(before.isEmpty ? clause.startIndex : clause.range(of: before)!.lowerBound)]
            guard lead.count <= 8 else { continue }
            let rest = clause[open...]
            let run: Substring
            if after.isEmpty {
                run = rest.prefix { !"，、, 　".contains($0) }
            } else {
                guard let close = rest.range(of: after) else { continue }
                run = rest[rest.startIndex..<close.lowerBound]
            }
            let name = run.trimmingCharacters(in: .whitespaces)
            guard (1...16).contains(name.count) else { continue }
            let chars = Array(name)
            // Before a closing phrase the name ends the run ("営業部のアナと申します", "마케팅팀 아나입니다"): its endings. After an opening
            // one it starts it ("我是安娜来自…"): its beginnings. Longest first; Context decides which is a person.
            let candidates = (1...chars.count).reversed().map { after.isEmpty ? String(chars.prefix($0)) : String(chars.suffix($0)) }
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return Cue(candidates: candidates, quote: clause)
        }
        return nil
    }

    // MARK: Words

    struct Lexicon {
        var spaced = true
        /// Cue words as written in lower case, and whether a greeting must come first ("this is").
        var cues: [(String, Bool)] = []
        var greetings: Set<String> = []
        /// Words between the parts of a name ("de", "van", "da").
        var particles: Set<String> = []
        /// A last word after a bare name ("here", "speaking").
        var trailing: Set<String> = []
        /// Japanese, Korean and Chinese: the text before and after the name ("私は" … "です").
        var frames: [(String, String)] = []
    }

    static let lexicons: [String: Lexicon] = [
        "en": Lexicon(cues: [("i'm", false), ("i am", false), ("my name is", false), ("my name's", false), ("this is", true), ("it's", true)],
                      greetings: ["hi", "hello", "hey", "morning", "good", "afternoon", "evening", "everyone", "all", "folks", "there"],
                      particles: ["de", "van", "von", "da", "del", "di", "le"], trailing: ["here", "speaking"]),
        "es": Lexicon(cues: [("soy", false), ("yo soy", false), ("me llamo", false), ("mi nombre es", false), ("te habla", false),
                             ("les habla", false), ("os habla", false), ("habla", true)],
                      greetings: ["hola", "buenos", "buenas", "días", "tardes", "noches", "a", "todos", "todas", "qué", "tal"],
                      particles: ["de", "del", "la", "y"], trailing: ["aquí"]),
        "fr": Lexicon(cues: [("je suis", false), ("je m'appelle", false), ("je m’appelle", false), ("moi c'est", false), ("moi c’est", false),
                             ("c'est", true), ("c’est", true), ("ici", true)],
                      greetings: ["bonjour", "salut", "bonsoir", "à", "tous", "toutes", "tout", "le", "monde"],
                      particles: ["de", "du", "le", "la"], trailing: ["ici"]),
        "de": Lexicon(cues: [("ich bin", false), ("mein name ist", false), ("ich heiße", false), ("hier ist", true), ("hier spricht", false)],
                      greetings: ["hallo", "hi", "guten", "morgen", "tag", "abend", "zusammen", "allerseits", "servus", "moin"],
                      particles: ["von", "van", "de", "zu"], trailing: ["hier"]),
        "it": Lexicon(cues: [("sono", false), ("io sono", false), ("mi chiamo", false), ("il mio nome è", false), ("parla", true), ("qui è", true)],
                      greetings: ["ciao", "buongiorno", "buonasera", "salve", "a", "tutti", "tutte"],
                      particles: ["de", "di", "da", "del", "della"], trailing: ["qui"]),
        "pt": Lexicon(cues: [("sou", false), ("eu sou", false), ("sou a", false), ("sou o", false), ("me chamo", false), ("meu nome é", false),
                             ("aqui é", true), ("aqui é o", true), ("aqui é a", true), ("aqui fala", true), ("aqui fala o", true),
                             ("aqui fala a", true), ("quem fala é", false)],
                      greetings: ["olá", "oi", "bom", "boa", "dia", "tarde", "noite", "a", "todos", "todas", "pessoal"],
                      particles: ["de", "da", "do", "dos", "das", "e"], trailing: ["aqui"]),
        "ja": Lexicon(spaced: false, frames: [("私は", "です"), ("私は", "と申します"), ("私は", "といいます"), ("わたしは", "です"), ("僕は", "です"),
                                               ("", "と申します"), ("", "といいます"), ("", "と言います")]),
        "ko": Lexicon(spaced: false, frames: [("저는 ", "입니다"), ("저는 ", "이에요"), ("저는 ", "예요"), ("제 이름은 ", "입니다"), ("제 이름은 ", "이에요"), ("제 이름은 ", "예요"),
                                               ("", "라고 합니다"), ("", "이라고 합니다")]),
        "zh": Lexicon(spaced: false, frames: [("我是", ""), ("我叫", ""), ("我的名字是", ""), ("我的名字叫", "")]),
    ]
}
