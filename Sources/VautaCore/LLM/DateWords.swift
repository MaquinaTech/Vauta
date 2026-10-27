// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Words that say a date in the nine languages Vauta is translated into (English, Spanish, French, German, Italian,
/// Brazilian Portuguese, Japanese, Korean, Chinese). Used by `MinutesVerifier` to check a task's due date against the
/// words of the segment it cites. All entries are normalized keys (`TextKeys.norm`): lowercase, no accents.
/// Not a calendar parser: it recognizes the words people use, nothing more.
enum DateWords {
    /// Weekday names: Calendar numbering, 1 = Sunday ... 7 = Saturday.
    static let weekdays: [Int: [String]] = [
        2: ["monday", "lunes", "lundi", "montag", "lunedi", "月曜", "월요일", "星期一", "周一", "週一", "礼拜一"],
        3: ["tuesday", "martes", "mardi", "dienstag", "martedi", "terca", "火曜", "화요일", "星期二", "周二", "週二", "礼拜二"],
        4: ["wednesday", "miercoles", "mercredi", "mittwoch", "mercoledi", "quarta", "水曜", "수요일", "星期三", "周三", "週三", "礼拜三"],
        5: ["thursday", "jueves", "jeudi", "donnerstag", "giovedi", "木曜", "목요일", "星期四", "周四", "週四", "礼拜四"],
        6: ["friday", "viernes", "vendredi", "freitag", "venerdi", "金曜", "금요일", "星期五", "周五", "週五", "礼拜五"],
        7: ["saturday", "sabado", "samedi", "samstag", "sonnabend", "sabato", "土曜", "토요일", "星期六", "周六", "週六", "礼拜六"],
        1: ["sunday", "domingo", "dimanche", "sonntag", "domenica", "日曜", "일요일", "星期日", "星期天", "周日", "週日", "礼拜天", "礼拜日"],
    ]

    /// Brazilian Portuguese "segunda", "quinta" and "sexta" are also the ordinals second, fifth and sixth ("a segunda versão",
    /// "la segunda versión"), so they name a day only in the weekday sense (see `mentionedWeekdays`).
    static let ambiguousWeekdays: [Int: String] = [2: "segunda", 5: "quinta", 6: "sexta"]

    /// What may come before a bare "segunda"/"quinta"/"sexta" that is a day: "na quinta", "até sexta", "pra segunda".
    private static let weekdayLeaders: Set<String> = ["na", "ate", "nesta", "esta", "dessa", "nessa", "numa", "pra", "para", "pela", "desta", "so", "somente"]

    /// The weekdays a normalized text names (Calendar numbering). "segunda-feira" always counts; a bare "segunda",
    /// "quinta" or "sexta" only after a word that makes it a day, so an ordinal ("a segunda versão") does not.
    static func mentionedWeekdays(_ norm: String) -> Set<Int> {
        var days = Set(weekdays.filter { contains(norm, $0.value) }.map(\.key))
        let tokens = norm.split(separator: " ").map(String.init)
        for (day, word) in ambiguousWeekdays {
            for (i, token) in tokens.enumerated() where token == word {
                let prev = i > 0 ? tokens[i - 1] : "", prev2 = i > 1 ? tokens[i - 2] : ""
                let next = i + 1 < tokens.count ? tokens[i + 1] : ""
                if next == "feira" || weekdayLeaders.contains(prev) || (["a", "na"].contains(prev) && ["ate", "para", "pra"].contains(prev2)) {
                    days.insert(day)
                }
            }
        }
        return days
    }

    /// Words before "morgen"/"manana" that make them the morning, not the next day ("heute Morgen", "esta mañana",
    /// "por la mañana"), or the day after ("pasado mañana", "après-demain").
    private static let notTomorrow: Set<String> = [
        "heute", "gestern", "guten", "am", "jeden", "diesen", "diesem", "dieser", "den", "dem", "des", "vorgestern", "ubermorgen",
        "esta", "la", "una", "cada", "toda", "ayer", "mi", "su", "esa", "otra", "pasado", "apres", "depois",
    ]

    /// Whether a normalized text says "tomorrow". The words that also mean "morning" count only where they cannot.
    static func mentionsTomorrow(_ norm: String) -> Bool {
        let tokens = norm.split(separator: " ").map(String.init)
        for (i, token) in tokens.enumerated() {
            let prev = i > 0 ? tokens[i - 1] : ""
            switch token {
            case "morgen", "manana": if !notTomorrow.contains(prev) { return true }
            case "demain": if prev != "apres" { return true }
            case "amanha": if !(prev == "de" && i > 1 && tokens[i - 2] == "depois") { return true }
            case "tomorrow", "domani": return true
            default: break
            }
        }
        return contains(norm, ["明日", "あした", "明天", "내일"])
    }

