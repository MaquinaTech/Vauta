// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// A person someone speaks to by name: "What do you think, Ana?", "Ana, ¿lo has visto?", "Over to you, Ana", "Thanks, Ana.", "田中さん、
/// どう思いますか？". Whoever answers the question or takes the floor is probably that person, and so is whoever had just spoken when
/// they are thanked. It only proposes: `MeetingStore.suggestSpeakersFromTranscript` points the name at a turn, keeps it only when the
/// turns agree, and then only suggests it ("Is this Ana?"); it never names a speaker.
///
/// Read without a model in the nine languages. A name counts only where it is said to someone: at the start of a clause before a comma
/// ("Ana, …", "So Ana, …"), at its end after a comma ("…, Ana?") or right after thanks ("Thanks Ana"), and only in a question, a
/// handover or thanks. A remark ("That's your fault, Ana"), a name talked about ("I'll ask Ana", "Ana's table") or a list ("Paula,
/// Iván, Lena?") gives nothing: in the public AMI meetings with real first names, the speaker after a question asked by name was the
/// person asked about nine times in ten, and after a remark about half the time.
public enum SpeakerAddresses {
    /// Whose turn the name points to.
    public enum Turn: Sendable, Equatable {
        /// A question or a handover: the next speaker.
        case next
        /// Thanks: the speaker before.
        case previous
    }

    public struct Address: Sendable, Equatable {
        /// The name, as the line has it.
        public let range: Range<String.Index>
        public let turn: Turn
    }

    /// The names of `names` (ranges of `text`) that the line says to someone, in the languages given (BCP-47 or language codes).
    public static func addresses(in text: String, names: [Range<String.Index>], languages: [String]) -> [Address] {
        let words = Words(languages: languages)
        var out: [Address] = []
        for clause in clauses(of: text) {
            let inside = names.filter { clause.range.contains($0.lowerBound) && $0.upperBound <= clause.range.upperBound }
            // Two names in one clause: a list, or a name said twice ("Hugo, Hugo, could you…"); nobody in particular.
            guard inside.count == 1, let name = inside.first else { continue }
            let turn = TextKeys.isNoSpaceScript(text[name.lowerBound]) ? dense(text, clause, name, words) : spaced(text, clause, name, words)
            if let turn { out.append(Address(range: name, turn: turn)) }
        }
        return out
    }

