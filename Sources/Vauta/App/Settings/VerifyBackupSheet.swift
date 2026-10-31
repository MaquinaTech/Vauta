// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// "Verify Backup…": the password of a backup file, then what it holds. The file is opened exactly as Restore opens it, and
/// nothing is replaced or kept.
struct VerifyBackupSheet: View {
    @Bindable var model: BackupModel
    @FocusState private var passwordFocused: Bool
    @AccessibilityFocusState private var doneFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if case .done = model.stage {
                SheetHeader(Text("Backup Verified", comment: "Verify sheet title once the backup passed the check"), symbol: "checkmark.shield")
            } else {
                SheetHeader(Text("Verify a Backup", comment: "Verify sheet title: check a backup file without restoring it"), symbol: "checkmark.shield")
            }
            content
            buttons
        }
        .padding(20)
        .frame(width: 440)
        .environment(\.iconColumnAlignment, .leading)
        .onAppear { passwordFocused = true }
        .onExitCommand { if model.stage != .working { model.reset() } }
        .onChange(of: model.stage) { _, stage in
            if stage == .form { passwordFocused = true }
            BackupAnnouncement.post(for: stage) { doneFocused = true }
            BackupAnnouncement.postWorking(stage, model: model)
        }
        .onChange(of: model.error) { _, error in BackupAnnouncement.post(error: error, hint: model.errorHint) }
    }

    @ViewBuilder
    private var content: some View {
        if case .done(let text) = model.stage {
            fileCard
            FeedbackLabel(feedback: .init(kind: .success, text: text))
                .frame(maxWidth: .infinity, alignment: .leading)
            if let contents = model.verified { contentsCard(contents) }
        } else {
            Text("Enter the backup’s password. Vauta opens it as Restore would, without changing anything.",
                 comment: "Verify sheet: the sentence under the title")
                .fixedSize(horizontal: false, vertical: true)
            fileCard
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Password").gridColumnAlignment(.leading)
                    SecureField(text: $model.password, prompt: Text(verbatim: "")) { Text("Backup password") }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .focused($passwordFocused)
                        .onSubmit { verify() }
                }
            }
            .disabled(model.stage == .working)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground()
            statusSlot
        }
    }

    /// The progress and a wrong password share one slot, sized for the taller, so the buttons keep their place.
    private var statusSlot: some View {
        ZStack(alignment: .topLeading) {
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
            } else if let error = model.error {
                FeedbackLabel(feedback: .init(kind: .error, text: error, note: model.errorHint))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// What the backup holds, counted in it, in the grey card of the sheets: what a restore would bring back.
    private func contentsCard(_ contents: BackupContents) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            row(Text("Meetings"), contents.meetings.formatted())
            if contents.savedVoices > 0 { row(Text("Saved voices"), contents.savedVoices.formatted()) }
            if contents.documentSources > 0 {
                row(Text("Document sources", comment: "Verify sheet: how many folders and files added as knowledge sources the backup holds"),
                    contents.documentSources.formatted())
            }
            row(Text("Settings", comment: "Verify sheet: whether the backup carries the app's settings"),
                contents.hasSettings ? String(localized: "Included", comment: "Verify sheet: the backup carries the settings")
                                     : String(localized: "Not included", comment: "Verify sheet: the backup carries no settings (made by an earlier version)"))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func row(_ label: Text, _ value: String) -> some View {
        GridRow {
            label.foregroundStyle(.secondary).gridColumnAlignment(.leading)
            Text(verbatim: value).monospacedDigit()
        }
    }

    @ViewBuilder
    private var fileCard: some View {
        if let file = model.file { BackupFileCard(file: file, date: model.backupDate) }
    }

    private var buttons: some View {
        HStack {
            if case .done = model.stage {
                Spacer()
                Button(BackupAnnouncement.doneTitle) { model.reset() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityFocused($doneFocused)
            } else {
                // A wrong or damaged file is fixed from here, as in the restore sheet.
                Button("Choose Another File…") { Task { await model.chooseAnotherFile() } }
                    .disabled(model.stage == .working)
                Spacer()
                // While checking, Cancel goes back to the form: nothing is changed either way.
                Button("Cancel", role: .cancel) { model.stage == .working ? model.cancelOpen() : model.reset() }
                    .keyboardShortcut(.cancelAction)
                Button { verify() } label: { Text("Verify", comment: "Verify sheet: the button that opens and checks the backup") }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.password.isEmpty || model.stage == .working)
            }
        }
    }

    private func verify() {
        guard !model.password.isEmpty, model.stage == .form else { return }
        model.startVerify()
    }
}
