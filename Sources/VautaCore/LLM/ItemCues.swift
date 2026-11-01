// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Synchronization

/// The words that tell a task or a decision from talk about one, in the nine languages Vauta is translated into. Phrase lists, not
/// grammar, like `FirstPerson`: every entry is a `TextKeys.norm` key (lowercase, no accents, apostrophes as spaces), matched as whole
/// words (as a substring in the scripts written without spaces). English and Spanish are measured on meetings; the other seven are
/// covered by unit tests only. A missed cue makes an item "to be confirmed" or ownerless, never a wrong owner.
enum ItemCues {
    /// `TextKeys.norm`, remembered: the same clauses are read by many checks (the cache is dropped when it holds 4,096 texts).
    static func norm(_ raw: String) -> String { normCache.norm(raw) }

    private static let normCache = NormCache()

    /// Drops the remembered texts (transcript clauses): called when a minutes run ends, so no decrypted text stays in memory after it.
    static func forgetTexts() { normCache.removeAll() }

    private final class NormCache: Sendable {
        private let known = Mutex<[String: String]>([:])

        func removeAll() { known.withLock { $0.removeAll() } }

        func norm(_ raw: String) -> String {
            if let hit = known.withLock({ $0[raw] }) { return hit }
            let made = TextKeys.norm(raw)
            known.withLock { known in
                if known.count >= 4_096 { known.removeAll(keepingCapacity: true) }
                known[raw] = made
            }
            return made
        }
    }

    /// A clause or a text, normalised once, asked about each cue.
    struct Text {
        let norm: String
        private let tokens: [Substring]
        init(_ raw: String) {
            norm = ItemCues.norm(raw)
            tokens = norm.split(separator: " ")
        }

        func has(_ cue: PhraseSet) -> Bool { cue.matches(in: norm, tokens: tokens) }
        /// Number of words (every character of a script written without spaces counts as one).
        var wordCount: Int { QuoteKey.make(norm).count }
    }

    /// "I have to leave at three", "voy a decir una cosa", "I need to understand the costs": an obligation or a plan is a commitment to a task
    /// only when an action verb follows it. Bare, it is a weak cue (`obligation`), which leaves the task to be confirmed with no certain owner.
    /// German puts the verb at the end of the clause ("Ich muss den Bericht schicken"), so it has no entry here: its obligations stay weak.
    private static let obligationLeads: [(leads: [String], verbs: [String])] = [
        (["i have to", "i need to", "i ve got to", "i gotta", "i must"],
         ["send", "prepare", "write", "review", "check", "finish", "update", "book", "call", "email", "schedule", "share", "follow up", "fix", "draft", "contact", "submit", "organize"]),
        (["voy a", "tengo que", "lo voy a"],
         ["enviar", "mandar", "preparar", "escribir", "revisar", "llamar", "terminar", "actualizar", "reservar", "compartir", "contactar", "organizar", "redactar", "presentar"]),
        (["je dois", "j ai a"], ["envoyer", "preparer", "ecrire", "verifier", "terminer", "appeler", "organiser"]),
        (["devo"], ["inviare", "preparare", "scrivere", "controllare", "finire", "chiamare", "organizzare"]),
        (["tenho que", "preciso"], ["enviar", "preparar", "escrever", "revisar", "terminar", "ligar", "organizar"]),
    ]
    private static let obligationCommitments: [String] = obligationLeads.flatMap { group in group.leads.flatMap { lead in group.verbs.map { "\(lead) \($0)" } } }

    static let selfCommit = PhraseSet(FirstPerson.phrases + obligationCommitments + [
        "let me", "i can do that", "i can look", "i m gonna", "i d be happy to", "i can check", "i can find",
        "voy a enviar", "voy a preparar", "voy a escribir", "voy a mandar", "lo preparo", "lo reviso", "me comprometo", "lo veo yo",
        "yo lo", "me lo apunto", "yo me ocupo", "lo investigo",
        "ich schreibe", "ich bereite", "ich prufe", "preparo io", "controllo io", "vou preparar", "vou fazer", "eu preparo",
        "i can pick", "i can grab", "i can get", "i can set", "i can run", "i can review", "i can update", "i can fix", "i can organize", "i can book", "i can call",
        "i can email", "i can start", "i can look", "i can check", "i can do", "i can take", "i can send", "i can write", "i can prepare", "i can handle",
    ])

