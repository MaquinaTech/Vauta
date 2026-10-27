// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Editor of the selected task. Edits are saved automatically (after a pause,
/// with Return, or when another task or meeting is selected), like the
/// Summary of a meeting.
struct TaskEditor: View {
    @Bindable var model: MeetingsModel
    /// The width of the table above (the note's lines are sized for it).
    var width: CGFloat = 650

    var body: some View {
        if model.taskDraft != nil {
            VStack(alignment: .leading, spacing: PaneLayout.item) {
                // The same form style as the Context editor: leading labels, the text field under its label,
                // the short controls at the trailing edge of their row.
                ContextFieldRow("Task") {
                    NoCopyField(title: String(localized: "Task", comment: "Placeholder of the task text field"), text: field(\.text, ""),
                                accessibilityLabel: String(localized: "Task", comment: "Accessibility label")) {
                        Task { await model.saveTask() }
                    }
                }
                ContextFieldRow("Owner", centersLabel: true) {
                    Picker("Owner", selection: field(\.ownerID, nil)) {
                        Text("Unassigned").tag(Int64?.none)
                        ForEach(model.people) { Text($0.displayName).tag(Int64?.some($0.id)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                ContextFieldRow("Due", centersLabel: true) {
                    HStack(spacing: PaneLayout.item) {
                        if model.taskDraft?.hasDue == true {
                            DueDateButton(date: field(\.due, AppClock.now))
                            IconButton(label: String(localized: "Remove Due Date", comment: "Button"), systemImage: "xmark.circle.fill") {
                                field(\.hasDue, false).wrappedValue = false
                            }
                            .foregroundStyle(.secondary)
                        } else {
                            Button("Set a Date") { field(\.hasDue, false).wrappedValue = true }
                        }
                    }
                }
                ContextFieldRow("Status", centersLabel: true) {
                    Picker("Status", selection: field(\.status, .open)) {
                        ForEach(TaskItem.Status.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if let task = model.selectedTask, task.status == .open || model.actions.state(of: task).kind != .none {
                    ContextFieldRow(verbatim: ActionAppName.reminders, centersLabel: true) { TaskRemindersControl(actions: model.actions, task: task) }
                }
                if let task = model.selectedTask, task.unconfirmed || (task.ownerMarked) {
                    // The button sits right under the warnings it clears; the destructive action
                    // stays alone in the footer row below.
                    VerificationNote(task: task, width: width)
                    HStack {
                        Spacer(minLength: 0)
                        Button("Mark as Checked") { Task { await model.markSelectedTaskChecked() } }
                            .help(Text("I checked it: remove the mark", comment: "Help of the Mark as Checked button in the task editor"))
                    }
                    Divider()
                }
                // As the Context editor: the destructive action at the leading edge, the note trailing.
                HStack {
                    Button("Delete Task…", role: .destructive) { model.confirmDeleteSelectedTask() }
                    Spacer()
                    Text("Changes are saved automatically.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .cardBackground()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Selected task"))
        }
    }

    /// `fallback` is only read while no task is selected (the editor is hidden then).
    private func field<Value>(_ keyPath: WritableKeyPath<TaskDraft, Value>, _ fallback: Value) -> Binding<Value> {
        Binding(get: { model.taskDraft.map { $0[keyPath: keyPath] } ?? fallback },
                set: { value in
                    model.taskDraft?[keyPath: keyPath] = value
                    model.taskEdited()
                })
    }
}

/// The due date as text, written like the tables ("Oct 7"), that opens a calendar to change it.
private struct DueDateButton: View {
    @Binding var date: Date
    @ViewLocalState private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Text(TaskDueFormat.text(date))
        }
        .help("Change the due date")
        .accessibilityLabel(Text("Due"))
        .accessibilityValue(Text(date.formatted(date: .long, time: .omitted)))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            DueDatePicker(date: $date)
        }
    }
}

/// The calendar in the due date's popover.
struct DueDatePicker: View {
    @Binding var date: Date

    var body: some View {
        DatePicker("Due", selection: $date, displayedComponents: .date)
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding(12)
    }
}

/// The circle that completes a task in one click (as in Reminders). Dropped
/// tasks are changed in the editor only.
struct TaskDoneButton: View {
    let task: TaskItem
    let toggle: (TaskItem.Status) -> Void

    var body: some View {
        switch task.status {
        case .dropped:
            Image(systemName: "minus.circle")
                .foregroundStyle(.tertiary)
                .help("Dropped")
                .accessibilityLabel(Text("Dropped"))
        case .done:
            Button { toggle(.open) } label: {
                StatusSymbol.ok.image
            }
            .buttonStyle(.plain)
            .help("Mark as not done")
            .accessibilityLabel(Text("Mark “\(task.text)” as Not Done"))
        case .open:
            Button { toggle(.done) } label: {
                Image(systemName: "circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Mark as done")
            .accessibilityLabel(Text("Mark “\(task.text)” as Done"))
        }
    }
}

/// The text cell of a task in both tables: done or dropped tasks struck through, and after the text the badge of a
/// task the model proposed (the leading column is the done circle, so a column means one thing).
struct TaskTextCell: View {
    let task: TaskItem
    /// The list has no Owner column (it is filtered by one person), so the cell carries the mark of an owner nothing
    /// in the cited passage confirms.
    var showsOwnerMark = false

    private var ownerMarked: Bool { showsOwnerMark && task.ownerMarked }

    /// What the badge takes from the text's width.
    static let badgeWidth: CGFloat = 6 + SourceBadge.columnWidth
    /// What the "unconfirmed" glyph takes besides it.
    static let unconfirmedWidth: CGFloat = 20

    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        HStack(spacing: 0) {
            // The badge is part of the text, so on a task that wraps it follows the last word.
            (Text(task.text).strikethrough(task.status != .open) + badge)
                .lineLimit(2)
                .foregroundStyle(task.status == .open ? .primary : .secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help)
        .accessibilityValue(Text(verbatim: [task.unconfirmed ? VerificationText.unconfirmed : nil,
                                            ownerMarked ? VerificationText.ownerHelp : nil].compactMap { $0 }.joined(separator: ". ")))
    }

    /// Every mark in the cell is explained on hover, the model's own badge included.
    private var help: Text {
        var sentences: [String] = []
        if task.source == "llm" { sentences.append(String(localized: "Proposed by the model: review it", comment: "Help of the sparkles badge on a task the model proposed")) }
        if task.unconfirmed { sentences.append(VerificationText.unconfirmedHelp) }
        if ownerMarked { sentences.append(VerificationText.ownerHelp) }
        return Text(verbatim: sentences.joined(separator: " "))
    }

    private var badge: Text {
        // A selected row has a coloured fill: a blue glyph would vanish into it.
        var out = Text(verbatim: "")
        if task.source == "llm" {
            let color: Color = prominence == .increased ? .primary : .blue
            out = out + Text(verbatim: "\u{00A0}") + Text(Image(systemName: "sparkles")).foregroundStyle(color)
        }
        if task.unconfirmed || ownerMarked {
            let color: Color = prominence == .increased ? .primary : .orange
            out = out + Text(verbatim: "\u{00A0}") + Text(Image(systemName: "questionmark.circle")).foregroundStyle(color)
        }
        return out
    }
}

/// The done circle in its own fixed column, so the Task header lines up with the task text.
struct TaskLeadCell: View {
    let task: TaskItem
    let toggle: (TaskItem.Status) -> Void

    static let width: CGFloat = 24

    var body: some View {
        // The glyph's centre sits on the first line's x-height centre, 1.5 pt below the cell's top line.
        TaskDoneButton(task: task, toggle: toggle).frame(width: 18).offset(y: 1.5)
    }
}

/// The height of a task table that is as tall as its rows, counting the rows whose text wraps.
enum TaskTableSizing {
    /// The Owner column of both task tables: one width range, so the same task wraps (or not) alike in each and the
    /// Task column takes the rest.
    static let ownerWidth: (min: CGFloat, ideal: CGFloat, max: CGFloat) = (100, 130, 150)
    /// Changes whenever a row may change height: the tasks' text and marks, and the table's width.
    static func token(_ tasks: [TaskItem], width: CGFloat, extra: Int = 0) -> Int {
        var hasher = Hasher()
        hasher.combine(Int(width))
        hasher.combine(extra)
        for t in tasks { hasher.combine(t.id); hasher.combine(t.text); hasher.combine(t.status); hasher.combine(t.meetingTitle) }
        return hasher.finalize()
    }
    /// The top padding `firstLineAligned()` adds to every cell; rows are this much taller than a plain row.
    static let cellTopPadding: CGFloat = 4
    /// A row of one line in the bordered table: the plain row plus the cells' top padding.
    static let singleLineRow: CGFloat = 25 + cellTopPadding
    /// The header, the table's 1 pt border on both sides and a little room under the last row.
    static let chrome: CGFloat = 32 + 2
    /// - Parameters:
    ///   - width: the width of the table (0 until measured).
    ///   - fixed: the width of every column except Task, at its widest.
    ///   - extraLine: the height the second line of a row adds.
    static func height(_ tasks: [TaskItem], marksOwner: Bool = false, width: CGFloat, fixed: CGFloat, baseRow: CGFloat, extraLine: CGFloat = 16, slack: CGFloat = 72, bottom: CGFloat = 0, extra: CGFloat = 0, cap: CGFloat) -> CGFloat {
        let textWidth = max(80, width - fixed - slack)
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let rows = tasks.reduce(CGFloat(0)) { total, t in
            let room = textWidth - (t.source == "llm" ? TaskTextCell.badgeWidth : 0) - (t.unconfirmed || (marksOwner && t.ownerMarked) ? TaskTextCell.unconfirmedWidth : 0)
            // Wrapping happens at word breaks, earlier than the text's total width suggests: a margin of 6%.
            let wraps = width > 0 && (t.text as NSString).size(withAttributes: [.font: font]).width * 1.06 > room
            return total + baseRow + (wraps ? extraLine : 0)
        }
        return min(chrome + rows + bottom + extra, cap)
    }
}

/// The due date of a task in both tables: overdue in red with an exclamation mark, due today in orange with a clock.
/// Due dates are whole days: only a day before today is overdue.
struct TaskDueCell: View {
    let task: TaskItem
    /// The color of a due date that is neither overdue nor today (the tables use primary text).
    var normal: HierarchicalShapeStyle = .primary

    var body: some View {
        let day = task.displayDay()
        let (overdue, dueToday) = TaskDueFormat.marks(day: day, open: task.status == .open, today: DueDay.containing(AppClock.now, in: .current))
        HStack(spacing: 4) {
            if overdue {
                // An exclamation mark, not the ✕ of the clear-date button: late, not failed or removed.
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    .accessibilityHidden(true)
            } else if dueToday {
                Image(systemName: "clock.fill").foregroundStyle(.orange)
                    .accessibilityHidden(true)
            }
            Text(day.map { TaskDueFormat.text($0) } ?? "—")
                .lineLimit(1)
                .foregroundStyle(overdue ? AnyShapeStyle(Color.red) : dueToday ? AnyShapeStyle(Color.orange) : AnyShapeStyle(normal))
        }
        .help(overdue ? Text("Overdue") : dueToday ? Text("Due today") : Text(verbatim: ""))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(overdue ? Text("Overdue") : dueToday ? Text("Due today") : Text("Due"))
        .accessibilityValue(Text(day.map { ActionClock.dayText($0) } ?? "—"))
    }
}

extension View {
    /// A table cell that starts at the top of its row, so on a task whose text wraps the done circle, owner and
    /// date line up with the first line instead of the middle.
    /// `titleBaselineOffset`: the Owner and Due cells sit on the title's baseline, which the title's badge glyph
    /// lowers by 1 pt (the lead cell has its own offset).
    func firstLineAligned(titleBaselineOffset: Bool = false) -> some View {
        padding(.top, TaskTableSizing.cellTopPadding + (titleBaselineOffset ? 1 : 0)).frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The tasks of one meeting.
struct MeetingTasksTab: View {
    @Bindable var model: MeetingsModel
    let recorder: RecorderModel
    @ViewLocalState private var tableWidth: CGFloat = 650
    @ViewLocalState private var measuredHeight: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: PaneLayout.item) {
            if model.tasks.isEmpty {
                // The empty state fills the pane (no fixedSize: its height is flexible) and holds the field that adds
                // a task, so the two form one centred block.
                empty
            } else {
                table
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { tableWidth = $0 }
                    .measuredTableHeight(token: TaskTableSizing.token(model.sortedTasks, width: tableWidth, extra: model.linkRowsToken)) { measuredHeight = $0 }
                    // The table is as tall as its rows (up to a limit), so the editor is right under the last one.
                    .frame(height: tableHeight)
            }
            // As in Open Tasks, the editor of the selected task comes directly after the table;
            // the field that adds a task closes the page.
            if let id = model.taskSelection, model.tasks.contains(where: { $0.id == id }) {
                TaskEditor(model: model, width: tableWidth)
            }
            if !model.tasks.isEmpty { newTaskField }
        }
        .padding(PaneLayout.pane)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // What Reminders says about the tasks that have a reminder is read when the tab opens, never in the background.
        .task(id: model.selectedID) { await model.actions.refresh(tasks: model.tasks, readBack: true) }
        .onChange(of: TaskTableSizing.token(model.tasks, width: 0)) { Task { await model.actions.refresh(tasks: model.tasks) } }
    }

    /// The column with the reminder's state appears only when a task of the list has one.
    private var showsStatus: Bool { model.sortedTasks.contains { model.actions.state(of: $0).kind != .none } }

    private var newTaskField: some View {
        NoCopyField(title: String(localized: "New task (press Return to add)", comment: "Placeholder"), text: $model.newTask,
                    accessibilityLabel: String(localized: "New task", comment: "Accessibility label")) {
            Task { await model.addTask() }
        }
    }

    private var tableHeight: CGFloat {
        let due = TaskDueFormat.width(for: model.sortedTasks, icon: true)
        if let measuredHeight { return min(measuredHeight, 420) }
        return TaskTableSizing.height(model.sortedTasks, width: tableWidth, fixed: TaskLeadCell.width + TaskTableSizing.ownerWidth.max + due + (showsStatus ? ActionStatusCell.width : 0), baseRow: TaskTableSizing.singleLineRow,
                                      extra: CGFloat(model.linkRows.values.filter { $0.link.kind == .task }.count) * LinkRowHost.estimatedHeight, cap: 420)
    }

    private var table: some View {
        Table(model.sortedTasks, selection: $model.taskSelection, sortOrder: $model.taskSort) {
            TableColumn(Text(verbatim: "")) { t in
                TaskLeadCell(task: t) { status in Task { await model.setStatus(t.id, status) } }
                    .firstLineAligned()
            }
            .width(TaskLeadCell.width)
            TableColumn("Task", value: \.text) { t in
                // A suggestion that this task is the same as one from an earlier meeting sits under it, as a question.
                VStack(alignment: .leading, spacing: 6) {
                    TaskTextCell(task: t)
                    LinkRowHost(model: model, kind: .task, id: t.id)
                }
                .firstLineAligned()
            }
            .width(min: 120, ideal: 200)
            TableColumn("Owner", value: \.ownerSortKey) { TaskOwnerCell(task: $0, name: ownerName($0)).firstLineAligned(titleBaselineOffset: true) }
                .width(min: TaskTableSizing.ownerWidth.min, ideal: TaskTableSizing.ownerWidth.ideal, max: TaskTableSizing.ownerWidth.max)
            TableColumn("Due", value: \.dueSortKey) { TaskDueCell(task: $0).firstLineAligned(titleBaselineOffset: true) }
                .width(TaskDueFormat.width(for: model.sortedTasks, icon: true))
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
            if let id = ids.first, let task = model.tasks.first(where: { $0.id == id }) { TaskActionMenu(actions: model.actions, task: task) }
        }
    }

    /// Whether the empty state offers to write the minutes (it then has a button).
    private var offersWriting: Bool {
        model.cardSource != "llm" && recorder.llmStatus.configured && !model.isActive && !model.transcript.isEmpty
    }

    private var emptyMessage: String {
        model.cardSource == "llm" ? String(localized: "The minutes don’t list any tasks.\nAdd one below.")
                                  : String(localized: "Add one below, or write the minutes to have tasks proposed.")
    }

    private var empty: some View {
        EmptyStateView(Text("No Tasks Yet"), symbol: "checklist", message: emptyMessage) {
            // Rewriting would replace the whole minutes (and the user's edits) just to look for tasks:
            // the button is only offered while the model hasn't written any.
            if offersWriting {
                Button("Write Minutes") { Task { await model.regenerateMinutes() } }
            }
            newTaskField.frame(width: 380)
        }
    }

    private func ownerName(_ t: TaskItem) -> String {
        guard let name = t.ownerName else { return "—" }
        let isSelf = model.people.first { $0.id == t.ownerID }?.isSelf ?? false
        return MeetingStore.displayName(name, isSelf: isSelf)
    }
}

/// How a due date is written in the task tables: day and month, with the year only when it is not this year,
/// and a column width taken from the widest date shown (long languages such as pt-BR need more room).
enum TaskDueFormat {
    static func text(_ date: Date) -> String {
        let style = Date.FormatStyle().day().month(.abbreviated)
        return Calendar.current.isDate(date, equalTo: AppClock.now, toGranularity: .year)
            ? date.formatted(style) : date.formatted(style.year())
    }

    /// A due day as the tables write it. The day is formatted as the day it is: never moved through the zone it was set in.
    static func text(_ day: DueDay, now: Date = AppClock.now, zone: TimeZone = .current, locale: Locale = .current) -> String {
        var style = Date.FormatStyle(locale: locale, timeZone: TimeZone(identifier: "UTC")!).day().month(.abbreviated)
        if day.year != DueDay.containing(now, in: zone).year { style = style.year() }
        return day.utcNoonDate.formatted(style)
    }

    /// Overdue (a day before today) and due today, by calendar day: the day a task says, compared with today's date where the person is.
    static func marks(day: DueDay?, open: Bool, today: DueDay) -> (overdue: Bool, today: Bool) {
        guard open, let day else { return (false, false) }
        return (day < today, day == today)
    }

    /// Fixed width of the Due column: the widest date (or the dash), the status icon when there is one, and the cell padding.
    static func width(for tasks: [TaskItem], icon: Bool) -> CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .body)
        let widest = (tasks.compactMap { $0.displayDay() }.map { text($0) } + ["—"])
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        // The header's title in its bold font plus the sort indicator must fit too (long words such as "Fecha límite").
        let header = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize(for: .small))
        let title = (String(localized: "Due", comment: "Column header of the due date of a task") as NSString).size(withAttributes: [.font: header]).width
        return max(ceil(widest) + (icon ? 20 : 0), ceil(title) + 22) + 14
    }
}
