// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import Foundation

/// Invented meetings for the UI snapshot renderer (`Vauta render-ui`). Nothing
/// here is real data. The content exists in the nine interface languages, and every
/// language mirrors the English meetings line by line (see `featuredTranslations`).
public struct SampleContent: Sendable {
    public struct Person: Sendable {
        let name: String
        let note: String
        let aliases: [String]
    }

    public struct Line: Sendable {
        let mine: Bool
        let text: String
    }

    struct SampleTask: Sendable {
        let text: String
        /// Index into `people` (0 = the user) or nil.
        let owner: Int?
        let dueInDays: Int?
        let segment: Int
    }

    struct SampleMeeting: Sendable {
        let daysAgo: Int
        let hour: Int
        let minutes: Int
        let title: String
        let lines: [Line]
        let summary: String
        let topics: [String]
        /// (text, segment index)
        let decisions: [(String, Int)]
        let tasks: [SampleTask]
        let questions: [String]
        /// Indexes into `people` (1…).
        let attendees: [Int]
    }

    /// Index 0 is the user ("Me"); 1… are the other people.
    public let people: [Person]
    public let project: Person
    public let client: Person
    public let glossary: [(term: String, expansion: String)]
    let meetings: [SampleMeeting]
    /// The recording shown in the menu-bar panel.
    public let liveTranscript: [Line]
    public let livePoints: [String]
    public let liveDecisions: [String]
    public let liveTasks: [String]
    public let askQuestion: String
    public let askAnswer: String
    /// (claim, segment index in the first meeting)
    public let askClaims: [(String, Int)]
    public let notes: [String]
    public let searchQuery: String
    public let callApp = "Zoom"

    /// Translations of the featured meeting's lines, line by line: the Spanish text for English,
    /// the English text for every other language.
    var featuredTranslations: [String] {
        let other = isEnglish ? SampleContent.spanish : SampleContent.english
        // The same people under the other language's names (Priya, not Carmen): a translation never changes who is addressed.
        let renames: [(from: String, to: String)] = zip(other.people, people).compactMap { theirs, ours in
            guard let from = theirs.aliases.first, let to = ours.aliases.first, from != to else { return nil }
            return (from, to)
        }
        return other.meetings[0].lines.map { line in renames.reduce(line.text) { $0.replacingOccurrences(of: $1.from, with: $1.to) } }
    }

    /// The featured meeting's title, a decision, a task and an open question, in the sample's language (the dialogs name them).
    public var featuredTitle: String { meetings[0].title }
    public var featuredDecision: String { meetings[0].decisions.first?.0 ?? "" }
    public var featuredTask: String { meetings[0].tasks.first?.text ?? "" }
    public var featuredQuestion: String { meetings[0].questions.first ?? "" }

    /// The language code of `featuredTranslations`.
    var featuredTranslationLanguage: String { isEnglish ? "es" : "en" }

    private var isEnglish: Bool { people.first?.name == "Me" }

    public static func forLanguage(_ code: String) -> SampleContent {
        switch code.split(separator: "-").first.map(String.init) ?? code {
        case "es": .spanish
        case "ja": .japanese
        case "fr": .french
        case "de": .german
        case "it": .italian
        case "pt": .portugueseBrazil
        case "ko": .korean
        case "zh": .simplifiedChinese
        default: .english
        }
    }

    // MARK: English

