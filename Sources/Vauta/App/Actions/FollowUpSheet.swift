// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import SwiftUI
import VautaCore

/// What the one sheet of the Meetings window shows: the Follow-up sheet, or an editor in its place.
struct ActionsSheetHost: View {
    @Bindable var actions: ActionsModel
    let showInTranscript: (TaskItem) -> Void

    var body: some View {
        content.background(SheetHardening())
    }

    @ViewBuilder private var content: some View {
        switch actions.page {
        case .followUp?:
            if let state = actions.sheet { FollowUpSheet(actions: actions, state: state) }
        case .reminder?:
            if let state = actions.reminderEditor {
                ReminderEditor(actions: actions, state: state, showInTranscript: showInTranscript, openSystemSettings: { Permissions.open(.reminders) })
            }
        case .event?:
            if let state = actions.eventEditor { EventEditor(actions: actions, state: state) }
        case nil:
            EmptyView()
        }
    }
}

extension ActionsModel {
    /// The owner as the sheet shows it: "Me" for the person's own tasks, nil for a task nobody owns.
    func ownerLabel(_ task: TaskItem) -> String? {
        guard let name = task.ownerName else { return nil }
        let isSelf = host?.people.first { $0.id == task.ownerID }?.isSelf ?? false
        return MeetingStore.displayName(name, isSelf: isSelf)
    }
}

/// "Follow Up…" (⇧⌘U): reminders from the open tasks, calendar events from the follow-up meetings, and the email draft. Nothing is
/// ticked, nothing is added until a button says Add, and nothing is sent.
struct FollowUpSheet: View {
    @Bindable var actions: ActionsModel
    let state: FollowUpSheetState
    /// The tallest the sheet grows before its content scrolls.
    var maxHeight: CGFloat = 700

