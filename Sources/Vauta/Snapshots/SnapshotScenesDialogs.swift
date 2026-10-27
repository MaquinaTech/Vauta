// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import SwiftUI

/// A system alert or confirmation dialog, drawn by AppKit's `NSAlert` (what SwiftUI's `.alert` and
/// `.confirmationDialog` show), so its size, icon, button order and default button are the real ones.
struct SnapshotAlert {
    struct Button {
        var title: String
        var destructive = false
    }

    var title: String
    var message: String
    var buttons: [Button]
    var warning = false
    /// The button Return presses, as in the app.
    var defaultIndex = 0
    /// An SF Symbol drawn instead of the app icon (the Touch ID prompt shows the fingerprint).
    var symbol: String?
}

/// Alerts and confirmation dialogs. Their wording comes from the same types the app uses where it has one
/// (`PendingDeletion`, `MeetingsAlert`, `ContextFailure`, `ReanalysisReportText`); the rest repeat the app's strings.
extension SnapshotScenes {
    private static func dialog(_ name: String, title: String, message: String, buttons: [SnapshotAlert.Button], warning: Bool = false, defaultIndex: Int = 0) -> SnapshotScene {
        SnapshotScene(name: "dialog-\(name)", size: CGSize(width: 260, height: 160), isSheet: true) { _ in
            .init(view: AnyView(EmptyView()), alert: SnapshotAlert(title: title, message: message, buttons: buttons, warning: warning, defaultIndex: defaultIndex))
        }
    }

    private static var cancel: SnapshotAlert.Button { .init(title: String(localized: "Cancel", comment: "Alert button")) }
    private static var ok: SnapshotAlert.Button { .init(title: String(localized: "OK", comment: "Alert button")) }

    /// A confirmation: the destructive action, then Cancel (SwiftUI adds it last). Cancel is the default button (Return),
    /// as in the quit alert; `safeDefault: false` keeps the action as the default, for the one that can be undone.
    private static func confirmation(_ name: String, title: String, message: String, action: String, safeDefault: Bool = true) -> SnapshotScene {
        dialog(name, title: title, message: message, buttons: [.init(title: action, destructive: true), cancel], defaultIndex: safeDefault ? 1 : 0)
    }

    /// A deletion that names something of the sample (a meeting, a task...): its text is the sample's, in the language of the render.
    private static func deletion(_ name: String, _ make: @escaping @Sendable (SampleContent) -> PendingDeletion) -> SnapshotScene {
        SnapshotScene(name: "dialog-\(name)", size: CGSize(width: 260, height: 160), isSheet: true) { fixture in
            let pending = make(fixture.content)
            return .init(view: AnyView(EmptyView()),
                         alert: SnapshotAlert(title: pending.title, message: pending.message,
                                              buttons: [.init(title: pending.confirmLabel, destructive: true), cancel], defaultIndex: 1))
        }
    }

    private nonisolated static func sampleMeeting(_ content: SampleContent) -> MeetingStore.Meeting {
        let when = SampleWorld.snapshotNow.addingTimeInterval(-3600)
        return MeetingStore.Meeting(id: 1, startedAt: when, endedAt: when.addingTimeInterval(2_700), title: content.featuredTitle)
    }

    /// Deleting a note: the note is one of the sample bullets, in the language of the render.
    private static func noteDeletion(_ name: String) -> SnapshotScene {
        SnapshotScene(name: "dialog-\(name)", size: CGSize(width: 260, height: 160), isSheet: true) { fixture in
            let pending = PendingDeletion.note(MeetingNote(id: 1, meetingID: 1, t: 754, text: fixture.content.notes.first ?? ""))
            return .init(view: AnyView(EmptyView()),
                         alert: SnapshotAlert(title: pending.title, message: pending.message,
                                              buttons: [.init(title: pending.confirmLabel, destructive: true), cancel], defaultIndex: 1))
        }
    }

