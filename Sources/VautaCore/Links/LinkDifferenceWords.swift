// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Words `LinkDifference` reads, in the nine languages of the app. Code data, not interface text. Latin entries are in the folded form of
/// `TextKeys.norm` (lower case, no accents); entries of the scripts written without spaces are matched as substrings.
enum LinkDifferenceWords {
    /// A reversal attached to a verb or an object, by the language of the item. Bare "no" and "not" are not here on purpose ("no later than
    /// Friday" is not a change). A language's words are read in that language's items only: French "reporter" is also an English noun, and
    /// "reporte" a Spanish one.
    static let polarityByLanguage: [String: [String]] = [
        "en": ["no longer", "cancel", "cancelled", "canceled", "postpone", "postponed", "reject", "rejected", "instead of", "called off", "put on hold",
               "abandon", "abandoned", "scrap", "scrapped"],
        "es": ["ya no", "cancelar", "cancelado", "cancelada", "aplazar", "aplazado", "aplazada", "rechazar", "rechazado", "rechazada", "en lugar de", "en vez de"],
        "pt": ["nao mais", "adiar", "adiado", "adiada", "rejeitar", "rejeitado", "rejeitada", "cancelar", "cancelado", "em vez de"],
        "fr": ["ne plus", "annuler", "annule", "annulee", "reporter", "reporte", "rejeter", "rejete", "au lieu de"],
        "de": ["nicht mehr", "abgesagt", "absagen", "verschoben", "verschieben", "abgelehnt", "ablehnen", "anstatt", "statt"],
        "it": ["non piu", "annullare", "annullato", "rinviare", "rinviato", "rifiutare", "rifiutato", "invece di"],
        "ja": ["中止", "キャンセル", "延期", "却下", "取りやめ", "見送り", "ではなく"],
        "ko": ["취소", "연기", "거부", "대신", "중단"],
        "zh": ["取消", "推迟", "推遲", "延期", "拒绝", "拒絕", "不再", "改为", "改為", "而不是", "暂停"],
    ]

    /// The reversal words of an item's language (its ISO code, "es" for "es-ES"); every language's when the language is not one of the nine.
    static func polarity(for language: String?) -> [String] {
        if let language, let own = polarityByLanguage[String(language.prefix(while: { $0 != "-" && $0 != "_" })).lowercased()] { return own }
        return Array(Set(polarityByLanguage.values.flatMap { $0 })).sorted()
    }

    /// A claim that something was turned down; against `BriefStatusWords.decided` it is a status pair (approved ↔ rejected).
    static let rejected: [String] = [
        "rejected", "declined", "refused", "denied", "vetoed",
        "rechazado", "rechazada", "denegado", "denegada", "rejeitado", "rejeitada", "recusado", "recusada",
        "rejete", "rejetee", "refuse", "refusee", "abgelehnt", "verweigert", "rifiutato", "rifiutata", "respinto", "respinta",
        "却下", "否決", "拒否", "거부됨", "반려됨", "已拒绝", "已拒絕", "被拒绝", "否决", "否決",
    ]

    /// Currency and unit words to one key, so "40.000 euros" and "48.200 €" share a unit.
    static let units: [String: String] = [
        "€": "eur", "eur": "eur", "euro": "eur", "euros": "eur",
        "$": "usd", "usd": "usd", "dollar": "usd", "dollars": "usd", "dolar": "usd", "dolares": "usd",
        "£": "gbp", "gbp": "gbp", "pound": "gbp", "pounds": "gbp", "libra": "gbp", "libras": "gbp",
        "¥": "jpy", "円": "jpy", "yen": "jpy", "元": "cny", "yuan": "cny", "rmb": "cny",
        "%": "pct", "％": "pct", "percent": "pct", "porciento": "pct", "prozent": "pct", "pourcent": "pct", "percento": "pct", "por": "",
    ]

    /// Words before a number that make it a period or an ordinal position, not a quantity ("week 12", "semana 12").
    static let periodLeaders: Set<String> = [
        "week", "semana", "semaine", "woche", "settimana", "q", "kw", "sprint", "version", "v", "release", "fase", "phase", "step", "paso", "etapa",
    ]

    /// Short forms of the months (folded), by language, next to the full names of `DateWords.months`. Scripts written with numbered months have none.
    static let monthAbbreviationsByLanguage: [String: [String: Int]] = [
        "en": ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "sept": 9, "oct": 10, "nov": 11, "dec": 12],
        "es": ["ene": 1, "feb": 2, "mar": 3, "abr": 4, "may": 5, "jun": 6, "jul": 7, "ago": 8, "sep": 9, "sept": 9, "set": 9, "oct": 10, "nov": 11, "dic": 12],
        "pt": ["jan": 1, "fev": 2, "mar": 3, "abr": 4, "mai": 5, "jun": 6, "jul": 7, "ago": 8, "set": 9, "out": 10, "nov": 11, "dez": 12],
        "fr": ["janv": 1, "fevr": 2, "mars": 3, "avr": 4, "mai": 5, "juin": 6, "juil": 7, "aout": 8, "sept": 9, "oct": 10, "nov": 11, "dec": 12],
        "de": ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "mai": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "sept": 9, "okt": 10, "nov": 11, "dez": 12],
        "it": ["gen": 1, "feb": 2, "mar": 3, "apr": 4, "mag": 5, "giu": 6, "lug": 7, "ago": 8, "set": 9, "ott": 10, "nov": 11, "dic": 12],
    ]

    /// Abbreviations that are also common words ("may", "mar", "set", "dez"…): they count as a month only when written with a capital or a full
    /// stop, as in "12 Mar" or "12 mar.".
    static let ambiguousAbbreviations: Set<String> = ["may", "mar", "set", "dez", "mai", "mag", "ago", "out", "dic", "gen", "sep", "ott"]

    static func monthAbbreviations(for language: String?) -> [String: Int] {
        guard let language else { return [:] }
        return monthAbbreviationsByLanguage[String(language.prefix(while: { $0 != "-" && $0 != "_" })).lowercased()] ?? [:]
    }

    /// Joiners between a day and its month ("12 de octubre", "12th of October").
    static let dateJoiners: Set<String> = ["de", "of", "del", "the", "th", "st", "nd", "rd", "di", "du", "des", "le", "el", "am", "den"]
}
