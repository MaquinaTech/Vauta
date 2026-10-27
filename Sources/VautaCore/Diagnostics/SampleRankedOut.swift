// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import Foundation

/// Invented items that ranked out of the featured meeting's minutes ("Other possible items") in the language being rendered, for the
/// scenes with many items and with a long one. None repeats a decision or a task of the sample meetings, and none cites a line that one of them cites
/// (`segment` is the index of that line). Only six lines of the meeting are left over, so a few ranked-out items share one.
struct SampleRankedOutItem {
    let segment: Int
    let isTask: Bool
    let text: String
}

enum SampleRankedOut {
    /// Nine distinct items.
    static func items(for language: String) -> [SampleRankedOutItem] {
        let rows = many[language] ?? many["en"]!
        let segments = [1, 2, 2, 6, 7, 9, 11, 11, 1]
        let isTask = [false, true, false, true, false, true, false, true, false]
        return rows.enumerated().map { SampleRankedOutItem(segment: segments[$0.offset], isTask: isTask[$0.offset], text: $0.element) }
    }

    /// A long decision and a long task: real sentences of several clauses, so they wrap over several lines the way a model's would.
    static func long(for language: String) -> (decision: SampleRankedOutItem, task: SampleRankedOutItem) {
        let pair = longPair[language] ?? longPair["en"]!
        return (SampleRankedOutItem(segment: 1, isTask: false, text: pair.0), SampleRankedOutItem(segment: 6, isTask: true, text: pair.1))
    }

    private static let longPair: [String: (String, String)] = [
        "en": ("Offer testers a short welcome call during the first week of the beta, record the questions they ask most often, and turn the ten most frequent ones into help articles before the public launch, so support does not answer the same question twice.",
               "Collect the feedback from the first week of the beta in one document, group it by workspace size and by team, mark every report that mentions the sync service, and share the summary with the team before the next weekly sync."),
        "es": ("Ofrecer a los probadores una llamada de bienvenida breve durante la primera semana de la beta, anotar las preguntas que más repiten y convertir las diez más frecuentes en artículos de ayuda antes del lanzamiento público, para que soporte no responda dos veces lo mismo.",
               "Reunir los comentarios de la primera semana de la beta en un solo documento, agruparlos por tamaño de espacio y por equipo, marcar cada informe que mencione el servicio de sincronización y compartir el resumen con el equipo antes de la próxima reunión semanal."),
        "fr": ("Proposer aux testeurs un court appel d’accueil pendant la première semaine de la bêta, noter les questions qu’ils posent le plus souvent et transformer les dix plus fréquentes en articles d’aide avant le lancement public, afin que le support ne réponde pas deux fois à la même question.",
               "Réunir les retours de la première semaine de la bêta dans un seul document, les classer par taille d’espace et par équipe, repérer chaque rapport qui mentionne le service de synchronisation et partager la synthèse avec l’équipe avant le prochain point hebdomadaire."),
        "de": ("Den Testern in der ersten Woche der Beta ein kurzes Willkommensgespräch anbieten, ihre häufigsten Fragen festhalten und die zehn häufigsten vor dem öffentlichen Start zu Hilfeartikeln machen, damit der Support nicht zweimal dieselbe Frage beantworten muss.",
               "Das Feedback der ersten Betawoche in einem Dokument sammeln, nach Größe des Workspace und nach Team gruppieren, jede Meldung zum Sync-Dienst markieren und die Zusammenfassung vor dem nächsten wöchentlichen Meeting mit dem Team teilen."),
        "it": ("Offrire ai tester una breve chiamata di benvenuto nella prima settimana della beta, annotare le domande più frequenti e trasformare le dieci più ricorrenti in articoli di aiuto prima del lancio pubblico, così l’assistenza non risponde due volte alla stessa domanda.",
               "Raccogliere in un solo documento i riscontri della prima settimana della beta, raggrupparli per dimensione dello spazio e per team, segnare ogni segnalazione che cita il servizio di sincronizzazione e condividere la sintesi con il team prima della prossima riunione settimanale."),
        "pt": ("Oferecer aos testadores uma breve chamada de boas-vindas na primeira semana da beta, anotar as perguntas mais frequentes e transformar as dez mais comuns em artigos de ajuda antes do lançamento público, para que o suporte não responda duas vezes à mesma pergunta.",
               "Reunir em um único documento o retorno da primeira semana da beta, agrupá-lo por tamanho de espaço e por equipe, marcar cada relato que cite o serviço de sincronização e compartilhar o resumo com a equipe antes da próxima reunião semanal."),
        "ja": ("ベータの最初の1週間にテスター向けの短いウェルカムコールを開き、よく出る質問を記録して、いちばん多い10件を一般公開の前にヘルプ記事にすることで、サポートが同じ質問に二度答えなくて済むようにする。",
               "ベータ最初の1週間のフィードバックを1つの文書にまとめ、ワークスペースの大きさとチームごとに分類し、同期サービスに触れた報告にはすべて印を付けて、次の定例の前にチームへ要約を共有する"),
        "ko": ("베타 첫 주에 테스터를 위한 짧은 환영 통화를 열고, 가장 자주 나오는 질문을 기록해 상위 열 개를 정식 출시 전에 도움말 문서로 만들어서 지원팀이 같은 질문에 두 번 답하지 않게 한다.",
               "베타 첫 주의 피드백을 한 문서에 모으고, 작업 공간 크기와 팀별로 나눈 뒤, 동기화 서비스를 언급한 보고에는 모두 표시를 해서 다음 주간 회의 전에 팀에 요약을 공유하기"),
        "zh": ("在测试版的第一周为测试人员安排一次简短的欢迎通话，记录他们最常问的问题，并在公开发布之前把最常见的十个问题整理成帮助文章，这样支持团队就不用把同一个问题回答两遍。",
               "把测试版第一周的反馈汇总到一份文档里，按工作区大小和团队分组，给每条提到同步服务的报告做上标记，并在下次周会之前把摘要分享给团队"),
    ]

