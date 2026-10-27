// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import Foundation

/// Invented text for the brief's scenes, in the language being rendered: reminders, invitation lines, a document and a note, a related
/// meeting and the suggested agenda. The meetings, people, tasks and decisions come from the sample store itself.
struct BriefSample {
    let reminders: [String]
    let invitation: [String]
    let materialFile: String
    let documentFile: String
    let documentText: String
    let noteFile: String
    let noteText: String
    let relatedText: String
    let followUp: String
    let decide: String
    let ask: String
    let longTitle: String
    let lists: [String]

    static func forLanguage(_ language: String) -> BriefSample {
        switch language {
        case "es":
            BriefSample(reminders: ["enviar la lista revisada de la beta", "preguntar a soporte por la semana del lanzamiento", "reservar una sala para las sesiones de usabilidad"],
                        invitation: ["Estado de la beta y bloqueos", "Cobertura de soporte en la semana del lanzamiento", "Sesiones de usabilidad con Northwind"],
                        materialFile: "Lista de la beta.xlsx", documentFile: "Plan de lanzamiento.pdf",
                        documentText: "La beta llega a los probadores el jueves y el lanzamiento público sigue el día 28.",
                        noteFile: "Turnos de soporte.md", noteText: "Soporte cubre los días laborables de 9 a 18 durante la semana del lanzamiento.",
                        relatedText: "Espacios compartidos y exportación de auditoría para el piloto.",
                        followUp: "El plan de marcha atrás de la beta", decide: "Quién cubre soporte en la semana del lanzamiento",
                        ask: "Si Northwind necesita inicio de sesión único",
                        longTitle: "Revisión trimestral de planificación, presupuesto y contratación de las áreas de plataforma, datos y diseño con los responsables regionales",
                        lists: ["Trabajo", "Personal"])
        case "fr":
            BriefSample(reminders: ["envoyer la liste de contrôle révisée de la bêta", "demander au support la couverture de la semaine du lancement", "réserver une salle pour les sessions d’utilisabilité"],
                        invitation: ["État de la bêta et points bloquants", "Couverture du support la semaine du lancement", "Sessions d’utilisabilité avec Northwind"],
                        materialFile: "Liste de la bêta.xlsx", documentFile: "Plan de lancement.pdf",
                        documentText: "La bêta part chez les testeurs jeudi et le lancement public reste fixé au 28.",
                        noteFile: "Planning du support.md", noteText: "Le support couvre les jours ouvrés de 9 h à 18 h pendant la semaine du lancement.",
                        relatedText: "Espaces partagés et export d’audit pour le pilote.",
                        followUp: "Le plan de retour arrière de la bêta", decide: "Qui couvre le support la semaine du lancement",
                        ask: "Si Northwind a besoin de l’authentification unique",
                        longTitle: "Revue trimestrielle de la planification, du budget et des recrutements des équipes plateforme, données et design avec les responsables régionaux",
                        lists: ["Travail", "Personnel"])
        case "de":
            BriefSample(reminders: ["die überarbeitete Beta-Checkliste schicken", "beim Support die Abdeckung der Startwoche erfragen", "einen Raum für die Usability-Sitzungen buchen"],
                        invitation: ["Stand der Beta und Blocker", "Support-Abdeckung in der Startwoche", "Usability-Sitzungen mit Northwind"],
                        materialFile: "Beta-Checkliste.xlsx", documentFile: "Launch-Plan.pdf",
                        documentText: "Die Beta geht am Donnerstag an die Tester, der öffentliche Start bleibt am 28.",
                        noteFile: "Support-Dienstplan.md", noteText: "Der Support deckt in der Startwoche die Werktage von 9 bis 18 Uhr ab.",
                        relatedText: "Geteilte Arbeitsbereiche und Audit-Export für den Pilot.",
                        followUp: "Der Rollback-Plan für die Beta", decide: "Wer in der Startwoche den Support übernimmt",
                        ask: "Ob Northwind Single Sign-on braucht",
                        longTitle: "Quartalsplanung, Budgetprüfung und Einstellungsplan der Plattform-, Daten- und Designteams mit den regionalen Verantwortlichen",
                        lists: ["Arbeit", "Privat"])
        case "it":
            BriefSample(reminders: ["inviare la checklist rivista della beta", "chiedere al supporto la copertura della settimana del lancio", "prenotare una sala per le sessioni di usabilità"],
                        invitation: ["Stato della beta e blocchi", "Copertura del supporto nella settimana del lancio", "Sessioni di usabilità con Northwind"],
                        materialFile: "Checklist della beta.xlsx", documentFile: "Piano di lancio.pdf",
                        documentText: "La beta arriva ai tester giovedì e il lancio pubblico resta il 28.",
                        noteFile: "Turni del supporto.md", noteText: "Il supporto copre i giorni feriali dalle 9 alle 18 nella settimana del lancio.",
                        relatedText: "Spazi condivisi ed esportazione di audit per il pilota.",
                        followUp: "Il piano di ripristino della beta", decide: "Chi copre il supporto nella settimana del lancio",
                        ask: "Se Northwind ha bisogno del single sign-on",
                        longTitle: "Revisione trimestrale di pianificazione, budget e assunzioni dei team piattaforma, dati e design con i responsabili regionali",
                        lists: ["Lavoro", "Personale"])
        case "pt-BR":
            BriefSample(reminders: ["enviar a lista revisada da beta", "perguntar ao suporte sobre a cobertura da semana do lançamento", "reservar uma sala para as sessões de usabilidade"],
                        invitation: ["Situação da beta e bloqueios", "Cobertura do suporte na semana do lançamento", "Sessões de usabilidade com a Northwind"],
                        materialFile: "Lista da beta.xlsx", documentFile: "Plano de lançamento.pdf",
                        documentText: "A beta vai para os testadores na quinta e o lançamento público continua no dia 28.",
                        noteFile: "Escala do suporte.md", noteText: "O suporte cobre os dias úteis das 9h às 18h na semana do lançamento.",
                        relatedText: "Espaços compartilhados e exportação de auditoria para o piloto.",
                        followUp: "O plano de reversão da beta", decide: "Quem cobre o suporte na semana do lançamento",
                        ask: "Se a Northwind precisa de login único",
                        longTitle: "Revisão trimestral de planejamento, orçamento e contratações das equipes de plataforma, dados e design com os responsáveis regionais",
                        lists: ["Trabalho", "Pessoal"])
        case "ja":
            BriefSample(reminders: ["ベータ版の改訂チェックリストを送る", "ローンチ週のサポート体制をサポートに確認する", "ユーザビリティセッション用の部屋を予約する"],
                        invitation: ["ベータ版の状況とブロッカー", "ローンチ週のサポート体制", "Northwindとのユーザビリティセッション"],
                        materialFile: "ベータ版チェックリスト.xlsx", documentFile: "ローンチ計画.pdf",
                        documentText: "ベータ版は木曜にテスターへ配布し、一般公開は28日のままです。",
                        noteFile: "サポート当番.md", noteText: "ローンチ週は平日の9時から18時までサポートが対応します。",
                        relatedText: "パイロット向けの共有ワークスペースと監査エクスポート。",
                        followUp: "ベータ版のロールバック計画", decide: "ローンチ週のサポート担当者",
                        ask: "Northwindにシングルサインオンが必要かどうか",
                        longTitle: "プラットフォーム・データ・デザイン各チームの四半期計画と予算・採用計画レビュー会議（各地域リーダー合同）",
                        lists: ["仕事", "個人"])
        case "ko":
            BriefSample(reminders: ["수정한 베타 체크리스트 보내기", "출시 주간 지원 체계를 지원팀에 문의하기", "사용성 세션용 회의실 예약하기"],
                        invitation: ["베타 현황과 걸림돌", "출시 주간 지원 체계", "노스윈드와의 사용성 세션"],
                        materialFile: "베타 체크리스트.xlsx", documentFile: "출시 계획.pdf",
                        documentText: "베타는 목요일에 테스터에게 전달되고 정식 출시는 28일 그대로입니다.",
                        noteFile: "지원 당번표.md", noteText: "출시 주간에는 평일 9시부터 18시까지 지원팀이 대응합니다.",
                        relatedText: "파일럿을 위한 공유 작업 공간과 감사 내보내기.",
                        followUp: "베타 롤백 계획", decide: "출시 주간 지원 담당자",
                        ask: "노스윈드에 싱글 사인온이 필요한지 여부",
                        longTitle: "플랫폼·데이터·디자인 팀의 분기 계획, 예산 검토 및 채용 계획 회의 (지역별 책임자 합동)",
                        lists: ["업무", "개인"])
        case "zh-Hans":
            BriefSample(reminders: ["发送修订后的测试版检查清单", "向支持团队确认发布周的值班安排", "为可用性测试预订会议室"],
                        invitation: ["测试版进展与阻碍", "发布周的支持安排", "与 Northwind 的可用性测试"],
                        materialFile: "测试版检查清单.xlsx", documentFile: "发布计划.pdf",
                        documentText: "测试版周四发给测试人员，公开发布仍定在 28 日。",
                        noteFile: "支持值班表.md", noteText: "发布周内，支持团队在工作日 9 点至 18 点值班。",
                        relatedText: "试点用的共享工作区和审计导出。",
                        followUp: "测试版的回滚方案", decide: "发布周的支持负责人",
                        ask: "Northwind 是否需要单点登录",
                        longTitle: "平台、数据和设计团队的季度规划、预算评审与招聘计划会议（与各地区负责人）",
                        lists: ["工作", "个人"])
        default:
            BriefSample(reminders: ["send the revised beta checklist", "ask support about launch week coverage", "book a room for the usability sessions"],
                        invitation: ["Beta status and blockers", "Support coverage for launch week", "Usability sessions with Northwind"],
                        materialFile: "Beta checklist.xlsx", documentFile: "Launch plan.pdf",
                        documentText: "The beta goes to testers on Thursday and the public launch stays on the 28th.",
                        noteFile: "Support rota.md", noteText: "Support covers weekdays from 9 to 18 during launch week.",
                        relatedText: "Shared workspaces and the audit export for the pilot.",
                        followUp: "The rollback plan for the beta", decide: "Who covers support during launch week",
                        ask: "Whether Northwind needs single sign-on",
                        longTitle: "Quarterly planning, budget review and hiring plan for the platform, data and design teams with the regional leads",
                        lists: ["Work", "Personal"])
        }
    }
}
#endif