    /// Subject pronouns of the languages that drop or keep them in a statement of what one does ("yo preparo el informe", "et moi, je prépare",
    /// "io organizzo", "eu envio", "ich schicke"), and the verbs after them that are not an action to take (opinion, state, ability).
    private static let subjectPronouns: Set<String> = ["yo", "io", "eu", "je", "ich"]
    private static let notAnAction: Set<String> = [
        "creo", "pienso", "siento", "se", "veo", "entiendo", "soy", "estoy", "tengo", "puedo", "quiero", "no", "te", "lo", "la", "le", "me", "mi", "tambien", "ya", "tampoco",
        "penso", "credo", "sono", "sto", "so", "vedo", "capisco", "ho", "posso", "voglio", "non", "ti", "ci", "devo", "vado",
        "dois", "preciso", "muss",
        "acho", "acredito", "sou", "estou", "sei", "vejo", "entendo", "tenho", "posso", "quero", "nao", "nao",
        "pense", "crois", "sais", "suis", "vois", "comprends", "peux", "veux", "ne", "n", "t", "l", "m", "j", "pas", "aussi", "ai",
        "denke", "glaube", "weiss", "bin", "sehe", "verstehe", "habe", "kann", "will", "nicht", "kein", "auch", "mochte", "finde", "meine",
    ]

    /// A first-person statement of an action in the present, with the pronoun written ("yo preparo", "je prépare"): the clause says what the
    /// speaker does, and in a meeting about tasks that is a commitment. Opinion, state and ability verbs do not count.
    static func firstPersonAction(_ norm: String) -> Bool {
        let words = norm.split(separator: " ").map(String.init)
        for (i, word) in words.enumerated() where subjectPronouns.contains(word) && i + 1 < words.count {
            let next = words[i + 1]
            if !notAnAction.contains(next) && next.count >= 4 { return true }
        }
        return false
    }

    /// The clause opens by naming whom it is addressed to ("Ana, can you…", "Lucía, ¿puedes…", "田中さん、…お願いできますか", "민수 씨, …"): a request
    /// to somebody by name, which is a task statement even before an answer.
    static func vocative(_ clause: String) -> Bool {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cut = trimmed.firstIndex(where: { ",，、".contains($0) }) else { return false }
        let head = String(trimmed[..<cut]).trimmingCharacters(in: .whitespaces)
        let words = head.split(separator: " ")
        guard !head.isEmpty, words.count <= 3 else { return false }
        if ["さん", "씨", "님", "先生", "老师", "さま", "様"].contains(where: { head.hasSuffix($0) }) { return true }
        let interjections: Set<String> = ["okay", "ok", "yeah", "yes", "well", "so", "right", "sure", "and", "but", "now", "then", "good", "great", "perfect", "alright", "hey", "oh", "bueno", "vale",
                                          "claro", "pues", "entonces", "bien", "perfecto", "bon", "alors", "oui", "ben", "ja", "also", "gut", "dann", "ecco", "allora", "bene", "sim", "entao",
                                          "tudo", "ola"]
        guard let first = head.first else { return false }
        if TextKeys.isNoSpaceScript(first) { return head.count <= 4 }
        guard first.isUppercase, words.allSatisfy({ $0.first?.isUppercase == true }) || words.count == 1 else { return false }
        return !interjections.contains(TextKeys.norm(head))
    }

    /// Said in answer to a request, enough to commit: a self-commitment, or the polite forms of "yes, I'll do it".
    static let committingAcceptance = PhraseSet(selfCommit.phrases + [
        "will do", "no problem", "consider it done", "sure i", "sin problema", "no hay problema", "con gusto", "cuenta conmigo", "claro lo", "dale lo",
        "pas de probleme", "kein problem", "nessun problema", "sem problema", "problema nenhum", "没问题", "沒問題", "問題ありません", "문제없습니다", "no worries", "not a problem", "no te preocupes",
    ])

    /// Words that refer back to the request ("I'll do that", "lo hago eso") or only say when, so they do not make a commitment about
    /// something else.
    private static let referring: Set<String> = [
        "that", "this", "them", "these", "those", "there", "thing", "things", "yeah", "okay", "sure", "today", "tonight", "tomorrow", "later", "soon", "then",
        "week", "morning", "afternoon", "thanks", "thank", "great", "right", "fine", "happy", "gladly", "myself",
        "eso", "esto", "esos", "esas", "hoy", "manana", "luego", "pronto", "tarde", "noche", "gracias", "claro", "dale", "perfecto", "semana",
    ]

    /// Whether a committing clause, said after a request, is the answer to that request and not a commitment about something else: it is a
    /// bare acceptance ("I'll do that", "will do", "sure, I can", "lo hago"), or the words it adds are about the item ("I'll send it to the
    /// board" for "send the deck to the board"). `reference` holds the content words of the item and of the request clause. "Can you look
    /// into the logo?" "I'll send the minutes tonight." is nobody accepting the logo.
    static func answersRequest(_ clause: String, reference: Set<String>, language: String?) -> Bool {
        guard commits(clause, cues: committingAcceptance) else { return false }
        return addsNothingElse(clause, reference: reference, language: language)
    }

