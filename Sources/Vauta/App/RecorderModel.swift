// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import Observation
import ServiceManagement
import SwiftUI

/// A live segment with a stable identity (`receive` may insert in the middle).
struct LiveSegment: Identifiable {
    let id: Int
    let segment: Segment
}

/// "Nothing from the meeting" while recording: what is wrong and what to check.
struct SilenceNotice: Equatable {
    let title: String
    let detail: String
}

/// The recording controller. Each meeting is written to the encrypted store
/// as final segments arrive (flushed to disk every few seconds and at stop).
///
/// Split by responsibility: `+Lifecycle` (stop, abort, quit), `+Session`
/// (segments, marks, notes, live notes),
/// `+Monitoring` (meters, auto-stop, autosave, retention), `+Presence` (calls
/// and suggestions), `+Services` (model server and notifications),
/// `+History` (Touch ID lock and system events) and `+Settings` (languages,
/// shortcuts, launch at login).
@MainActor
@Observable
final class RecorderModel {
    enum Phase: Equatable {
        case opening, idle, starting, recording, stopping
        /// Only for failures without an active capture (opening the store, starting).
        case failed(String)
    }

    let preferences: Preferences
    /// Live Translation of the "Others" channel (see `+Translation`).
    let liveTranslation: LiveTranslationModel

    // MARK: Observed state (written only by RecorderModel and its extensions)

    var phase: Phase = .opening {
        didSet {
            // Indexing the documents waits while a meeting records and for two minutes after it stops.
            if oldValue == .recording, phase != .recording { recordingStoppedAt = .now }
            if phase == .idle, oldValue != .idle { Task { await detectDeferredFollowUps() } }
            let recordingNow = phase == .recording || phase == .starting
            searchEnvironment.set(recording: recordingNow, stoppedAt: recordingStoppedAt)
            if (oldValue == .recording || oldValue == .starting) != recordingNow { LanguageModelAccess.shared.setRecording(recordingNow) }
            if (oldValue == .recording || oldValue == .starting) != recordingNow, let llm { Task { await llm.environmentChanged() } }
            if (oldValue == .recording || oldValue == .starting) != (phase == .recording || phase == .starting) { documents?.environmentChanged() }
        }
    }
    /// When the last recording stopped (see `DocumentsModel`).
    var recordingStoppedAt: Date?
    /// The documents the person added as knowledge sources.
    var documents: DocumentsModel?
    /// A backup is being restored (Settings → Privacy): the store is being replaced, so Vauta waits to quit.
    var isRestoring = false
    /// Erase Everything is running (Settings → Privacy): the store is being wiped, so no meeting starts and Vauta waits to quit.
    var isErasing = false
    /// The store is being replaced (restored or erased).
    var isReplacingData: Bool { isRestoring || isErasing }
    var startedAt: Date?
    var elapsedSeconds = 0
    /// The recording is paused (`+Pause`): nothing is captured, the meeting stays open.
    var isPaused = false
    /// When the pause that is on began, and whether its reminder was posted (`pauseReminderMinutes`).
    @ObservationIgnored var pausedSince: ContinuousClock.Instant?
    @ObservationIgnored var pauseReminded = false
    /// Final segments, in time order.
    var segments: [LiveSegment] = []
    /// The latest provisional result of each channel, in time order.
    var volatileSegments: [Segment] = []
    /// Level per channel from 0 to 1 (for the meters).
    var levels: [Channel: Double] = [:]
    /// The consent helper's reminder for the recording in progress (see `+Consent`).
    var consentPrompt: ConsentPrompt?
    /// Warnings that don't stop the recording (a segment not saved…).
    var lastError: String?
    /// The system's own text for a warning, shown only as its tooltip. Keyed by the warning.
    var warningDetails: [String: String] = [:]
    /// A failed save as a banner (title, what to do, whether the disk is full), by the message that `saveFailure` returned.
    var warningParts: [String: (title: String, detail: String, isDiskFull: Bool)] = [:]
    /// The autosave failed (it is retried).
    var saveError: String?
    /// Per-channel warnings: microphone or output reconnecting, analyzer down, lagging.
    var channelWarnings: [Channel: String] = [:]
    /// `.others` gets no audio while `.me` does.
    var silenceWarning: SilenceNotice?
    /// A meeting app is in a call but nothing reaches `.others` (once per silent stretch; see `OthersSilenceDetector`).
    var captureAlert: SilenceNotice?
    /// The capture alert already speaks for the silence going on now (raised, and sound has not really returned), so the
    /// panel keeps the ordinary silence banner and the menu-bar warning out of it. Mirrors `silenceDetector`, which is not
    /// observed, so the views update when it flips.
    var captureAlertCoversSilence = false
    /// While recording, where the sound comes out (`OutputRoute`), and whether the microphone was measured to hear the others
    /// (`SpeakerEcho`, for speakers the route can't name: Bluetooth, USB).
    var outputRoute = OutputRoute.unknown
    var speakersHeard = false
    /// The headphones tip was dismissed for this recording.
    var speakersTipDismissed = false
    @ObservationIgnored var outputWatcher: OutputRouteWatcher?
    @ObservationIgnored var lastEchoCheck: ContinuousClock.Instant?

