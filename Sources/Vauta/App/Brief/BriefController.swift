// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import EventKit
import Foundation
import Observation

/// The pre-meeting brief in the app: which event is next, its brief (built by `BriefComposer` from the store, the documents, the
/// reminders and the event), and what the panel, the Meetings window and the notification show of it.
///
/// Nothing here writes to Calendar, Reminders or Notes. The brief lives in memory (the cache) and is dropped when Meetings lock and on
/// Erase. While Meetings are locked only the event's title and time are kept. The notification never carries brief content.
@MainActor
@Observable
final class BriefController {
    /// One event and its brief.
    struct Entry: Equatable, Identifiable {
        var event: BriefEvent
        var snapshot: BriefSnapshot?
        /// The Mac is too hot: nothing was built.
        var hot = false
        var reminders = BriefRemindersState.off
        var id: BriefOccurrence { event.occurrence }
    }

    /// What the Upcoming view shows.
    enum UpcomingState: Equatable {
        /// Calendar or the brief is off: the view is not offered.
        case off
        case calendarDenied
        case loading
        /// No qualifying meeting in the next 12 hours.
        case none
        case entries([Entry])
    }

    /// What a test replaces so the controller runs without Calendar, a recorder or a store.
    struct Seams {
        var isLocked: () -> Bool = { false }
        var calendarOn: () -> Bool = { true }
        var hasAccess: () -> Bool = { true }
        var calendars: () -> Set<String> = { ["work"] }
        var source: any BriefEventSource
        var build: (BriefEvent, Bool) async -> Entry
        /// Whether a recording is running; nil asks the recorder.
        var isRecording: (() -> Bool)?
        /// Keeps the brief with the meeting; nil writes it to the recorder's store.
        var saveBrief: ((BriefStoredReferences, Int64, Date) async -> Void)?
    }

    /// How far from now an event may start for the one-time offer (the window Settings → Calendar names).
    static let offerWindow: TimeInterval = 10 * 60

    let prefs: BriefPreferencesModel

    /// The event the panel card is about (from `lead` minutes before it starts until 15 minutes after).
    private(set) var next: Entry?
    private(set) var upcoming = UpcomingState.off
    /// The brief the current recording was started with (hidden while Meetings are locked).
    private(set) var recordingBrief: BriefSnapshot?
    /// Which of the Upcoming entries is shown.
    var upcomingIndex = 0

    @ObservationIgnored weak var recorder: RecorderModel?
    @ObservationIgnored let cache = BriefCache()
    @ObservationIgnored var ledger = BriefNotificationLedger()
    @ObservationIgnored private var ekStore: EKEventStore?
    @ObservationIgnored private(set) var eventSource: (any BriefEventSource)?
    @ObservationIgnored var seams: Seams?
    @ObservationIgnored private var reminderSource: EventKitReminderSource?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var remindersStamp = 0
    /// The panel card and the Upcoming page load apart: one never cancels the other.
    @ObservationIgnored private var nextTask: Task<Void, Never>?
    @ObservationIgnored private var upcomingTask: Task<Void, Never>?
    @ObservationIgnored private var upcomingRun = 0
    @ObservationIgnored private(set) var upcomingBusy = false
    @ObservationIgnored private var inputsTask: Task<Void, Never>?
    @ObservationIgnored private var agendaTasks: [BriefOccurrence: Task<Void, Never>] = [:]
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var pruneTask: Task<Void, Never>?
    /// Builds the references of a recording that started while Meetings were locked.
    @ObservationIgnored private var attachmentTask: Task<Void, Never>?
    @ObservationIgnored private var recordingRun = 0
    @ObservationIgnored private var announced = Set<BriefOccurrence>()
    /// Set at recording start, kept until the meeting is saved: only references (no reminder or invitation text) and when the recording began.
    @ObservationIgnored private(set) var attachment: Attachment?
    @ObservationIgnored var lastNotified: BriefEvent?
    /// The occurrence "Record at Start" was pressed for: the card says so until the meeting starts or the person cancels.
    var armed: BriefOccurrence?
    @ObservationIgnored var armedTask: Task<Void, Never>?
    @ObservationIgnored var removalTask: Task<Void, Never>?
    struct Attachment {
        var references: BriefStoredReferences
        var occurrence: BriefOccurrence
        var title: String
        var start: Date
        var end: Date
        var service: ConferencingService?
        /// When the recording began: the brief is the one the person had then.
        var recordedAt: Date
    }

