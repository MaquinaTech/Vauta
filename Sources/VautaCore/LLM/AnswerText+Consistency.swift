// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Checks that the words of an answer agree with its shape (`found`, a whole sentence, a quote that is a quote).
extension AnswerText {
    /// The text has a letter or a digit: "........" or "…" is the filler the grammar writes to close a field, not text.
    static func hasWords(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    /// The sentence of a long answer stops without closing punctuation: the grammar closes a string at its byte cap, in the middle of a
    /// word or a clause, and the JSON is whole (finish reason `stop`). Only an answer that came within a tenth of the grammar's byte cap
    /// (`capBytes`) can have been closed by it: a shorter one that ends on a figure, a percent sign, a list item or a name finished.
    static func endsMidSentence(_ text: String, capBytes: Int) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count >= capBytes * 9 / 10, let last = trimmed.last else { return false }
        return !".!?…。！？」』”»)）]\"'’*".contains(last)
    }

    /// Phrases that say the material itself does not state something, in the languages of the app (accents and case folded; CJK as
    /// written): the subject is the material or nobody ("it is not specified", "no se menciona"). An ordinary negative fact about
    /// someone ("the client did not give approval", "María no sabe usar la herramienta") is never in this list.
    private static let absence = try! NSRegularExpression(pattern: [
        // English
        #"\bnot (specified|mentioned|stated|indicated|detailed)\b"#,
        #"\b(material|transcript|meeting|recording|documents?|notes|excerpts?|passages?|conversation|discussion|text)\b.{0,30}\b(does not|doesn't|did not|didn't|do not|don't|never) (\w+ )?(specify|say|mention|state|indicate|detail|clarify|cover|address|contain|reveal)\b"#,
        #"\b(no|any) (information|details?|mention|indication|data|record)\b.{0,40}\b(is|are|was|were|given|provided|available|found)\b"#,
        #"\b(cannot|can't|could not|couldn't) be (determined|established)\b"#,
        // Spanish
        #"\bno se (especifica|especifican|menciona|mencionan|indica|indican|detalla|detallan|aclara|aclaran|precisa|precisan|senala|informa|aborda)\b"#,
        #"\bno consta\b"#,
        #"\btampoco se \w+"#,
        #"\b(no hay|sin) (informacion|mencion|datos|detalles|indicacion)\b"#,
        #"\b(sin especificar|no queda claro|no esta claro|no se puede determinar)\b"#,
        #"\b(material|transcripcion|reunion|grabacion|documentos?|notas|texto|conversacion|extractos?|pasajes?)\b.{0,30}\bno (dice|dicen|da|dan|incluye|aborda|cubre|contiene|recoge|trata|menciona|especifica|indica)\b"#,
        // French
        #"\bn['e ]? ?(est|sont|etait|etaient) pas (precis|mentionn|indiqu|specifi|detaill)"#,
        #"\b(aucune|pas d['e ]) ?(information|mention|precision|indication|detail)"#,
        #"\b(materiel|transcription|reunion|enregistrement|documents?|notes|texte|conversation|extraits?|passages?)\b.{0,30}\bne (precise|precisent|mentionne|mentionnent|indique|indiquent|specifie|detaille|dit|disent|donne|contient|couvre|traite|fournit) pas\b"#,
        // German
        #"\bnicht (angegeben|genannt|erwahnt|spezifiziert|ersichtlich|angesprochen|festgelegt)\b"#,
        #"\bkeine (angabe|angaben|information|informationen|details|erwahnung)\b"#,
        #"\b(material|transkript|besprechung|aufnahme|dokumente?|notizen|text|gesprach|auszuge?|passagen?)\b.{0,60}\b(nennt|nennen|erwahnt|erwahnen|spezifiziert|beschreibt|sagt|enthalt|enthalten|liefert|behandelt|gibt)\b.{0,60}\bnicht\b"#,
        // Italian
        #"\bnon (e|viene|vengono|sono|risulta|risultano) (specificat|menzionat|indicat|dettagliat|precisat)"#,
        #"\b(nessuna|nessun|senza) (informazione|menzione|dettaglio|indicazione)\b"#,
        #"\b(material[ei]|trascrizion[ei]|riunion[ei]|registrazion[ei]|document[oi]|not[ae]|test[oi]|conversazion[ei]|estratt[oi]|passagg[io])\b.{0,30}\bnon (specifica|specificano|menziona|menzionano|indica|indicano|dice|dicono|precisa|precisano|chiarisce|fornisce|contiene|copre|tratta)\b"#,
        // Portuguese
        #"\bnao (e|foi|foram|esta|estao|sao|fica) (especificad|mencionad|indicad|informad|detalhad)"#,
        #"\b(nenhuma|sem) (informacao|mencao|detalhe|indicacao)\b"#,
        #"\b(material|transcricao|reuniao|gravacao|documentos?|notas|texto|conversa|trechos?|passagens?)\b.{0,30}\bnao (especifica|especificam|menciona|mencionam|indica|indicam|diz|dizem|detalha|esclarece|informa|fornece|contem|cobre|trata)\b"#,
        // Japanese, Korean, Chinese
        #"(言及|明記|記載|示|述べ|触れ|説明|特定)(さ)?れて(い)?(ない|ません|いない)"#,
        #"(언급|명시|기재|설명)되(지|어 있지|어있지) ?않"#,
        #"(나와|적혀|제시되어) ?있지 ?않"#,
        #"(材料|记录|录音|文档|笔记|内容|会议|文字记录)(中|里)?(并)?(没有|未|没)"#,
        #"(没有|并没有|未|并未)明确(提到|提及|说明|指出|指明)"#,
        #"(不明确|未明确|没有明确|没有相关信息)"#,
    ].joined(separator: "|"), options: [.caseInsensitive])

