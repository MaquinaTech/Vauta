// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// "Restore…": password, then a confirmation with counts, then the replacement.
struct RestoreSheet: View {
    let recorder: RecorderModel
    @Bindable var model: BackupModel
    @FocusState private var passwordFocused: Bool
    @AccessibilityFocusState private var doneFocused: Bool
    /// The backup of the current meetings that "Back Up Current Data First…" opens over this sheet.
    @ViewLocalState private var safety = BackupModel()
    /// The safety backup was made (and where), so the confirmation says so.
    @ViewLocalState private var safetyBackedUp = false
    @ViewLocalState private var safetyBackup: URL?
    /// A recording has stood in the way of this restore: its row keeps its room until the sheet closes.
    @ViewLocalState private var reservesBlockerRoom = false

    /// Goes to Settings → Context (after a restore that brought no meetings).
    var showContext: (() -> Void)?
    /// Goes to Settings → Models (after a restore that chose a model server this Mac doesn't have).
    var showModels: (() -> Void)?

    init(recorder: RecorderModel, model: BackupModel, safetyBackup: URL? = nil, showContext: (() -> Void)? = nil, showModels: (() -> Void)? = nil) {
        self.recorder = recorder
        self.showContext = showContext
        self.showModels = showModels
        _model = Bindable(wrappedValue: model)
        _safetyBackedUp = ViewLocalState(initialValue: safetyBackup != nil)
        _safetyBackup = ViewLocalState(initialValue: safetyBackup)
    }

    /// The replacement itself is running: nothing else may be done until it ends.
    private var restoring: Bool { model.stage == .working && model.work == .restoring }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if case .done = model.stage {
                SheetHeader(Text("Backup Restored", comment: "Restore sheet title once the backup is restored"), symbol: "arrow.down.doc")
            } else if restoring {
                // While it runs the title says what is happening, not the question already answered (as the erase sheet).
                SheetHeader(Text("Restoring Backup", comment: "Restore sheet title while the backup replaces the data"), symbol: "arrow.down.doc", tint: destructive ? .red : .accentColor)
            } else {
                SheetHeader(Text("Restore from a Backup"), symbol: "arrow.down.doc", tint: destructive ? .red : .accentColor)
            }
            if restoring {
                restoringContent
            } else {
                content
                if model.stage == .form || model.stage == .working {
                    // One slot for the opening progress and a wrong password, so the sheet keeps its height and the
                    // buttons keep their place from the form to the result.
                    statusSlot
                } else if let error = visibleError {
                    FeedbackLabel(feedback: error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                buttons
            }
        }
        .padding(20)
        .frame(width: 440)
        .environment(\.iconColumnAlignment, .leading)
        .onAppear { passwordFocused = true }
        .onChange(of: recorder.blocksDataReplacement, initial: true) { _, blocked in if blocked { reservesBlockerRoom = true } }
        .onExitCommand {
            switch model.stage {
            case .done, .confirm: model.reset()
            default: break
            }
        }
        // After a wrong password the field is enabled again, with the typed text selected for the next try.
        .onChange(of: model.stage) { _, stage in
            if stage == .form { passwordFocused = true }
            BackupAnnouncement.post(for: stage, note: model.restoredNote) { doneFocused = true }
            BackupAnnouncement.postWorking(stage, model: model)
        }
        .onChange(of: model.error) { _, error in BackupAnnouncement.post(error: error, hint: model.errorHint) }
        // A relock closes this sheet: a safety backup still encrypting is cancelled, so no file is written unseen.
        .onDisappear { safety.reset() }
        // The safety backup's sheet closes by resetting its model: what happened is kept here.
        .onChange(of: safety.stage) { _, stage in
            if case .done = stage { safetyBackup = safety.savedFile ?? safetyBackup; safetyBackedUp = true }
        }
        .sheet(isPresented: Binding(get: { safety.sheet != nil }, set: { if !$0 { safety.reset() } })) {
            BackUpSheet(recorder: recorder, model: safety)
        }
    }

    /// The failure to show under the form (not the "stop the recording" notice, which has its own row).
    private var visibleError: ModelsSettingsModel.Feedback? {
        guard let error = model.error, !(recorder.blocksDataReplacement && error == BackupModel.stopRecordingMessage) else { return nil }
        return .init(kind: .error, text: error, note: model.errorHint)
    }

