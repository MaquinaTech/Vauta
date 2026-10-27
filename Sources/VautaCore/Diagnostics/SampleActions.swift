// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import Foundation

/// What the post-meeting actions scenes add to the featured meeting for the UI snapshot renderer: more tasks, attendee addresses and
/// follow-up meetings. Invented (addresses are on example.org); nothing is real, and nothing here reaches Reminders, Calendar or Mail.
extension SampleWorld {
    /// The featured meeting's tasks as the actions scenes use them: the ones it has, plus three invented ones of its own in the
    /// language being rendered (never copies of another meeting's tasks, so no task appears twice with another owner or date): a short
    /// one with no owner, a short one with an owner, and a long one to see how the rows wrap.
    public func seedActionTasks() async throws {
        try await resetActions()
        let words = Self.inventedTasks[locale.language.languageCode?.identifier ?? "en"] ?? Self.inventedTasks["en"]!
        let segment = featuredSegmentIDs[min(3, featuredSegmentIDs.count - 1)]
        func due(_ days: Int) -> Date? { dueDate(ofMeeting: 0, afterDays: days) }
        let owner = { (index: Int) in peopleIDs[min(index, peopleIDs.count - 1)] }
        _ = try await store.addTask(featuredMeetingID, text: words.ownerless, ownerID: nil, due: due(3), segmentID: segment, t: 3 * 38, source: "llm")
        _ = try await store.addTask(featuredMeetingID, text: words.owned, ownerID: owner(1), due: due(7), segmentID: segment, t: 3 * 38, source: "llm")
        _ = try await store.addTask(featuredMeetingID, text: words.long[0], ownerID: owner(2), due: due(9), segmentID: segment, t: 4 * 38, source: "llm")
    }

    /// Two more long tasks (two lines or more each, each its own sentence, owner and date) for the scenes that stress long rows.
    /// The first task is about what testers need before Thursday's beta, so it is due the day after the meeting; the others are later.
    public func seedLongTasks() async throws {
        let words = Self.inventedTasks[locale.language.languageCode?.identifier ?? "en"] ?? Self.inventedTasks["en"]!
        let segment = featuredSegmentIDs[min(3, featuredSegmentIDs.count - 1)]
        for (index, text) in words.long.dropFirst().enumerated() {
            _ = try await store.addTask(featuredMeetingID, text: text, ownerID: peopleIDs[min(index + 1, peopleIDs.count - 1)],
                                        due: dueDate(ofMeeting: 0, afterDays: index == 0 ? 1 : 8 + index), segmentID: segment, t: 4 * 38, source: "llm")
        }
    }