    /// Whether a bare yes ("Yes.", "Sure, go ahead.") is about the request it follows: "Yes, and the budget is fine." says yes to something else. A yes that also commits ("Claro, lo confirmo.") accepts.
    static func acceptsRequest(_ clause: String, reference: Set<String>, language: String?) -> Bool {
        guard OwnerInference.isWeakAcceptance(clause) else { return false }
        if commits(clause, cues: committingAcceptance) { return true }
        return addsNothingElse(clause, reference: reference, language: language)
    }

    private static func addsNothingElse(_ clause: String, reference: Set<String>, language: String?) -> Bool {
        let own = contentWords(clause, language: language).filter { !referring.contains($0) }
        if !own.isDisjoint(with: reference) { return true }
        var rest = " " + norm(clause) + " "
        let phrases = (committingAcceptance.phrases + weakAcceptance.phrases + FirstPerson.phrases).sorted { $0.count > $1.count }
        for phrase in phrases where !phrase.isEmpty {
            let spaced = phrase.unicodeScalars.contains { TextKeys.isNoSpaceScript($0) || (0xAC00...0xD7AF).contains($0.value) } ? phrase : " \(phrase) "
            if rest.contains(spaced) { rest = rest.replacingOccurrences(of: spaced, with: " ") }
        }
        let added = contentWords(rest, language: language).filter { !referring.contains($0) }
        if added.isEmpty { return true }
        // Scripts written without spaces: a handful of characters left over is a polite ending, not a different action.
        if clause.contains(where: { TextKeys.isNoSpaceScript($0) }) && added.count <= 3 { return true }
        return !added.isDisjoint(with: reference)
    }

    static let weakAcceptance = PhraseSet([
        "yeah", "yes", "yep", "okay", "ok", "fine", "sure", "alright", "right", "mm hmm", "uh huh",
        "dale", "bueno", "vale", "listo", "claro", "de acuerdo", "oui", "d accord", "ja", "gut", "va bene", "certo", "sim", "tudo bem",
    ])

    /// The "yes" cues that are also something else inside a longer text: the Spanish "si" (also "if"), and the words of the scripts written
    /// without spaces and Korean, which a substring match would find inside other words ("네트워크", "好像", "你可以"). They count only as the
    /// first word of the reply, with at most a particle after them.
    private static let leadingYes: Set<String> = ["はい", "わかりました", "네", "좋아요", "好的", "好", "可以", "是的"]
    private static let yesParticles: Set<String> = ["", "的", "吧", "了", "啊", "呀", "です", "ね", "よ", "ます", "요", "네"]
    private static let afterSpanishSi: Set<String> = ["claro", "vale", "dale", "listo", "gracias", "perfecto", "bueno", "ok", "okay", "por"]

    /// A short plain "yes" (no commitment in it): at most eight words, a cue such as "yeah", "okay", "dale", no question and no refusal
    /// ("Yeah, no, I can't do that").
    static func isWeakYes(_ raw: String) -> Bool {
        let t = Text(raw)
        guard t.wordCount <= 8, !isQuestion(raw), !refuses(raw) else { return false }
        if t.has(weakAcceptance) { return true }
        let tokens = t.norm.split(separator: " ")
        guard let first = tokens.first.map(String.init) else { return false }
        if first == "si" { return tokens.count == 1 || afterSpanishSi.contains(String(tokens[1])) }
        for cue in leadingYes where first.hasPrefix(cue) && yesParticles.contains(String(first.dropFirst(cue.count))) { return true }
        return false
    }

    /// Negations that mean "no" in an answer. `FirstPerson.negations` also holds the polite request forms, which a commitment cannot contain
    /// but a "yes" can ("はい、お願いします").
    private static let refusalNegations = PhraseSet(FirstPerson.negations.filter { !["必要", "べき", "お願い", "ください", "下さい", "부탁", "拜托", "请你", "請你"].contains($0) })

    private static let refusalCues = PhraseSet([
        "unable", "sorry", "busy", "swamped", "lo siento", "ocupado", "ocupada", "desole", "desolee", "es tut mir leid", "mi dispiace", "sinto muito", "desculpa",
        "申し訳", "죄송", "抱歉", "对不起", "對不起",
    ])

    /// What somebody says when asked to do something and declines: a negation or an apology, and no commitment of their own
    /// ("Sorry, I can't this week", "no puedo", "Yeah, no, I can't"). "Sorry, I'll do it" and "no problem" are acceptances.
    static func refuses(_ raw: String) -> Bool {
        let all = clauses(raw)
        if !all.isEmpty, all.allSatisfy({ isQuestion($0.trimmingCharacters(in: .whitespaces)) }) { return false }
        if all.contains(where: { commits($0, cues: committingAcceptance) }) { return false }
        var rest = norm(raw)
        for phrase in politeNegations where rest.contains(phrase) { rest = rest.replacingOccurrences(of: phrase, with: " ") }
        return refusalNegations.matches(in: rest) || refusalCues.matches(in: rest)
    }

