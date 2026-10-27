// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Open tasks of every meeting (Tasks mode).
struct OpenTasksView: View {
    @Bindable var model: MeetingsModel
    @ViewLocalState private var tableWidth: CGFloat = 650
    @ViewLocalState private var measuredHeight: CGFloat?

    private var editorShown: Bool {
        model.taskSelection.map { id in model.openTasks.contains { $0.id == id } } ?? false
    }

    private func tableHeight(cap: CGFloat) -> CGFloat {
        if let measuredHeight { return min(measuredHeight, cap) }
        let due = TaskDueFormat.width(for: model.sortedOpenTasks, icon: true)
        let owner: CGFloat = model.ownerFilter == nil ? TaskTableSizing.ownerWidth.max : 0
        return TaskTableSizing.height(model.sortedOpenTasks, marksOwner: model.ownerFilter != nil, width: tableWidth, fixed: TaskLeadCell.width + owner + due + (showsStatus ? ActionStatusCell.width : 0), baseRow: 43, extraLine: 16.5, slack: 52, bottom: 18,
                                      extra: CGFloat(model.sortedOpenTasks.filter { model.openChains[$0.id] != nil }.count) * 20, cap: cap)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PaneLayout.item) {
            Text(heading).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            if model.sortedOpenTasks.isEmpty {
                empty
            } else if editorShown {
                // With the editor open the table is as tall as its rows, so the editor sits right under it.
                table
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { tableWidth = $0 }
                    .measuredTableHeight(token: TaskTableSizing.token(model.sortedOpenTasks, width: tableWidth, extra: chainToken)) { measuredHeight = $0 }
                    .frame(height: tableHeight(cap: 400))
            } else {
                // As tall as its rows, and no taller than the pane: a short list ends under its last row and a long
                // one fills the pane and scrolls inside, so no row is ever cut off.
                table
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { tableWidth = $0 }
                    .measuredTableHeight(token: TaskTableSizing.token(model.sortedOpenTasks, width: tableWidth, extra: chainToken)) { measuredHeight = $0 }
                    .frame(maxHeight: tableHeight(cap: .greatestFiniteMagnitude))
            }
            if editorShown { TaskEditor(model: model, width: tableWidth) }
        }
        .sheet(item: $model.chainDonePrompt) { chain in ChainDoneSheet(model: model, chain: chain) }
        .padding(PaneLayout.pane)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: model.openTasks.map(\.id)) { await model.actions.refresh(tasks: model.openTasks, readBack: true) }
    }

    /// Changes when a chain appears or its list of mentions opens (a row's height changes the table's).
    private var chainToken: Int {
        var hasher = Hasher()
        for (id, chain) in model.openChains.sorted(by: { $0.key < $1.key }) { hasher.combine(id); hasher.combine(chain.meetings); hasher.combine(model.expandedChains.contains(id)) }
        for (id, n) in model.pendingLinkCounts.sorted(by: { $0.key < $1.key }) { hasher.combine(id); hasher.combine(n) }
        return hasher.finalize()
    }

    private var showsStatus: Bool { model.sortedOpenTasks.contains { model.actions.state(of: $0).kind != .none } }

    private var table: some View {
        Table(model.sortedOpenTasks, selection: $model.taskSelection, sortOrder: $model.taskSort) {
            TableColumn(Text(verbatim: "")) { t in
                TaskLeadCell(task: t) { status in Task { await model.setStatus(chainOf: t.id, status) } }
                    .firstLineAligned()
            }
            .width(TaskLeadCell.width)
            // The meeting is a link line under the task, so the task keeps the width of the pane.
            TableColumn("Task", value: \.text) { t in
                VStack(alignment: .leading, spacing: 2) {
                    TaskTextCell(task: t, showsOwnerMark: model.ownerFilter != nil)
                    meetingLink(t)
                    // Tasks the person confirmed as the same are one row: the newest open one, with the earlier mentions under it.
                    if let chain = model.openChains[t.id] { OpenChainLine(model: model, chain: chain) }
                }
                .firstLineAligned()
            }
            .width(min: 160, ideal: 320)
            // Filtered by one person, the heading already says whose tasks these are.
            if model.ownerFilter == nil {
                TableColumn("Owner", value: \.ownerSortKey) { t in
                    TaskOwnerCell(task: t, name: t.ownerName.map { name in MeetingStore.displayName(name, isSelf: model.people.first { $0.id == t.ownerID }?.isSelf ?? false) } ?? "—")
                        .firstLineAligned(titleBaselineOffset: true)
                }
                .width(min: TaskTableSizing.ownerWidth.min, ideal: TaskTableSizing.ownerWidth.ideal, max: TaskTableSizing.ownerWidth.max)
            }
            TableColumn("Due", value: \.dueSortKey) { TaskDueCell(task: $0).firstLineAligned(titleBaselineOffset: true) }
                .width(TaskDueFormat.width(for: model.sortedOpenTasks, icon: true))
            if showsStatus {
                TableColumn(Text(verbatim: ActionAppName.reminders)) { t in
                    let state = model.actions.state(of: t)
                    ActionStatusCell(state: state, list: model.actions.containerLabel(state.containerID)).firstLineAligned(titleBaselineOffset: true)
                }
                .width(ActionStatusCell.width)
            }
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: Int64.self) { ids in
            if let id = ids.first, let task = model.sortedOpenTasks.first(where: { $0.id == id }) { TaskActionMenu(actions: model.actions, task: task) }
        }
    }

    /// The meeting the task came from, opening it at the task's moment, and how many suggestions wait under this task.
    @ViewBuilder
    private func meetingLink(_ t: TaskItem) -> some View {
        if let m = t.meetingID {
            HStack(spacing: 6) {
                Button {
                    if let at = t.t { model.open(meeting: m, at: at) } else { model.open(meeting: m) }
                } label: {
                    Label(t.meetingTitle ?? String(localized: "Untitled meeting", comment: "Task list: meeting without a title"),
                          systemImage: "waveform")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(nsColor: .linkColor))
                .pointerStyle(.link)
                // Suggestions are not shown in this list: the link opens the task's meeting, where each one is answered.
                if let pending = model.pendingLinkCounts[t.id], pending > 0 {
                    Text(verbatim: "·").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                    Button {
                        model.open(meeting: m, tab: .tasks)
                    } label: {
                        Text("\(pending) suggestions", comment: "Tasks mode: a link on a task’s row; how many suggestions that this task is the same as an earlier one wait for it")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(nsColor: .linkColor))
                    .pointerStyle(.link)
                    // Out of context the link would not say which meeting it is about.
                    .accessibilityHint(Text(verbatim: t.meetingTitle ?? String(localized: "Untitled meeting", comment: "Task list: meeting without a title")))
                }
            }
        }
    }

    @ViewBuilder
    private var empty: some View {
        if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            // Informational, but the way on is the meetings list, where tasks are proposed and added.
            EmptyStateView(Text("No Open Tasks"), symbol: "checklist",
                           message: String(localized: "Tasks from your meetings appear here until they’re done.")) {
                Button("Show Meetings") { model.mode = .meetings }
            }
        } else {
            SearchEmptyStateView(query: model.query) { model.query = "" }
        }
    }

    private var heading: String {
        guard let owner = model.ownerFilter, let person = model.people.first(where: { $0.id == owner }) else {
            return String(localized: "Open tasks", comment: "Heading of the Tasks mode and section of the People card (a heading inside the window: sentence case)")
        }
        return String(localized: "Open tasks for \(person.displayName)", comment: "Heading of the Tasks mode filtered by person (a heading inside the window: sentence case)")
    }
}

