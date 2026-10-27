// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import Observation
import os

/// Live Translation as the interface sees it: the switch, the language pair,
/// the captions and their panel. The work itself happens in `LiveTranslator`
/// (an actor); this class only forwards segments to it and publishes what it
/// sends back, at most ten times a second.
///
/// With the feature off there is no translator, no task and no panel:
/// `feed` is a single optional check.
@MainActor
@Observable
final class LiveTranslationModel {
    let preferences: Preferences
    let downloader = TranslationDownloader()

    /// What the captions panel draws.
    private(set) var snapshot = CaptionSnapshot()
    private(set) var isRecording = false
    private(set) var isPaused = false
    /// Paused by the user, or showing the paused state: the one answer for the panel's row and the captions bar.
    var showsPaused: Bool { isPaused || snapshot.status == .paused }
    /// The language the other participants speak in this meeting.
    private(set) var sourceLanguage: Locale.Language?
    /// The languages that can be translated into from the source, for the menus.
    private(set) var targets: [TranslationTarget] = []
    /// How many of the other participants' voices are told apart in this recording, and the names the user gave them (by the
    /// number the voice has while recording). Captions carry a speaker label from two voices on.
    private(set) var speakerCount = 0
    private(set) var speakerNames: [Int: String] = [:]
    /// The pointer is over the panel: its controls show.
    var controlsVisible = false
    /// The last download did not finish (declined in Apple's sheet or failed): the captions say so and offer it again.
    private(set) var downloadFailed = false
    /// The pair whose last download did not finish, so Settings can say which language and offer it again.
    private(set) var failedPair: TranslationPair?

    @ObservationIgnored private let backend = AppleTranslationBackend()
    @ObservationIgnored private var translator: LiveTranslator?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var targetsSource: Locale.Language?
    @ObservationIgnored private var hideControls: Task<Void, Never>?
    /// The newest caption already announced to VoiceOver.
    @ObservationIgnored private var lastAnnouncedLine = -1
    @ObservationIgnored private let panel = CaptionsPanelController()
    @ObservationIgnored private let signposter = OSSignposter(subsystem: "local.vauta", category: "LiveTranslation")
    /// Called with every final translation, to be stored, and the number of the recording it belongs to
    /// (`recordingNumber` when it was started): answers from the model server can arrive after the stop.
    @ObservationIgnored var onFinal: (@MainActor (FinalTranslation, Int) -> Void)?
    /// Called with a finished recording's number when its translator has nothing left to wait for.
    @ObservationIgnored var lingeringDone: (@MainActor (Int) -> Void)?
    /// Counts recordings, so a late answer is never stored into a later meeting.
    private(set) var recordingNumber = 0
    /// The recording is stopping and the last sentences are being translated and stored with it.
    private(set) var isEnding = false
    /// Translators of finished recordings that are still waiting for the model server's last answers.
    @ObservationIgnored private var lingering: [UUID: LiveTranslator] = [:]
    /// The model service whose server refines finished sentences (nil = none yet).
    @ObservationIgnored var llm: (@MainActor () -> LLMService?)?

    /// The "Test" button in Settings → Translation.
    enum RefinementTestState: Equatable {
        case idle
        case running
        case finished(RefinementTest)
    }
    private(set) var refinementTest = RefinementTestState.idle
    @ObservationIgnored private var testTask: Task<Void, Never>?

    init(preferences: Preferences) {
        self.preferences = preferences
        panel.model = self
        downloader.onFinished = { [weak self] _ in self?.downloadFinished() }
        downloader.onStopped = { [weak self] pair, failed in self?.downloadStopped(pair, failed: failed) }
        observePreferences()
    }

    /// Whether the translator exists (a recording is running with the feature on).
    var isRunning: Bool { translator != nil }
    var isEnabled: Bool {
        #if VAUTA_DIAGNOSTICS
        if isSnapshotOnly { return true }  // shown on without changing the shared snapshot preferences
        #endif
        return preferences.liveTranslationEnabled
    }

    /// The shortcut that turns Live Translation on or off, as shown to the user.
    var hotKeyText: String { GlobalHotKey.displayString(preferences.translationHotKey) }

    /// How the server's refinement is going (a small indicator, never an alert).
    var refinementStatus: RefinementStatus { snapshot.refinement }

    // MARK: Refinement

