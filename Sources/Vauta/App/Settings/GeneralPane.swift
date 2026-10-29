// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import ServiceManagement
import SwiftUI

/// Settings → General: login, shortcuts and notifications.
struct GeneralPane: View {
    @Bindable var recorder: RecorderModel
    @Bindable var preferences: Preferences
    @Bindable var model: SettingsModel
    @ViewLocalState private var notifications: PermissionState?

    /// Notifications can't be delivered yet: the switches are dimmed until the permission is granted.
    /// The switches read as off while notifications aren't allowed, without touching what the user chose.
    private func shown(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { !notificationsBlocked && binding.wrappedValue }, set: { binding.wrappedValue = $0 })
    }

    private var notificationsBlocked: Bool { notifications == .denied || notifications == .notDetermined }

    var body: some View {
        Form {
            if model.menuBarIconMayBeHidden {
                Section {
                    NoticeLabel(Text("Vauta’s icon may be hidden in the menu bar, for example behind the notch. Open Vauta again from Finder, Spotlight or Apps to come back here.",
                                     comment: "Settings → General, after setup when the menu bar icon couldn't be found"), status: .info)
                }
            }
            Section {
                Toggle(isOn: Binding(
                    get: { model.loginItemStatus == .enabled || model.loginItemStatus == .requiresApproval },
                    set: { model.setLaunchAtLogin($0, recorder) })) {
                    Text("Open Vauta at login")
                    Text(description: String(localized: "Vauta lives in the menu bar: click the waveform icon at the top of the screen to record, see live notes and open Meetings.",
                         comment: "Settings → General"))
                }
                if model.loginItemStatus == .requiresApproval {
                    // The longest "Open … Settings" button (de) does not fit beside the note: it goes under it, wrapping if it must.
                    let note = SettingsNote(String(localized: "Approve Vauta in System Settings\u{00A0}→\u{00A0}General\u{00A0}→\u{00A0}Login Items & Extensions.", comment: "Settings → General"))
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            note
                            Spacer()
                            Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }.lineLimit(1)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            note
                            FittingButton(title: Text("Open Login Items Settings")) { SMAppService.openSystemSettingsLoginItems() }
                        }
                    }
                }
            } header: {
                Text("Startup", comment: "Settings → General: section with the open-at-login switch")
            }

            Section {
                HotKeyRecorder(recorder: recorder, label: String(localized: "Start or stop recording", comment: "Shortcut name"),
                               spec: $preferences.recordHotKey,
                               others: [preferences.markHotKey, preferences.noteHotKey, preferences.translationHotKey],
                               defaultSpec: Preferences.defaultRecordHotKey)
                HotKeyRecorder(recorder: recorder, label: String(localized: "Mark a moment", comment: "Shortcut name"),
                               spec: $preferences.markHotKey,
                               others: [preferences.recordHotKey, preferences.noteHotKey, preferences.translationHotKey],
                               defaultSpec: Preferences.defaultMarkHotKey)
                HotKeyRecorder(recorder: recorder, label: String(localized: "Take a note", comment: "Shortcut name: opens the floating notepad to type a short note during a recording"),
                               spec: $preferences.noteHotKey,
                               others: [preferences.recordHotKey, preferences.markHotKey, preferences.translationHotKey],
                               defaultSpec: Preferences.defaultNoteHotKey)
                HotKeyRecorder(recorder: recorder, label: String(localized: "Turn Live Translation on or off", comment: "Shortcut name"),
                               spec: $preferences.translationHotKey,
                               others: [preferences.recordHotKey, preferences.markHotKey, preferences.noteHotKey],
                               defaultSpec: Preferences.defaultTranslationHotKey)
                if !recorder.hotKeyAvailable {
                    NoticeLabel(Text("\(recorder.recordHotKeyText) is used by another app. Choose a different shortcut to start and stop recording.", comment: "Settings → General; argument is a shortcut"), status: .warning)
                }
                if !recorder.translationHotKeyAvailable {
                    NoticeLabel(Text("\(recorder.translationHotKeyText) is used by another app. Choose a different shortcut to turn Live Translation on or off.", comment: "Settings → General; argument is a shortcut"), status: .warning)
                }
                if recorder.isRecording && !recorder.noteHotKeyAvailable {
                    NoticeLabel(Text("\(recorder.noteHotKeyText) is used by another app. Choose a different shortcut to open the notepad.", comment: "Settings → General; argument is a shortcut"), status: .warning)
                }
            } header: {
                Text("Keyboard shortcuts")
            } footer: {
                SettingsNote(String(localized: "These shortcuts work in any app. Marking a moment, taking a note and Live Translation work only while recording.",
                                    comment: "Settings → General"))
            }

            // Not a shortcut: its own group, after the footer that explains the shortcuts.
            Section {
                Toggle(isOn: $preferences.openNotepadOnStart) {
                    Text("Open the notepad when recording starts")
                    Text(description: String(localized: "A small floating window for short notes. It never takes the keyboard from your meeting app until you click it or use the shortcut. Vauta asks macOS to keep it out of screen sharing, but that is not guaranteed.",
                         comment: "Settings → General, under the switch that opens the notepad when a recording starts"))
                }
            }

            Section {
                Toggle(isOn: Bindable(preferences.actions).followUpCardEnabled) {
                    Text("Show follow-up after meetings", comment: "Settings → General: the switch for the menu-bar panel card that offers to review a meeting's tasks and follow-up meetings")
                    Text(description: ActionsRelease.followUpDetection
                         ? String(localized: "When the minutes of a meeting are ready, the menu bar panel offers to review its tasks and follow-up meetings. It shows nothing from the meeting while Meetings are locked.",
                                  comment: "Settings → General, under the follow-up card switch")
                         : String(localized: "When the minutes of a meeting are ready, the menu bar panel offers to review its tasks. It shows nothing from the meeting while Meetings are locked.",
                                  comment: "Settings → General, under the follow-up card switch, while Vauta does not look for follow-up meetings"))
                }
            }

            Section {
                // The permission first: the switches below do nothing until it is granted.
                switch notifications {
                case .denied:
                    HStack {
                        NoticeLabel(Text("Notifications for Vauta are turned off in System Settings.", comment: "Settings → General"), status: .warning)
                        Spacer()
                        Button("Open System Settings") { Permissions.open(.notifications) }
                    }
                case .notDetermined:
                    HStack {
                        NoticeLabel(Text("Notifications are off until you allow them.", comment: "Settings → General"), status: .info)
                        Spacer()
                        Button("Allow Notifications…") { Task { notifications = await Permissions.requestNotifications() } }
                    }
                default:
                    EmptyView()
                }
                Group {
                    Toggle("When minutes are ready", isOn: shown($preferences.notifyMinutesReady))
                    Toggle(isOn: shown($preferences.notifyProblems)) {
                        Text("When something needs your attention")
                        Text(description: String(localized: "For example, a recording that is about to stop on its own, or a model server that doesn’t answer. Notifications never include transcripts or minutes.",
                             comment: "Settings → General"))
                    }
                    Toggle(isOn: shown(Bindable(recorder.calendar).showTitleInNotifications)) {
                        Text("Show meeting titles in notifications")
                        Text(description: String(localized: "Calendar event and meeting titles. Notifications can appear on the Lock Screen and in screen shares.",
                             comment: "Settings → General"))
                    }
                }
                .disabled(notificationsBlocked)
            } header: {
                Text("Notifications")
            }
        }
        .formStyle(.grouped)
        .task {
            model.refreshLoginItem()
            notifications = await Permissions.notifications()
        }
    }
}