    /// What to show of a line under a suggestion: the clause that says `name` (or its first word), with its end mark; the line cut to
    /// `limit` characters when no clause does.
    public static func quote(_ text: String, naming name: String, limit: Int = 140) -> String {
        let keys = [TextKeys.norm(name), name.split(separator: " ").first.map { TextKeys.norm(String($0)) } ?? ""].filter { $0.count >= 2 }
        let found = clauses(of: text).first { clause in
            let said = TextKeys.norm(String(text[clause.range]))
            return keys.contains { key in
                TextKeys.isNoSpaceScript(key.first ?? " ") ? said.contains(key) : " \(said) ".contains(" \(key) ")
            }
        }
        var out = text.trimmingCharacters(in: .whitespaces)
        if let found {
            let end = found.range.upperBound < text.endIndex ? text.index(after: found.range.upperBound) : found.range.upperBound
            out = String(text[found.range.lowerBound..<end]).trimmingCharacters(in: .whitespaces)
        }
        guard out.count > limit else { return out }
        return String(out.prefix(limit - 3)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: Clauses

    struct Clause {
        let range: Range<String.Index>
        /// It ends with a question mark.
        let question: Bool
    }

    /// The clauses of a line, cut where a sentence or clause ends. "¿" and "¡" open a clause without ending one ("Ana, ¿lo has visto?" is
    /// one), and commas never end one.
    static func clauses(of text: String) -> [Clause] {
        var out: [Clause] = []
        var start = text.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ".;:!?。！？；：…".contains(ch) {
                if text[start..<i].contains(where: { !$0.isWhitespace }) { out.append(Clause(range: start..<i, question: ch == "?" || ch == "？")) }
                start = text.index(after: i)
            }
            i = text.index(after: i)
        }
        if text[start...].contains(where: { !$0.isWhitespace }) { out.append(Clause(range: start..<text.endIndex, question: false)) }
        return out
    }

    // MARK: Scripts written with spaces (Latin, Korean…)

    private static func spaced(_ text: String, _ clause: Clause, _ name: Range<String.Index>, _ words: Words) -> Turn? {
        var after = text[name.upperBound..<clause.range.upperBound]
        // "Ana's table" is about Ana.
        if after.hasPrefix("'s") || after.hasPrefix("’s") { return nil }
        // A title after the name ("안나 씨, …", "도윤 님?"); with the topic after it, a question asks the person ("안나 씨는 …?").
        var topic = false
        let word = after.drop { $0 == " " }.prefix { $0 != " " && $0 != "," }
        if let title = words.afterTitles.first(where: { word.hasPrefix($0) }) {
            let rest = word.dropFirst(title.count)
            if rest.isEmpty || words.topics.contains(String(rest)) {
                topic = !rest.isEmpty
                after = text[word.endIndex..<clause.range.upperBound]
            }
        }
        let trim = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "¿¡\"“”«»„"))
        var before = text[clause.range.lowerBound..<name.lowerBound].trimmingCharacters(in: trim)
        // A title before the name ("Gracias, señor Ibarra", "Thanks, Dr. Okoro" is cut at the period anyway).
        if let last = before.split(separator: " ").last, words.titles.contains(last.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            before = String(before.dropLast(last.count)).trimmingCharacters(in: trim)
        }
        let rest = after.trimmingCharacters(in: trim)
        let lead = lowerWords(before)
        let tail = lowerWords(rest.hasPrefix(",") ? String(rest.dropFirst()) : rest)
        if listed(text, clause, words) { return nil }
        // "Ana, …", "So Ana, …", "Hi Ana, …", or the whole clause ("Ana?").
        let opening = lead.allSatisfy(words.fillers.contains) && (rest.isEmpty || rest.hasPrefix(",") || (topic && clause.question))
        // "…, Ana?", "…, Ana, …?", "Thanks Ana", "Over to you Ana", "Thanks Ana for the update".
        let leadEnds = { (phrases: [[String]]) in phrases.contains { lead.count >= $0.count && Array(lead.suffix($0.count)) == $0 } }
        let closing = (rest.isEmpty || rest.hasPrefix(",") || (leadEnds(words.thanks) && words.thanksFor.contains(tail.first ?? "")))
            && (before.hasSuffix(",") || leadEnds(words.thanks) || leadEnds(words.handovers))
        guard opening || closing else { return nil }
        let starts = { (phrases: [[String]], list: [String]) in
            let list = list.drop(while: words.fillers.contains)
            return phrases.contains { list.count >= $0.count && Array(list.prefix($0.count)) == $0 }
        }
        // Thanks open the clause, before the name or right after it: the person had just spoken.
        if (closing && starts(words.thanks, lead)) || (opening && starts(words.thanks, tail)) {
            return .previous
        }
        let all = lead + tail
        if words.handovers.contains(where: { phrase in all.indices.contains { i in Array(all[i...].prefix(phrase.count)) == phrase } }) { return .next }
        return clause.question ? .next : nil
    }

    /// Two or more capitalized words, each alone between commas: a list of people ("Paula, uh Iván, Lena?"). The clause's first
    /// part is left out, where a capital opens the sentence ("Perfect, Ana"), and so are the words of fillers, thanks, handovers and titles.
    private static func listed(_ text: String, _ clause: Clause, _ words: Words) -> Bool {
        text[clause.range].split(separator: ",").dropFirst().filter { part in
            let kept = part.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }
                .filter { !$0.isEmpty && !words.phraseWords.contains($0.lowercased()) }
            return (1...2).contains(kept.count) && kept.allSatisfy { $0.first?.isUppercase == true } && kept != ["I"]
        }.count >= 2
    }

    private static func lowerWords(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\u{00A0}" })
            .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "'’-"))) }
            .filter { !$0.isEmpty }
    }

    // MARK: Japanese and Chinese

    private static func dense(_ text: String, _ clause: Clause, _ name: Range<String.Index>, _ words: Words) -> Turn? {
        var end = name.upperBound
        let next = text[end..<clause.range.upperBound].drop { $0 == " " }
        let honored = Self.honorifics.first { next.hasPrefix($0) }
        if let honored { end = text.index(next.startIndex, offsetBy: honored.count) }
        let before = text[clause.range.lowerBound..<name.lowerBound].trimmingCharacters(in: .whitespaces)
        let after = text[end..<clause.range.upperBound].trimmingCharacters(in: .whitespaces)
        let marks: Set<Character> = ["、", "，", ","]
        let whole = String(text[clause.range])
        let question = clause.question || words.denseQuestionEnds.contains { whole.trimmingCharacters(in: .whitespaces).hasSuffix($0) }
        // "田中さん、…", "王伟，…"; with a title, "田中さんは…？" asks the person too.
        let topic = honored != nil && question && Self.topicParticles.contains { after.hasPrefix($0) }
        let opening = (before.isEmpty || words.denseFillers.contains(before)) && (after.isEmpty || after.first.map(marks.contains) == true || topic)
        // "…、田中さん？", "谢谢王伟".
        let thanksBefore = Self.denseThanks.contains { before.hasSuffix($0) || before.trimmingCharacters(in: .init(charactersIn: "、，,")).hasSuffix($0) }
        let closing = after.isEmpty && (before.last.map(marks.contains) == true || thanksBefore)
        guard opening || closing else { return nil }
        if (closing && Self.denseThanks.contains(where: before.hasPrefix)) || thanksBefore
            || (opening && Self.denseThanks.contains { after.drop(while: marks.contains).hasPrefix($0) }) {
            return .previous
        }
        if words.denseHandovers.contains(where: whole.contains) { return .next }
        return question ? .next : nil
    }

    /// Titles said after a name, in Japanese and Chinese.
    static let honorifics = ["さん", "さま", "様", "くん", "君", "ちゃん", "先生", "部長", "課長", "社長", "氏", "殿",
                             "女士", "小姐", "老师", "老師", "经理", "經理", "总", "總"]
    /// The topic after a name and a title, in a question to that person.
    static let topicParticles = ["は"]
    static let denseThanks = ["ありがとう", "感謝", "감사", "고마", "고맙", "谢谢", "謝謝", "感谢", "多谢", "多謝"]

    // MARK: Words

    struct Words {
        /// Words that may come before a name said to someone ("so", "okay", "hi").
        var fillers: Set<String> = []
        var thanks: [[String]] = []
        /// After "thanks <name>": "for", "por", "pour".
        var thanksFor: Set<String> = []
        var handovers: [[String]] = []
        /// Words said before a surname ("señor", "Frau").
        var titles: Set<String> = []
        /// Titles said after a name, written apart from it ("씨", "님"), and the topic that may follow one ("는").
        var afterTitles: [String] = []
        var topics: Set<String> = []
        /// Every word of the fillers, thanks, handovers and titles.
        var phraseWords: Set<String> = []
        var denseFillers: Set<String> = []
        var denseQuestionEnds: [String] = []
        var denseHandovers: [String] = []

        init(languages: [String]) {
            let codes = Set(languages.compactMap { Locale(identifier: $0).language.languageCode?.identifier })
            for code in codes.sorted() {
                guard let lexicon = SpeakerAddresses.lexicons[code] else { continue }
                fillers.formUnion(lexicon.fillers.split(separator: " ").map(String.init))
                thanks += lexicon.thanks.map { $0.split(separator: " ").map(String.init) }
                thanksFor.formUnion(lexicon.thanksFor.split(separator: " ").map(String.init))
                handovers += lexicon.handovers.map { $0.split(separator: " ").map(String.init) }
                titles.formUnion(lexicon.titles.split(separator: " ").map(String.init))
                afterTitles += lexicon.afterTitles
                topics.formUnion(lexicon.topics)
                denseFillers.formUnion(lexicon.denseFillers)
                denseQuestionEnds += lexicon.denseQuestionEnds
                denseHandovers += lexicon.denseHandovers
            }
            phraseWords = fillers.union(titles).union((thanks + handovers).flatMap { $0 })
            // Longest first, so "thank you so much" is read before "thank you".
            thanks.sort { $0.count > $1.count }
            handovers.sort { $0.count > $1.count }
            afterTitles.sort { $0.count > $1.count }
        }
    }

    struct Lexicon {
        var fillers = ""
        var thanks: [String] = []
        var thanksFor = ""
        var handovers: [String] = []
        var titles = ""
        var afterTitles: [String] = []
        var topics: [String] = []
        var denseFillers: [String] = []
        var denseQuestionEnds: [String] = []
        var denseHandovers: [String] = []
    }

    static let lexicons: [String: Lexicon] = [
        "en": Lexicon(fillers: "so okay ok and well um uh erm hey oh right now alright hi hello yes yeah then also but",
                      thanks: ["thanks", "thank you", "thank you so much", "thanks so much", "thanks a lot", "many thanks", "cheers"],
                      thanksFor: "for",
                      handovers: ["go ahead", "over to you", "your turn", "you're up", "you’re up", "take it away", "the floor is yours",
                                  "you have the floor", "you're next", "you’re next"],
                      titles: "mr mrs ms miss dr"),
        "es": Lexicon(fillers: "y bueno pues vale oye entonces ahora hola eh sí si venga mira pero a ver",
                      thanks: ["gracias", "muchas gracias", "mil gracias", "muchísimas gracias"],
                      thanksFor: "por",
                      handovers: ["adelante", "te toca", "tu turno", "tienes la palabra", "tiene la palabra", "cuando quieras",
                                  "te escuchamos", "te cedo la palabra", "le cedo la palabra"],
                      titles: "señor señora señorita sr sra srta don doña doctor doctora"),
        "fr": Lexicon(fillers: "et alors bon donc euh eh bah ok bonjour salut oui mais",
                      thanks: ["merci", "merci beaucoup", "merci bien", "un grand merci"],
                      thanksFor: "pour",
                      handovers: ["vas-y", "allez-y", "à toi", "à vous", "c'est à toi", "c’est à toi", "c'est à vous", "c’est à vous",
                                  "je te laisse la parole", "je vous laisse la parole", "on t'écoute", "on t’écoute", "on vous écoute"],
                      titles: "monsieur madame mademoiselle m mme mlle docteur"),
        "de": Lexicon(fillers: "und also so ähm äh hallo gut okay ja na aber",
                      thanks: ["danke", "danke schön", "dankeschön", "vielen dank", "danke dir", "danke ihnen", "herzlichen dank"],
                      thanksFor: "für",
                      handovers: ["du bist dran", "sie sind dran", "leg los", "schieß los", "fang an", "du hast das wort", "sie haben das wort"],
                      titles: "herr frau dr"),
        "it": Lexicon(fillers: "e allora bene quindi ehm ciao ok sì senti ma",
                      thanks: ["grazie", "grazie mille", "molte grazie"],
                      thanksFor: "per",
                      handovers: ["tocca a te", "a te la parola", "vai pure", "la parola a te"],
                      titles: "signor signore signora signorina sig sig.ra dott dottor dottoressa"),
        "pt": Lexicon(fillers: "e então bom bem olha oi olá tá sim mas ok",
                      thanks: ["obrigado", "obrigada", "muito obrigado", "muito obrigada", "valeu"],
                      thanksFor: "por pelo pela",
                      handovers: ["sua vez", "é com você", "pode falar", "fique à vontade", "a palavra é sua", "com a palavra"],
                      titles: "senhor senhora sr sra dona doutor doutora"),
        "ja": Lexicon(denseFillers: ["では", "じゃあ", "えっと", "あの", "それでは", "では次に"],
                      denseQuestionEnds: ["か", "かな", "ですか", "ますか", "でしょうか"], denseHandovers: ["どうぞ", "お願いします", "お願いできますか"]),
        "ko": Lexicon(fillers: "그럼 자 그러면 네 그리고",
                      thanks: ["감사합니다", "감사해요", "고맙습니다", "고마워요", "고마워"],
                      handovers: ["말씀하세요", "말씀해 주세요", "말씀해주세요", "차례입니다", "차례예요"],
                      afterTitles: ["씨", "님", "선배님", "팀장님", "부장님", "과장님", "대리님", "선생님"], topics: ["는", "은"]),
        "zh": Lexicon(denseFillers: ["那么", "好", "那", "嗯"], denseQuestionEnds: ["吗", "呢", "嗎"],
                      denseHandovers: ["请讲", "请说", "你来", "請講", "請說"]),
    ]
}