    /// The server translator for `pair`, or nil when refinement is off or no server is set up.
    private func refiner(for pair: TranslationPair) async -> (any RefiningTranslator)? {
        guard preferences.translationRefinementEnabled, let service = llm?() else { return nil }
        return await service.refinementTranslator(source: pair.source, target: pair.target, model: preferences.translationModel)
    }

    /// Translates a sample sentence with the model server and records the real latency.
    func runRefinementTest(source: Locale.Language?) {
        guard refinementTest != .running, let service = llm?() else { return }
        refinementTest = .running
        let sample = RefinementTest.Sample.make(source: source, target: source.flatMap { resolvedTarget(for: $0) })
        let model = preferences.translationModel
        testTask?.cancel()
        testTask = Task { [weak self] in
            let result: RefinementTest
            if let translator = await service.refinementTranslator(source: sample.source, target: sample.target, model: model,
                                                                   purpose: .connectionTest) {
                result = await RefinementTest.run(sample, with: translator)
            } else {
                result = RefinementTest(sample: sample, outcome: .failed(String(localized: "No model server is set up.", comment: "Translation test: no model server to try")), seconds: 0)
            }
            guard !Task.isCancelled else { return }
            self?.refinementTest = .finished(result)
        }
    }

    func clearRefinementTest() {
        testTask?.cancel()
        refinementTest = .idle
    }

    // MARK: Segments

    /// Every segment of the recording; only "Others" matters. Costs one
    /// optional check when the feature is off.
    func feed(_ segment: Segment, key: Int) {
        translator?.submit(segment, key: key)
    }

    // MARK: Switch

    func setSpeakers(count: Int, names: [Int: String]) {
        if speakerCount != count { speakerCount = count }
        if speakerNames != names { speakerNames = names }
    }

    func toggle() { setEnabled(!preferences.liveTranslationEnabled) }

    func setEnabled(_ on: Bool) {
        preferences.liveTranslationEnabled = on
        reconcile()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        guard let translator else { return }
        Task { await translator.setPaused(paused) }
    }

    func recordingStarted(language: Locale) {
        recordingNumber += 1
        isRecording = true
        isPaused = false
        lastAnnouncedLine = -1
        sourceLanguage = language.language
        snapshot = CaptionSnapshot()
        reconcile()
    }

    /// The recording is stopping: the last sentences get a moment to be translated and stored.
    func recordingEnded() async {
        isRecording = false
        isEnding = true
        defer { isEnding = false }
        let translator = translator
        self.translator = nil
        panel.hide()
        await translator?.finish(maxWait: .seconds(2))
        // Requests already sent to the model server finish in the background (bounded) and are stored;
        // stopping does not wait for them.
        if let translator {
            let id = UUID(), number = recordingNumber
            lingering[id] = translator
            Task { [weak self] in
                await translator.waitForRefinements()
                self?.lingering[id] = nil
                self?.lingeringDone?(number)
            }
        }
        consumer?.cancel()
        consumer = nil
        sourceLanguage = nil
        snapshot = CaptionSnapshot()
    }

    // MARK: Pair

    /// The language the captions are translated into for `source`.
    func resolvedTarget(for source: Locale.Language) -> Locale.Language? {
        #if VAUTA_DIAGNOSTICS
        if noTarget { return nil }
        #endif
        if let id = preferences.translationTarget {
            let chosen = Locale.Language(identifier: id)
            return chosen.isSameLanguage(as: source) ? TranslationPair.automaticTarget(source: source) : chosen
        }
        return TranslationPair.automaticTarget(source: source)
    }

    /// "English → Spanish" (every name capitalized, as a label) for the current or next meeting, if known.
    func pairName(source: Locale.Language? = nil) -> String? {
        if let pair = snapshot.pair { return pair.labelName }
        guard let source = source ?? sourceLanguage, let target = resolvedTarget(for: source) else { return nil }
        return TranslationPair(source: source, target: target).labelName
    }

    /// Just the language translated into ("Spanish"), for compact menus.
    /// `source` is the language of the next meeting, when none is running.
    func targetName(source: Locale.Language? = nil) -> String? {
        if let pair = snapshot.pair { return TranslationPair.name(of: pair.target) }
        guard let source = sourceLanguage ?? source, let target = resolvedTarget(for: source) else { return nil }
        return TranslationPair.name(of: target)
    }

    /// A language chosen from a menu (nil = automatic). The preference observer applies it.
    func chooseTarget(_ id: String?) {
        preferences.translationTarget = id
    }

