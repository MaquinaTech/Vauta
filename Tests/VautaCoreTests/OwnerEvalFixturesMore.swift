// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
@testable import VautaCore

/// The meetings of the offline owner evaluation, second half: the Asian languages and the hard cases (labels the
/// diarizer is unsure about, crosstalk, a second voice on the user's microphone, a model that mixes people up).
extension OwnerEvalCase {
    static let secondHalf: [OwnerEvalCase] = [japanese, korean, chinese, englishDoubtful, germanMixedUp, frenchRoomVoice]

    static let japanese = OwnerEvalCase(
        id: "ja リリース準備", locale: "ja-JP", people: ["田中", "佐藤"],
        speakers: [me, remote("田中"), remote("佐藤")],
        lines: [
            Line(1, 0.95, "来週のリリースの準備を確認しましょう。"),
            Line(2, 0.93, "請求書の確認は私が対応します。"),
            Line(1, 0.91, "では、顧客への連絡は私がやります。"),
            Line(0, 0.99, "資料の作成は僕が担当します。"),
            Line(2, 0.86, "田中さん、会議室の予約をお願いできますか。"),
        ],
        gold: [Gold(line: 1, owner: "佐藤"), Gold(line: 2, owner: "田中"), Gold(line: 3, owner: "Me"), Gold(line: 4, owner: "田中")],
        baseline: [
            Output("請求書を確認する", line: 1, owner: "田中", quote: "請求書の確認は私が対応します"),
            Output("顧客に連絡する", line: 2, owner: nil, quote: "顧客への連絡は私がやります"),
            Output("資料を作成する", line: 3, owner: "Me", quote: "資料の作成は僕が担当します"),
            Output("会議室を予約する", line: 4, owner: "田中", quote: "会議室の予約をお願いできますか"),
        ],
        withSpeakers: [
            Output("請求書を確認する", line: 1, owner: "佐藤", quote: "請求書の確認は私が対応します"),
            Output("顧客に連絡する", line: 2, owner: "田中", quote: "顧客への連絡は私がやります"),
            Output("資料を作成する", line: 3, owner: "Me", quote: "資料の作成は僕が担当します"),
            Output("会議室を予約する", line: 4, owner: "田中", quote: "会議室の予約をお願いできますか"),
        ],
        planted: [])

    static let korean = OwnerEvalCase(
        id: "ko 예산 보고서", locale: "ko-KR", people: ["민수", "지은"],
        speakers: [me, remote("민수"), remote("지은")],
        lines: [
            Line(1, 0.95, "이번 주 예산 보고서를 마무리해야 해요."),
            Line(2, 0.92, "보고서는 제가 금요일까지 정리하겠습니다."),
            Line(1, 0.90, "그럼 고객 연락은 제가 할게요."),
            Line(0, 0.99, "회의록은 제가 보낼게요."),
            Line(2, 0.88, "민수 씨, 계약서 12장을 확인해 주실래요."),
        ],
        gold: [Gold(line: 1, owner: "지은"), Gold(line: 2, owner: "민수"), Gold(line: 3, owner: "Me"), Gold(line: 4, owner: "민수")],
        baseline: [
            Output("예산 보고서 정리", line: 1, owner: "민수", quote: "보고서는 제가 금요일까지 정리하겠습니다", due: "2026-10-09"),
            Output("고객에게 연락", line: 2, owner: nil, quote: "고객 연락은 제가 할게요"),
            Output("회의록 발송", line: 3, owner: "Me", quote: "회의록은 제가 보낼게요"),
            Output("계약서 12장 확인", line: 4, owner: "민수", quote: "계약서 12장을 확인해 주실래요"),
        ],
        withSpeakers: [
            Output("예산 보고서 정리", line: 1, owner: "지은", quote: "보고서는 제가 금요일까지 정리하겠습니다", due: "2026-10-09"),
            Output("고객에게 연락", line: 2, owner: "민수", quote: "고객 연락은 제가 할게요"),
            Output("회의록 발송", line: 3, owner: "Me", quote: "회의록은 제가 보낼게요"),
            Output("계약서 12장 확인", line: 4, owner: "민수", quote: "계약서 12장을 확인해 주실래요"),
        ],
        planted: [])

