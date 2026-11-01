// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation
import SwiftUI

/// The selected meeting: loading, the autosaved card draft, decisions,
/// tasks, notes, suggestions and the minutes written by the model.
extension MeetingsModel {
    /// How long typing must pause before a draft is saved.
    static let autosaveDelay: Duration = .seconds(1.5)

    func loadDetail() async {
        guard let id = selectedID else { clearDetail(); return }
        do {
            let segs = try await store.segments(of: id, echoes: true)
            let stored = try await store.translations(of: id)
            let marks = try await store.marks(id)
            let pauses = try await store.pauses(of: id)
            let notes = try await store.notes(id)
            let decisions = try await store.decisions(id)
            let tasks = try await store.tasks(id)
            let suggestions = try await store.suggestions(id)
            let card = try await store.card(id)
            let attendees = try await store.meetingEntities(id, role: .attendee)
            let others = try await store.meetingEntities(id, role: .others)
            let topics = try await store.meetingEntities(id, role: .topic)
            let jobs = try await store.jobs(for: id)
            let source = try await store.cardSource(id)
            let template = try await store.minutesTemplate(id)
            let followed = try await store.cardTemplate(id)
            let custom = try await store.customMinutesTemplates()
            let live = try await store.liveNotes(id)
            let title = try await store.meeting(id)?.title
            let brief = try? await store.storedBrief(of: id)
            let speakers = try await store.speakers(of: id)
            let speakersOff = try await store.speakersOff(meetingID: id)
            let kept = try await store.speakersWithKeptVoice(meetingID: id)
            let imported = try await store.isImported(meetingID: id)
            let informedAt = try await store.participantsInformedAt(id)
            guard selectedID == id else { return }
            self.jobs = jobs
            storedBrief = brief
            if brief == nil, tab == .brief { tab = .summary }
            cardSource = source
            minutesTemplate = template
            cardTemplate = followed
            customTemplates = custom
            transcript = segs
            self.speakers = speakers
            self.speakersOff = speakersOff
            meetingImported = imported
            keptVoices = kept
            roster = SpeakerRoster(speakers: speakers, segments: segs)
            translations = TranslationDisplay.texts(from: stored, preferred: preferences?.translationTarget)
            translationLanguage = TranslationDisplay.chooseLanguage(from: stored, preferred: preferences?.translationTarget)
            self.marks = marks
            self.pauses = pauses
            self.notes = notes
            let sameMeeting = notepad.meetingID == id
            notepad.meetingID = id
            notepad.hasTranscript = !segs.isEmpty
            notepad.offset = { [weak self] in Self.endOfMeeting(segs, notes: self?.notes ?? notes) }
            await notepad.reload(markUpdates: sameMeeting)
            if opensOnNotes {
                opensOnNotes = false
                if !notes.isEmpty { tab = .notes }
            }
            self.decisions = decisions
            self.tasks = tasks
            await loadLinks(id)
            self.suggestions = suggestions
            self.attendees = attendees
            othersNamed = others
            self.topics = topics
            openQuestions = card?.openQuestions ?? []
            participantsInformedAt = informedAt
            liveNotes = live
            await loadQuestions(id)
            if draft?.meetingID == id {
                draft?.rebase(title: title, card: card)
            } else {
                draft = MeetingDraft(meetingID: id, title: title, card: card)
            }
            loadTaskEditor()
            await loadDocuments()
            await loadRelatedMeetings()
        } catch {
            present(String(localized: "Couldn’t open this meeting", comment: "Alert title"), error)
        }
    }

    /// After a model job finished (new minutes).
    func refreshDetail() async {
        await loadDetail()
        suggestionCounts = (try? await store.openSuggestionCounts()) ?? suggestionCounts
    }

    /// The model job of the open meeting finished: reload its minutes and, when they are there now, tell VoiceOver
    /// (the system banner is not shown over the window that already shows them, and nothing else says it).
    func refreshAfterMinutes() async {
        let before = cardSource
        let wasRunning = jobs.contains { $0.kind == .minutes && $0.state == .running }
        await refreshDetail()
        guard cardSource == "llm", before != "llm" || wasRunning,
              !jobs.contains(where: { $0.kind == .minutes && $0.state == .failed }) else { return }
        AccessibilityNotification.Announcement(String(localized: "Minutes ready", comment: "Notification title")).post()
    }

    /// Where a note typed after the meeting goes in its timeline: the end of what was said, after every earlier note.
    static func endOfMeeting(_ segments: [MeetingStore.StoredSegment], notes: [MeetingNote]) -> Double {
        max(segments.map(\.end).max() ?? 0, notes.map(\.t).max() ?? 0)
    }