    /// The panel suggests headphones: the sound plays through speakers, or the microphone hears it and it isn't headphones.
    var suggestsHeadphones: Bool {
        isRecording && !speakersTipDismissed && (outputRoute == .speakers || (speakersHeard && outputRoute != .headphones))
    }
    /// What to do about a store that did not open, shown under the cause in the panel (nil while it is open).
    var storeOpenRecovery: String?
    /// The store did not open because the disk is full: the panel offers to open Storage next to Try Again.
    var storeOpenIsDiskFull = false
    /// Why the last recording stopped by itself (silence, sleep, lock…).
    var lastStopReason: RecordingStopReason?
    /// The last recording ended with nothing in it and was removed; the panel says so until it is dismissed or a new one starts.
    var nothingRecorded = false
    /// The start failed for lack of a permission: the panel offers to open System Settings.
    var permissionProblem: SystemPrivacyPane?
    var hotKeyAvailable = false
    var markHotKeyAvailable = false
    var noteHotKeyAvailable = false
    var pauseHotKeyAvailable = false
    var translationHotKeyAvailable = false
    var history: MeetingsModel?
    /// Meetings whose minutes are ready and have not been reviewed (identifiers, counts and a time only): the panel's Follow-up card.
    var followUpPending: [FollowUpPending] = []
    /// Meetings whose card was reviewed or dismissed in this session (identifiers only): rewriting their minutes does not bring it back.
    @ObservationIgnored var followUpHandled: Set<Int64> = []
    /// Bumped when the card's 2 hours run out, so the panel draws again.
    var followUpTick = 0
    @ObservationIgnored var followUpExpiry: Task<Void, Never>?
    var context: ContextModel?
    /// "Meetings" and "Context" are unlocked (Touch ID or password).
    var historyUnlocked = false

