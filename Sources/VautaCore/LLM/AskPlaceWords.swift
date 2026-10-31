// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The words `AskMeetingPlace` reads a meeting's place in ("the last meeting", "la reunión anterior", "前回の会議"), written as people
/// write them and compared as `TextKeys.norm` keys, like `AskTimeWords` (whose meeting nouns and numbers it shares).
enum AskPlaceWords {
    enum Kind: Sendable, Equatable { case last, first, beforeLast }

    struct Lexicon: Sendable {
        /// Right before the meeting noun ("the last meeting", "la primera reunión"), with what they name.
        var before: [(words: [String], kind: Kind)] = []
        /// Right after it ("la reunión anterior", "the meeting before last").
        var after: [(words: [String], kind: Kind)] = []
        /// The plural meeting nouns: "the last meetings" without a number is the last three.
        var plurals: Set<String> = []
        /// The words that may stand between a word that makes it a point in time and the place ("since the last meeting").
        var articles: Set<String> = []
        /// Right before the place (or its article): it is a point in time, not meetings to look in ("since the last meeting", "antes de
        /// la última reunión").
        var around: [[String]] = []
        /// Skipped right after the place ("the last meeting we had with Ana").
        var had: [[String]] = []
        /// Right after the place: who or what it was with or about ("with Ana", "sobre Kobaltix"), or a clause that says it by what was
        /// said in it ("where we discussed Kobaltix"). Either way only the meetings that name the question's people or projects count.
        var of: [[String]] = []
        /// Ordinal words: one elsewhere in the clause compares meetings ("between the third and the last meeting", "from the second to
        /// the fourth meeting"), and the place is not read.
        var ordinals: Set<String> = []
    }

    /// German ordinals in their five endings.
    private static func declined(_ stems: [String]) -> Set<String> {
        Set(stems.flatMap { stem in ["e", "en", "er", "es", "em"].map { TextKeys.norm(stem + $0) } })
    }

    static func phrases(_ texts: [String]) -> [[String]] {
        texts.map { TextKeys.norm($0).split(separator: " ").map(String.init) }
    }

    private static func kinds(_ entries: [(String, Kind)]) -> [(words: [String], kind: Kind)] {
        entries.map { (TextKeys.norm($0.0).split(separator: " ").map(String.init), $0.1) }
    }

    private static func keys(_ texts: [String]) -> Set<String> { Set(texts.map(TextKeys.norm)) }

    static let latin: [String: Lexicon] = ["en": english, "es": spanish, "fr": french, "de": german, "it": italian, "pt": portuguese]

    private static let english = Lexicon(
        before: kinds([("last", .last), ("latest", .last), ("most recent", .last), ("previous", .last), ("prior", .last), ("recent", .last),
                       ("first", .first), ("very first", .first), ("penultimate", .beforeLast), ("second to last", .beforeLast),
                       ("second last", .beforeLast), ("next to last", .beforeLast)]),
        after: kinds([("before last", .beforeLast)]),
        plurals: keys(["meetings", "calls", "syncs", "standups", "sessions", "workshops", "interviews"]),
        articles: keys(["the", "our", "my", "this", "that"]),
        around: phrases(["since", "before", "after", "until", "till", "prior to", "ahead of", "by"]),
        had: phrases(["we had", "i had", "you had", "we held", "i attended", "we did", "that we had", "that i had", "which we had"]),
        of: phrases(["with", "about", "regarding", "on", "where", "in which", "at which", "when", "that", "which"]),
        ordinals: keys(["first", "second", "third", "fourth", "fifth", "sixth", "last", "latest", "final", "previous", "earlier", "penultimate",
                        "kick", "kickoff", "initial", "opening"]))