    /// The notes of the open meeting were added, edited or deleted in the Notes tab: the lists that show them (the
    /// Minutes tab's count, the transcript's inline notes) read them again.
    func refreshNotes() {
        guard let id = notepad.meetingID, id == selectedID else { return }
        Task {
            if let fresh = try? await store.notes(id), selectedID == id { notes = fresh }
        }
    }

    func clearDetail() {
        notepad.meetingID = nil; notepad.rows = []; notepad.draft = ""; notepad.editingID = nil; notepad.working = []
        notepad.disclosed = []; notepad.updated = []; notepad.clearBanners(); highlightedNote = nil
        speakers = []; keptVoices = []; voiceConsent = nil; voiceHistory = nil; reviewingPastVoices = false; roster = .empty; speakersOff = false; meetingImported = false; speakersRemovedHere = false; separationTouched = false; speakerPopover = nil; confirmingSpeakersOff = false
        transcript = []; translations = [:]; translationLanguage = nil; marks = []; pauses = []; notes = []; decisions = []; tasks = []; suggestions = []
        attendees = []; othersNamed = []; topics = []; openQuestions = []; liveNotes = []; detectedQuestions = []; jobs = []
        participantsInformedAt = nil
        materials = []; relatedDocuments = []; relatedMeetings = []
        cardSource = nil
        minutesTemplate = nil
        cardTemplate = nil
        storedBrief = nil
        draft = nil
        newDecision = ""
        newQuestion = ""
        newTask = ""
        taskSelection = nil
        taskDraft = nil
    }

    // MARK: Card draft (autosaved)

