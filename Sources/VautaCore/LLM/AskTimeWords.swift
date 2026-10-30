// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The words `AskTimeScope` reads the time of a question in, for the languages written with spaces: English, Spanish, French,
/// German, Italian and Portuguese (Japanese, Korean and Chinese are in `AskTimeWords+CJK`). Written as people write them and
/// compared as normalized keys (`TextKeys.norm`: lowercase, no accents, punctuation as spaces), so "aujourd’hui" is
/// "aujourd hui". Not a language model: it knows these phrases and nothing more.
enum AskTimeWords {
    /// A stretch of the calendar told by its distance from today: `day(-1)` is yesterday, `week(0)` this week.
    enum Relative: Sendable, Equatable {
        case day(Int), week(Int), month(Int), quarter(Int), year(Int)
        /// The last n units, up to today ("the last two weeks").
        case rolling(Unit, Int)
    }

    enum Unit: Sendable, Equatable { case day, week, month, year }

    struct Phrase: Sendable {
        let words: [String]
        let period: Relative
        /// Names the period that is going on ("today", "this week"), which a question uses as often for what is due then as for
        /// the meetings held then. "This morning" is over: it is not.
        let current: Bool
    }

    /// One language's words. Leaders and nouns are phrases of one to three words.
    struct Lexicon: Sendable {
        var periods: [Phrase] = []
        /// Periods said as an adjective, always of a noun ("im gestrigen Meeting", "die gestrigen Zahlen").
        var adjectives: [Phrase] = []
        /// Phrases that contain a period word without naming it ("hoy en día": nowadays).
        var excluded: [[String]] = []
        /// "hace <n> días", "<n> days ago".
        var agoBefore: [[String]] = [], agoAfter: [[String]] = []
        /// "the last <n> days"; French puts the word between ("les 3 derniers jours").
        var lastBefore: [[String]] = [], lastBetween: [[String]] = []
        var units: [String: (unit: Unit, count: Int)] = [:]
        /// "last Monday", "el lunes pasado".
        var weekdayBefore: [[String]] = [], weekdayAfter: [[String]] = []
        var months: [String: Int] = [:]
        var quarter: [String] = [], ordinals: [String: Int] = [:]
        /// Words before a time that make it a deadline ("by", "hasta"), the start of a stretch up to today ("since"), the time in
        /// which something happened ("in", "during") or what something is of ("the minutes of", "las ventas de").
        var deadline: [[String]] = [], since: [[String]] = [], into: [[String]] = [], genitive: [[String]] = []
        /// English "last week's": the possessive "s" after the time.
        var possessive = false
        var meetings: [[String]] = []
    }

    private static func phrases(_ texts: [String]) -> [[String]] {
        texts.map { TextKeys.norm($0).split(separator: " ").map(String.init) }
    }

    private static func periods(_ entries: [(String, Relative)], current: Set<String> = []) -> [Phrase] {
        entries.map { text, period in
            Phrase(words: TextKeys.norm(text).split(separator: " ").map(String.init), period: period, current: current.contains(text))
        }
    }

    private static func units(_ entries: [(String, Unit, Int)]) -> [String: (unit: Unit, count: Int)] {
        Dictionary(entries.map { (TextKeys.norm($0.0), (unit: $0.1, count: $0.2)) }) { a, _ in a }
    }

    private static func months(_ names: [[String]]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (i, list) in names.enumerated() { for name in list { out[TextKeys.norm(name)] = i + 1 } }
        return out
    }

    private static func ordinals(_ entries: [(String, Int)]) -> [String: Int] {
        Dictionary(entries.map { (TextKeys.norm($0.0), $0.1) }) { a, _ in a }
    }