    static let english = SampleContent(
        people: [
            Person(name: "Me", note: "", aliases: []),
            Person(name: "Maya Chen", note: "Product lead", aliases: ["Maya"]),
            Person(name: "Daniel Okafor", note: "Engineering manager", aliases: ["Daniel"]),
            Person(name: "Priya Raman", note: "Design", aliases: ["Priya"]),
        ],
        project: Person(name: "Atlas launch", note: "Public launch on the 28th", aliases: ["Atlas"]),
        client: Person(name: "Northwind", note: "Pilot customer", aliases: []),
        glossary: [("SLA", "Service level agreement"), ("RC", "Release candidate")],
        meetings: [
            SampleMeeting(
                daysAgo: 0, hour: 10, minutes: 24, title: "Weekly product sync",
                lines: [
                    Line(mine: false, text: "Thanks everyone for joining. Let’s start with the Atlas launch date. Daniel, where are we on the beta?"),
                    Line(mine: false, text: "The beta build is stable. We closed the last blocking bug yesterday, so we can ship to testers on Thursday."),
                    Line(mine: true, text: "Great. Priya, are the onboarding screens ready for that build?"),
                    Line(mine: false, text: "Almost. I still need to finish the empty states, but I can hand them over by Wednesday."),
                    Line(mine: false, text: "Then let’s decide: we ship the beta to testers on Thursday and keep the public launch on the 28th."),
                    Line(mine: true, text: "Agreed. I’ll write the release notes and send them to Northwind before Thursday."),
                    Line(mine: false, text: "One risk is the sync service. It still times out on large workspaces."),
                    Line(mine: true, text: "Can we limit the first beta to workspaces under five hundred items?"),
                    Line(mine: false, text: "Yes, let’s do that and revisit after the first week of feedback."),
                    Line(mine: false, text: "I’d also like to run two quick usability sessions with Northwind next week."),
                    Line(mine: false, text: "Good idea. Priya, please schedule them. Do we know who will cover support during launch week?"),
                    Line(mine: true, text: "Not yet. That is still open, we need to talk to the support team."),
                    Line(mine: false, text: "I’ll also prepare a rollback plan in case the beta misbehaves."),
                    Line(mine: false, text: "Perfect. Let’s close here. Thanks everyone."),
                ],
                summary: "The team agreed to ship the Atlas beta to testers on Thursday and keep the public launch on the 28th. The first beta is limited to small workspaces because the sync service still times out on large ones. Design will hand over the onboarding empty states by Wednesday, and two usability sessions with Northwind are planned for next week.",
                topics: ["Atlas launch", "Beta rollout", "Sync service", "Usability sessions"],
                decisions: [("Ship the beta to testers on Thursday and keep the public launch on the 28th.", 4),
                            ("Limit the first beta to workspaces under 500 items.", 8)],
                tasks: [SampleTask(text: "Write the release notes and send them to Northwind", owner: 0, dueInDays: 2, segment: 5),
                        SampleTask(text: "Hand over the onboarding empty states", owner: 3, dueInDays: 1, segment: 3),
                        SampleTask(text: "Schedule two usability sessions with Northwind", owner: 3, dueInDays: 7, segment: 10),
                        SampleTask(text: "Prepare a rollback plan for the beta", owner: 2, dueInDays: 3, segment: 12)],
                questions: ["Who covers support during launch week?", "How will the sync timeout be fixed for large workspaces?"],
                attendees: [1, 2, 3]),
            SampleMeeting(
                daysAgo: 1, hour: 16, minutes: 31, title: "1:1 with Daniel",
                lines: [
                    Line(mine: true, text: "How is the team doing after the last release?"),
                    Line(mine: false, text: "Tired but happy. I would like to give everyone a recovery day before the beta."),
                    Line(mine: true, text: "That works for me. Please send me the plan and I will approve it today."),
                    Line(mine: false, text: "Also, I am proposing a quarterly hardening sprint to reduce the bug backlog."),
                ],
                summary: "Daniel proposed a recovery day for the team before the beta and a quarterly hardening sprint to reduce the bug backlog.",
                topics: ["Team health", "Hardening sprint"],
                decisions: [("Give the team a recovery day before the beta.", 2)],
                tasks: [SampleTask(text: "Approve Daniel’s recovery day plan", owner: 0, dueInDays: 0, segment: 2)],
                questions: [], attendees: [2]),
            SampleMeeting(
                daysAgo: 4, hour: 11, minutes: 47, title: "Northwind kickoff call",
                lines: [
                    Line(mine: true, text: "Welcome, and thank you for being our pilot customer. Let me walk you through the plan."),
                    Line(mine: false, text: "We are most interested in shared workspaces and the audit export."),
                    Line(mine: true, text: "Both are in the beta. Maya will share the test accounts this week."),
                    Line(mine: false, text: "Great, our team can start testing next Monday."),
                ],
                summary: "Northwind will pilot Atlas, focusing on shared workspaces and the audit export. Test accounts are shared this week and testing starts next Monday.",
                topics: ["Northwind pilot", "Shared workspaces", "Audit export"],
                decisions: [],
                tasks: [SampleTask(text: "Share the test accounts with Northwind", owner: 1, dueInDays: 3, segment: 2)],
                questions: ["Does Northwind need single sign-on during the pilot?"], attendees: [1]),
            SampleMeeting(
                daysAgo: 6, hour: 15, minutes: 38, title: "Design review",
                lines: [
                    Line(mine: false, text: "Here is the new onboarding flow. It has four steps instead of six."),
                    Line(mine: true, text: "Much clearer. Can we keep the permissions step last?"),
                    Line(mine: false, text: "Yes, that tested better with the pilot users."),
                ],
                summary: "Priya presented a shorter onboarding flow with four steps. The permissions step stays last because it tested better.",
                topics: ["Onboarding flow", "Permissions"],
                decisions: [("Keep the permissions step last in onboarding.", 2)],
                tasks: [], questions: [], attendees: [3]),
        ],
        liveTranscript: [
            Line(mine: false, text: "So the beta build is stable and we can ship on Thursday."),
            Line(mine: true, text: "Great, then I will write the release notes today."),
            Line(mine: false, text: "One risk is the sync service on large workspaces."),
        ],
        livePoints: ["Beta build is stable", "Sync service times out on large workspaces"],
        liveDecisions: ["Ship the beta to testers on Thursday"],
        liveTasks: ["Write the release notes (Me)"],
        askQuestion: "What did we decide about the beta?",
        askAnswer: "The beta ships to testers on Thursday, limited to workspaces under 500 items, and the public launch stays on the 28th.",
        askClaims: [("The beta ships to testers on Thursday and the public launch stays on the 28th.", 4),
                    ("The first beta is limited to workspaces under 500 items.", 8)],
        notes: ["Ask Northwind about single sign-on", "Release notes need a short migration section"],
        searchQuery: "beta")

