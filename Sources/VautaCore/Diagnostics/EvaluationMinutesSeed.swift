// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

extension BriefEvaluation.StoredMinutes {
    /// Writes these minutes into a seeded meeting as the app writes minutes, so an evaluation that reads them back (the follow-up email, the
    /// brief) sees what the app would show. Minutes written since the extraction phase carry the flags and citations the app stores: each
    /// item with a cited segment goes in through `applyMinutes`, with its confirmation and reason (an item the ranking left out stays out of
    /// the brief, as in the app). An item without a mapped citation is added on its own, with its flags and no segment; older files have no
    /// citations at all and every item goes that way. `segments` maps the line IDs the minutes cite to the store's segments. Returns how many
    /// items had no mapped citation.
    func seed(into store: MeetingStore, meeting id: Int64, segments dbID: [Int64: Int64], zone: TimeZone,
              owner: (Task) -> Int64?, ownerSpeaker: (Task) async -> Int64? = { _ in nil }) async throws -> Int {
        try await store.saveCard(MeetingCard(summary: summary ?? "", topics: [], openQuestions: open_questions ?? []), of: id)
        let starts = Dictionary(uniqueKeysWithValues: try await store.segments(of: id).map { ($0.id, $0.start) })
        var validated = ValidatedMinutes()
        validated.summary = summary ?? ""
        validated.openQuestions = open_questions ?? []
        var lone: [(decision: Decision?, task: Task?)] = []
        for d in decisions ?? [] {
            if let seg = d.citations?.first.flatMap({ dbID[$0] }) {
                var item = ValidatedMinutes.Item(text: d.text, segment: seg, t: starts[seg] ?? 0, unconfirmed: d.unconfirmed ?? false)
                item.doubt = d.reason
                validated.decisions.append(item)
            } else { lone.append((d, nil)) }
        }
        for t in tasks ?? [] {
            if let seg = t.citations?.first.flatMap({ dbID[$0] }) {
                let day = t.due.flatMap { DueDay(String($0.trimmingCharacters(in: .whitespaces).prefix(10))) }
                var item = ValidatedMinutes.Task(text: t.text, owner: owner(t), due: day?.startOfDay(in: zone), segment: seg, t: starts[seg] ?? 0, unconfirmed: t.unconfirmed ?? false,
                                                 ownerUncertain: t.owner_uncertain ?? false, ownerSpeaker: await ownerSpeaker(t), dueDay: day)
                item.doubt = t.reason
                validated.tasks.append(item)
            } else { lone.append((nil, t)) }
        }
        if !validated.decisions.isEmpty || !validated.tasks.isEmpty { try await store.applyMinutes(validated, to: id) }
        for item in lone {
            if let d = item.decision {
                let row = try await store.addDecision(id, text: d.text, source: "llm")
                if d.unconfirmed == true { try await store.flagForEvaluation(decision: row, reason: d.reason) }
            } else if let t = item.task {
                // No citation, so no segment: addTask stores the owner as a person only, and an unnamed speaker owner is not kept (the runs report these as unmapped).
                let day = t.due.flatMap { DueDay(String($0.trimmingCharacters(in: .whitespaces).prefix(10))) }
                let row = try await store.addTask(id, text: t.text, ownerID: owner(t), due: day?.startOfDay(in: zone), dueDay: day, source: "llm")
                if t.unconfirmed == true || t.owner_uncertain == true { try await store.flagForEvaluation(task: row, unconfirmed: t.unconfirmed ?? false, ownerUncertain: t.owner_uncertain ?? false, reason: t.reason) }
            }
        }
        return lone.count
    }
}
