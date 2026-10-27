// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The words the follow-up detector looks for, in the nine languages Vauta is translated into. They live in code, not in the design
/// document, so the people who write evaluation fixtures never see them. Everything is compared as normalized keys (`TextKeys.norm`:
/// lowercase, no accents, no punctuation, single spaces), so "Let’s meet again" is "let s meet again".
///
/// A cue says "we will meet again". It is not a date: a cue without a date is dropped. Not a language model; it recognizes the
/// phrases people use, and the evaluation reports how many it misses.
enum FollowUpWords {
    /// Phrases that announce another meeting or call.
    static let cues: [String] = [
        // English
        "meet again", "next meeting", "next call", "next sync", "next session", "next catch up", "follow up meeting", "follow up call",
        "follow up session", "follow up sync", "followup meeting", "reconvene", "regroup", "catch up again", "touch base again", "talk again",
        "speak again", "same time next", "same time in", "see you next", "see you on", "another meeting", "another call", "pick this up", "pick this back up",
        "get together again", "sync again", "call again", "let s meet", "let s catch up", "let s talk again", "schedule the follow up",
        "schedule a follow up", "set up a follow up", "book a follow up", "meet next", "reconnect",
        // Spanish
        "nos vemos", "vernos", "volver a vernos", "nos volvemos a ver", "reunirnos", "volvemos a reunirnos", "nos reunimos", "otra reunion",
        "proxima reunion", "siguiente reunion", "reunion de seguimiento", "llamada de seguimiento", "seguimiento", "quedamos", "nos juntamos",
        "retomamos", "retomar esto", "volvemos a hablar", "hablamos de nuevo", "nos llamamos", "volver a reunirnos",
        // French
        "on se revoit", "se revoir", "nous nous reverrons", "se reunir", "on se reunit", "prochaine reunion", "reunion de suivi", "point de suivi",
        "on se retrouve", "se retrouver", "on se rappelle", "on reprend", "refaire un point", "autre reunion", "on se voit", "prochain point",
        "prochain rendez vous", "se reparler",
        // German
        "treffen uns wieder", "wieder treffen", "nochmal treffen", "erneut treffen", "nachstes treffen", "nachstes meeting", "nachste besprechung",
        "nachster termin", "folgetermin", "folgemeeting", "nachfasstermin", "wir sehen uns", "sprechen wieder", "wieder zusammensetzen",
        "weiterbesprechen", "nachster call", "nachstes gesprach", "melden uns wieder",
        // Italian
        "ci rivediamo", "rivederci", "ci vediamo", "ci risentiamo", "ci sentiamo", "prossima riunione", "prossimo incontro", "riunione di follow up",
        "ci aggiorniamo", "rivediamoci", "riaggiorniamoci", "un altro incontro", "prossima call", "prossimo meeting",
        // Portuguese
        "nos encontramos", "nos veremos", "nos vemos", "nos reunimos", "proxima reuniao", "reuniao de acompanhamento", "reuniao de follow up",
        "voltamos a nos reunir", "nova reuniao", "marcamos", "a gente se ve", "nos falamos", "retomamos", "proximo encontro", "outra reuniao",
        "reencontrar",
        // Japanese
        "また会", "またお会い", "次回", "次の会議", "次のミーティング", "次の打ち合わせ", "フォローアップ", "改めて", "再度会議", "また集まり", "また打ち合わせ",
        "またミーティング", "もう一度会", "再開しましょう", "またお話し", "また話し",
        // Korean
        "다음 회의", "다음 미팅", "다음 모임", "다시 만나", "다음에 만나", "후속 회의", "또 만나", "다시 모여", "다시 회의", "다시 미팅", "다음에 다시",
        // Chinese (simplified and traditional)
        "下次会议", "下次開會", "下次會議", "下次开会", "再次开会", "再次開會", "再开会", "再開會", "再见面", "再見面", "下次见", "下次見", "跟进会议", "跟進會議",
        "后续会议", "後續會議", "再聚", "再约", "再約", "改天再", "下次碰面", "再碰头", "再碰頭", "再通话", "再通話",
    ].map(TextKeys.norm)

    /// Whether a normalized text contains a cue, as whole words (or as a substring in the scripts written without spaces).
    static func hasCue(_ norm: String) -> Bool { cues.contains { phrase in matches(norm, phrase) } }

    static func matches(_ norm: String, _ phrase: String) -> Bool {
        if phrase.unicodeScalars.contains(where: { TextKeys.isNoSpaceScript($0) || (0xAC00...0xD7AF).contains($0.value) }) { return norm.contains(phrase) }
        return PromptText.containsNormalizedWords(norm, phrase)
    }

    // MARK: Dates

