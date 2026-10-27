// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import SwiftUI

// Remaining states: whole Settings panes (below the fold), locked windows,
// empty lists, minutes queued or failed, a selected task, a pending calendar
// person, Status with problems and speech model downloads. States that the
// window's own first load would replace are applied in `after`.

extension SnapshotScenes {
    static var coverage: [SnapshotScene] { settingsFull + settingsMore + contextMore + meetingsMore + onboardingMore }

    // MARK: Settings panes in full

    /// Each pane at a height that shows everything (the real window scrolls).
    static var settingsFull: [SnapshotScene] {
        [
            settingsScene("general-full", .general, size: CGSize(width: 1020, height: 1180)),
            settingsScene("recording-full", .recording, size: CGSize(width: 1020, height: 1340)),
            settingsScene("translation-full", .translation, size: CGSize(width: 1020, height: 1400)) { recorder, fixture in
                fixture.preferences.translationRefinementEnabled = true
                fixture.preferences.translationModel = ""
                fixture.installTranslationSettings(on: recorder.liveTranslation)
            },
            // A language being downloaded (Apple's sheet is open), and one whose download didn't finish.
            settingsScene("translation-downloading", .translation, size: CGSize(width: 1020, height: 1400)) { recorder, fixture in
                let sample = fixture.captionSample
                fixture.installTranslationSettings(on: recorder.liveTranslation)
                if let target = sample.targets.first(where: { $0.availability != .installed }) {
                    recorder.liveTranslation.installSnapshotDownloading(TranslationPair(source: sample.pair.source, target: target.language))
                }
            },
            settingsScene("translation-download-failed", .translation, size: CGSize(width: 1020, height: 1400)) { recorder, fixture in
                let sample = fixture.captionSample
                fixture.installTranslationSettings(on: recorder.liveTranslation)
                let failed = sample.targets.first(where: { $0.availability != .installed })
                recorder.liveTranslation.installSnapshotDownloadFailed(failed.map { TranslationPair(source: sample.pair.source, target: $0.language) })
            },
            settingsScene("privacy-full", .privacy, size: CGSize(width: 1020, height: 1180)),
            // Old copies from the earlier-version migration exist: Erase names them.
            settingsScene("privacy-full-leftovers", .privacy, size: CGSize(width: 1020, height: 1180)) { _, fixture in
                try? fixture.world.stageLeftovers(setAside: 2, oldFolder: true)
            },
            settingsScene("status-full", .status, size: CGSize(width: 1020, height: 960)),
        ]
    }

    // MARK: Settings states

    static var settingsMore: [SnapshotScene] {
        [
            settingsScene("recording-downloading", .recording, size: CGSize(width: 1020, height: 1340)) { _, fixture in
                let speech = fixture.settings.speech
                await speech.refresh()
                let language = SnapshotMode.catalog?.language(matching: foreignSpeechID(fixture))
                speech.installSnapshotState(downloading: language, progress: 0.42,
                                            failed: SnapshotMode.catalog?.language(matching: foreignSpeechID(fixture, 1)))
            },
            // Everything that can go wrong at once: permissions, model server, shortcut.
            settingsScene("status-problems", .status, size: CGSize(width: 1020, height: 960)) { recorder, fixture in
                fixture.settings.resetSnapshotStatus()
                SnapshotMode.microphone = .denied
                SnapshotMode.notifications = .notDetermined
                recorder.serverConfig = nil
                recorder.hotKeyAvailable = false
            },
        ]
    }

    // MARK: Context states