    static let request = PhraseSet([
        "can you", "could you", "would you", "will you", "you should", "you need to", "you have to", "you ll", "you can", "you re going to", "you could",
        "why don t you", "please", "do you want to", "do you mind", "how about you", "do you think you can", "you re gonna", "you are going to",
        "do you wanna", "you wanna", "you gonna", "make sure", "remember to", "don t forget", "asegurate", "acordate de", "no te olvides", "acuerdate de",
        "puedes", "podes", "podrias", "puede usted", "te pido", "le pido", "encargate", "tienes que", "tenes que", "deberias", "por favor", "te encargas",
        "te toca", "te lo encargo", "quieres", "quisieras", "podria usted", "podrian",
        "peux tu", "tu peux", "vous pouvez", "pouvez vous", "pourrais tu", "pourriez vous", "tu dois", "vous devez", "s il te plait", "s il vous plait",
        "kannst du", "konntest du", "konnen sie", "du musst", "bitte",
        "puoi", "potresti", "devi", "per favore",
        "voce pode", "poderia", "voce precisa", "voce deve",
        "お願い", "ください", "下さい", "してくれ", "していただ", "부탁", "해주세요", "해 주세요", "해줄 수", "주실래요", "주세요", "주시겠", "请你", "請你", "你能", "你可以", "麻烦", "麻煩", "拜托",
    ])

    static let volunteerCall = PhraseSet([
        "who wants to", "who can", "who will", "who s going to", "who would like", "anyone", "anybody", "somebody", "someone to", "any volunteers",
        "quien se encarga", "quien puede", "alguien", "quien quiere", "quien se ocupa", "voluntario",
        "qui veut", "qui peut", "quelqu un", "qui s en charge", "wer kann", "wer mochte", "wer ubernimmt", "jemand",
        "chi puo", "chi vuole", "chi si occupa", "qualcuno", "quem pode", "quem quer", "quem se encarrega", "alguem",
        "誰か", "どなたか", "누가", "누구", "谁来", "誰來", "有人", "谁可以", "誰可以",
    ])

    static let groupObligation = PhraseSet([
        "we ll", "we will", "we need to", "we have to", "we should", "we must", "we re going to", "we are going to", "for next meeting", "everybody", "everyone",
        "all of you", "each of you", "we can", "let s",
        "tenemos que", "hay que", "vamos a", "debemos", "habra que", "todos", "tendremos que", "deberiamos",
        "il faut", "on doit", "nous devons", "on va", "nous allons", "wir mussen", "wir werden", "man muss", "dobbiamo", "bisogna", "dovremmo", "andremo",
        "precisamos", "temos que", "vamos", "devemos",
        "しなければ", "必要があり", "해야", "합시다", "我们需要", "我們需要", "我们要", "我們要", "必须", "必須", "咱们", "咱們",
    ])

    static let agreement = PhraseSet([
        "agreed", "we agree", "i agree", "let s go with", "we ll go with", "go with", "decided", "we decided", "settled", "that s it", "we keep", "we ll keep",
        "approved", "it s a deal", "sounds good", "that works", "we re going with", "let s do", "that s the plan", "okay then", "voted", "all in favor",
        "so we will", "so we ll", "we ll do", "we do that",
        "aprobado", "se aprueba", "afirmativo", "por unanimidad", "por mayoria", "de acuerdo", "queda aprobado", "pasa a comision", "aprobamos", "decidimos",
        "acordamos", "quedamos", "votacion", "se resuelve", "queda decidido", "aprobada", "se aprobo", "votos a favor", "todos a favor", "por la afirmativa",
        "d accord", "on a decide", "nous avons decide", "approuve", "adopte", "on garde", "convenu", "einverstanden", "beschlossen", "abgemacht", "wir nehmen", "genehmigt",
        "deciso", "approvato", "concordato", "restiamo", "decidido", "aprovado", "combinado", "fechado",
        "決定", "承認", "合意", "決まり", "賛成", "결정", "승인", "합의", "찬성", "同意", "决定", "批准", "通过", "通過", "一致",
    ])

    /// A group stating what it will do or has chosen ("we'll go for", "let's say", "we have included"): a decision when no one objects.
    static let groupDecision = PhraseSet([
        "we ll", "we will", "we re going to", "we are going to", "let s say", "let s", "we have to", "we ve decided", "we have included", "we ve included",
        "has been eliminated", "have been eliminated", "is eliminated", "we go for", "we go with", "we take", "we keep", "we use", "we don t need",
        "we re gonna", "we are gonna", "going for", "we should", "should aim", "aim for", "aim to",
        "vamos a", "usaremos", "dejamos", "nos quedamos con", "tenemos que", "hay que", "on va", "on prend", "wir nehmen", "wir machen", "prendiamo", "faremos", "vamos usar",
        "决定", "采用", "採用", "にします", "にしましょう", "으로 하겠습니다",
    ])