    private static func meetingsAlert(_ name: String, _ alert: MeetingsAlert) -> SnapshotScene {
        switch alert.recovery {
        case .openSettings(let pane)?:
            dialog(name, title: alert.title, message: alert.message, buttons: [.init(title: pane.openTitle), cancel])
        case .retry?:
            dialog(name, title: alert.title, message: alert.message, buttons: [.init(title: String(localized: "Try Again", comment: "Alert button")), cancel])
        case nil:
            dialog(name, title: alert.title, message: alert.message, buttons: [ok])
        }
    }

    static var dialogs: [SnapshotScene] {
        let person = "Daniel Ortega", term = "Kubernetes", meetings = 12, speakers = 3
        let language = Locale.current.localizedString(forIdentifier: "en-US") ?? "English"
        var progress = ReanalysisProgress()
        progress.start(total: 14)
        for index in 0..<14 {
            var found = AnalysisSummary()
            found.mentions = 3; found.ambiguous = index < 3 ? 1 : 0; found.corrections = index == 0 ? 1 : 0
            progress.record(found)
        }
        progress.finish()
        var stopped = ReanalysisProgress()
        stopped.start(total: 14)
        for _ in 0..<5 { stopped.record(AnalysisSummary()) }
        stopped.recordFailure()
        stopped.cancel()
        return [
            // Meetings window.
            // The counts of the featured meeting itself, as its tabs show them.
            SnapshotScene(name: "dialog-meeting-delete", size: CGSize(width: 260, height: 160), isSheet: true) { fixture in
                let world = fixture.world
                try? await world.resetActions()
                guard let meeting = try? await world.store.meeting(world.featuredMeetingID) else { return .init(view: AnyView(EmptyView())) }
                let pending = PendingDeletion.meeting(meeting, segments: (try? await world.store.segments(of: meeting.id).count) ?? 0,
                                                      decisions: (try? await world.store.decisions(meeting.id).count) ?? 0,
                                                      tasks: (try? await world.store.tasks(meeting.id).count) ?? 0)
                return .init(view: AnyView(EmptyView()),
                             alert: SnapshotAlert(title: pending.title, message: pending.message,
                                                  buttons: [.init(title: pending.confirmLabel, destructive: true), cancel], defaultIndex: 1))
            },
            // A short recording that has no title: one passage, one decision, one task (the singular wording).
            SnapshotScene(name: "dialog-meeting-delete-singular", size: CGSize(width: 260, height: 160), isSheet: true) { fixture in
                let start = fixture.world.startDate(ofMeeting: 1)
                let pending = PendingDeletion.meeting(MeetingStore.Meeting(id: 1, startedAt: start, endedAt: start.addingTimeInterval(240), title: nil),
                                                      segments: 1, decisions: 1, tasks: 1)
                return .init(view: AnyView(EmptyView()),
                             alert: SnapshotAlert(title: pending.title, message: pending.message,
                                                  buttons: [.init(title: pending.confirmLabel, destructive: true), cancel], defaultIndex: 1))
            },
            // A `Decision` can't be built here: the same wording, with the decision's text as the message.
            SnapshotScene(name: "dialog-decision-delete", size: CGSize(width: 260, height: 160), isSheet: true) { fixture in
                .init(view: AnyView(EmptyView()), alert: SnapshotAlert(
                    title: String(localized: "Delete this decision?", comment: "Confirmation title"), message: fixture.content.featuredDecision,
                    buttons: [.init(title: String(localized: "Delete Decision", comment: "Button: confirm deleting a decision"), destructive: true), cancel], defaultIndex: 1))
            },
            deletion("task-delete") { .task(id: 1, text: $0.featuredTask) },
            noteDeletion("note-delete"),
            deletion("mark-delete") { _ in .mark(MeetingMark(id: 1, meetingID: 1, t: 754)) },
            deletion("question-delete") { .question(index: 0, text: $0.featuredQuestion) },
            meetingsAlert("copy-protected", .copyProtected),
            meetingsAlert("export-failed", .exportFailure(CocoaError(.fileWriteNoPermission), retry: {})),
            meetingsAlert("load-failed", .loadFailure(StoreError(.fileSystem, detail: "snapshot"), retry: {})),
            meetingsAlert("recording-busy", MeetingsAlert(title: String(localized: "This meeting is being recorded", comment: "Alert title"),
                                                          message: String(localized: "Stop the recording before deleting this meeting.", comment: "Alert message"))),
            // Context (Settings → Context).
            dialog("context-unsaved", title: String(localized: "Do you want to save the changes to “\(person)”?", comment: "Prompt before leaving an edited item; the argument is its name"),
                   message: String(localized: "Your changes will be lost if you don’t save them.", comment: "Alert message"),
                   buttons: [.init(title: String(localized: "Save", comment: "Button")), .init(title: String(localized: "Don’t Save", comment: "Button"), destructive: true), cancel]),
            confirmation("context-term-delete", title: String(localized: "Delete “\(term)”?", comment: "Confirmation title; the argument is a glossary term"),
                         message: String(localized: "The term is removed from the glossary. Transcripts don’t change. You can’t undo this.", comment: "Confirmation message"),
                         action: String(localized: "Delete Term", comment: "Alert button")),
            SnapshotScene(name: "dialog-context-series-delete", size: CGSize(width: 260, height: 160), isSheet: true) { fixture in
                let title = sampleMeeting(fixture.content).displayTitle
                return .init(view: AnyView(EmptyView()), alert: SnapshotAlert(
                    title: String(localized: "Delete “\(title)”?", comment: "Confirmation title; the argument is the title of a recurring meeting"),
                    message: [String(localized: "\(meetings) meetings stay, but are no longer grouped under this recurring meeting.", comment: "Delete confirmation for a recurring meeting; the argument is a count"),
                                   String(localized: "It comes from your calendar, so Vauta creates it again the next time you record this event.", comment: "Delete confirmation for a recurring meeting created from a calendar event"),
                                   String(localized: "You can’t undo this.", comment: "Last sentence of a delete confirmation")].joinedAsSentences(),
                    buttons: [.init(title: String(localized: "Delete Recurring Meeting", comment: "Alert button"), destructive: true), cancel], defaultIndex: 1))
            },
            dialog("context-failure", title: ContextOperation.saveEntity(.person).failureTitle,
                   message: [KnowledgeError.emailInUse("daniel@example.com").localizedDescription, String(localized: "Each email address can belong to only one person.", comment: "Recovery suggestion for a duplicate email")].joinedAsSentences(),
                   // The alert the editor shows when the person who owns the email is known: the action, then Cancel.
                   buttons: [.init(title: ContextFailure.mergeTitle), cancel]),
            dialog("context-reanalysis-finished", title: String(localized: "Finished finding names", comment: "Alert title after finding the names again in all meetings"),
                   message: ReanalysisReportText.message(for: progress), buttons: [ok]),
            dialog("context-reanalysis-stopped", title: String(localized: "Finding names stopped", comment: "Alert title after the user cancelled finding the names again in all meetings"),
                   message: ReanalysisReportText.message(for: stopped), buttons: [ok]),
            // Settings.
            confirmation("settings-speech-model-remove", title: String(localized: "Remove the speech model for \(language)?", comment: "Confirmation title; argument is a language"),
                         message: String(localized: "Vauta will no longer transcribe this language until you download it again. macOS deletes the model when no other app uses it.", comment: "Confirmation message"),
                         action: String(localized: "Remove Model", comment: "Alert button")),
            confirmation("settings-server-remove", title: String(localized: "Remove the model server?", comment: "Confirmation title"),
                         message: String(localized: "Vauta forgets the server address, models and key. Minutes will use Apple Intelligence on this Mac until you set up a server again.", comment: "Confirmation message"),
                         action: String(localized: "Remove Server", comment: "Alert button")),
            confirmation("settings-search-model-delete", title: String(localized: "Delete the search model?", comment: "Confirmation title"),
                         message: SearchModelText.deleteMessage(choice: .onDeviceModel, freed: SearchModelSpec.pinned.installedSize),
                         action: String(localized: "Delete", comment: "Alert button")),
            confirmation("settings-search-model-delete-server", title: String(localized: "Delete the search model?", comment: "Confirmation title"),
                         message: SearchModelText.deleteMessage(choice: .server, freed: SearchModelSpec.pinned.installedSize),
                         action: String(localized: "Delete", comment: "Alert button")),
            confirmation("settings-search-model-discard", title: String(localized: "Discard the partial download?", comment: "Confirmation title"),
                         message: String(localized: "You’ll start from the beginning next time.", comment: "Confirmation message"),
                         action: String(localized: "Discard", comment: "Alert button")),
            confirmation("settings-key-remove", title: String(localized: "Remove the saved key?", comment: "Confirmation title"),
                         message: String(localized: "Vauta will stop sending a key to the server until you enter one again.", comment: "Confirmation message"),
                         action: String(localized: "Remove Key", comment: "Alert button")),
            confirmation("settings-leftovers-delete", title: String(localized: "Delete the old copies of your meetings?", comment: "Confirmation title"),
                         message: StatusPane.leftoversMessage(bytes: 20_480, hasOldFolder: false, hasSetAside: true),
                         action: String(localized: "Delete Old Copies", comment: "Alert button")),
            dialog("settings-models-unsaved", title: String(localized: "Save your model server changes?", comment: "Alert when closing Settings or quitting with unsaved Models changes"),
                   message: String(localized: "You changed the model server settings but haven’t saved them. If you don’t save them, your changes are lost.", comment: "Alert when closing Settings or quitting with unsaved Models changes"),
                   buttons: [.init(title: String(localized: "Save", comment: "Button")), .init(title: String(localized: "Don’t Save", comment: "Alert button"), destructive: true), cancel]),
            confirmation("speakers-separation-off", title: String(localized: "Don’t separate speakers in this meeting?", comment: "Confirmation title"),
                         message: String(localized: "The \(speakers) speakers in this meeting, and any names you gave them, are removed. Vauta can’t separate them again because it keeps no audio. You can undo this from the Edit menu until you open another meeting.", comment: "Confirmation message"),
                         action: String(localized: "Don’t Separate Speakers", comment: "Alert button")),
            // App-level alerts.
            dialog("quit-recording", title: String(localized: "Stop recording and quit?", comment: "Alert title when quitting from the panel during a recording"),
                   message: String(localized: "The meeting so far is saved.", comment: "Alert text when quitting from the panel during a recording"),
                   buttons: [cancel, .init(title: String(localized: "Stop and Quit", comment: "Alert button"), destructive: true)]),
            dialog("already-running", title: String(localized: "Vauta is already running", comment: "Alert title"),
                   message: String(localized: "Use the copy in the menu bar. This one quits without touching your meetings.", comment: "Alert text when a second instance starts"),
                   buttons: [ok]),
            dialog("no-login-password", title: String(localized: "Your Mac has no login password", comment: "Alert title"),
                   message: String(localized: "Vauta protects Meetings and Context with your login password or Touch ID. Without a password, anyone using this Mac can open them. You can set one in System Settings\u{00A0}→\u{00A0}Users & Groups.", comment: "Alert text when the Mac has no password"),
                   buttons: [.init(title: String(localized: "Open Users & Groups Settings", comment: "Alert button")), .init(title: String(localized: "Open Meetings", comment: "Alert button")), cancel],
                   warning: true),
            dialog("no-login-password-backup", title: String(localized: "Your Mac has no login password", comment: "Alert title"),
                   message: String(localized: "Vauta asks for your login password or Touch ID before a backup, restore or erase. Without a password, anyone using this Mac can do these. You can set one in System Settings\u{00A0}→\u{00A0}Users & Groups.", comment: "Alert text when the Mac has no password and the action is a backup, restore or erase"),
                   buttons: [.init(title: String(localized: "Open Users & Groups Settings", comment: "Alert button")),
                             .init(title: String(localized: "Continue Without a Password", comment: "Alert button")), cancel],
                   warning: true),
        ]
    }
}
#endif