    /// The target changed (menu, Settings): same translator, new pair.
    private func applyTarget() {
        #if VAUTA_DIAGNOSTICS
        if isSnapshotOnly { return }
        #endif
        guard isRecording, preferences.liveTranslationEnabled, let source = sourceLanguage else { return }
        guard let target = resolvedTarget(for: source) else {
            snapshot = CaptionSnapshot(status: .sameLanguage)
            return
        }
        if let translator {
            Task { await translator.configure(source: source, target: target) }
        } else {
            start()
        }
    }

    // MARK: Languages

    /// Reads which languages the Mac can translate into from `source`.
    func refreshTargets(source: Locale.Language?) async {
        #if VAUTA_DIAGNOSTICS
        if targetsAreSample { return }
        #endif
        guard let source else { return }
        if source == targetsSource, !targets.isEmpty { return }
        let supported = pickerLanguages(await backend.supportedLanguages())
        let found = await backend.targets(from: source, among: supported)
        targetsSource = source
        targets = found
    }

    /// Reads the availability again (after a download).
    func reloadTargets(source: Locale.Language?) async {
        targetsSource = nil
        await refreshTargets(source: source)
    }

    /// Asks the system to download `pair` (its own sheet asks for consent).
    func download(_ pair: TranslationPair, from requester: TranslationDownloader.Requester) {
        downloadFailed = false
        failedPair = nil
        Task {
            let strategy = await backend.downloadStrategy(from: pair.source, to: pair.target)
            downloader.request(pair, strategy: strategy, from: requester)
            if requester == .panel { panel.setAcceptsKey(true) }
            if snapshot.pair == pair { await translator?.setDownloading(true) }
        }
    }

    /// Gives up the download in progress: the captions go back to offering it.
    func cancelDownload() { downloader.cancel() }

    /// The download ended without the pair: the captions leave "Downloading…" and, unless it was cancelled, say why.
    private func downloadStopped(_ pair: TranslationPair, failed: Bool) {
        panel.setAcceptsKey(false)
        downloadFailed = failed
        failedPair = failed ? pair : nil
        Task { await translator?.setDownloading(false) }
    }

    /// Tries the translator again (after a failure or a download).
    func retry() {
        let translator = translator
        Task { await translator?.retry() }
    }

    private func downloadFinished() {
        panel.setAcceptsKey(false)
        downloadFailed = false
        failedPair = nil
        let source = sourceLanguage ?? targetsSource
        Task {
            await translator?.retry()
            await reloadTargets(source: source)
        }
    }

    // MARK: Lifecycle

    /// Starts or stops the translator and the panel to match the settings.
    func reconcile() {
        #if VAUTA_DIAGNOSTICS
        if isSnapshotOnly { return }
        #endif
        let wanted = preferences.liveTranslationEnabled && isRecording
        if wanted, translator == nil {
            start()
        } else if !wanted, let running = translator {
            translator = nil
            consumer?.cancel()
            consumer = nil
            Task { await running.stop() }
            snapshot = CaptionSnapshot()
        }
        if wanted { panel.show() } else { panel.hide() }
    }

    private func start() {
        guard let source = sourceLanguage else { return }
        guard let target = resolvedTarget(for: source) else {
            snapshot = CaptionSnapshot(status: .sameLanguage)
            return
        }
        let refiner: LiveTranslator.Refiner = { [weak self] pair in await self?.refiner(for: pair) }
        let number = recordingNumber
        let translator = LiveTranslator(backend: backend, refiner: refiner) { [weak self] final in
            await self?.deliver(final, recording: number)
        }
        self.translator = translator
        snapshot = CaptionSnapshot(pair: TranslationPair(source: source, target: target), status: .starting)
        consumer = Task { [weak self] in
            for await next in translator.snapshots { self?.apply(next) }
        }
        Task {
            await translator.configure(source: source, target: target)
            if isPaused { await translator.setPaused(true) }
        }
        Task { await refreshTargets(source: source) }
    }

    private func deliver(_ final: FinalTranslation, recording: Int) {
        onFinal?(final, recording)
    }

    private func apply(_ next: CaptionSnapshot) {
        let state = signposter.beginInterval("applyCaptions")
        defer { signposter.endInterval("applyCaptions", state) }
        if next != snapshot {
            snapshot = next
            announce(next)
        }
    }

