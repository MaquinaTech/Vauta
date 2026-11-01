// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

/// Approximate sound keys for English, French, Italian and Portuguese, the languages besides Spanish whose capitals mark names
/// (German capitalizes every noun, so its corrector is off). Spellings a transcriber writes for the same sound of a name or a
/// term it doesn't know come out alike: "Cobaltics" and "Kobaltix", "Thibaut" and "Tibo", "Kiara" and "Chiara", "Joakin" and
/// "Joaquim". Names that sound different stay apart: "Hannah" and "Anna", "Peter" and "Petra", "Jean" and "Jeanne". The key
/// only makes a word a candidate for a suggestion the person confirms (`MeetingStore.correctionTargets`), so the rules are the
/// spellings each language uses reliably for one sound; vowels stay as written, apart from those spellings. Input: the word
/// as written, since French accents tell how it sounds.
enum PhoneticKeys {
    static func key(_ text: String, language: String) -> String? {
        // Digits stay, as in the Spanish key: two codes never sound alike for lack of letters.
        let word = TextKeys.norm(accentsSaid(text, language: language)).filter { $0.isLetter || $0.isNumber }
        let key: String? = switch language {
        case "en": apply(english, to: word)
        case "fr": apply(french, to: frenchEnding(word))
        case "it": apply(italian, to: word)
        case "pt": apply(portuguese, to: word)
        default: nil
        }
        return key?.isEmpty == false ? key : nil
    }

    /// A spelling and the sound it stands for, where it applies.
    struct Rule {
        enum Place {
            case anywhere, start, notStart, end, beforeFront, beforeVowel, betweenVowels
            /// Where a vowel and n sound nasal in French: before a consonant other than n, m or h, or at the end ("Laurent",
            /// "Sylvain"), not before a vowel or another n ("Simone", "Adrienne").
            case nasal
            /// The same, but not at the end, where a vowel and m are said apart ("Tom") and so is -en in names from other
            /// languages ("Carmen", "Karen").
            case nasalWithin
        }
        let spelling: [Character]
        let sound: String
        let place: Place
        init(_ spelling: String, _ sound: String, _ place: Place = .anywhere) {
            self.spelling = Array(spelling)
            self.sound = sound
            self.place = place
        }
    }

    // MARK: Rules

    /// English: c, k, ck and q; ph and f; th and t; z and s; x as ks; a silent h; y inside a word as i.
    private static let english = ordered([
        Rule("kn", "n", .start), Rule("wr", "r", .start), Rule("gn", "n", .start),
        Rule("chr", "kr"), Rule("chl", "kl"), Rule("ch", "ch"), Rule("sh", "sh"),
        Rule("ph", "f"), Rule("th", "t"), Rule("wh", "w"), Rule("ck", "k"), Rule("qu", "kw"),
        Rule("c", "s", .beforeFront), Rule("c", "k"), Rule("q", "k"), Rule("x", "ks"), Rule("z", "s"),
        Rule("y", "i", .notStart), Rule("h", "", .notStart),
    ])

    /// French, after its ending (`frenchEnding`): eau, au and o; ai, ei and e; the nasal vowels, written in capitals (A for
    /// an, en, am and em; I for in, ain, ein, im, yn and un; O for on and om); ph, th, qu, gn; ch and c before l or r as k;
    /// c and g before e or i; a silent h; z as s. A silent e (ə) and a silent consonant (_) say nothing.
    private static let french = ordered([
        Rule("eaux", "o"), Rule("eau", "o"), Rule("aux", "o"), Rule("au", "o"),
        Rule("sch", "ch"), Rule("chr", "kr"), Rule("chl", "kl"), Rule("ch", "ch"),
        Rule("ph", "f"), Rule("th", "t"), Rule("qu", "k"), Rule("gn", "ni"),
        Rule("ain", "I", .nasal), Rule("ein", "I", .nasal), Rule("ien", "iI", .nasal), Rule("in", "I", .nasal),
        Rule("yn", "I", .nasal), Rule("un", "I", .nasal), Rule("an", "A", .nasal), Rule("on", "O", .nasal),
        Rule("en", "A", .nasalWithin), Rule("aim", "I", .nasalWithin), Rule("im", "I", .nasalWithin), Rule("ym", "I", .nasalWithin),
        Rule("am", "A", .nasalWithin), Rule("em", "A", .nasalWithin), Rule("om", "O", .nasalWithin),
        Rule("ai", "e"), Rule("ei", "e"), Rule("ay", "e"), Rule("ey", "e"),
        Rule("gu", "g", .beforeFront), Rule("g", "j", .beforeFront), Rule("c", "s", .beforeFront), Rule("c", "k"), Rule("q", "k"),
        Rule("x", "ks"), Rule("z", "s"), Rule("y", "i"), Rule("h", ""), Rule("ə", ""), Rule("_", ""),
    ])

