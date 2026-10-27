// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import SwiftUI
import VautaCore

/// The "After meetings" group of Settings › Calendar & Reminders. There is no switch for adding reminders: pressing Add, and answering
/// the macOS prompt, is the consent.
struct AfterMeetingsSection: View {
    @Bindable var model: AfterMeetingsSettings
    @Bindable var preferences: ActionsPreferences

    var body: some View {
        Section {
            listPicker
            calendarPicker
            Toggle(isOn: alertOn) {
                Text("Alert on the due day", comment: "Settings → Calendar & Reminders: the switch that gives a reminder an alert on its due day; the time is the row below")
                Text(description: String(localized: "A reminder with a due day also alerts at this time, wherever you are.",
                     comment: "Settings → Calendar & Reminders: what the alert on the due day does"))
            }
            if let minute = preferences.alertMinute {
                DatePicker(selection: Binding(get: { ActionClock.date(minute: minute) }, set: { preferences.alertMinute = ActionClock.minute(of: $0) }),
                           displayedComponents: .hourAndMinute) {
                    Text("Time of the alert", comment: "Settings → Calendar & Reminders: the time of day of the alert")
                }
            }
            Toggle(isOn: $preferences.includeMeetingName) {
                Text("Include the meeting’s name in notes", comment: "Settings → Calendar & Reminders: the notes of a reminder name the meeting it came from")
            }
        } header: {
            Text("After meetings", comment: "Settings → Calendar & Reminders: header of the group about adding tasks to Reminders and follow-up meetings to Calendar")
        } footer: {
            SettingsNote(String(localized: "Vauta adds a reminder or an event only when you press Add, and only what you confirmed. To avoid duplicates it reads, in memory, the titles in the list it adds to. It never changes or deletes anything it did not add.",
                                comment: "Settings → Calendar & Reminders: what Vauta writes and reads after a meeting"))
        }
    }

    private var alertOn: Binding<Bool> {
        Binding(get: { preferences.alertMinute != nil }, set: { preferences.alertMinute = $0 ? ReminderDraft.defaultAlertMinute : nil })
    }

    @ViewBuilder private var listPicker: some View {
        switch model.reminderAccess {
        case .full:
            Picker(selection: Binding(get: { preferences.reminderListID ?? "" }, set: { model.chooseList($0.isEmpty ? nil : $0, in: preferences) })) {
                Text("Last used, else Reminders’ default", comment: "Settings → Calendar & Reminders: no list is fixed; a reminder starts in the list used last, and in the one Reminders chooses until then").tag("")
                ForEach(model.reminderLists) { Text(verbatim: ActionsModel.label($0)).tag($0.id) }
                if let id = preferences.reminderListID, !model.reminderLists.contains(where: { $0.id == id }) {
                    Text(verbatim: preferences.reminderListName ?? "—").tag(id)
                }
            } label: {
                Text("Default list", comment: "Settings → Calendar & Reminders: the list a new reminder starts in")
            }
        case .denied, .restricted:
            HStack {
                NoticeLabel(Text("Reminders access is turned off for Vauta in System Settings.", comment: "Settings → Calendar & Reminders"), status: .warning)
                Spacer()
                Button("Open System Settings") { Permissions.open(.reminders) }
            }
        case .notDetermined, .writeOnly:
            LabeledContent {
                Text("Chosen at the first Add", comment: "Settings → Calendar & Reminders: the default list can be chosen once Vauta has access to Reminders, which it asks for when you first add a task").foregroundStyle(.secondary)
            } label: {
                Text("Default list", comment: "Settings → Calendar & Reminders: the list a new reminder starts in")
            }
        }
    }

    @ViewBuilder private var calendarPicker: some View {
        if model.eventAccess == .full {
            Picker(selection: Binding(get: { preferences.eventCalendarID ?? "" }, set: { model.chooseCalendar($0.isEmpty ? nil : $0, in: preferences) })) {
                Text("Last used, else Calendar’s default", comment: "Settings → Calendar & Reminders: no calendar is fixed; an event starts in the calendar used last, and in the one Calendar chooses until then").tag("")
                ForEach(model.calendars) { Text(verbatim: ActionsModel.label($0)).tag($0.id) }
                if let id = preferences.eventCalendarID, !model.calendars.contains(where: { $0.id == id }) {
                    Text(verbatim: preferences.eventCalendarName ?? "—").tag(id)
                }
            } label: {
                Text("Default calendar", comment: "Settings → Calendar & Reminders: the calendar a new follow-up event starts in")
            }
        } else {
            LabeledContent {
                Text("Calendar asks where to add it", comment: "Settings → Calendar & Reminders: without full Calendar access an event is handed to Calendar as a file, which asks where to put it").foregroundStyle(.secondary)
            } label: {
                Text("Default calendar", comment: "Settings → Calendar & Reminders: the calendar a new follow-up event starts in")
            }
        }
    }
}