    /// Words that void an agreement cue in the same clause: "we haven't decided", "to be decided", "pending".
    static let agreementVoid = PhraseSet([
        "haven t decided", "hasn t been decided", "not decided", "isn t decided", "aren t decided", "didn t decide", "to be decided", "yet to be", "not yet", "still pending", "pending",
        "need to decide", "needs to be decided", "have to decide", "haven t agreed", "not agreed", "not approved", "no agreement", "undecided", "tbd",
        "pendiente", "sin decidir", "por decidir", "no se decidio", "no esta aprobado", "no aprobado", "a definir", "todavia no", "aun no",
    ])

    /// "No objections", "no one objects": a negation word that agrees.
    private static let agreeingNegations: [String] = ["no objection", "no objections", "no one objects", "nobody objects", "sin objeciones", "sin objecion", "ninguna objecion"]

    /// Whether a clause states an agreement: an agreement cue in a clause that is not a question, holds no negation and no word that leaves the
    /// matter open.
    static func agrees(_ clause: String) -> Bool {
        if isQuestion(clause) { return false }
        let t = Text(clause)
        guard t.has(agreement) else { return false }
        var rest = t.norm
        for phrase in politeNegations + agreeingNegations where rest.contains(phrase) { rest = rest.replacingOccurrences(of: phrase, with: " ") }
        return !agreementNegations.matches(in: rest) && !agreementVoid.matches(in: rest)
    }

    static let hedge = PhraseSet([
        "maybe", "might", "perhaps", "probably", "could", "if", "not sure", "i guess", "possibly", "potentially", "whether", "depends", "see if", "try to",
        "i think we could", "we may", "kind of", "sort of",
        "quizas", "capaz", "tal vez", "podriamos", "si hace falta", "a lo mejor", "posiblemente", "probablemente", "habria que ver", "depende", "veremos", "podria",
        "peut etre", "pourrait", "pourrions", "probablement", "je ne sais pas", "si besoin", "vielleicht", "konnte", "konnten", "eventuell", "wahrscheinlich", "falls",
        "forse", "potremmo", "magari", "probabilmente", "se serve", "talvez", "poderiamos", "provavelmente", "se precisar",
        "かもしれ", "たぶん", "多分", "かな", "もし", "아마", "어쩌면", "일지도", "만약", "也许", "也許", "可能", "或许", "或許", "如果", "大概",
    ])

    static let recap = PhraseSet([
        "last meeting", "previous meeting", "last time", "last session", "previous session", "earlier meeting", "previous minutes", "reading the minutes",
        "minutes of the last", "minutes of the previous", "minutes from the last", "minutes from last", "minutes of last", "as we decided", "we decided last", "last week s meeting",
        "sesion anterior", "acta anterior", "reunion anterior", "lectura del acta", "ultima sesion", "la semana pasada", "en la anterior",
        "reunion precedente", "derniere reunion", "dernier compte rendu", "seance precedente", "letzten sitzung", "letztes treffen", "vorheriges protokoll",
        "letzten besprechung", "riunione precedente", "ultima riunione", "verbale precedente", "seduta precedente", "reuniao anterior", "ultima reuniao",
        "ata anterior", "sessao anterior", "前回", "前の会議", "前回の議事録", "지난 회의", "지난번", "이전 회의", "上次会议", "上次會議", "上一次", "上次",
    ])

    static let reading = PhraseSet([
        "articulo", "visto", "considerando", "se da lectura", "ingreso una nota", "nota de", "expediente", "ordenanza", "proyecto de", "dictamen",
        "orden del dia", "mocion", "decreto", "whereas", "hereby", "article", "considerant", "gemass", "articolo", "ordem do dia", "条", "議案",
    ])

    static let procedure = PhraseSet([
        "slide", "slides", "presentation", "next point", "next item", "let s start", "take a break", "minutes left", "agenda", "next speaker", "your turn",
        "move on", "powerpoint", "microphone", "on the screen", "go through", "go over", "walk you through", "show you", "let me show", "let me just", "my slide", "start first",
        "go first", "my presentation", "next topic", "siguiente punto", "cuarto intermedio", "diapositiva", "presentacion", "pasamos al",
        "pasamos a", "tiene la palabra", "uso de la palabra", "microfono", "diapositive", "point suivant", "ordre du jour", "pause", "folie", "tagesordnung",
        "nachster punkt", "punto successivo", "ordine del giorno", "pausa", "proximo ponto", "pauta", "intervalo", "スライド", "次の議題", "休憩",
        "슬라이드", "다음 안건", "휴식", "幻灯片", "幻燈片", "下一项", "下一項", "休息",
    ])