    /// Month names and the abbreviations people write, as normalized keys, by month number (DateWords has the full names).
    static let monthNames: [String: Int] = {
        var out: [String: Int] = [:]
        for (month, names) in DateWords.months { for name in names { out[TextKeys.norm(name)] = month } }
        let extra: [Int: [String]] = [
            1: ["jan", "ene", "janv", "gen"], 2: ["feb", "fev", "febr", "fevr"], 3: ["mar", "mars", "mär", "mrz"], 4: ["apr", "abr", "avr"],
            5: ["may", "mag", "mai"], 6: ["jun", "juin", "giu"], 7: ["jul", "juil", "lug"], 8: ["aug", "aou"], 9: ["sep", "sept"],
            10: ["oct", "okt", "ott"], 11: ["nov"], 12: ["dec", "dic", "dez"],
        ]
        for (month, names) in extra { for name in names { out[TextKeys.norm(name)] = month } }
        return out
    }()

    /// Words before or after a date that put it in the past ("last Tuesday", "el martes pasado", "mardi dernier", "letzten Dienstag").
    static let pastBefore: Set<String> = ["last", "previous", "past", "letzten", "letzter", "letzte", "vergangenen", "vergangenen", "vorigen", "scorso", "scorsa",
                                          "ultimo", "ultima", "anterior", "pasado", "pasada", "passado", "passada", "dernier", "derniere"]
    static let pastAfter: Set<String> = ["pasado", "pasada", "passado", "passada", "dernier", "derniere", "scorso", "scorsa", "anterior", "ago", "atras", "fa",
                                         "vergangenen", "letzten"]
    /// CJK markers that put a day in the past when they come right before it.
    static let pastCJK = ["先週", "先月", "この前", "前回", "上周", "上週", "上个", "上個", "上次", "지난", "저번", "지난주"]

    /// Phrases that look back at an earlier meeting ("last time we spoke on the 3rd"): a date after them is a memory, not a plan.
    /// Normalized keys, so accents are gone.
    static let lookbacks: [String] = [
        "last time", "the last time", "last meeting we", "ultima vez", "la derniere fois", "derniere fois", "letztes mal", "letzte mal", "das letzte mal",
        "ultima volta", "l ultima volta", "前回", "上次", "지난번", "지난 번",
    ].map(TextKeys.norm)

    /// "By Friday", "before the 12th": a deadline, not a meeting.
    static let deadlineBefore: Set<String> = ["by", "before", "until", "till", "antes", "hasta", "avant", "jusqu", "bis", "vor", "entro", "prima", "fino", "ate", "due", "deadline"]
    static let deadlineAfterCJK = ["まで", "までに", "까지", "之前", "前に", "以前"]

    // MARK: Numbers and times

    static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "a": 1, "an": 1,
        "uno": 1, "una": 1, "un": 1, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5, "seis": 6, "siete": 7, "ocho": 8, "nueve": 9, "diez": 10, "once": 11, "doce": 12,
        "deux": 2, "trois": 3, "quatre": 4, "cinq": 5, "sept": 7, "huit": 8, "neuf": 9, "dix": 10, "onze": 11, "douze": 12,
        "eins": 1, "ein": 1, "eine": 1, "zwei": 2, "drei": 3, "vier": 4, "funf": 5, "sechs": 6, "sieben": 7, "acht": 8, "neun": 9, "zehn": 10, "elf": 11, "zwolf": 12,
        "due": 2, "tre": 3, "quattro": 4, "cinque": 5, "sei": 6, "sette": 7, "otto": 8, "nove": 9, "dieci": 10, "undici": 11, "dodici": 12,
        "duas": 2, "quatro": 4, "oito": 8, "dez": 10, "doze": 12, "um": 1, "uma": 1,
        "一": 1, "二": 2, "两": 2, "兩": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10,
    ]

    /// Words that stand before an hour in the nine languages ("at ten", "a las 10", "à 10 heures", "um 10 Uhr", "alle 10", "às 10").
    static let hourLeaders: Set<String> = ["at", "a", "las", "la", "um", "alle", "ore", "as", "vers", "gegen", "ab", "around", "about", "to"]
    static let hourTrailers: Set<String> = ["uhr", "h", "heures", "heure", "horas", "hora", "ore", "oclock"]
    static let pm: Set<String> = ["pm", "tarde", "soir", "abends", "nachmittags", "pomeriggio", "sera", "noite", "afternoon", "evening"]
    static let am: Set<String> = ["am", "matin", "morgens", "vormittags", "mattina", "morning"]
    /// CJK markers (matched as substrings of the text around the hour).
    static let pmCJK = ["午後", "오후", "下午", "晚上", "夜"]
    static let amCJK = ["午前", "오전", "上午", "早上", "朝"]
}