    /// Renderings invent the state and never touch EventKit.
    @ObservationIgnored private(set) var isSnapshot = false
    @ObservationIgnored private var snapshotOffer: Bool?
    @ObservationIgnored private var snapshotLocked: Bool?
    /// Renderings of the loading page after the wait (the Refresh button is there).
    @ObservationIgnored private(set) var snapshotWaited = false
    /// The event rules as the EventKit reader needs them (it qualifies events off the main actor).
    @ObservationIgnored private let rulesBox = BriefRulesBox()

    init(defaults: UserDefaults = .standard) {
        prefs = BriefPreferencesModel(defaults: defaults)
    }

    /// Connects the brief to the recorder (calendar, store, models). Nothing is read until the calendar is on.
    func start(recorder: RecorderModel) {
        self.recorder = recorder
        prefs.onChange = { [weak self] in self?.settingsChanged() }
        recorder.calendar.briefPlan = { [weak self] in self?.wakePlan() }
        recorder.calendar.onBriefDue = { [weak self] due in self?.briefDue(due) }
        if recorder.calendar.enabled && recorder.calendar.hasAccess { connectEventKit() }
        if prefs.remindersEnabled { connectEventKit() }
        observeInputs()
    }

    /// A finished documents sync, a search model installed or removed, or another provider: the brief on screen is built again.
    private func observeInputs() {
        guard !isSnapshot, let recorder else { return }
        withObservationTracking {
            _ = recorder.documents?.briefGeneration
            _ = recorder.searchModel.status.isReady
            _ = "\(recorder.llmStatus.chatProvider)"
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inputsTask?.cancel()
                // Indexing changes the generation many times: the brief waits until it is quiet.
                self.inputsTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    self?.inputsChanged()
                }
                self.observeInputs()
            }
        }
    }

    /// Creates the EventKit readers (read-only) once they are needed.
    private func connectEventKit() {
        guard !isSnapshot, ekStore == nil, recorder != nil else { return }
        let store = EKEventStore()
        ekStore = store
        let box = rulesBox
        // The invitation's description is read only while the brief is on (the set-up offer shows a title and a time and nothing else).
        eventSource = EventKitBriefEventSource(store: store, readNotes: { let p = BriefPreferences(defaults: .standard); return p.enabled && p.readInvitationNotes }, limit: 2) { event in
            BriefEventSelector.candidates([event], now: .now, rules: box.value).count == 1
        }
        let reminders = EventKitReminderSource(store: store)
        reminderSource = reminders
        prefs.attach(reminders)
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.eventStoreChanged() }
        }
    }

    // MARK: State the views read

    /// Meetings are locked: only the title and the time of the event are shown.
    var isLocked: Bool { snapshotLocked ?? seams?.isLocked() ?? !(recorder?.historyUnlocked ?? false) }

    /// The panel card, nil when there is nothing to show now. With the brief off it is the one-time offer: a title, a time and "Set Up…".
    var panelCard: BriefPanelCard? {
        guard let next, isSnapshot || isWithinCard(next.event, now: .now) else { return nil }
        guard prefs.enabled else { return prefs.hintSeen ? nil : BriefPanelCard.offer(event: next.event) }
        return BriefPanelCard.make(event: next.event, snapshot: next.snapshot, locked: isLocked, hot: next.hot)
    }

    /// The recording row shows the brief the meeting started with.
    var recordingRow: BriefSnapshot? { isLocked ? nil : recordingBrief }

    var calendarOn: Bool { seams?.calendarOn() ?? (recorder?.calendar.enabled == true) }

    private var calendarAccess: Bool { seams?.hasAccess() ?? (recorder?.calendar.hasAccess == true) }

    var selectedCalendars: Set<String> { seams?.calendars() ?? recorder?.calendar.selected ?? [] }

    var activeSource: (any BriefEventSource)? { seams?.source ?? eventSource }

    /// The Upcoming row of the Meetings sidebar is offered while Calendar is on (with the brief off it says how to turn the brief on).
    var offersUpcoming: Bool { snapshotOffer ?? calendarOn }

    /// The first-time offer in the panel: Calendar is on, the brief is off and was never set up, and a qualifying meeting is coming.
    var offersSetUp: Bool { !prefs.enabled && !prefs.hintSeen && panelCard != nil }

    private var cardLead: Int { prefs.leadMinutes > 0 ? prefs.leadMinutes : BriefEventSelector.defaultLeadMinutes }

    private func isWithinCard(_ event: BriefEvent, now: Date) -> Bool {
        now >= event.start.addingTimeInterval(-Double(cardLead) * 60) && now <= event.start.addingTimeInterval(BriefEventSelector.lateGrace)
    }

    // MARK: Environment

    private func environment() -> BriefEnvironment {
        BriefEnvironment(isRecording: recorder?.phase == .recording || recorder?.phase == .starting, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                         thermalState: ProcessInfo.processInfo.thermalState, onBattery: DocumentsModel.onBattery, highMemoryPressure: BriefMemoryPressure.shared.isHigh)
    }

    var rules: BriefEventRules {
        let value = BriefEventRules(calendarIDs: selectedCalendars, includeInPerson: prefs.inPerson)
        rulesBox.value = value
        return value
    }

    private var calendarReadable: Bool { calendarOn && calendarAccess && !selectedCalendars.isEmpty && activeSource != nil }

    var canRead: Bool { prefs.enabled && calendarReadable }

    /// Only the offer to set the brief up is wanted: the event's title and time are looked at, nothing is built.
    private var canOffer: Bool { !prefs.enabled && !prefs.hintSeen && calendarReadable }

    // MARK: Refresh

    /// The panel opened, the calendar changed, the minute of the wake-up came, Meetings were unlocked: look at the event about to start.
    func refreshNext() {
        guard !isSnapshot else { return }
        nextTask?.cancel()
        nextTask = Task { [weak self] in await self?.performRefreshNext() }
    }

    /// Waits for the panel and Upcoming loads that are running (tests).
    func settle() async {
        await nextTask?.value
        await upcomingTask?.value
        await attachmentTask?.value
    }

    private func performRefreshNext() async {
        await pruneNow()
        guard canRead || canOffer, let source = activeSource else { next = nil; return }
        let now = Date.now
        let rules = self.rules
        // The one-time offer looks only at events from 10 minutes before to 10 minutes after now (what Settings says), and it asks no
        // further: with the brief on the card keeps its longer window.
        let offerOnly = !prefs.enabled
        let events = await source.events(from: now.addingTimeInterval(offerOnly ? -BriefController.offerWindow : -BriefEventSelector.lateGrace),
                                         to: now.addingTimeInterval(offerOnly ? BriefController.offerWindow : Double(cardLead) * 60 + 60), calendarIDs: selectedCalendars)
            .filter { !offerOnly || abs($0.start.timeIntervalSince(now)) <= BriefController.offerWindow }
        guard !Task.isCancelled else { return }
        guard let event = BriefEventSelector.next(events, now: now, rules: rules), isWithinCard(event, now: now) else {
            next = nil
            return
        }
        scheduleExpiry(for: event)
        if isLocked || !prefs.enabled {
            // Title and time only: no attendee, no note, nothing built.
            next = Entry(event: BriefController.stripped(event))
            return
        }
        // No store (still opening, being recovered or failed to open): there is nothing to build a brief from, so there is no card. It
        // is looked at again when the store opens (`storeOpened`).
        if seams == nil, recorder?.store == nil {
            next = nil
            return
        }
        if next?.event.occurrence != event.occurrence { next = Entry(event: event) }
        let entry = await buildEntry(event, force: false)
        guard !Task.isCancelled, !isLocked else { return }
        next = entry
        // VoiceOver hears that the brief is ready, once per meeting, and never its content.
        if entry.snapshot != nil, announced.insert(entry.event.occurrence).inserted {
            AccessibilityNotification.Announcement(BriefLabels.briefReady(at: entry.event.start)).post()
        }
    }

    /// The store finished opening: what could not be built without it is looked at again.
    func storeOpened() {
        refreshNext()
        if case .loading = upcoming, !isLocked { openUpcoming() }
    }

    /// The panel card goes away 15 minutes after the start without anyone opening the panel again.
    private func scheduleExpiry(for event: BriefEvent) {
        expiry?.cancel()
        let end = event.start.addingTimeInterval(BriefEventSelector.lateGrace + 1)
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, end.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.refreshNext()
        }
    }

    // MARK: Dropping what ended

    /// Schedules the moment the oldest kept brief is 30 minutes past the end of its event (and the Upcoming entry of that event with it).
    private func schedulePrune() {
        pruneTask?.cancel()
        pruneTask = Task { [weak self] in
            guard let self else { return }
            var due = await self.cache.nextExpiry()
            if case .entries(let entries) = self.upcoming, let first = entries.map({ $0.event.end.addingTimeInterval(BriefCache.retention) }).min() {
                due = due.map { min($0, first) } ?? first
            }
            guard let due else { return }
            try? await Task.sleep(for: .seconds(max(1, due.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            await self.pruneNow()
        }
    }

    /// Drops the briefs whose event ended more than 30 minutes before `now`, from the cache and from the Upcoming page.
    func pruneNow(now: Date = .now) async {
        await cache.prune(now: now)
        if case .entries(let entries) = upcoming {
            let kept = entries.filter { now.timeIntervalSince($0.event.end) <= BriefCache.retention }
            if kept.count != entries.count {
                upcoming = kept.isEmpty ? .none : .entries(kept)
                upcomingIndex = min(upcomingIndex, max(0, kept.count - 1))
            }
        }
        schedulePrune()
    }

    /// Opening Upcoming (or Refresh): the event about to start and the next one within 12 hours, nothing else.
    func openUpcoming(force: Bool = false) {
        guard !isSnapshot else { return }
        guard prefs.enabled, calendarOn else { upcoming = .off; return }
        guard calendarAccess else { upcoming = .calendarDenied; return }
        guard !isLocked else { upcoming = .loading; return }
        if case .entries = upcoming {} else { upcoming = .loading }
        upcomingTask?.cancel()
        upcomingRun += 1
        let run = upcomingRun
        upcomingBusy = true
        upcomingTask = Task { [weak self] in
            await self?.performUpcoming(force: force)
            if let self, self.upcomingRun == run { self.upcomingBusy = false }
        }
    }

    /// The Upcoming page is waiting (the Mac was unlocked, or a load was cut short) and nothing is loading it: load it.
    func resumeUpcomingIfIdle() {
        guard case .loading = upcoming, !upcomingBusy, !isLocked else { return }
        openUpcoming()
    }

    private func performUpcoming(force: Bool) async {
        await cache.prune()
        guard canRead, let source = activeSource else { upcoming = calendarAccess ? .none : .calendarDenied; return }
        let now = Date.now
        let rules = self.rules
        let events = await source.events(from: now.addingTimeInterval(-BriefEventSelector.lateGrace),
                                         to: now.addingTimeInterval(BriefEventSelector.horizon), calendarIDs: selectedCalendars)
        let chosen = BriefEventSelector.upcoming(events, now: now, rules: rules)
        guard !Task.isCancelled else { return }
        guard !chosen.isEmpty else { upcoming = .none; return }
        var entries: [Entry] = []
        for event in chosen {
            if force { await cache.invalidate(.occurrence(event.occurrence)) }
            entries.append(await buildEntry(event, force: force))
            guard !Task.isCancelled, !isLocked else { return }
        }
        upcoming = .entries(entries)
        upcomingIndex = min(upcomingIndex, entries.count - 1)
        schedulePrune()
    }

    /// An event reduced to what a locked card may show.
    static func stripped(_ event: BriefEvent) -> BriefEvent {
        BriefEvent(identifier: event.identifier, title: event.title, start: event.start, end: event.end, calendarID: event.calendarID, service: event.service)
    }

    // MARK: Building

    private func cacheKey(_ event: BriefEvent) async -> BriefCacheKey {
        let revision = await recorder?.store?.editRevision ?? 0
        return BriefCacheKey(occurrence: event.occurrence, storeRevision: revision, documentsGeneration: recorder?.documents?.briefGeneration ?? 0,
                             remindersStamp: remindersStamp, searchModelInstalled: recorder?.searchModel.status.isReady == true,
                             provider: recorder.map { "\($0.llmStatus.chatProvider)" } ?? "", language: agendaLanguage(nil).identifier)
    }

    private func agendaLanguage(_ lastLocale: String?) -> OutputLanguage {
        if case .fixed(let id)? = recorder?.preferences.outputLanguage { return OutputLanguage(Locale(identifier: id)) }
        return OutputLanguage(Locale(identifier: lastLocale ?? Locale.current.identifier))
    }

    /// The brief of one event: from the cache when nothing it was built from changed, else built again (steps 1 to 5 at once; the
    /// agenda only when what it cites changed).
    func buildEntry(_ event: BriefEvent, force: Bool) async -> Entry {
        if let build = seams?.build { return await build(event, force) }
        return await build(event, force: force)
    }

    /// `deterministic`: the steps that read the store only. The cache is not written, no agenda is asked of a model and the Mac's
    /// recording state is respected (used for a recording that starts while Meetings are locked).
    func build(_ event: BriefEvent, force: Bool, deterministic: Bool = false) async -> Entry {
        guard let recorder, let store = recorder.store else { return Entry(event: event) }
        let key = await cacheKey(event)
        if !force, !deterministic, let cached = await cache.snapshot(for: key) { return Entry(event: event, snapshot: cached, reminders: remindersStateNow()) }
        let adapters = recorder.llm?.briefAdapters()
        let composer = BriefComposer(store: store, retriever: adapters?.retriever, reminders: reminderSource)
        let backend = deterministic ? nil : await recorder.llm?.briefBackend()
        let env = environment()
        let loaded = deterministic ? false : await recorder.llm?.briefIntegratedLoaded() ?? false
        let result = await composer.build(event, settings: prefs.snapshot.settings, environment: env, backend: backend, integratedLoaded: loaded)
        guard let snapshot = result.snapshot else { return Entry(event: event, hot: true, reminders: result.reminders) }
        if deterministic { return Entry(event: event, snapshot: snapshot, reminders: result.reminders) }
        let previous = await cache.previous(for: event.occurrence)
        let sameProvider = await cache.previousKey(for: event.occurrence)?.provider == key.provider
        var (carried, needsAgenda) = BriefCache.carryAgenda(from: previous, to: snapshot, sameProvider: sameProvider)
        let decision = BriefAgendaShipping.decision(backend: backend)
        switch decision {
        case .hidden: carried.agenda = .none; needsAgenda = false
        case .needsModel: carried.agenda = .unavailable; needsAgenda = false
        case .run: break
        }
        if !isLocked {
            await cache.store(carried, key: key)
            schedulePrune()
        }
        if needsAgenda, let backend, let writer = adapters?.writer, let budget = await recorder.llm?.briefBudget() {
            startAgenda(for: carried, key: key, backend: backend, writer: writer, budget: budget, locale: result.facts?.last?.locale, integratedLoaded: loaded)
        }
        return Entry(event: event, snapshot: carried, reminders: result.reminders)
    }

    private func startAgenda(for snapshot: BriefSnapshot, key: BriefCacheKey, backend: BriefBackend, writer: any BriefAgendaWriter, budget: ContextBudget,
                             locale: String?, integratedLoaded: Bool) {
        let occurrence = snapshot.occurrence
        agendaTasks[occurrence]?.cancel()
        let language = agendaLanguage(locale)
        let env = environment()
        agendaTasks[occurrence] = Task { [weak self] in
            let state = await BriefAgenda.run(snapshot: snapshot, backend: backend, writer: writer, language: language, budget: budget, environment: env, integratedLoaded: integratedLoaded)
            guard !Task.isCancelled, let self, !self.isLocked else { return }
            var updated = snapshot
            updated.agenda = state
            await self.cache.store(updated, key: key)
            self.schedulePrune()
            self.apply(updated)
        }
    }

    /// An agenda arrived: it joins the entry it belongs to.
    private func apply(_ snapshot: BriefSnapshot) {
        if var entry = next, entry.event.occurrence == snapshot.occurrence { entry.snapshot = snapshot; next = entry }
        if case .entries(var entries) = upcoming, let index = entries.firstIndex(where: { $0.event.occurrence == snapshot.occurrence }) {
            entries[index].snapshot = snapshot
            upcoming = .entries(entries)
        }
    }

    private func remindersStateNow() -> BriefRemindersState {
        guard prefs.remindersEnabled else { return .off }
        switch prefs.remindersAccess {
        case .notDetermined: return .notAsked
        case .denied: return .denied
        case .granted: return prefs.reminderListIDs.isEmpty ? .noLists : .shown
        }
    }

    // MARK: Changes that drop or rebuild

    private func settingsChanged() {
        Task { await cache.invalidate(.eventStoreChanged) }
        remindersStamp &+= 1
        recorder?.calendar.scheduleNext()
        if prefs.remindersEnabled || recorder?.calendar.hasAccess == true { connectEventKit() }
        refreshNext()
        if case .entries = upcoming { openUpcoming(force: true) }
        if !prefs.enabled { upcoming = .off }
    }

    /// The calendar or the reminders changed.
    func eventStoreChanged() {
        remindersStamp &+= 1
        Task { await cache.invalidate(.eventStoreChanged) }
        refreshNext()
        switch upcoming {
        case .entries, .none: openUpcoming()
        case .loading: if !isLocked { openUpcoming() }
        default: break
        }
        withdrawNotificationIfGone()
    }

    /// The event the notification announced was cancelled, declined or moved: the delivered notification goes away.
    private func withdrawNotificationIfGone() {
        guard let notified = lastNotified, let source = activeSource else { return }
        let calendars = selectedCalendars
        let rules = self.rules
        Task { [weak self] in
            let events = await source.events(from: notified.start.addingTimeInterval(-1), to: notified.start.addingTimeInterval(1), calendarIDs: calendars)
            guard let self, self.lastNotified?.occurrence == notified.occurrence else { return }
            if !BriefEventSelector.candidates(events, now: .now, rules: rules).contains(where: { $0.occurrence == notified.occurrence }) {
                self.recorder?.withdrawBriefNotification()
                self.removalTask?.cancel()
                self.armedTask?.cancel()
                self.armed = nil
                self.lastNotified = nil
            }
        }
    }

    /// The calendar was turned on or off, or access changed.
    func calendarChanged() {
        if recorder?.calendar.enabled == true, recorder?.calendar.hasAccess == true { connectEventKit() }
        guard calendarOn else {
            next = nil
            upcoming = .off
            return
        }
        refreshNext()
    }

    /// The documents were indexed, the search model or the provider changed: what is on screen is built again (its key changed).
    func inputsChanged() {
        guard prefs.enabled, !isLocked else { return }
        refreshNext()
        if case .entries = upcoming { openUpcoming() }
    }

    /// A recording ended: the agenda of a later event that waited for it is asked for again, while that event
    /// has not started. Nothing runs when no agenda is waiting.
    func resumePausedAgendas(now: Date = .now) {
        guard prefs.enabled, !isLocked else { return }
        var entries: [Entry] = next.map { [$0] } ?? []
        if case .entries(let upcomingEntries) = upcoming { entries += upcomingEntries }
        guard entries.contains(where: { $0.snapshot?.agenda == .paused && $0.event.start > now }) else { return }
        Task { [weak self] in
            await self?.cache.invalidate(.eventStoreChanged)
            self?.inputsChanged()
        }
    }

    /// Meetings locked: no brief stays in memory. Only the title and time of the event remain for the panel.
    func locked() {
        pruneTask?.cancel()
        nextTask?.cancel()
        upcomingTask?.cancel()
        upcomingBusy = false
        for task in agendaTasks.values { task.cancel() }
        agendaTasks = [:]
        Task { await cache.invalidate(.locked) }
        if let entry = next { next = Entry(event: BriefController.stripped(entry.event)) }
        upcoming = prefs.enabled && calendarOn ? .loading : .off
        recordingBrief = nil
    }

    /// Meetings were unlocked: build what the panel shows, and show again the brief the running recording started with.
    func unlocked() {
        if recordingBrief == nil, let held = attachment, isRecordingNow {
            recordingBrief = BriefSnapshot(occurrence: held.occurrence, title: held.title, start: held.start, end: held.end, service: held.service, seriesName: nil,
                                           mode: .keyword, relatedSkipped: false, sections: held.references.sections,
                                           agenda: held.references.agenda.isEmpty ? .none : .lines(held.references.agenda))
        }
        refreshNext()
    }

    /// Erase Everything: nothing of the brief, its cache or its stored briefs is kept.
    func erased() {
        pruneTask?.cancel()
        attachmentTask?.cancel()
        recordingRun += 1
        nextTask?.cancel()
        upcomingTask?.cancel()
        upcomingBusy = false
        inputsTask?.cancel()
        for task in agendaTasks.values { task.cancel() }
        agendaTasks = [:]
        Task { await cache.invalidate(.erased) }
        next = nil
        upcoming = prefs.enabled && calendarOn ? .none : .off
        recordingBrief = nil
        attachment = nil
        lastNotified = nil
        armedTask?.cancel()
        armed = nil
    }

    // MARK: Recording

    private var isRecordingNow: Bool { seams?.isRecording?() ?? (recorder?.phase == .recording || recorder?.phase == .starting) }

    /// A recording that takes no linked calendar event can still be the in-person event the card is about: the card's
    /// event, when it has no meeting link and the card is inside the window `BriefRecordingMatch` uses. The recording takes that event as
    /// its calendar event (title, attendees and series, never the invitation's notes), so its attendees and series are saved like those of
    /// a meeting with a link and the next occurrence finds this one.
    func inPersonEventOnCard(at now: Date = .now) -> CalendarEventMatch? {
        guard prefs.enabled, let event = next?.event, event.service == nil, isWithinCard(event, now: now) else { return nil }
        return CalendarEventMatch(meeting: event.calendarMeeting, service: nil, occurrence: event.occurrence)
    }

    func inPersonOccurrenceOnCard(at now: Date = .now) -> BriefOccurrence? { inPersonEventOnCard(at: now)?.occurrence }

    /// A recording starts. When the event on screen is the one it takes (the same occurrence of the same event), the meeting keeps that
    /// brief when it ends, whether Meetings were unlocked then or not. A recording that takes no calendar event never carries one.
    func recordingStarted(recordingOccurrence: BriefOccurrence?) {
        removalTask?.cancel()
        recorder?.withdrawBriefNotification()
        armedTask?.cancel()
        armed = nil
        attachmentTask?.cancel()
        attachment = nil
        recordingBrief = nil
        recordingRun += 1
        guard prefs.enabled, let entry = next,
              BriefRecordingMatch.matches(entry.event.occurrence, at: .now, leadMinutes: prefs.leadMinutes, recordingOccurrence: recordingOccurrence)
        else { return }
        if !isLocked, let snapshot = entry.snapshot {
            keep(snapshot, showing: true)
            return
        }
        // Locked (the usual state): the deterministic brief is built anyway, with no model, no cache and nothing shown. Only its
        // references are kept, and the row appears when Meetings are unlocked.
        let occurrence = entry.event.occurrence
        let run = recordingRun
        attachmentTask = Task { [weak self] in
            guard let self, let snapshot = await self.snapshotForRecording(occurrence), !Task.isCancelled, self.recordingRun == run,
                  self.isRecordingNow else { return }
            self.keep(snapshot, showing: !self.isLocked)
        }
    }

    private func keep(_ snapshot: BriefSnapshot, showing: Bool) {
        if showing { recordingBrief = snapshot }
        guard snapshot.hasContent else { return }
        attachment = Attachment(references: BriefStoredReferences(snapshot: snapshot), occurrence: snapshot.occurrence, title: snapshot.title,
                                start: snapshot.start, end: snapshot.end, service: snapshot.service, recordedAt: .now)
    }

    /// The event of the occurrence is read again in full (the locked card holds only its title and time) and its brief built from the
    /// store alone.
    private func snapshotForRecording(_ occurrence: BriefOccurrence) async -> BriefSnapshot? {
        guard canRead, let source = activeSource else { return nil }
        let start = Date(timeIntervalSince1970: TimeInterval(occurrence.startSeconds))
        let events = await source.events(from: start.addingTimeInterval(-1), to: start.addingTimeInterval(1), calendarIDs: selectedCalendars, matching: [occurrence])
        guard let event = events.first(where: { $0.occurrence == occurrence }) else { return nil }
        let entry: Entry
        if let build = seams?.build { entry = await build(event, false) } else { entry = await build(event, force: false, deterministic: true) }
        return entry.snapshot
    }

    /// The recording ended and the meeting was saved: its brief is stored with it (references and the verified agenda only).
    func recordingEnded(meetingID: Int64?) async {
        await attachmentTask?.value
        let held = attachment
        defer {
            resumePausedAgendas()
            recordingBrief = nil
            attachment = nil
            attachmentTask = nil
        }
        guard let meetingID, let held else { return }
        if let save = seams?.saveBrief {
            await save(held.references, meetingID, held.recordedAt)
        } else if let store = recorder?.store {
            try? await store.saveBrief(held.references, for: meetingID, at: held.recordedAt)
        } else {
            return
        }
        await cache.invalidate(.occurrence(held.occurrence))
        next = nil
        refreshNext()
    }

    /// The recording was discarded (nothing recorded): the brief is not kept.
    func recordingDiscarded() {
        resumePausedAgendas()
        attachmentTask?.cancel()
        recordingRun += 1
        recordingBrief = nil
        attachment = nil
    }

    // MARK: Opening other apps (read-only)

    /// Shows the event in Calendar when it has an identifier, else launches Calendar. Nothing is created or changed.
    func openCalendar(_ event: BriefEvent? = nil) { openCalendar(eventIdentifier: event?.eventIdentifier) }

    func openCalendar(eventIdentifier: String?) {
        if let url = BriefOpenURL.event(eventIdentifier: eventIdentifier), BriefController.openShowing(url, in: "com.apple.iCal") { return }
        BriefController.openApp("com.apple.iCal")
    }

    /// Shows the reminder in Reminders when its identifier is known, else launches Reminders.
    func openReminders(id: String? = nil) {
        if let url = BriefOpenURL.reminder(id: id), BriefController.openShowing(url, in: "com.apple.reminders") { return }
        BriefController.openApp("com.apple.reminders")
    }

    /// Opens `url` with the Apple app that owns it; false when that app is not there.
    private static func openShowing(_ url: URL, in bundleID: String) -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    static func openApp(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Renderings

    #if VAUTA_DIAGNOSTICS
    /// For `Vauta render-ui`: the state is invented, so EventKit is never touched.
    func installSnapshotState(next: Entry?, upcoming: UpcomingState, recordingBrief: BriefSnapshot? = nil, offersUpcoming: Bool = false,
                              locked: Bool = false, loadingWaited: Bool = false) {
        isSnapshot = true
        snapshotWaited = loadingWaited
        snapshotOffer = offersUpcoming
        snapshotLocked = locked
        self.next = next
        self.upcoming = upcoming
        self.recordingBrief = recordingBrief
    }
    #endif
}

/// The rules shared with the EventKit reader, which qualifies events off the main actor.
final class BriefRulesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = BriefEventRules(calendarIDs: [])

    var value: BriefEventRules {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