    /// Italian: ch and k; c and g before e or i, with a silent i before another vowel; gh, gn, gli, sc before e or i; qu; a
    /// silent h; j and y as i; ph, in names from other languages, as f ("Sophia").
    private static let italian = ordered([
        Rule("sch", "sk"), Rule("sci", "sh", .beforeVowel), Rule("sc", "sh", .beforeFront),
        Rule("ch", "k"), Rule("gh", "g"), Rule("gn", "n"), Rule("gli", "li"), Rule("ph", "f"),
        Rule("ci", "c", .beforeVowel), Rule("gi", "j", .beforeVowel), Rule("c", "c", .beforeFront), Rule("g", "j", .beforeFront),
        Rule("c", "k"), Rule("qu", "kw"), Rule("q", "k"),
        Rule("j", "i"), Rule("y", "i"), Rule("w", "v"), Rule("x", "ks"), Rule("h", ""),
    ])

    /// Portuguese: ch and x, but k before l or r ("Christiano"); lh, nh; qu and k before e or i; c and g before e or i; s
    /// between vowels as z, a final z as s and a final m as n; a silent h; ph, th; y as i and w as v.
    private static let portuguese = ordered([
        Rule("chr", "kr"), Rule("chl", "kl"), Rule("ch", "x"), Rule("lh", "li"), Rule("nh", "ni"), Rule("ph", "f"), Rule("th", "t"),
        Rule("qu", "k", .beforeFront), Rule("qu", "kw"), Rule("gu", "g", .beforeFront),
        Rule("c", "s", .beforeFront), Rule("c", "k"), Rule("q", "k"), Rule("g", "j", .beforeFront),
        Rule("s", "z", .betweenVowels), Rule("z", "s", .end), Rule("m", "n", .end),
        Rule("y", "i"), Rule("w", "v"), Rule("h", ""),
    ])

    // MARK: French

    /// What folding would lose: in French, an é, è or ê is always said ("René" is not "Rennes") and a diaeresis says the vowel
    /// apart from the one before it, as an h between vowels does ("Anaïs" is not "Anne"); in French and Portuguese, ç is s.
    private static func accentsSaid(_ text: String, language: String) -> String {
        guard language == "fr" || language == "pt" else { return text }
        var out = ""
        for ch in text.lowercased() {
            switch (ch, language) {
            case ("ç", _): out += "s"
            case ("é", "fr"), ("è", "fr"), ("ê", "fr"): out += "ee"
            case ("ï", "fr"): out += "hi"
            case ("ë", "fr"): out += "he"
            case ("ü", "fr"): out += "hu"
            default: out.append(ch)
            }
        }
        return out
    }