    /// Expected time of the automatic stop if the silence goes on.
    var pendingAutoStopAt: Date?
    /// The meeting app released the microphone while recording ("did you hang up?").
    var hangupNotice = false
    /// The recording ended: the notepad shows where to keep adding notes (the meeting it was saved as).
    var notepadSavedMeeting: Int64?
    /// Changing it asks the notepad's field for the keyboard (the shortcut was pressed).
    var notepadFocusRequest = 0
    var marks: [MeetingMark] = []
    /// The user's shorthand notes of the recording and what the model wrote from them (see `+Notepad`).
    let notepad = NotepadModel()
    /// The floating notepad (see `NotepadPanelController`).
    @ObservationIgnored let notepadWindow = NotepadPanelController()
    /// Hide Vauta Windows, for presenting (see `+Concealment`); `notepadComesBack`: the notepad was open, or was to open by
    /// itself, while they were hidden.
    let concealer = WindowConcealer()
    @ObservationIgnored var notepadComesBack = false
    /// The Answers card: answers to the questions heard in the meeting (see `+LiveAnswers`).
    let answers = LiveAnswersModel()
    /// The detector of the recording in progress, and the order in which lines reach it.
    @ObservationIgnored var questionDetector: QuestionDetector?
    @ObservationIgnored var questionChain: Task<Void, Never>?
    /// What the detector says reaches the card through one stream, so the events are applied in the order they happened.
    @ObservationIgnored var answerBridge: LiveAnswersBridge?
    /// What the running detector started with: only the switch changes during a recording.
    @ObservationIgnored var runningAnswerSettings: LiveAnswerSettings?
    /// The backend that answered while recording the last time the model status changed.
    @ObservationIgnored var lastLiveAnswersBackend: LiveAnswerBackendKind?
    /// The meeting the live-answers detector runs for (its unkept questions are removed when it ends, if the person asked for that).
    @ObservationIgnored var questionMeetingID: Int64?
    @ObservationIgnored let liveAnswerEnvironment = LiveAnswerEnvironmentBox()
    /// Who "Others" is: search in the context (200 ms debounce).
    var othersQuery = "" {
        didSet {
            guard othersQuery != oldValue else { return }
            othersNotice = nil
            searchOthers(othersQuery)
        }
    }
    /// Why the typed name was not added (it is the user's own name), shown under the field until the text changes.
    var othersNotice: String?
    var othersHits: [NameHit] = []
    /// The query `othersHits` belong to (Return never picks stale results).
    var othersHitsQuery = ""
    var othersNamed: [Entity] = []
    /// The voices of the other participants told apart so far, by the number they have while recording (Speaker 2 is 2),
    /// and who the user said each one is. The numbers are provisional: the final clustering may renumber them when the
    /// meeting ends, so a name is carried over by where the voice was heard (`LiveSpeakers.carryOver`).
    var liveSpeakers: [Int] = []
    var liveSpeakerPeople: [Int: Entity] = [:]
    /// The voice the "Their name" field is for; nil follows the voice heard last.
    var chosenLiveSpeaker: Int?
    /// The voice kept while the user types a name or points at the naming tools (see `updateLiveNamingPin`).
    var pinnedLiveSpeaker: Int?
    var pointerInLiveNaming = false
    var latestLiveSpeaker: Int?
    /// After a recording whose speakers were told apart: the names shown while recording may have changed.
    var speakersUpdated = false
    /// The meeting that notice is about, for its button.
    var speakersUpdatedMeetingID: Int64?
    /// Attendees of the calendar event (suggestions for "Others").
    var attendees: [Entity] = []

    let calendar = CalendarWatcher()
    /// The pre-meeting brief: the card in the panel, Upcoming in Meetings and the notification.
    let brief = BriefController()
    /// "Transcribe this meeting?": a call in progress, with its calendar event if any.
    var suggestion: RecordingSuggestion?
    /// Suggest recording when a meeting app starts a call (with or without the calendar).
    var suggestOnCall: Bool {
        didSet { UserDefaults.standard.set(!suggestOnCall, forKey: Self.noCallSuggestionKey) }
    }