    static var contextMore: [SnapshotScene] {
        [
            settingsScene("context-locked", .context, size: CGSize(width: 1020, height: SettingsWindow.defaultHeight)) { recorder, _ in
                recorder.historyUnlocked = false
            },
            contextAfterScene("context-series-empty") { context, _ in
                context.section = .series
                context.close()
                context.series = []
            },
            contextAfterScene("context-pending-person") { context, fixture in
                pend(context, fixture)
                context.section = .people
                context.show(entityID: fixture.world.peopleIDs[2])
            },
            // The forms at their full height, so the bottom margin shows.
            contextAfterScene("context-people-full", size: CGSize(width: 1020, height: 1000)) { context, fixture in
                context.section = .people
                context.show(entityID: fixture.world.peopleIDs[1])
            },
            contextAfterScene("context-projects-full", size: CGSize(width: 1020, height: 1000)) { context, fixture in
                context.section = .work
                context.show(entityID: fixture.world.projectID)
            },
            contextAfterScene("context-pending-prompt") { context, fixture in
                pend(context, fixture)
                context.section = .people
                context.close()
            },
        ]
    }

    /// One sample person shown as an attendee the calendar suggested (in memory only).
    private static func pend(_ context: ContextModel, _ fixture: SnapshotFixture) {
        let id = fixture.world.peopleIDs[2]
        context.entities = context.entities.map { $0.id == id ? $0.snapshotPending : $0 }
    }

    static func contextAfterScene(_ name: String, size: CGSize = CGSize(width: 1020, height: SettingsWindow.defaultHeight),
                                          apply: @escaping @MainActor (ContextModel, SnapshotFixture) -> Void) -> SnapshotScene {
        SnapshotScene(name: "settings-\(name)", size: size) { fixture in
            let recorder = await fixture.makeRecorder()
            let settings = fixture.settings
            settings.pane = .context
            let view = SettingsWindow(recorder: recorder, preferences: fixture.preferences, model: settings)
                .environment(\.copyProtection, false)
            return .init(view: AnyView(view), title: SettingsModel.Pane.context.title, after: {
                guard let context = recorder.context else { return }
                await context.reload()
                apply(context, fixture)
            })
        }
    }

    // MARK: Meetings states

    /// A Meetings scene whose state goes on top of the window's own first load.
    /// The same, for a scene about documents: the recorder holds `documents` when the window opens (it takes them from there).
    static func meetingsDocumentsScene(_ name: String, size: CGSize = meetingsSize, documents: @escaping @MainActor (SnapshotFixture) -> DocumentsModel,
                                       prepare: @escaping @MainActor (MeetingsModel, SnapshotFixture) async -> Void = { _, _ in },
                                       apply: @escaping @MainActor (MeetingsModel, SnapshotFixture) async -> Void) -> SnapshotScene {
        buildMeetingsScene(name, prefix: "", size: size, documents: documents, prepare: prepare, apply: apply)
    }

    static func meetingsAfterScene(_ name: String, prefix: String = "meetings-", size: CGSize = meetingsSize,
                                   prepare: @escaping @MainActor (MeetingsModel, SnapshotFixture) async -> Void = { _, _ in },
                                   apply: @escaping @MainActor (MeetingsModel, SnapshotFixture) async -> Void) -> SnapshotScene {
        buildMeetingsScene(name, prefix: prefix, size: size, documents: nil, prepare: prepare, apply: apply)
    }

    private static func buildMeetingsScene(_ name: String, prefix: String, size: CGSize, documents: (@MainActor (SnapshotFixture) -> DocumentsModel)?,
                                           prepare: @escaping @MainActor (MeetingsModel, SnapshotFixture) async -> Void,
                                           apply: @escaping @MainActor (MeetingsModel, SnapshotFixture) async -> Void) -> SnapshotScene {
        SnapshotScene(name: "\(prefix)\(name)", size: size) { fixture in
            let recorder = await fixture.makeRecorder()
            // The window takes its documents from the recorder when it opens: a scene about them sets them there.
            if let model = documents?(fixture) { recorder.documents = model }
            guard let history = recorder.history else { return .init(view: AnyView(EmptyView())) }
            history.llm = nil
            try? await fixture.world.restoreTranscript()
            await history.reload()
            await prepare(history, fixture)
            if history.tab == .notes { history.tab = .summary }
            let view = MeetingsWindow(model: history, recorder: recorder, preferences: fixture.preferences, settings: fixture.settings)
            return .init(view: AnyView(view), title: String(localized: "Meetings", comment: "Window title"), after: {
                await apply(history, fixture)
            })
        }
    }

