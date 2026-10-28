// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import Observation

/// State of the "Set up a model server" guide. It polls for the server only between
/// `start()` and `stop()` (the sheet's lifetime), and only on LM Studio's and Ollama's loopback ports.
@MainActor
@Observable
final class ModelGuideModel {
    enum Phase: Equatable {
        case guide
        case applying
        case done(Summary)
        case failed(String)
    }

    /// What was saved, for the final screen.
    struct Summary: Equatable {
        let serverName: String
        let mainModel: String
        /// Set when a different fast model was also configured.
        let fastModel: String?
        /// Search by meaning was switched to keyword search because the new server has no embedding model.
        let embeddingsOff: Bool
        /// Ask uses keyword search only (no embedding provider is in use).
        let keywordSearch: Bool
        /// The saved server answered with a problem (for example a model that is not loaded).
        let warning: String?
    }

    var app: LocalModelApp = .lmStudio {
        didSet {
            guard app != oldValue else { return }
            watcher.configuration.app = app
            refreshInstalled()
        }
    }
    /// Large Macs: also download the 9B model as the fast model (off = one model only).
    var includeFastModel = true {
        didSet { watcher.configuration.includeFastModel = includeFastModel }
    }
    var phase: Phase = .guide
    var status: SetupStatus = .searching
    private(set) var installedURL: URL?
    private(set) var freeBytes: Int64?

    let recommendation: ModelRecommendation
    let physicalMemory: UInt64
    private let watcher: ModelSetupWatcher
    private let scanner: any ServerScanning
    private let locate: @MainActor (LocalModelApp) -> URL?
    private let measureFreeSpace: @MainActor () -> Int64?
    /// Snapshots set the state by hand and must not poll.
    private let polls: Bool

    init(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory, scanner: any ServerScanning = LoopbackServerScanner(),
         polls: Bool = true, locate: @escaping @MainActor (LocalModelApp) -> URL? = ModelGuideModel.locateInstalled,
         freeSpace: @escaping @MainActor () -> Int64? = { DiskSpace.availableBytes() }) {
        self.physicalMemory = physicalMemory
        recommendation = ModelRecommendation(physicalMemory: physicalMemory)
        self.scanner = scanner
        watcher = ModelSetupWatcher(scanner: scanner, configuration: SetupConfiguration(app: .lmStudio, recommendation: recommendation))
        self.locate = locate
        measureFreeSpace = freeSpace
        self.polls = polls
        freeBytes = freeSpace()
        watcher.onUpdate = { [weak self] status in
            self?.status = status
            self?.refreshInstalled()
        }
        refreshInstalled()
    }

    // MARK: Lifecycle

    /// Starts watching for the server. `existing` is the saved server configuration (its embedding model is kept).
    func start(existing: LLMServerConfig?) {
        // Measured even when nothing is polled: the disk warning doesn't depend on the server.
        freeBytes = measureFreeSpace()
        refreshInstalled()
        guard polls, recommendation.hasRecommendation else { return }
        watcher.configuration.existing = existing
        watcher.start()
    }

    func stop() { watcher.stop() }

    var isWatching: Bool { watcher.isActive }

    /// Still before a successful save (also after a failed one): the server is worth watching.
    var isLookingForServer: Bool {
        if case .done = phase { false } else { true }
    }

    // MARK: Derived state

    var isInstalled: Bool { installedURL != nil }

    var serverRunning: Bool {
        switch status {
        case .searching, .serverNotRunning: false
        case .noSuitableModel, .contextTooSmall, .ready: true
        }
    }

    var modelFound: Bool {
        switch status {
        case .contextTooSmall, .ready: true
        default: false
        }
    }

    /// The steps by what they are: 1 install the app, 2 download the model, 3 start the server (and set the context),
    /// 4 use it. Ollama serves as soon as its app is open and its download command needs that, so it opens the app before
    /// the download; LM Studio's server is started once the model is there. When the model is already downloaded and
    /// its context is too small, the fix comes after the download for Ollama too: a step to do never sits before one
    /// that is done (the numbers would suggest downloading again).
    var stepOrder: [Int] {
        if case .contextTooSmall = status { return [1, 2, 3, 4] }
        return app == .ollama ? [1, 3, 2, 4] : [1, 2, 3, 4]
    }

    /// The number a step is shown with: its place in `stepOrder`.
    func number(of step: Int) -> Int { (stepOrder.firstIndex(of: step) ?? step - 1) + 1 }

    /// Steps 1 to 3 (install, download, start the server) are done on their own evidence; the first one not
    /// done, in the order they are shown, is the current step, so there is always exactly one next action. Step 4 (use it)
    /// is never finished here: it is the current step once a model was found, and the page then closes.
    func stepState(_ step: Int) -> GuideStepState {
        if step == 4 { return candidate == nil ? .upcoming : .current }
        // A model that is loaded with too little context is downloaded (step 2 is done); its fix is in step 3.
        var contextTooSmall = false
        if case .contextTooSmall = status { contextTooSmall = true }
        let done: [Int: Bool] = [1: isInstalled || serverRunning, 2: modelFound, 3: serverRunning && !contextTooSmall]
        guard let isDone = done[step] else { return .upcoming }
        if isDone { return .done }
        return stepOrder.first { done[$0] == false } == step ? .current : .upcoming
    }

    var candidate: SetupCandidate? {
        if case .ready(let candidate) = status { candidate } else { nil }
    }

    var models: [LocalModel] { recommendation.models(includeFast: includeFastModel) }

    var downloadGB: Double { recommendation.downloadGB(for: app, includeFast: includeFastModel) }