    private static let spanish = Lexicon(
        before: kinds([("última", .last), ("últimas", .last), ("último", .last), ("últimos", .last), ("anterior", .last), ("más reciente", .last),
                       ("primera", .first), ("primeras", .first), ("primer", .first), ("primeros", .first),
                       ("penúltima", .beforeLast), ("penúltimo", .beforeLast)]),
        after: kinds([("anterior", .last), ("anteriores", .last), ("pasada", .last), ("pasadas", .last), ("pasado", .last),
                      ("más reciente", .last), ("más recientes", .last)]),
        plurals: keys(["reuniones", "llamadas", "juntas", "sesiones", "videollamadas", "entrevistas", "talleres"]),
        articles: keys(["la", "las", "el", "los", "nuestra", "nuestras", "nuestro", "mi", "mis"]),
        around: phrases(["desde", "antes de", "antes del", "después de", "después del", "hasta", "tras"]),
        had: phrases(["que tuvimos", "que tuve", "que hicimos", "que celebramos"]),
        of: phrases(["con", "sobre", "acerca de", "en la que", "en las que", "en el que", "en que", "donde", "que", "cuando"]),
        ordinals: keys(["primera", "primer", "primero", "segunda", "segundo", "tercera", "tercer", "tercero", "cuarta", "cuarto", "quinta", "quinto",
                        "última", "último", "anterior", "penúltima", "penúltimo", "final", "inicial", "lanzamiento", "arranque"]))

    private static let french = Lexicon(
        before: kinds([("dernière", .last), ("dernières", .last), ("dernier", .last), ("derniers", .last), ("précédente", .last),
                       ("plus récente", .last), ("première", .first), ("premières", .first), ("premier", .first), ("premiers", .first),
                       ("avant-dernière", .beforeLast), ("avant-dernier", .beforeLast)]),
        after: kinds([("précédente", .last), ("précédentes", .last), ("précédent", .last), ("la plus récente", .last), ("le plus récent", .last)]),
        plurals: keys(["réunions", "appels", "séances", "entretiens", "ateliers"]),
        articles: keys(["la", "le", "les", "l", "notre", "nos", "ma", "mon", "mes"]),
        around: phrases(["depuis", "avant", "après", "jusqu à"]),
        had: phrases(["qu on a eue", "que nous avons eue", "qu on a faite", "que j ai eue"]),
        of: phrases(["avec", "sur", "à propos de", "concernant", "où", "dans laquelle", "lors de laquelle", "qui", "que", "quand"]),
        ordinals: keys(["première", "premier", "deuxième", "second", "seconde", "troisième", "quatrième", "cinquième", "dernière", "dernier",
                        "précédente", "précédent", "finale", "final", "initiale", "lancement"]))

    private static let german = Lexicon(
        before: kinds([("letzte", .last), ("letzten", .last), ("letzter", .last), ("letztes", .last), ("letztem", .last),
                       ("vorige", .last), ("vorigen", .last), ("voriger", .last), ("voriges", .last), ("vorigem", .last),
                       ("vorherige", .last), ("vorherigen", .last), ("vorheriger", .last), ("vorheriges", .last), ("vorherigem", .last),
                       ("jüngste", .last), ("jüngsten", .last), ("neueste", .last), ("neuesten", .last),
                       ("erste", .first), ("ersten", .first), ("erster", .first), ("erstes", .first), ("erstem", .first),
                       ("vorletzte", .beforeLast), ("vorletzten", .beforeLast), ("vorletzter", .beforeLast), ("vorletztes", .beforeLast),
                       ("vorletztem", .beforeLast)]),
        plurals: keys(["Meetings", "Besprechungen", "Termine", "Sitzungen", "Calls", "Telefonate", "Gespräche", "Workshops"]),
        articles: keys(["der", "die", "das", "dem", "den", "des", "unser", "unsere", "unserem", "unserer", "unseren", "mein", "meinem", "meiner"]),
        around: phrases(["seit", "vor", "nach", "bis", "bis zum", "bis zur", "seit dem", "vor dem", "nach dem"]),
        had: phrases(["das wir hatten", "die wir hatten", "den wir hatten", "das ich hatte", "die ich hatte"]),
        of: phrases(["mit", "über", "zu", "zum", "zur", "in dem", "in der", "bei dem", "bei der", "an dem", "auf dem", "in welchem",
                     "in welcher", "wo", "als"]),
        ordinals: declined(["erst", "zweit", "dritt", "viert", "fünft", "letzt", "vorletzt", "vorig", "vorherig"])
            .union(keys(["Auftakt", "Kickoff", "Kick"])))

