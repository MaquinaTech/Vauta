// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import Foundation

/// What the model "wrote" from the sample bullets, by hand, in the nine interface languages: complete sentences that say more
/// than the bullet, from what the sample transcript says (the snapshots show an enriched note, not a repeated transcript line).
/// Each sentence cites a sample line whose text backs it; the quote is cut from that line.
struct SnapshotNoteWriting {
    /// The recording in the panel and the notepad (the sample's three live lines).
    let panelBeta: String
    let panelNotes: String
    /// Says something the transcript does not say about the note (shown after "The transcript says:").
    let panelDiffers: String
    /// A saved meeting (the featured meeting's lines).
    let tabBeta: String
    /// A claim the line does not back (a figure that is not in it).
    let tabUnconfirmed: String
    let tabBetaMore: String
    let tabNotes: String
    let tabDiffers: String
    let tabDecision: String
    /// The user's own rewrite.
    let tabEdited: String

    static func forLanguage(_ code: String) -> SnapshotNoteWriting {
        switch code.split(separator: "-").first.map(String.init) ?? code {
        case "es": spanish
        case "ja": japanese
        case "fr": french
        case "de": german
        case "it": italian
        case "pt": portuguese
        case "ko": korean
        case "zh": chinese
        default: english
        }
    }

    static let english = SnapshotNoteWriting(
        panelBeta: "The beta build is stable and can ship on Thursday.",
        panelNotes: "You will write the release notes today.",
        panelDiffers: "The release notes are written today; nothing was said about a migration section.",
        tabBeta: "The beta build is stable and the last blocking bug was closed yesterday.",
        tabUnconfirmed: "Two blocking bugs were closed yesterday.",
        tabBetaMore: "It can ship to testers on Thursday.",
        tabNotes: "You agreed to write the release notes and send them to Northwind before Thursday.",
        tabDiffers: "The release notes go to Northwind before Thursday; no migration section was mentioned.",
        tabDecision: "The team decided to ship the beta to testers on Thursday and keep the public launch on the 28th.",
        tabEdited: "Beta to testers on Thursday; the launch stays on the 28th.")

    static let spanish = SnapshotNoteWriting(
        panelBeta: "La beta es estable y se puede enviar el jueves.",
        panelNotes: "Escribirás las notas de la versión hoy.",
        panelDiffers: "Las notas de la versión se escriben hoy; no se dijo nada de una sección de migración.",
        tabBeta: "La beta es estable y ayer se cerró el último error bloqueante.",
        tabUnconfirmed: "Ayer se cerraron dos errores bloqueantes.",
        tabBetaMore: "Se puede enviar a los probadores el jueves.",
        tabNotes: "Quedaste en escribir las notas de la versión y enviárselas a Northwind antes del jueves.",
        tabDiffers: "Las notas de la versión van a Northwind antes del jueves; no se mencionó ninguna sección de migración.",
        tabDecision: "Se decidió enviar la beta a los probadores el jueves y mantener el lanzamiento público el día 28.",
        tabEdited: "Beta a probadores el jueves; el lanzamiento sigue el 28.")

    static let french = SnapshotNoteWriting(
        panelBeta: "La bêta est stable et peut être livrée jeudi.",
        panelNotes: "Vous rédigerez les notes de version aujourd’hui.",
        panelDiffers: "Les notes de version sont rédigées aujourd’hui ; rien n’a été dit sur une section de migration.",
        tabBeta: "La bêta est stable et le dernier bug bloquant a été corrigé hier.",
        tabUnconfirmed: "Deux bugs bloquants ont été corrigés hier.",
        tabBetaMore: "Elle peut être livrée aux testeurs jeudi.",
        tabNotes: "Vous avez convenu de rédiger les notes de version et de les envoyer à Northwind avant jeudi.",
        tabDiffers: "Les notes de version partent chez Northwind avant jeudi ; aucune section sur la migration n’a été mentionnée.",
        tabDecision: "L’équipe a décidé de livrer la bêta aux testeurs jeudi et de garder le lancement public le 28.",
        tabEdited: "Bêta aux testeurs jeudi ; le lancement reste le 28.")

    static let german = SnapshotNoteWriting(
        panelBeta: "Der Beta-Build ist stabil und kann am Donnerstag ausgeliefert werden.",
        panelNotes: "Die Release Notes werden heute geschrieben.",
        panelDiffers: "Die Release Notes werden heute geschrieben; zu einem Migrationsabschnitt wurde nichts gesagt.",
        tabBeta: "Der Beta-Build ist stabil, und der letzte blockierende Fehler wurde gestern behoben.",
        tabUnconfirmed: "Gestern wurden zwei blockierende Fehler behoben.",
        tabBetaMore: "Er kann am Donnerstag an die Tester gehen.",
        tabNotes: "Vereinbart wurde, die Release Notes zu schreiben und vor Donnerstag an Northwind zu schicken.",
        tabDiffers: "Die Release Notes gehen vor Donnerstag an Northwind; ein Migrationsabschnitt wurde nicht erwähnt.",
        tabDecision: "Das Team hat beschlossen, die Beta am Donnerstag an die Tester auszuliefern und den öffentlichen Start am 28. beizubehalten.",
        tabEdited: "Beta am Donnerstag an Tester; Start bleibt am 28.")