    /// The user typed in the title, summary or topics: save after a pause.
    func draftEdited() {
        noteActivity()
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            await self?.saveDraft()
        }
    }

    /// Saves the current draft now (if anything changed).
    func saveDraft() async {
        guard let draft, draft.isDirty else { return }
        let changes = draft.changes
        do {
            try await Self.write(changes, meetingID: draft.meetingID, to: store)
            if self.draft?.meetingID == draft.meetingID { self.draft?.markSaved(changes) }
            if changes.title != nil { meetings = (try? await store.meetings()) ?? meetings }
        } catch {
            alert = MeetingsAlert(String(localized: "Couldn’t save your changes", comment: "Alert title"), error: error,
                                  recovery: .retry { [weak self] in await self?.saveDraft() })
        }
    }

    /// Takes the pending drafts and saves them without waiting (selection
    /// change, close, relock): the values are captured now, so clearing the
    /// interface loses nothing. `refreshList` updates the sidebar titles
    /// afterwards (not when the interface is being purged).
    func saveDraftsInBackground(refreshList: Bool = true) {
        autosaveTask?.cancel()
        let store = store
        if let draft, draft.isDirty {
            let changes = draft.changes
            Task { [weak self] in
                do {
                    try await Self.write(changes, meetingID: draft.meetingID, to: store)
                    if refreshList, changes.title != nil, let self { self.meetings = (try? await store.meetings()) ?? self.meetings }
                } catch {
                    self?.present(String(localized: "Couldn’t save your changes", comment: "Alert title"), error)
                }
            }
        }
        draft = nil
        saveTaskDraftInBackground()
    }

    /// Saves pending drafts and waits (before quitting).
    func flushDrafts() async {
        autosaveTask?.cancel()
        await saveDraft()
        await saveTask()
        // The words being edited, the note not yet added and the expansion being rewritten are saved with the others.
        await notepad.commitAndSettle()
    }

    static func write(_ changes: MeetingDraft.Changes, meetingID: Int64, to store: MeetingStore) async throws {
        if let title = changes.title { try await store.setTitle(title, of: meetingID) }
        if let card = changes.card { try await store.saveCard(card, of: meetingID) }
    }

    // MARK: Topics, decisions, notes

    func setAttendees(_ ids: [Int64]) async {
        guard let id = selectedID else { return }
        await perform(String(localized: "Couldn’t change the attendees", comment: "Alert title")) {
            try await store.setMeetingEntities(id, role: .attendee, ids)
        }
        await loadDetail()
    }

    func setTopics(_ ids: [Int64]) async {
        guard let id = selectedID else { return }
        await perform(String(localized: "Couldn’t change the topics", comment: "Alert title")) {
            try await store.setMeetingEntities(id, role: .topic, ids)
        }
        await loadDetail()
    }

    func addDecision() async {
        let text = SingleLineText.flatten(newDecision).trimmingCharacters(in: .whitespaces)
        guard let id = selectedID, !text.isEmpty else { return }
        let seg = highlightedSegment
        await perform(String(localized: "Couldn’t add the decision", comment: "Alert title")) {
            _ = try await store.addDecision(id, text: text, segmentID: seg?.id, t: seg?.start)
            newDecision = ""
        }
        await loadDetail()
    }

    /// Adds an open question to the minutes by hand, keeping what the user has typed in the summary.
    func addQuestion() async {
        let text = SingleLineText.flatten(newQuestion).trimmingCharacters(in: .whitespaces)
        guard let id = selectedID, !text.isEmpty else { return }
        await saveDraft()
        await perform(String(localized: "Couldn’t add the question", comment: "Alert title")) {
            var card = try await store.card(id) ?? MeetingCard()
            card.openQuestions = (card.openQuestions ?? []) + [text]
            try await store.saveCard(card, of: id)
            newQuestion = ""
        }
        await loadDetail()
    }

    func addTask() async {
        let text = SingleLineText.flatten(newTask).trimmingCharacters(in: .whitespaces)
        guard let id = selectedID, !text.isEmpty else { return }
        let seg = highlightedSegment
        await perform(String(localized: "Couldn’t add the task", comment: "Alert title")) {
            let task = try await store.addTask(id, text: text, segmentID: seg?.id, t: seg?.start)
            newTask = ""
            await loadDetail()
            taskSelection = task
        }
    }

    /// The highlighted transcript segment (cited by a new decision or task).
    var highlightedSegment: MeetingStore.StoredSegment? {
        highlighted.flatMap { h in transcript.first { $0.id == h } }
    }

    func highlight(_ segment: MeetingStore.StoredSegment) {
        noteActivity()
        highlighted = highlighted == segment.id ? nil : segment.id
    }

    /// Moves the highlight to the previous or next segment (arrow keys).
    func moveHighlight(by step: Int) {
        guard !transcript.isEmpty else { return }
        let index = highlighted.flatMap { h in transcript.firstIndex { $0.id == h } }
        let next = index.map { min(max($0 + step, 0), transcript.count - 1) } ?? (step > 0 ? 0 : transcript.count - 1)
        highlighted = transcript[next].id
    }

    // MARK: Task editor

    /// The selected task as stored (the editor edits a draft of it).
    var selectedTask: TaskItem? {
        taskSelection.flatMap { id in (tasks + openTasks + entityTasks).first { $0.id == id } }
    }

    func loadTaskEditor() {
        guard let id = taskSelection, let t = (tasks + openTasks + entityTasks).first(where: { $0.id == id }) else {
            taskDraft = nil
            return
        }
        if taskDraft?.taskID == id, taskDraft?.isDirty == true { return }
        taskDraft = TaskDraft(t)
    }

    /// The task editor changed: save after a pause (Return and selecting another task save at once).
    func taskEdited() {
        noteActivity()
        taskAutosave?.cancel()
        taskAutosave = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            await self?.saveTask()
        }
    }

    func saveTask() async {
        guard let draft = taskDraft, draft.isDirty, draft.canSave else { return }
        let edited = draft.edited
        await perform(String(localized: "Couldn’t save the task", comment: "Alert title")) {
            try await store.updateTask(edited)
            taskDraft = nil
        }
        await refreshTasks()
    }

    /// Saves an edited task when the selection moves away from it.
    func saveTaskDraftInBackground() {
        guard let draft = taskDraft, draft.isDirty, draft.canSave else { return }
        let store = store, edited = draft.edited
        taskDraft = nil
        Task { [weak self] in
            do {
                try await store.updateTask(edited)
            } catch {
                self?.present(String(localized: "Couldn’t save the task", comment: "Alert title"), error)
            }
            await self?.refreshTasks()
        }
    }

    /// "Mark as Checked": the user verified what the transcript did not back.
    func markSelectedTaskChecked() async {
        guard let id = taskSelection else { return }
        await saveTask()
        await perform(String(localized: "Couldn’t change the task", comment: "Alert title")) { try await store.markTaskChecked(id) }
        taskDraft = nil
        await refreshTasks()
    }

    func markDecisionChecked(_ decision: Decision) async {
        await perform(String(localized: "Couldn’t change the decision", comment: "Alert title")) { try await store.markDecisionChecked(decision.id) }
        await loadDetail()
    }

    /// "Mark as Checked" on a task from the minutes' group of other possible items (the Tasks tab does it for the selected task).
    func markTaskChecked(_ task: TaskItem) async {
        await perform(String(localized: "Couldn’t change the task", comment: "Alert title")) { try await store.markTaskChecked(task.id) }
        if taskSelection == task.id { taskDraft = nil }
        await refreshTasks()
    }

    func setStatus(_ id: Int64, _ status: TaskItem.Status) async {
        await perform(String(localized: "Couldn’t change the task", comment: "Alert title")) {
            try await store.setTaskStatus(id, status)
        }
        await refreshTasks()
    }

    func refreshTasks() async {
        if let id = selectedID { tasks = (try? await store.tasks(id)) ?? tasks }
        openTasks = (try? await store.openTasks()) ?? openTasks
        await loadChains()
        if let e = selectedEntityID { entityTasks = (try? await store.openTasks(owner: e)) ?? entityTasks }
        loadTaskEditor()
    }

    // MARK: Suggestions and analysis

    func resolve(_ s: Suggestion, entity: Int64?) async {
        await perform(String(localized: "Couldn’t apply the suggestion", comment: "Alert title")) {
            try await store.resolveSuggestion(s.id, entity: entity)
        }
        suggestionCounts = (try? await store.openSuggestionCounts()) ?? suggestionCounts
        await loadDetail()
    }

    /// Records (or removes) that the participants were told the meeting was transcribed.
    func setParticipantsInformed(_ informed: Bool) async {
        guard let id = selectedID else { return }
        await perform(String(localized: "Couldn’t save the change", comment: "Alert title")) {
            if informed { try await store.markParticipantsInformed(id) } else { try await store.clearParticipantsInformed(id) }
        }
        participantsInformedAt = (try? await store.participantsInformedAt(id)) ?? nil
    }

    /// Accepts one of the suggestion's candidates: a person or project, or a glossary term.
    func resolve(_ s: Suggestion, candidate: SuggestionCandidate) async {
        if let entity = candidate.entityID {
            await resolve(s, entity: entity)
        } else if let term = candidate.glossaryID {
            await perform(String(localized: "Couldn’t apply the suggestion", comment: "Alert title")) {
                try await store.resolveSuggestion(s.id, glossary: term)
            }
            suggestionCounts = (try? await store.openSuggestionCounts()) ?? suggestionCounts
            await loadDetail()
        } else {
            await resolve(s, entity: nil)
        }
    }

    func reanalyze() async {
        guard let id = selectedID, !reanalyzing else { return }
        reanalyzing = true
        defer { reanalyzing = false }
        await perform(String(localized: "Couldn’t analyze the meeting", comment: "Alert title")) {
            _ = try await store.analyze(id)
            // A person added to Context since: a speaker who said they are that person is asked about them now.
            try await store.suggestSpeakersFromIntroductions(meetingID: id)
        }
        suggestionCounts = (try? await store.openSuggestionCounts()) ?? suggestionCounts
        await loadDetail()
    }

    // MARK: Minutes from the model

    /// Writes (or rewrites) the minutes with a template; nil keeps the
    /// meeting's own template (set from the default when it was recorded),
    /// or uses its series' template, else the default, for meetings recorded before templates existed.
    func regenerateMinutes(template: MinutesTemplateChoice? = nil) async {
        guard let id = selectedID, let llm else { return }
        noteActivity()
        var chosen = template
        if chosen == nil, (try? await store.minutesTemplate(id)) == nil {
            chosen = (try? await store.seriesTemplate(of: id)) ?? preferences?.minutesTemplate
        }
        await llm.regenerateMinutes(id, template: chosen)
        guard selectedID == id else { return }
        if let chosen { minutesTemplate = chosen }
        jobs = (try? await store.jobs(for: id)) ?? jobs
    }

    /// The templates the person wrote changed in Settings: the Rewrite menu and the open meeting's template follow (a deleted one
    /// gave its meetings another). Nothing is read while Meetings are locked.
    func minutesTemplatesChanged() {
        guard isShowing else { return }
        Task {
            customTemplates = (try? await store.customMinutesTemplates()) ?? customTemplates
            if let id = selectedID, let template = try? await store.minutesTemplate(id), selectedID == id { minutesTemplate = template }
        }
    }

    /// The model's card followed a template the person wrote: the minutes say it was not evaluated, with its name while it exists.
    var cardFollowedCustomTemplate: (followed: Bool, name: String?) {
        guard case .custom(let id) = cardTemplate else { return (false, nil) }
        return (true, customTemplates.first { $0.id == id }?.name)
    }

    func cancelMinutes() async {
        guard let id = selectedID, let llm else { return }
        await llm.cancel(meetingID: id, kind: .minutes)
        jobs = (try? await store.jobs(for: id)) ?? jobs
    }

    func perform(_ title: String, _ work: () async throws -> Void) async {
        do { try await work() } catch { present(title, error) }
    }
}
