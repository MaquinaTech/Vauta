// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation
import Observation

/// Meetings → Transcript → Translate: a finished meeting's transcript translated on request (`TranscriptTranslator`), one
/// meeting at a time; the languages offered for a meeting; and Apple's download of a language that isn't on this Mac yet (the
/// system's own sheet asks first). The work goes on while Meetings are locked, as the minutes do, and waits while a meeting
/// is recorded. A corrected line is translated again quietly, with nothing shown unless the person asked for more.
@MainActor
@Observable
final class TranscriptTranslationModel {
    typealias Scope = TranscriptTranslator.Scope

    /// A transcript to translate.
    struct Request: Equatable, Sendable {
        let meetingID: Int64
        let source: Locale.Language
        let target: Locale.Language
        let scope: Scope
        /// After a correction: no progress, no notice and never a download.
        let quiet: Bool
    }

    /// Where the work the person asked for is.
    enum Stage: Equatable {
        /// Behind another meeting.
        case waiting(Locale.Language)
        /// Apple's languages for the pair are downloading: the system shows its own sheet.
        case downloading(Locale.Language)
        /// `server`: the model server translates; otherwise Apple's translation on this Mac.
        case translating(Locale.Language, done: Int, total: Int, server: Bool)
        /// A meeting is being recorded: the work goes on when it ends.
        case waitingForRecording(Locale.Language)
    }

    /// How the last translation of a meeting ended, when there is something to say.
    enum Notice: Equatable {
        /// Lines left without a translation.
        case missing(Int)
        /// The model server stopped answering (what it said): Apple's translation did the rest (`onDevice`), or the rest has none.
        case serverStopped(String, onDevice: Bool)
        /// The translation couldn't run (why).
        case failed(String)
        /// Apple's download of the languages didn't finish.
        case downloadFailed
    }

    /// A language to translate into.
    struct Target: Identifiable, Equatable {
        let language: Locale.Language
        /// Apple's languages for it are downloaded first (the model server doesn't translate).
        let needsDownload: Bool
        var id: String { language.storageCode }
        var name: String { TranslationPair.name(of: language) }
    }

    /// The meetings being translated or waiting for it, as the person asked.
    private(set) var stages: [Int64: Stage] = [:]
    private(set) var notices: [Int64: Notice] = [:]
    /// The languages the meeting shown can be translated into, by name.
    private(set) var targets: [Target] = []
    let downloader = TranslationDownloader()

    @ObservationIgnored var store: MeetingStore?
    @ObservationIgnored var llm: LLMService?
    @ObservationIgnored var preferences: Preferences?
    /// Whether a model server is set up (the recorder's status).
    @ObservationIgnored var serverConfigured: () -> Bool = { false }
    /// Translations of a meeting were stored: the meeting shown reads them again.
    @ObservationIgnored var onStored: ((Int64) -> Void)?
    /// Apple's download sheet can show: the Meetings window, which hosts it, is open.
    @ObservationIgnored var canAskForDownload: () -> Bool = { true }

    @ObservationIgnored private let backend: any TranscriptTranslationBackend
    /// At most one request per meeting waits.
    @ObservationIgnored private var queue: [Request] = []
    @ObservationIgnored private var running: (request: Request, task: Task<Void, Never>)?
    @ObservationIgnored private var targetsKey: String?
    @ObservationIgnored private var supported: [Locale.Language]?

    init(backend: any TranscriptTranslationBackend = AppleTranslationBackend()) {
        self.backend = backend
        downloader.onFinished = { [weak self] _ in self?.downloadEnded(success: true, failed: false) }
        downloader.onStopped = { [weak self] _, failed in self?.downloadEnded(success: false, failed: failed) }
    }

    /// The model server translates transcripts: the person improves translations with it (Settings → Translation), and one is set up.
    var usesServer: Bool { (preferences?.translationRefinementEnabled ?? false) && serverConfigured() }

