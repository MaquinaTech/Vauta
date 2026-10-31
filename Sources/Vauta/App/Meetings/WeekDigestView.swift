// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Tasks mode: the open tasks, or what a week held.
struct TasksModeView: View {
    @Bindable var model: MeetingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker(String(localized: "Show", comment: "Tasks mode: label of the control that switches between the open tasks and This Week"),
                   selection: $model.tasksPane) {
                ForEach(TasksPane.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding([.top, .horizontal], PaneLayout.pane)
            switch model.tasksPane {
            case .open: OpenTasksView(model: model)
            case .week: WeekDigestView(model: model)
            }
        }
    }
}

/// What a week of the person's calendar held, from the store as it is (`WeekDigest`): its meetings, the decisions taken in
/// them, the tasks added and done in it, what is overdue now and the open questions. Each item opens where it came from.
struct WeekDigestView: View {
    @Bindable var model: MeetingsModel
    @Environment(\.copyProtection) private var copyProtection

    var body: some View {
        VStack(alignment: .leading, spacing: PaneLayout.item) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(model.weekDigest?.title() ?? TasksPane.week.label).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                ControlGroup {
                    Button { model.moveWeek(by: -1) } label: { Image(systemName: "chevron.backward") }
                        .help(String(localized: "Previous Week", comment: "This Week: button that shows the week before"))
                        .accessibilityLabel(Text("Previous Week", comment: "This Week: button that shows the week before"))
                    Button(TasksPane.week.label) { model.showThisWeek() }
                        .disabled(model.showsThisWeek)
                    Button { model.moveWeek(by: 1) } label: { Image(systemName: "chevron.forward") }
                        .disabled(model.showsThisWeek)
                        .help(String(localized: "Next Week", comment: "This Week: button that shows the week after"))
                        .accessibilityLabel(Text("Next Week", comment: "This Week: button that shows the week after"))
                }
                .fixedSize()
                Button("Export…") { Task { await model.exportWeek() } }
                    .disabled(copyProtection || model.weekDigest == nil)
                    .help(copyProtection ? Text("Copy protection is on, so meeting text can’t be exported.", comment: "Tooltip of a disabled Export button")
                                         : Text("Save this week as a Markdown file", comment: "Tooltip of the This Week Export button"))
            }
            if let digest = model.weekDigest {
                if digest.isEmpty {
                    EmptyStateView(Text("Nothing This Week", comment: "This Week: title when the week has no meetings and no tasks"), symbol: "calendar",
                                   message: String(localized: "Nothing was recorded this week.", comment: "This Week: when the week has no meetings and no tasks"))
                } else {
                    ScrollView { sections(digest).frame(maxWidth: 760, alignment: .leading) }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(PaneLayout.pane)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: model.weekShown) { await model.loadWeek() }
    }

    private func sections(_ d: WeekDigest) -> some View {
        VStack(alignment: .leading, spacing: PaneLayout.section) {
            section(String(localized: "Meetings", comment: "Meetings window mode"), count: d.meetings.count) {
                ForEach(d.meetings) { m in
                    Button { model.open(meeting: m.id) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(m.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                                .foregroundStyle(.secondary).monospacedDigit()
                            ProtectedText(m.displayTitle)
                        }
                    }
                    .buttonStyle(.link)
                }
            }
            section(String(localized: "Decisions", comment: "Exported minutes: section title"), count: d.decisions.count) {
                ForEach(d.decisions) { item($0.text, meetingID: $0.meetingID, at: $0.t, digest: d) }
            }
            section(String(localized: "Tasks added", comment: "This Week: section of the tasks added in the week, and its title in the export"), count: d.tasksAdded.count) {
                ForEach(d.tasksAdded) { task($0, digest: d) }
            }
            section(String(localized: "Tasks done", comment: "This Week: section of the tasks marked done in the week, and its title in the export"), count: d.tasksDone.count) {
                ForEach(d.tasksDone) { task($0, digest: d) }
            }
            section(String(localized: "Overdue tasks", comment: "This Week: section of the open tasks whose day has passed, and its title in the export"), count: d.tasksOverdue.count) {
                ForEach(d.tasksOverdue) { task($0, digest: d) }
            }
            section(String(localized: "Open questions", comment: "Exported minutes: section title"), count: d.openQuestions.count) {
                ForEach(Array(d.openQuestions.enumerated()), id: \.offset) { _, q in item(q.text, meetingID: q.meetingID, at: nil, digest: d) }
            }
        }
    }

    /// A heading with its count, and its rows; nothing when it has none.
    @ViewBuilder
    private func section<Rows: View>(_ title: String, count: Int, @ViewBuilder rows: () -> Rows) -> some View {
        if count > 0 {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "\(title) · \(count.formatted())").font(.headline).accessibilityAddTraits(.isHeader)
                rows()
            }
        }
    }

    /// An item's words, and the meeting it came from as a link to the moment.
    private func item(_ text: String, meetingID: Int64?, at t: Double?, digest: WeekDigest) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ProtectedText(text)
            if let meetingID, let title = digest.meetingTitle(meetingID) {
                Button(title) { if let t { model.open(meeting: meetingID, at: t) } else { model.open(meeting: meetingID) } }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
    }

    /// A task with its owner and day under it, and the meeting it came from.
    private func task(_ t: TaskItem, digest: WeekDigest) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: t.status == .done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(t.status == .done ? Color.green : Color.secondary)
                .accessibilityLabel(t.status == .done ? Text("Done", comment: "Task status") : Text("Open", comment: "Task status"))
            VStack(alignment: .leading, spacing: 2) {
                ProtectedText(t.text)
                HStack(spacing: 6) {
                    if let owner = t.ownerName { Text(verbatim: owner) }
                    if let day = t.displayDay(in: .current) { Text(TaskDueFormat.text(day.startOfDay(in: .current))) }
                    if let meetingID = t.meetingID, let title = digest.meetingTitle(meetingID) ?? t.meetingTitle {
                        Button(title) { model.open(meeting: meetingID, tab: .tasks) }.buttonStyle(.link)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }
}