    var llm: LLMService?
    /// The optional search model (Settings → Models): its status, the indexing progress and the actions.
    let searchModel = SearchModelModel()
    /// The optional integrated language model (Settings → Models): its status and the actions.
    let integratedModel = IntegratedModelModel()
    /// The recording state as the search model's pause rules read it (from any thread).
    @ObservationIgnored let searchEnvironment = SearchEnvironmentBox()
    @ObservationIgnored var searchObservers: [NSObjectProtocol] = []
    /// Moving to or from the charger releases or holds the embedding jobs that wait for it.
    @ObservationIgnored var powerSourceWatcher: PowerSourceWatcher?
    var llmStatus = LLMService.Status()
    /// Chosen server and models (Settings › Models); nil = not configured, or
    /// the Keychain was locked at launch (see `serverConfigUnavailable`).
    var serverConfig: LLMServerConfig?
    /// The Keychain was locked when the configuration was read: it may exist,
    /// so Settings must not treat the server as unconfigured.
    var serverConfigUnavailable = false
    /// A server key is in the Keychain (the interface never reads its value).
    var hasServerKey: Bool
    /// Live notes of the recording in progress.
    var livePoints: [String] = []
    var liveDecisions: [String] = []
    var liveTasks: [String] = []
    var liveNotesError: LiveNotesNotice?
    /// The second speed of retention (days; 0 = no limit; 90 = everything at 90).
    /// Purges at once when shortened: Settings must confirm BEFORE assigning.
    var knowledgeRetentionDays: Int {
        didSet {
            UserDefaults.standard.set(knowledgeRetentionDays, forKey: Self.knowledgeKey)
            let days = knowledgeRetentionDays
            Task {
                await store?.setKnowledgeRetention(days: days)
                if (try? await store?.purgeExpired()) ?? 0 > 0 {
                    await llm?.forgetPastTranscripts()
                    await history?.reloadIfShowing()
                }
            }
        }
    }
    /// A known meeting app holds the microphone (see `callApp`).
    var callInProgress = false
    /// The meeting app family that holds the microphone right now, if any.
    var callApp: MeetingAppFamily?
    /// The app and service of the call in progress, as shown to the user.
    var currentCall: CallDescription?

    /// Minutes of silence on both channels before stopping (2–30).
    var autoStopMinutes: Int {
        didSet { UserDefaults.standard.set(autoStopMinutes, forKey: Self.autoStopKey) }
    }
    /// Dictation with vocabulary per channel (experimental).
    var dictationMe: Bool {
        didSet { UserDefaults.standard.set(dictationMe, forKey: Self.dictationMeKey) }
    }
    var dictationOthers: Bool {
        didSet { UserDefaults.standard.set(dictationOthers, forKey: Self.dictationOthersKey) }
    }
    /// The live transcript is hidden by default (in case the screen is shared).
    var showTranscript = false
    /// Which system audio becomes "Others": some meeting apps, the app in the
    /// call (auto), or everything except Vauta.
    var audioSource: SystemAudioScope {
        didSet { audioSource.save(to: .standard) }
    }

    // Per recording
    /// Language of the recording in progress.
    var recordingLanguage: SpeechLanguage?
    /// The concrete audio source of the recording in progress (`.auto` resolved).
    var recordingSource: SystemAudioScope?
    /// The meeting app recorded as the source of the recording in progress.
    var recordingApp: CallDescription?

    // Languages
    var speechCatalog: SpeechLanguageCatalog?
    /// The model the last start needed and didn't find (the panel offers to install it).
    var missingModel: MissingSpeechModel?
    /// The speech model downloads of the whole app: setup, Settings and the panel start and read the same ones, so a
    /// download begun in one place is seen (and not started again) in the others.
    @ObservationIgnored let speechDownloads = SpeechSettingsModel()

    var launchAtLoginStatus: SMAppService.Status = SMAppService.mainApp.status
    /// Bumped when the keyboard layout changes (shortcut labels follow it).
    var keyboardLayoutRevision = 0
    /// Seconds left before the automatic stop (nil without a warning).
    var autoStopRemaining: Int?

