// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation
import Observation
import SwiftUI

/// A search filter (a token in the search field).
struct FilterToken: Identifiable, Hashable {
    enum Kind: Hashable { case entity(Int64), series(Int64), lastDays(Int) }
    let kind: Kind
    let label: String
    let symbol: String
    var id: String {
        switch kind {
        case .entity(let i): "e\(i)"
        case .series(let i): "s\(i)"
        case .lastDays(let d): "d\(d)"
        }
    }
}

/// The Meetings window: history with search and filters, reviewing the
/// minutes, Ask, open tasks and the cards of people and projects. Everything
/// comes from the encrypted store and is dropped from the interface's memory
/// when the window closes or the app relocks (drafts are saved first).
///
/// The detail, editing, deletion and export parts live in extensions
/// (`MeetingsModel+*.swift`); Ask and import have their own models.
@MainActor
@Observable
final class MeetingsModel {
    enum Mode: String, CaseIterable, Identifiable {
        case meetings, ask, tasks, people
        var id: String { rawValue }
        var label: String {
            switch self {
            case .meetings: String(localized: "Meetings", comment: "Meetings window mode")
            case .ask: String(localized: "Ask", comment: "Meetings window mode: ask questions about your meetings")
            case .tasks: String(localized: "Tasks", comment: "Meetings window mode: open tasks")
            case .people: String(localized: "People", comment: "Meetings window mode: people and projects")
            }
        }
        var symbol: String {
            switch self {
            case .meetings: "list.bullet.rectangle"
            case .ask: "questionmark.bubble"
            case .tasks: "checklist"
            case .people: "person.2"
            }
        }
        /// ⌘1–⌘4.
        var shortcut: Character {
            switch self {
            case .meetings: "1"
            case .ask: "2"
            case .tasks: "3"
            case .people: "4"
            }
        }
    }

    enum DetailTab: Hashable { case notes, summary, tasks, transcript, suggestions, brief }

    /// "Upcoming" (the brief of the next meeting) is shown instead of a meeting; the sidebar row above the list selects it.
    var showingUpcoming = false
    /// The brief the open meeting was recorded with, as far as what it pointed to still exists (nil: none was kept).
    var storedBrief: (references: BriefStoredReferences, createdAt: Date)?
    /// The pre-meeting brief of the app (the window sets it when it appears).
    weak var brief: BriefController?

    var mode: Mode = .meetings {
        didSet {
            guard mode != oldValue else { return }
            noteActivity()
            if mode != .meetings { showingUpcoming = false }
            if !mode.searchesMeetings {
                searchTask?.cancel()
                hits = []
                knowledgeHits = []
                documentHits = []
                suggestedTokens = []
            }
            Task { await reloadMode() }
        }
    }

    // MARK: List and search

    var meetings: [MeetingStore.Meeting] = []
    var hits: [MeetingStore.SearchHit] = []
    var knowledgeHits: [KnowledgeHit] = []
    /// Passages of the person's documents that match the search (keywords only, no model).
    var documentHits: [DocumentPassage] = []
    /// The "By meaning" group of the sidebar search (the search model): passages of meetings and documents that the keyword
    /// results above do not already show.
    var meaningMeetingHits: [RetrievedPassage] = []
    var meaningDocumentHits: [DocumentPassage] = []
    @ObservationIgnored var meaningTask: Task<Void, Never>?
    var suggestionCounts: [Int64: Int] = [:]
    /// The error or notice shown as an alert.
    var alert: MeetingsAlert?
    /// Segment to highlight (when arriving from a result, a mention or a mark).
    var highlighted: Int64?
    /// The transcript line whose words are being corrected, with what was typed so far.
    var lineDraft: LineDraft?
    /// After a correction: the same words elsewhere in the meeting, offered to correct there too.
    var everywhereOffer: MeetingStore.CorrectEverywhereOffer?
    /// The meeting being recorded (it can't be deleted).
    var activeMeetingID: Int64?
    /// Meetings matching the tokens (nil = no filter).
    var filteredIDs: [Int64]?
    var tokens: [FilterToken] = [] {
        didSet {
            guard tokens != oldValue else { return }
            query = ""
            Task { await applyFilter() }
        }
    }
    var suggestedTokens: [FilterToken] = []
    /// The search result whose meeting is open ("k" or "t" and the hit's id), selected in the sidebar's results.
    var openedHit: String?

