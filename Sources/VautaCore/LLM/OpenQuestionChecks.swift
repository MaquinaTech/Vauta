// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Swift reads the open questions the model wrote and drops what is not one, with no model (`MinutesQuestions.checks`): a line of the
/// transcript copied as it is, a text too short or with no question form, a restated topic, a point a decision of the minutes settles, and a
/// repeat. The model is never asked to judge its own list. Only questions disappear; nothing is added or reworded.
enum OpenQuestionChecks {
    /// The most open questions Apple's model keeps (its list is mostly generic questions the meeting never asked).
    static let appleCap = 3
    static let minWords = 4
    /// Share of the question's words found in one transcript line for it to count as that line copied.
    static let copyShare = 0.8
    /// Share of the question's content words found in one decision (or task) for the decision to answer it.
    static let settledShare = 0.6
    static let settledWords = 2
    /// Share of the question's content words found in one topic for it to only restate that topic.
    static let topicShare = 0.8

    static func apply(_ minutes: ValidatedMinutes, segments: [CitableSegment], integrated: Bool, parts: MinutesQuestions) -> ValidatedMinutes {
        var out = minutes
        guard !out.openQuestions.isEmpty else { return out }
        let lines = segments.map { Set(words($0.text)) }
        let said = lines.reduce(into: Set<String>()) { $0.formUnion($1) }
        let settled = (out.decisions.map(\.text) + out.tasks.map(\.text)).map { SummaryChecks.contentKey($0) }
        let topics = out.topics.map { SummaryChecks.contentKey($0) }.filter { !$0.isEmpty }
        var kept: [String] = []
        var keys: [Set<String>] = []
        func drop(_ reason: String) { out.counts["question.dropped.\(reason)", default: 0] += 1 }
        for question in out.openQuestions {
            let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
            let w = words(text)
            // With `short` (not in the release): a real question can be this short ("Who pays?"): two or three words pass when they are asked as a question (a mark and a question word)
            // and every word that is not a question word is said in the transcript. The copy check does not apply to them (two words are always in some line).
            let shortAsked = parts.contains(.short) && w.count >= 2 && w.count < minWords && isShortQuestionSaid(text, words: w, said: said)
            if parts.contains(.form), w.count < minWords, !shortAsked { drop("short"); continue }
            // The integrated model writes the unresolved point as a statement; only Apple's model is held to a question form.
            if parts.contains(.form), !integrated, !hasQuestionForm(text, words: w) { drop("form"); continue }
            let set = Set(w)
            if parts.contains(.copy), !shortAsked, lines.contains(where: { Double(set.intersection($0).count) / Double(set.count) > copyShare }) { drop("copy"); continue }
            if parts.contains(.generic), isStock(text) { drop("generic"); continue }
            let key = SummaryChecks.contentKey(text)
            if !key.isEmpty {
                if parts.contains(.topic), topics.contains(where: { Double(key.intersection($0).count) / Double(key.count) >= topicShare }) { drop("topic"); continue }
                // Apple's model lists the points it was only half sure of in the decisions too, and a real follow-up question is often about one of them:
                // the check is held to the integrated model, whose decisions are few and firm.
                if parts.contains(.settled), integrated, key.count >= settledWords,
                   settled.contains(where: { $0.intersection(key).count >= settledWords && Double($0.intersection(key).count) / Double(key.count) >= settledShare }) {
                    drop("settled"); continue
                }
                if parts.contains(.repeats), keys.contains(where: { SummaryChecks.jaccard($0, key) >= 0.7 }) { drop("repeat"); continue }
                keys.append(key)
            }
            kept.append(text)
        }
        if parts.contains(.cap), !integrated, kept.count > appleCap {
            out.counts["question.dropped.cap", default: 0] += kept.count - appleCap
            // The questions with a question mark are the ones the speakers asked; they come first.
            let asked = kept.filter { $0.contains("?") || $0.contains("？") }
            kept = Array((asked + kept.filter { q in !asked.contains(q) }).prefix(appleCap))
        }
        out.openQuestions = kept
        return out
    }

    /// "Who pays?": a question mark, a question word to start, and the other words found in the transcript (so the question is about something said).
    static func isShortQuestionSaid(_ text: String, words w: [String], said: Set<String>) -> Bool {
        guard text.contains("?") || text.contains("？") || text.contains("¿"), let first = w.first, openers.contains(first) else { return false }
        let rest = w.dropFirst().filter { !openers.contains($0) }
        return !rest.isEmpty && rest.allSatisfy { said.contains($0) }
    }