    /// Numbers written as words, in the six languages (`FollowUpWords.numberWords` plus the forms a stretch of time takes:
    /// "vor einer Woche", "dois meses", "quince días").
    static let numbers: [String: Int] = FollowUpWords.numberWords.merging([
        "une": 1, "einem": 1, "einer": 1, "einen": 1, "dois": 2, "sete": 7, "fourteen": 14, "fifteen": 15, "catorce": 14, "quince": 15,
        "quatorze": 14, "quinze": 15, "vierzehn": 14, "funfzehn": 15, "quattordici": 14, "quindici": 15,
    ]) { a, _ in a }

    /// Weekday names in the six languages (Calendar numbering, 1 = Sunday), including Portuguese "segunda", "quinta" and "sexta",
    /// which name a day here only with a word that puts it in the past ("na segunda passada").
    static let weekdays: [String: Int] = {
        var out: [String: Int] = [:]
        for (day, names) in DateWords.weekdays { for name in names where !name.unicodeScalars.contains(where: { $0.value > 0x2FFF }) { out[name] = day } }
        for (day, name) in DateWords.ambiguousWeekdays { out[name] = day }
        return out
    }()

    static let latin: [String: Lexicon] = ["en": english, "es": spanish, "fr": french, "de": german, "it": italian, "pt": portuguese]

    private static let english = Lexicon(
        periods: periods([
            ("the day before yesterday", .day(-2)), ("yesterday", .day(-1)), ("this morning", .day(0)), ("earlier today", .day(0)), ("today", .day(0)),
            ("this week", .week(0)), ("last week", .week(-1)), ("previous week", .week(-1)), ("past week", .rolling(.week, 1)),
            ("this month", .month(0)), ("last month", .month(-1)), ("previous month", .month(-1)), ("past month", .rolling(.month, 1)),
            ("this quarter", .quarter(0)), ("last quarter", .quarter(-1)), ("previous quarter", .quarter(-1)),
            ("this year", .year(0)), ("last year", .year(-1)), ("past year", .rolling(.year, 1)),
        ], current: ["today", "this week", "this month", "this quarter", "this year"]),
        agoAfter: phrases(["ago"]),
        lastBefore: phrases(["last", "past"]),
        units: units([("day", .day, 1), ("days", .day, 1), ("week", .week, 1), ("weeks", .week, 1), ("fortnight", .week, 2), ("fortnights", .week, 2),
                      ("month", .month, 1), ("months", .month, 1), ("year", .year, 1), ("years", .year, 1)]),
        weekdayBefore: phrases(["last", "this past"]),
        // "May" is left out: it is also a verb.
        months: months([["january"], ["february"], ["march"], ["april"], [], ["june"], ["july"], ["august"], ["september"], ["october"], ["november"], ["december"]]),
        quarter: ["quarter"], ordinals: ordinals([("first", 1), ("1st", 1), ("second", 2), ("2nd", 2), ("third", 3), ("3rd", 3), ("fourth", 4), ("4th", 4)]),
        deadline: phrases(["by", "before", "until", "till", "due", "for", "deadline", "next"]),
        since: phrases(["since"]),
        into: phrases(["in", "during", "on", "at", "throughout", "over"]),
        genitive: phrases(["of", "from", "about"]),
        possessive: true,
        meetings: phrases(["meeting", "meetings", "call", "calls", "sync", "syncs", "standup", "standups", "stand up", "session", "sessions",
                           "retro", "retrospective", "workshop", "workshops", "interview", "interviews", "catch up", "one on one"]))

