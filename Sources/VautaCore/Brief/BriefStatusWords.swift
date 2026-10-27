// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Words that claim a status ("agreed", "approved", "done") in the nine languages, for `BriefVerifier`. Code data, not interface text.
/// Entries are in the folded form of `TextKeys.norm` (lower case, no accents). Words that are also everyday words of another language
/// (French "décidé" folds to English "decide", the imperative the agenda uses) are left out. CJK entries are matched as substrings.
enum BriefStatusWords {
    /// A claim that a decision was taken: backed by a cited decision, or by the word in a cited item.
    static let decided: [String] = [
        // en
        "agreed", "approved", "decided", "confirmed", "resolved", "settled",
        // es, pt
        "acordado", "acordada", "aprobado", "aprobada", "decidido", "decidida", "confirmado", "confirmada", "resuelto", "resuelta",
        "aprovado", "aprovada", "resolvido", "resolvida",
        // fr
        "convenu", "convenue", "approuve", "approuvee", "decidee", "confirme", "confirmee", "resolu", "resolue",
        // de
        "vereinbart", "genehmigt", "beschlossen", "bestatigt", "geklart",
        // it
        "concordato", "concordata", "approvato", "approvata", "deciso", "decisa", "confermato", "confermata", "risolto", "risolta",
        // ja
        "合意済", "承認済", "決定済", "確認済", "解決済",
        // ko
        "합의됨", "승인됨", "확정됨", "확인됨", "해결됨", "합의했", "승인했", "확정했",
        // zh
        "已同意", "已批准", "已确认", "已決定", "已决定", "已解决", "已商定", "已確認", "已解決",
    ]

    /// A claim that work is finished: only a cited item that says so backs it.
    static let completed: [String] = [
        "done", "completed", "finished", "closed", "delivered",
        "terminado", "terminada", "completado", "completada", "cerrado", "cerrada", "entregado", "entregada",
        "concluido", "concluida", "finalizado", "finalizada", "fechado", "fechada", "entregue",
        "termine", "terminee", "fini", "finie", "livre", "livree",
        "erledigt", "abgeschlossen", "fertig", "geliefert", "beendet",
        "completato", "completata", "terminato", "terminata", "concluso", "conclusa", "chiuso", "chiusa", "consegnato",
        "完了", "終了済", "済み", "完成", "対応済",
        "완료됨", "완료했", "마무리됨", "종료됨",
        "已完成", "已结束", "已交付", "完成了", "已关闭", "已完成", "已結束", "已關閉",
    ]

    static func isCJK(_ word: String) -> Bool {
        word.unicodeScalars.contains { TextKeys.isNoSpaceScript($0) || (0xAC00...0xD7AF).contains($0.value) }
    }

    /// The words of `list` that `norm` (a folded text) contains.
    static func claims(in norm: String, _ list: [String]) -> [String] {
        list.filter { word in isCJK(word) ? norm.contains(word) : PromptText.containsNormalizedWords(norm, word) }
    }
}