    private static let inventedTasks: [String: (ownerless: String, owned: String, long: [String])] = [
        "en": ("Confirm the pilot kickoff date with Northwind", "Update the beta checklist with this meeting’s open items",
               ["Prepare a one-page summary of the pilot goals, the agreed limits and the open risks for the Northwind steering group, and send it to everyone invited before the next meeting",
                "Ask the support team to review the macros for the beta, list the answers that still need an owner and agree on who writes each of them before testers get access",
                "Write down the rollback steps for the first week of the beta, test them once on a copy of the workspace and share the result in the project channel with the date of the test"]),
        "es": ("Confirmar con Northwind la fecha de inicio del piloto", "Actualizar la lista de la beta con los puntos abiertos de esta reunión",
               ["Preparar un resumen de una página con los objetivos del piloto, los límites acordados y los riesgos abiertos para el comité de Northwind, y enviarlo a todos los invitados antes de la próxima reunión",
                "Pedir al equipo de soporte que revise las respuestas guardadas para la beta, haga una lista de las que aún no tienen responsable y acuerde quién escribe cada una antes de que los probadores tengan acceso",
                "Anotar los pasos para revertir la beta durante su primera semana, probarlos una vez en una copia del espacio de trabajo y compartir el resultado en el canal del proyecto con la fecha de la prueba"]),
        "fr": ("Confirmer avec Northwind la date de lancement du pilote", "Mettre à jour la liste de contrôle de la bêta avec les points ouverts de cette réunion",
               ["Préparer une synthèse d’une page sur les objectifs du pilote, les limites convenues et les risques ouverts pour le comité de pilotage de Northwind, et l’envoyer à tous les invités avant la prochaine réunion",
                "Demander à l’équipe du support de relire les réponses types de la bêta, de lister celles qui n’ont pas encore de responsable et de décider qui rédige chacune avant que les testeurs n’aient accès",
                "Noter les étapes pour revenir en arrière pendant la première semaine de la bêta, les tester une fois sur une copie de l’espace de travail et partager le résultat dans le canal du projet avec la date du test"]),
        "de": ("Mit Northwind den Starttermin des Pilotprojekts bestätigen", "Beta-Checkliste um die offenen Punkte dieses Meetings ergänzen",
               ["Eine einseitige Zusammenfassung der Pilotziele, der vereinbarten Grenzen und der offenen Risiken für den Lenkungskreis von Northwind erstellen und vor dem nächsten Meeting an alle Eingeladenen schicken",
                "Das Support-Team bitten, die Antwortvorlagen für die Beta durchzusehen, alle ohne Zuständige aufzulisten und zu klären, wer welche schreibt, bevor die Testenden Zugang bekommen",
                "Die Rollback-Schritte für die erste Woche der Beta aufschreiben, einmal an einer Kopie des Arbeitsbereichs testen und das Ergebnis mit dem Datum des Tests im Projektkanal teilen"]),
        "it": ("Confermare con Northwind la data di avvio del pilota", "Aggiornare la checklist della beta con i punti aperti di questa riunione",
               ["Preparare una sintesi di una pagina su obiettivi del pilota, limiti concordati e rischi aperti per il comitato di Northwind e inviarla a tutti gli invitati prima della prossima riunione",
                "Chiedere al team di assistenza di rivedere le risposte predefinite della beta, elencare quelle ancora senza responsabile e decidere chi scrive ciascuna prima che i tester abbiano accesso",
                "Annotare i passaggi per tornare indietro nella prima settimana della beta, provarli una volta su una copia dello spazio di lavoro e condividere il risultato nel canale del progetto con la data della prova"]),
        "pt": ("Confirmar com a Northwind a data de início do piloto", "Atualizar a lista de verificação da beta com os pontos em aberto desta reunião",
               ["Preparar um resumo de uma página com os objetivos do piloto, os limites combinados e os riscos em aberto para o comitê da Northwind e enviá-lo a todos os convidados antes da próxima reunião",
                "Pedir à equipe de suporte que revise as respostas prontas da beta, liste as que ainda não têm responsável e combine quem escreve cada uma antes de os testadores terem acesso",
                "Anotar os passos para reverter a beta na primeira semana, testá-los uma vez em uma cópia do espaço de trabalho e compartilhar o resultado no canal do projeto com a data do teste"]),
        "ja": ("Northwindとパイロットの開始日を確認する", "この会議で残った項目をベータのチェックリストに反映する",
               ["パイロットの目標、合意した制限、残っているリスクを1ページにまとめ、Northwindの運営委員会向けに、次の会議の前に招待者全員へ送る",
                "サポートチームにベータ用の定型回答を見直してもらい、担当者が決まっていないものを一覧にして、テスターが使い始める前に誰が書くかを決める",
                "ベータ最初の1週間に元へ戻す手順を書き出し、ワークスペースのコピーで一度試して、結果をテスト日とともにプロジェクトのチャンネルで共有する"]),
        "ko": ("노스윈드와 파일럿 시작일 확정하기", "이 회의에서 남은 항목을 베타 체크리스트에 반영하기",
               ["파일럿 목표, 합의한 한도, 남아 있는 위험을 한 페이지로 정리해 노스윈드 운영위원회용으로 만들고, 다음 회의 전에 초대받은 모든 사람에게 보내기",
                "지원팀에 베타용 답변 템플릿을 검토해 달라고 요청하고, 담당자가 없는 답변을 목록으로 만든 뒤 테스터가 접근하기 전에 누가 각각 쓸지 정하기",
                "베타 첫 주에 되돌리는 절차를 적어 두고, 작업 공간 사본에서 한 번 시험한 뒤 시험 날짜와 함께 결과를 프로젝트 채널에 공유하기"]),
        "zh": ("与 Northwind 确认试点的开始日期", "把这次会议遗留的事项补充到测试版清单中",
               ["准备一页摘要，写明试点目标、已商定的限制和尚未解决的风险，供 Northwind 指导小组使用，并在下次会议前发给所有受邀者",
                "请支持团队检查测试版的预设回复，列出还没有负责人的回复，并在测试人员获得访问权限之前定好由谁来写",
                "写下测试版第一周的回退步骤，在工作区副本上试一次，并把结果连同测试日期分享到项目频道"]),
    ]