    private static let spanish = Lexicon(
        periods: periods([
            ("anteayer", .day(-2)), ("antier", .day(-2)), ("antes de ayer", .day(-2)), ("ayer", .day(-1)), ("esta mañana", .day(0)), ("hoy", .day(0)),
            ("esta semana", .week(0)), ("la semana pasada", .week(-1)), ("semana pasada", .week(-1)), ("la pasada semana", .week(-1)),
            ("la semana anterior", .week(-1)), ("este mes", .month(0)), ("el mes pasado", .month(-1)), ("mes pasado", .month(-1)),
            ("el pasado mes", .month(-1)), ("el mes anterior", .month(-1)), ("este trimestre", .quarter(0)), ("el trimestre pasado", .quarter(-1)),
            ("trimestre pasado", .quarter(-1)), ("el trimestre anterior", .quarter(-1)), ("este año", .year(0)), ("el año pasado", .year(-1)),
            ("año pasado", .year(-1)), ("el pasado año", .year(-1)),
        ], current: ["hoy", "esta semana", "este mes", "este trimestre", "este año"]),
        excluded: phrases(["hoy en día", "hoy por hoy"]),
        agoBefore: phrases(["hace"]), agoAfter: phrases(["atrás"]),
        lastBefore: phrases(["últimos", "últimas"]),
        units: units([("día", .day, 1), ("días", .day, 1), ("semana", .week, 1), ("semanas", .week, 1), ("quincena", .week, 2),
                      ("mes", .month, 1), ("meses", .month, 1), ("año", .year, 1), ("años", .year, 1)]),
        weekdayBefore: phrases(["pasado", "último"]), weekdayAfter: phrases(["pasado"]),
        months: months([["enero"], ["febrero"], ["marzo"], ["abril"], ["mayo"], ["junio"], ["julio"], ["agosto"], ["septiembre", "setiembre"],
                        ["octubre"], ["noviembre"], ["diciembre"]]),
        quarter: ["trimestre"], ordinals: ordinals([("primer", 1), ("primero", 1), ("segundo", 2), ("tercer", 3), ("tercero", 3), ("cuarto", 4)]),
        deadline: phrases(["para", "hasta", "antes de", "antes del", "plazo", "a más tardar", "próximo", "próxima"]),
        since: phrases(["desde", "a partir de", "a partir del"]),
        into: phrases(["en", "el", "durante", "a lo largo de"]),
        genitive: phrases(["de", "del", "sobre"]),
        meetings: phrases(["reunión", "reuniones", "llamada", "llamadas", "junta", "juntas", "sesión", "sesiones", "videollamada", "videollamadas",
                           "entrevista", "entrevistas", "taller", "talleres", "comité", "daily"]))

    private static let french = Lexicon(
        periods: periods([
            ("avant-hier", .day(-2)), ("hier", .day(-1)), ("ce matin", .day(0)), ("aujourd’hui", .day(0)),
            ("cette semaine", .week(0)), ("la semaine dernière", .week(-1)), ("semaine dernière", .week(-1)), ("la semaine passée", .week(-1)),
            ("la semaine précédente", .week(-1)), ("ce mois-ci", .month(0)), ("ce mois", .month(0)), ("le mois dernier", .month(-1)),
            ("mois dernier", .month(-1)), ("le mois passé", .month(-1)), ("le mois précédent", .month(-1)), ("ce trimestre", .quarter(0)),
            ("le trimestre dernier", .quarter(-1)), ("trimestre dernier", .quarter(-1)), ("le trimestre précédent", .quarter(-1)),
            ("cette année", .year(0)), ("l’année dernière", .year(-1)), ("année dernière", .year(-1)), ("l’an dernier", .year(-1)),
            ("l’année passée", .year(-1)), ("l’an passé", .year(-1)),
        ], current: ["aujourd’hui", "cette semaine", "ce mois-ci", "ce mois", "ce trimestre", "cette année"]),
        excluded: phrases(["au jour d’aujourd’hui"]),
        agoBefore: phrases(["il y a", "y a"]),
        lastBetween: phrases(["derniers", "dernières"]),
        units: units([("jour", .day, 1), ("jours", .day, 1), ("semaine", .week, 1), ("semaines", .week, 1), ("quinzaine", .week, 2),
                      ("mois", .month, 1), ("an", .year, 1), ("ans", .year, 1), ("année", .year, 1), ("années", .year, 1)]),
        weekdayAfter: phrases(["dernier", "passé"]),
        months: months([["janvier"], ["février"], ["mars"], ["avril"], ["mai"], ["juin"], ["juillet"], ["août"], ["septembre"], ["octobre"],
                        ["novembre"], ["décembre"]]),
        quarter: ["trimestre"], ordinals: ordinals([("premier", 1), ("1er", 1), ("deuxième", 2), ("second", 2), ("2e", 2), ("troisième", 3), ("3e", 3),
                                                     ("quatrième", 4), ("4e", 4)]),
        deadline: phrases(["pour", "avant", "jusqu’à", "jusqu’au", "d’ici", "au plus tard", "prochain", "prochaine"]),
        since: phrases(["depuis", "à partir de", "à partir du"]),
        into: phrases(["en", "le", "pendant", "durant", "au", "au cours de"]),
        genitive: phrases(["de", "du", "d", "des", "sur"]),
        meetings: phrases(["réunion", "réunions", "appel", "appels", "séance", "séances", "visio", "visioconférence", "call", "entretien", "entretiens",
                           "atelier", "ateliers", "comité"]))

