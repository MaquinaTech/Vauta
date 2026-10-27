// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Settings → Models, "Search by meaning": the optional search model (EmbeddingGemma 2). One row whose second line and controls
/// follow the model's state: not installed, downloading, paused, stopped, checking, preparing, indexing, ready, failed.
/// Nothing is downloaded until the person clicks Download.
struct SearchModelSection: View {
    @Bindable var model: SearchModelModel
    @Bindable var models: ModelsSettingsModel
    let recorder: RecorderModel
    @ViewLocalState private var confirmingDelete = false
    @ViewLocalState private var confirmingDiscard = false
    @ViewLocalState private var showingAbout = false
    /// The line about links to earlier meetings: only where they are on (a snapshot shows it with the switch forced on).
    @Environment(\.showsLinksLine) private var showsLinksLine

    var body: some View {
        Section {
            if model.showsRetiredNotice { retiredNotice }
            LabeledContent {
                controls
            } label: {
                Text(verbatim: SearchModelText.modelName)
                // One view for every line under the name, so they all have the same (secondary) look.
                VStack(alignment: .leading, spacing: 2) { detail }
            }
            LabeledContent {
                Button("About This Model…") { showingAbout = true }
            } label: {
                Text("Source and license", comment: "Settings → Models; row that opens the facts about the search model")
                Text(description: String(localized: "Google’s original, from Hugging Face (revision \(SearchModelText.shortRevision)), checked before use.",
                                         comment: "Settings → Models; under “Source and license”; true whether it was downloaded or imported from a file; the argument is the revision, not translated"))
            }
            if showsLinksLine {
                Text("Also suggests tasks and decisions that repeat earlier meetings. You decide on each one.",
                     comment: "Settings → Models; one line in the search model section: with the search model, the links to earlier meetings are found by meaning")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Search by meaning", comment: "Settings → Models; header of the search model section")
        } footer: {
            SettingsNote(String(localized: "Downloads only from Hugging Face, and only when you click Download; the download is listed in Network Activity. Downloading sends nothing from your meetings or documents.",
                                comment: "Settings → Models; footer of the search model section"))
        }
        .sheet(isPresented: $showingAbout) { SearchModelAboutSheet { showingAbout = false } }
        .confirmationDialog(String(localized: "Delete the search model?", comment: "Confirmation title"), isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { model.delete() }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: {
            Text(verbatim: SearchModelText.deleteMessage(choice: models.embeddings,
                                                          freed: model.status.installedBytes > 0 ? model.status.installedBytes : SearchModelSpec.pinned.installedSize))
        }
        .confirmationDialog(String(localized: "Discard the partial download?", comment: "Confirmation title"), isPresented: $confirmingDiscard) {
            Button("Discard", role: .destructive) { model.discardPartial() }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: {
            Text("You’ll start from the beginning next time.")
        }
        .onChange(of: model.status.state) { old, new in announce(from: old, to: new) }
        .onChange(of: model.index?.ranking) { _, ranking in
            if ranking == true, model.status.isReady {
                AccessibilityNotification.Announcement(String(localized: "Indexing for search by meaning is complete.", comment: "VoiceOver announcement")).post()
            }
        }
    }

    // MARK: Rows

    private var retiredNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            NoticeLabel(Text(description: SearchModelText.migratedNotice), status: .info)
            Spacer(minLength: 8)
            Button("Dismiss") { model.dismissRetiredNotice() }
        }
    }

    /// Files that no longer match the pinned checksums are a damaged install, whichever way the engine reported them.
    private var state: SearchModelStatus.State {
        if case .unsupported(.verificationFailed) = model.status.state { return .damaged }
        return model.status.state
    }

    @ViewBuilder
    private var detail: some View {
        let status = model.status
        switch state {
        case .notInstalled:
            Text(description: SearchModelText.notInstalled)
        case .unsupported(let reason):
            ModelFailureLabel(text: SearchModelText.unsupported)
            Text(description: SearchModelText.unsupportedDetail(reason))
        case .downloading(let received, let total, _):
            Text(description: SearchModelText.progress(received: received, total: total, secondsRemaining: status.secondsRemaining))
        case .pausedForRecording(let received, let total):
            Text(description: SearchModelText.progress(received: received, total: total, secondsRemaining: nil))
            Text(description: SearchModelText.pausedForRecording)
        case .partial(let verified, let total):
            Text(description: SearchModelText.stopped(verified: verified, total: total))
            if let error = status.lastError { ModelFailureLabel(text: SearchModelText.failure(error)) }
        case .needsFile(let missing):
            Text(description: SearchModelText.importedPart(missing: missing))
            if let error = status.lastError { ModelFailureLabel(text: SearchModelText.failure(error)) }
        case .verifying:
            Text(description: SearchModelText.verifying)
        case .preparing:
            Text(description: SearchModelText.preparing)
        case .deleting:
            Text(description: SearchModelText.deleting)
        case .ready:
            if models.embeddings == .server {
                Text(description: SearchModelText.readyServerChosen)
            } else if models.embeddings == .none {
                Text(description: SearchModelText.readyKeywordChosen)
            } else if let index = model.index, !index.ranking {
                Text(description: SearchModelText.indexingTitle)
                Text(description: SearchModelText.indexing(index))
                if let pause = SearchModelText.pauseReason(index) { Text(description: pause) }
            } else {
                Text(description: SearchModelText.ready(installedBytes: status.installedBytes))
            }
            if let index = model.index, index.skipped > 0, models.embeddings == .onDeviceModel { Text(description: SearchModelText.skipped(index.skipped)) }
        case .damaged:
            ModelFailureLabel(text: SearchModelText.damaged)
        case .failed(let error):
            ModelFailureLabel(text: SearchModelText.failure(error))
        }
    }

    @ViewBuilder
    private var controls: some View {
        let status = model.status
        switch state {
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
        case .downloading(let received, let total, _), .pausedForRecording(let received, let total):
            let paused: Bool = { if case .pausedForRecording = state { true } else { false } }()
            let spoken = SearchModelText.spokenProgress(received: Self.coarse(received), total: total, secondsRemaining: status.secondsRemaining.map { Self.coarse($0, step: 10) })
            HStack(spacing: 8) {
                // A pause is a symbol and a grey bar, not only a second line of text.
                if paused { Image(systemName: "pause.circle").foregroundStyle(.secondary).accessibilityHidden(true) }
                ProgressView(value: status.fraction ?? 0)
                    .frame(width: 120)
                    .tint(paused ? .secondary : nil)
                    .accessibilityLabel(Text("Download progress"))
                    .accessibilityValue(Text(paused ? SearchModelText.spokenPaused(spoken) : spoken))
                ActionButton("Cancel") { model.cancel() }
            }
        case .partial:
            HStack(spacing: 8) {
                Button("Resume") { model.download() }
                Button("Discard…") { confirmingDiscard = true }
            }
        case .needsFile(let missing):
            HStack(spacing: 8) {
                switch missing {
                case .tokenizer:
                    Button("Choose tokenizer.json…") { model.chooseFilesToImport(missing: .tokenizer) }
                    Button("Download Tokenizer") { model.downloadTokenizer() }
                case .weights:
                    Button("Choose model.safetensors…") { model.chooseFilesToImport(missing: .weights) }
                    Button("Download Weights") { model.download() }
                }
                Button("Discard…") { confirmingDiscard = true }
            }
        case .verifying where status.cancellable:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).accessibilityLabel(Text(Self.busyLabel(status.state)))
                ActionButton("Cancel") { model.cancel() }
            }
        case .verifying, .preparing, .deleting:
            ProgressView().controlSize(.small)
                .accessibilityLabel(Text(Self.busyLabel(status.state)))
        case .ready:
            HStack(spacing: 8) {
                if models.embeddings == .server { Button("Use This Mac Instead") { Task { await models.useSearchModelHere(recorder) } } }
                else if models.embeddings == .none { Button("Use for Search") { Task { await models.useSearchModelHere(recorder) } } }
                else if let index = model.index, !index.ranking {
                    ProgressView(value: index.fraction)
                        .frame(width: 100)
                        .accessibilityLabel(Text("Indexing progress"))
                        .accessibilityValue(Text(index.fraction, format: .percent.precision(.fractionLength(0))))
                } else {
                    StatusSymbol.ok.image
                }
                Button("Delete…") { confirmingDelete = true }
            }
        case .damaged:
            HStack(spacing: 8) {
                Button("Try Again") { model.retry() }
                Button("Delete…") { confirmingDelete = true }
            }
        case .failed(let error):
            HStack(spacing: 8) {
                if SearchModelText.isDiskFull(error) { Button("Open Storage Settings") { Permissions.open(.storage) }.wrapsToTwoLines() }
                // Files already on this Mac (a model that stopped working): check them again; otherwise download.
                Button("Try Again") { if model.hasFilesOnDisk { model.retry() } else { model.download() } }
                if SearchModelText.offersImport(error) { Button("Import from a File…") { model.chooseFilesToImport() } }
                if model.hasFilesOnDisk { Button("Delete…") { confirmingDelete = true } }
            }
        }
    }

    /// VoiceOver hears the value when it changes: round it so it is not read every few kilobytes.
    private static func coarse(_ value: Int, step: Int = 10_000_000) -> Int { value / step * step }

    private static func busyLabel(_ state: SearchModelStatus.State) -> String {
        switch state {
        case .verifying: SearchModelText.verifying
        case .deleting: SearchModelText.deleting
        default: SearchModelText.preparing
        }
    }

    private func announce(from old: SearchModelStatus.State, to new: SearchModelStatus.State) {
        switch new {
        case .ready where old != .ready:
            AccessibilityNotification.Announcement(String(localized: "The search model is ready.", comment: "VoiceOver announcement")).post()
        case .failed(let error):
            AccessibilityNotification.Announcement(SearchModelText.failure(error)).post()
        case .damaged:
            AccessibilityNotification.Announcement(SearchModelText.damaged).post()
        default:
            break
        }
    }
}