    /// Month names: 1 = January. The numeric forms of Japanese, Korean and Chinese ("10月") are read by a pattern.
    /// English "may" is left out on purpose: it is also a verb.
    static let months: [Int: [String]] = [
        1: ["january", "enero", "janvier", "januar", "gennaio", "janeiro"],
        2: ["february", "febrero", "fevrier", "februar", "febbraio", "fevereiro"],
        3: ["march", "marzo", "mars", "marz", "marco"],
        4: ["april", "abril", "avril", "aprile"],
        5: ["mayo", "mai", "maggio", "maio"],
        6: ["june", "junio", "juin", "juni", "giugno", "junho"],
        7: ["july", "julio", "juillet", "juli", "luglio", "julho"],
        8: ["august", "agosto", "aout"],
        9: ["september", "septiembre", "setiembre", "septembre", "settembre", "setembro"],
        10: ["october", "octubre", "octobre", "oktober", "ottobre", "outubro"],
        11: ["november", "noviembre", "novembre", "novembro"],
        12: ["december", "diciembre", "decembre", "dezember", "dicembre", "dezembro"],
    ]

    static let today = ["today", "hoy", "aujourd hui", "heute", "oggi", "hoje", "今日", "きょう", "今天", "오늘"]

    /// Periods that name a stretch of the calendar, as whole phrases (never single words such as "next" or "fine",
    /// which are everyday words). `MinutesVerifier` accepts a due date only when it falls inside the stretch.
    static let thisWeek = [
        "this week", "esta semana", "cette semaine", "diese woche", "questa settimana",
        "今週", "本周", "本週", "이번 주", "이번주", "end of the week", "end of week",
    ]
    static let nextWeek = [
        "next week", "la semana que viene", "semana que viene", "proxima semana", "la semana proxima", "semana proxima",
        "semaine prochaine", "la semaine prochaine", "nachste woche", "naechste woche", "prossima settimana",
        "settimana prossima", "semana que vem", "来週", "下周", "下週", "다음 주", "다음주",
    ]
    /// "Next Friday": said before a weekday, it usually means the Friday of next week.
    static let nextWeekdayLeaders = [
        "next", "proximo", "proxima", "que viene", "prochain", "nachsten", "naechsten", "prossimo", "proxima", "que vem",
        "来週", "下周", "下週", "다음 주", "다음주",
    ]
    /// "In two weeks": two weeks from the meeting, give or take.
    static let inTwoWeeks = [
        "in two weeks", "in 2 weeks", "en dos semanas", "en 2 semanas", "dentro de dos semanas", "dans deux semaines",
        "dans 2 semaines", "in zwei wochen", "in 2 wochen", "tra due settimane", "fra due settimane", "em duas semanas",
        "daqui a duas semanas", "再来週", "2週間後", "二週間後", "两周后", "兩週後", "2주 후", "2주후", "이주 후",
    ]
    static let thisMonth = [
        "end of the month", "end of month", "this month", "fin de mes", "finales de mes", "este mes", "fin du mois",
        "ce mois", "ende des monats", "monatsende", "diesen monat", "dieses monats", "fine mese", "fine del mese",
        "questo mese", "fim do mes", "este mes", "月末", "今月", "월말", "이번 달", "이번달", "月底", "本月", "这个月", "這個月",
    ]
    static let nextMonth = [
        "next month", "el mes que viene", "mes que viene", "proximo mes", "mes proximo", "mois prochain", "le mois prochain",
        "nachsten monat", "naechsten monat", "prossimo mese", "mese prossimo", "mes que vem", "proximo mes",
        "来月", "다음 달", "다음달", "下个月", "下個月",
    ]
    static let endOfDay = ["eod", "end of day", "end of the day", "fin de journee", "fin del dia", "ende des tages"]

    /// Whether `text` (already normalized) contains one of `words`, as whole words, or as a substring for scripts
    /// written without spaces and for Korean, whose particles attach to the word ("내일까지").
    static func contains(_ text: String, _ words: [String]) -> Bool {
        words.contains { word in
            word.unicodeScalars.contains { (0xAC00...0xD7AF).contains($0.value) } ? text.contains(word)
                                                                                  : PromptText.containsNormalizedWords(text, word)
        }
    }
}
