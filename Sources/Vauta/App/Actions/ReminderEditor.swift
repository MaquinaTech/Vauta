// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import SwiftUI
import VautaCore

/// "Add to Reminders…": the exact fields that will be written, and where. It is a sheet (a popover would close when the macOS
/// permission prompt takes the focus), and its draft lives in `ActionsModel`, so it survives the prompt. Nothing is written until Add.
struct ReminderEditor: View {
    @Bindable var actions: ActionsModel
    let state: ReminderEditorState
    let showInTranscript: (TaskItem) -> Void
    let openSystemSettings: () -> Void

    static let width: CGFloat = 500

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(Text("Add to Reminders", comment: "Title of the sheet that adds a task to Reminders"), symbol: "checklist")
            // The warning comes first: Return in the title field must not add a task whose warning was never seen.
            if state.warnsUnconfirmed { unconfirmed }
            access
            if state.access == .full { fields }
            if actions.copyProtected && state.access == .full { copyProtection }
            finding
            if state.failed {
                NoticeLabel(Text("Vauta couldn’t add the reminder. Nothing was added.", comment: "Reminder editor: the save failed"), status: .error)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { actions.cancelEditor() }.keyboardShortcut(.cancelAction)
                Button("Add to Reminders") { Task { await actions.addReminder() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!state.canAdd)
            }
        }
        .padding(20)
        .frame(width: Self.width)
    }

    // MARK: Permission

    @ViewBuilder private var access: some View {
        switch state.access {
        case .notDetermined, .writeOnly:
            HStack(alignment: .firstTextBaseline) {
                NoticeLabel(Text("Vauta needs access to Reminders to add this task.", comment: "Reminder editor: before access to Reminders was asked"), status: .info)
                Spacer(minLength: 8)
                Button("Allow Access…") { Task { await actions.allowReminderAccess() } }
                    .disabled(state.requestingAccess)
            }
            taskPreview
        case .denied, .restricted:
            HStack(alignment: .firstTextBaseline) {
                NoticeLabel(Text("Reminders access is turned off for Vauta in System Settings.", comment: "Settings → Calendar & Reminders"), status: .warning)
                Spacer(minLength: 8)
                Button("Open System Settings", action: openSystemSettings)
            }
            taskPreview
        case .full:
            if state.containers.isEmpty {
                NoticeLabel(Text("You have no list Vauta can add to.", comment: "Reminder editor: no writable reminder list"), status: .warning)
            }
        }
    }

    /// Without access the draft is still shown, so the person sees what they are about to allow.
    private var taskPreview: some View {
        Text(verbatim: state.draft.title)
            .lineLimit(3)
            .truncationMode(.middle)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Fields

    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            ContextFieldRow("Title") {
                NoCopyField(title: String(localized: "Title", comment: "Placeholder of the reminder title field"),
                            text: Binding(get: { state.draft.title }, set: { actions.reminderEditor?.draft.title = $0 }),
                            accessibilityLabel: String(localized: "Title", comment: "Accessibility label of the reminder title field"),
                            takesInitialFocus: true) { if state.canAdd { Task { await actions.addReminder() } } }
            }
            ContextFieldRow("List", centersLabel: true) {
                Picker("List", selection: Binding(get: { state.draft.containerID }, set: { id in Task { await actions.setReminderList(id) } })) {
                    if !state.hasList { Text(verbatim: "—").tag(state.draft.containerID) }
                    ForEach(state.containers) { Text(verbatim: ActionsModel.label($0)).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(state.containers.isEmpty)
            }
            if let name = state.unavailableList {
                NoticeLabel(Text("Your list “\(name)” is not available.", comment: "Reminder editor: the default list chosen in Settings is gone; the argument is its name"), status: .info, secondary: true)
            }
            Text("Reminders may sync this list to iCloud or another account.", comment: "Reminder editor: footnote under the list")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ContextFieldRow("Due", centersLabel: true) { due }
            if let skipped = state.draft.skippedDueDay, state.draft.dueDay == nil {
                NoticeLabel(Text("The task’s due date (\(ActionClock.dayText(skipped, withYear: true))) looks wrong, so it was left out.", comment: "Reminder editor: the task's stored due date is before the meeting or more than a year after it; the argument is that date"), status: .info, secondary: true)
            }
            if state.draft.dueDay != nil {
                ContextFieldRow("Alert", centersLabel: true) { alert }
            }
            ContextFieldRow(verbatim: String(localized: "event.field.notes", defaultValue: "Notes",
                                              comment: "Label of the notes field of a reminder or an event in the editor; Apple’s Reminders and Calendar name this field (zh-Hans 备注), unlike the Notes tab of a meeting")) { notes }
        }
    }

    private var due: some View {
        HStack(spacing: 8) {
            if let day = state.draft.dueDay {
                DatePicker("Due", selection: Binding(get: { ActionClock.date(of: day) }, set: { actions.setReminderDue(ActionClock.day(of: $0)) }),
                           displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.field)
                if state.draft.alertMinuteOfDay == nil {
                    Text("No time", comment: "Reminder editor: the reminder has a due day but no time of day").foregroundStyle(.secondary)
                }
                IconButton(label: String(localized: "Remove Due Date", comment: "Button"), systemImage: "xmark.circle.fill") { actions.setReminderDue(nil) }
                    .foregroundStyle(.secondary)
            } else {
                Text("No date", comment: "Reminder editor: the reminder has no due day").foregroundStyle(.secondary)
                Button("Set a Date") { actions.setReminderDue(ActionClock.day(of: AppClock.now)) }
            }
        }
    }

    private var alert: some View {
        HStack(spacing: 8) {
            Toggle("Alert", isOn: Binding(get: { state.draft.alertMinuteOfDay != nil }, set: { actions.setReminderAlert($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text("Alert"))
            if state.draft.alertMinuteOfDay != nil {
                DatePicker("Alert", selection: Binding(get: { ActionClock.date(minute: state.alertMinute) },
                                                       set: { actions.setReminderAlertMinute(ActionClock.minute(of: $0)) }),
                           displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.field)
            } else {
                Text("Off", comment: "Reminder editor: no alert").foregroundStyle(.secondary)
            }
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: state.draft.notes ?? "—")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if state.meeting != nil {
                Toggle("Include the meeting’s name", isOn: Binding(get: { state.includeMeetingName }, set: { actions.setIncludeMeetingName($0) }))
                    .toggleStyle(.checkbox)
            }
        }
    }

    // MARK: Warnings and findings

    private var unconfirmed: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.task.unconfirmed {
                NoticeLabel(Text("Vauta could not confirm this task in the transcript. Check it before adding.", comment: "Reminder editor: the task is unconfirmed (an uncertain owner alone gets the owner note instead)"), status: .warning)
            } else {
                // Only the owner is in doubt: the task itself was confirmed.
                NoticeLabel(Text(VerificationText.ownerHelp), status: .warning)
            }
            if state.task.meetingID != nil {
                Button("Show in Transcript") { showInTranscript(state.task) }.controlSize(.small)
            }
        }
    }

    private var copyProtection: some View {
        NoticeLabel(Text("Copy protection is on. This text will leave Vauta for \(ActionAppName.reminders).", comment: "Editor, with copy protection on: the text goes to another app; the argument is the app's name, Reminders or Calendar"), status: .info, secondary: true)
    }

    @ViewBuilder private var finding: some View {
        let list = actions.containerLabel(state.draft.containerID) ?? state.containers.first { $0.id == state.draft.containerID }.map(ActionsModel.label) ?? ""
        switch state.finding {
        case .none:
            EmptyView()
        case .alreadyAdded(let row):
            HStack(alignment: .firstTextBaseline) {
                NoticeLabel(Text("This task is already in Reminders.", comment: "Reminder editor: the task has a reminder from Vauta"), status: .info)
                Spacer(minLength: 8)
                Button("Open in Reminders") { actions.openReminders(row.itemID) }.disabled(row.itemID == nil)
            }
        case .orphan(let row):
            DuplicateBanner(title: Text("You added this to Reminders on \(row.writtenAt.formatted(date: .abbreviated, time: .omitted))", comment: "Reminder editor: the task was deleted here, its reminder is still there; the argument is a date"),
                            useTitle: "Use This Reminder", use: { Task { await actions.useExistingReminder() } },
                            addAnyway: { Task { await actions.addReminder(acceptingDuplicate: true) } })
        case .existing(let item):
            DuplicateBanner(title: Text("You already have “\(item.title)” in \(list)", comment: "Reminder editor: an equal reminder is in the list; the arguments are its title and the list"),
                            useTitle: "Use This One", use: { Task { await actions.useExistingReminder() } },
                            addAnyway: { Task { await actions.addReminder(acceptingDuplicate: true) } })
        case .chainReminder(let row):
            DuplicateBanner(title: Text("Already in Reminders (added \(row.writtenAt.formatted(date: .abbreviated, time: .omitted)))", comment: "Reminder editor: the task was confirmed as the same as an earlier one, which already has a reminder; the argument is the date it was added"),
                            useTitle: "Use This Reminder", use: { Task { await actions.useExistingReminder() } },
                            addAnyway: { Task { await actions.addReminder(acceptingDuplicate: true) } })
        case .existingEvent:
            EmptyView()
        }
    }
}

/// A reminder like this one is already there: use it, or add anyway. Nothing is written until the person chooses.
struct DuplicateBanner: View {
    let title: Text
    let useTitle: LocalizedStringKey
    let use: () -> Void
    let addAnyway: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NoticeLabel(title, status: .info)
            HStack {
                Button(useTitle, action: use).controlSize(.small)
                Button("Add Anyway", action: addAnyway).controlSize(.small)
            }
            .padding(.leading, 28)   // the notice's icon column (20) and its gap (8): under the text
        }
    }
}