    var isRecording: Bool { phase == .recording }
    /// Replacing or erasing the store must wait: a recording is running, about to start, or still being saved (the meeting
    /// is written to the store until the phase is back to idle).
    var blocksDataReplacement: Bool { phase == .recording || phase == .starting || phase == .stopping }
    var isBusy: Bool { phase == .starting || phase == .stopping || phase == .opening }
    var storeAvailable: Bool { history != nil }
    /// An outcome to know about, not a problem (an automatic stop, an empty recording): the panel shows it as an info
    /// notice and the menu-bar icon stays a plain waveform.
    var hasNotice: Bool { lastStopReason != nil || nothingRecorded || speakersUpdated }
    var hasWarning: Bool {
        if case .failed = phase { return true }
        // The silence warning the capture alert has taken over is not shown, so it must not light the menu-bar icon either.
        return lastError != nil || saveError != nil || (silenceWarning != nil && !captureAlertCoversSilence) || captureAlert != nil || !channelWarnings.isEmpty
            || pendingAutoStopAt != nil || hangupNotice || missingModel != nil
    }
    var elapsed: String { ElapsedTime.stamp(elapsedSeconds) }
    /// Seconds into the meeting, where "now" is in the transcript: seconds since the first captured audio, on the capture's monotonic clock, so
    /// marks, notes and live notes line up with the segments. The wall clock since the start only before any audio.
    var currentOffset: Double {
        capture?.elapsedSeconds ?? startedAt.map { max(0, AppClock.now.timeIntervalSince($0)) } ?? 0
    }
    /// Something must be closed or saved before quitting.
    var needsGracefulStop: Bool { capture != nil || phase == .starting || phase == .stopping || stopTask != nil || store != nil }

    static let noCallSuggestionKey = "noSafariCallSuggestion"   // 0.1.0 key, inverted
    static let knowledgeKey = "knowledgeRetentionDays"
    static let autoStopKey = "autoStopMinutes"
    static let dictationMeKey = "dictationMe"
    static let dictationOthersKey = "dictationOthers"
    /// The meeting being recorded, kept until it is closed: if Vauta quits
    /// abruptly, the next launch writes its minutes (recovery closed it).
    static let recordingMeetingKey = "recordingMeetingID"

    // MARK: Internal state