    private static let many: [String: [String]] = [
        "en": ["Freeze new features in the beta build until the first week of feedback is in.",
               "Check that the onboarding screens read well in every supported language",
               "Keep the empty-state illustrations simple for the first beta.",
               "Reproduce the sync time-out on a large test workspace and log the slowest calls",
               "Tell testers about the 500-item limit in the welcome email.",
               "Collect Northwind’s questions before the usability sessions",
               "Cover launch-week support with a shared rota instead of one person.",
               "Ask the support team how many people they can spare for launch week",
               "Keep the previous build available for 48 hours after the beta ships."],
        "es": ["Congelar las funciones nuevas de la beta hasta recibir los comentarios de la primera semana.",
               "Comprobar que las pantallas de bienvenida se leen bien en todos los idiomas compatibles",
               "Mantener sencillas las ilustraciones de los estados vacíos en la primera beta.",
               "Reproducir el error de tiempo de espera de la sincronización en un espacio de prueba grande y anotar las llamadas más lentas",
               "Avisar a los probadores del límite de 500 elementos en el correo de bienvenida.",
               "Reunir las preguntas de Northwind antes de las sesiones de usabilidad",
               "Cubrir el soporte de la semana del lanzamiento con un turno compartido en lugar de una sola persona.",
               "Preguntar al equipo de soporte cuántas personas pueden dedicar a la semana del lanzamiento",
               "Mantener disponible la versión anterior durante 48 horas tras publicar la beta."],
        "fr": ["Geler les nouvelles fonctionnalités de la bêta jusqu’aux premiers retours d’une semaine.",
               "Vérifier que les écrans d’accueil se lisent bien dans toutes les langues prises en charge",
               "Garder des illustrations simples pour les états vides de la première bêta.",
               "Reproduire le délai dépassé de la synchronisation sur un grand espace de test et noter les appels les plus lents",
               "Prévenir les testeurs de la limite de 500 éléments dans l’e\u{2011}mail de bienvenue.",
               "Recueillir les questions de Northwind avant les sessions d’utilisabilité",
               "Assurer le support de la semaine du lancement avec un roulement partagé plutôt qu’avec une seule personne.",
               "Demander à l’équipe du support combien de personnes elle peut libérer pour la semaine du lancement",
               "Garder la version précédente disponible pendant 48 heures après la sortie de la bêta."],
        "de": ["Neue Funktionen im Beta-Build einfrieren, bis das Feedback der ersten Woche vorliegt.",
               "Prüfen, ob die Onboarding-Bildschirme in jeder unterstützten Sprache gut lesbar sind",
               "Die Illustrationen der leeren Zustände für die erste Beta einfach halten.",
               "Das Sync-Timeout in einem großen Test-Workspace nachstellen und die langsamsten Aufrufe protokollieren",
               "Die Tester in der Willkommens-E-Mail auf das Limit von 500 Einträgen hinweisen.",
               "Die Fragen von Northwind vor den Usability-Sitzungen sammeln",
               "Den Support in der Startwoche mit einem gemeinsamen Dienstplan statt mit einer Person abdecken.",
               "Das Support-Team fragen, wie viele Leute es für die Startwoche freistellen kann",
               "Den vorherigen Build nach dem Beta-Start 48 Stunden lang bereithalten."],
        "it": ["Bloccare le nuove funzioni della beta finché non arriva il riscontro della prima settimana.",
               "Verificare che le schermate di benvenuto si leggano bene in tutte le lingue supportate",
               "Mantenere semplici le illustrazioni degli stati vuoti nella prima beta.",
               "Riprodurre il timeout della sincronizzazione su un grande spazio di prova e annotare le chiamate più lente",
               "Avvisare i tester del limite di 500 elementi nell’email di benvenuto.",
               "Raccogliere le domande di Northwind prima delle sessioni di usabilità",
               "Coprire l’assistenza della settimana del lancio con un turno condiviso invece che con una sola persona.",
               "Chiedere al team di assistenza quante persone può dedicare alla settimana del lancio",
               "Tenere disponibile la versione precedente per 48 ore dopo il rilascio della beta."],
        "pt": ["Congelar os novos recursos da beta até chegar o retorno da primeira semana.",
               "Verificar se as telas de boas-vindas ficam bem legíveis em todos os idiomas compatíveis",
               "Manter simples as ilustrações dos estados vazios na primeira beta.",
               "Reproduzir o tempo limite da sincronização em um espaço de teste grande e registrar as chamadas mais lentas",
               "Avisar os testadores sobre o limite de 500 itens no e\u{2011}mail de boas-vindas.",
               "Reunir as perguntas da Northwind antes das sessões de usabilidade",
               "Cobrir o suporte da semana do lançamento com um revezamento compartilhado, em vez de uma pessoa só.",
               "Perguntar à equipe de suporte quantas pessoas ela pode reservar para a semana do lançamento",
               "Manter a versão anterior disponível por 48 horas depois do lançamento da beta."],
        "ja": ["ベータ版の新機能は、最初の1週間のフィードバックが届くまで凍結する。",
               "オンボーディング画面が対応するすべての言語で読みやすいか確認する",
               "最初のベータでは、空の状態のイラストをシンプルに保つ。",
               "大きなテスト用ワークスペースで同期のタイムアウトを再現し、遅い呼び出しを記録する",
               "ウェルカムメールで、500項目までの制限をテスターに伝える。",
               "ユーザビリティセッションの前にNorthwindからの質問を集める",
               "ローンチ週のサポートは、1人ではなく共有のシフト表で担当する。",
               "ローンチ週に何人割けるかをサポートチームに確認する",
               "ベータ公開後、前のビルドを48時間は使えるようにしておく。"],
        "ko": ["첫 주 피드백이 들어올 때까지 베타 빌드의 새 기능은 동결한다.",
               "온보딩 화면이 지원하는 모든 언어에서 잘 읽히는지 확인하기",
               "첫 베타에서는 빈 상태 일러스트를 단순하게 유지한다.",
               "큰 테스트 작업 공간에서 동기화 시간 초과를 재현하고 가장 느린 호출 기록하기",
               "환영 이메일로 테스터에게 500개 항목 제한을 알린다.",
               "사용성 테스트 전에 노스윈드의 질문 모으기",
               "출시 주 지원은 한 사람이 아니라 공유 당번표로 맡는다.",
               "출시 주에 몇 명을 낼 수 있는지 지원팀에 묻기",
               "베타 배포 후 48시간 동안은 이전 빌드를 계속 받을 수 있게 둔다."],
        "zh": ["在收到第一周的反馈之前，冻结测试版的新功能。",
               "检查引导界面在所有支持的语言中是否都读得通顺",
               "第一个测试版的空状态插图保持简单。",
               "在大型测试工作区里重现同步超时，并记录最慢的调用",
               "在欢迎邮件里告知测试人员 500 项的上限。",
               "在可用性测试之前收集 Northwind 的问题",
               "发布周的支持由共享轮值表负责，而不是只靠一个人。",
               "问支持团队发布周能抽出多少人",
               "测试版发布后的 48 小时内，继续提供上一个版本。"],
    ]
}
#endif