    // MARK: Spanish

    static let spanish = SampleContent(
        people: [
            Person(name: "Yo", note: "", aliases: []),
            Person(name: "Lucía Navarro", note: "Responsable de producto", aliases: ["Lucía"]),
            Person(name: "Daniel Herrera", note: "Jefe de ingeniería", aliases: ["Daniel"]),
            Person(name: "Carmen Vidal", note: "Diseño", aliases: ["Carmen"]),
        ],
        project: Person(name: "Lanzamiento Atlas", note: "Lanzamiento público el día 28", aliases: ["Atlas"]),
        client: Person(name: "Northwind", note: "Cliente piloto", aliases: []),
        glossary: [("SLA", "Acuerdo de nivel de servicio"), ("RC", "Candidata a versión final")],
        meetings: [
            SampleMeeting(
                daysAgo: 0, hour: 10, minutes: 24, title: "Reunión semanal de producto",
                lines: [
                    Line(mine: false, text: "Gracias a todos por conectaros. Empecemos por la fecha del lanzamiento de Atlas. Daniel, ¿cómo va la beta?"),
                    Line(mine: false, text: "La versión beta es estable. Cerramos el último fallo bloqueante ayer, así que podemos enviarla a los probadores el jueves."),
                    Line(mine: true, text: "Genial. Carmen, ¿están listas las pantallas de bienvenida para esa versión?"),
                    Line(mine: false, text: "Casi. Me faltan los estados vacíos, pero puedo entregarlos el miércoles."),
                    Line(mine: false, text: "Entonces decidamos: enviamos la beta a los probadores el jueves y mantenemos el lanzamiento público el día 28."),
                    Line(mine: true, text: "De acuerdo. Escribiré las notas de la versión y se las enviaré a Northwind antes del jueves."),
                    Line(mine: false, text: "Un riesgo es el servicio de sincronización. Todavía da error por tiempo de espera con espacios grandes."),
                    Line(mine: true, text: "¿Podemos limitar la primera beta a espacios de menos de quinientos elementos?"),
                    Line(mine: false, text: "Sí, hagámoslo y lo revisamos tras la primera semana de comentarios."),
                    Line(mine: false, text: "También querría hacer dos sesiones de usabilidad rápidas con Northwind la semana que viene."),
                    Line(mine: false, text: "Buena idea. Carmen, por favor, organízalas. ¿Sabemos quién cubrirá el soporte durante la semana del lanzamiento?"),
                    Line(mine: true, text: "Todavía no. Sigue abierto, tenemos que hablar con el equipo de soporte."),
                    Line(mine: false, text: "Yo también prepararé un plan de vuelta atrás por si la beta falla."),
                    Line(mine: false, text: "Perfecto. Lo dejamos aquí. Gracias a todos."),
                ],
                summary: "El equipo acordó enviar la beta de Atlas a los probadores el jueves y mantener el lanzamiento público el día 28. La primera beta se limita a espacios pequeños porque el servicio de sincronización aún falla con los grandes. Diseño entregará los estados vacíos de la bienvenida el miércoles y se planean dos sesiones de usabilidad con Northwind la semana próxima.",
                topics: ["Lanzamiento de Atlas", "Despliegue de la beta", "Servicio de sincronización", "Sesiones de usabilidad"],
                decisions: [("Enviar la beta a los probadores el jueves y mantener el lanzamiento público el día 28.", 4),
                            ("Limitar la primera beta a espacios de menos de 500 elementos.", 8)],
                tasks: [SampleTask(text: "Escribir las notas de la versión y enviarlas a Northwind", owner: 0, dueInDays: 2, segment: 5),
                        SampleTask(text: "Entregar los estados vacíos de la bienvenida", owner: 3, dueInDays: 1, segment: 3),
                        SampleTask(text: "Organizar dos sesiones de usabilidad con Northwind", owner: 3, dueInDays: 7, segment: 10),
                        SampleTask(text: "Preparar un plan de vuelta atrás para la beta", owner: 2, dueInDays: 3, segment: 12)],
                questions: ["¿Quién cubre el soporte durante la semana del lanzamiento?", "¿Cómo se corregirá el tiempo de espera de la sincronización en espacios grandes?"],
                attendees: [1, 2, 3]),
            SampleMeeting(
                daysAgo: 1, hour: 16, minutes: 31, title: "Uno a uno con Daniel",
                lines: [
                    Line(mine: true, text: "¿Cómo está el equipo después de la última versión?"),
                    Line(mine: false, text: "Cansado pero contento. Me gustaría dar un día de descanso a todos antes de la beta."),
                    Line(mine: true, text: "Me parece bien. Envíame el plan y lo apruebo hoy."),
                    Line(mine: false, text: "Además propongo un sprint trimestral de estabilización para reducir los errores pendientes."),
                ],
                summary: "Daniel propuso un día de descanso para el equipo antes de la beta y un sprint trimestral de estabilización para reducir los errores pendientes.",
                topics: ["Salud del equipo", "Sprint de estabilización"],
                decisions: [("Dar al equipo un día de descanso antes de la beta.", 2)],
                tasks: [SampleTask(text: "Aprobar el plan del día de descanso de Daniel", owner: 0, dueInDays: 0, segment: 2)],
                questions: [], attendees: [2]),
            SampleMeeting(
                daysAgo: 4, hour: 11, minutes: 47, title: "Llamada de inicio con Northwind",
                lines: [
                    Line(mine: true, text: "Bienvenidos, y gracias por ser nuestro cliente piloto. Os explico el plan."),
                    Line(mine: false, text: "Nos interesan sobre todo los espacios compartidos y la exportación de auditoría."),
                    Line(mine: true, text: "Las dos cosas están en la beta. Lucía compartirá las cuentas de prueba esta semana."),
                    Line(mine: false, text: "Perfecto, nuestro equipo puede empezar a probar el próximo lunes."),
                ],
                summary: "Northwind probará Atlas centrándose en los espacios compartidos y la exportación de auditoría. Las cuentas de prueba se comparten esta semana y las pruebas empiezan el próximo lunes.",
                topics: ["Piloto de Northwind", "Espacios compartidos", "Exportación de auditoría"],
                decisions: [],
                tasks: [SampleTask(text: "Compartir las cuentas de prueba con Northwind", owner: 1, dueInDays: 3, segment: 2)],
                questions: ["¿Necesita Northwind inicio de sesión único durante el piloto?"], attendees: [1]),
            SampleMeeting(
                daysAgo: 6, hour: 15, minutes: 38, title: "Revisión de diseño",
                lines: [
                    Line(mine: false, text: "Este es el nuevo flujo de bienvenida. Tiene cuatro pasos en lugar de seis."),
                    Line(mine: true, text: "Mucho más claro. ¿Podemos dejar el paso de permisos al final?"),
                    Line(mine: false, text: "Sí, funcionó mejor con los usuarios del piloto."),
                ],
                summary: "Carmen presentó un flujo de bienvenida más corto, de cuatro pasos. El paso de permisos se queda al final porque funcionó mejor.",
                topics: ["Flujo de bienvenida", "Permisos"],
                decisions: [("Dejar el paso de permisos al final de la bienvenida.", 2)],
                tasks: [], questions: [], attendees: [3]),
        ],
        liveTranscript: [
            Line(mine: false, text: "Entonces la beta es estable y podemos enviarla el jueves."),
            Line(mine: true, text: "Genial, escribiré hoy las notas de la versión."),
            Line(mine: false, text: "Un riesgo es el servicio de sincronización con espacios grandes."),
        ],
        livePoints: ["La beta es estable", "La sincronización falla con espacios grandes"],
        liveDecisions: ["Enviar la beta a los probadores el jueves"],
        liveTasks: ["Escribir las notas de la versión (Yo)"],
        askQuestion: "¿Qué decidimos sobre la beta?",
        askAnswer: "La beta se envía a los probadores el jueves, limitada a espacios de menos de 500 elementos, y el lanzamiento público se mantiene el día 28.",
        askClaims: [("La beta se envía a los probadores el jueves y el lanzamiento público se mantiene el día 28.", 4),
                    ("La primera beta se limita a espacios de menos de 500 elementos.", 8)],
        notes: ["Preguntar a Northwind por el inicio de sesión único", "Las notas de la versión necesitan una sección de migración"],
        searchQuery: "beta")

