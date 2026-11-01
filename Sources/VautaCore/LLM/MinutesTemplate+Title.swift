// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The template a meeting's title points to ("1:1 with Ana", "Daily stand-up", "Entrevista: backend", "面接"), in the nine languages
/// Vauta is translated into. It is only offered: the person chooses it with one click, and nothing is written with it on its own. The
/// words are compared as normalized keys (`TextKeys.norm`: lowercase, no accents, no punctuation), as whole words, or as substrings
/// in the scripts written without spaces. A word that also means something else in a title ("en cours", "in corso", "talk with
/// Ana", "sprint demo", "pitch deck") is left out: a wrong suggestion costs more trust than a missing one.
extension MinutesTemplate {
    /// The template the title suggests, or nil. Several kinds can match ("1:1 with a candidate"): the first of `titleOrder` wins.
    public static func suggested(forTitle title: String) -> MinutesTemplate? {
        let norm = TextKeys.norm(title)
        guard !norm.isEmpty else { return nil }
        return titleOrder.first { template in
            if template == .oneOnOne, title.range(of: oneOnOneNumbers, options: [.regularExpression, .caseInsensitive]) != nil { return true }
            // Whole words, or substrings in the scripts written without spaces and in Korean, whose particles join the word.
            return (titleWords[template] ?? []).contains { FollowUpWords.matches(norm, $0) }
        }
    }

    /// The most specific kind first: an interview is often one to one, and a stand-up with a client is still a stand-up.
    static let titleOrder: [MinutesTemplate] = [.interview, .oneOnOne, .standup, .lecture, .clientCall]

    /// "1:1", "1-1", "1x1", "1 on 1", "1 to 1", "1 a 1", "1対1", "1对1", "1대1", never inside a longer number ("11:15", "21-1"). (A set
    /// that starts with "[:" is a property in ICU's syntax, so the hyphen comes first.)
    static let oneOnOneNumbers = #"(?<![\p{N}.,:])1\s?(?:[-:x×]|on|to|a|対|对|對|대)\s?1(?![\p{N}.,:])"#

    static let titleWords: [MinutesTemplate: [String]] = [
        .oneOnOne: [
            "one on one", "one to one", "1on1", "skip level",
            "uno a uno", "reunion individual", "reunion uno a uno",                      // es
            "tete a tete", "entretien individuel", "point individuel", "entretien annuel", // fr
            "einzelgesprach", "vier augen gesprach", "mitarbeitergesprach",                 // de
            "colloquio individuale", "incontro individuale",                               // it
            "um a um", "reuniao individual", "conversa individual",                         // pt
            "ワンオンワン", "個別面談", "個人面談",                                              // ja
            "일대일", "원온원", "개별 면담",                                                    // ko
            "一对一", "一對一",                                                               // zh
        ],
        .standup: [
            "standup", "stand up", "daily", "dailies", "daily scrum", "daily sync", "huddle",
            "reunion diaria",                                                               // es
            "point quotidien", "melee quotidienne",                                         // fr
            "tagliches meeting", "morgenrunde",                                             // de
            "riunione quotidiana", "riunione giornaliera",                                  // it
            "reuniao diaria",                                                               // pt
            "朝会", "デイリー", "スタンドアップ", "朝礼", "夕会",                                  // ja
            "데일리", "스탠드업", "일일 회의",                                                  // ko
            "站会", "站立会议", "站立會議", "晨会", "晨會", "早会", "早會",                           // zh
        ],
        .interview: [
            "interview", "screening", "phone screen", "candidate",
            "entrevista", "candidato", "candidata",                                         // es, pt
            "entretien d embauche", "entretien de recrutement", "entrevue", "candidat",     // fr
            "vorstellungsgesprach", "bewerbungsgesprach", "bewerber", "bewerberin",         // de
            "colloquio di lavoro", "colloquio conoscitivo", "intervista",                   // it
            "面接", "採用面談", "カジュアル面談",                                                // ja
            "면접", "인터뷰",                                                                 // ko
            "面试", "面試",                                                                   // zh
        ],
        .lecture: [
            "lecture", "class", "lesson", "seminar", "webinar", "keynote", "tech talk", "lunch and learn", "masterclass",
            "clase", "charla tecnica", "ponencia", "seminario", "leccion",                  // es
            "cours magistral", "seminaire", "webinaire", "lecon",                           // fr
            "vorlesung", "vortrag", "schulung", "unterricht",                               // de
            "lezione", "conferenza",                                                        // it
            "aula", "palestra",                                                             // pt
            "講義", "授業", "セミナー", "講演", "勉強会", "研修", "ウェビナー",                         // ja
            "강의", "수업", "세미나", "강연", "웨비나",                                            // ko
            "讲座", "講座", "课程", "課程", "研讨会", "研討會", "讲课", "講課", "培训", "培訓",          // zh
        ],
        .clientCall: [
            "client", "customer", "prospect", "sales call", "discovery call",
            "cliente", "clientes", "llamada comercial",                                     // es, it, pt
            "clients", "rendez vous client",                                                // fr
            "kunde", "kunden", "kundin", "kundentermin", "kundengesprach", "verkaufsgesprach", // de
            "clienti",                                                                      // it
            "顧客", "商談", "お客様", "クライアント",                                             // ja
            "고객", "고객사", "클라이언트",                                                     // ko
            "客户", "客戶",                                                                   // zh
        ],
    ].mapValues { $0.map(TextKeys.norm) }
}