    static let width: CGFloat = 640

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding([.horizontal, .top], 20).padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    remindersSection
                    calendarSection
                    if actions.emailDraftAvailable { EmailDraftView(actions: actions, state: state.email, locked: actions.copyProtected) }
                }
                .padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
            // The sheet is modal: the window's bar behind it cannot be clicked, so the bar after an Add is shown here while it is open.
            if let bar = actions.undoBar {
                Divider()
                ActionUndoBar(bar: bar, open: { actions.openAddedItem(bar) }, undo: { Task { await actions.undo(bar) } },
                              dismiss: { actions.dismissUndoBar() })
                    .frame(height: MeetingsBottomBar.height)
                    .padding(.horizontal, 20)
                    .background(.bar)
            }
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: Self.width)
        .frame(maxHeight: maxHeight)
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(alignment: .top) {
            SheetHeader(Text("Follow Up", comment: "Title of the sheet with reminders, calendar events and the email draft of a meeting"),
                        message: Text(verbatim: state.meeting.title), symbol: "checklist.checked")
            if let next = state.others.first {
                Button("Next Meeting") { Task { await actions.openFollowUp(meetingID: next, others: Array(state.others.dropFirst())) } }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Vauta adds nothing until you press Add. Nothing is sent.", comment: "Follow-up sheet footer")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("Close") { actions.closeSheet() }.keyboardShortcut(.cancelAction)
        }
    }

    // MARK: Reminders

    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: ActionAppName.reminders).font(.headline).accessibilityAddTraits(.isHeader)
            switch actions.reminderAccess {
            case .notDetermined, .writeOnly:
                if !state.tasks.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        NoticeLabel(Text("Vauta needs access to Reminders to add these tasks.", comment: "Follow-up sheet: before access to Reminders was asked; shown above the list of tasks"), status: .info)
                        Spacer(minLength: 8)
                        Button("Allow Access…") { Task { await actions.allowReminderAccess() } }
                    }
                }
            case .denied, .restricted:
                HStack(alignment: .firstTextBaseline) {
                    NoticeLabel(Text("Reminders access is turned off for Vauta in System Settings.", comment: "Settings → Calendar & Reminders"), status: .warning)
                    Spacer(minLength: 8)
                    Button("Open System Settings") { Permissions.open(.reminders) }
                }
            case .full:
                EmptyView()
            }
            if state.tasks.isEmpty {
                Text("No open tasks in this meeting.", comment: "Follow-up sheet: nothing to add to Reminders").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(state.tasks.enumerated()), id: \.element.id) { index, task in
                        if index > 0 { Divider() }
                        TaskOfferRow(actions: actions, task: task, ticked: state.ticked.contains(task.id), note: state.notes[task.id],
                                     list: state.containers.first { $0.id == state.containerID }.map(ActionsModel.label) ?? "")
                    }
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                batchFooter
            }
        }
    }

    private var batchFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            batchControls
            // Copy protection allows the write, with the same one-line warning as the editor.
            if ActionCopyPolicy.writeWarns(copyProtection: actions.copyProtected), actions.reminderAccess == .full {
                NoticeLabel(Text("Copy protection is on. This text will leave Vauta for \(ActionAppName.reminders).", comment: "Editor, with copy protection on: the text goes to another app; the argument is the app's name, Reminders or Calendar"), status: .info, secondary: true)
            }
        }
    }

    private var batchControls: some View {
        HStack(spacing: 12) {
            if actions.reminderAccess == .full, !state.containers.isEmpty {
                Picker("List", selection: Binding(get: { state.containerID ?? "" }, set: { actions.setBatchList($0) })) {
                    ForEach(state.containers) { Text(verbatim: ActionsModel.label($0)).tag($0.id) }
                }
                .fixedSize()
            } else if actions.reminderAccess == .full {
                NoticeLabel(Text("You have no list Vauta can add to.", comment: "Reminder editor: no writable reminder list"), status: .warning)
            }
            if let name = state.unavailableList {
                NoticeLabel(Text("Your list “\(name)” is not available.", comment: "Reminder editor: the default list chosen in Settings is gone; the argument is its name"), status: .info, secondary: true)
            }
            Spacer(minLength: 8)
            let count = state.addableTicked.count
            let listTitle = state.containers.first { $0.id == state.containerID }?.title ?? ""
            Button {
                Task { await actions.addTicked() }
            } label: {
                if count == 0 { Text("Add to Reminders") } else { Text("Add \(count) to Reminders · \(listTitle)", comment: "Follow-up sheet button; the arguments are how many tasks are ticked and the list's name") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(count == 0 || state.busy || actions.reminderAccess != .full || state.containerID == nil)
        }
    }

    // MARK: Calendar

    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: ActionAppName.calendar).font(.headline).accessibilityAddTraits(.isHeader)
            let list = state.visibleFollowUps
            if list.isEmpty {
                if actions.followUpDetectionAvailable, !state.followUps.isEmpty {
                    // The search found meetings and the person dismissed every one: it must not say it found none.
                    Text("You marked every suggested follow-up as not a meeting. Add one by hand if one was agreed.", comment: "Follow-up sheet: every suggested follow-up meeting was dismissed with the Not a Meeting button")
                        .foregroundStyle(.secondary)
                    if state.followUps.count >= FollowUpDetector.maximumPerMeeting {
                        Text("Vauta suggests at most two follow-up meetings. Add any others by hand.", comment: "Follow-up sheet, under the suggested follow-up meetings: the search offers two at most").font(.caption).foregroundStyle(.secondary)
                    }
                } else if actions.followUpDetectionAvailable {
                    // The rules found nothing; that is not a statement about what the meeting said (they miss many mentions).
                    Text("Vauta found no follow-up meeting in the transcript. Add one by hand if one was agreed.", comment: "Follow-up sheet: the automatic search found no follow-up meeting; it must not claim none was mentioned").foregroundStyle(.secondary)
                } else {
                    // Vauta did not look: it must not say that nothing was mentioned.
                    Text("Add the next meeting by hand.", comment: "Follow-up sheet, Calendar section, while Vauta does not look for follow-up meetings in the transcript").foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, follow in
                        if index > 0 { Divider() }
                        FollowUpRow(actions: actions, follow: follow, quote: state.quotes[follow.id], row: state.events[follow.id], existing: state.existing[follow.id])
                    }
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                // Every suggestion counts, dismissed ones too: the cap may still have cut other mentions. The text says "two"; a test ties it to the constant.
                if actions.followUpDetectionAvailable, state.followUps.count >= FollowUpDetector.maximumPerMeeting {
                    Text("Vauta suggests at most two follow-up meetings. Add any others by hand.", comment: "Follow-up sheet, under the suggested follow-up meetings: the search offers two at most").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("New Event…") { Task { await actions.openEventEditor(nil) } }
                Spacer()
            }
        }
    }
}

/// One open task: an unticked box (the tick is the confirmation), the task, its owner and due day, and where it is.
private struct TaskOfferRow: View {
    @Bindable var actions: ActionsModel
    let task: TaskItem
    let ticked: Bool
    let note: BatchNote?
    let list: String