    static let italian = SnapshotNoteWriting(
        panelBeta: "La build beta è stabile e può essere consegnata giovedì.",
        panelNotes: "Scriverai le note di rilascio oggi.",
        panelDiffers: "Le note di rilascio si scrivono oggi; non si è detto nulla di una sezione sulla migrazione.",
        tabBeta: "La build beta è stabile e ieri è stato chiuso l’ultimo bug bloccante.",
        tabUnconfirmed: "Ieri sono stati chiusi due bug bloccanti.",
        tabBetaMore: "Può essere consegnata ai tester giovedì.",
        tabNotes: "Hai concordato di scrivere le note di rilascio e di inviarle a Northwind prima di giovedì.",
        tabDiffers: "Le note di rilascio vanno a Northwind prima di giovedì; non è stata citata alcuna sezione sulla migrazione.",
        tabDecision: "Il team ha deciso di consegnare la beta ai tester giovedì e di mantenere il lancio pubblico il 28.",
        tabEdited: "Beta ai tester giovedì; il lancio resta il 28.")

    static let portuguese = SnapshotNoteWriting(
        panelBeta: "A versão beta está estável e pode ser liberada na quinta.",
        panelNotes: "Você vai escrever as notas da versão hoje.",
        panelDiffers: "As notas da versão são escritas hoje; nada foi dito sobre uma seção de migração.",
        tabBeta: "A versão beta está estável e o último bug bloqueante foi fechado ontem.",
        tabUnconfirmed: "Dois bugs bloqueantes foram fechados ontem.",
        tabBetaMore: "Ela pode ser liberada para os testadores na quinta.",
        tabNotes: "Você combinou de escrever as notas da versão e enviá-las à Northwind antes de quinta.",
        tabDiffers: "As notas da versão vão para a Northwind antes de quinta; nenhuma seção sobre migração foi mencionada.",
        tabDecision: "A equipe decidiu liberar a beta para os testadores na quinta e manter o lançamento público no dia 28.",
        tabEdited: "Beta para testadores na quinta; lançamento continua no dia 28.")

    static let japanese = SnapshotNoteWriting(
        panelBeta: "ベータ版は安定しており、木曜日に配布できます。",
        panelNotes: "リリースノートは今日書きます。",
        panelDiffers: "リリースノートは今日書きます。移行の項目については何も話されていません。",
        tabBeta: "ベータ版は安定しており、最後のブロッキングバグは昨日解消されました。",
        tabUnconfirmed: "ブロッキングバグが昨日2件解消されました。",
        tabBetaMore: "木曜日にテスターへ配布できます。",
        tabNotes: "リリースノートを書き、木曜日までにNorthwindへ送ることで合意しました。",
        tabDiffers: "リリースノートは木曜日までにNorthwindへ送ります。移行の項目には触れられていません。",
        tabDecision: "ベータは木曜日にテスターへ配布し、一般公開は28日のままにすると決まりました。",
        tabEdited: "ベータは木曜日にテスターへ。公開は28日のまま。")

    static let korean = SnapshotNoteWriting(
        panelBeta: "베타 빌드가 안정적이어서 목요일에 배포할 수 있습니다.",
        panelNotes: "릴리스 노트는 오늘 작성합니다.",
        panelDiffers: "릴리스 노트는 오늘 작성합니다. 마이그레이션 항목에 대해서는 언급이 없었습니다.",
        tabBeta: "베타 빌드가 안정적이고, 마지막 차단 버그는 어제 해결되었습니다.",
        tabUnconfirmed: "차단 버그 두 건이 어제 해결되었습니다.",
        tabBetaMore: "목요일에 테스터에게 배포할 수 있습니다.",
        tabNotes: "릴리스 노트를 작성해 목요일 전에 노스윈드에 보내기로 했습니다.",
        tabDiffers: "릴리스 노트는 목요일 전에 노스윈드에 보냅니다. 마이그레이션 항목은 언급되지 않았습니다.",
        tabDecision: "베타는 목요일에 테스터에게 배포하고 공개 출시는 28일로 유지하기로 했습니다.",
        tabEdited: "베타는 목요일에 테스터에게, 출시는 28일 유지.")

    static let chinese = SnapshotNoteWriting(
        panelBeta: "测试版构建很稳定，周四可以发布。",
        panelNotes: "你今天会撰写发布说明。",
        panelDiffers: "发布说明今天撰写；没有提到迁移部分。",
        tabBeta: "测试版构建很稳定，最后一个阻塞性缺陷昨天已关闭。",
        tabUnconfirmed: "昨天关闭了两个阻塞性缺陷。",
        tabBetaMore: "周四可以发给测试人员。",
        tabNotes: "已约定撰写发布说明，并在周四前发给 Northwind。",
        tabDiffers: "发布说明会在周四前发给 Northwind，没有提到迁移部分。",
        tabDecision: "决定周四把测试版发给测试人员，公开发布仍定在28日。",
        tabEdited: "周四测试版发给测试人员；发布仍在28日。")
}
#endif