    private static let italian = Lexicon(
        before: kinds([("ultima", .last), ("ultime", .last), ("ultimo", .last), ("ultimi", .last), ("precedente", .last), ("più recente", .last),
                       ("prima", .first), ("prime", .first), ("primo", .first), ("primi", .first),
                       ("penultima", .beforeLast), ("penultimo", .beforeLast)]),
        after: kinds([("precedente", .last), ("precedenti", .last), ("scorsa", .last), ("scorse", .last), ("scorso", .last),
                      ("più recente", .last), ("più recenti", .last)]),
        plurals: keys(["riunioni", "chiamate", "incontri", "sessioni", "colloqui", "videochiamate"]),
        articles: keys(["la", "le", "l", "il", "lo", "i", "gli", "nostra", "nostre", "nostro", "nostri", "mia", "mio"]),
        around: phrases(["da", "dall", "dalla", "dalle", "dal", "dai", "dopo", "prima di", "prima del", "prima della", "prima dell", "fino a",
                         "fino alla", "fino all"]),
        had: phrases(["che abbiamo avuto", "che abbiamo fatto", "che ho avuto"]),
        of: phrases(["con", "su", "sul", "sulla", "sullo", "riguardo", "in cui", "nella quale", "durante la quale", "dove", "che", "quando"]),
        ordinals: keys(["prima", "primo", "seconda", "secondo", "terza", "terzo", "quarta", "quarto", "ultima", "ultimo", "precedente", "penultima",
                        "finale", "iniziale", "lancio"]))

    private static let portuguese = Lexicon(
        before: kinds([("última", .last), ("últimas", .last), ("último", .last), ("últimos", .last), ("mais recente", .last),
                       ("primeira", .first), ("primeiras", .first), ("primeiro", .first), ("primeiros", .first),
                       ("penúltima", .beforeLast), ("penúltimo", .beforeLast)]),
        after: kinds([("anterior", .last), ("anteriores", .last), ("passada", .last), ("passadas", .last), ("passado", .last),
                      ("mais recente", .last), ("mais recentes", .last)]),
        plurals: keys(["reuniões", "chamadas", "ligações", "sessões", "conversas", "encontros"]),
        articles: keys(["a", "as", "o", "os", "nossa", "nossas", "nosso", "nossos", "minha", "meu"]),
        around: phrases(["desde", "antes da", "antes do", "antes de", "depois da", "depois do", "depois de", "até", "após"]),
        had: phrases(["que tivemos", "que tive", "que fizemos"]),
        of: phrases(["com", "sobre", "a respeito de", "em que", "na qual", "no qual", "onde", "que", "quando"]),
        ordinals: keys(["primeira", "primeiro", "segunda", "segundo", "terceira", "terceiro", "quarta", "quarto", "última", "último", "anterior",
                        "penúltima", "final", "inicial", "lançamento"]))

    // MARK: Japanese, Korean, Chinese

    /// Patterns with an optional named group `n` (a count). The place counts only next to a meeting noun; `ofBefore` right before it
    /// ("Anaとの", "Ana와의", "和Ana的") narrows it to the people or projects the question names, and so does a clause that ends right
    /// before it (`modifierEnds`: "予算を話し合った最後の会議").
    struct Script: Sendable {
        var patterns: [(regex: String, kind: Kind)] = []
        var ofBefore: [String] = []
        var modifierEnds: Set<Character> = []
        var aroundAfter: [String] = [], aroundBefore: [String] = []
        /// Another ordinal before or after the place compares meetings ("第二次和最后一次会议", "3回目と最後の会議"): not read.
        var otherOrdinals = ""
    }