    /// Reads the languages `source` can be translated into, when they may have changed (another meeting language, the server
    /// turned on or off, a download).
    func refreshTargets(source: Locale.Language) async {
        let server = usesServer
        let key = "\(source.storageCode)|\(server)"
        guard key != targetsKey else { return }
        let all: [Locale.Language]
        if let supported { all = supported } else { all = pickerLanguages(await backend.supportedLanguages()); supported = all }
        var found = await backend.targets(from: source, among: all)
            .map { Target(language: $0.language, needsDownload: $0.availability == .downloadable && !server) }
        if server {
            // The model server translates into any of them, also where Apple's translation can't.
            let offered = Set(found.map(\.id))
            found += all.filter { !$0.isSameLanguage(as: source) && !offered.contains($0.storageCode) }
                .map { Target(language: $0, needsDownload: false) }
            found.sort { LanguageNameSort.precedes($0.name, $1.name) }
        }
        targetsKey = key
        targets = found
    }

    /// Translates the lines of `meetingID` in `scope` into `target`, after the meeting being translated if there is one. Asked
    /// again for what is under way, nothing changes; another language, or every line again, takes the place of what the person
    /// asked before. `quiet`: lines a correction changed, which never push back what the person asked for.
    func translate(_ meetingID: Int64, source: Locale.Language, into target: Locale.Language, scope: Scope = .missing, quiet: Bool = false) {
        var request = Request(meetingID: meetingID, source: source, target: target, scope: scope, quiet: quiet)
        if !quiet { notices[meetingID] = nil }
        if let running, running.request.meetingID == meetingID {
            let current = running.request
            if current.target.storageCode == target.storageCode {
                if quiet {
                    // The running translation read the lines before the correction: what it misses comes after it.
                    request = Request(meetingID: meetingID, source: source, target: target,
                                      scope: current.scope == .changed ? .changed : .missing, quiet: true)
                } else if !current.quiet, current.scope >= scope {
                    return
                } else if !current.quiet {
                    cancel(running)
                }
            } else if !current.quiet, !quiet {
                cancel(running)
            }
        }
        enqueue(request)
        let showing = running.map { $0.request.meetingID == meetingID && !$0.request.quiet } ?? false
        if !quiet, !showing { stages[meetingID] = .waiting(target) }
        startNext()
    }

    /// One request per meeting waits: one for the same language takes the wider scope, another language replaces it (a quiet
    /// one never replaces what the person asked for).
    private func enqueue(_ request: Request) {
        guard let index = queue.firstIndex(where: { $0.meetingID == request.meetingID }) else { return queue.append(request) }
        let waiting = queue[index]
        if waiting.target.storageCode == request.target.storageCode {
            queue[index] = Request(meetingID: request.meetingID, source: request.source, target: request.target,
                                   scope: max(waiting.scope, request.scope), quiet: waiting.quiet && request.quiet)
        } else if !request.quiet || waiting.quiet {
            queue[index] = request
        }
    }

    /// Stops translating `meetingID` and takes it out of the queue. What was stored stays.
    func stop(_ meetingID: Int64) {
        queue.removeAll { $0.meetingID == meetingID }
        guard let running, running.request.meetingID == meetingID else {
            stages[meetingID] = nil
            return
        }
        cancel(running)
    }

    func dismissNotice(_ meetingID: Int64) { notices[meetingID] = nil }

    /// Everything stops and is forgotten: all meetings were erased, or a backup replaces them (their ids are used again).
    func stopAll() {
        queue = []
        let task = running?.task
        running = nil
        task?.cancel()
        downloader.cancel()
        stages = [:]
        notices = [:]
    }

    // MARK: Work

    private func cancel(_ running: (request: Request, task: Task<Void, Never>)) {
        if case .downloading = stages[running.request.meetingID] { downloader.cancel() } else { running.task.cancel() }
    }