    /// One line of the featured meeting says when the next meeting is, in the language being rendered, so the Follow-up sheet quotes the
    /// words a person really said and "day inferred from …" names the day phrase. `weekday` says it as a weekday ("on Tuesday"), else as
    /// a date. The scenes' transcript is restored by `restoreTranscript`.
    public func sayFollowUp(segmentIndex: Int, day: DueDay, minuteOfDay: Int?, weekday: Bool, meetingDay: DueDay? = nil) async throws {
        guard !featuredSegmentIDs.isEmpty else { return }
        let id = featuredSegmentIDs[min(segmentIndex, featuredSegmentIDs.count - 1)]
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate(weekday ? "EEEE" : "dMMMM")
        var when = f.string(from: day.utcNoonDate)
        // A calendar date needs its article in French and Italian ("le 1er novembre", "il 1° novembre"); a weekday does not.
        let language = locale.language.languageCode?.identifier
        if !weekday, language == "fr" || language == "it" {
            let first = when.hasPrefix("1 ")
            when = (language == "fr" ? "le " : "il ") + (first ? (language == "fr" ? "1er" : "1°") + when.dropFirst() : when)
        }
        let code = locale.language.languageCode?.identifier ?? "en"
        // A weekday more than a week after the meeting is only understood as that day when the speaker pins it to the week after.
        if weekday, let meetingDay, day.utcNoonDate.timeIntervalSince(meetingDay.utcNoonDate) > 6 * 86_400, let pin = Self.nextWeekPhrase[code] {
            when = pin.replacingOccurrences(of: "{day}", with: when)
        }
        let words = Self.followUpWords[code] ?? Self.followUpWords["en"]!
        let afternoon = (minuteOfDay ?? 0) >= 12 * 60
        let text: String
        if minuteOfDay != nil {
            text = words.timed.replacingOccurrences(of: "{when}", with: when).replacingOccurrences(of: "{time}", with: afternoon ? words.three : words.ten)
        } else {
            text = words.bare.replacingOccurrences(of: "{when}", with: when)
        }
        try await store.replaceSegmentTextForSnapshots(id, with: text)
    }

    private static let nextWeekPhrase: [String: String] = [
        "en": "{day} next week", "es": "{day} de la semana que viene", "fr": "{day} de la semaine prochaine", "de": "{day} nächste Woche",
        "it": "{day} della settimana prossima", "pt": "{day} da semana que vem", "ja": "来週の{day}", "ko": "다음 주 {day}", "zh": "下周{day}",
    ]

    private static let followUpWords: [String: (bare: String, timed: String, ten: String, three: String)] = [
        "en": ("Let's meet again on {when}.", "Let's meet again on {when} at {time}.", "ten", "three in the afternoon"),
        "es": ("Nos vemos otra vez el {when}.", "Nos vemos otra vez el {when} a las {time}.", "diez", "tres de la tarde"),
        "fr": ("On se revoit {when}.", "On se revoit {when} à {time}.", "dix heures", "quinze heures"),
        "de": ("Wir sehen uns am {when} wieder.", "Wir sehen uns am {when} um {time} wieder.", "zehn Uhr", "fünfzehn Uhr"),
        "it": ("Ci vediamo di nuovo {when}.", "Ci vediamo di nuovo {when} alle {time}.", "dieci", "tre del pomeriggio"),
        "pt": ("Nos vemos de novo em {when}.", "Nos vemos de novo em {when} às {time}.", "dez", "três da tarde"),
        "ja": ("{when}にまた会いましょう。", "{when}の{time}にまた会いましょう。", "10時", "午後3時"),
        "ko": ("{when}에 다시 만납시다.", "{when} {time}에 다시 만납시다.", "10시", "오후 3시"),
        "zh": ("我们{when}再见面。", "我们{when}{time}再见面。", "上午十点", "下午三点"),
    ]

    /// The attendees of the featured meeting get an address (the person is on example.org, one guest is not).
    public func seedAddresses(externalGuest: Bool = true) async throws {
        try await store.setAddressesForSnapshots(people: peopleIDs, externalIndex: externalGuest ? 3 : nil)
    }

    /// Back to the sample minutes: no ledger rows, no follow-ups, no extra tasks, no addresses, no marks.
    public func resetActions() async throws {
        let keep = Set(content.meetings[0].tasks.map(\.text))
        for task in try await store.tasks(featuredMeetingID) where !keep.contains(task.text) { try await store.deleteTask(task.id) }
        try await store.resetActionsForSnapshots()
        try await clearVerificationMarks()
        for task in try await store.tasks(featuredMeetingID) where task.status != .open { try await store.setTaskStatus(task.id, .open) }
    }
}

extension MeetingStore {
    func resetActionsForSnapshots() async throws {
        try run("DELETE FROM created_actions")
        try run("DELETE FROM follow_ups")
        try run("UPDATE entities SET email = NULL WHERE email LIKE '%@example.org' OR email LIKE '%@partner.example'")
        try await commitEdit()
    }

    func setAddressesForSnapshots(people: [Int64], externalIndex: Int?) async throws {
        for (index, id) in people.enumerated() {
            let domain = index == externalIndex ? "partner.example" : "example.org"
            try run("UPDATE entities SET email = ? WHERE id = ?", [.text("person\(index + 1)@\(domain)"), .integer(id)])
        }
        try await commitEdit()
    }
}
#endif