/// The facts about the model: who made it, where it comes from, how it was checked, its license and the third-party code that runs it.
struct SearchModelAboutSheet: View {
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: SearchModelText.modelName).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            fact(String(localized: "Made by Google. It turns passages and questions into numbers so that Vauta can find the passages that mean the same, in any language and across languages.",
                        comment: "About the search model"))
            fact(String(localized: "Source: \(SearchModelManifest.repository) on Hugging Face, revision \(SearchModelText.shortRevision). Vauta downloads only the text part (\(SearchModelText.downloadSize)) and checks every piece against checksums it carries before using it. The weights are Google’s original ones, unchanged.",
                        comment: "About the search model; the arguments are the repository and the revision (not translated) and the download size"))
            fact(String(localized: "It runs on this Mac with Apple’s MLX. Your meetings and documents are never sent anywhere.",
                        comment: "About the search model"))
            fact(String(localized: "License: Apache License 2.0, as stated on the model card at this revision. Google’s Gemma terms are linked for information. Google doesn’t endorse Vauta.",
                        comment: "About the search model"))
            VStack(alignment: .leading, spacing: 4) {
                Link(String(localized: "Model card on Hugging Face", comment: "Link"), destination: SearchModelText.modelCard)
                Link(String(localized: "Gemma Terms of Use", comment: "Link"), destination: SearchModelText.gemmaTerms)
                Link(String(localized: "Gemma Prohibited Use Policy", comment: "Link"), destination: SearchModelText.gemmaPolicy)
                Link(String(localized: "MLX (MIT license, modified)", comment: "Link to the modified build of the MLX project that runs the search model"), destination: SearchModelText.mlxRepository)
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

private struct ShowsLinksLineKey: EnvironmentKey { static let defaultValue = LinksRelease.shipsOnAnyBackend }

extension EnvironmentValues {
    /// Whether Settings → Models says that the search model also finds tasks and decisions like earlier ones. Follows `LinksRelease`.
    var showsLinksLine: Bool {
        get { self[ShowsLinksLineKey.self] }
        set { self[ShowsLinksLineKey.self] = newValue }
    }
}