    @ObservationIgnored var store: MeetingStore?
    @ObservationIgnored var opening: Task<Void, Never>?
    @ObservationIgnored var capture: MeetingCapture?
    /// Separates the speakers of the Others channel during this recording; nil when speaker separation is off.
    @ObservationIgnored var diarizer: Diarizer?
    /// Analysed windows on their way from the diarizer's queue to the store. A new one per recording (`makeDiarizer`),
    /// so a sink call still in flight from an abandoned recording can never fill the next one's.
    @ObservationIgnored var windowSpool = WindowSpool()
    @ObservationIgnored var meetingID: Int64?
    @ObservationIgnored var volatile: [Channel: Segment] = [:]
    @ObservationIgnored var nextSegmentID = 0
    /// Segments in order towards `persist`.
    @ObservationIgnored var segmentInput: AsyncStream<Segment>.Continuation?
    @ObservationIgnored var consumer: Task<Void, Never>?
    /// Writes in order: each waits for the previous one.
    @ObservationIgnored var writes: Task<Void, Never>?
    @ObservationIgnored var ticker: Task<Void, Never>?
    @ObservationIgnored var autosave: Task<Void, Never>?
    @ObservationIgnored var stopTask: Task<Void, Never>?
    @ObservationIgnored var stopRequested = false
    /// The capture's start was given up while it was still waiting on macOS (`GiveUp`): it is stopped when it ends, never by
    /// the abort, which would wait on the same call.
    @ObservationIgnored var captureLeftStarting = false
    /// Something from this session didn't reach the store: the panel isn't cleared at stop.
    @ObservationIgnored var sessionLostData = false
    /// Monotonic clock: a clock change doesn't move the stop. nil = never heard.
    @ObservationIgnored var lastOthersHeard: ContinuousClock.Instant?
    @ObservationIgnored var lastMeHeard: ContinuousClock.Instant?
    @ObservationIgnored var silenceDetector = OthersSilenceDetector()
    @ObservationIgnored var hotKey: GlobalHotKey?
    @ObservationIgnored var markHotKey: GlobalHotKey?
    @ObservationIgnored var noteHotKey: GlobalHotKey?
    @ObservationIgnored var pauseHotKey: GlobalHotKey?
    @ObservationIgnored var translationHotKey: GlobalHotKey?
    /// Store row of each final segment of the recording (by `LiveSegment.id`), so translations can refer to it.
    @ObservationIgnored var segmentRowIDs: [Int: Int64] = [:]
    /// Ended recordings whose translator may still deliver late answers from the model server (by recording number).
    @ObservationIgnored var endedTranslationTargets: [Int: EndedTranslationTarget] = [:]
    /// Shortcut fields listening for a new combination (both may be at once).
    @ObservationIgnored var hotKeySuspensions = 0
    var hotKeysSuspended: Bool { hotKeySuspensions > 0 }
    @ObservationIgnored let notifier = Notifier()
    @ObservationIgnored var presence: MeetingPresence?
    @ObservationIgnored var othersSearch: Task<Void, Never>?
    /// A call was seen during this recording (for "did you hang up?").
    @ObservationIgnored var sawCallThisSession = false
    @ObservationIgnored var hangupTimer: Task<Void, Never>?
    /// Puts "Copied" back to "Copy Notice" after a moment.
    @ObservationIgnored var consentCopyReset: Task<Void, Never>?
    /// The suggestion was dismissed (not repeated until the next call).
    @ObservationIgnored var suggestionDismissed = false
    /// The live pass over the user's notes: one at a time, and when it last failed (see `+Notepad`).
    @ObservationIgnored var noteExpansionTask: Task<Void, Never>?
    @ObservationIgnored var noteRecheck: Task<Void, Never>?
    @ObservationIgnored var noteExpansionToken: UUID?
    @ObservationIgnored var noteAttempts: [Int64: Int] = [:]
    @ObservationIgnored var notepadClose: Task<Void, Never>?
    /// A new recording is waiting for the last meeting's unsaved note to be written.
    @ObservationIgnored var savingNoteBeforeStart = false
    @ObservationIgnored var liveNotesTask: Task<Void, Never>?
    @ObservationIgnored var liveNotesToken: UUID?
    @ObservationIgnored var lastLiveNotes: ContinuousClock.Instant?
    @ObservationIgnored var charsSinceLiveNotes = 0
    /// "Update Now" was pressed and is waiting for the run in flight to end (see `updateLiveNotesNow`).
    @ObservationIgnored var liveNotesAsked = false
    /// Observed by the Live notes card: a run is in flight, and text arrived since the last one started.
    var liveNotesRunning = false
    var liveNotesHaveNewText = false
    /// "Can't reach the model server" was already notified for this recording.
    @ObservationIgnored var serverDownNotified = false
    @ObservationIgnored var unlock: UnlockWindow
    @ObservationIgnored var relockTimer: Task<Void, Never>?
    @ObservationIgnored var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored var retention: Task<Void, Never>?
    @ObservationIgnored var modelInstall: Task<Void, Never>?
    /// Exactly one enableSuddenTermination per disable.
    @ObservationIgnored var suddenTerminationDisabled = false
    /// Window actions from the menu-bar label (the only view that always exists).
    @ObservationIgnored var openWindowAction: OpenWindowAction?
    /// Settings' state, to open it on a given pane.
    @ObservationIgnored var settingsModel: SettingsModel?
    @ObservationIgnored var dismissWindowAction: DismissWindowAction?