    private func startNext() {
        guard running == nil, let store, !queue.isEmpty else { return }
        let request = queue.removeFirst()
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.run(request, store: store)
        }
        running = (request, task)
    }

    private func run(_ request: Request, store: MeetingStore) async {
        let id = request.meetingID
        let availability = await backend.availability(from: request.source, to: request.target)
        var onDevice: (any Translator)?
        var deviceError: Error?
        if availability == .installed {
            do { onDevice = try await backend.makeTranscriptTranslator(from: request.source, to: request.target) } catch { deviceError = error }
        }
        let server = usesServer ? await llm?.transcriptTranslator(source: request.source, target: request.target,
                                                                  model: preferences?.translationModel) : nil
        guard running?.request == request, !Task.isCancelled else { return finish(request, cancelled: true) }
        if server == nil, onDevice == nil {
            if let deviceError { return finish(request, notice: .failed(deviceError.localizedDescription)) }
            guard availability == .downloadable else {
                return finish(request, notice: .failed(String(localized: "This language can’t be translated on this Mac.",
                                                              comment: "Transcript tab: the meeting's language can't be translated into the one chosen")))
            }
            // A correction never starts a download, and no sheet can show while the Meetings window is closed.
            guard !request.quiet, canAskForDownload() else { return finish(request, notice: .downloadFailed) }
            // Downloaded first; the translation starts when the system says the languages are here (`downloadEnded`).
            stages[id] = .downloading(request.target)
            let strategy = await backend.transcriptDownloadStrategy(from: request.source, to: request.target)
            downloader.request(TranslationPair(source: request.source, target: request.target), strategy: strategy, from: .meetings)
            return
        }
        let usingServer = server != nil
        if !request.quiet { stages[id] = .translating(request.target, done: 0, total: 0, server: usingServer) }
        let translator = TranscriptTranslator(onDevice: onDevice, server: server)
        do {
            let outcome = try await translator.translate(id, into: request.target, store: store, scope: request.scope) { [weak self] progress in
                await self?.progressed(request, progress, server: usingServer)
            }
            let notice: Notice? = if let failure = outcome.serverFailure {
                .serverStopped(failure, onDevice: onDevice != nil)
            } else if outcome.missing > 0 {
                .missing(outcome.missing)
            } else {
                nil
            }
            finish(request, notice: notice)
        } catch is CancellationError {
            finish(request, cancelled: true)
        } catch {
            finish(request, notice: .failed(error.localizedDescription))
        }
    }

    private func progressed(_ request: Request, _ progress: TranscriptTranslator.Progress, server: Bool) {
        guard running?.request == request else { return }
        if !request.quiet {
            stages[request.meetingID] = progress.waitingForRecording
                ? .waitingForRecording(request.target)
                : .translating(request.target, done: progress.done, total: progress.total, server: server)
        }
        if progress.done > 0 { onStored?(request.meetingID) }
    }

    private func finish(_ request: Request, notice: Notice? = nil, cancelled: Bool = false) {
        guard running?.request == request else { return }
        let id = request.meetingID
        running = nil
        if !request.quiet, !cancelled { notices[id] = notice }
        if let waiting = queue.first(where: { $0.meetingID == id }), !waiting.quiet {
            stages[id] = .waiting(waiting.target)
        } else if !request.quiet {
            stages[id] = nil
        }
        onStored?(id)
        startNext()
    }

    private func downloadEnded(success: Bool, failed: Bool) {
        guard let running, case .downloading = stages[running.request.meetingID] else { return }
        let request = running.request
        self.running = nil
        // Whether a language is on this Mac changed: the menu reads it again.
        targetsKey = nil
        if success {
            if !queue.contains(where: { $0.meetingID == request.meetingID }) { queue.insert(request, at: 0) }
        } else {
            stages[request.meetingID] = nil
            if failed { notices[request.meetingID] = .downloadFailed }
        }
        startNext()
    }
}