    // MARK: Japanese

    static let japanese = SampleContent(
        people: [
            Person(name: "自分", note: "", aliases: []),
            Person(name: "田中美咲", note: "プロダクト責任者", aliases: ["田中"]),
            Person(name: "佐藤大輔", note: "エンジニアリングマネージャー", aliases: ["佐藤"]),
            Person(name: "鈴木優", note: "デザイン", aliases: ["鈴木"]),
        ],
        project: Person(name: "アトラス ローンチ", note: "28日に一般公開", aliases: ["アトラス"]),
        client: Person(name: "Northwind", note: "パイロット顧客", aliases: []),
        glossary: [("SLA", "サービスレベル契約"), ("RC", "リリース候補版")],
        meetings: [
            SampleMeeting(
                daysAgo: 0, hour: 10, minutes: 24, title: "週次プロダクト定例",
                lines: [
                    Line(mine: false, text: "皆さん、ご参加ありがとうございます。まずアトラスのローンチ日からいきましょう。佐藤さん、ベータの状況はどうですか。"),
                    Line(mine: false, text: "ベータ版は安定しています。昨日、最後のブロッカーを解消したので、木曜日にテスターへ配布できます。"),
                    Line(mine: true, text: "よかったです。鈴木さん、そのビルドに合わせたオンボーディング画面は用意できますか。"),
                    Line(mine: false, text: "ほぼ完成です。空の状態の画面が残っていますが、水曜日までに渡せます。"),
                    Line(mine: false, text: "では決めましょう。ベータは木曜日にテスターへ配布し、一般公開は28日のままにします。"),
                    Line(mine: true, text: "了解です。リリースノートを書いて、木曜日までにNorthwindへ送ります。"),
                    Line(mine: false, text: "リスクは同期サービスです。大きなワークスペースではまだタイムアウトします。"),
                    Line(mine: true, text: "最初のベータは500件未満のワークスペースに限定できませんか。"),
                    Line(mine: false, text: "はい、そうしましょう。最初の1週間のフィードバックを見て見直します。"),
                    Line(mine: false, text: "来週、Northwindと短いユーザビリティ調査を2回行いたいです。"),
                    Line(mine: false, text: "いいですね。鈴木さん、日程を調整してください。ローンチ週のサポート担当はもう決まっていますか。"),
                    Line(mine: true, text: "まだです。未定なので、サポートチームと話す必要があります。"),
                    Line(mine: false, text: "ベータに問題が出た場合に備えて、ロールバック計画も準備します。"),
                    Line(mine: false, text: "完璧です。ここで終わりにしましょう。ありがとうございました。"),
                ],
                summary: "アトラスのベータを木曜日にテスターへ配布し、一般公開は28日のままとすることで合意した。同期サービスが大きなワークスペースでまだタイムアウトするため、最初のベータは小規模なワークスペースに限定する。デザインは水曜日までにオンボーディングの空の状態を渡し、来週Northwindと2回のユーザビリティ調査を行う予定。",
                topics: ["アトラスのローンチ", "ベータの展開", "同期サービス", "ユーザビリティ調査"],
                decisions: [("ベータは木曜日にテスターへ配布し、一般公開は28日のままにする。", 4),
                            ("最初のベータは500件未満のワークスペースに限定する。", 8)],
                tasks: [SampleTask(text: "リリースノートを書いてNorthwindへ送る", owner: 0, dueInDays: 2, segment: 5),
                        SampleTask(text: "オンボーディングの空の状態の画面を渡す", owner: 3, dueInDays: 1, segment: 3),
                        SampleTask(text: "Northwindとのユーザビリティ調査を2回設定する", owner: 3, dueInDays: 7, segment: 10),
                        SampleTask(text: "ベータのロールバック計画を準備する", owner: 2, dueInDays: 3, segment: 12)],
                questions: ["ローンチ週のサポートは誰が担当するか？", "大きなワークスペースの同期タイムアウトをどう解消するか。"],
                attendees: [1, 2, 3]),
            SampleMeeting(
                daysAgo: 1, hour: 16, minutes: 31, title: "佐藤さんとの1対1",
                lines: [
                    Line(mine: true, text: "前回のリリース後、チームの調子はどうですか。"),
                    Line(mine: false, text: "疲れていますが前向きです。ベータの前に全員へ回復休暇を1日あげたいです。"),
                    Line(mine: true, text: "いいですね。計画を送ってくれれば今日承認します。"),
                    Line(mine: false, text: "それと、未解決のバグを減らすために四半期ごとの改善スプリントを提案します。"),
                ],
                summary: "佐藤さんから、ベータの前にチームへ回復休暇を1日設けることと、未解決のバグを減らすための四半期ごとの改善スプリントが提案された。",
                topics: ["チームの状態", "改善スプリント"],
                decisions: [("ベータの前にチームへ回復休暇を1日設ける。", 2)],
                tasks: [SampleTask(text: "佐藤さんの回復休暇の計画を承認する", owner: 0, dueInDays: 0, segment: 2)],
                questions: [], attendees: [2]),
            SampleMeeting(
                daysAgo: 4, hour: 11, minutes: 47, title: "Northwindキックオフ",
                lines: [
                    Line(mine: true, text: "ようこそ。パイロット顧客になっていただきありがとうございます。計画をご説明します。"),
                    Line(mine: false, text: "共有ワークスペースと監査エクスポートに特に関心があります。"),
                    Line(mine: true, text: "どちらもベータに入っています。田中が今週テスト用アカウントを共有します。"),
                    Line(mine: false, text: "ありがとうございます。来週の月曜日からテストを始められます。"),
                ],
                summary: "Northwindは共有ワークスペースと監査エクスポートを中心にアトラスを試用する。テスト用アカウントは今週共有され、来週の月曜日からテストが始まる。",
                topics: ["Northwindのパイロット", "共有ワークスペース", "監査エクスポート"],
                decisions: [],
                tasks: [SampleTask(text: "Northwindへテスト用アカウントを共有する", owner: 1, dueInDays: 3, segment: 2)],
                questions: ["パイロット中にシングルサインオンは必要か。"], attendees: [1]),
            SampleMeeting(
                daysAgo: 6, hour: 15, minutes: 38, title: "デザインレビュー",
                lines: [
                    Line(mine: false, text: "新しいオンボーディングです。6ステップから4ステップになりました。"),
                    Line(mine: true, text: "ずっと分かりやすいですね。権限のステップは最後のままにできますか。"),
                    Line(mine: false, text: "はい、パイロットユーザーの検証でもその方が良い結果でした。"),
                ],
                summary: "鈴木さんが4ステップの短いオンボーディングを発表した。権限のステップは検証結果が良かったため最後に残す。",
                topics: ["オンボーディングの流れ", "権限"],
                decisions: [("オンボーディングの権限のステップは最後に残す。", 2)],
                tasks: [], questions: [], attendees: [3]),
        ],
        liveTranscript: [
            Line(mine: false, text: "ベータ版は安定しているので、木曜日に配布できます。"),
            Line(mine: true, text: "よかったです。今日中にリリースノートを書きます。"),
            Line(mine: false, text: "リスクは大きなワークスペースでの同期サービスです。"),
        ],
        livePoints: ["ベータ版は安定している", "大きなワークスペースで同期がタイムアウトする"],
        liveDecisions: ["ベータは木曜日にテスターへ配布する"],
        liveTasks: ["リリースノートを書く（自分）"],
        askQuestion: "ベータについて何を決めましたか？",
        askAnswer: "ベータは木曜日に500件未満のワークスペースに限定してテスターへ配布し、一般公開は28日のままです。",
        askClaims: [("ベータは木曜日にテスターへ配布し、一般公開は28日のままです。", 4),
                    ("最初のベータは500件未満のワークスペースに限定します。", 8)],
        notes: ["Northwindにシングルサインオンを確認する", "リリースノートに移行の項目が必要"],
        searchQuery: "ベータ")
}
#endif
