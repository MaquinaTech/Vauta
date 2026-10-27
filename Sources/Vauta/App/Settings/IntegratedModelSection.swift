// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Settings → Models, "Integrated model": the optional language model that runs inside Vauta (Gemma 4 E4B). One row whose second
/// line and controls follow the model's state, like the search model's. Nothing is downloaded until the person clicks Download.
struct IntegratedModelSection: View {
    @Bindable var model: IntegratedModelModel
    @Bindable var models: ModelsSettingsModel
    let recorder: RecorderModel
    @ViewLocalState private var confirmingDelete = false
    @ViewLocalState private var confirmingDiscard = false
    @ViewLocalState private var confirmingCancel = false
    @ViewLocalState private var showingAbout = false

    /// The saved choice, not the draft: "ready" means what the app does now.
    private var chosen: Bool { models.savedSettings.chat == .integrated }
    /// Whether Apple Intelligence can write minutes while this model is not ready; the card never promises a stand-in that is not there.
    private var appleAvailable: Bool { models.appleAvailable }
    /// The work that is running is the repair of the installed model (stopping it deletes the model).
    private var repairing: Bool { model.status.source == "repair" }

    var body: some View {
        Section {
            LabeledContent {
                controls
            } label: {
                Text(verbatim: IntegratedModelText.modelName)
                // One view for every line under the name, so they all have the same (secondary) look.
                VStack(alignment: .leading, spacing: 2) { detail }
            }
            if model.status.state == .ready, chosen, appleAvailable {
                LabeledContent {
                    Picker(selection: Binding(get: { model.liveTasks }, set: { model.setLiveTasks($0) })) {
                        Text("Integrated model", comment: "Settings → Models; While recording choice: the integrated model writes live notes and answers").tag(ModelProviderSettings.LiveTasks.integrated)
                        Text("Apple Intelligence").tag(ModelProviderSettings.LiveTasks.apple)
                    } label: {
                        Text("While recording", comment: "Settings → Models; who writes live notes and answers questions during a meeting")
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Text("While recording", comment: "Settings → Models; who writes live notes and answers questions during a meeting")
                    Text(description: IntegratedModelText.readyLiveApple)
                }
            }
            LabeledContent {
                Button("About This Model…") { showingAbout = true }
            } label: {
                Text("Source and license", comment: "Settings → Models; row that opens the facts about the integrated model")
                Text(description: String(localized: "Google’s original, from Hugging Face (revision \(IntegratedModelText.shortRevision)), converted and checked on this Mac before use.",
                                         comment: "Settings → Models; under “Source and license” of the integrated model; the argument is the revision, not translated"))
            }
        } header: {
            Text("Integrated model", comment: "Settings → Models; header of the integrated model section")
        } footer: {
            SettingsNote(String(localized: "Downloads only from Hugging Face, and only when you click Download; the download is listed in Network Activity. Downloading sends nothing from your meetings.",
                                comment: "Settings → Models; footer of the integrated model section"))
        }
        .sheet(isPresented: $showingAbout) { IntegratedModelAboutSheet { showingAbout = false } }
        .confirmationDialog(IntegratedModelText.deleteTitle, isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { model.delete() }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: {
            Text(verbatim: Self.deleteDialogMessage(chosen: chosen, liveIntegrated: recorder.phase == .recording && model.liveTasks == .integrated,
                                                    installedBytes: model.status.installedBytes, appleAvailable: appleAvailable))
        }
        .confirmationDialog(repairing ? IntegratedModelText.cancelRepairTitle : IntegratedModelText.discardTitle, isPresented: $confirmingDiscard) {
            // A paused repair holds the damaged model itself: discarding it deletes the model, and the dialog says so.
            Button(repairing ? "Delete Model" : "Discard", role: .destructive) { model.discardPartial() }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: {
            Text(verbatim: repairing ? IntegratedModelText.cancelRepairMessage(downloadSize: IntegratedModelText.downloadSize) : IntegratedModelText.discardMessage)
        }
        .confirmationDialog(repairing ? IntegratedModelText.cancelRepairTitle : IntegratedModelText.cancelTitle, isPresented: $confirmingCancel) {
            if repairing {
                Button("Delete Model", role: .destructive) { model.cancelAndDiscard() }
                Button("Keep Repairing", role: .cancel) {}.keyboardShortcut(.defaultAction)
            } else {
                Button("Delete Download", role: .destructive) { model.cancelAndDiscard() }
                Button("Keep Downloading", role: .cancel) {}.keyboardShortcut(.defaultAction)
            }
        } message: {
            Text(verbatim: repairing ? IntegratedModelText.cancelRepairMessage(downloadSize: IntegratedModelText.downloadSize)
                                     : IntegratedModelText.cancelMessage(downloaded: Self.downloaded(model.status)))
        }
        .onChange(of: model.status.state) { old, new in announce(from: old, to: new) }
    }

    /// The text of the Delete confirmation: the stand-in it names is Apple Intelligence only on a Mac where it is available.
    static func deleteDialogMessage(chosen: Bool, liveIntegrated: Bool, installedBytes: Int, appleAvailable: Bool) -> String {
        IntegratedModelText.deleteMessage(chosen: chosen, liveIntegrated: liveIntegrated,
                                          freed: installedBytes > 0 ? installedBytes : LanguageModelSpec.pinned.installedSize, appleAvailable: appleAvailable)
    }

    private static func downloaded(_ status: LanguageModelStatus) -> Int {
        switch status.state {
        case .downloading(let r, _, _), .pausedForRecording(let r, _), .repairing(let r, _): r
        case .partial(let v, _): v
        default: status.installedBytes
        }
    }

    // MARK: Rows

    @ViewBuilder
    private var detail: some View {
        let status = model.status
        switch status.state {
        case .notInstalled:
            Text(description: IntegratedModelText.notInstalled)
        case .unsupported(let reason):
            ModelFailureLabel(text: IntegratedModelText.unsupportedNote(reason))
        case .downloading(let received, let total, let phase):
            Text(description: phase == .tokenizer && received == 0 ? IntegratedModelText.starting
                                                                   : IntegratedModelText.progress(received: received, total: total, secondsRemaining: status.secondsRemaining))
        case .checkingPartial:
            Text(description: IntegratedModelText.checkingPartial)
        case .pausedForRecording(let received, let total):
            Text(description: IntegratedModelText.pausedForRecording(received: received, total: total))
        case .partial(let verified, let total):
            Text(description: repairing ? IntegratedModelText.repairPaused(verified: verified, total: total, appleAvailable: appleAvailable)
                                        : IntegratedModelText.paused(verified: verified, total: total))
            if let error = status.lastError { ModelFailureLabel(text: IntegratedModelText.failure(error, appleAvailable: appleAvailable)) }
        case .importing(let fraction):
            Text(description: status.importPaused ? IntegratedModelText.convertingPaused(fraction) : IntegratedModelText.converting(fraction))
        case .needsFile(let missing):
            Text(description: IntegratedModelText.importedPart(missing: missing))
            if let error = status.lastError { ModelFailureLabel(text: IntegratedModelText.failure(error, appleAvailable: appleAvailable)) }
        case .verifying:
            Text(description: IntegratedModelText.verifying)
        case .preparing:
            Text(description: IntegratedModelText.preparing)
        case .deleting:
            Text(description: IntegratedModelText.deleting)
        case .ready:
            Text(description: chosen ? IntegratedModelText.ready(installedBytes: status.installedBytes)
                                     : IntegratedModelText.notChosen(provider: models.savedSettings.chat == .server ? .localServer : .onDevice))
        case .damaged:
            ModelFailureLabel(text: IntegratedModelText.damaged(appleAvailable: appleAvailable))
            Text(description: IntegratedModelText.repairSize)
        case .repairing(let received, let total):
            Text(description: IntegratedModelText.repairing(received: received, total: total))
        case .failed(let error):
            ModelFailureLabel(text: IntegratedModelText.failure(error, appleAvailable: appleAvailable))
        }
    }

    @ViewBuilder
    private var controls: some View {
        let status = model.status
        switch status.state {
        case .notInstalled:
            HStack(spacing: 8) {
                Button("Download") { model.download() }
                Button("Import from a File…") { model.chooseFilesToImport() }
            }
        case .unsupported:
            HStack(spacing: 8) {
                Image(systemName: StatusSymbol.inactive.name).foregroundStyle(.secondary).accessibilityHidden(true)
                if model.hasFilesOnDisk { Button("Delete…") { confirmingDelete = true } }
            }
        case .downloading(let received, let total, _), .pausedForRecording(let received, let total), .repairing(let received, let total):
            let paused: Bool = { if case .pausedForRecording = status.state { true } else { false } }()
            let spoken = IntegratedModelText.spokenProgress(received: Self.coarse(received), total: total, secondsRemaining: status.secondsRemaining.map { Self.coarse($0, step: 60) })
            HStack(spacing: 8) {
                // A pause is a symbol and a grey bar, not only a second line of text.
                if paused { Image(systemName: "pause.circle").foregroundStyle(.secondary).accessibilityHidden(true) }
                ProgressView(value: status.fraction ?? 0)
                    .frame(width: 120)
                    .tint(paused ? .secondary : nil)
                    .accessibilityLabel(Text("Download progress"))
                    .accessibilityValue(Text(paused ? IntegratedModelText.spokenPaused(spoken) : spoken))
                if !paused { ActionButton("Pause") { model.pause() } }
                ActionButton("Cancel…") { confirmingCancel = true }
            }
        case .checkingPartial:
            ProgressView().controlSize(.small).accessibilityLabel(Text(IntegratedModelText.checkingPartial))
        case .importing(let fraction):
            HStack(spacing: 8) {
                if status.importPaused { Image(systemName: "pause.circle").foregroundStyle(.secondary).accessibilityHidden(true) }
                ProgressView(value: fraction)
                    .frame(width: 120)
                    .tint(status.importPaused ? .secondary : nil)
                    .accessibilityLabel(Text("Conversion progress", comment: "Accessibility label of the progress of converting the model file"))
                    .accessibilityValue(Text(status.importPaused ? IntegratedModelText.spokenPaused(fraction.formatted(.percent.precision(.fractionLength(0)))) : fraction.formatted(.percent.precision(.fractionLength(0)))))
                ActionButton("Cancel") { model.cancelImport() }
            }
        case .partial:
            HStack(spacing: 8) {
                if repairing { Button("Resume Repair") { model.download() } } else { Button("Resume") { model.download() } }
                Button("Discard…") { confirmingDiscard = true }
            }
        case .needsFile(let missing):
            HStack(spacing: 8) {
                switch missing {
                case .tokenizer:
                    Button("Choose tokenizer.json…") { model.chooseFilesToImport(missing: .tokenizer) }
                    Button("Download Tokenizer") { model.download() }
                case .weights:
                    Button("Choose model.safetensors…") { model.chooseFilesToImport(missing: .weights) }
                    Button("Download Model") { model.download() }
                }
                Button("Discard…") { confirmingDiscard = true }
            }
        case .verifying, .preparing, .deleting:
            ProgressView().controlSize(.small)
                .accessibilityLabel(Text(Self.busyLabel(status.state)))
        case .ready:
            HStack(spacing: 8) {
                if chosen { StatusSymbol.ok.image } else { Button("Use for Minutes") { model.useForMinutes() } }
                Button("Delete…") { confirmingDelete = true }
            }
        case .damaged:
            HStack(spacing: 8) {
                Button("Repair") { model.repair() }
                Button("Delete…") { confirmingDelete = true }
            }
        case .failed(let error):
            HStack(spacing: 8) {
                if IntegratedModelText.isDiskFull(error) { Button("Open Storage Settings") { Permissions.open(.storage) }.wrapsToTwoLines() }
                // Files already on this Mac (a model that stopped working): check them again; otherwise download.
                Button("Try Again") { if model.hasFilesOnDisk { model.retry() } else { model.download() } }
                if IntegratedModelText.offersImport(error) { Button("Import from a File…") { model.chooseFilesToImport() } }
                if model.hasFilesOnDisk { Button("Delete…") { confirmingDelete = true } }
            }
        }
    }

    /// VoiceOver hears the value when it changes: round it so it is not read every few kilobytes.
    private static func coarse(_ value: Int, step: Int = 100_000_000) -> Int { value / step * step }

    private static func busyLabel(_ state: LanguageModelStatus.State) -> String {
        switch state {
        case .verifying: IntegratedModelText.verifying
        case .deleting: IntegratedModelText.deleting
        default: IntegratedModelText.preparing
        }
    }

    private func announce(from old: LanguageModelStatus.State, to new: LanguageModelStatus.State) {
        switch new {
        case .ready where old != .ready:
            AccessibilityNotification.Announcement(String(localized: "The integrated model is ready.", comment: "VoiceOver announcement")).post()
        case .partial where old != new:
            AccessibilityNotification.Announcement(String(localized: "Download paused.", comment: "VoiceOver announcement")).post()
        case .failed(let error):
            AccessibilityNotification.Announcement(IntegratedModelText.failure(error, appleAvailable: appleAvailable)).post()
        case .damaged:
            AccessibilityNotification.Announcement(String(localized: "The integrated model files are damaged.", comment: "VoiceOver announcement")).post()
        default:
            break
        }
    }
}

/// The facts about the model: who made it, where it comes from, how it was checked, its license and the third-party code that runs it.
struct IntegratedModelAboutSheet: View {
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: IntegratedModelText.modelName).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            fact(String(localized: "Made by Google. It writes minutes, live notes and answers on this Mac, with citations Vauta checks against the transcript.",
                        comment: "About the integrated model"))
            fact(String(localized: "Source: \(LanguageModelManifest.repository) on Hugging Face, revision \(IntegratedModelText.shortRevision). Vauta downloads only the text part (\(IntegratedModelText.downloadSize)), checks every 64 MB block against checksums it carries, converts it to a 4-bit model of \(IntegratedModelText.installedSize) on this Mac, and checks the result. The \(IntegratedModelText.originalSize) original is never stored.",
                        comment: "About the integrated model; the arguments are the repository and the revision (not translated) and sizes, e.g. 15 GB, 4.2 GB and 16 GB"))
            fact(String(localized: "It runs on this Mac with Apple’s MLX and uses about 3 to 4.5 GB of memory while it works. Your meetings are never sent anywhere.",
                        comment: "About the integrated model"))
            fact(String(localized: "License: Apache License 2.0, as stated on the model card at this revision. Google’s Gemma terms are linked for information. Google doesn’t endorse Vauta.",
                        comment: "About the integrated model"))
            VStack(alignment: .leading, spacing: 4) {
                Link(String(localized: "Model card on Hugging Face", comment: "Link"), destination: IntegratedModelText.modelCard)
                Link(String(localized: "Gemma 4 license", comment: "Link"), destination: IntegratedModelText.license)
                Link(String(localized: "Gemma Terms of Use", comment: "Link"), destination: IntegratedModelText.gemmaTerms)
                Link(String(localized: "Gemma Prohibited Use Policy", comment: "Link"), destination: IntegratedModelText.gemmaPolicy)
                Link(String(localized: "MLX (MIT license, modified)", comment: "Link to the modified build of the MLX project that runs the models"), destination: SearchModelText.mlxRepository)
            }
            .font(.callout)
            HStack {
                Spacer()
                Button(BackupAnnouncement.doneTitle, action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func fact(_ text: String) -> some View {
        Text(description: text).font(.callout).fixedSize(horizontal: false, vertical: true)
    }
}
