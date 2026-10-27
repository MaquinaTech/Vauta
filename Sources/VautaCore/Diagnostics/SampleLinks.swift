// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import Foundation

/// Links to earlier meetings for the UI snapshot renderer: a task or decision of the featured meeting that repeats or replaces one of an
/// earlier sample meeting, in the state a scene needs. Rows are written with the store's own functions (confirm, dismiss), so a scene
/// shows what a person would see. Invented; nothing is real.
extension SampleWorld {
    /// What the "budget" decisions say in the language being rendered (`{n}` is the figure).
    private static let budgetWords: [String: String] = [
        "en": "Budget capped at {n}", "es": "Presupuesto máximo de {n}", "fr": "Budget plafonné à {n}", "de": "Budget auf {n} begrenzt",
        "it": "Budget limitato a {n}", "pt": "Orçamento limitado a {n}", "ja": "予算の上限は{n}", "ko": "예산 상한은 {n}", "zh": "预算上限为{n}",
    ]

    private var budgetText: String { Self.budgetWords[locale.language.languageCode?.identifier ?? "en"] ?? Self.budgetWords["en"]! }

    /// The state a seeded link is left in.
    public enum LinkSeedState: Sendable { case suggested, confirmed, dismissed }

    /// Back to the sample minutes: no links, no dismissals, no vectors, and none of the items the link scenes added.
    public func resetLinks() async throws {
        try await store.resetLinksForSnapshots()
        let keepFeatured = Set(content.meetings[0].tasks.map(\.text))
        for task in try await store.tasks(featuredMeetingID) where !keepFeatured.contains(task.text) && task.source == "llm" && task.status == .open {
            // Items the scenes added (copies of other meetings' tasks): the sample's own are never touched.
            if content.meetings.dropFirst().contains(where: { $0.tasks.contains { $0.text == task.text } }) { try await store.deleteTask(task.id) }
        }
        for index in meetingIDs.indices.dropFirst() {
            let keep = Set(content.meetings[index].tasks.map(\.text))
            for task in try await store.tasks(meetingIDs[index]) where !keep.contains(task.text) { try await store.deleteTask(task.id) }
            let keepDecisions = Set(content.meetings[index].decisions.map(\.0))
            for decision in try await store.decisions(meetingIDs[index]) where !keepDecisions.contains(decision.text) { try await store.deleteDecision(decision.id) }
        }
        let keepDecisions = Set(content.meetings[0].decisions.map(\.0))
        for decision in try await store.decisions(featuredMeetingID) where !keepDecisions.contains(decision.text) { try await store.deleteDecision(decision.id) }
    }

    /// The first task of the featured meeting repeats a task of the previous sample meeting (same words, its owner and a due day).
    @discardableResult
    public func seedTaskLink(_ state: LinkSeedState = .suggested, task index: Int = 0, earlierMeeting: Int = 1, earlierUnconfirmed: Bool = false,
                             earlierDone: Bool = false) async throws -> (newer: Int64, earlier: Int64) {
        try await resetLinks()
        let newer = try await store.tasks(featuredMeetingID)[index]
        let due = dueDate(ofMeeting: earlierMeeting, afterDays: 0)
        let earlier = try await store.addTask(meetingIDs[earlierMeeting], text: newer.text, ownerID: newer.ownerID, due: due, segmentID: nil, source: "llm")
        if earlierUnconfirmed { try await store.markForSnapshots(task: earlier, unconfirmed: true, ownerUncertain: false, reason: "figures") }
        if earlierDone { try await store.setTaskStatus(earlier, .done) }
        try await link(.task, newer.id, earlier, state: state)
        return (newer.id, earlier)
    }

    /// A second suggestion on the next task of the featured meeting (after `seedTaskLink`), so a meeting has two waiting.
    public func seedSecondTaskLink() async throws {
        let tasks = try await store.tasks(featuredMeetingID)
        guard tasks.count > 1 else { return }
        let earlier = try await store.addTask(meetingIDs[1], text: tasks[1].text, ownerID: tasks[1].ownerID, source: "llm")
        try await link(.task, tasks[1].id, earlier, state: .suggested)
    }

