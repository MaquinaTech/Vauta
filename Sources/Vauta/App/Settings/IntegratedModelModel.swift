// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import Observation

/// What Settings → Models shows and does about the optional integrated language model (Gemma 4 E4B): the status the controller pushes
/// and the actions. Nothing here downloads on its own: every action is a click.
@MainActor
@Observable
final class IntegratedModelModel {
    private(set) var status = LanguageModelStatus()
    /// Who does the live work of a recording when this model is the provider.
    private(set) var liveTasks: ModelProviderSettings.LiveTasks
    /// The memory and GPU of this Mac, as the gate reads them (snapshots set another).
    private(set) var unsupported: LanguageModelUnsupported?
    /// Counts the times the controller saved the chat choice (a download, an import or "Use for Minutes"): Settings → Models takes the saved choice then.
    private(set) var chatChoiceRevision = 0

    @ObservationIgnored private let controller: LanguageModelController
    @ObservationIgnored private let defaults: UserDefaults
    /// Called after "While recording" is saved: the model that answers live may be another one now (the recorder re-checks at once).
    @ObservationIgnored var onLiveTasksChanged: (() -> Void)?

    init(controller: LanguageModelController = .shared, defaults: UserDefaults = .standard) {
        self.controller = controller
        self.defaults = defaults
        liveTasks = ModelProviderSettings.liveTasks(defaults: defaults)
        unsupported = LanguageModelGate.unsupported(gpuSupported: LanguageModelGate.gpuSupported)
    }

    /// Connects to the controller's status (the recorder starts the controller itself, before the model service reads its providers).
    func start() {
        let controller = controller
        let holder = WeakModel(self)
        Task {
            await controller.setStatusHandler { status in
                Task { @MainActor in holder.model?.status = status }
            }
        }
    }

    /// The integrated option is offered on Macs that meet the gate (16 GB, a supported GPU), and where the model self-test did not
    /// fail; a Mac below it sees a note instead.
    var isOffered: Bool {
        if unsupported != nil { return false }
        if case .unsupported = status.state { return false }
        return true
    }

    /// Why the option is not offered (nil when it is).
    var unsupportedReason: LanguageModelUnsupported? {
        if let unsupported { return unsupported }
        if case .unsupported(let reason) = status.state { return reason }
        return nil
    }

    /// The card is shown when the integrated model is the chosen provider, files are on this Mac, or something is going on, so Delete
    /// is always reachable.
    func showsCard(provider: ModelProviderChoice) -> Bool {
        if provider == .integrated { return true }
        switch status.state {
        case .notInstalled, .unsupported: return hasFilesOnDisk
        default: return true
        }
    }

    var hasFilesOnDisk: Bool { status.installedBytes > 0 }

    /// A download, conversion or repair is in progress (including waiting for a recording to end).
    var isBusy: Bool {
        switch status.state {
        case .downloading, .checkingPartial, .pausedForRecording, .importing, .verifying, .preparing, .repairing, .deleting: true
        default: false
        }
    }

    // MARK: Actions (each one is a click)

    func download() { Task { await controller.download() } }
    func pause() { Task { await controller.pause() } }
    func cancelImport() { Task { await controller.cancelImport() } }
    func cancelAndDiscard() { Task { await controller.cancelAndDiscard() } }
    func discardPartial() { Task { await controller.discard() } }
    func delete() { Task { await controller.delete() } }
    func repair() { Task { await controller.repair() } }
    func retry() { Task { await controller.retry() } }
    func useForMinutes() { Task { await controller.useForMinutes() } }
    func importFiles(_ urls: [URL]) { Task { await controller.importFiles(urls) } }

    /// Lets the person choose the model files, then installs them (verified like a download).
    func chooseFilesToImport(missing: LanguageModelStatus.MissingPart? = nil) {
        let urls = IntegratedModelImportPanel.chooseFiles(missing: missing)
        if !urls.isEmpty { importFiles(urls) }
    }

    func setLiveTasks(_ tasks: ModelProviderSettings.LiveTasks) {
        ModelProviderSettings.saveLiveTasks(tasks, defaults: defaults)
        liveTasks = tasks
        onLiveTasksChanged?()
    }

    func refreshLiveTasks() { liveTasks = ModelProviderSettings.liveTasks(defaults: defaults) }

    /// The controller saved the integrated model as the chat choice.
    func chatChoiceChanged() {
        refreshLiveTasks()
        chatChoiceRevision += 1
    }
}

/// A weak reference the controller's status handler can hold from any thread.
private final class WeakModel: @unchecked Sendable {
    weak var model: IntegratedModelModel?
    init(_ model: IntegratedModelModel) { self.model = model }
}

extension IntegratedModelModel {
    /// For `Vauta render-ui` and tests: a state of the model, without the controller or the disk.
    func installSnapshotState(_ status: LanguageModelStatus, unsupported: LanguageModelUnsupported? = nil,
                              liveTasks: ModelProviderSettings.LiveTasks = .integrated) {
        self.status = status
        self.unsupported = unsupported
        self.liveTasks = liveTasks
    }
}