    private var statusSlot: some View {
        ZStack(alignment: .topLeading) {
            // Sized for the tallest thing it holds: the progress row, or a failure with its advice.
            VStack(alignment: .leading, spacing: 0) {
                BusyRow(title: model.workingMessage)
                FeedbackLabel(feedback: .init(kind: .error, text: BackupModel.message(StoreError(.backupAuthentication)),
                                              note: BackupModel.hint(for: StoreError(.backupAuthentication))))
            }
            .hidden()
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            if model.stage == .working {
                BusyRow(title: model.workingMessage)
            } else if let error = visibleError {
                FeedbackLabel(feedback: error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        switch model.stage {
        case .form, .working:
            // The sentence under the header, then the file, as in the confirmation step.
            Text("Enter the password you chose when you made this backup.")
                .fixedSize(horizontal: false, vertical: true)
            fileCard
            // The same card as the backup sheet: a primary label beside the field, which itself stays empty.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Password").gridColumnAlignment(.leading)
                    SecureField(text: $model.password, prompt: Text(verbatim: "")) { Text("Backup password") }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .focused($passwordFocused)
                        .onSubmit { open() }
                }
            }
            .disabled(model.stage == .working)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground()
        case .confirm(let current, let backup):
            VStack(alignment: .leading, spacing: 16) { confirmContent(current: current, backup: backup) }
        case .done(let text):
            fileCard
            VStack(alignment: .leading, spacing: 8) {
                // The settings sentence is the note under the result, as the error states have theirs.
                FeedbackLabel(feedback: .init(kind: .success, text: text, note: model.restoredNote))
                if model.restoredNeedsServer {
                    // A title and its note, like the result above it. What happens meanwhile depends on this Mac.
                    FeedbackLabel(feedback: .init(kind: .warning,
                                                  text: String(localized: "The model server isn’t included", comment: "Restore sheet result, title: the restored settings chose a model server and this Mac has none"),
                                                  note: model.restoredAppleAvailable
                                                      ? String(localized: "Minutes use Apple Intelligence on this Mac until you set one up.", comment: "Restore sheet result, note under the missing model server title, on a Mac with Apple Intelligence")
                                                      : String(localized: "No minutes are written until you set one up.", comment: "Restore sheet result, note under the missing model server title, on a Mac without Apple Intelligence")))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The confirmation: lead, file, what stands in the way, the warning and the closing line. Also the invisible sizer
    /// under the restoring step, so the sheet keeps its height when the replacement starts.
    @ViewBuilder
    private func confirmContent(current: Int, backup: Int) -> some View {
        // The lead sentence, then the backup it is about in the grey card, then what stands in the way (a recording
        // is stopped first), then the warning (as in the other sheets).
        let context = model.currentContext
        if current > 0 {
            Text("This replaces \(current) meetings with \(backup) from the backup.")
                .fixedSize(horizontal: false, vertical: true)
        } else if context > 0 {
            // No meetings, but the context (people, projects, glossary, recurring meetings) is replaced too: the lead says so.
            Text("This restores \(backup) meetings and replaces your context (\(context) entries) from the backup.",
                 comment: "Restore sheet: there are no meetings here, but there is context; the arguments are the meetings in the backup and the context entries (people, projects, glossary terms, recurring meetings) being replaced")
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("This restores \(backup) meetings from the backup.")
                .fixedSize(horizontal: false, vertical: true)
        }
        fileCard
        // A recording in the way is stopped from here (the stop button, the saving wait, then nothing). Once it has
        // been there, its room is kept for the rest of the steps, so the sheet and its buttons keep their place.
        if recorder.blocksDataReplacement || reservesBlockerRoom {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    NoticeLabel(Text(BackupModel.stopRecordingMessage), status: .info)
                    Button("Stop Recording") {}.padding(.leading, 28)
                }
                .hidden()
                .accessibilityHidden(true)
                .allowsHitTesting(false)
                DataReplacementBlocker(recorder: recorder, message: BackupModel.stopRecordingMessage, inline: false)
            }
        }
        // The warnings and the button that goes with them share one rhythm (8 pt), like the blocker above. Only when there
        // is something to replace: an empty stack would still add its 16 pt gap.
        if current > 0 || context > 0 || model.backupHasSettings || model.backupHasVoices || model.backupDocumentSources > 0 || model.currentDocumentSources > 0 {
            VStack(alignment: .leading, spacing: 8) {
                if current > 0 {
                    NoticeLabel(Text(description: String(localized: "Your current meetings (with their transcripts, minutes, notes and tasks) and all your context will be erased. The backup file isn’t changed.")),
                                status: .warning)
                } else if context > 0 {
                    NoticeLabel(Text(description: String(localized: "Your current context will be erased. The backup file isn’t changed.",
                                     comment: "Restore sheet: there are no meetings here, but there is context")),
                                status: .warning)
                }
                if current > 0 || context > 0 {
                    // Both states are one row of the button's height (the result and "Show in Finder" on one line), so
                    // the sheet and the button that erases don't move when the safety backup finishes and no gap is left.
                    if safetyBackedUp {
                        safetyBackedUpRow
                    } else {
                        // Under the warning, in the text column like "Show in Finder" after the backup. A recording running
                        // doesn't prevent it (the pane backs up while recording too); one being saved does, as the store is
                        // still being written.
                        Button("Back Up Current Data First…") { safety.beginBackUp() }
                            .disabled(recorder.phase == .stopping || recorder.phase == .starting)
                            .padding(.leading, 28)
                    }
                }
                if model.backupHasVoices {
                    // Biometric data comes back with the backup, including voices deleted since it was made: said before it runs.
                    NoticeLabel(Text("This backup holds saved voices. Restoring brings them back, including any you deleted after it was made, and replaces the voices saved since. You can delete them again in Settings\u{00A0}→\u{00A0}Speakers.",
                                     comment: "Restore sheet: the backup carries saved voice fingerprints, which come back with it"),
                                status: .warning)
                }
                if model.backupDocumentSources > 0 {
                    // The folders and files come back with their bookmarks; their text is not in a backup, so it is read again.
                    NoticeLabel(Text("The \(model.backupDocumentSources) document sources in the backup replace the ones here and are indexed again.",
                                     comment: "Restore sheet: the backup carries document sources (folders and files Ask reads); the argument is how many. They replace the sources of this Mac, and their text is not in the backup, so it is indexed again after the restore"),
                                status: .info)
                }
                if model.backupDocumentSources == 0, model.currentDocumentSources > 0 {
                    // A restore replaces the sources too: a backup made before documents, or without any, leaves this Mac with none.
                    NoticeLabel(Text("This backup has no document sources, so the ones on this Mac will be removed along with their index. Your files aren’t touched.",
                                     comment: "Restore sheet: the backup carries no document sources, so the ones on this Mac are removed with their index; the files themselves are not touched"),
                                status: .warning)
                }
                if model.backupHasSettings {
                    // The restore writes the backup's settings too: said before it runs, not on the result screen.
                    NoticeLabel(Text("Your settings (shortcuts, languages, privacy) will be replaced by the backup’s.",
                                     comment: "Restore sheet: the backup carries settings, which replace this Mac's"),
                                status: destructive ? .warning : .info)
                }
            }
        }
        if destructive {
            // The same closing line as the other destructive sheets.
            SheetFootnote(String(localized: "You can’t undo this.", comment: "Footnote of a sheet that deletes something for good"))
        }
    }

    /// The result of the safety backup in the place of the button it replaces, with "Show in Finder" on the same line.
    private var safetyBackedUpRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            FeedbackLabel(feedback: .init(kind: .success, text: String(localized: "Current data backed up.", comment: "Restore sheet: shown after the safety backup was saved")))
            Spacer(minLength: 0)
            if let file = safetyBackup {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
        }
        .frame(minHeight: 22)
    }

    /// The destructive button: what it replaces, settings included when the backup carries them (as the warning says).
    private func replaceTitle(current: Int) -> String {
        switch (current > 0, model.backupHasSettings) {
        case (true, true): String(localized: "Replace Meetings, Context and Settings")
        case (true, false): String(localized: "Replace Meetings and Context")
        case (false, true): String(localized: "Replace Context and Settings")
        case (false, false): String(localized: "Replace Context")
        }
    }

    /// The restore replaces something: the header is red and the closing line says it can't be undone.
    private var destructive: Bool {
        switch model.stage {
        case .confirm(let current, _): current > 0 || model.currentContext > 0
        case .working where model.work == .restoring: (model.counts?.current ?? 0) > 0 || model.currentContext > 0
        default: false
        }
    }

    /// The backup file in the grey card, on every step of the sheet.
    @ViewBuilder
    private var fileCard: some View {
        if let file = model.file { BackupFileCard(file: file, date: model.backupDate) }
    }

    /// The destructive step: the file, the progress and the warning not to quit (the title already says what is
    /// happening), then an empty footer (a half-done replacement can't be cancelled).
    private var restoringContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // The confirmation's room stays (it is drawn invisibly under the progress), so the sheet doesn't shrink and its
            // buttons don't move when the replacement starts.
            // The progress sits in the middle of that room, not at its top over an empty band.
            ZStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 16) {
                    confirmContent(current: model.counts?.current ?? 0, backup: model.counts?.backup ?? 0)
                }
                .hidden()
                .accessibilityHidden(true)
                .allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 16) {
                    fileCard
                    WorkingLabel(meetings: model.counts?.backup, encrypting: false, quitNote: true)
                }
            }
            // No buttons while it runs (neither can be used, and the question was answered); their height is kept.
            Color.clear.frame(height: 22).accessibilityHidden(true)
        }
    }

    private var buttons: some View {
        HStack {
            if model.stage == .form || model.stage == .working {
                // A wrong or damaged file is fixed from here, without starting the restore again from Settings.
                Button("Choose Another File…") { Task { await model.chooseAnotherFile() } }
                    .disabled(model.stage == .working)
            }
            Spacer()
            switch model.stage {
            case .done:
                if model.restoredNeedsServer {
                    // The restored settings point minutes at a server this Mac doesn't have: where to set it up.
                    Button(SettingsModel.Pane.models.openTitle) {
                        showModels?()
                        model.reset()
                    }
                } else if model.restoredMeetings == 0 {
                    // Only the context came back: go where it is.
                    Button(SettingsModel.Pane.context.openTitle) {
                        showContext?()
                        model.reset()
                    }
                } else {
                    Button("Open Meetings") {
                        Task { await recorder.openMeeting(nil) }
                        model.reset()
                    }
                }
                Button(BackupAnnouncement.doneTitle) { model.reset() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityFocused($doneFocused)
            case .confirm(let current, _):
                // Cancel is the default (Return) wherever something is replaced for good; Escape also cancels (onExitCommand).
                Button("Cancel", role: .cancel) { model.reset() }.keyboardShortcut(current > 0 || model.currentContext > 0 ? .defaultAction : .cancelAction)
                if current > 0 || model.currentContext > 0 {
                    // Replacing something: the system's red destructive button, and never the Return key's default.
                    let title = replaceTitle(current: current)
                    // Red only while it can be used: blocked, it is the system's plain disabled button.
                    if recorder.blocksDataReplacement {
                        Button(title, role: .destructive) {}
                            .destructiveSheetButton()
                            .disabled(true)
                    } else {
                        Button(title, role: .destructive) { Task { await model.restore(recorder) } }
                            .destructiveSheetButton()
                    }
                } else {
                    Button("Restore") { Task { await model.restore(recorder) } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(recorder.blocksDataReplacement)
                }
            default:
                // While opening, Cancel goes back to the form: nothing has been replaced yet.
                Button("Cancel", role: .cancel) { model.stage == .working ? model.cancelOpen() : model.reset() }
                    .keyboardShortcut(.cancelAction)
                Button("Open Backup") { open() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.password.isEmpty || model.stage == .working)
            }
        }
        // Escape cancels although Cancel is the Return button while a restore would replace something.
        .onExitCommand { if model.stage != .working { model.reset() } }
    }

    private func open() {
        guard !model.password.isEmpty, model.stage == .form else { return }
        model.startOpen(recorder)
    }
}

/// The backup file a sheet works with, in the grey card used on every step: its name and, when known, when the
/// backup was made; optionally the button that shows it in Finder.
struct BackupFileCard: View {
    let file: URL
    let date: Date?
    var showInFinder = false

    /// When the file was made, for a card that has no date of its own (a backup just saved).
    static func creationDate(of file: URL) -> Date? {
        (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.lastPathComponent).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    if let date {
                        Text(date, format: .dateTime.day().month(.wide).year().hour().minute())
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "doc").foregroundStyle(.secondary)
            }
            .labelStyle(AlignedIconLabelStyle())
            if showInFinder {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    .padding(.leading, 28)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}