    // MARK: Words

    private static func isWide(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
    }

    /// The words of a text, normalised; Japanese, Chinese and Korean text, which has no spaces, is cut into pairs of characters.
    static func words(_ text: String) -> [String] {
        let norm = TextKeys.norm(text)
        var out: [String] = []
        for part in norm.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            if part.contains(where: isWide) {
                let chars = Array(part)
                if chars.count == 1 { out.append(String(chars)) } else { for i in 0..<(chars.count - 1) { out.append(String(chars[i...i + 1])) } }
            } else {
                out.append(String(part))
            }
        }
        return out
    }

    // MARK: Stock questions

    /// The frames of the questions that fit any meeting: what the next steps are, what something implies, how to ensure it, what to do about it.
    /// Apple's model writes them to fill the list; the speakers did not ask them (28 of the 104 on the development meetings, 2 of them real).
    private static let stock: [String] = [
        "next steps", "what are the implications", "what is the implication", "implications (?:of|for) ", "what to do (?:with|about|if)", "what should be done (?:with|about)",
        "how (?:will|can|do|should|would) (?:we|the team|the group|they|the project|it) (?:ensure|guarantee|make sure)", "how (?:to|can we|do we) ensure",
        "(?:proximos|siguientes) pasos", "que pasos (?:se|debe|deben|seguira|tomara)", "que implica", "que implican", "que implicaciones", "se garantizara", "se asegurara", "como garantizar", "que se debe hacer (?:con|respecto|sobre)", "que se hara con",
        "prochaines etapes", "quelles sont les implications", "que implique", "que faut il faire", "comment garantir", "comment (?:le|la|l) (?:equipe|groupe) garantira",
        "naechsten schritte", "was bedeutet", "welche folgen hat", "was ist zu tun", "wie wird sichergestellt", "wie koennen wir sicherstellen",
        "prossimi passi", "cosa implica", "quali sono le implicazioni", "come garantire", "come si garantira", "cosa fare (?:con|per|riguardo)",
        "proximos passos", "o que implica", "quais sao as implicacoes", "como garantir", "como sera garantido", "o que fazer (?:com|sobre|em relacao)",
    ]
    private static let stockPattern = try? NSRegularExpression(pattern: "(?:^| )(?:" + stock.joined(separator: "|") + ")")

    static func isStock(_ text: String) -> Bool {
        guard let pattern = stockPattern else { return false }
        let norm = TextKeys.norm(text)
        return pattern.firstMatch(in: norm, range: NSRange(norm.startIndex..., in: norm)) != nil
    }

    // MARK: Question form

    private static let openers: Set<String> = [
        "what", "how", "who", "whom", "whose", "when", "where", "why", "which", "should", "can", "could", "do", "does", "did", "is", "are", "was",
        "will", "would", "shall", "may", "might", "whether", "if", "who", "need", "must",
        "que", "como", "quien", "quienes", "cuando", "donde", "cual", "cuales", "cuanto", "cuantos", "cuanta", "por", "debemos", "deberiamos",
        "debe", "deberia", "podemos", "podria", "puede", "hay", "es", "son", "si", "se", "habra", "vamos", "quedan",
        "quoi", "comment", "qui", "quand", "ou", "quel", "quelle", "quels", "quelles", "pourquoi", "combien", "faut", "doit", "doit-on", "peut", "peut-on", "est", "sommes",
        "was", "wie", "wer", "wen", "wem", "wann", "wo", "welche", "welcher", "welches", "warum", "wieso", "weshalb", "soll", "sollen", "sollten", "kann", "koennen", "ob", "gibt", "ist", "sind",
        "cosa", "chi", "quando", "dove", "quale", "quali", "perche", "quanto", "quanti", "dobbiamo", "deve", "puo", "possiamo", "c'e", "ce",
        "quem", "onde", "qual", "quais", "devemos", "deve", "pode", "podemos", "ha", "sera", "porque", "quanto",
    ]
    /// Phrases that say a point is left open or whether something holds, anywhere in the text (accents folded, lower case). The integrated model
    /// writes the unresolved point as a statement ("The group needs to decide…"), Apple's model as a question.
    private static let cues: [String] = [
        // English
        "whether", "unclear", "undecided", "unresolved", "not clear", "open question", "remains? (?:open|unclear|to be|a concern|unresolved|conceptual|undecided)",
        "(?:needs?|need) to (?:be )?(?:decide|decided|determine|determined|confirm|confirmed|finali[sz]e|finali[sz]ed|address|addressed|clarify|clarified|define|defined|agree|agreed|resolve|resolved|settle|settled|discuss|discussed|choose|chosen|establish|established|check|checked|find|work out)",
        "(?:not|never) (?:yet |been |fully |definitively )*(?:decided|settled|determined|defined|finali[sz]ed|confirmed|resolved|agreed|clarified|chosen|set)",
        "still (?:open|needs?|to be|undecided|unclear|unresolved|being)", "to be (?:decided|determined|defined|confirmed|clarified|agreed|resolved|discussed)", "yet to (?:decide|be)", "tbd", "(?:not|no) consensus", "did not reach", "without (?:a )?(?:decision|agreement|consensus)",
        // Spanish
        "no esta claro", "no queda claro", "pendiente", "sin (?:decidir|definir|resolver|aclarar|confirmar)", "por (?:decidir|definir|determinar|confirmar|aclarar|resolver|acordar)", "no se (?:ha|han) (?:decidido|definido|resuelto|aclarado|acordado|determinado|confirmado)",
        "(?:hay|habra|es necesario|falta|faltan|queda|quedan|necesita|necesitan|debe|deben|deberan|debera) (?:que |por |aun |todavia )?(?:decidir|definir|determinar|confirmar|aclarar|resolver|acordar|establecer|elegir|concretar|revisar)", "queda(?:n)? (?:abierto|abierta|por)", "sin resolver",
        // French
        "pas clair", "pas encore (?:decide|defini|tranche|confirme|determine)", "reste (?:a|ouvert)", "restent? (?:a|ouvert)", "a (?:decider|definir|determiner|confirmer|clarifier|preciser)", "(?:doit|doivent|faut|faudra) (?:encore )?(?:decider|determiner|definir|confirmer|clarifier|choisir|preciser|trancher)", "non resolu",
        // German
        "unklar", "offen", "noch nicht", "ungeklaert", "(?:muss|muessen|sollte|sollten) (?:noch )?(?:entschieden|geklaert|festgelegt|bestimmt|entscheiden|klaeren|festlegen|bestimmen|bestaetigen|besprochen|beschlossen)",
        // Italian
        "non e chiaro", "non ancora", "ancora (?:da|aperto|aperta)", "resta(?:no)? (?:da|aperto|aperta)", "da (?:decidere|definire|determinare|confermare|chiarire|risolvere)", "(?:deve|devono|bisogna|occorre) (?:ancora )?(?:decidere|definire|determinare|confermare|chiarire|risolvere|stabilire|scegliere)", "irrisolt",
        // Portuguese
        "nao esta claro", "ainda nao", "em aberto", "por (?:decidir|definir|determinar|confirmar|esclarecer|resolver)", "a (?:decidir|definir|determinar|confirmar|esclarecer)", "(?:precisa|precisam|falta|faltam|deve|devem|e preciso) (?:ainda )?(?:decidir|definir|determinar|confirmar|esclarecer|resolver|estabelecer|escolher)", "sem resolver",
    ]
    private static let wideCues = ["か", "かどうか", "どう", "何", "未定", "未決", "未確定", "検討", "決める", "決定", "確認", "불분명", "여부", "할지", "인지", "무엇", "어떻게", "정해야", "결정해야", "미정", "是否", "什么", "如何", "怎么", "吗", "尚未", "未决", "待定", "需要决定", "需要确定", "未确定", "有待"]
    private static let cuePattern = try? NSRegularExpression(pattern: "(?:^| )(?:" + cues.joined(separator: "|") + ")(?: |$)")

    static func hasQuestionForm(_ text: String, words w: [String]) -> Bool {
        if text.contains("?") || text.contains("？") || text.contains("¿") { return true }
        let norm = TextKeys.norm(text)
        if let first = w.first, openers.contains(first) { return true }
        if wideCues.contains(where: { text.contains($0) }) { return true }
        guard let pattern = cuePattern else { return false }
        return pattern.firstMatch(in: norm, range: NSRange(norm.startIndex..., in: norm)) != nil
    }
}
