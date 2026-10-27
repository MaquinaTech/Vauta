// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import VautaCore

/// A chain of tasks the person confirmed as the same, as Tasks mode shows it: the newest open member and the mentions before it.
struct OpenTaskChain: Identifiable, Equatable {
    var id: Int64 { task.id }
    let task: TaskItem
    /// The other members, newest first, each with the date of its meeting.
    let earlier: [(task: TaskItem, date: Date)]
    /// The date of the first mention.
    let since: Date
    /// How many meetings mention it (the task shown included).
    let meetings: Int
    /// The earlier mentions still open: the ones "mark done" can close too.
    var earlierOpen: [TaskItem] { earlier.map(\.task).filter { $0.status == .open } }

    static func == (a: OpenTaskChain, b: OpenTaskChain) -> Bool { a.task == b.task && a.meetings == b.meetings && a.since == b.since && a.earlier.map(\.task) == b.earlier.map(\.task) }
}

/// Links to earlier meetings in the Meetings window: the rows under tasks and decisions, the chains of Tasks mode, and the person's answers
/// (each one in the window's undo history).
@MainActor
extension MeetingsModel {
    func linkRow(_ kind: LinkKind, _ id: Int64) -> LinkRow? { linkRows[LinkRowKey(kind: kind, itemID: id)] }

    /// Changes whenever a link row appears, goes or changes state (a row's height changes the table's).
    var linkRowsToken: Int {
        var hasher = Hasher()
        for row in linkRows.values.sorted(by: { $0.id < $1.id }) { hasher.combine(row.id); hasher.combine(row.link.state.rawValue) }
        return hasher.finalize()
    }

    func loadLinks(_ meetingID: Int64) async {
        let rows = (try? await store.linkRows(ofMeeting: meetingID)) ?? [:]
        guard selectedID == meetingID else { return }
        linkRows = rows
        dismissedLinks = (try? await store.dismissedLinks(ofMeeting: meetingID)) ?? []
    }

    func reloadLinks() async {
        if let id = selectedID { await loadLinks(id) }
        pendingLinkCounts = (try? await store.pendingTaskLinkCounts()) ?? pendingLinkCounts
    }

    /// A link pass wrote the suggestions of this meeting (the model's service tells the window): the open meeting shows them without being
    /// selected again, and Tasks mode counts them.
    func linksChanged(_ meetingID: Int64) async {
        if selectedID == meetingID { await loadLinks(meetingID) }
        pendingLinkCounts = (try? await store.pendingTaskLinkCounts()) ?? pendingLinkCounts
        if mode == .tasks { await loadChains() }
    }

    /// Open tasks that stand for a chain: each chain is one row, the newest open member, with the earlier mentions under it.
    func loadChains() async {
        pendingLinkCounts = (try? await store.pendingTaskLinkCounts()) ?? [:]
        let chains = (try? await store.linkChains(.task)) ?? []
        guard !chains.isEmpty else {
            openChains = [:]
            hiddenChainTasks = []
            return
        }
        let items = Dictionary(uniqueKeysWithValues: ((try? await store.tasks(ids: chains.flatMap { $0.members.map(\.id) })) ?? []).map { ($0.id, $0) })
        var out: [Int64: OpenTaskChain] = [:]
        var hidden = Set<Int64>()
        for chain in chains {
            let members = chain.members.compactMap { m in items[m.id].map { (task: $0, date: m.date) } }
            guard let shown = members.first(where: { $0.task.status == .open }), let first = members.last else { continue }
            let earlier = members.filter { $0.task.id != shown.task.id }
            out[shown.task.id] = OpenTaskChain(task: shown.task, earlier: earlier, since: first.date, meetings: members.count)
            for e in earlier where e.task.status == .open { hidden.insert(e.task.id) }
        }
        openChains = out
        hiddenChainTasks = hidden
    }

    // MARK: Answers

    /// "Same Task", "Same Decision", "Yes, It Changed".
    func confirm(_ row: LinkRow) async {
        guard actingLinks.insert(row.id).inserted else { return }
        defer { actingLinks.remove(row.id) }
        var outcome = LinkConfirmOutcome.stale
        await perform(String(localized: "Couldn’t save the link", comment: "Alert title")) { outcome = try await store.confirmLinkOutcome(row.link.id) }
        await afterLinkChange()
        switch outcome {
        case .confirmed: registerLinkUndo(row, name: LinkLabels.confirmTitle(row))
        case .stale: staleLinkNotice()
        case .withdrawn: break   // two items of one meeting never share a chain: the row goes without a notice
        }
    }