    /// What French says of the end of a word. -ier, -yer, -ger and -cher sound -é ("Gauthier", "Roger") and -ault sounds o
    /// ("Thibault"). A final consonant that is not said (`silentAtTheEnd`) leaves a silent _, so the vowel before still sounds
    /// nasal ("Laurent" is "Lauran"); a final e that is not said, alone ("Claire") or before one ("Jacques"), leaves a silent
    /// ə, which keeps c and g soft and the vowel before n oral ("Maurice"; "Jeanne" is not "Jean"). The e of -et is said
    /// ("Jacquet" is not "Jack").
    private static func frenchEnding(_ word: String) -> String {
        var s = word
        guard s.count > 3 else { return s }
        if s.count > 4, ["ier", "yer", "ger", "cher"].contains(where: s.hasSuffix) { return String(s.dropLast()) }
        if s.hasSuffix("ault") { s.removeLast(2) }
        var dropped: [Character] = []
        for _ in 0..<2 where s.count > 3 && silentAtTheEnd(s) { dropped.append(s.removeLast()) }
        var silent = dropped.isEmpty ? "" : "_"
        if s.hasSuffix("e"), dropped.allSatisfy({ $0 == "s" }) {
            s.removeLast()
            silent = "ə" + silent
        }
        return s + silent
    }

    /// A final s; a final t, but not after s or t ("Ernest", "Scott"); a d after r, n or u ("Gérard", "Durand", "Arnaud"),
    /// not after another vowel ("David"); a p after m or u ("Deschamps", "Leloup"); an x after u or oi ("Margaux", "Lacroix"),
    /// not after another vowel ("Félix"). A final z is said: most names ending in z come from Spanish ("López").
    private static func silentAtTheEnd(_ s: String) -> Bool {
        guard let last = s.last else { return false }
        let before = s.dropLast()
        switch last {
        case "s": return true
        case "t": return before.last.map { !"st".contains($0) } ?? false
        case "d": return before.last.map { "rnu".contains($0) } ?? false
        case "p": return before.last.map { "mu".contains($0) } ?? false
        case "x": return before.hasSuffix("u") || before.hasSuffix("oi")
        default: return false
        }
    }

    // MARK: Applying them

    /// Vowels and the front vowels that soften c and g, with French's silent e among them.
    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y", "ə"]
    private static let front: Set<Character> = ["e", "i", "y", "ə"]

    /// The longest spelling first; among spellings as long, the first listed.
    private static func ordered(_ rules: [Rule]) -> [Rule] {
        rules.enumerated().sorted { ($0.element.spelling.count, -$0.offset) > ($1.element.spelling.count, -$1.offset) }.map(\.element)
    }

    /// Left to right, the first rule that fits at each letter gives its sound; a letter left alone stays. Then a sound written
    /// twice in a row counts once ("Phillip", "Matthew").
    static func apply(_ rules: [Rule], to word: String) -> String {
        let s = Array(word)
        var out: [Character] = []
        var i = 0
        while i < s.count {
            if let rule = rules.first(where: { fits($0, in: s, at: i) }) {
                out.append(contentsOf: rule.sound)
                i += rule.spelling.count
            } else {
                out.append(s[i])
                i += 1
            }
        }
        var key: [Character] = []
        for c in out where key.last != c { key.append(c) }
        return String(key)
    }

    private static func fits(_ rule: Rule, in s: [Character], at i: Int) -> Bool {
        let n = rule.spelling.count
        guard i + n <= s.count else { return false }
        for k in 0..<n where s[i + k] != rule.spelling[k] { return false }
        let next: Character? = i + n < s.count ? s[i + n] : nil
        let previous: Character? = i > 0 ? s[i - 1] : nil
        switch rule.place {
        case .anywhere: return true
        case .start: return i == 0
        case .notStart: return i > 0
        case .end: return next == nil
        case .beforeFront: return next.map(front.contains) ?? false
        case .beforeVowel: return next.map(vowels.contains) ?? false
        case .betweenVowels: return (previous.map(vowels.contains) ?? false) && (next.map(vowels.contains) ?? false)
        case .nasal: return next.map(closesNasal) ?? true
        case .nasalWithin: return next.map(closesNasal) ?? false
        }
    }

    /// A letter after a vowel and n or m that leaves them nasal: a consonant, but not n, m or h ("Anne", "Emmanuel",
    /// "Bonheur"), or a silent one.
    private static func closesNasal(_ c: Character) -> Bool { !vowels.contains(c) && !"nmh".contains(c) }
}