    var diskIsShort: Bool { DiskSpace.isShort(downloadGB: downloadGB, available: freeBytes) }

    /// The model's display name for an identifier a server reported.
    func displayName(of identifier: String) -> String {
        recommendation.acceptable.first { $0.matches(modelID: identifier) }?.displayName ?? identifier
    }

    // MARK: App

    func refreshInstalled() { installedURL = locate(app) }

    nonisolated static func locateInstalled(_ app: LocalModelApp) -> URL? {
        for id in app.bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        // The identifier may change between releases: fall back to the app's name.
        return LocalModelApp.applicationFolders().map { $0.appending(path: app.bundleFileName) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func openApp() {
        guard let url = installedURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func openWebsite() {
        NSWorkspace.shared.open(app.websiteURL)
    }

    // MARK: Using the model

    private var useTask: Task<Void, Never>?

    /// Starts `use` so that it can be cancelled while the connection test runs.
    func startUse(recorder: RecorderModel, settings: ModelsSettingsModel) {
        guard phase != .applying else { return }
        useTask = Task { await use(recorder: recorder, settings: settings) }
    }

    /// Stops a running `use`: the previous setup is put back and the guide shows its steps again.
    func cancelUse() { useTask?.cancel() }

    /// Saves the found server through the Settings model (validation, key rules, connection check), then switches
    /// "Write minutes with" to the server. Search by meaning stays as it is, unless it needs a model the server lacks.
    /// A context that turns out too small is not kept: the previous setup is restored and the guide shows the fix.
    func use(recorder: RecorderModel, settings: ModelsSettingsModel) async {
        guard let candidate, phase != .applying else { return }
        phase = .applying
        settings.loadIfNeeded(recorder)
        let previousConfig = recorder.serverConfig
        let previousSettings = settings.savedSettings
        let hadKey = recorder.hasServerKey
        settings.provider = .localServer
        settings.draft = ServerDraft(config: candidate.config)
        var embeddingsOff = false
        if settings.embeddings == .server && candidate.config.embeddingModel.isEmpty {
            settings.embeddings = .none
            embeddingsOff = true
        }
        await settings.apply(recorder)
        if Task.isCancelled {
            // Cancelled by the person: nothing is kept. The restore runs outside the cancelled task.
            await Task { await restore(previousConfig, previousSettings, recorder: recorder, settings: settings) }.value
            phase = .guide
            return
        }
        guard recorder.serverConfig == candidate.config, settings.savedSettings.chat == .server else {
            phase = .failed(settings.applyFeedback?.text ?? String(localized: "Couldn’t save the server settings.",
                                                                    comment: "Settings → Models apply error"))
            return
        }
        // The connection test has just run the model: a server that couldn't say which context it loads with (Ollama
        // reports it only for a running model) can now be asked.
        var warning = settings.applyFeedback.flatMap { $0.kind == .success ? nil : $0.text }
        if !candidate.contextVerified, let shortfall = await contextShortfallAfterTest() {
            // Writing minutes with a truncating context is worse than the previous setup: put it back, unless that
            // would lose a saved key (then the server stays, and the page says what is wrong).
            let keyWouldBeLost = hadKey && !recorder.hasServerKey
            if !keyWouldBeLost {
                await restore(previousConfig, previousSettings, recorder: recorder, settings: settings)
                phase = .guide
                return
            }
            warning = [Self.contextTitle(shortfall, name: displayName(of: shortfall.modelID)),
                       Self.contextDetail(shortfall)].joinedAsSentences()
        }
        stop()
        phase = .done(Summary(serverName: candidate.serverKind.displayName, mainModel: displayName(of: candidate.mainModel),
                              fastModel: candidate.fastModel == candidate.mainModel ? nil : displayName(of: candidate.fastModel),
                              embeddingsOff: embeddingsOff, keywordSearch: settings.embeddings == .none, warning: warning))
    }

    /// Looks at the servers again; the shortfall (and the status says so) when a model now reports less context than Vauta needs.
    private func contextShortfallAfterTest() async -> ContextShortfall? {
        guard polls else { return nil }
        let servers = await scanner.scan()
        let status = SetupEvaluation.evaluate(servers, configuration: watcher.configuration)
        guard case .contextTooSmall(let shortfall) = status else { return nil }
        self.status = status
        return shortfall
    }

    /// Puts the server and the "Write minutes with" choice back as they were before `use`.
    private func restore(_ config: LLMServerConfig?, _ saved: ModelProviderSettings, recorder: RecorderModel,
                         settings: ModelsSettingsModel) async {
        _ = await recorder.setServerConfig(config, embeddingsOnServer: saved.embeddings == .server)
        saved.save()
        await recorder.llm?.configurationChanged()
        settings.revert(recorder)
    }

    static func contextTitle(_ shortfall: ContextShortfall, name: String) -> String {
        contextTitle(current: shortfall.current, name: name)
    }

    static func contextTitle(current: Int, name: String) -> String {
        String(localized: "\(name)’s context is too short (\(tokens(current)))",
               comment: "Model guide status title when a model has too little context; arguments are a model name and a token count like “4K”")
    }

    static func contextDetail(_ shortfall: ContextShortfall) -> String { contextDetail(required: shortfall.required) }

    static func contextDetail(required: Int) -> String {
        String(localized: "Vauta needs at least \(tokens(required)).", comment: "Model guide status detail; the argument is a token count")
    }

    /// A context length the way the rest of the guide writes it: 32,768 is "32K".
    static func tokens(_ count: Int) -> String {
        count > 0 && count % 1024 == 0 ? "\(count / 1024)K" : count.formatted()
    }
}
