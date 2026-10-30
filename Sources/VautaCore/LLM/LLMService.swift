// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Orchestrates everything Vauta asks of the models, on a model server or on
/// this Mac (see `ModelProviderSettings`). One request in flight, by
/// priority: Ask (0) > answers to questions heard (1) > live notes (2) > background: embeddings and minutes (3).
/// Rules:
/// - Background jobs wait while recording (live notes use the fast model and
///   a model switch would delay them) and while another client says it is
///   using the server.
/// - Ask interrupts a background job (it goes back to the queue).
/// - Retries happen on "busy" (capped), network errors and a locked
///   Keychain; the queue is persistent.
///
/// Split by responsibility: `+Queue` (background jobs, cancel, events),
/// `+Minutes`, `+Live`, `+Ask`, `+Embeddings` and `+Lane`.
public actor LLMService {
    public struct Status: Sendable, Equatable {
        /// A chat model can be used (the server is set up, or the on-device model is ready).
        public var configured = false
        /// A model server is set up (whatever provider is chosen for chat), so it can refine live translations.
        public var serverConfigured = false
        /// Where chat and embeddings run, as chosen in Settings.
        public var chatProvider: ModelProviderSettings.Chat = .server
        public var embeddingsProvider: ModelProviderSettings.Embeddings = .server
        /// Why the chat model cannot be used now (nil when it can).
        public var issue: ProviderIssue?
        /// Why Ask cannot use semantic search now (it still works with keywords).
        public var searchIssue: ProviderIssue?
        /// nil = not checked yet.
        public var reachable: Bool?
        public var lastError: String?
        /// What it is doing now, without meeting content ("Writing minutes", "Live notes"…).
        public var activity: String?
        public var activityMeeting: Int64?
        public var activityStarted: Date?
        /// The activity is a question being answered (not minutes or another job): its stage belongs to that question.
        public var activityIsAsk = false
        public var progressTokens = 0
        /// The stage of the minutes or the answer being written (the integrated model reports it; other providers leave it nil).
        public var stage: Stage?
        /// Tokens of the prompt read so far and in all, while the integrated model reads a meeting (nil otherwise).
        public var prefill: PrefillProgress?
        /// The person chose the integrated model but Apple's writes for now (it is not ready, damaged or unsupported).
        public var integratedFallback: IntegratedModelIssue?
        /// The integrated model is reading the meeting while it is recorded, so the minutes start within seconds when it ends.
        public var readingMeeting = false
        public var queued = 0
        public var models: [String] = []
        public var lastCacheHit: Int?
        /// Configured models the server does not list (misspelled or not downloaded).
        public var missingModels: [String] = []
        /// The server keeps answering "busy": background work resumes at this time.
        public var busyUntil: Date?
        /// How much of the library is indexed for search by meaning with the search model (nil when it is not in use).
        public var searchIndex: SearchIndexStatus?
        public init() {}
    }

    /// What the model is doing for the person right now, for the progress line.
    public enum Stage: Sendable, Equatable {
        case readingTranscript
        case writingMinutes
        /// The second pass over a long meeting looks for decisions and tasks one stretch at a time.
        case findingItems(part: Int, of: Int)
        case checkingAnswer
    }

    public struct PrefillProgress: Sendable, Equatable {
        public var done: Int
        public var total: Int
        public init(done: Int, total: Int) { self.done = done; self.total = total }
        public var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    }

    public enum Priority: Int, Comparable, Sendable {
        /// `auto`: the answer to a question heard in the meeting (live answers): after the person's own question, before the live notes.
        case ask = 0, auto = 1, live = 2, background = 3
        public static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    /// A background job finished, failed for good or was cancelled (drives
    /// "minutes ready" notifications and the meetings window). Emitted for
    /// both job kinds; most callers only care about `.minutes`.
    public struct JobEvent: Sendable, Equatable {
        public enum Outcome: Sendable, Equatable {
            case succeeded
            /// Failed for good (no more automatic retries); localized message.
            case failed(String)
            case cancelled
        }
        public let meetingID: Int64
        public let kind: LLMJob.Kind
        public let outcome: Outcome
        public init(meetingID: Int64, kind: LLMJob.Kind, outcome: Outcome) {
            self.meetingID = meetingID
            self.kind = kind
            self.outcome = outcome
        }
    }

    let store: MeetingStore
    let providers: any ModelProviding
    /// The index of the person's documents, when they added any (Ask also answers from it).
    var documents: DocumentIndex?
    var status = Status()
    private var onStatus: (@Sendable (Status) -> Void)?
    var onJobEvent: (@Sendable (JobEvent) -> Void)?
    var recording = false
    /// Meetings whose lines were embedded on demand while they were recorded (E3): their partial chunks are removed when the recording ends.
    var onDemandMeetings: Set<Int64> = []
    /// Tests: runs after a meeting is recorded as holding typed-question chunks and before they are stored.
    var beforeOnDemandChunksStored: (@Sendable () async -> Void)?
    func setBeforeOnDemandChunksStored(_ hook: (@Sendable () async -> Void)?) { beforeOnDemandChunksStored = hook }
    /// What the checks did to the last minutes this service wrote: counts and reasons, never text.
    public internal(set) var lastMinutesDiagnostics: MinutesDiagnostics?
    /// The decisions Apple's "was it decided?" check dropped in the last minutes (for the evaluation of public transcripts; never logged).
    public internal(set) var lastDecidedDrops: [String] = []
    var externalBusy = false
    /// A backup is being restored: no background job starts (see `pauseForRestore`).
    var restoring = false

    // Background queue.
    var worker: Task<Void, Never>?
    /// Wakes up for the next deferred job (Retry-After, retries).
    var wakeup: Task<Void, Never>?
    /// Questions waiting for the lane: background work yields as soon as it gets it.
    var askWaiting = 0
    /// Meetings whose leftover notes were tried in this launch (see `expandLeftoverNotes`).
    var leftoverTried = Set<Int64>()
    var backgroundTask: Task<Void, Error>?
    /// The answer to a question heard that is running (at most one), and whether the person's own question took its place.
    var autoTask: Task<AskResult, Error>?
    var autoSuperseded = false
    /// How long the model check of a heard question may take once it has the model (tests lengthen it: a loaded Mac starves them).
    var liveCheckSeconds = 6.0
    /// Whether decision D16 (no live answers on Apple's model) is enforced; only the evaluation turns it off.
    nonisolated let liveAnswerGate = LiveAnswerGate()
    /// The job the queue is working on (also while it waits for the lane).
    var currentJob: LLMJob?
    /// Jobs the user cancelled while they were running or about to run.
    var cancelledJobs: Set<Int64> = []
    /// Consecutive "busy" answers per job (capped, see `maxBusyRetries`).
    var busyRetries: [Int64: Int] = [:]

    // Single lane with priorities.
    var laneBusy = false
    var laneOwner: Priority?
    var waiters: [Waiter] = []
    var seq = 0

    /// Live-translation requests to the server in flight: live notes wait for them (see `+Translation`).
    var refinementsInFlight = 0

    /// Which parts of the integrated minutes are on (the evaluation turns some off).
    var minutesArms = MinutesArms.shipped
    /// Which parts of the extraction of decisions, tasks and owners are on (the evaluation compares the old and the new one).
    /// `nil` runs the release choice for the backend (`MinutesRelease.extraction(integrated:)`); `setMinutesExtraction` forces a value.
    var minutesExtractionOverride: MinutesExtraction?
    /// Whether the minutes on a model server reason first, after how often their reasoning ran past the limit.
    var minutesReasoning = MinutesReasoningMemory()
    /// Which parts of the outcome-first summary are on. `nil` runs the release choice for the backend (`MinutesSummaryRelease.summary(integrated:)`);
    /// `setMinutesSummary` forces a value (the evaluation compares the old and the new one).
    var minutesSummaryOverride: MinutesSummary?
    /// Which parts of the integrated model's items-first minutes request are on. `nil` runs the release choice for the backend
    /// (`MinutesHarnessRelease.harness(integrated:)`); `setMinutesHarness` forces a value (the evaluation compares the old and the new one).
    var minutesHarnessOverride: MinutesHarness?
    /// Which parts of the open questions' checks are on. `nil` runs the release choice for the backend (`MinutesQuestionsRelease.questions(integrated:)`);
    /// `setMinutesQuestions` forces a value (the evaluation compares the old and the new one).
    var minutesQuestionsOverride: MinutesQuestions?
    var answerGuards = AnswerGuards.shipped
    /// Which parts of Ask's request and retrieval are on. `nil` runs the release choice for the backend (`AskHarnessRelease.harness(integrated:)`);
    /// `setAskHarness` forces a value (the evaluation compares the old and the new one).
    var askHarnessOverride: AskHarness?
    /// Bounded reasoning in a model server's Ask after the meeting. `nil` runs the release choice (`AskReasoningRelease.serverAfterMeeting`).
    var serverAskReasoningOverride: Bool?
    /// Which parts of the notepad expansion on the small window are on. `nil` runs the release choice (`NoteHarnessRelease.harness(integrated:)`);
    /// `setNoteHarness` forces a value (the evaluation compares the old and the new one).
    var noteHarnessOverride: NoteHarness?
    /// Which parts of the live notes are on. `nil` runs the release choice (`LiveHarnessRelease.harness(integrated:)`);
    /// `setLiveHarness` forces a value (the evaluation compares the old and the new one).
    var liveHarnessOverride: LiveHarness?
    /// Apple's decisions are read once more for "was it decided?" (`keepDecided`). Off by default (decided on 2026-10-15): it
    /// dropped about as many true decisions as false ones. `setDecidedFilter(true)` / `llm-eval --decided on` turn it on.
    var decidedFilter = false
    /// Guided generation for Apple's answers: off until the 52-question gate is run on Apple's model; `VAUTA_APPLE_GUIDED=1` turns it on
    /// for the evaluation.
    var appleGuidedAsk = ProcessInfo.processInfo.environment["VAUTA_APPLE_GUIDED"] == "1"
    var warmCadence = WarmCadence()
    var itemsPassBudget = (floor: LLMService.itemsPassFloor, share: LLMService.itemsPassShare)

    // Reading the meeting while it is recorded (the integrated model; see `+Warm`).
    var warm: WarmState?
    /// The meeting whose prefix is pinned after its recording, until its minutes are written.
    var warmMeetingKept: Int64?
    /// The meetings whose transcript the Ask prefix may hold. A meeting is added when a call that writes the prefix starts (the prefix
    /// exists even when the call then fails, throws or is cancelled), and the slot holds one prefix at a time, so a meeting stays in the
    /// set until the slot is dropped: deleting any of them drops the whole slot.
    var askPrefixMeetings: Set<Int64> = []
    /// The same for the meeting slot when it is not the one being recorded (minutes of a past meeting that found the slot free).
    var meetingSlotMeetings: Set<Int64> = []
    /// The newest report of the model's reading that was applied (reading, report number): older ones that arrive late are ignored.
    var lastPrefillReport: (reader: Int, sequence: Int)?

    // Live notes (a prompt that only grows at the end, so the server cache is reused).
    var live: LiveSession?
    /// The meeting being recorded, when the app told the service which.
    var liveSessionMeeting: Int64? { live?.meetingID }
    struct LiveSession {
        let meetingID: Int64
        let language: OutputLanguage
        var entities: ChatMessage
        var lines: [String] = []
        var lastSegment: Int64 = 0
        var segmentIDs: Set<Int64> = []
        var previous: [String] = []
        /// What the live-notes checks need (`LiveHarness`): the text of each line read, the lines of the user's own microphone, the notes taken so far.
        var texts: [Int64: String] = [:]
        var mine: Set<Int64> = []
        var taken: [LiveCheck.Earlier] = []
    }

    /// Vector sizes seen for each embedding model in this session: a change
    /// (new truncation setting, another model under the same name) means
    /// the stored chunks are in another space.
    var knownDimensions: [String: Int] = [:]
    /// Meetings whose chunk text was compared with their transcript this session and found current.
    var textChecked = Set<Int64>()
    /// The search model is being deleted: embedding work that uses it stops and stores nothing until `searchModelRemoved` ends.
    var searchModelRetiring = false
    /// Translates a question into the transcripts' language for keyword search (E4); nil = questions are always searched as asked.
    var queryTranslator: QueryTranslator?
    /// Overrides the stored switch of `embedLivePrefix` (E3, on demand): tests and the evaluation.
    var embedLivePrefixOverride: Bool?
    /// Where complete-coverage markers are kept (`searchModelCoverageReached.*`).
    let searchDefaults: UserDefaults
    /// What the Mac is doing (recording, power, heat), set by the app.
    var environmentProvider: @Sendable () -> IndexerEnvironment = { IndexerEnvironment() }

    // Links to earlier meetings (post-meeting actions, Part B; see `+Links`).
    /// Forces the link policy (tests and the evaluation); `nil` runs the release choice for the backend (`LinksRelease`).
    var linkPolicyOverride: LinkPolicy?
    /// Meetings whose link pass had to wait (recording, Low Power Mode, heat) and runs when the Mac is quiet again.
    var linksWaiting: Set<Int64> = []
    /// The waiting passes that were to be followed by the model check (the check runs in the `embed` job, which is queued again).
    var linksWaitingCheck: Set<Int64> = []
    /// A pass wrote the suggestions of this meeting (the open window reloads them).
    var onLinksChanged: (@Sendable (Int64) -> Void)?
    var linksRetry: Task<Void, Never>?
    /// The short wait after an edit, per meeting, so several edits make one pass.
    var linkEditTimers: [Int64: Task<Void, Never>] = [:]
    /// Evaluation only: the `embed` job leaves the meeting's chunks alone and embeds its items (the links evaluation measures the items).
    var evaluationSkipsChunks = false
    /// How long after an edit the pass runs (2 s by design; tests shorten it).
    var linkEditDelay: Duration = .seconds(2)
    /// What the last passes did: counts and timings only, never text (the evaluation reads it).
    public internal(set) var linkTraces: [LinkTrace] = []

    /// Reads the server configuration from the Keychain and the provider
    /// choice from `defaults`. If the Keychain is locked, the service starts
    /// without a server and reads it again on the next `kick()`.
    public init(store: MeetingStore, client: LLMClient = LLMClient(), defaults: UserDefaults = .standard) {
        self.init(store: store, providers: SystemModelProviders(client: client, defaults: defaults), searchDefaults: defaults)
    }

    /// With a fixed server configuration (tools and tests).
    public init(store: MeetingStore, config: LLMServerConfig?, client: LLMClient = LLMClient(),
                defaults: UserDefaults = .standard) {
        self.init(store: store, providers: SystemModelProviders(client: client, defaults: defaults, loadConfig: { config }), searchDefaults: defaults)
    }

    init(store: MeetingStore, providers: any ModelProviding, searchDefaults: UserDefaults = .standard) {
        self.store = store
        self.providers = providers
        self.searchDefaults = searchDefaults
        status = Self.providerStatus(status, providers: providers, reloadIssue: nil)
    }

    public func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        onStatus = handler
        publish()
    }

    public func setJobEventHandler(_ handler: @escaping @Sendable (JobEvent) -> Void) {
        onJobEvent = handler
    }

    /// Called with the meeting's id after a link pass wrote its suggestions, so an open window can show them.
    public func setLinksChangedHandler(_ handler: @escaping @Sendable (Int64) -> Void) {
        onLinksChanged = handler
    }

    func publish() {
        onStatus?(status)
    }

    /// A chat model can be used now.
    public var isConfigured: Bool {
        if case .success = providers.chat() { return true }
        return false
    }

    // MARK: Providers

    /// Reads the settings again and records why a provider cannot be used.
    func refreshProviders() {
        let reloadIssue = providers.reload()
        status = Self.providerStatus(status, providers: providers, reloadIssue: reloadIssue)
    }

    private static func providerStatus(_ current: Status, providers: any ModelProviding, reloadIssue: ProviderIssue?) -> Status {
        var s = current
        let previousIssue = s.issue
        s.chatProvider = providers.settings.chat
        s.embeddingsProvider = providers.settings.embeddings
        switch providers.chat() {
        case .success(let chat):
            s.issue = nil
            s.integratedFallback = chat.fallbackReason
        case .failure(let u):
            s.issue = u.issue
            s.integratedFallback = nil
        }
        if s.issue == nil, reloadIssue == .keychainLocked, providers.settings.embeddings == .server { s.searchIssue = .keychainLocked }
        else if case .unavailable(let issue) = providers.embeddings() { s.searchIssue = issue }
        else { s.searchIssue = nil }
        s.configured = s.issue == nil
        s.serverConfigured = providers.refinementChat != nil
        // The issue is the status message, except a server that was simply never set up.
        if let issue = s.issue, issue != .serverNotConfigured {
            s.lastError = issue.localizedDescription
        } else if let previousIssue, s.lastError == previousIssue.localizedDescription {
            s.lastError = nil
        }
        return s
    }

    /// The chat model, or the error that explains why there is none.
    func chatProvider() throws -> ChatProvider {
        try chatProvider(for: .main)
    }

    /// The chat model for one kind of work: live notes and answers during a recording may go to Apple's model when the person
    /// chose that for "While recording"; minutes and everything after the meeting use the chosen provider.
    func chatProvider(for task: ChatTask) throws -> ChatProvider {
        switch providers.chat(for: task) {
        case .success(let chat): return chat
        case .failure(let u): throw Self.error(for: u.issue)
        }
    }

    static func error(for issue: ProviderIssue) -> LLMError {
        switch issue {
        case .serverNotConfigured: .notConfigured
        case .keychainLocked: .keychainUnavailable
        case .onDeviceModel: .modelUnavailable
        case .searchModelNotInstalled, .searchModelUnavailable: .searchModelUnavailable
        case .integratedModel: .modelUnavailable
        }
    }

    // MARK: Lifecycle

    public func start() async {
        // Renaming, merging or deleting a person named on a speaker changes the text of chunks and the marks on owners.
        await store.setPeopleChangeHandler { [weak self] in
            Task { await self?.peopleChanged() }
        }
        // Adding, editing or checking a task or decision runs the link pass for its meeting shortly after (nothing happens until links ship).
        await store.setItemsEditedHandler { [weak self] meeting in
            Task { await self?.itemsChanged(meetingID: meeting) }
        }
        try? await store.requeueInterruptedJobs()
        status.queued = (try? await store.pendingJobCount()) ?? 0
        refreshProviders()
        publish()
        await reconcileEmbeddings()
        kick()
        Task { await self.catchUpLinks() }
    }

    /// Recording: the background job is cancelled (back to the queue) and live
    /// notes start. When it stops, the queue resumes.
    public func setRecording(_ on: Bool, meetingID: Int64?) async {
        recording = on
        if on {
            backgroundTask?.cancel()
            if let meetingID {
                let budget = (try? chatProvider()).map { ContextBudget(contextTokens: $0.contextTokens) }
                let entities = (try? await store.candidateEntities(meetingID, limit: budget?.liveEntityLimit ?? 60)) ?? []
                let me = (try? await store.selfEntityID()) ?? nil
                let meeting = try? await store.meeting(meetingID)
                let language = meeting.map(OutputLanguage.init(meeting:))
                    ?? OutputLanguage(Locale(identifier: MeetingStore.Meeting.legacyLocaleIdentifier))
                live = LiveSession(meetingID: meetingID, language: language,
                                   entities: VautaPrompts.entitiesMessage(entities, selfEntity: me))
                beginWarm(meetingID: meetingID, entities: entities, selfEntity: me)
            }
        } else {
            let ended = live?.meetingID
            live = nil
            await endWarm()
            // Chunks stored for the typed questions stop at the last of them; the embedding job writes the meeting's whole set, and until
            // then the meeting is not covered (it ranks by keywords, like every meeting that has not been embedded yet).
            // Only the meeting that just ended: an earlier one has its whole set by now, written by the embedding job.
            if let ended, onDemandMeetings.remove(ended) != nil { _ = try? await store.dropChunks(ended, keeping: [], space: GemmaEmbeddingModel.space) }
            kick()
        }
    }

    /// Another client says it is using the server: no background job starts.
    public func setExternalBusy(_ busy: Bool) {
        externalBusy = busy
        if !busy { kick() }
    }

    /// New (or deleted) server, models, key or provider choice in Settings.
    public func configurationChanged() async {
        status.reachable = nil
        status.lastError = nil
        status.busyUntil = nil
        busyRetries = [:]
        refreshProviders()
        // The minutes no longer go to the integrated model: the meeting it kept is not needed.
        if let kept = warmMeetingKept, (try? chatProvider(for: .main))?.integrated != true { await releaseWarm(kept) }
        // Leaving the search model forgets that its index was ever complete: the chunks may be re-embedded in another space, and
        // coming back must wait for the coverage again.
        if providers.settings.embeddings != .onDeviceModel { forgetSearchModelCoverage() }
        status.models = []
        status.missingModels = []
        publish()
        // Embeddings that failed with the old settings may work with the new ones.
        try? await store.forgetFailedJobs(.embed)
        await reconcileEmbeddings()
        kick()
    }

    /// Checks the chosen providers: for a server, the connection, the key and
    /// that the chosen models exist (GET /v1/models); for the on-device
    /// model, its availability. Returns nil when everything is fine, else the
    /// message to show.
    @discardableResult
    public func check() async -> String? {
        refreshProviders()
        var failure: String?
        if let issue = status.issue {
            failure = issue.localizedDescription
        } else if let server = providers.server,
                  providers.settings.chat == .server || providers.settings.embeddings == .server {
            // A server that stays configured but is not used is not contacted.
            let useServerChat = providers.settings.chat == .server
            let useServerEmbeddings = providers.settings.embeddings == .server
            do {
                let models = try await server.client.allModels()
                status.models = models
                status.reachable = true
                status.lastError = nil
                let wanted = ((useServerChat ? [LLMRole.fast, .deep] : []) + (useServerEmbeddings ? [.embedding] : []))
                    .map { server.config.model(for: $0) }.filter { !$0.isEmpty }
                status.missingModels = Array(Set(wanted.filter { !models.contains($0) })).sorted()
                if !status.missingModels.isEmpty {
                    let missing = status.missingModels.joined(separator: ", ")
                    failure = String(localized: "The server doesn’t list these models: \(missing). Check the names or download them.",
                                     comment: "Model server check result; the argument is a list of model names")
                    status.lastError = failure
                }
            } catch {
                status.reachable = (error as? LLMError).map { if case .network = $0 { false } else { true } } ?? false
                failure = error.localizedDescription
                status.lastError = failure
            }
        } else {
            status.reachable = providers.settings.chat == .onDevice ? true : nil
            status.models = []
            status.missingModels = []
        }
        publish()
        if failure == nil { kick() }
        return failure
    }
}

/// A flag read from any thread: whether the live-answers gate of decision D16 applies to a service.
final class LiveAnswerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    var enforced: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