    init(preferences: Preferences) {
        self.preferences = preferences
        liveTranslation = LiveTranslationModel(preferences: preferences)
        hasServerKey = ((try? ServerCredentials.sessionBearer()) ?? nil).map { !$0.isEmpty } ?? false
        do {
            serverConfig = try LLMServerConfig.load()
        } catch {
            serverConfigUnavailable = true
        }
        let defaults = UserDefaults.standard
        // A new install (no saved setting, no store) starts on Auto. Save the
        // choice now: once the first meeting creates a store, this Mac no
        // longer looks new.
        let hadScope = SystemAudioScope.hasSavedValue(in: defaults)
        let scope = SystemAudioScope(defaults: defaults, newInstall: !MeetingStore.existsAtDefaultLocation)
        if !hadScope { scope.save(to: defaults) }
        audioSource = scope
        let minutes = defaults.integer(forKey: Self.autoStopKey)
        autoStopMinutes = (2...30).contains(minutes) ? minutes : 5
        dictationMe = defaults.bool(forKey: Self.dictationMeKey)
        dictationOthers = defaults.bool(forKey: Self.dictationOthersKey)
        suggestOnCall = !defaults.bool(forKey: Self.noCallSuggestionKey)
        let keep = defaults.object(forKey: Self.knowledgeKey) as? Int ?? MeetingStore.retentionDays
        knowledgeRetentionDays = [0, MeetingStore.retentionDays, 365, 730].contains(keep) ? keep : MeetingStore.retentionDays
        unlock = UnlockWindow(interval: preferences.relockPolicy.interval)
        applyHotKeys()
        speechDownloads.onInstallFinished = { [weak self] in await self?.speechDownloadFinished() }
        liveTranslation.onFinal = { [weak self] final, recording in self?.storeTranslation(final, recording: recording) }
        liveTranslation.lingeringDone = { [weak self] recording in self?.endedTranslationTargets[recording] = nil }
        liveTranslation.llm = { [weak self] in self?.llm }
        notifier.onAction = { [weak self] action, meetingID, occurrence in self?.handle(action, meetingID: meetingID, occurrence: occurrence) }
        notifier.isShowingMeeting = { [weak self] id in
            guard let self, historyUnlocked, let history, history.isShowing, history.selectedID == id else { return false }
            return NSApp.keyWindow?.identifier?.rawValue.hasPrefix("meetings") == true
        }
        presence = MeetingPresence { [weak self] state in
            MainActor.assumeIsolated { self?.presenceChanged(state) }
        }
        calendar.onEventStart = { [weak self] in self?.considerSuggestion() }
        calendar.onChange = { [weak self] in self?.brief.calendarChanged() }
        brief.start(recorder: self)
        preferences.liveAnswersBackend = { [weak self] in self?.liveAnswersBackendNow() }
        openStore()
        observeSystemEvents()
        observePreferences()
    }

    #if VAUTA_DIAGNOSTICS
    /// For `Vauta render-ui` only: a recorder on a sample store. It reads no
    /// Keychain item, opens no real store and registers no shortcut, observer
    /// or capture (see Snapshots/).
    init(snapshotPreferences preferences: Preferences, store: MeetingStore) {
        self.preferences = preferences
        liveTranslation = LiveTranslationModel(preferences: preferences)
        hasServerKey = false
        audioSource = .auto
        autoStopMinutes = 5
        dictationMe = false
        dictationOthers = false
        suggestOnCall = true
        knowledgeRetentionDays = MeetingStore.retentionDays
        unlock = UnlockWindow(interval: preferences.relockPolicy.interval)
        self.store = store
        history = MeetingsModel(store: store)
        context = ContextModel(store: store)
        history?.preferences = preferences
        brief.installSnapshotState(next: nil, upcoming: .off)
        brief.prefs.installSnapshotDefaults()
        history?.brief = brief
        preferences.liveAnswersBackend = { [weak self] in self?.liveAnswersBackendNow() }
        historyUnlocked = true
        phase = .idle
        hotKeyAvailable = true
        markHotKeyAvailable = true
        noteHotKeyAvailable = true
        pauseHotKeyAvailable = true
        translationHotKeyAvailable = true
    }
    #endif

    // MARK: Store