    /// The first decision of the featured meeting repeats a decision of the previous sample meeting. With `.changes` the featured one carries
    /// another figure and the evidence names both.
    @discardableResult
    public func seedDecisionLink(_ relation: LinkRelation, _ state: LinkSeedState = .suggested, decision index: Int = 0,
                                 earlierUnconfirmed: Bool = false) async throws -> (newer: Int64, earlier: Int64) {
        try await resetLinks()
        let decisions = try await store.decisions(featuredMeetingID)
        var newer = decisions[index]
        var earlierText = newer.text
        var evidence: String?
        if relation == .changes {
            let before = "40.000 €", now = "48.200 €"
            // A decision of its own (first in the list), so the sample's decisions are never edited.
            let id = try await store.addDecision(featuredMeetingID, text: budgetText.replacingOccurrences(of: "{n}", with: now), segmentID: newer.segmentID, t: 0, source: "llm")
            newer = try await store.decisions(featuredMeetingID).first { $0.id == id } ?? newer
            earlierText = budgetText.replacingOccurrences(of: "{n}", with: before)
            evidence = #"{"a":["\#(before)"],"b":["\#(now)"]}"#
        }
        let earlier = try await store.addDecision(meetingIDs[1], text: earlierText, segmentID: nil, source: "llm")
        if earlierUnconfirmed { try await store.markForSnapshots(decision: earlier, reason: "figures") }
        try await link(.decision, newer.id, earlier, rel: relation, state: state, evidence: evidence)
        return (newer.id, earlier)
    }

    /// A second decision link on the other decision of the featured meeting (so a scene can show a suggestion and a confirmed one).
    public func seedSecondDecisionLink(_ state: LinkSeedState, relation: LinkRelation = .same) async throws {
        let decisions = try await store.decisions(featuredMeetingID)
        guard decisions.count > 1 else { return }
        let second = decisions[1]
        let earlier = try await store.addDecision(meetingIDs[1], text: second.text, segmentID: nil, source: "llm")
        try await link(.decision, second.id, earlier, rel: relation, state: state, evidence: nil)
    }

    /// An open task that the person confirmed is the same in three meetings: the featured one, the previous and the one before. The featured
    /// task is the newest member and stands for the chain in Tasks mode.
    @discardableResult
    public func seedTaskChain(dueDifference: Bool = false) async throws -> [Int64] {
        try await resetLinks()
        let text = content.meetings[1].tasks[0].text
        let owner = content.meetings[1].tasks[0].owner.map { peopleIDs[$0] }
        let day = { (n: Int) in Optional(dueDate(ofMeeting: 0, afterDays: n)) }
        let newest = try await store.addTask(featuredMeetingID, text: text, ownerID: owner, due: day(dueDifference ? 14 : 5), source: "llm")
        let middle = (try await store.tasks(meetingIDs[1])).first { $0.text == text }?.id
        guard let middle else { return [] }
        let oldest = try await store.addTask(meetingIDs[2], text: text, ownerID: owner, due: day(dueDifference ? 5 : 5), source: "llm")
        try await link(.task, newest, middle, state: .confirmed)
        try await link(.task, middle, oldest, state: .confirmed)
        return [newest, middle, oldest]
    }

    /// Two pairs the person said are not the same (a task and a decision), listed in the featured meeting's To Review tab.
    public func seedDismissedLinks() async throws {
        try await resetLinks()
        let task = try await store.tasks(featuredMeetingID)[0]
        let earlierTask = try await store.addTask(meetingIDs[1], text: task.text, ownerID: task.ownerID, source: "llm")
        try await link(.task, task.id, earlierTask, state: .dismissed)
        let decision = try await store.decisions(featuredMeetingID)[0]
        let earlierDecision = try await store.addDecision(meetingIDs[1], text: decision.text, source: "llm")
        try await link(.decision, decision.id, earlierDecision, state: .dismissed)
    }

    private func link(_ kind: LinkKind, _ src: Int64, _ dst: Int64, rel: LinkRelation = .same, state: LinkSeedState, evidence: String? = nil) async throws {
        let id = try await store.insertLinkForSnapshots(kind: kind, src: src, dst: dst, rel: rel, evidence: evidence)
        switch state {
        case .suggested: break
        case .confirmed: try await store.confirmLink(id)
        case .dismissed: try await store.dismissLink(id)
        }
    }
}

extension MeetingStore {
    func resetLinksForSnapshots() async throws {
        try run("DELETE FROM item_links")
        try run("DELETE FROM item_link_dismissals")
        try run("DELETE FROM item_vectors")
        // Confirming a link made its two items the person's; the sample's own items are the model's again.
        try run("UPDATE tasks SET source = 'llm' WHERE created_at > 0")
        try run("UPDATE decisions SET source = 'llm' WHERE created_at > 0")
        try await commitEdit()
    }

    func insertLinkForSnapshots(kind: LinkKind, src: Int64, dst: Int64, rel: LinkRelation, evidence: String?) async throws -> Int64 {
        try run("""
            INSERT INTO item_links(kind, src_id, dst_id, rel, state, method, score, evidence, recipe, created_at) VALUES (?, ?, ?, ?, 'suggested', 'keyword', 0.9, ?, ?, ?)
            """, [.text(kind.rawValue), .integer(src), .integer(dst), .text(rel.rawValue), evidence.map { .text($0) }, .integer(Int64(LinkPolicy.recipe)),
                  .real(AppClock.now.timeIntervalSince1970)])
        let id = db.lastInsertRowID
        try await commitEdit()
        return id
    }
}
#endif
