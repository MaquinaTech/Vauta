// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The fixed sentences of the follow-up email in the nine languages. The email is written in the language of the meeting, not of the
/// app, and a String Catalog cannot be read for another language from Swift Package code without a bundle per language, so the fifteen
/// sentences live here, in one table that a test compares with the English source (same placeholders, none empty). Item text (decisions,
/// tasks, names) is never translated.
struct FollowUpEmailWords: Equatable {
    /// "%1$@, %2$@: …" with the meeting's name and its short date.
    var subject: String
    /// The subject of a per-owner draft, which holds only that person's next steps; the same two arguments.
    var subjectOwner: String
    var hello: String
    /// One argument: the person's first name (a per-owner draft greets them by name).
    var helloOwner: String
    /// One argument: the meeting's long date.
    var intro: String
    /// One argument: the long date.
    var introOwner: String
    var summary: String
    var decisions: String
    var nextSteps: String
    var openQuestions: String
    /// One argument: the day and time.
    var nextMeeting: String
    /// One argument: the due day.
    var by: String
    var toConfirm: String
    var ownerToAgree: String
    /// Before a task of the sender's own, whose name is not stored ("Me: …").
    var me: String
    var regards: String

    static let supported = ["en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh"]

    /// The words for a locale's language; English when the language is not one of the nine.
    static func words(for locale: Locale) -> FollowUpEmailWords {
        table[code(of: locale)] ?? table["en"]!
    }

    static func code(of locale: Locale) -> String {
        let language = locale.language.languageCode?.identifier ?? "en"
        return supported.contains(language) ? language : "en"
    }