/// "Carried over · 3 meetings since 12 Sep": the mark of a row that stands for a chain, with the list of the earlier mentions.
struct OpenChainLine: View {
    @Bindable var model: MeetingsModel
    let chain: OpenTaskChain

    private var expanded: Binding<Bool> {
        Binding(get: { model.expandedChains.contains(chain.task.id) },
                set: { if $0 { model.expandedChains.insert(chain.task.id) } else { model.expandedChains.remove(chain.task.id) } })
    }

    var body: some View {
        let since = TaskDueFormat.text(chain.since)
        DisclosureGroup(isExpanded: expanded) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(chain.earlier, id: \.task.id) { mention in
                    Button {
                        if let t = mention.task.t, let m = mention.task.meetingID { model.open(meeting: m, at: t) } else if let m = mention.task.meetingID { model.open(meeting: m) }
                    } label: {
                        Text(verbatim: "\(mention.task.meetingTitle ?? String(localized: "Untitled meeting", comment: "Task list: meeting without a title")) · \(TaskDueFormat.text(mention.date))")
                            .font(.caption).lineLimit(1).truncationMode(.tail)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(nsColor: .linkColor))
                    .pointerStyle(.link)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        } label: {
            Label {
                Text("Carried over · \(chain.meetings) meetings since \(since)", comment: "Tasks mode: the mark of a task that the person confirmed is the same as the one from earlier meetings; the arguments are how many meetings mention it and the date of the first")
            } icon: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
    }
}

/// Marking a chain done asks once whether the earlier mentions go too (D14). The box starts ticked.
struct ChainDoneSheet: View {
    @Bindable var model: MeetingsModel
    let chain: OpenTaskChain
    @ViewLocalState private var alsoEarlier = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This task was carried over from earlier meetings", comment: "Headline when the person marks done a task that they confirmed is the same as ones from earlier meetings; the checkbox below asks about the earlier mentions")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            ProtectedText(chain.task.text).foregroundStyle(.secondary).lineLimit(3)
            Toggle(isOn: $alsoEarlier) {
                Text("Also mark the \(chain.earlierOpen.count) earlier mentions as done", comment: "Checkbox in the question about marking a chain of tasks done, on by default; the argument is how many earlier open tasks it would close")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.chainDonePrompt = nil }.keyboardShortcut(.cancelAction)
                Button { Task { await model.finishChain(chain, alsoEarlier: alsoEarlier) } } label: {
                    Text("Mark as Done", comment: "Button in the question about marking a chain of tasks done; also the name of the Edit › Undo item that takes it back")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
