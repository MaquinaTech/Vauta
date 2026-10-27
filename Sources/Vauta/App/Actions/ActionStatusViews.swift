// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import SwiftUI
import VautaCore

/// The Apple apps by the names macOS gives them.
enum ActionAppName {
    static var reminders: String { String(localized: "Reminders", comment: "The Apple app Reminders, by its name in macOS; also the mark on a task that has a reminder") }
    static var calendar: String { String(localized: "Calendar", comment: "The Apple app Calendar, by its name in macOS; also the Settings pane") }
}

/// A calendar day and a time of day as the date pickers hold them, without a time zone: the day in the picker is the day written.
enum ActionClock {
    static func date(of day: DueDay) -> Date { day.startOfDay(in: .current) }
    static func day(of date: Date) -> DueDay { DueDay.containing(date, in: .current) }

    /// A moment on a fixed day whose wall-clock time is `minute`; only its hour and minute are read back.
    static func date(minute: Int) -> Date {
        var parts = DateComponents(year: 2001, month: 1, day: 2)
        parts.hour = minute / 60
        parts.minute = minute % 60
        return Calendar.current.date(from: parts) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    static func minute(of date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    static func dayText(_ day: DueDay, withYear: Bool = false) -> String { day.formatted(locale: .current, withYear: withYear) }

    /// "Oct 21": a day in a narrow cell.
    /// The day and the month are joined with no-break spaces, so a narrow cell never breaks between them.
    static func shortDayText(_ day: DueDay) -> String {
        date(of: day).formatted(.dateTime.day().month(.abbreviated)).replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    static func timeText(minute: Int) -> String { date(minute: minute).formatted(date: .omitted, time: .shortened) }

    /// "Tue 21 Oct, 10:00" or "Tue 21 Oct" for a day with no time.
    static func whenText(day: DueDay, minute: Int?) -> String {
        minute.map { "\(dayText(day)), \(timeText(minute: $0))" } ?? dayText(day)
    }

    /// The words that say the day, for the notice that asks the person to check it: the clause of the line the day was read from, else
    /// the start of the line. `day` is the day the follow-up has now, so the right clause is picked when a line says two.
    static func datePhrase(in text: String, meeting: ActionsModel.MeetingFacts?, day: DueDay?) -> String {
        if let meeting, let phrase = FollowUpPhrase.phrase(in: text, meetingStart: meeting.start, timeZone: meeting.zone,
                                                           locale: meeting.minutesLocale.identifier, day: day) { return phrase }
        return leadingQuote(text)
    }

    /// The start of a line, cut at a word, for a notice that only names it.
    static func leadingQuote(_ text: String, limit: Int = 40) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > limit else { return clean }
        return FollowUpPhrase.shorten(clean, limit: limit)
    }

    /// The transcript line a follow-up was found in, shortened in the middle at word boundaries (a word is never cut).
    static func shortQuote(_ text: String, limit: Int = 90) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > limit else { return clean }
        var head = String(clean.prefix(limit * 2 / 3)), tail = String(clean.suffix(limit / 3 - 1))
        // Back to the last space of the head and on to the first space of the tail; text written without spaces is cut as it is.
        if let space = head.lastIndex(where: \.isWhitespace) { head = String(head[..<space]) }
        if let space = tail.firstIndex(where: \.isWhitespace) { tail = String(tail[tail.index(after: space)...]) }
        return FollowUpPhrase.withoutTrailingMarks(head) + "… " + tail.trimmingCharacters(in: .whitespaces)
    }
}

/// The trailing cell of a task row: a symbol and words, never colour alone. A task with no reminder shows nothing.
struct ActionStatusCell: View {
    let state: TaskActionState
    /// "Work · iCloud" when Vauta can read the list's name.
    var list: String?
    @Environment(\.backgroundProminence) private var prominence

    static let width: CGFloat = 176

    var body: some View {
        if let spoken = Self.spoken(state, list: list) {
            content.accessibilityLabel(Text(verbatim: spoken))
        } else {
            content
        }
    }

    @ViewBuilder private var content: some View {
        switch state.kind {
        case .none:
            Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
        case .inReminders:
            cell("checklist", Text("Reminders", comment: "Task row: the task is in Reminders"), tint: .secondary)
                .help(list.map { Text($0) } ?? Text("Reminders", comment: "Task row: the task is in Reminders"))
        case .linked:
            cell("link", Text("Reminders", comment: "Task row: the task is in Reminders"), tint: .secondary)
                .help(Text("Linked to a reminder you already had", comment: "Help of the Reminders mark on a task linked to a reminder the person already had"))
        case .missing:
            cell("exclamationmark.circle", Self.missingText, tint: .orange)
        case .doneInReminders:
            cell("checkmark.circle", Self.doneText, tint: .green)
        case .dueDiffers(let reminder, let task):
            let sentence = Self.dueDiffersText(reminder: reminder, task: task)
            cell("calendar.badge.exclamationmark", sentence, tint: .orange)
                .help(sentence)
        }
    }

    private static var missingText: Text { Text("Not in Reminders any more", comment: "Task row: its reminder was deleted or moved in Reminders") }
    private static var doneText: Text { Text("Done in Reminders", comment: "Task row: the reminder was completed in Reminders and the task is still open here") }

    private static func dueDiffersText(reminder: DueDay?, task: DueDay?) -> Text {
        let there = reminder.map(ActionClock.shortDayText) ?? "—", here = task.map(ActionClock.shortDayText) ?? "—"
        return Text("In Reminders, due \(there) (here: \(here))", comment: "Task row: the reminder has another due day than the task; the arguments are two dates")
    }