    static let chinese = OwnerEvalCase(
        id: "zh 预算", locale: "zh-CN", people: ["李明", "王芳"],
        speakers: [me, remote("李明"), remote("王芳")],
        lines: [
            Line(1, 0.95, "我们需要在周五之前确认预算。"),
            Line(2, 0.93, "预算表我来处理，今天下班前给大家。"),
            Line(1, 0.91, "客户那边我负责联系，一共5家。"),
            Line(0, 0.99, "会议纪要我会发给大家。"),
            Line(2, 0.87, "李明，你可以检查一下合同吗？"),
            Line(1, 0.90, "好的。"),
        ],
        gold: [Gold(line: 1, owner: "王芳"), Gold(line: 2, owner: "李明"), Gold(line: 3, owner: "Me"), Gold(line: 4, owner: "李明")],
        baseline: [
            Output("整理预算表", line: 1, owner: "李明", quote: "预算表我来处理，今天下班前给大家", due: "2026-10-06"),
            Output("联系5家客户", line: 2, owner: nil, quote: "客户那边我负责联系，一共5家"),
            Output("发送会议纪要", line: 3, owner: "Me", quote: "会议纪要我会发给大家"),
            Output("检查合同", line: 4, owner: "李明", quote: "你可以检查一下合同吗"),
        ],
        withSpeakers: [
            Output("整理预算表", line: 1, owner: "王芳", quote: "预算表我来处理，今天下班前给大家", due: "2026-10-06"),
            Output("联系5家客户", line: 2, owner: "李明", quote: "客户那边我负责联系，一共5家"),
            Output("发送会议纪要", line: 3, owner: "Me", quote: "会议纪要我会发给大家"),
            Output("检查合同", line: 4, owner: "李明", quote: "你可以检查一下合同吗"),
        ],
        planted: [])

    /// Labels the diarizer is unsure about, crosstalk and a speaker nobody named.
    static let englishDoubtful = OwnerEvalCase(
        id: "en doubtful labels", locale: "en-US", people: ["Priya", "Daniel"],
        speakers: [me, remote("Priya"), remote("Daniel"), remote(nil)],
        lines: [
            Line(1, 0.95, "Okay, let's decide who owns the onboarding flow."),
            Line(3, 0.80, "I'll take the onboarding copy."),
            Line(2, 0.91, "I'll own the analytics dashboard, due next week."),
            Line(1, 0.45, "I can pick up the three bug fixes."),
            Line(0, 0.99, "Great, I'll write the release notes."),
            Line(2, 0.90, "I'll handle the invoices as well.", overlap: true),
            // Nobody takes it in the words: the model guesses an owner nothing in the meeting supports.
            Line(1, 0.90, "We should also run the customer survey."),
        ],
        // Nobody the meeting names owns the copy; Priya and Daniel did take the last two, but the labels cannot say so.
        gold: [Gold(line: 1, owner: nil), Gold(line: 2, owner: "Daniel"), Gold(line: 3, owner: "Priya"), Gold(line: 4, owner: "Me"),
               Gold(line: 5, owner: "Daniel"), Gold(line: 6, owner: nil)],
        baseline: [
            Output("Write the onboarding copy", line: 1, owner: "Priya", quote: "take the onboarding copy"),
            Output("Own the analytics dashboard", line: 2, owner: "Priya", quote: "own the analytics dashboard", due: "2026-10-13"),
            Output("Fix three bugs", line: 3, owner: "Daniel", quote: "pick up the three bug fixes"),
            Output("Write the release notes", line: 4, owner: "Me", quote: "write the release notes"),
            Output("Handle the invoices", line: 5, owner: "Priya", quote: "handle the invoices as well"),
            Output("Run the customer survey", line: 6, owner: "Daniel", quote: "run the customer survey"),
        ],
        withSpeakers: [
            Output("Write the onboarding copy", line: 1, owner: nil, quote: "take the onboarding copy"),
            Output("Own the analytics dashboard", line: 2, owner: "Daniel", quote: "own the analytics dashboard", due: "2026-10-13"),
            Output("Fix three bugs", line: 3, owner: "Priya", quote: "pick up the three bug fixes"),
            Output("Write the release notes", line: 4, owner: "Me", quote: "write the release notes"),
            Output("Handle the invoices", line: 5, owner: "Daniel", quote: "handle the invoices as well"),
            Output("Run the customer survey", line: 6, owner: "Daniel", quote: "run the customer survey"),
        ],
        planted: [])

