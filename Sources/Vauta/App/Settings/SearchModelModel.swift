// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import Observation

/// What Settings → Models shows and does about the optional search model (EmbeddingGemma 2): the status the controller pushes, how
/// much of the library is indexed, and the actions. Settings → Models and the Ask tab show it.
@MainActor
@Observable
final class SearchModelModel {
    private(set) var status = SearchModelStatus()
    /// How much of the meetings and documents has vectors for the search model (nil while it is not in use).
    private(set) var index: LLMService.SearchIndexStatus?
    /// Apple's on-device embeddings were removed and the saved choice was moved to keyword search: Settings says so once.
    private(set) var showsRetiredNotice: Bool

    /// The saved choice for how Ask finds passages (read when the model service publishes its status).
    private(set) var embeddingsChoice: ModelProviderSettings.Embeddings
    /// Ask's empty state offered the model once; the person closed the offer.
    var offerDismissed = false {
        didSet { defaults.set(offerDismissed, forKey: Self.offerDismissedKey) }
    }
    static let offerDismissedKey = "searchModelOfferDismissed"

    @ObservationIgnored private let controller: SearchModelController
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var preloadTask: Task<Void, Never>?

    init(controller: SearchModelController = .shared, defaults: UserDefaults = .standard, hasServerConfig: Bool = false) {
        self.controller = controller
        self.defaults = defaults
        // Loading the choice is what migrates the retired Apple option (and sets the flag of the notice), so it comes first.
        embeddingsChoice = ModelProviderSettings.load(defaults: defaults, hasServerConfig: hasServerConfig).embeddings
        showsRetiredNotice = defaults.bool(forKey: ModelProviderSettings.retiredAppleNLKey)
        offerDismissed = defaults.bool(forKey: Self.offerDismissedKey)
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

    func llmStatusChanged(_ llm: LLMService.Status) {
        index = llm.searchIndex
        embeddingsChoice = ModelProviderSettings.load(defaults: defaults, hasServerConfig: llm.configured).embeddings
        showsRetiredNotice = defaults.bool(forKey: ModelProviderSettings.retiredAppleNLKey)
    }

    /// How Ask finds passages right now, for the label under the question. nil while a model server's embeddings do it
    /// (the label is about the search model). The rule is per corpus: meetings can rank by meaning while documents still index.
    enum AskMode: Equatable {
        case meaning
        /// One corpus ranks by meaning, the other still indexes (`percent` of it).
        case meaningIndexing(Corpus, percent: Int)
        /// Keywords while the corpora index.
        case indexing(percent: Int)
        case keyword
    }

    enum Corpus: Equatable { case meetings, documents }

    var askMode: AskMode? {
        if embeddingsChoice == .server { return nil }
        guard embeddingsChoice == .onDeviceModel, status.isReady, let index else { return .keyword }
        if index.ranking { return .meaning }
        func percent(_ coverage: SemanticRanker.Coverage) -> Int { min(99, Int((coverage.fraction * 100).rounded(.down))) }   // never "100%" while something is missing
        switch (index.meetingsRanking, index.documentsRanking) {
        case (true, false): return .meaningIndexing(.documents, percent: percent(index.documents))
        case (false, true): return .meaningIndexing(.meetings, percent: percent(index.meetings))
        default:
            let behind = [index.meetings, index.documents].filter { $0.total > 0 && !$0.isComplete }
            return .indexing(percent: percent(behind.min { $0.fraction < $1.fraction } ?? index.meetings))
        }
    }

    /// The documents' coverage while the search model still indexes them (Settings → Documents says how far it is).
    var documentsBackfill: SemanticRanker.Coverage? {
        guard embeddingsChoice == .onDeviceModel, status.isReady, let index, !index.documents.isComplete, index.documents.total > 0 else { return nil }
        return index.documents
    }

    /// Ask's empty state offers the download once: not installed, supported, and nothing else chosen.
    var offersDownload: Bool {
        guard !offerDismissed, embeddingsChoice != .server else { return false }
        if case .notInstalled = status.state { return true }
        return false
    }

    /// The Settings card is shown whenever this Mac can run the model (so the download is always there to click, whatever the
    /// saved choice), and also when the person chose it, or something about it is going on or installed.
    func showsCard(choice: ModelProviderSettings.Embeddings) -> Bool {
        if choice == .onDeviceModel || showsRetiredNotice { return true }
        if case .unsupported(.unsupportedHardware) = status.state { return false }
        return true
    }

    /// Files of the model (installed or half downloaded) are on this Mac, so there is something to delete.
    var hasFilesOnDisk: Bool { status.installedBytes > 0 }

    // MARK: Actions (each one is a click)

    func download() { Task { await controller.download() } }
    /// Only the 32 MB tokenizer, after the weights were imported from a file.
    func downloadTokenizer() { Task { await controller.download(tokenizerOnly: true) } }
    func cancel() { Task { await controller.cancel() } }
    func discardPartial() { Task { await controller.discard() } }
    func delete() { Task { await controller.delete() } }
    /// Try Again with files already on this Mac: checks them again (or, when damaged, deletes and downloads them again).
    func retry() { Task { await controller.retry() } }
    /// Loads the model in the background so the next question does not wait (the controller decides whether the Mac is quiet).
    /// Called when Ask or the sidebar search appears; waits 300 ms so a quick pass through the screen costs nothing.
    func preload() {
        preloadTask?.cancel()
        let controller = controller
        preloadTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await controller.preload()
        }
    }
    func importFiles(_ urls: [URL]) { Task { await controller.importFiles(urls) } }
    /// Lets the person choose the model files, then installs them (verified like a download).
    func chooseFilesToImport(missing: SearchModelStatus.MissingPart? = nil) {
        let urls = SearchModelImportPanel.chooseFiles(missing: missing)
        if !urls.isEmpty { importFiles(urls) }
    }

    func dismissRetiredNotice() {
        defaults.removeObject(forKey: ModelProviderSettings.retiredAppleNLKey)
        showsRetiredNotice = false
    }
}

/// The Mac's state as the search model's pause rules need it, readable from any thread (the recorder writes the recording part).
final class SearchEnvironmentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var recording = false
    private var stoppedAt: Date?

    func set(recording: Bool, stoppedAt: Date?) {
        lock.withLock {
            self.recording = recording
            self.stoppedAt = stoppedAt
        }
    }

    func snapshot() -> IndexerEnvironment {
        let (recording, stoppedAt) = lock.withLock { (self.recording, self.stoppedAt) }
        return IndexerEnvironment(isRecording: recording, recordingStoppedAt: stoppedAt, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                  thermalState: ProcessInfo.processInfo.thermalState, onBattery: DocumentsModel.onBattery)
    }
}

/// A weak reference the controller's status handler can hold from any thread.
private final class WeakModel: @unchecked Sendable {
    weak var model: SearchModelModel?
    init(_ model: SearchModelModel) { self.model = model }
}

extension SearchModelModel {
    /// For `Vauta render-ui` and tests: a state of the model and of its index, without the controller or the disk.
    func installSnapshotState(_ status: SearchModelStatus, index: LLMService.SearchIndexStatus? = nil, choice: ModelProviderSettings.Embeddings = .onDeviceModel,
                              retiredNotice: Bool = false) {
        self.status = status
        self.index = index
        embeddingsChoice = choice
        showsRetiredNotice = retiredNotice
    }
}