    /// What VoiceOver says for the state, on the cell and on the Follow-up sheet's checkbox (which is disabled for these states). nil for none.
    static func spoken(_ state: TaskActionState, list: String?) -> String? {
        switch state.kind {
        case .none: nil
        case .inReminders, .linked:
            list.map { String(localized: "In Reminders, list \($0)", comment: "VoiceOver: the task has a reminder; the argument is the list and its account") }
                ?? String(localized: "In Reminders", comment: "VoiceOver: the task has a reminder")
        case .missing: String(localized: "Not in Reminders any more", comment: "Task row: its reminder was deleted or moved in Reminders")
        case .doneInReminders: String(localized: "Done in Reminders", comment: "Task row: the reminder was completed in Reminders and the task is still open here")
        case .dueDiffers(let reminder, let task):
            String(localized: "In Reminders, due \(reminder.map(ActionClock.shortDayText) ?? "—") (here: \(task.map(ActionClock.shortDayText) ?? "—"))",
                   comment: "Task row: the reminder has another due day than the task; the arguments are two dates")
        }
    }

    private func cell(_ symbol: String, _ text: Text, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: symbol)
                .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(tint))
                .accessibilityHidden(true)
            text.font(.callout).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
    }
}

/// The context menu of a task: what is offered depends on where its reminder is. Nothing here writes without the editor
/// or a confirmation.
struct TaskActionMenu: View {
    let actions: ActionsModel
    let task: TaskItem

    var body: some View {
        let state = actions.state(of: task)
        switch state.kind {
        case .none:
            if task.status == .open {
                Button("Add to Reminders…") { Task { await actions.openReminderEditor(task) } }
            }
        case .inReminders, .linked, .dueDiffers:
            openButton(state)
            removal(state)
        case .missing:
            if task.status == .open { Button("Add Again…") { Task { await actions.openReminderEditor(task) } } }
            if !state.isBorrowed { Button("Forget") { Task { await actions.forget(state) } } }
        case .doneInReminders:
            if task.status == .open { Button("Mark Done Here") { Task { await actions.markDoneHere(task) } } }
            openButton(state)
            removal(state)
        }
    }

    private func openButton(_ state: TaskActionState) -> some View {
        Button("Open in Reminders") { actions.openReminders(state.itemID) }
    }

    @ViewBuilder private func removal(_ state: TaskActionState) -> some View {
        if state.canRemove, let id = state.rowID {
            Button("Remove from Reminders…") { Task { await actions.requestRemoval(rowID: id) } }
        } else if state.canUnlink {
            Button("Unlink") { Task { await actions.forget(state) } }
        }
    }
}

/// The bar after an Add: where it went, Open, and Undo for 10 seconds (no time-out while VoiceOver is on). It never takes the focus.
struct ActionUndoBar: View {
    let bar: ActionsModel.UndoBar
    let open: () -> Void
    let undo: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            StatusSymbol.ok.image
            Text(verbatim: bar.text).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if bar.itemID != nil {
                Button(bar.kind == .reminder ? "Open in Reminders" : "Open in Calendar", action: open).controlSize(.small)
            }
            Button("Undo", action: undo).controlSize(.small)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Dismiss")
                .accessibilityLabel(Text("Dismiss"))
        }
        .accessibilityElement(children: .contain)
    }
}

/// "Remove “…” from Work?" for what Vauta created, with Cancel as the default. When the person changed the item there, it says so.
struct RemovalDialog: ViewModifier {
    @Bindable var actions: ActionsModel

    func body(content: Content) -> some View {
        content.confirmationDialog(
            actions.pendingRemoval.map { pending in
                pending.listName.isEmpty
                    ? Text("Remove “\(pending.preview.title)”?", comment: "Confirmation title when the list or calendar cannot be named; the argument is a reminder or event title")
                    : Text("Remove “\(pending.preview.title)” from \(pending.listName)?", comment: "Confirmation title; the arguments are a reminder or event title and its list or calendar")
            } ?? Text(verbatim: ""),
            isPresented: Binding(get: { actions.pendingRemoval != nil }, set: { if !$0 { actions.pendingRemoval = nil } }),
            titleVisibility: .visible, presenting: actions.pendingRemoval) { pending in
            Button("Remove", role: .destructive) { Task { await actions.confirmRemoval() } }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { pending in
            if pending.preview.edited {
                Text(pending.preview.kind == .reminder ? "You changed this reminder in Reminders after Vauta added it." : "You changed this event in Calendar after Vauta added it.")
            } else {
                Text(pending.preview.kind == .reminder ? "Only the reminder Vauta added is removed." : "Only the event Vauta added is removed.")
            }
        }
    }
}

extension View {
    func removalDialog(_ actions: ActionsModel) -> some View { modifier(RemovalDialog(actions: actions)) }
}

/// The Reminders row of the task editor: the keyboard and VoiceOver way to what the context menu offers.
struct TaskRemindersControl: View {
    let actions: ActionsModel
    let task: TaskItem

    var body: some View {
        let state = actions.state(of: task)
        HStack(spacing: 8) {
            if state.kind == .none {
                Button("Add to Reminders…") { Task { await actions.openReminderEditor(task) } }
                    .disabled(task.status != .open)
            } else {
                ActionStatusCell(state: state, list: actions.containerLabel(state.containerID))
                Menu {
                    TaskActionMenu(actions: actions, task: task)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(Text("Reminder actions", comment: "Help of the menu with the actions on a task’s reminder"))
                .accessibilityLabel(Text("Reminder actions", comment: "Accessibility label of the menu with the actions on a task’s reminder"))
            }
        }
    }
}