    /// Opens the store off the main thread (Keychain + decryption). If it fails
    /// (e.g. the Keychain prompt was cancelled) it can be retried: that path
    /// never creates a new key.
    func openStore() {
        guard store == nil, opening == nil else { return }
        phase = .opening
        opening = Task {
            do {
                let keepDays = knowledgeRetentionDays
                let store = try await Task.detached(priority: .userInitiated) {
                    try MeetingStore(recoverOpenMeetings: true, knowledgeRetentionDays: keepDays)
                }.value
                self.store = store
                history = MeetingsModel(store: store)
                context = ContextModel(store: store)
                // Activity in Meetings postpones the automatic relock.
                history?.onActivity = { [weak recorder = self] in recorder?.touchHistory() }
                history?.preferences = preferences
                history?.brief = brief
                // The Follow-up sheet opened from the window (not by Review…) clears the panel's card for that meeting.
                history?.actions.onFollowUpOpened = { [weak recorder = self] id in recorder?.followUpHandled.insert(id); recorder?.followUpPending.removeAll { $0.meetingID == id } }
                history?.ask.onAsked = { [weak recorder = self] text in recorder?.noteManualQuestion(text) }
                // An import that finishes while Meetings is closed or locked says so with a notification.
                history?.onImportedWhileHidden = { [weak recorder = self] id in recorder?.post(.recordingImported(meetingID: id)) }
                history?.onGlossaryChanged = { [weak recorder = self] in Task { await recorder?.context?.reload() } }
                history?.onErased = { [weak recorder = self] in
                    // The meetings the list names are gone, and the new database reuses their ids.
                    recorder?.preferences.questionCleanup.clear()
                    // The templates the person wrote went with the rest, and the new database reuses their ids.
                    if recorder?.preferences.minutesTemplate.isCustom == true { recorder?.preferences.minutesTemplate = .general }
                    if let recorder { Task { await recorder.settingsModel?.minutesTemplates.reload(recorder) } }
                    recorder?.context?.purge()
                    Task { await recorder?.context?.reload() }
                    recorder?.documents?.dataReplaced()
                    recorder?.brief.erased()
                }
                phase = .idle
                storeOpenRecovery = nil
                storeOpenIsDiskFull = false
                startRetention()
                startLLM(store)
                brief.storeOpened()
            } catch let e as StoreError where e.kind == .alreadyOpen {
                // Another instance holds the store: say so and quit without touching anything.
                phase = .failed(String(localized: "Vauta is already running.", comment: "Store open failure"))
                let alert = NSAlert()
                alert.messageText = String(localized: "Vauta is already running", comment: "Alert title")
                alert.informativeText = String(localized: "Use the copy in the menu bar. This one quits without touching your meetings.",
                                               comment: "Alert text when a second instance starts")
                NSApp.activate()
                alert.runModal()
                NSApp.terminate(nil)
            } catch {
                // Only the cause: the locked window already carries the title "Your data couldn’t be opened".
                (phase, storeOpenRecovery) = Self.storeOpenFailure(error)
                storeOpenIsDiskFull = SaveFailure.cause(of: error) == .diskFull
            }
            opening = nil
        }
    }

    /// What the panel and the locked windows say for a store that did not open: the cause and the next step. When the
    /// cause is known (the disk is full) the generic sentence adds nothing, so only that cause and its next step show.
    static func storeOpenFailure(_ error: Error) -> (phase: Phase, recovery: String?) {
        if SaveFailure.cause(of: error) == .diskFull, (error as? LocalizedError)?.recoverySuggestion == nil {
            return (.failed(recovery(forStoreError: error)), nil)
        }
        return (.failed(error.localizedDescription), recovery(forStoreError: error))
    }

    /// The next step for a store that did not open: the error's own suggestion, or what to check for a disk problem.
    static func recovery(forStoreError error: Error) -> String {
        if let suggestion = (error as? LocalizedError)?.recoverySuggestion { return suggestion }
        switch SaveFailure.cause(of: error) {
        case .diskFull:
            return String(localized: "The disk is full. Free up space, then try again.",
                          comment: "Panel warning under the title when a save failed because the disk is full")
        case .noPermission:
            return SaveFailure.nextStep(for: error)
        case .other:
            return String(localized: "Make sure the disk has free space, then try again.",
                          comment: "Panel warning under the cause when the encrypted store could not be opened and nothing more specific is known")
        }
    }
}