    private static let german = Lexicon(
        periods: periods([
            ("vorgestern", .day(-2)), ("gestern", .day(-1)), ("heute Morgen", .day(0)), ("heute früh", .day(0)), ("heute Vormittag", .day(0)), ("heute", .day(0)),
            ("diese Woche", .week(0)), ("dieser Woche", .week(0)), ("letzte Woche", .week(-1)), ("letzten Woche", .week(-1)), ("letzter Woche", .week(-1)),
            ("vergangene Woche", .week(-1)), ("vergangenen Woche", .week(-1)), ("vorige Woche", .week(-1)), ("vorigen Woche", .week(-1)),
            ("diesen Monat", .month(0)), ("diesem Monat", .month(0)), ("dieses Monats", .month(0)), ("letzten Monat", .month(-1)), ("letzter Monat", .month(-1)),
            ("letzten Monats", .month(-1)), ("vergangenen Monat", .month(-1)), ("vergangenen Monats", .month(-1)), ("vorigen Monat", .month(-1)),
            ("dieses Quartal", .quarter(0)), ("diesem Quartal", .quarter(0)), ("letztes Quartal", .quarter(-1)), ("letzten Quartal", .quarter(-1)),
            ("vergangenen Quartal", .quarter(-1)), ("vorigen Quartal", .quarter(-1)), ("dieses Jahr", .year(0)), ("diesem Jahr", .year(0)),
            ("letztes Jahr", .year(-1)), ("letzten Jahr", .year(-1)), ("vergangenes Jahr", .year(-1)), ("vergangenen Jahr", .year(-1)),
            ("voriges Jahr", .year(-1)), ("vorigen Jahr", .year(-1)), ("letzten Jahres", .year(-1)), ("letztem Monat", .month(-1)),
            ("vergangenem Monat", .month(-1)), ("vorigem Monat", .month(-1)), ("letztem Quartal", .quarter(-1)), ("letztem Jahr", .year(-1)),
            ("vergangenem Jahr", .year(-1)),
        ], current: ["heute", "diese Woche", "dieser Woche", "diesen Monat", "diesem Monat", "dieses Monats", "dieses Quartal", "diesem Quartal",
                     "dieses Jahr", "diesem Jahr"]),
        adjectives: periods([("vorgestrigen", .day(-2)), ("vorgestrige", .day(-2)), ("gestrigen", .day(-1)), ("gestrige", .day(-1)),
                             ("gestriges", .day(-1)), ("heutigen", .day(0)), ("heutige", .day(0)), ("heutiges", .day(0))],
                            current: ["heutigen", "heutige", "heutiges"]),
        agoBefore: phrases(["vor"]),
        lastBefore: phrases(["letzten", "vergangenen"]),
        units: units([("Tag", .day, 1), ("Tage", .day, 1), ("Tagen", .day, 1), ("Woche", .week, 1), ("Wochen", .week, 1), ("Monat", .month, 1),
                      ("Monate", .month, 1), ("Monaten", .month, 1), ("Jahr", .year, 1), ("Jahre", .year, 1), ("Jahren", .year, 1)]),
        weekdayBefore: phrases(["letzten", "letzter", "vergangenen", "vorigen"]),
        months: months([["Januar", "Jänner"], ["Februar"], ["März"], ["April"], ["Mai"], ["Juni"], ["Juli"], ["August"], ["September"], ["Oktober"],
                        ["November"], ["Dezember"]]),
        quarter: ["quartal", "quartals"], ordinals: ordinals([("erste", 1), ("ersten", 1), ("erstes", 1), ("zweite", 2), ("zweiten", 2), ("zweites", 2),
                                                             ("dritte", 3), ("dritten", 3), ("drittes", 3), ("vierte", 4), ("vierten", 4), ("viertes", 4)]),
        deadline: phrases(["bis", "vor", "für", "spätestens", "nächste", "nächsten", "kommende", "kommenden"]),
        since: phrases(["seit", "ab"]),
        into: phrases(["im", "in", "während", "am", "in der", "in den"]),
        genitive: phrases(["vom", "von", "des", "der", "aus", "über"]),
        meetings: phrases(["Meeting", "Meetings", "Besprechung", "Besprechungen", "Termin", "Termine", "Sitzung", "Sitzungen", "Call", "Calls",
                           "Telefonat", "Telefonate", "Gespräch", "Gespräche", "Runde", "Workshop", "Workshops", "Standup", "Daily", "Jour fixe",
                           "Konferenz", "Telefonkonferenz", "Videokonferenz"]))