    var body: some View {
        let status = actions.state(of: task)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Toggle(isOn: Binding(get: { ticked }, set: { _ in actions.toggleTick(task) })) {
                    EmptyView()
                }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(status.kind != .none && status.kind != .missing)
                .accessibilityLabel(Text(verbatim: task.text))
                .accessibilityValue(spoken(status))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(verbatim: task.text).lineLimit(3).help(task.text)
                        if task.unconfirmed || task.ownerMarked {
                            // One glyph per task: its help and VoiceOver text name the task, the owner, or both, as in the task table.
                            let owner = task.ownerMarked ? VerificationText.ownerSpoken(actions.ownerLabel(task) ?? "") : nil
                            Image(systemName: "questionmark.circle").foregroundStyle(.orange)
                                .help([task.unconfirmed ? VerificationText.unconfirmedHelp : nil, task.ownerMarked ? VerificationText.ownerHelp : nil]
                                    .compactMap { $0 }.joined(separator: " "))
                                .accessibilityLabel(Text(verbatim: [task.unconfirmed ? VerificationText.unconfirmed : nil, owner].compactMap { $0 }.joined(separator: ". ")))
                        }
                    }
                    detail
                }
                Spacer(minLength: 8)
                if status.kind != .none {
                    ActionStatusCell(state: status, list: actions.containerLabel(status.containerID))
                        .frame(maxWidth: ActionStatusCell.width, alignment: .leading)
                } else if ticked {
                    Button("Edit…") { Task { await actions.openReminderEditor(task, fromFollowUp: true) } }.controlSize(.small)
                }
            }
            if let note { noteView(note) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private var detail: some View {
        HStack(spacing: 8) {
            Text(verbatim: actions.ownerLabel(task) ?? "—")
            if task.dueDay != nil {
                if let day = offeredDay.use {
                    Text(verbatim: ActionClock.shortDayText(day))
                } else if offeredDay.skipped != nil {
                    // The reminder is written without it, as the editor says: the row must not promise a day it will not write.
                    Text("Due date left out: it looks wrong", comment: "Follow-up sheet, task row: the task's stored due date is before the meeting or more than a year after it, so the reminder gets none")
                        .foregroundStyle(.orange)
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// The due day the batch will write for this task.
    private var offeredDay: (use: DueDay?, skipped: DueDay?) {
        let meeting = actions.sheet?.meeting
        return ReminderDraft.dueDay(of: task, meetingDate: meeting?.start, meetingTimeZone: meeting?.zone ?? .current)
    }

    /// The checkbox's value: owner, due day, and why it is disabled when the task is already in Reminders (or linked, or done there).
    private func spoken(_ status: TaskActionState) -> Text {
        let owner = actions.ownerLabel(task).map { String(localized: "Owner \($0)", comment: "VoiceOver, Follow-up sheet: the owner of the task; the argument is a name") }
        let due = offeredDay.use.map { String(localized: "Due \(ActionClock.dayText($0))", comment: "VoiceOver, Follow-up sheet: the task's due day; the argument is a date") }
            ?? (offeredDay.skipped != nil ? String(localized: "Due date left out: it looks wrong", comment: "Follow-up sheet, task row: the task's stored due date is before the meeting or more than a year after it, so the reminder gets none") : nil)
        let state = ActionStatusCell.spoken(status, list: actions.containerLabel(status.containerID))
        return Text(verbatim: [owner, due, state].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". "))
    }

    @ViewBuilder private func noteView(_ note: BatchNote) -> some View {
        switch note {
        case .failed:
            NoticeLabel(Text("Vauta couldn’t add the reminder. Nothing was added.", comment: "Reminder editor: the save failed"), status: .error)
        case .duplicate(.existing(let item)):
            DuplicateBanner(title: Text("You already have “\(item.title)” in \(list)", comment: "Reminder editor: an equal reminder is in the list; the arguments are its title and the list"),
                            useTitle: "Use This One", use: { Task { await actions.resolveBatch(task, useExisting: true) } },
                            addAnyway: { Task { await actions.resolveBatch(task, useExisting: false) } })
        case .duplicate(.orphan(let row)):
            DuplicateBanner(title: Text("You added this to Reminders on \(row.writtenAt.formatted(date: .abbreviated, time: .omitted))", comment: "Reminder editor: the task was deleted here, its reminder is still there; the argument is a date"),
                            useTitle: "Use This Reminder", use: { Task { await actions.resolveBatch(task, useExisting: true) } },
                            addAnyway: { Task { await actions.resolveBatch(task, useExisting: false) } })
        case .duplicate(.chainReminder(let row)):
            DuplicateBanner(title: Text("Already in Reminders (added \(row.writtenAt.formatted(date: .abbreviated, time: .omitted)))", comment: "Reminder editor: the task was confirmed as the same as an earlier one, which already has a reminder; the argument is the date it was added"),
                            useTitle: "Use This Reminder", use: { Task { await actions.resolveBatch(task, useExisting: true) } },
                            addAnyway: { Task { await actions.resolveBatch(task, useExisting: false) } })
        case .duplicate:
            EmptyView()
        }
    }
}

/// One follow-up meeting: when, where it was said, and what can be done with it.
private struct FollowUpRow: View {
    @Bindable var actions: ActionsModel
    let follow: FollowUp
    let quote: String?
    let row: CreatedAction?
    let existing: ActionItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Next meeting: \(whenText)", comment: "Follow-up sheet: the day and time of the follow-up meeting").fontWeight(.medium)
                    sourceLine
                }
                Spacer(minLength: 8)
                trailing
            }
            if follow.dayInferred, row == nil {
                NoticeLabel(Text("Day inferred from “\(ActionClock.datePhrase(in: quote ?? "", meeting: actions.sheet?.meeting, day: follow.day))”: check it", comment: "Event editor: the day came from a phrase such as next Tuesday, not from a date; the argument is the phrase"), status: .warning, secondary: true)
            }
            if follow.minuteOfDay == nil, row == nil {
                Text("Time not said", comment: "Event editor: the meeting did not say what time the follow-up is").font(.callout).foregroundStyle(.secondary)
                    .padding(.leading, 28)   // under the notice's text: its icon column (20) and the gap (8)
            }
            if let existing, row == nil {
                HStack(alignment: .firstTextBaseline) {
                    NoticeLabel(Text("Already in your calendar: \(ActionClock.whenText(day: existing.day ?? follow.day ?? .init(year: 2000, month: 1, day: 1)!, minute: existing.minuteOfDay ?? follow.minuteOfDay))", comment: "Event editor: an event like this one is in the calendar; the argument is its day and, when known, its time"), status: .info)
                    Spacer(minLength: 8)
                    Button("Open in Calendar") { actions.openCalendar(existing.itemID) }.controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private var whenText: String {
        guard let day = follow.day else { return "—" }
        return ActionClock.whenText(day: day, minute: follow.minuteOfDay)
    }

    @ViewBuilder private var sourceLine: some View {
        if let quote {
            HStack(spacing: 6) {
                if let t = follow.t { Text(verbatim: ElapsedTime.stamp(t)).monospacedDigit() }
                Text("“\(ActionClock.shortQuote(quote))”", comment: "Words heard in the meeting between quotation marks (a question, or the line that names the next meeting); the argument is the quote. Use the quotation marks of the language").lineLimit(2).truncationMode(.middle)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var trailing: some View {
        if let row {
            VStack(alignment: .trailing, spacing: 4) {
                if row.target == .ics {
                    Label { Text("Sent to Calendar", comment: "Notice after an event file was handed to Calendar, which asks where to add it") } icon: { StatusSymbol.ok.image }
                    Button("Forget") { Task { await actions.forgetEvent(follow) } }.controlSize(.small)
                } else {
                    Label {
                        if let name = actions.containerLabel(row.containerID) {
                            Text("Added to Calendar · \(name)", comment: "Bar after adding a calendar event; the argument is the calendar and its account, such as Work · iCloud")
                        } else {
                            Text("Added to Calendar", comment: "Follow-up sheet: the event was added, and the calendar's name cannot be read")
                        }
                    } icon: { StatusSymbol.ok.image }
                    HStack {
                        Button("Open in Calendar") { actions.openCalendar(row.itemID) }.controlSize(.small)
                        Button("Remove from Calendar…") { Task { await actions.requestEventRemoval(follow) } }.controlSize(.small)
                    }
                }
            }
            .font(.callout)
        } else if existing == nil {
            HStack {
                Button("Edit and Add…") { Task { await actions.openEventEditor(follow) } }.controlSize(.small)
                Button("Not a Meeting") { Task { await actions.dismissFollowUp(follow) } }.controlSize(.small)
            }
        } else {
            Button("Not a Meeting") { Task { await actions.dismissFollowUp(follow) } }.controlSize(.small)
        }
    }
}