    /// A speaker announcing what they do in the meeting itself ("I'll start off", "I'll go through the findings", "I'll take my file down"): a
    /// commitment, but to the running of the meeting, not a task for afterwards.
    static let speakerProcedure = PhraseSet([
        "start off", "i ll start", "i ll move on", "i ll explain", "i ll show", "i ll present", "i ll go through", "i ll go over", "i ll walk", "let me present",
        "let me show", "let me go", "let me move", "let me just", "take my file", "i ll take the minutes", "i will take the minutes",
        "voy a presentar", "les muestro", "paso a explicar", "empiezo yo", "je vais presenter", "ich zeige", "ich fange an", "mostro", "comincio io", "vou apresentar", "eu comeco",
        "発表します", "説明します", "시작하겠습니다", "我先开始", "我來說明",
    ])

    static let rating = PhraseSet([
        "out of", "score", "rate", "rating", "i like", "i don t like", "is nice", "is the bomb", "cool", "is great", "love it", "awesome", "looks good",
        "me gusta", "puntaje", "genial", "buenisimo", "j aime", "j adore", "gefallt mir", "mi piace", "bello", "punteggio", "gosto", "legal",
        "好き", "いいですね", "点数", "좋아요", "마음에 들", "점수", "我喜欢", "我喜歡", "不错", "不錯", "分数", "評分",
    ])

    static let done = PhraseSet([
        "we did", "i did", "i ve done", "we ve done", "already", "i have done", "i sent", "i ve sent", "we sent", "was done", "is done", "finished", "completed",
        "ya lo hice", "ya esta", "ya hicimos", "ya envie", "hecho", "completado", "deja fait", "j ai fait", "j ai envoye", "schon erledigt", "bereits",
        "gia fatto", "ho fatto", "ho inviato", "ja fiz", "ja enviei", "済み", "終わりました", "送りました", "이미", "보냈", "已经", "已經", "完成了",
    ])

    static let modalFuture = PhraseSet([
        "will", "is going to", "are going to", "is supposed to", "are supposed to", "needs to", "need to", "has to", "have to", "should", "must",
        "va a", "van a", "debe", "deben", "tiene que", "tienen que", "debera", "tendra que", "se encargara", "se encarga", "enviara", "presentara",
    ])

    /// Words that are not a third party when they come before a modal: the speaker, the addressee, "it", "that", relative pronouns.
    static let nonThirdParty: Set<String> = [
        "i", "we", "you", "it", "that", "this", "there", "which", "who", "what", "and", "so", "then", "but", "yo", "nosotros", "tu", "usted", "eso", "esto",
        "ello", "que", "y", "entonces", "pero", "ya", "no", "not", "also", "just", "all", "everybody", "everyone", "todos", "alguien", "someone", "somebody", "anyone",
    ]

    static let thirdPartyPronouns: Set<String> = ["they", "he", "she", "ellos", "ella", "ellas"]

    static let roles: [String] = [
        "designer", "expert", "manager", "marketing", "engineer", "secretary", "chair", "treasurer", "team", "department", "committee", "council", "mayor",
        "executive", "office", "director", "client", "customer", "vendor", "supplier",
        "ejecutivo", "secretario", "secretaria", "comision", "departamento", "intendente", "concejo", "area", "direccion", "oficina", "presidente", "tesorero", "equipo",
        "secretaire", "equipe", "chef", "responsable", "sekretar", "abteilung", "leiter", "segretario", "reparto", "squadra", "equipa", "diretor",
    ]