    private static let italian = Lexicon(
        periods: periods([
            ("l’altro ieri", .day(-2)), ("altro ieri", .day(-2)), ("altroieri", .day(-2)), ("ieri l’altro", .day(-2)), ("ieri", .day(-1)),
            ("stamattina", .day(0)), ("stamani", .day(0)), ("questa mattina", .day(0)), ("oggi", .day(0)),
            ("questa settimana", .week(0)), ("la settimana scorsa", .week(-1)), ("settimana scorsa", .week(-1)), ("la scorsa settimana", .week(-1)),
            ("scorsa settimana", .week(-1)), ("la settimana passata", .week(-1)), ("settimana passata", .week(-1)), ("questo mese", .month(0)),
            ("il mese scorso", .month(-1)), ("mese scorso", .month(-1)), ("lo scorso mese", .month(-1)), ("scorso mese", .month(-1)),
            ("il mese passato", .month(-1)), ("questo trimestre", .quarter(0)), ("il trimestre scorso", .quarter(-1)), ("trimestre scorso", .quarter(-1)),
            ("lo scorso trimestre", .quarter(-1)), ("quest’anno", .year(0)), ("questo anno", .year(0)), ("l’anno scorso", .year(-1)),
            ("anno scorso", .year(-1)), ("lo scorso anno", .year(-1)), ("l’anno passato", .year(-1)),
        ], current: ["oggi", "questa settimana", "questo mese", "questo trimestre", "quest’anno", "questo anno"]),
        excluded: phrases(["oggi giorno", "al giorno d’oggi"]),
        agoAfter: phrases(["fa"]),
        lastBefore: phrases(["ultimi", "ultime"]),
        units: units([("giorno", .day, 1), ("giorni", .day, 1), ("settimana", .week, 1), ("settimane", .week, 1), ("mese", .month, 1), ("mesi", .month, 1),
                      ("anno", .year, 1), ("anni", .year, 1)]),
        weekdayBefore: phrases(["scorso", "scorsa"]), weekdayAfter: phrases(["scorso", "scorsa", "passato", "passata"]),
        months: months([["gennaio"], ["febbraio"], ["marzo"], ["aprile"], ["maggio"], ["giugno"], ["luglio"], ["agosto"], ["settembre"], ["ottobre"],
                        ["novembre"], ["dicembre"]]),
        quarter: ["trimestre"], ordinals: ordinals([("primo", 1), ("secondo", 2), ("terzo", 3), ("quarto", 4)]),
        deadline: phrases(["entro", "per", "prima di", "prima del", "prima della", "fino a", "fino al", "non oltre", "prossimo", "prossima"]),
        since: phrases(["da", "dal", "dalla", "dallo", "a partire da", "a partire dal"]),
        into: phrases(["a", "ad", "il", "in", "nel", "nella", "durante", "nel corso di"]),
        genitive: phrases(["di", "del", "della", "dello", "dei", "delle", "su", "sul"]),
        meetings: phrases(["riunione", "riunioni", "chiamata", "chiamate", "call", "incontro", "incontri", "sessione", "sessioni", "meeting", "colloquio",
                           "colloqui", "videochiamata", "videochiamate", "workshop"]))

