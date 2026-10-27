// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What a long meeting settled, for the digest a small window writes its summary from: the decisions and tasks of the block extracts after
/// Swift validated them (the quote is in the cited segment) and `ItemEvidence` checked them against the lines around, each with a status.
/// The summary is written from these first, so it states results instead of what each block "discussed". No model is involved.
struct MinutesOutcome: Equatable {
    enum Status: String { case agreed, rejected, task, proposed }
    let status: Status
    let text: String
    let segment: Int64
    let t: Double

    /// Ranked (confirmed decisions, confirmed tasks, then what is only proposed; later first inside a rank, since a later
    /// statement is the one that stands), cut to `limit` lines, and returned in meeting order.
    static func select(from minutes: ValidatedMinutes, limit: Int) -> [MinutesOutcome] {
        var all: [(rank: Int, outcome: MinutesOutcome)] = []
        for d in minutes.decisions {
            let status: Status = d.unconfirmed ? .proposed : isRejection(d.text) ? .rejected : .agreed
            all.append((d.unconfirmed ? 2 : 0, .init(status: status, text: d.text, segment: d.segment, t: d.t)))
        }
        for t in minutes.tasks {
            all.append((t.unconfirmed ? 3 : 1, .init(status: t.unconfirmed ? .proposed : .task, text: t.text, segment: t.segment, t: t.t)))
        }
        let ranked = all.sorted { a, b in a.rank != b.rank ? a.rank < b.rank : a.outcome.t > b.outcome.t }
        // Two blocks often extract the same point in other words: the better ranked copy stays.
        var chosen: [MinutesOutcome] = []
        var keys: [Set<String>] = []
        for (_, outcome) in ranked where chosen.count < max(0, limit) {
            let key = SummaryChecks.contentKey(outcome.text)
            if key.count >= 2, keys.contains(where: { SummaryChecks.jaccard($0, key) >= 0.6 }) { continue }
            chosen.append(outcome)
            keys.append(key)
        }
        return chosen.sorted { ($0.t, $0.segment) < ($1.t, $1.segment) }
    }

    /// A decision whose words say something was turned down, dropped or cut. Not a model: a short list of words per language.
    static func isRejection(_ text: String) -> Bool {
        let norm = TextKeys.norm(text)
        return ["reject", "rejected", "drop ", "dropped", "decided against", "ruled out", "scrapped", "voted down", "not to ", "no longer",
                                         "will not", "won t", "cancel", "turned down", "rechaz", "descart", "no se aprob", "no aprob", "se elimin", "elimin", "desestim",
                                         "refus", "abandon", "ablehn", "rifiut", "rejeit", "recus"].contains { norm.contains($0) }
    }

    /// The label in front of the outcome's line in the digest.
    var label: String {
        switch status {
        case .agreed: "Agreed"
        case .rejected: "Rejected"
        case .task: "Task"
        case .proposed: "Proposed only"
        }
    }

    /// The outcomes as the digest shows them, in meeting order, one labelled line each.
    static func lines(_ outcomes: [MinutesOutcome], characters: Int = lineCharacters) -> String {
        (["Results of the meeting:"] + outcomes.map { "- \($0.label): " + PromptText.defang(PromptText.clip(SingleLineText.flatten($0.text), characters)) })
            .joined(separator: "\n")
    }

    static let lineCharacters = 130
}