    /// Selecting the same meeting again does nothing (keeps the highlight).
    var selectedID: Int64? {
        didSet {
            guard selectedID != oldValue else { return }
            noteActivity()
            otherItemsExpanded = false
            if selectedID != nil { showingUpcoming = false }
            forgetSpeakerEdits()
            if notice?.reveal != nil { dismissNotice() }
            saveDraftsInBackground()
            // Words being edited and a note not yet added belong to the meeting being left: they are saved there.
            notepad.commitPendingBeforeLeaving()
            saveLineDraft()
            everywhereOffer = nil
            if findShown { closeFind() }
            highlighted = pendingHighlight
            pendingHighlight = nil
            if highlighted == nil {
                tab = .summary
                // The notes are the user's document: a meeting that has some opens on them (once it is loaded).
                opensOnNotes = true
            }
            notepad.forgetUndo()
            Task { await loadDetail() }
        }
    }
    /// Called after "Erase All" (so other views drop what they held).
    @ObservationIgnored var onErased: (() -> Void)?
    /// Called after a term was added to the glossary from here (so Context lists it).
    @ObservationIgnored var onGlossaryChanged: (() -> Void)?
    /// Called on user activity, so an unlocked window stays unlocked while in
    /// use (the relock timer lives in the recorder). Throttled.
    @ObservationIgnored var onActivity: (() -> Void)?