    /// "Not the Same", "Not Related": never suggested again.
    func dismiss(_ row: LinkRow) async {
        guard actingLinks.insert(row.id).inserted else { return }
        defer { actingLinks.remove(row.id) }
        var done = false
        await perform(String(localized: "Couldn’t save the link", comment: "Alert title")) { done = try await store.dismissLink(row.link.id) }
        await afterLinkChange()
        if done { registerLinkUndo(row, name: LinkLabels.dismissTitle(row)) } else { staleLinkNotice() }
    }

    /// "Undo Link" in the row's menu: back to a suggestion.
    func undoLink(_ row: LinkRow) async {
        guard actingLinks.insert(row.id).inserted else { return }
        defer { actingLinks.remove(row.id) }
        var done = false
        await perform(String(localized: "Couldn’t save the link", comment: "Alert title")) { done = try await store.undoLink(row.link.id) }
        await afterLinkChange()
        if !done { staleLinkNotice() }
    }

    /// "Restore" in the Suggestions tab. A pair whose row went with a rewrite of the minutes has no suggestion to come back to: the pass runs
    /// again for the meeting, and it comes back with the next one if the words still match.
    func restore(_ dismissed: DismissedLink) async {
        var restored = true
        await perform(String(localized: "Couldn’t save the link", comment: "Alert title")) { restored = try await store.restoreDismissal(dismissed) }
        if !restored { await llm?.itemsChanged(meetingID: dismissed.srcMeetingID) }
        await afterLinkChange()
    }

    /// The row was answered, replaced or removed while the person was looking at it (a pass or an edit changed it): the list is up to date now,
    /// and nothing the person clicked was lost silently.
    private func staleLinkNotice() {
        alert = MeetingsAlert(title: String(localized: "Couldn’t save the link", comment: "Alert title"),
                              message: String(localized: "The suggestion changed while you were looking at it. The list is up to date now.",
                                              comment: "Alert message: the person answered a link suggestion that a newer pass or an edit had already replaced"))
    }

    private func afterLinkChange() async {
        await reloadLinks()
        await refreshTasks()
    }

    /// Edit › Undo takes the answer back: a confirmed or dismissed link is a suggestion again.
    private func registerLinkUndo(_ row: LinkRow, name: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { _ = Task { await model.undoLink(row) } }
        }
        undoManager.setActionName(name)
    }

    /// "Show": the earlier meeting at the cited passage.
    func showEarlier(_ row: LinkRow) {
        open(meeting: row.earlierMeetingID, segment: row.earlierSegmentID, at: row.earlierT)
    }

    // MARK: Chains

    /// The done circle of a chain row: asks once whether the earlier mentions go too (D14). A task that is not a chain is changed at once.
    func setStatus(chainOf id: Int64, _ status: TaskItem.Status) async {
        guard status != .open, let chain = openChains[id], !chain.earlierOpen.isEmpty else { return await setStatus(id, status) }
        chainDonePrompt = chain
    }

    /// The prompt's answer: the task is done, and the earlier mentions with it when the person left the box ticked. One Edit › Undo puts every
    /// status back.
    func finishChain(_ chain: OpenTaskChain, alsoEarlier: Bool, status: TaskItem.Status = .done) async {
        chainDonePrompt = nil
        var before: [MeetingStore.TaskStatusChange] = []
        await perform(String(localized: "Couldn’t change the task", comment: "Alert title")) {
            before = try await store.setTaskStatuses([chain.task.id] + (alsoEarlier ? chain.earlierOpen.map(\.id) : []), status)
        }
        await refreshTasks()
        guard !before.isEmpty, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                _ = Task {
                    await model.perform(String(localized: "Couldn’t change the task", comment: "Alert title")) { try await model.store.restoreTaskStatuses(before) }
                    await model.refreshTasks()
                }
            }
        }
        undoManager.setActionName(String(localized: "Mark as Done", comment: "Button in the question about marking a chain of tasks done; also the name of the Edit › Undo item that takes it back"))
    }
}