    /// A minutes job of the featured meeting in `state`, read back from the store and removed again.
    static func job(_ fixture: SnapshotFixture, _ state: LLMJob.State, code: JobErrorCode? = nil) async -> LLMJob? {
        let store = fixture.world.store
        let id = fixture.world.featuredMeetingID
        try? await store.enqueueJob(.minutes, meeting: id)
        guard let queued = (try? await store.jobs(for: id))?.first(where: { $0.kind == .minutes }) else { return nil }
        if state != .queued { try? await store.markJob(queued.id, state, code: code) }
        let read = (try? await store.jobs(for: id))?.first { $0.id == queued.id }
        try? await store.removeJob(queued.id)
        return read
    }

    static func featured(_ history: MeetingsModel, _ fixture: SnapshotFixture) async {
        history.selectedID = fixture.world.featuredMeetingID
        await history.loadDetail()
    }

    static var meetingsMore: [SnapshotScene] {
        [
            SnapshotScene(name: "meetings-locked", size: meetingsSize) { fixture in
                let recorder = await fixture.makeRecorder()
                return .init(view: AnyView(MeetingsLockedView(recorder: recorder).frame(maxWidth: .infinity, maxHeight: .infinity)),
                             title: String(localized: "Meetings", comment: "Window title"))
            },
            // The store failed to open: the reason and a way to retry, not a spinner.
            SnapshotScene(name: "meetings-store-failed", size: meetingsSize) { fixture in
                let recorder = await fixture.makeRecorder()
                recorder.history = nil
                (recorder.phase, recorder.storeOpenRecovery) = RecorderModel.storeOpenFailure(StoreError(.keychainUnavailable, detail: "snapshot"))
                return .init(view: AnyView(MeetingsLockedView(recorder: recorder).frame(maxWidth: .infinity, maxHeight: .infinity)),
                             title: String(localized: "Meetings", comment: "Window title"))
            },
            // First run: no meetings at all.
            meetingsAfterScene("empty") { history, _ in
                history.selectedID = nil
                history.meetings = []
                history.suggestionCounts = [:]
            },
            // A filter by someone with no meetings yet (a client just added): the real filter finds nothing. The entity
            // exists only for this scene.
            meetingsAfterScene("filter-empty", prepare: { history, fixture in
                _ = try? await fixture.world.store.saveEntity(EntityDraft(kind: .client, name: "Contoso", note: "", aliases: []))
                await history.reload()
            }) { history, fixture in
                let store = fixture.world.store
                if let client = history.entities.first(where: { $0.displayName == "Contoso" }) {
                    history.tokens = [FilterToken(kind: .entity(client.id), label: client.displayName, symbol: client.kind.symbol)]
                    try? await Task.sleep(for: .milliseconds(500))
                    try? await store.deleteEntity(client.id)
                }
                history.selectedID = nil
            },
            meetingsAfterScene("search-empty") { history, _ in
                history.query = "zqxw"
                try? await Task.sleep(for: .milliseconds(900))
            },
            // Still being recorded: the minutes come at the end, so the summary is empty (only the status line).
            meetingsAfterScene("recording", prepare: { history, fixture in
                // It began a few minutes ago: "Recording" and today's time belong to one live meeting, and its minutes (tasks included) come at the end.
                try? await fixture.world.startFeaturedMeeting(minutesAgo: 6)
                await history.reload()
                await featured(history, fixture)
            }) { history, fixture in
                history.activeMeetingID = fixture.world.featuredMeetingID
                history.tasks = []
                history.draft?.summary = ""
                history.draft?.topicsText = ""
                // Only what is shown: the store keeps the minutes (an edit that looks unsaved would be written back).
                if let draft = history.draft { history.draft?.markSaved(draft.changes) }
                history.decisions = []
                history.openQuestions = []
                history.liveNotes = []
                history.cardSource = nil
            },
            // The confirmation banner, and the one with the exported file.
            meetingsAfterScene("notice-copied", prepare: featured) { history, _ in
                history.notice = .copied
            },
            // A PDF still being written: a spinner, never the success mark.
            meetingsAfterScene("notice-exporting", prepare: featured) { history, _ in
                history.notice = MeetingsNotice(text: String(localized: "Exporting…", comment: "Shown while a meeting is written to a PDF file"),
                                                symbol: "hourglass", inProgress: true)
            },
            meetingsAfterScene("notice-exported", prepare: featured) { history, _ in
                // The file is named after the (localized) meeting, as the exporter names it.
                let name = (history.selected?.displayTitle ?? "Meeting") + ".md"
                history.notice = MeetingsNotice(text: String(localized: "Exported “\(name)”", comment: "Confirmation after exporting a meeting; the argument is the file name"),
                                                symbol: StatusSymbol.ok.name,
                                                reveal: URL(fileURLWithPath: "/Users/maya/Documents/\(name)"))
            },
            // A passage highlighted to cite it; and a meeting opened from a search (the words are marked).
            meetingsAfterScene("transcript-highlight", prepare: featured) { history, fixture in
                history.tab = .transcript
                history.highlighted = fixture.world.featuredSegmentIDs[3]
            },
            // Opened from a search result: the result is selected and its own passage is highlighted.
            meetingsAfterScene("transcript-from-search", prepare: featured) { history, fixture in
                history.tab = .transcript
                history.query = fixture.content.searchQuery
                try? await Task.sleep(for: .milliseconds(900))
                if let hit = history.hits.first(where: { $0.meeting.id == fixture.world.featuredMeetingID }) ?? history.hits.first {
                    history.openedHit = "t\(hit.id)"
                }
                try? await Task.sleep(for: .milliseconds(400))
            },
            // The end of a finished meeting's Summary: live notes (expanded), decisions, marks and notes, and the footer.
            meetingsAfterScene("summary-bottom", size: CGSize(width: 1040, height: 1180), prepare: featured) { history, fixture in
                // The notes taken during the recording, from the meeting's own decisions, questions and tasks.
                let ids = fixture.world.featuredSegmentIDs
                history.liveNotes = [LiveNotesBatch(
                    t: 300,
                    points: history.openQuestions.prefix(1).map { .init(text: $0, segment: ids[2]) },
                    decisions: history.decisions.prefix(1).map { .init(text: $0.text, segment: ids[4]) },
                    tasks: history.tasks.prefix(1).map { .init(text: $0.text, owner: $0.ownerName, segment: ids[5]) })]
                history.liveNotesExpanded = true
            },
            // The transcript header's other states: the retention period passed, and nothing was transcribed.
            meetingsAfterScene("transcript-expired", prepare: featured) { history, _ in
                if let meeting = history.selected, let index = history.meetings.firstIndex(where: { $0.id == meeting.id }) {
                    // A fixed time of day, so every language and round shows the same date line.
                    let day = AppClock.now.addingTimeInterval(-Double(MeetingStore.retentionDays + 10) * 86_400)
                    let old = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: day) ?? day
                    let aged = MeetingStore.Meeting(id: meeting.id, startedAt: old, endedAt: old.addingTimeInterval(1_800),
                                                    title: meeting.title, locale: meeting.locale,
                                                    outputLocale: meeting.outputLocale, sourceApp: meeting.sourceApp)
                    // The list is newest first, so the aged meeting is now the last one.
                    history.meetings.remove(at: index)
                    history.meetings.append(aged)
                }
                history.transcript = []
                history.tab = .transcript
            },
            meetingsAfterScene("transcript-empty", prepare: featured) { history, _ in
                history.transcript = []
                history.tab = .transcript
            },
            meetingsAfterScene("tasks-tab-empty", prepare: featured) { history, _ in
                history.tab = .tasks
                history.tasks = []
            },
            meetingsAfterScene("task-selected", prepare: featured) { history, _ in
                history.tab = .tasks
                history.taskSelection = history.sortedTasks.first?.id
                try? await Task.sleep(for: .milliseconds(300))
            },
            meetingsAfterScene("suggestions-empty", prepare: featured) { history, _ in
                history.tab = .suggestions
                history.suggestions = []
            },
            meetingsAfterScene("minutes-queued", prepare: featured) { history, fixture in
                if let job = await job(fixture, .queued) { history.jobs = [job] }
                history.cardSource = nil
            },
            meetingsAfterScene("minutes-failed", prepare: featured) { history, fixture in
                if let job = await job(fixture, .failed, code: .contextLengthExceeded) { history.jobs = [job] }
                history.cardSource = nil
            },
            // Written by hand: "Write Minutes" instead of "Rewrite Minutes", no model notice.
            meetingsAfterScene("minutes-manual", prepare: featured) { history, _ in
                history.jobs = []
                history.cardSource = "user"
            },
            meetingsAfterScene("open-tasks-empty") { history, _ in
                history.mode = .tasks
                // After the window's own load has filled the list.
                try? await Task.sleep(for: .milliseconds(600))
                history.openTasks = []
            },
            meetingsAfterScene("open-tasks-search-empty") { history, _ in
                history.mode = .tasks
                await history.reloadMode()
                history.query = "zqxw"
            },
            meetingsAfterScene("open-task-selected") { history, _ in
                history.mode = .tasks
                await history.reloadMode()
                history.taskSelection = history.sortedOpenTasks.first?.id
                try? await Task.sleep(for: .milliseconds(300))
            },
            meetingsAfterScene("people-select-prompt") { history, _ in
                history.mode = .people
                history.selectedEntityID = nil
            },
            meetingsAfterScene("people-project") { history, fixture in
                history.mode = .people
                history.selectedEntityID = fixture.world.projectID
                await history.loadEntity()
            },
            meetingsAfterScene("people-empty") { history, _ in
                history.mode = .people
                try? await Task.sleep(for: .milliseconds(600))
                history.selectedEntityID = nil
                history.entities = []
            },
        ]
    }

    // MARK: Onboarding states

    /// The speech model page for a language that isn't installed yet (the page is skipped when it is).
    private static func speechPage(_ name: String, configure: @escaping @MainActor (SpeechSettingsModel, SpeechLanguage?) -> Void)
        -> SnapshotScene {
        SnapshotScene(name: "onboarding-\(name)", size: onboardingSize) { fixture in
            let recorder = await fixture.makeRecorder()
            let preferences = fixture.makeScratchPreferences()
            preferences.onboardingCompletedVersion = Preferences.currentOnboardingVersion
            // The interface language's own speech model is the one missing (see `onboardingScene`).
            if let own = SnapshotMode.catalog?.language(matching: fixture.world.locale.identifier(.bcp47)), own.isInstalled {
                SnapshotMode.catalog = SampleWorld.speechCatalog(notInstalled: [own.id], rendering: fixture.world.locale.identifier(.bcp47))
                recorder.speechCatalog = SnapshotMode.catalog
            }
            let missing = SnapshotMode.catalog?.language(matching: fixture.world.locale.identifier(.bcp47))
            preferences.transcriptionLanguage = missing?.id
            let model = OnboardingModel()
            model.flow = OnboardingFlow(step: .speechModel)
            model.models.physicalMemory = 16 * ModelRecommendation.gibibyte
            let view = OnboardingView(recorder: recorder, preferences: preferences, snapshotModel: model)
            return .init(view: AnyView(view), title: String(localized: "Set Up Vauta", comment: "Window title of the first-run setup"),
                         after: {
                             await model.speech.refresh()
                             configure(model.speech, missing)
                         })
        }
    }

    static var onboardingMore: [SnapshotScene] {
        [
            speechPage("speech-model-downloading") { speech, language in
                speech.installSnapshotState(downloading: language, progress: 0.42)
            },
            speechPage("speech-model-failed") { speech, language in
                speech.installSnapshotState(downloading: nil, progress: 0, failed: language)
            },
        ]
    }
}
#endif