    /// Search with a 200 ms pause that cancels the previous one: no query per
    /// keystroke against the actor that is also recording.
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            noteActivity()
            searchTask?.cancel()
            // The old query's meaning results never stay under a new query.
            meaningTask?.cancel()
            meaningMeetingHits = []
            meaningDocumentHits = []
            if !mode.searchesMeetings || query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
                hits = []
                knowledgeHits = []
                documentHits = []
                suggestedTokens = []
                return
            }
            searchTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                await self?.runSearch()
            }
        }
    }

    /// The documents the person added (Ask and the search use them; a citation opens the passage viewer).
    @ObservationIgnored var documentsModel: DocumentsModel? {
        didSet { ask.documents = documentsModel }
    }
    /// The passage viewer that a citation or a search result opened.
    var passageViewer: PassageViewerModel?
    /// Files attached to the open meeting, and passages of the person's documents that go with its topics and decisions.
    var materials: [MeetingMaterial] = []
    /// Files are being dragged over the Materials section (it draws an outline; a rendering sets it to show that state).
    var materialsDropTargeted = false
    /// How each material is doing in the index (Waiting, Indexing, the reason it was skipped…), by `MeetingMaterial.id`.
    var materialStates: [String: MaterialState] = [:]
    /// What happened to the files just dropped or chosen that could not be attached; it shows in Materials, where the person is.
    var materialsNotes: [DocumentsModel.Note] = []
    @ObservationIgnored var materialsNotesMeeting: Int64?
    var relatedDocuments: [DocumentPassage] = []
    /// The related documents were found by meaning (the search model), not by keywords.
    var relatedDocumentsByMeaning = false
    /// Other meetings close to the open one by meaning (the search model only).
    var relatedMeetings: [MeetingStore.Meeting] = []

    func openDocument(_ citation: DocumentCitation) {
        passageViewer = PassageViewerModel(request: PassageViewerRequest(citation: citation), documents: documentsModel)
    }

    /// A destructive action waiting for confirmation.
    var pendingDeletion: PendingDeletion?
    /// A short confirmation (exported, copied) shown over the window for a few seconds.
    var notice: MeetingsNotice?
    @ObservationIgnored var noticeTask: Task<Void, Never>?
    /// The export sheet is shown (for the selected meeting).
    var showingExport = false

    // MARK: Meeting detail

    var tab: DetailTab = .summary {
        didSet {
            guard tab != oldValue else { return }
            opensOnNotes = false
            // The bar of Find in Meeting is the transcript's.
            if tab != .transcript, findShown { closeFind() }
        }
    }
    /// The meeting just opened shows its Notes tab if it has notes.
    @ObservationIgnored var opensOnNotes = false
    /// The user's shorthand notes of the open meeting, with what the model wrote from them (the Notes tab).
    let notepad = NotepadModel()
    /// The note a search result opened, highlighted in the Notes tab.
    var highlightedNote: Int64?
    var transcript: [MeetingStore.StoredSegment] = [] {
        // Another meeting, or lines added: the places found are the new transcript's.
        didSet { if findShown, transcript != oldValue { refreshFind() } }
    }
    /// Stored translations by segment, in one language (see `TranslationDisplay`).
    var translations: [Int64: String] = [:]
    /// The language of `translations` (a language identifier).
    var translationLanguage: String?
    var marks: [MeetingMark] = []
    /// When the recording was paused: the transcript shows where nothing was captured.
    var pauses: [MeetingPause] = []
    var notes: [MeetingNote] = []
    var decisions: [Decision] = []
    var tasks: [TaskItem] = []
    /// The minutes' decisions split from the items that ranked out (the "Other possible items" group of the Minutes tab).
    var minutesGroups: OtherPossibleItems { OtherPossibleItems(decisions: decisions, tasks: tasks) }
    /// The "Other possible items" group is open. It starts closed for every meeting.
    var otherItemsExpanded = false
    var suggestions: [Suggestion] = []
    var attendees: [Entity] = []
    var othersNamed: [Entity] = []
    var topics: [Entity] = []
    var openQuestions: [String] = []
    /// When the user marked the participants as informed (consent helper); nil = not marked.
    var participantsInformedAt: Date?
    var liveNotes: [LiveNotesBatch] = []
    /// The questions heard in the meeting (live answers) and whether their section is open.
    var detectedQuestions: [DetectedQuestion] = []
    var questionsExpanded = false
    /// Set to scroll the Minutes tab to the Questions section (a kept question opened from search).
    var revealQuestions = false
    /// The speakers of the open meeting and what the views derive from them (empty without speaker data).
    var speakers: [MeetingSpeaker] = []
    var roster = SpeakerRoster.empty
    /// separation is off for the meeting.
    var speakersOff = false
    /// The open meeting was made from an imported file.
    var meetingImported = false
    /// The undo of the last speaker edit in flight: the next edit or undo waits for it, so quick repeated ⌘Z presses
    /// restore the store one after the other, in order.
    @ObservationIgnored var speakerUndoQueue: Task<Void, Never>?
    /// This session removed the open meeting's speakers (separation turned off while it had some). The switch stays on
    /// screen afterwards, with a note, because turning separation back on cannot bring them back (there is no audio).
    var speakersRemovedHere = false
    /// The last removal of the meeting's speakers, with the token of its Edit ▸ Undo entry: "Bring Back Speakers" undoes
    /// exactly this, never whatever else is on the window's undo stack.
    @ObservationIgnored var pendingSpeakerRemoval: (token: UUID, outcome: SpeakerEditOutcome)?
    /// Undo entries whose edit was already taken back some other way: their step does nothing when it comes up.
    @ObservationIgnored var spentSpeakerUndos: Set<UUID> = []
    /// The user used the switch in this session: it stays on screen, whatever state it ends in.
    var separationTouched = false
    /// The speaker popover that is open (on a transcript line or on a "Who spoke" row).
    var speakerPopover: SpeakerPopoverTarget?
    /// The confirmation of turning speaker separation off for the open meeting is shown.
    var confirmingSpeakersOff = false
    /// Speakers of the open meeting whose voice Vauta kept, so “Remember this voice” can save it (only while recognizing
    /// voices is on). IDs only.
    var keptVoices: Set<Int64> = []
    /// The consent sheet of “Remember this voice” is open for this speaker.
    var voiceConsent: VoiceConsentRequest?
    /// Looking for a voice the user just confirmed in earlier meetings: the offer, the search and its result.
    var voiceHistory: VoiceHistoryState?
    /// The review of what the search found is open.
    var reviewingPastVoices = false
    /// What undoes each decision of the review and the whole search (no voice data: speaker rows).
    @ObservationIgnored var pastVoiceUndos: [Int64: SpeakerUndo] = [:]
    @ObservationIgnored var pastVoiceSweepUndo: SpeakerUndo?
    /// How many saved voices (fingerprints) the person on the entity card has.
    var entityVoices = 0
    /// The window's undo manager: speaker edits register with it, so Edit ▸ Undo and ⌘Z take them back.
    @ObservationIgnored weak var undoManager: UndoManager? {
        didSet {
            notepad.undoManager = undoManager
            actions.undoManager = undoManager
        }
    }
    /// The "Live notes" group of the Summary is open.
    var liveNotesExpanded = false
    /// Title, summary and topics being edited (autosaved).
    var draft: MeetingDraft?
    var newDecision = ""
    var newQuestion = ""
    var newTask = ""
    /// "Find Names Again" is running.
    var reanalyzing = false
    @ObservationIgnored var autosaveTask: Task<Void, Never>?
    @ObservationIgnored var taskAutosave: Task<Void, Never>?

    // Task editor (in the meeting or in Tasks)
    var taskSelection: Int64? {
        didSet {
            guard taskSelection != oldValue else { return }
            saveTaskDraftInBackground()
            loadTaskEditor()
        }
    }
    var taskDraft: TaskDraft?
    var taskSort: [KeyPathComparator<TaskItem>] = [KeyPathComparator(\TaskItem.dueSortKey)]
    /// Tasks mode shows the open tasks or a week (`+Week`): a day of the week shown, and what it held once read.
    var tasksPane: TasksPane = .open
    var weekShown = Date.now
    var weekDigest: WeekDigest?

    // MARK: Minutes

    var jobs: [LLMJob] = []
    var cardSource: String?
    @ObservationIgnored var llm: LLMService? {
        didSet { ask.llm = llm; importer.llm = llm; notepad.llm = llm }
    }
    /// App preferences (copy protection, default template and language).
    @ObservationIgnored var preferences: Preferences? {
        didSet {
            importer.preferences = preferences
            if let preferences { actions.preferences = preferences.actions }
        }
    }

    // MARK: Ask and import

    let ask: AskModel
    let importer: RecordingImportModel
    /// Reminders, Calendar events and the follow-up email of the meetings (the Follow-up sheet and its editors).
    let actions: ActionsModel

    // MARK: Open tasks

    var openTasks: [TaskItem] = []
    /// Links to earlier meetings (post-meeting actions, Part B). The suggestions and confirmed links of the open meeting by the newer item,
    /// and the pairs the person said are not the same.
    var linkRows: [LinkRowKey: LinkRow] = [:]
    var dismissedLinks: [DismissedLink] = []
    /// Tasks mode: the open task that stands for each chain of tasks confirmed as the same (by its id), and the earlier open members it hides.
    var openChains: [Int64: OpenTaskChain] = [:]
    var hiddenChainTasks: Set<Int64> = []
    /// How many suggestions wait under each task, by task id ("1 suggestion" on its row in Tasks mode).
    var pendingLinkCounts: [Int64: Int] = [:]
    /// The chain whose done circle was pressed: the prompt asks whether its earlier mentions go too.
    var chainDonePrompt: OpenTaskChain?
    /// The chains whose earlier mentions are listed (by the id of the task that stands for the chain).
    var expandedChains: Set<Int64> = []
    /// Link rows being acted on: a pass that replaces one meanwhile does not take it from under the pointer.
    @ObservationIgnored var actingLinks: Set<Int64> = []
    var ownerFilter: Int64?
    /// Bumped by Edit > Find: the window moves the focus to the search field.
    var searchFocusRequest = 0
    /// Find in the meeting shown (⌘F, `MeetingsModel+Find`): the bar, its text, the speaker it is limited to, the places found and the
    /// one chosen.
    var findShown = false
    var findText = "" { didSet { if findText != oldValue { refreshFind() } } }
    var findSpeaker: Int64? { didSet { if findSpeaker != oldValue { refreshFind() } } }
    var findMatches: [TranscriptFind.Match] = []
    var findIndex: Int?
    /// Bumped by ⌘F: the bar moves the focus to its field.
    var findFocusRequest = 0

    // MARK: People and projects

    var entities: [Entity] = []
    var selectedEntityID: Int64? {
        didSet { if selectedEntityID != oldValue { noteActivity(); Task { await loadEntity() } } }
    }
    var entityRefs: [MentionRef] = []
    var entityTimeline: [TimelineEntry] = []
    /// In how many meetings the person was named as a speaker.
    var entitySpokeIn = 0
    /// A passage per meeting the person said, when the user named them as a speaker.
    var entityQuotes: [SpokenQuote] = []
    var entityImpact: [GraphNode] = []
    var entityTasks: [TaskItem] = []

    var selected: MeetingStore.Meeting? { meetings.first { $0.id == selectedID } }
    var selectedEntity: Entity? { entities.first { $0.id == selectedEntityID } }
    var isActive: Bool { selectedID != nil && selectedID == activeMeetingID }
    /// A recording is in progress: "Erase All" is not possible.
    var isRecording: Bool { activeMeetingID != nil }
    /// A text search found nothing: the sidebar says so, and the detail pane doesn't keep showing a meeting the list doesn't.
    var searchHasNoResults: Bool {
        query.trimmingCharacters(in: .whitespaces).count >= 2 && hits.isEmpty && knowledgeHits.isEmpty && documentHits.isEmpty
    }
    /// The filters (tokens) match no meeting, though there are meetings.
    var filterHasNoResults: Bool {
        query.trimmingCharacters(in: .whitespaces).count < 2 && !meetings.isEmpty && visibleMeetings.isEmpty
    }
    /// The meeting the detail pane shows: none while the list has nothing to show, so the panes agree.
    var shownMeeting: MeetingStore.Meeting? { searchHasNoResults || filterHasNoResults ? nil : selected }
    var visibleMeetings: [MeetingStore.Meeting] {
        guard let filteredIDs else { return meetings }
        let set = Set(filteredIDs)
        return meetings.filter { set.contains($0.id) }
    }
    /// People, yourself first (the localized name of "Me" must not decide where it sits).
    var people: [Entity] { Self.selfFirst(entities.filter { $0.kind == .person }) }
    static func selfFirst(_ list: [Entity]) -> [Entity] { list.filter(\.isSelf) + list.filter { !$0.isSelf } }
    var sortedTasks: [TaskItem] { tasks.sorted(using: taskSort) }
    var openTaskCount: Int { tasks.filter { $0.status == .open }.count }
    var sortedOpenTasks: [TaskItem] {
        let visible = hiddenChainTasks.isEmpty ? openTasks : openTasks.filter { !hiddenChainTasks.contains($0.id) }
        let base = ownerFilter.map { o in visible.filter { $0.ownerID == o } } ?? visible
        let q = query.trimmingCharacters(in: .whitespaces)
        let filtered = q.isEmpty ? base : base.filter { $0.text.localizedStandardContains(q) }
        return filtered.sorted(using: taskSort)
    }
    var visibleEntities: [Entity] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entities }
        return entities.filter { ([$0.displayName, $0.name] + $0.aliases).contains { $0.localizedStandardContains(q) } }
    }
    /// Copy protection is on: no export, copy or selectable text.
    var copyProtected: Bool { preferences?.copyProtection ?? true }

    @ObservationIgnored let store: MeetingStore
    @ObservationIgnored var pendingHighlight: Int64?
    /// Review… in the panel while the window was still opening: the Follow-up sheet opens when it has loaded.
    @ObservationIgnored var pendingFollowUpReview: (meetingID: Int64, others: [Int64])?
    @ObservationIgnored var searchTask: Task<Void, Never>?
    @ObservationIgnored private var lastActivity = Date.distantPast
    /// The window is open and unlocked. An import that finishes while it is
    /// closed or locked must not load meeting text back into memory.
    @ObservationIgnored var isShowing = false
    /// Called with the new meeting's id when an import finishes while the window is closed or locked.
    @ObservationIgnored var onImportedWhileHidden: ((Int64) -> Void)?

    init(store: MeetingStore) {
        self.store = store
        ask = AskModel(store: store)
        importer = RecordingImportModel(store: store)
        actions = ActionsModel(store: store)
        actions.host = self
        ask.openCitation = { [weak self] meeting, segment in self?.open(meeting: meeting, segment: segment) }
        ask.openMinutes = { [weak self] meeting in self?.open(meeting: meeting, tab: .summary) }
        notepad.store = store
        notepad.addedAfter = true
        notepad.report = { [weak self] title, error in self?.present(title, error) }
        // Clearing a note's words in Meetings asks first, like every other delete here.
        notepad.confirmDelete = { [weak self] note in self?.pendingDeletion = .note(note) }
        notepad.notesChanged = { [weak self] in self?.refreshNotes() }
        // Notes that wait for the minutes job say so (its final pass writes them out).
        notepad.finalPassComing = { [weak self] in
            guard let self, let id = self.notepad.meetingID else { return false }
            return self.jobs.contains { $0.meetingID == id && $0.kind == .minutes && ($0.state == .queued || $0.state == .running) }
        }
        ask.meetingTitle = { [weak self] id in self?.meetings.first { $0.id == id }?.displayTitle }
        importer.onImported = { [weak self] id in
            guard let self else { return }
            guard self.isShowing else { self.onImportedWhileHidden?(id); return }
            await self.reload()
            self.mode = .meetings
            self.selectedID = id
            // A visible notice (which VoiceOver also announces), not only a spoken one.
            self.show(MeetingsNotice(text: String(localized: "Recording imported", comment: "Confirmation in Meetings when an import finishes"),
                                     symbol: StatusSymbol.ok.name))
        }
    }

    // MARK: Activity, errors, purge

    /// Tells the recorder the window is in use (at most every 5 s).
    func noteActivity() {
        let now = Date.now
        guard now.timeIntervalSince(lastActivity) >= 5 else { return }
        lastActivity = now
        onActivity?()
    }

    func present(_ title: String, _ error: Error) {
        alert = MeetingsAlert(title, error: error)
    }

    /// Drops what was shown from the interface's memory (window closed or app
    /// relocked). Unsaved drafts are saved first.
    func purgeVisible() {
        isShowing = false
        forgetSpeakerEdits()
        saveLineDraft()
        saveDraftsInBackground(refreshList: false)
        autosaveTask?.cancel()
        searchTask?.cancel()
        hits = []
        knowledgeHits = []
        documentHits = []
        query = ""
        tokens = []
        suggestedTokens = []
        filteredIDs = nil
        highlighted = nil
        pendingHighlight = nil
        selectedID = nil
        showingUpcoming = false
        clearDetail()
        meetings = []
        suggestionCounts = [:]
        openTasks = []
        entities = []
        selectedEntityID = nil
        entityRefs = []; entityTimeline = []; entityImpact = []; entityTasks = []; entitySpokeIn = 0; entityQuotes = []; entityVoices = 0
        ask.clear()
        pendingDeletion = nil
        showingExport = false
        alert = nil
        actions.forgetEverything()
        mode = .meetings
    }
}

extension MeetingsModel.Mode {
    /// Modes whose sidebar is the meeting list (search runs the full-text search).
    var searchesMeetings: Bool { self == .meetings || self == .ask }
}

extension TaskItem {
    /// Non-optional sort keys for `Table`.
    var dueSortKey: Double { displayDay().map { Double($0.epochDay) } ?? .greatestFiniteMagnitude }
    var ownerSortKey: String { ownerName ?? "~" }
    var statusSortKey: String { status.rawValue }
    var meetingSortKey: String { meetingTitle ?? "" }
}

extension TaskItem.Status {
    var label: String {
        switch self {
        case .open: String(localized: "Open", comment: "Task status")
        case .done: String(localized: "Done", comment: "Task status")
        case .dropped: String(localized: "Dropped", comment: "Task status")
        }
    }
}
