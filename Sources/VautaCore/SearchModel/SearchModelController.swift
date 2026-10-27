// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
internal import VautaMLX

/// What the app does when the model appears or goes away.
public struct SearchModelHooks: Sendable {
    /// The model was installed (and the embeddings choice adopted it): the service re-reads its providers and starts indexing.
    public var installed: @Sendable () async -> Void
    /// The model is about to be deleted: the service stops the embedding work that uses it (before the files go).
    public var removing: @Sendable () async -> Void
    /// The model was deleted: the service drops the vectors of its space.
    public var removed: @Sendable () async -> Void

    public init(installed: @escaping @Sendable () async -> Void = {}, removing: @escaping @Sendable () async -> Void = {},
                removed: @escaping @Sendable () async -> Void = {}) {
        self.installed = installed
        self.removing = removing
        self.removed = removed
    }
}

/// The state machine of the optional search model: not installed, downloading (pausing during recordings), partial, verifying,
/// preparing, ready, failed, deleting. It starts nothing on its own: constructing it and `start()` read the disk and make no
/// network request; only `download()` (the person's click) does.
public actor SearchModelController {
    private let store: SearchModelStore
    private let engine: SearchModelEngine
    private let access: SearchModelAccess
    private let defaults: UserDefaults
    private let log: NetworkActivityLog
    private let protocolClasses: [AnyClass]?
    private let supported: @Sendable () -> Bool
    private let appBuild: String
    private let meter = SearchModelProgressMeter()

    private var session: AuditedSession?
    private var task: Task<Void, Never>?
    /// The background load of an installed model (full check, tokenizer, encoder, kernels).
    private var prepTask: Task<Void, Never>?
    private let importer: @Sendable ([URL], SearchModelStore, String) async throws -> SearchModelImporter.Outcome
    private var serverConfigured: @Sendable () async -> Bool = { false }
    /// Which download the callbacks belong to: a delete or a new download makes the old one's late callbacks do nothing.
    private var runID = 0
    private var hooks = SearchModelHooks()
    private var handler: (@Sendable (SearchModelStatus) -> Void)?
    public private(set) var status = SearchModelStatus()

    /// The shared controller of the app.
    public static let shared = SearchModelController()

    init(store: SearchModelStore = SearchModelStore(), engine: SearchModelEngine? = nil, access: SearchModelAccess = .shared,
         defaults: UserDefaults = .standard, log: NetworkActivityLog = .shared, protocolClasses: [AnyClass]? = nil,
         supported: @escaping @Sendable () -> Bool = { MLXRuntime.isSupported },
         appBuild: String = SearchModelDownloader.currentBuild,
         importer: @escaping @Sendable ([URL], SearchModelStore, String) async throws -> SearchModelImporter.Outcome = {
             try await SearchModelImporter.importFiles($0, store: $1, appBuild: $2)
         }) {
        self.importer = importer
        self.store = store
        self.engine = engine ?? SearchModelEngine(store: store)
        self.access = access
        self.defaults = defaults
        self.log = log
        self.protocolClasses = protocolClasses
        self.supported = supported
        self.appBuild = appBuild
    }

    public func setHooks(_ hooks: SearchModelHooks) { self.hooks = hooks }

    /// Whether a model server is configured: without a saved choice such a person keeps their server for search, so installing
    /// the model must not move them.
    public func setServerConfigProvider(_ provider: @escaping @Sendable () async -> Bool) { serverConfigured = provider }

    public func setStatusHandler(_ handler: @escaping @Sendable (SearchModelStatus) -> Void) {
        self.handler = handler
        handler(status)
    }

    /// The engine, for the embedding model and tests.
    var searchEngine: SearchModelEngine { engine }

    private func set(_ state: SearchModelStatus.State, rate: Double? = nil, remaining: Int? = nil, error: SearchModelError? = nil) {
        status.state = state
        status.lastError = error
        status.bytesPerSecond = rate
        status.secondsRemaining = remaining
        status.installedBytes = store.bytesOnDisk()
        handler?(status)
    }

    // MARK: Start

    /// Reads the disk. No network. Excludes the folder from backups again (a rename can drop the attribute).
    public func start() async {
        try? store.prepare()
        guard supported() else {
            access.set(.unavailable(.unsupportedHardware), model: nil)
            set(.unsupported(.unsupportedHardware))
            return
        }
        access.setPreloader { [weak self] in Task { await self?.preload() } }
        let engine = engine
        await engine.setUnusableHandler { [weak self] error in
            Task { await self?.becameUnusable(error) }
        }
        switch store.disk() {
        case .installed:
            if SearchModelVerifier.quickCheck(file: store.weightsURL, spec: store.spec),
               SearchModelVerifier.quickCheckTokenizer(file: store.tokenizerURL, spec: store.spec) {
                markInstalled()
                await preload()
            } else {
                access.set(.unavailable(.verificationFailed), model: nil)
                set(.damaged)
            }
        case .partial:
            set(restingState())
            access.set(.notInstalled, model: nil)
        case .empty:
            access.set(.notInstalled, model: nil)
            set(.notInstalled)
        }
    }

    private func markInstalled() {
        access.set(.installed, model: GemmaEmbeddingModel(engine: engine))
        set(.ready)
    }

    private func becameUnusable(_ error: SearchModelError) {
        // Only an installed model can become unusable. A report that arrives late (bulk embedding that was suspended between two
        // batches when the person deleted the model) must not turn a deleted model into a damaged one.
        switch status.state {
        case .ready, .preparing, .verifying: break
        default: return
        }
        let reason: SearchModelUnavailableReason = switch error {
        case .unsupported: .unsupportedHardware
        case .selfTestFailed, .encoderFailed: .selfTestFailed
        default: .verificationFailed
        }
        access.set(.unavailable(reason), model: nil)
        switch error {
        case .mismatch, .tokenizerUnreadable: set(.damaged)
        case .encoderFailed: set(.failed(.encoderFailed))
        default:
            // Files that cannot be trusted are a damaged install, not a Mac that cannot run the model.
            set(reason == .verificationFailed ? .damaged : .unsupported(reason))
        }
    }

    // MARK: Preparing

    /// Loads an installed model in the background (the full check of its files, the tokenizer, the encoder and the GPU kernels, about
    /// 3 s) so that the first question after launch does not wait for it. Called after `start()` and, debounced, when Ask or the
    /// sidebar search appears. Does nothing unless the model is ready and not loaded, and the Mac is quiet: not during a recording
    /// (or two minutes after), in Low Power Mode or when it is hot; on battery it does preload (loading once is not bulk
    /// embedding). The status says "preparing" while it runs.
    public func preload() async {
        guard task == nil, prepTask == nil, status.state == .ready, supported(), !(await engine.isLoaded) else { return }
        let policy = IndexerPolicy.decide(access.environment)
        guard policy.pause == nil else { return }
        let run = runID
        let engine = engine
        set(.preparing)
        prepTask = Task { [weak self] in
            var failure: SearchModelError?
            do { try await engine.prepare() } catch let error as SearchModelError { failure = error } catch is CancellationError { failure = nil } catch { failure = .encoderFailed }
            await self?.preloaded(run: run, failure: failure)
        }
    }

    private func preloaded(run: Int, failure: SearchModelError?) {
        guard run == runID else { return }
        prepTask = nil
        guard status.state == .preparing else { return }
        if let failure { becameUnusable(failure) } else { set(.ready) }
    }

    private func estimatedVerifiedBytes() -> Int {
        var bytes = 0
        if (try? SearchModelVerifier.verifyTokenizer(file: store.stagedTokenizer, spec: store.spec)) != nil { bytes += store.spec.tokenizerSize }
        if let size = (try? FileManager.default.attributesOfItem(atPath: store.stagedWeightsPart.path)[.size]) as? Int {
            let blocks = max(0, size - store.spec.headerSize) / store.spec.blockSize
            bytes += min(store.spec.spanSize, blocks * store.spec.blockSize)
        }
        if FileManager.default.fileExists(atPath: store.stagedWeights.path) { bytes = max(bytes, store.spec.downloadSize - store.spec.tokenizerSize) }
        return min(bytes, store.spec.downloadSize)
    }

    /// What a stopped, interrupted or imported-in-part staging area shows: the weights alone are verified and staged (an import
    /// without the tokenizer: a download fetches the tokenizer first, so it never leaves this) or a partial download.
    private func restingState() -> SearchModelStatus.State {
        let fm = FileManager.default
        if fm.fileExists(atPath: store.stagedWeights.path), !fm.fileExists(atPath: store.stagedTokenizer.path) { return .needsFile(missing: .tokenizer) }
        return .partial(verified: estimatedVerifiedBytes(), total: store.spec.downloadSize)
    }

    // MARK: Download

    /// Starts (or resumes) the download. The person asked for it. One at a time. `tokenizerOnly` fetches just the 32 MB tokenizer
    /// (after the weights were imported from a file).
    public func download(tokenizerOnly: Bool = false) {
        guard task == nil, supported() else { return }
        let downloader = SearchModelDownloader(session: ensureSession(), store: store, appBuild: appBuild)
        let total = tokenizerOnly ? store.spec.tokenizerSize : store.spec.downloadSize
        meter.reset()
        runID += 1
        let run = runID
        set(.downloading(received: 0, total: total, phase: .tokenizer))
        let meter = meter
        let controller = self
        task = Task {
            do {
                try await downloader.run(tokenizerOnly: tokenizerOnly, progress: { p in
                    var p = p
                    if tokenizerOnly { p.total = total }
                    let now = ProcessInfo.processInfo.systemUptime
                    guard let tick = meter.record(bytes: p.received, total: p.total, at: now) else { return }
                    Task { await controller.progressed(p, rate: tick.rate, remaining: tick.remaining, run: run) }
                }, beforeBlock: { try await controller.waitWhileRecording() })
                await controller.finishedInstall(run: run)
            } catch is CancellationError {
                await controller.stopped(run: run)
            } catch let error as SearchModelError {
                await controller.failed(error, run: run)
            } catch {
                await controller.failed(.ioError, run: run)
            }
        }
    }

    private func ensureSession() -> AuditedSession {
        if let session { return session }
        let made = SearchModelDownloader.makeSession(protocolClasses: protocolClasses, log: log)
        session = made
        return made
    }

    private func progressed(_ p: SearchModelProgress, rate: Double?, remaining: Int?, run: Int) {
        guard task != nil, run == runID else { return }
        set(.downloading(received: p.received, total: p.total, phase: p.phase), rate: rate, remaining: remaining)
    }

    /// Holds the download while a recording runs (and for two minutes after): the person started the download, so it continues
    /// by itself. Low Power Mode and battery do not stop it.
    private func waitWhileRecording() async throws {
        var paused = false
        var phase = SearchModelProgress.Phase.weights   // what was being fetched when the pause began
        while IndexerPolicy.decide(access.environment).pause == .recording {
            try Task.checkCancellation()
            if !paused {
                paused = true
                if case .downloading(let r, let t, let p) = status.state {
                    phase = p
                    set(.pausedForRecording(received: r, total: t))
                }
            }
            try await Task.sleep(for: .seconds(1))
        }
        if paused, case .pausedForRecording(let r, let t) = status.state { set(.downloading(received: r, total: t, phase: phase)) }
    }

    /// Stops the download and keeps the verified blocks (Resume continues from them).
    public func cancel() {
        task?.cancel()
    }

    /// Deletes what a stopped download left.
    public func discard() {
        guard task == nil else { return }
        store.discardStaging()
        set(.notInstalled)
    }

    private func stopped(run: Int) async {
        guard run == runID else { return }
        task = nil
        session?.invalidateAndCancel()
        session = nil
        set(restingState())
    }

    private func failed(_ error: SearchModelError, run: Int) async {
        guard run == runID else { return }
        task = nil
        session?.invalidateAndCancel()
        session = nil
        // Nothing was installed. Blocks that were verified stay for Resume, unless the files did not match.
        if error == .mismatch {
            store.discardStaging()
            set(.failed(error))
            return
        }
        let verified = estimatedVerifiedBytes()
        if error == .offline || error == .hostNotAllowed, verified > 0 {
            set(restingState(), error: error)
        } else {
            set(.failed(error))
        }
    }

    private func finishedInstall(run: Int) async {
        guard run == runID else { return }
        task = nil
        session?.invalidateAndCancel()
        session = nil
        await adopt(source: "download", run: run)
    }

    /// The files are in place: prepare (self-test, load, warm up) and switch the embeddings choice to the model.
    private func adopt(source: String, run: Int) async {
        status.source = source
        status.cancellable = false
        set(.verifying)
        guard case .installed = store.disk() else { set(.failed(.ioError)); return }
        set(.preparing)
        do {
            try await engine.prepare()
        } catch let error as SearchModelError {
            guard run == runID else { return }
            becameUnusable(error)
            return
        } catch {
            guard run == runID else { return }
            set(.failed(.encoderFailed))
            return
        }
        // Deleted while it was preparing: the delete already reset everything.
        guard run == runID else { return }
        markInstalled()
        _ = ModelProviderSettings.adoptSearchModel(defaults: defaults, hasServerConfig: await serverConfigured())
        await hooks.installed()
    }

    /// Try Again after something went wrong with files that are already on this Mac. Damaged files are deleted and downloaded
    /// again; otherwise the model is checked and loaded again. Without files it is a plain download.
    public func retry() async {
        guard task == nil, prepTask == nil else { return }
        guard case .installed = store.disk() else { download(); return }
        if status.state == .damaged {
            await delete()
            download()
        } else {
            await engine.unload()
            runID += 1
            await adopt(source: status.source ?? "download", run: runID)
        }
    }

    // MARK: Import

    /// Installs from files the person chose. Nothing goes over the network. Cancel (and Delete) stop the work itself.
    public func importFiles(_ urls: [URL]) async {
        guard task == nil, prepTask == nil, supported() else { return }
        runID += 1
        let run = runID
        status.source = "import"
        status.cancellable = true
        set(.verifying)
        let store = store, build = appBuild, importer = importer
        let work = Task.detached { try await importer(urls, store, build) }
        // Cancelling `task` cancels the detached import (a plain child would not inherit the cancellation).
        task = Task { await withTaskCancellationHandler { _ = await work.result } onCancel: { work.cancel() } }
        let result = await work.result
        // Deleted while it ran: the delete owns the state from here.
        guard run == runID else { return }
        task = nil
        status.cancellable = false
        switch result {
        case .success(.installed): await adopt(source: "import", run: run)
        case .success(.needsTokenizer): set(.needsFile(missing: .tokenizer))
        case .success(.needsWeights): set(.needsFile(missing: .weights))
        case .failure(let error):
            if error is CancellationError {
                if estimatedVerifiedBytes() == 0 {
                    store.discardStaging()
                    set(.notInstalled)
                } else {
                    set(restingState())
                }
            } else {
                set(.failed((error as? SearchModelError) ?? .ioError))
            }
        }
    }

    // MARK: Delete

    /// Removes the model and its vectors' reason to exist: embeddings go back to keyword search if they used it.
    public func delete() async {
        runID += 1   // the late callbacks of a download or an import that was running do nothing
        status.cancellable = false
        // Embedding work that uses the model stops first; its files go after.
        await hooks.removing()
        let running = task, preparing = prepTask
        running?.cancel()
        preparing?.cancel()
        session?.invalidateAndCancel()
        session = nil
        set(.deleting)
        // The work that was running ends before its files go (a cancelled import must not write after the delete).
        await running?.value
        await preparing?.value
        task = nil
        prepTask = nil
        access.set(.notInstalled, model: nil)
        await engine.unload()
        store.delete()
        _ = ModelProviderSettings.dropSearchModel(defaults: defaults)
        set(.notInstalled)
        await hooks.removed()
    }
}

extension ModelProviderSettings {
    /// After an install: a person on keyword search (or on the retired Apple option, already migrated to it) moves to the model;
    /// starting the download already said they want it. Someone who chose a model server keeps it, and so does someone who
    /// never chose and has a server configured (their effective choice is the server). Only the embeddings key is written: the
    /// chat choice is never touched. Returns whether the choice changed.
    @discardableResult
    public static func adoptSearchModel(defaults: UserDefaults = .standard, hasServerConfig: Bool = false) -> Bool {
        guard load(defaults: defaults, hasServerConfig: hasServerConfig).embeddings == .none else { return false }
        defaults.set(Embeddings.onDeviceModel.rawValue, forKey: embeddingsKey)
        return true
    }

    /// After the model is deleted: the choice goes back to keyword search if it used the model. Only the embeddings key is written.
    @discardableResult
    public static func dropSearchModel(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.string(forKey: embeddingsKey) == Embeddings.onDeviceModel.rawValue else { return false }
        defaults.set(Embeddings.none.rawValue, forKey: embeddingsKey)
        return true
    }
}
