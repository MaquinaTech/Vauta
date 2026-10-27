// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// Settings → Calendar & Reminders: optional, read-only, minimal. Calendar suggests recording and names meetings; the brief (a switch
/// below) prepares a page before each meeting; Reminders (off until the person turns them on)
/// can add related reminders to it.
struct CalendarPane: View {
    @Bindable var calendar: CalendarWatcher
    @Bindable var brief: BriefPreferencesModel
    @Bindable var after: AfterMeetingsSettings
    @Bindable var actionsPreferences: ActionsPreferences

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $calendar.enabled) {
                    Text("Use Calendar to suggest and name meetings")
                    // Always the explanation: the access problem is said once, in the section below.
                    Text(description: String(localized: "When an event with a video call link is happening and a meeting app is in a call, Vauta suggests recording it. It never starts on its own. When you record, the meeting takes the event’s title and attendees.",
                         comment: "Settings → Calendar"))
                }
                if !calendar.enabled && calendar.hasAccess {
                    HStack {
                        NoticeLabel(Text("Vauta doesn’t read your calendars while this is off. You can also remove its access.", comment: "Settings → Calendar"), status: .info)
                        Spacer()
                        Button("Open System Settings") { Permissions.open(.calendars) }
                    }
                }
            } header: {
                Text("Meeting suggestions", comment: "Settings → Calendar; header of the group with the switch")
            }
            if calendar.enabled {
                Section {
                    if !calendar.hasAccess {
                        // Only the step that works: the prompt before the first request, System Settings after a denial.
                        if calendar.canRequestAccess {
                            // Says why, as the denied state does.
                            HStack {
                                NoticeLabel(Text("Vauta needs your permission to read your calendars.", comment: "Settings → Calendar; before access was asked"), status: .info)
                                Spacer()
                                Button("Allow Calendar Access…") { Task { await calendar.requestAccess() } }
                            }
                        } else {
                            HStack {
                                NoticeLabel(Text("Calendar access is turned off for Vauta in System Settings.", comment: "Settings → Calendar"), status: .warning)
                                Spacer()
                                Button("Open System Settings") { Permissions.open(.calendars) }
                            }
                        }
                    } else {
                        ForEach(calendar.calendars) { choice in
                            Toggle(isOn: Binding(get: { calendar.selected.contains(choice.id) },
                                                 set: { if $0 { calendar.selected.insert(choice.id) } else { calendar.selected.remove(choice.id) } })) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    // The calendar's colour, as in the Calendar app (the title says which one).
                                    Circle()
                                        .fill(choice.color ?? Color.secondary)
                                        .frame(width: 10, height: 10)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(choice.title)
                                        Text(choice.source).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if calendar.calendars.isEmpty {
                            HStack {
                                NoticeLabel(Text("No calendars found. Add an account in the Calendar app.", comment: "Settings → Calendar empty state"), status: .info)
                                Spacer()
                                Button(String(localized: "Open Calendar", comment: "Settings → Calendar empty state: opens the Calendar app")) {
                                    BriefController.openApp("com.apple.iCal")
                                }
                            }
                        }
                    }
                } header: {
                    Text("Calendars Vauta reads")
                } footer: {
                    if brief.enabled {
                        SettingsNote(String(localized: "macOS can only give Vauta access to all your calendars. Vauta reads just the ones you turn on and keeps no copy. It looks at events from 10\u{00A0}minutes before to 10\u{00A0}minutes after now to suggest recording.",
                                            comment: "Settings → Calendar access explanation when the brief is on; keep the no-break space between each number and “minutes”"))
                    } else {
                        SettingsNote(String(localized: "macOS can only give Vauta access to all your calendars. Vauta reads just the ones you turn on, only events from 10\u{00A0}minutes before to 10\u{00A0}minutes after now, and keeps no copy. While the brief is off, it also checks in memory whether other people are invited to those events, only to decide whether to offer you the brief.",
                                            comment: "Settings → Calendar access explanation while the brief is off; keep the no-break space between each number and “minutes”"))
                    }
                }
                if calendar.hasAccess {
                    briefSection
                    if brief.enabled { remindersSection }
                }
            }
            // Adding a task to Reminders or a follow-up meeting to Calendar does not depend on the suggestions above.
            AfterMeetingsSection(model: after, preferences: actionsPreferences)
        }
        .formStyle(.grouped)
        .background(ClearInitialFocus())
        .onAppear {
            calendar.loadCalendars()
            brief.loadLists()
        }
        .task { await after.load() }
        .onDisappear {
            calendar.forgetCalendars()
            brief.forgetLists()
            after.forget()
        }
    }

    // MARK: Brief

    private var briefSection: some View {
        Section {
            Toggle(isOn: $brief.enabled) {
                Text("Prepare a brief before meetings", comment: "Settings → Calendar & Reminders: the switch that turns the pre-meeting brief on")
                Text(description: String(localized: "A short page about the meeting that is about to start: who is coming, what the last meeting left open, and related meetings, documents and notes. It is built on this Mac. The brief never changes your calendar, reminders or notes.",
                     comment: "Settings → Calendar & Reminders: what the brief is"))
            }
            if brief.enabled {
                Picker(selection: $brief.leadMinutes) {
                    ForEach(BriefEventSelector.leadOptions, id: \.self) { minutes in
                        if minutes == 0 {
                            Text("Off", comment: "Settings → Calendar & Reminders: no notification before a meeting").tag(0)
                        } else {
                            Text(verbatim: Duration.seconds(minutes * 60).formatted(.units(allowed: [.minutes], width: .wide))).tag(minutes)
                        }
                    }
                } label: {
                    Text("Notify me before a meeting", comment: "Settings → Calendar & Reminders: how long before a meeting the notification goes out; the choices are Off, 5, 10, 15 and 30 minutes")
                    Text(description: String(localized: "The notification says only that a brief is ready. It never shows the brief.",
                         comment: "Settings → Calendar & Reminders: the notification before a meeting carries no content"))
                }
                Toggle(isOn: $brief.inPerson) {
                    Text("Also for meetings without a video link", comment: "Settings → Calendar & Reminders: the switch that lets the brief cover in-person events")
                    Text(description: String(localized: "Meetings with at least one other person, such as in-person meetings.",
                         comment: "Settings → Calendar & Reminders: the brief also covers events without a meeting link"))
                }
                Toggle(isOn: $brief.readInvitationNotes) {
                    Text("Use the invitation’s notes", comment: "Settings → Calendar & Reminders: the switch that lets the brief show the agenda lines of the calendar invitation")
                    Text(description: String(localized: "Shows the agenda lines of the invitation as plain text. They are read only for the brief; they are never saved and never sent to a model server.",
                         comment: "Settings → Calendar & Reminders: what using the event's description means"))
                }
            }
        } header: {
            Text("Pre-meeting brief", comment: "Settings → Calendar & Reminders; header of the group with the brief's switches")
        } footer: {
            SettingsNote(String(localized: "Vauta reads in full only the meeting about to start and the next one within 12\u{00A0}hours: title, time, people and link. To time the notification it looks only at when the events of the next few hours start. It keeps no copy of your calendar, and the brief never writes to Calendar, Reminders or Notes.",
                                comment: "Settings → Calendar & Reminders: what the brief reads from the calendar; in languages that put a space between the number and “hours”, make it a no-break space; Japanese and Korean write 12時間 and 12시간 with none, like the minutes in the same pane"))
        }
    }

    // MARK: Reminders

    @ViewBuilder private var remindersSection: some View {
        Section {
            Toggle(isOn: $brief.remindersEnabled) {
                Text("Show related reminders in the brief", comment: "Settings → Calendar & Reminders: the switch that adds related reminders to the brief")
                Text(description: String(localized: "Vauta reads only incomplete reminders in the lists you choose: title, due date, list and priority. It keeps no copy, and the brief never changes them.",
                     comment: "Settings → Calendar & Reminders: what showing reminders in the brief reads"))
            }
            if brief.remindersEnabled {
                switch brief.remindersAccess {
                case .notDetermined:
                    HStack {
                        NoticeLabel(Text("Vauta needs your permission to read your reminders.", comment: "Settings → Calendar & Reminders; before access to Reminders was asked"), status: .info)
                        Spacer()
                        Button(String(localized: "Allow Reminders Access…", comment: "Settings → Calendar & Reminders: asks macOS for access to Reminders")) { Task { await brief.requestRemindersAccess() } }
                    }
                case .denied:
                    HStack {
                        NoticeLabel(Text("Reminders access is turned off for Vauta in System Settings.", comment: "Settings → Calendar & Reminders"), status: .warning)
                        Spacer()
                        Button("Open System Settings") { Permissions.open(.reminders) }
                    }
                case .granted:
                    EmptyView()
                }
            }
        } header: {
            Text("Reminders in the brief", comment: "Settings → Calendar & Reminders; header of the group with the Reminders switch")
        }
        if brief.remindersEnabled, brief.remindersAccess == .granted {
            Section {
                ForEach(brief.reminderLists) { list in
                    Toggle(isOn: Binding(get: { brief.reminderListIDs.contains(list.id) }, set: { brief.setList(list.id, chosen: $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: list.title)
                            Text(verbatim: list.source).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                if brief.reminderLists.isEmpty {
                    HStack {
                        NoticeLabel(Text("No reminder lists found. Add an account in the Reminders app.", comment: "Settings → Calendar & Reminders empty state"), status: .info)
                        Spacer()
                        Button(String(localized: "Open Reminders", comment: "Settings → Calendar & Reminders empty state: opens the Reminders app")) {
                            BriefController.openApp("com.apple.reminders")
                        }
                    }
                } else if brief.reminderListIDs.isEmpty {
                    NoticeLabel(Text("Turn on the lists to read. With none, no reminders appear in the brief.", comment: "Settings → Calendar & Reminders: no reminder list is chosen"), status: .info)
                }
            } header: {
                Text("Reminder lists Vauta reads", comment: "Settings → Calendar & Reminders; header of the list of reminder lists")
            }
        }
    }
}