    static let table: [String: FollowUpEmailWords] = [
        "en": FollowUpEmailWords(
            subject: "%1$@, %2$@: decisions and next steps", subjectOwner: "%1$@, %2$@: your next steps", hello: "Hello,", helloOwner: "Hello %@,",
            intro: "Here are the decisions and next steps from our meeting on %@.",
            introOwner: "Here are your next steps from our meeting on %@:",
            summary: "Summary", decisions: "Decisions", nextSteps: "Next steps", openQuestions: "Open questions",
            nextMeeting: "Next meeting: %@", by: "by %@", toConfirm: "(to be confirmed)", ownerToAgree: "owner to be agreed", me: "Me", regards: "Best regards,"),
        "es": FollowUpEmailWords(
            subject: "%1$@, %2$@: decisiones y próximos pasos", subjectOwner: "%1$@, %2$@: tus próximos pasos", hello: "Hola,", helloOwner: "Hola %@,",
            intro: "Estas son las decisiones y los próximos pasos de nuestra reunión del %@.",
            introOwner: "Estos son tus próximos pasos de nuestra reunión del %@:",
            summary: "Resumen", decisions: "Decisiones", nextSteps: "Próximos pasos", openQuestions: "Preguntas abiertas",
            nextMeeting: "Próxima reunión: %@", by: "para el %@", toConfirm: "(por confirmar)", ownerToAgree: "responsable por acordar", me: "Yo", regards: "Un saludo,"),
        "fr": FollowUpEmailWords(
            subject: "%1$@, %2$@\u{00A0}: décisions et prochaines étapes", subjectOwner: "%1$@, %2$@\u{00A0}: vos prochaines étapes", hello: "Bonjour,", helloOwner: "Bonjour %@,",
            intro: "Voici les décisions et les prochaines étapes de notre réunion du %@.",
            introOwner: "Voici vos prochaines étapes de notre réunion du %@\u{00A0}:",
            summary: "Résumé", decisions: "Décisions", nextSteps: "Prochaines étapes", openQuestions: "Questions en suspens",
            nextMeeting: "Prochaine réunion\u{00A0}: %@", by: "d’ici le %@", toConfirm: "(à confirmer)", ownerToAgree: "responsable à convenir", me: "Moi", regards: "Cordialement,"),
        "de": FollowUpEmailWords(
            subject: "%1$@, %2$@: Entscheidungen und nächste Schritte", subjectOwner: "%1$@, %2$@: deine nächsten Schritte", hello: "Hallo,", helloOwner: "Hallo %@,",
            intro: "Hier sind die Entscheidungen und nächsten Schritte aus unserem Meeting am %@.",
            introOwner: "Hier sind deine nächsten Schritte aus unserem Meeting am %@:",
            summary: "Zusammenfassung", decisions: "Entscheidungen", nextSteps: "Nächste Schritte", openQuestions: "Offene Fragen",
            nextMeeting: "Nächstes Meeting: %@", by: "bis %@", toConfirm: "(noch zu bestätigen)", ownerToAgree: "Zuständigkeit noch zu klären", me: "Ich", regards: "Viele Grüße"),
        "it": FollowUpEmailWords(
            subject: "%1$@, %2$@: decisioni e prossimi passi", subjectOwner: "%1$@, %2$@: i tuoi prossimi passi", hello: "Ciao,", helloOwner: "Ciao %@,",
            intro: "Ecco le decisioni e i prossimi passi della nostra riunione di %@.",
            introOwner: "Ecco i tuoi prossimi passi della nostra riunione di %@:",
            summary: "Riepilogo", decisions: "Decisioni", nextSteps: "Prossimi passi", openQuestions: "Domande aperte",
            nextMeeting: "Prossima riunione: %@", by: "entro %@", toConfirm: "(da confermare)", ownerToAgree: "responsabile da definire", me: "Io", regards: "Cordiali saluti,"),
        "pt": FollowUpEmailWords(
            subject: "%1$@, %2$@: decisões e próximos passos", subjectOwner: "%1$@, %2$@: seus próximos passos", hello: "Olá,", helloOwner: "Olá %@,",
            intro: "Aqui estão as decisões e os próximos passos da nossa reunião de %@.",
            introOwner: "Aqui estão seus próximos passos da nossa reunião de %@:",
            summary: "Resumo", decisions: "Decisões", nextSteps: "Próximos passos", openQuestions: "Perguntas em aberto",
            nextMeeting: "Próxima reunião: %@", by: "até %@", toConfirm: "(a confirmar)", ownerToAgree: "responsável a definir", me: "Eu", regards: "Atenciosamente,"),
        "ja": FollowUpEmailWords(
            subject: "%1$@、%2$@：決定事項と次のステップ", subjectOwner: "%1$@、%2$@：次のステップ", hello: "お疲れさまです。", helloOwner: "%@さん、お疲れさまです。",
            intro: "%@の会議の決定事項と次のステップをお送りします。",
            introOwner: "%@の会議での次のステップです：",
            summary: "要約", decisions: "決定事項", nextSteps: "次のステップ", openQuestions: "未解決の質問",
            nextMeeting: "次回の会議：%@", by: "%@まで", toConfirm: "（要確認）", ownerToAgree: "担当者は未定", me: "私", regards: "よろしくお願いいたします。"),
        "ko": FollowUpEmailWords(
            subject: "%1$@, %2$@: 결정 사항 및 다음 단계", subjectOwner: "%1$@, %2$@: 다음 단계", hello: "안녕하세요,", helloOwner: "%@님, 안녕하세요.",
            intro: "%@ 회의의 결정 사항과 다음 단계를 공유드립니다.",
            introOwner: "%@ 회의에서 정해진 다음 단계입니다:",
            summary: "요약", decisions: "결정 사항", nextSteps: "다음 단계", openQuestions: "미해결 질문",
            nextMeeting: "다음 회의: %@", by: "%@까지", toConfirm: "(확인 필요)", ownerToAgree: "담당자 미정", me: "저", regards: "감사합니다."),
        "zh": FollowUpEmailWords(
            subject: "%1$@，%2$@：决定和后续步骤", subjectOwner: "%1$@，%2$@：您的后续步骤", hello: "您好，", helloOwner: "%@，您好，",
            intro: "以下是%@会议的决定和后续步骤。",
            introOwner: "以下是%@会议中分配给您的后续步骤：",
            summary: "摘要", decisions: "决定", nextSteps: "后续步骤", openQuestions: "待解决问题",
            nextMeeting: "下次会议：%@", by: "截止%@", toConfirm: "（待确认）", ownerToAgree: "负责人待定", me: "我", regards: "此致敬礼，"),
    ]

    /// Fills a template with `%@` or `%1$@`/`%2$@` placeholders in one pass over the template, so an argument that itself contains a
    /// placeholder or a format specifier is copied as it is.
    static func fill(_ template: String, _ arguments: String...) -> String {
        var out = ""
        var next = 0
        var rest = Substring(template)
        while let at = rest.firstIndex(of: "%") {
            out += rest[..<at]
            let tail = rest[at...]
            if tail.hasPrefix("%@") {
                if next < arguments.count { out += arguments[next] }
                next += 1
                rest = tail.dropFirst(2)
            } else if tail.count >= 4, let digit = tail.dropFirst().first?.wholeNumberValue, tail.dropFirst(2).hasPrefix("$@") {
                if digit >= 1, digit <= arguments.count { out += arguments[digit - 1] }
                rest = tail.dropFirst(4)
            } else {
                out += "%"
                rest = tail.dropFirst()
            }
        }
        return out + rest
    }
}