    /// The clauses of a segment, terminators kept, in order: split on . ? ! ; and their full-width forms.
    static func clauses(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ".?!;。？！；".contains(ch) {
                if !current.trimmingCharacters(in: .whitespaces).isEmpty { out.append(current) }
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { out.append(current) }
        return out
    }

    /// The clause of the cited segment that carries the item: the one that shares the most content words with the item's text and its quote
    /// (words of four letters or more, every character of a script written without spaces), a clause with a commitment or a request winning a
    /// tie. The model's quote is often a different sentence of the same turn than the one that says who will do what.
    static func evidenceClause(item: String, quote: String, in text: String, language: String?) -> (index: Int, clauses: [String]) {
        let infos = clauseInfos(text, language: language)
        return (evidenceIndex(item: item, quote: quote, infos: infos, language: language), infos.map(\.text))
    }

    /// A clause of a segment with the content words it holds, worked out once.
    struct ClauseInfo: Sendable {
        let text: String
        let content: Set<String>
    }

    static func contentWords(_ s: String, language: String?) -> Set<String> {
        Set(QuoteKey.make(s, language: language).filter { $0.count >= 4 || ($0.count == 1 && TextKeys.isNoSpaceScript($0.first!)) })
    }

    static func clauseInfos(_ text: String, language: String?) -> [ClauseInfo] {
        let all = clauses(text)
        if all.count <= 1 { return [ClauseInfo(text: all.first ?? text, content: [])] }
        return all.map { ClauseInfo(text: $0, content: contentWords($0, language: language)) }
    }

    static func evidenceIndex(item: String, quote: String, infos: [ClauseInfo], language: String?) -> Int {
        guard infos.count > 1 else { return 0 }
        let wanted = contentWords(item + " " + quote, language: language)
        guard !wanted.isEmpty else { return 0 }
        let scores = infos.map { $0.content.intersection(wanted).count }
        let top = scores.max() ?? 0
        let tied = scores.indices.filter { scores[$0] == top }
        // A clause with a commitment or a request wins a tie; otherwise the first.
        return tied.first { i in let t = Text(infos[i].text); return commits(infos[i].text) || t.has(request) || t.has(volunteerCall) } ?? tied[0]
    }

    /// The clause of `text` that holds `quote`: the one that shares the most words with it (ties go to the first), with its index.
    static func clause(holding quote: String, in text: String, language: String?) -> (index: Int, clauses: [String]) {
        let all = clauses(text)
        guard all.count > 1 else { return (0, all.isEmpty ? [text] : all) }
        let q = Set(QuoteKey.make(quote, language: language))
        guard !q.isEmpty else { return (0, all) }
        var best = (index: 0, score: -1)
        for (i, c) in all.enumerated() {
            let score = Set(QuoteKey.make(c, language: language)).intersection(q).count
            if score > best.score { best = (i, score) }
        }
        return (best.index, all)
    }

    static func isQuestion(_ clause: String) -> Bool {
        let t = clause.trimmingCharacters(in: .whitespaces)
        return t.hasSuffix("?") || t.hasSuffix("？")
    }

    /// Whether the clause is somebody saying what they themselves will do. The question mark and the negations count inside the clause
    /// only (`FirstPerson.commits` reads a whole turn).
    static func commits(_ clause: String, cues: PhraseSet = selfCommit) -> Bool {
        if isQuestion(clause) { return false }
        if commitsWhole(clause, cues: cues) { return true }
        // "Ana can't make it, so I'll send the deck": a negation before "so" or "but" is about another thing than the commitment after it.
        let norm = " " + ItemCues.norm(clause) + " "
        for joiner in [" so ", " but "] where norm.contains(joiner) {
            let parts = norm.components(separatedBy: joiner)
            if parts.dropFirst().contains(where: { commitsWhole($0, cues: cues) }) { return true }
        }
        return false
    }

    private static func commitsWhole(_ clause: String, cues: PhraseSet) -> Bool {
        let t = Text(withoutStatives(clause))
        guard t.has(cues) || (cues.phrases.count == selfCommit.phrases.count && firstPersonAction(t.norm)) else { return false }
        // "No problem" and its translations say yes with a negation word in them.
        var rest = t.norm
        for phrase in politeNegations where rest.contains(phrase) { rest = rest.replacingOccurrences(of: phrase, with: " ") }
        return !negations.matches(in: rest)
    }

    static let negations = PhraseSet(FirstPerson.negations)
    private static let agreementNegations = PhraseSet(FirstPerson.negations + ["haven t", "hasn t", "isn t", "aren t", "didn t", "doesn t", "wouldn t", "couldn t", "shouldn t"])

    /// "I will need your snippets", "I'll want them by Friday": the speaker asks for something, not a commitment. "I'll need to send it" stays.
    static func withoutStatives(_ clause: String) -> String {
        let norm = ItemCues.norm(clause)
        // Most clauses have none of these words: nothing to do.
        guard norm.contains("need") || norm.contains("want") || norm.contains("like") || norm.contains(" see") || norm.contains("able") else { return norm }
        // A stutter ("I will I will need", "I I will") is one word or two said twice.
        var words = norm.split(separator: " ").map(String.init)
        var i = 0
        while i + 1 < words.count {
            if words[i] == words[i + 1] { words.remove(at: i + 1); continue }
            if i + 3 < words.count, words[i] == words[i + 2], words[i + 1] == words[i + 3] { words.removeSubrange((i + 2)...(i + 3)); continue }
            i += 1
        }
        var text = words.joined(separator: " ")
        for lead in ["i ll", "i will", "i d", "i would"] {
            for verb in ["need", "want", "like", "see", "be able"] {
                let phrase = "\(lead) \(verb)"
                guard text.contains(phrase) else { continue }
                if verb == "need" || verb == "want" || verb == "like", text.contains("\(phrase) to") { continue }
                text = text.replacingOccurrences(of: phrase, with: " ")
            }
        }
        return text
    }

    static let politeNegations: [String] = [
        "no problem", "no hay problema", "sin problema", "no pasa nada", "pas de probleme", "kein problem", "nessun problema", "sem problema",
        "problema nenhum", "没问题", "沒問題", "問題ありません", "문제없습니다", "no worries", "not a problem", "no te preocupes",
    ]

    /// The text with the polite request forms removed, so "could you" is not a hedge.
    static func withoutRequests(_ norm: String) -> String {
        var out = norm
        for phrase in request.phrases where phrase.contains(" ") && out.contains(phrase) { out = out.replacingOccurrences(of: phrase, with: " ") }
        return out
    }

    static func hedged(_ clause: String) -> Bool {
        hedge.matches(in: withoutRequests(norm(clause)))
    }

    /// The subject of a modal in the clause is somebody other than the speaker, the addressee or the group: a role ("the Industrial
    /// Designer will…", "que el ejecutivo envíe…") or a pronoun for somebody else ("they will…").
    private static let impersonal = PhraseSet(["se solicita al", "se solicita a la", "se pide al", "se le pide", "elevar a", "se solicita"])

    private static let modalByFirstWord: [String: [[String]]] = {
        var out: [String: [[String]]] = [:]
        for phrase in modalFuture.phrases {
            let words = phrase.split(separator: " ").map(String.init)
            if let first = words.first { out[first, default: []].append(words) }
        }
        return out
    }()

    static func thirdPartySubject(_ clause: String) -> Bool {
        let norm = ItemCues.norm(clause)
        let words = norm.split(separator: " ").map(String.init)
        // The Spanish subjunctive and impersonal requests: "que el ejecutivo envíe…", "se solicita al…".
        if impersonal.matches(in: norm) { return true }
        if let i = words.firstIndex(of: "que"), i + 2 < words.count, ["el", "la", "los", "las"].contains(words[i + 1]),
           roles.contains(where: { words[i + 2].hasPrefix($0) }) { return true }
        // A name before a firm modal ("Pernilla will review it"): somebody else, whom the meeting did not list as a person.
        let raw = clause.split(whereSeparator: { " ,;:".contains($0) }).map(String.init)
        for (i, word) in raw.enumerated() where i > 0 && i + 1 < raw.count && word.first?.isUppercase == true && word.count > 2 {
            let next = ItemCues.norm(raw[i + 1])
            if ["will", "va", "tendra", "debera", "necesita"].contains(next) || (next == "is" && i + 3 < raw.count && ItemCues.norm(raw[i + 2] + " " + raw[i + 3]) == "going to") { return true }
        }
        for at in words.indices where at > 0 {
            guard let candidates = modalByFirstWord[words[at]] else { continue }
            for mw in candidates where at + mw.count <= words.count && words[at..<(at + mw.count)].elementsEqual(mw) {
                let before = words[max(0, at - 4)..<at]
                guard let last = before.last, !nonThirdParty.contains(last) else { continue }
                if thirdPartyPronouns.contains(last) { return true }
                if before.contains(where: { w in roles.contains { w.hasPrefix($0) } }) { return true }
            }
        }
        return false
    }
}

/// A list of normalised phrases matched as whole words against a normalised text: the same answer as `DateWords.contains`, without building a
/// padded copy of the text for every phrase. Phrases in a script written without spaces (and Korean) are looked for as substrings.
struct PhraseSet: Sendable {
    let phrases: [String]
    /// Phrases of space-separated words, by their first word.
    private let byFirstWord: [String: [[String]]]
    private let substrings: [String]