    /// VoiceOver cannot follow a panel that never takes the keyboard: each finished caption is announced
    /// (only the newest when several arrive together, at low priority so VoiceOver never cuts itself off).
    private func announce(_ next: CaptionSnapshot) {
        let finals = next.lines.filter { $0.state == .final && !$0.translation.isEmpty }
        guard let newest = finals.last else { return }
        if newest.id < lastAnnouncedLine { lastAnnouncedLine = -1 }
        guard newest.id > lastAnnouncedLine else { return }
        lastAnnouncedLine = newest.id
        guard preferences.readCaptionsWithVoiceOver, !isPaused, NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: newest.translation, .priority: NSAccessibilityPriorityLevel.low.rawValue])
    }

    // MARK: Panel hover

    func pointerMoved(inside: Bool) {
        hideControls?.cancel()
        if inside {
            controlsVisible = true
        } else {
            hideControls = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                guard !Task.isCancelled else { return }
                self?.controlsVisible = false
            }
        }
    }

    // MARK: Preferences

    private func observePreferences() {
        let enabled = preferences.liveTranslationEnabled
        let target = preferences.translationTarget
        withObservationTracking {
            _ = preferences.liveTranslationEnabled
            _ = preferences.translationTarget
            _ = preferences.captionTextSize
            _ = preferences.captionShowOriginal
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.preferences.liveTranslationEnabled != enabled { self.reconcile() }
                if self.preferences.translationTarget != target { self.applyTarget() }
                self.panel.layoutChanged()
                self.observePreferences()
            }
        }
    }

    #if VAUTA_DIAGNOSTICS
    @ObservationIgnored var targetsAreSample = false
    /// Snapshot renderer: the state is drawn but nothing starts (no translator, no panel).
    @ObservationIgnored private var isSnapshotOnly = false

    /// For the snapshot renderer only: Live Translation on during a recording of `pair`, without starting anything.
    func installSnapshotRecording(pair: TranslationPair, targets: [TranslationTarget]) {
        isSnapshotOnly = true
        targetsAreSample = true
        isRecording = true
        sourceLanguage = pair.source
        self.targets = targets
        snapshot = CaptionSnapshot(pair: pair, status: .listening)
    }

    /// For the snapshot renderer only: the state the captions panel would be in (needs a download, paused, ...).
    func installSnapshotStatus(_ status: CaptionStatus, failed: Bool = false) {
        snapshot = CaptionSnapshot(pair: snapshot.pair, status: status)
        isPaused = status == .paused
        if failed { installSnapshotDownloadFailed(snapshot.pair) }
    }

    /// For the snapshot renderer only: no language to translate into (the menu says "Choose Language").
    func installSnapshotNoTarget() { noTarget = true }
    @ObservationIgnored private var noTarget = false

    /// For the snapshot renderer only: this language shows "Downloading…" in Settings.
    func installSnapshotDownloading(_ pair: TranslationPair) { downloader.installSnapshotRunning(pair) }

    /// For the snapshot renderer only: the last download did not finish.
    func installSnapshotDownloadFailed(_ pair: TranslationPair? = nil) {
        downloadFailed = true
        failedPair = pair
    }

    /// For the snapshot renderer only: Live Translation on, waiting for the next recording.
    func installSnapshotEnabledIdle() {
        isSnapshotOnly = true
    }

    /// For `translate-bench`: applies a snapshot as the live pipeline does.
    func benchApply(_ next: CaptionSnapshot) { apply(next) }
    func benchStop() { consumer?.cancel() }

    /// For the snapshot renderer only: fixed language lists instead of asking this Mac.
    func installSnapshotTargets(_ targets: [TranslationTarget], source: Locale.Language) {
        targetsAreSample = true
        self.targets = targets
        sourceLanguage = source
    }

    /// For the snapshot renderer only: the server refinement status shown in Settings.
    func installSnapshotRefinementStatus(_ status: RefinementStatus, pair: TranslationPair) {
        guard status != .off else { return }
        snapshot = CaptionSnapshot(pair: pair, status: .listening, refinement: status)
    }

    /// For the snapshot renderer only: the state of the "Test" button.
    func installSnapshotRefinementTest(_ state: RefinementTestState) { refinementTest = state }

    /// For the snapshot renderer only: a model showing `snapshot`, with no translator and no panel.
    init(snapshotPreferences preferences: Preferences, snapshot: CaptionSnapshot, targets: [TranslationTarget] = [],
         speakers: CaptionSpeakers = CaptionSpeakers()) {
        self.preferences = preferences
        self.snapshot = snapshot
        self.targets = targets
        speakerCount = speakers.count
        speakerNames = speakers.names
        isRecording = true
        sourceLanguage = snapshot.pair?.source
    }
    #endif
}
