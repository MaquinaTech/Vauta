// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
internal import VautaMLX

/// The state machine of the optional language model behind Settings → Models: not installed, downloading (pausing while a recording
/// runs and for two minutes after), checking what a paused download kept, partial, importing, waiting for the other file, verifying,
/// preparing, ready, damaged, repairing, failed, deleting. It starts nothing on its own: `start()` reads the disk and makes no
/// network request; only `download()`, `importFiles(_:)` and `repair()` (the person's clicks) do. When the engine finds the installed
/// files damaged, the controller says so and the model stops being offered, so chat goes back to Apple's model.
///
/// ```
/// notInstalled ──Download──▶ [preflight] ──space ok──▶ downloading(.tokenizer → .transfer)
///       │                         └─no space──▶ failed(diskFull)
///       ├──Import──▶ importing ──▶ needsFile(x) ──Choose/Download x──▶ verifying
///       │                     └──────────────────────────────────────▶ verifying
/// downloading ──recording──▶ pausedForRecording ──recording over + 2 min──▶ downloading
/// downloading ──Pause / quit / offline──▶ partial(+lastError)      downloading ──Cancel──▶ notInstalled
/// downloading ──mismatch──▶ failed(mismatch) (staging discarded)
/// partial ──Resume──▶ checkingPartial ──▶ downloading              partial ──Discard──▶ notInstalled
/// downloading / import done ──▶ verifying ──▶ preparing (self-test + load) ──▶ ready
/// ready ──engine reports damaged──▶ damaged ──Repair──▶ repairing ──▶ verifying ──▶ ready
/// any ──Delete──▶ deleting ──▶ notInstalled          failed ──Try Again──▶ (files? check again : download)
/// ```
public actor LanguageModelController {
    private let store: LanguageModelStore
    private let access: LanguageModelAccess
    private let engine: LanguageModelEngine
    private let environment: @Sendable () -> IndexerEnvironment
    private let log: NetworkActivityLog
    private let protocolClasses: [AnyClass]?
    private let supported: @Sendable () -> LanguageModelUnsupported?
    private let defaults: UserDefaults
    /// What "preparing" does after the files are in place: the first load (kernel self-test and weights).
    private let prepare: @Sendable (LanguageModelEngine) async throws -> Void
    private let appBuild: String
    private let pollInterval: Duration
    private let meter = DownloadProgressMeter()
    private var session: AuditedSession?
    private var task: Task<Void, Never>?
    private var runID = 0
    /// What to do with the staging area when the running task stops: keep it (Pause) or delete it (Cancel).
    private enum Stop { case keep, discard }
    private var stop = Stop.keep
    private var repairing = false
    private var hooks = LanguageModelHooks()
    private var handler: (@Sendable (LanguageModelStatus) -> Void)?
    public private(set) var status = LanguageModelStatus()

    public static let shared = LanguageModelController()

    init(store: LanguageModelStore = LanguageModelStore(), access: LanguageModelAccess = .shared, engine: LanguageModelEngine? = nil,
         environment: @escaping @Sendable () -> IndexerEnvironment = { SearchModelAccess.shared.environment },
         log: NetworkActivityLog = .shared, protocolClasses: [AnyClass]? = nil,
         supported: @escaping @Sendable () -> LanguageModelUnsupported? = { LanguageModelGate.unsupported(gpuSupported: LanguageModelGate.gpuSupported) },
         defaults: UserDefaults = .standard, appBuild: String = LanguageModelStore.currentBuild, pollInterval: Duration = .seconds(1),
         prepare: @escaping @Sendable (LanguageModelEngine) async throws -> Void = { try await $0.load() }) {
        self.prepare = prepare
        self.store = store
        self.access = access
        self.environment = environment
        self.log = log
        self.protocolClasses = protocolClasses
        self.supported = supported
        self.defaults = defaults
        self.appBuild = appBuild
        self.pollInterval = pollInterval
        self.engine = access.engine(for: store, using: engine)
    }

    public func setHooks(_ hooks: LanguageModelHooks) { self.hooks = hooks }

    public func setStatusHandler(_ handler: @escaping @Sendable (LanguageModelStatus) -> Void) {
        self.handler = handler
        handler(status)
    }

    private func set(_ state: LanguageModelStatus.State, rate: Double? = nil, remaining: Int? = nil, error: IntegratedModelError? = nil) {
        status.state = state
        if case .importing = state {} else { status.importPaused = false }
        status.lastError = error
        status.bytesPerSecond = rate
        status.secondsRemaining = remaining
        status.installedBytes = store.bytesOnDisk()
        handler?(status)
    }

    // MARK: Start

    /// Reads the disk. No network, and nothing is loaded.
    public func start() async {
        try? store.prepare()
        if let reason = supported() {
            set(.unsupported(reason))
            return
        }
        switch store.disk() {
        case .installed:
            if LanguageModelVerifier.quickCheck(file: store.weightsURL, spec: store.spec),
               LanguageModelVerifier.quickCheckTokenizer(file: store.tokenizerURL, spec: store.spec) {
                access.refresh(store: store, engine: engine)
                set(.ready)
            } else {
                access.markDamaged()
                set(.damaged)
            }
        case .partial:
            if store.stagingIsRepair { status.source = "repair" }
            set(restingState())
        case .empty: set(.notInstalled)
        }
    }

    /// The engine (loaded lazily) that the access hands out while the model is installed.
    var languageEngine: LanguageModelEngine { engine }

    // MARK: Staging

    private func estimatedVerifiedBytes() -> Int {
        let spec = store.spec
        let fm = FileManager.default
        if fm.fileExists(atPath: store.stagedWeights.path) { return spec.downloadSize }
        var bytes = 0
        if (try? LanguageModelVerifier.verifyTokenizer(file: store.stagedTokenizer, spec: spec)) != nil { bytes += spec.tokenizerSize }
        if let journal = (try? Data(contentsOf: store.stagedJournal)).flatMap({ try? JSONDecoder().decode(StreamingQuantizer.Journal.self, from: $0) }) {
            bytes += min(journal.resumeOffset, spec.spanSize)
        }
        return min(bytes, spec.downloadSize)
    }

    /// What a stopped, interrupted or half-imported staging area shows: the weights alone (a tokenizer is still needed), the
    /// tokenizer alone after an import (the weights are still needed), or a partial download.
    private func restingState() -> LanguageModelStatus.State {
        let fm = FileManager.default
        let weights = fm.fileExists(atPath: store.stagedWeights.path), tokenizer = fm.fileExists(atPath: store.stagedTokenizer.path)
        if weights, !tokenizer { return .needsFile(.tokenizer) }
        if tokenizer, !weights, status.source == "import", !fm.fileExists(atPath: store.stagedWeightsPart.path) { return .needsFile(.weights) }
        return .partial(verified: estimatedVerifiedBytes(), total: store.spec.downloadSize)
    }

    // MARK: Choosing

    /// Starting a download or an import is choosing the model: the saved chat choice becomes the integrated model at once (the chat
    /// choice only; nothing else of the saved settings), so no unsaved state hides behind a transfer of 15 GB. Until the model is ready,
    /// Apple's writes the minutes.
    private func choose() async {
        guard defaults.string(forKey: ModelProviderSettings.chatKey) != ModelProviderSettings.Chat.integrated.rawValue else { return }
        ModelProviderSettings.saveChat(.integrated, defaults: defaults)
        await hooks.chosen()
    }

    /// "Use for Minutes" on an installed model.
    public func useForMinutes() async {
        ModelProviderSettings.saveChat(.integrated, defaults: defaults)
        await hooks.chosen()
    }

    // MARK: Download

    /// Starts (or resumes) the download. The person asked for it. One at a time. No request is made when the disk lacks the room.
    public func download() async {
        guard task == nil, supported() == nil else { return }
        await choose()
        // Resuming a paused repair goes on with the repair (the damaged model is what is in staging).
        let repair = store.stagingIsRepair
        status.source = repair ? "repair" : "download"
        startDownload(repair: repair)
    }

    private func startDownload(repair: Bool) {
        // Not enough room: say so before any request.
        do { try store.checkRoomToInstall() } catch let error as IntegratedModelError {
            set(.failed(error))
            return
        } catch {
            set(.failed(.ioError))
            return
        }
        if session == nil { session = SearchModelDownloader.makeSession(protocolClasses: protocolClasses, log: log) }
        let downloader = LanguageModelDownloader(session: session!, store: store, appBuild: appBuild)
        repairing = repair
        stop = .keep
        meter.reset()
        runID += 1
        let run = runID
        let total = store.spec.downloadSize
        set(repair ? .repairing(received: 0, total: total) : .downloading(received: 0, total: total, phase: .tokenizer))
        status.cancellable = true
        let controller = self
        let meter = meter
        let source = repair ? "repair" : "download"
        task = Task {
            do {
                try await downloader.run(source: source, progress: { p in
                    guard let tick = meter.record(bytes: p.received, total: p.total, at: ProcessInfo.processInfo.systemUptime) else {
                        if p.phase == .checking || p.phase == .finishing { Task { await controller.progressed(p, rate: nil, remaining: nil, run: run) } }
                        return
                    }
                    Task { await controller.progressed(p, rate: tick.rate, remaining: tick.remaining, run: run) }
                }, beforeBlock: { try await controller.waitWhileRecording() })
                await controller.finishedInstall(run: run, source: source)
            } catch is CancellationError {
                await controller.stopped(run: run)
            } catch let error as IntegratedModelError {
                await controller.failed(error, run: run)
            } catch {
                await controller.failed(.ioError, run: run)
            }
        }
    }

    private func progressed(_ p: LanguageModelProgress, rate: Double?, remaining: Int?, run: Int) {
        guard task != nil, run == runID else { return }
        // A paused download shows "paused" until it goes on; late progress from the block in flight does not undo it.
        if case .pausedForRecording = status.state { return }
        switch p.phase {
        case .checking: set(.checkingPartial)
        case .finishing: set(.verifying)
        case .tokenizer, .downloading: set(repairing ? .repairing(received: p.received, total: p.total) : .downloading(received: p.received, total: p.total, phase: p.phase),
                                           rate: rate, remaining: remaining)
        }
    }

    /// Holds the work (download, conversion, repair) while a recording runs and for two minutes after: the person started it, so it
    /// continues by itself. Low Power Mode and battery do not stop it.
    func waitWhileRecording() async throws {
        var resume: LanguageModelStatus.State?
        while IndexerPolicy.decide(environment()).pause == .recording {
            try Task.checkCancellation()
            if resume == nil {
                switch status.state {
                case .downloading(let r, let t, _), .repairing(let r, let t):
                    resume = status.state
                    set(.pausedForRecording(received: r, total: t))
                case .importing:
                    // Still the import (conversion copy, the import's own Cancel): only marked as waiting.
                    resume = status.state
                    status.importPaused = true
                    handler?(status)
                default:
                    break
                }
            }
            try await Task.sleep(for: pollInterval)
        }
        if let resume {
            switch (resume, status.state) {
            case (.importing(let f), .importing(let now)):
                status.importPaused = false
                set(.importing(max(f, now)))
            case (_, .pausedForRecording):
                set(resume)
            default:
                break
            }
        }
    }

    /// Stops the download and keeps the verified blocks (Resume continues from them).
    public func pause() {
        stop = .keep
        task?.cancel()
    }

    /// Cancel on an import: stops the conversion and removes what this import wrote. Whatever an earlier import left (the tokenizer
    /// chosen before the weights) stays, and the card goes back to asking for the other file. Nothing is downloaded.
    public func cancelImport() {
        stop = .keep
        task?.cancel()
    }

    /// Stops what is running and deletes what it kept.
    public func cancelAndDiscard() async {
        guard let running = task else { return }
        stop = .discard
        running.cancel()
        await running.value
    }

    /// Deletes what a stopped download or a half-finished import left.
    public func discard() {
        guard task == nil else { return }
        store.discardStaging()
        status.source = nil
        set(.notInstalled)
    }

    private func endSession() {
        task = nil
        status.cancellable = false
        session?.invalidateAndCancel()
        session = nil
    }

    private func stopped(run: Int) {
        guard run == runID else { return }
        endSession()
        if stop == .discard {
            store.discardStaging()
            status.source = nil
            set(.notInstalled)
        } else {
            set(restingState())
        }
        repairing = false
    }

    private func failed(_ error: IntegratedModelError, run: Int) {
        guard run == runID else { return }
        endSession()
        repairing = false
        // Nothing was installed. Blocks that were verified stay for Resume, unless the bytes did not match what was pinned.
        if error == .mismatch {
            store.discardStaging()
            set(.failed(error))
            return
        }
        if error == .offline || error == .hostNotAllowed, estimatedVerifiedBytes() > 0 {
            set(restingState(), error: error)
        } else {
            set(.failed(error))
        }
    }

    private func finishedInstall(run: Int, source: String) async {
        guard run == runID else { return }
        endSession()
        repairing = false
        await adopt(source: source, run: run)
    }

    /// The files are in place: check, load once (the kernel self-test and the weights), and make the model available.
    private func adopt(source: String, run: Int) async {
        status.source = source
        status.cancellable = false
        set(.verifying)
        guard case .installed = store.disk() else { set(.failed(.ioError)); return }
        await engine.reset()
        set(.preparing)
        do {
            try await prepare(engine)
        } catch let error as IntegratedModelError {
            guard run == runID else { return }
            switch error {
            case .mismatch, .tokenizerUnreadable, .nonFiniteWeights:
                access.markDamaged()
                set(.damaged)
            case .unsupported:
                access.markDamaged()
                set(.unsupported(.selfTestFailed))
            default:
                set(.failed(error))
            }
            return
        } catch {
            guard run == runID else { return }
            set(.failed(.engineFailed("The model could not be loaded.")))
            return
        }
        // Deleted while it was preparing: the delete already reset everything.
        guard run == runID else { return }
        access.refresh(store: store, engine: engine)
        set(.ready)
        await hooks.installed()
    }

    /// Try Again after something went wrong with files that are already on this Mac. Damaged files are repaired; otherwise the model
    /// is checked and loaded again. Without files it is a plain download.
    public func retry() async {
        guard task == nil else { return }
        guard case .installed = store.disk() else { await download(); return }
        if status.state == .damaged {
            await repair()
        } else {
            await engine.unload()
            runID += 1
            await adopt(source: status.source ?? "download", run: runID)
        }
    }

    // MARK: Repair

    /// Fetches only the damaged part again. The installed file goes back to staging as a partial file whose journal says everything
    /// was written; the resume read-back then finds the first tensor that no longer matches its pinned hash and moves the restart to
    /// its source bytes. A tokenizer that no longer matches its hash is fetched again.
    public func repair() async {
        guard task == nil, supported() == nil, case .installed = store.disk() else { return }
        await choose()
        runID += 1
        access.clear()
        await engine.unload()
        let fm = FileManager.default
        do {
            try store.createStaging()
            fm.createFile(atPath: store.stagedRepairMarker.path, contents: Data(), attributes: [.posixPermissions: 0o600])
            try? fm.removeItem(at: store.stagedWeights)
            try? fm.removeItem(at: store.stagedWeightsPart)
            try fm.moveItem(at: store.weightsURL, to: store.stagedWeightsPart)
            if (try? LanguageModelVerifier.verifyTokenizer(file: store.tokenizerURL, spec: store.spec)) != nil {
                try? fm.removeItem(at: store.stagedTokenizer)
                try fm.moveItem(at: store.tokenizerURL, to: store.stagedTokenizer)
            }
            try store.saveJournal(StreamingQuantizer.Journal(resumeOffset: store.spec.spanSize))
            try? fm.removeItem(at: store.installDirectory)
        } catch {
            set(.failed(.ioError))
            return
        }
        status.source = "repair"
        startDownload(repair: true)
    }

    /// Called when a read of the installed files failed its check.
    public func markDamaged() {
        access.markDamaged()
        set(.damaged)
    }

    // MARK: Import

    /// Installs from files the person chose. Nothing goes over the network. Cancel (and Delete) stop the work itself.
    public func importFiles(_ urls: [URL]) async {
        guard task == nil, supported() == nil else { return }
        await choose()
        runID += 1
        let run = runID
        status.source = "import"
        status.cancellable = true
        stop = .keep
        // What an earlier import left in staging is not this import's to remove when it is cancelled.
        let hadStaging = [store.stagedWeights, store.stagedWeightsPart, store.stagedTokenizer, store.stagedJournal]
            .contains { FileManager.default.fileExists(atPath: $0.path) }
        meter.reset()
        set(.importing(0))
        let store = store, build = appBuild
        let controller = self
        let meter = meter
        let work = Task.detached {
            try await LanguageModelImporter.importFiles(urls, store: store, appBuild: build, progress: { f in
                guard meter.record(bytes: Int(f * 10_000), total: 10_000, at: ProcessInfo.processInfo.systemUptime) != nil else { return }
                Task { await controller.importProgressed(f, run: run) }
            }, beforeBlock: { try await controller.waitWhileRecording() })
        }
        // Cancelling `task` cancels the detached import (a plain child would not inherit the cancellation).
        task = Task { await withTaskCancellationHandler { _ = await work.result } onCancel: { work.cancel() } }
        let result = await work.result
        // Deleted while it ran: the delete owns the state from here.
        guard run == runID else { return }
        task = nil
        status.cancellable = false
        switch result {
        case .success(.installed): await adopt(source: "import", run: run)
        case .success(.needsTokenizer): set(.needsFile(.tokenizer))
        case .success(.needsWeights): set(.needsFile(.weights))
        case .failure(let error):
            if error is CancellationError {
                if stop == .discard || !hadStaging {
                    store.discardStaging()
                    status.source = nil
                    set(.notInstalled)
                } else {
                    set(restingState())
                }
            } else {
                set(.failed((error as? IntegratedModelError) ?? .ioError))
            }
        }
    }

    private func importProgressed(_ fraction: Double, run: Int) {
        guard task != nil, run == runID else { return }
        guard case .importing = status.state else { return }
        set(.importing(fraction))
    }

    // MARK: Delete

    /// Removes the model: chat goes back to Apple's model.
    public func delete() async {
        runID += 1   // the late callbacks of a download or an import that was running do nothing
        status.cancellable = false
        set(.deleting)
        let running = task
        running?.cancel()
        session?.invalidateAndCancel()
        session = nil
        await running?.value
        task = nil
        repairing = false
        access.clear()
        await engine.unload()
        await engine.reset()
        _ = store.delete()
        status.source = nil
        set(.notInstalled)
        await hooks.removed()
    }
}