    /// Speech verbs with any subject ("the vendor did not mention a date"). Used only for an answer none of whose quotes was found.
    private static let absenceOfSpeech = try! NSRegularExpression(pattern: [
        #"\b(does not|doesn't|did not|didn't|do not|don't) (\w+ )?(specify|say|mention|state|indicate|detail|clarify)\b"#,
        #"\bno (menciona|mencionan|especifica|especifican|indica|indican|detalla|aclara|precisa|dice|dicen)\b"#,
        #"\bne (precise|precisent|mentionne|mentionnent|indique|indiquent|specifie|detaille|dit|disent) pas\b"#,
        #"\b(nennt|nennen|erwahnt|erwahnen|spezifiziert|beschreibt) .{0,60}\bnicht\b"#,
        #"\bnon (specifica|specificano|menziona|menzionano|indica|indicano|dice|dicono|precisa|precisano|chiarisce)\b"#,
        #"\bnao (especifica|especificam|menciona|mencionam|indica|indicam|diz|dizem|detalha|esclarece)\b"#,
        #"(没有|并没有|未|并未|没)(明确)?(提到|提及|说明|指出|指明)"#,
    ].joined(separator: "|"), options: [.caseInsensitive])

    /// Words that join the absence to something else the sentence says ("although the value is not mentioned, they agreed to…", "the
    /// date is not given, only that it is next week").
    private static let contrast = try! NSRegularExpression(pattern: [
        #"\b(although|though|but|however|while|whereas|except|yet|only|just|aunque|pero|sin embargo|salvo|excepto|solo|solamente|unicamente|mais|cependant|bien que|sauf|seulement|uniquement|obwohl|aber|jedoch|allerdings|sondern|nur|sebbene|anche se|ma|tuttavia|soltanto|solamente|embora|porem|mas|contudo|somente|apenas|sino|en cambio|instead|rather|plutot|au contraire|stattdessen|invece|pelo contrario)\b"#,
        #"[;:]"#,
        #"(ですが|ますが|けれど|しかし|だけ|のみ|ただ|하지만|그러나|지만|다만|단지|뿐|但是|但|不过|然而|可是|只是|只有|仅)"#,
    ].joined(separator: "|"), options: [.caseInsensitive])

    private static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'")
    }

    /// Every sentence of the answer only says the material does not state something (and none adds anything with "but", "although"…).
    /// An answer that gives something and then says what is missing is a partial answer, not this. The caller applies it only when no
    /// claim of the answer verified: with one verified claim the negative sentence is a fact ("the vendor did not state the price").
    static func declaresNothingFound(_ answer: String) -> Bool {
        let sentences = answer.split(whereSeparator: { ".!?。！？\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { hasWords($0) }
        guard !sentences.isEmpty, sentences.count <= 4 else { return false }
        return sentences.allSatisfy { sentence in
            let folded = fold(sentence)
            let range = NSRange(folded.startIndex..., in: folded)
            guard contrast.firstMatch(in: folded, range: range) == nil else { return false }
            if absence.firstMatch(in: folded, range: range) != nil { return true }
            return absenceOfSpeech.firstMatch(in: folded, range: range) != nil
        }
    }
}