    /// A model that mixes people up even though the labels are clear: the code corrects it.
    static let germanMixedUp = OwnerEvalCase(
        id: "de model mixes people up", locale: "de-DE", people: ["Lena", "Tobias"],
        speakers: [me, remote("Lena"), remote("Tobias")],
        lines: [
            Line(1, 0.95, "Die Präsentation muss bis Donnerstag fertig sein."),
            Line(2, 0.92, "Ich mache die Folien bis Donnerstag fertig."),
            Line(1, 0.90, "Dann schicke ich Ihnen die 6 Verträge noch heute."),
            Line(0, 0.99, "Ich übernehme die Abstimmung mit der Technik."),
        ],
        gold: [Gold(line: 1, owner: "Tobias"), Gold(line: 2, owner: "Lena"), Gold(line: 3, owner: "Me")],
        baseline: [
            Output("Folien fertigstellen", line: 1, owner: "Lena", quote: "mache die Folien bis Donnerstag fertig", due: "2026-10-08"),
            Output("6 Verträge schicken", line: 2, owner: nil, quote: "schicke ich Ihnen die 6 Verträge noch heute"),
            Output("Abstimmung mit der Technik", line: 3, owner: "Me", quote: "übernehme die Abstimmung mit der Technik"),
        ],
        withSpeakers: [
            Output("Folien fertigstellen", line: 1, owner: "Lena", quote: "mache die Folien bis Donnerstag fertig", due: "2026-10-08"),
            Output("6 Verträge schicken", line: 2, owner: nil, quote: "schicke ich Ihnen die 6 Verträge noch heute"),
            Output("Abstimmung mit der Technik", line: 3, owner: "Me", quote: "übernehme die Abstimmung mit der Technik"),
        ],
        planted: [])

    /// A second voice on the user's own microphone, whom nobody named.
    static let frenchRoomVoice = OwnerEvalCase(
        id: "fr voice in the room", locale: "fr-FR", people: ["Inès"],
        speakers: [me, remote("Inès"), roomVoice],
        lines: [
            Line(1, 0.95, "Bonjour à tous, on commence."),
            Line(2, 0.80, "Je vais appeler le fournisseur demain."),
            Line(0, 0.99, "Je vais envoyer le compte rendu ce soir."),
            Line(0, 0.97, "Inès, peux-tu confirmer la salle ?"),
            Line(1, 0.90, "Oui."),
        ],
        gold: [Gold(line: 1, owner: nil), Gold(line: 2, owner: "Me"), Gold(line: 3, owner: "Inès")],
        baseline: [
            Output("Appeler le fournisseur", line: 1, owner: "Me", quote: "vais appeler le fournisseur demain", due: "2026-10-07"),
            Output("Envoyer le compte rendu", line: 2, owner: "Me", quote: "vais envoyer le compte rendu ce soir"),
            Output("Confirmer la salle", line: 3, owner: "Inès", quote: "peux-tu confirmer la salle"),
        ],
        withSpeakers: [
            Output("Appeler le fournisseur", line: 1, owner: "Me", quote: "vais appeler le fournisseur demain", due: "2026-10-07"),
            Output("Envoyer le compte rendu", line: 2, owner: "Me", quote: "vais envoyer le compte rendu ce soir"),
            Output("Confirmer la salle", line: 3, owner: "Inès", quote: "peux-tu confirmer la salle"),
        ],
        planted: [])
}