    private static let portuguese = Lexicon(
        periods: periods([
            ("anteontem", .day(-2)), ("antes de ontem", .day(-2)), ("ontem", .day(-1)), ("hoje de manhã", .day(0)), ("hoje cedo", .day(0)),
            ("esta manhã", .day(0)), ("nesta manhã", .day(0)), ("hoje", .day(0)),
            ("esta semana", .week(0)), ("nesta semana", .week(0)), ("essa semana", .week(0)), ("nessa semana", .week(0)),
            ("semana passada", .week(-1)), ("a semana passada", .week(-1)), ("na semana passada", .week(-1)), ("semana anterior", .week(-1)),
            ("na semana anterior", .week(-1)), ("este mês", .month(0)), ("neste mês", .month(0)), ("esse mês", .month(0)), ("nesse mês", .month(0)),
            ("mês passado", .month(-1)), ("o mês passado", .month(-1)), ("no mês passado", .month(-1)), ("mês anterior", .month(-1)),
            ("no mês anterior", .month(-1)), ("este trimestre", .quarter(0)), ("neste trimestre", .quarter(0)), ("trimestre passado", .quarter(-1)),
            ("no trimestre passado", .quarter(-1)), ("este ano", .year(0)), ("neste ano", .year(0)), ("esse ano", .year(0)), ("ano passado", .year(-1)),
            ("o ano passado", .year(-1)), ("no ano passado", .year(-1)),
        ], current: ["hoje", "esta semana", "nesta semana", "essa semana", "nessa semana", "este mês", "neste mês", "esse mês", "nesse mês",
                     "este trimestre", "neste trimestre", "este ano", "neste ano", "esse ano"]),
        excluded: phrases(["hoje em dia"]),
        agoBefore: phrases(["há", "faz"]), agoAfter: phrases(["atrás"]),
        lastBefore: phrases(["últimos", "últimas"]),
        units: units([("dia", .day, 1), ("dias", .day, 1), ("semana", .week, 1), ("semanas", .week, 1), ("quinzena", .week, 2), ("mês", .month, 1),
                      ("meses", .month, 1), ("ano", .year, 1), ("anos", .year, 1)]),
        weekdayBefore: phrases(["última", "último"]), weekdayAfter: phrases(["passada", "passado"]),
        months: months([["janeiro"], ["fevereiro"], ["março"], ["abril"], ["maio"], ["junho"], ["julho"], ["agosto"], ["setembro"], ["outubro"],
                        ["novembro"], ["dezembro"]]),
        quarter: ["trimestre"], ordinals: ordinals([("primeiro", 1), ("segundo", 2), ("terceiro", 3), ("quarto", 4)]),
        deadline: phrases(["até", "para", "antes de", "antes do", "antes da", "prazo", "no máximo", "próximo", "próxima"]),
        since: phrases(["desde", "a partir de", "a partir do", "a partir da"]),
        into: phrases(["em", "no", "na", "o", "durante", "ao longo de"]),
        genitive: phrases(["de", "do", "da", "dos", "das", "sobre"]),
        meetings: phrases(["reunião", "reuniões", "chamada", "chamadas", "ligação", "ligações", "sessão", "sessões", "call", "conversa",
                           "videochamada", "videoconferência", "encontro", "encontros", "meeting"]))
}