    static let scripts: [String: Script] = ["ja": japanese, "ko": korean, "zh": chinese]

    private static let jaMeeting = "(?:会議|ミーティング|打ち合わせ|打合せ|通話|面談|定例|会合)"
    private static let koMeeting = "(?:회의|미팅|통화|면담|모임)"
    private static let zhMeeting = "(?:会议|會議|开会|開會|例会|例會|通话|通話|讨论会|討論會|会上|會上)"
    private static let koCount = "(?<n>[0-9]{1,2}|한|두|세|네|다섯|여섯|일곱|여덟|아홉|열)"
    private static let hanCount = "(?<n>[0-9]{1,2}|[一二三四五六七八九十两兩]{1,2})"

    private static let japanese = Script(
        patterns: [("前々回(?:の\\s?\(jaMeeting))?", .beforeLast),
                   ("(?:直近|最近|過去|ここ)\\s?\(hanCount)\\s?回の?\\s?\(jaMeeting)", .last),
                   ("前回(?:の\\s?\(jaMeeting))?", .last),
                   ("(?:最後|直近|最新|この前|この間)の\\s?\(jaMeeting)", .last),
                   ("(?:最初|初回|第一回|第1回|初めて)の\\s?\(jaMeeting)", .first)],
        ofBefore: ["との", "と"],
        modifierEnds: ["た", "だ"],
        aroundAfter: ["から", "以来", "以降", "まで", "より前", "以前", "の前", "の後", "前に", "後に"],
        otherOrdinals: "第\\s?[0-9一二三四五六七八九十]+\\s?回|[0-9一二三四五六七八九十]+\\s?回目|最初|最後|初回|前回|前々回")

    private static let korean = Script(
        patterns: [("(?:지지난번|지지난)\\s?(?:의\\s?)?\(koMeeting)", .beforeLast),
                   ("(?:지난|최근|마지막)\\s?\(koCount)\\s?(?:번의|번|차례의|차례)\\s?\(koMeeting)", .last),
                   ("(?:지난번|지난|저번|마지막|최근|직전|이전)\\s?(?:의\\s?)?\(koMeeting)", .last),
                   ("(?:첫\\s?번째|첫|처음|최초의?)\\s?\(koMeeting)", .first)],
        ofBefore: ["와의", "과의", "하고의", "와", "과", "하고"],
        // An adnominal ending (논의한, 했던, 하는): the syllable before the place ends in ㄴ or ㄹ (`AskMeetingPlace.endsInModifier`).
        aroundAfter: ["부터", "이후", "이래", "까지", "전에", "전까지", "후에"],
        otherOrdinals: "[0-9]+\\s?번째|(?:두|세|네|다섯|여섯)\\s?번째|첫\\s?번째|처음|마지막")

    private static let chinese = Script(
        patterns: [("上上次\\s?的?\\s?\(zhMeeting)", .beforeLast),
                   ("(?:最近|过去|過去|最后|最後)\\s?的?\\s?\(hanCount)\\s?次\\s?的?\\s?\(zhMeeting)", .last),
                   ("(?:上次|上一次|上回|上一回|最近一次|最后一次|最後一次|前一次)\\s?的?\\s?\(zhMeeting)", .last),
                   ("(?:第一次|首次|头一次|頭一次)\\s?的?\\s?\(zhMeeting)", .first)],
        ofBefore: ["的"],
        aroundAfter: ["以来", "以來", "之后", "之後", "以后", "以後", "之前", "以前", "前"],
        aroundBefore: ["自从", "自從", "从", "從", "自", "截至", "直到"],
        otherOrdinals: "第\\s?[0-9一二三四五六七八九十]+\\s?次|最后|最後|上次|上一次|首次")
}