    init(_ phrases: [String]) {
        self.phrases = phrases
        var byFirst: [String: [[String]]] = [:]
        var subs: [String] = []
        for phrase in phrases where !phrase.isEmpty {
            let spaceless = phrase.unicodeScalars.contains { TextKeys.isNoSpaceScript($0) || (0xAC00...0xD7AF).contains($0.value) }
            if spaceless { subs.append(phrase); continue }
            let words = phrase.split(separator: " ").map(String.init)
            if let first = words.first { byFirst[first, default: []].append(words) }
        }
        byFirstWord = byFirst
        substrings = subs
    }

    func matches(in norm: String) -> Bool { matches(in: norm, tokens: norm.split(separator: " ")) }

    func matches(in norm: String, tokens: [Substring]) -> Bool {
        // Phrases in Chinese, Japanese and Korean exist only in text that has such characters; the substring search is the slow part.
        if !substrings.isEmpty, norm.utf8.contains(where: { $0 >= 0x80 }), substrings.contains(where: { norm.contains($0) }) { return true }
        for (i, token) in tokens.enumerated() {
            guard let candidates = byFirstWord[String(token)] else { continue }
            for words in candidates where i + words.count <= tokens.count {
                var all = true
                for (k, w) in words.enumerated() where tokens[i + k] != w { all = false; break }
                if all { return true }
            }
        }
        return false
    }
}
