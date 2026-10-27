// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import SwiftUI

/// One image: a view in a window or panel, prepared with sample state.
struct SnapshotScene {
    struct Prepared {
        var view: AnyView
        var title = ""
        var ready: @MainActor () -> Bool = { true }
        /// Runs once the window is on screen and its own loading (`.task`) has started: for states
        /// that the window's first load would otherwise replace (empty lists, pending items).
        var after: (@MainActor () async -> Void)?
        /// Set for a system alert or confirmation dialog: drawn by AppKit's own `NSAlert` instead of a hosted view.
        var alert: SnapshotAlert?
        /// Run on the final layout, before the image is taken: a reason the scene is wrong (the render fails with it), or nil.
        var verify: (@MainActor () -> String?)?
    }

    /// `<area>-<state>`; the language and appearance are appended to the file name.
    let name: String
    let size: CGSize
    var fitHeight = false
    var isPanel = false
    var isSheet = false
    var isFloating = false
    /// The image is as wide as the view is (a menu mock), not the width given in `size`.
    var fitWidth = false
    let make: @MainActor (SnapshotFixture) async -> Prepared

    func chrome(_ title: String) -> SnapshotHost.Chrome {
        isPanel ? .panel : isSheet ? .sheet : isFloating ? .floating : .window(title: title)
    }
}

@MainActor
enum SnapshotScenes {
    static let panelSize = CGSize(width: RecorderPanel.width, height: 400)
    static let settingsSize = CGSize(width: 1020, height: 540)
    static let meetingsSize = CGSize(width: 1040, height: 660)
    static let onboardingSize = OnboardingMetrics.windowSize

    static var all: [SnapshotScene] {
        let groups: [[SnapshotScene]] = [panel, panelStates, settings, settingsStates, context, onboarding, onboardingStates,
                                         meetings, meetingStates, consent, sheets, sheetStates, guide, captions, refinement,
                                         coverage, networkActivity, panelCoverage, speakers, liveSpeakers, voices, voiceHistory, dialogs, longContent, gaps,
                                         notepadScenes, documentScenes, searchModelScenes, integratedModelScenes, answerScenes, briefScenes, actionsScenes, otherItemsScenes, linkScenes, vqa]
        return groups.flatMap { $0 }
    }

    // MARK: Menu-bar panel

    /// The panel's room on a 13-inch MacBook Air; scenes use it so what clips never depends on the machine that renders.
    static let airPanelHeight: CGFloat = 860

    /// `maxHeight` stands in for the screen's height, to show how a tall panel scrolls.
    static func panelScene(_ name: String, maxHeight: CGFloat? = airPanelHeight, clock: Date? = nil, notesExpanded: Bool = false,
                           checksCuts: Bool = false, notesOnScreen: Bool = false, configure: @escaping @MainActor (RecorderModel, SnapshotFixture) -> Void) -> SnapshotScene {
        SnapshotScene(name: "panel-\(name)", size: panelSize, fitHeight: true, isPanel: true) { fixture in
            let recorder = await fixture.makeRecorder()
            configure(recorder, fixture)
            let view = RecorderPanel(model: recorder)
                .environment(\.panelMaxHeight, maxHeight)
                .environment(\.panelClock, clock)
                .environment(\.panelNotesExpanded, notesExpanded)
                .background(Color(nsColor: .windowBackgroundColor))
            var prepared = SnapshotScene.Prepared(view: AnyView(view))
            #if VAUTA_DIAGNOSTICS
            // The visible area of the panel never ends through a note (see `PanelGeometryProbe`).
            if checksCuts { prepared.verify = { PanelGeometryProbe.problem(requiringNotesOnScreen: notesOnScreen) } }
            #endif
            return prepared
        }
    }

    static var panel: [SnapshotScene] {
        [
            panelScene("idle") { _, _ in },
            panelScene("hotkey-taken") { recorder, _ in recorder.hotKeyAvailable = false },
            panelScene("suggestion") { recorder, fixture in
                recorder.callInProgress = true
                recorder.callApp = .zoom
                let call = CallDescription(appName: fixture.content.callApp, family: .zoom, service: nil)
                recorder.currentCall = call
                recorder.suggestion = RecordingSuggestion(event: nil, call: call)
            },
            panelScene("recording") { recorder, fixture in
                let content = fixture.content
                recorder.phase = .recording
                recorder.startedAt = AppClock.now.addingTimeInterval(-754)
                recorder.elapsedSeconds = 754
                recorder.levels = [.me: 0.35, .others: 0.7]
                recorder.segments = content.liveSegments.enumerated().map { LiveSegment(id: $0.offset, segment: $0.element) }
                recorder.volatileSegments = content.liveVolatileSegment.map { [$0] } ?? []
                recorder.showTranscript = true
                recorder.livePoints = content.livePoints
                recorder.liveDecisions = content.liveDecisions
                recorder.liveTasks = content.liveTasks
                recorder.recordingLanguage = SnapshotMode.catalog?.language(matching: fixture.world.locale.identifier(.bcp47))
                recorder.recordingSource = .apps([.zoom])
                recorder.recordingApp = CallDescription(appName: content.callApp, family: .zoom, service: nil)
            },
            panelScene("translation") { recorder, fixture in
                let content = fixture.content
                recorder.phase = .recording
                recorder.startedAt = AppClock.now.addingTimeInterval(-754)
                recorder.elapsedSeconds = 754
                recorder.levels = [.me: 0.35, .others: 0.7]
                let sample = fixture.captionSample
                // The others speak the sample's source language, so the row shows a real pair.
                recorder.recordingLanguage = SnapshotMode.catalog?.language(matching: sample.pair.source.minimalIdentifier)
                recorder.recordingSource = .apps([.zoom])
                recorder.recordingApp = CallDescription(appName: content.callApp, family: .zoom, service: nil)
                recorder.liveTranslation.installSnapshotRecording(pair: sample.pair, targets: sample.targets)
            },
            translationStatusScene("translation-needs-download", .needsDownload),
            translationStatusScene("translation-download-failed", .needsDownload, failed: true),
            translationStatusScene("translation-downloading", .downloading),
            translationStatusScene("translation-paused", .paused),
            panelScene("translation-idle") { recorder, fixture in
                // The next meeting is in the sample's spoken language, so the row shows the language it will be translated into.
                let sample = fixture.captionSample
                recorder.preferences.transcriptionLanguage = SnapshotMode.catalog?.language(matching: sample.pair.source.minimalIdentifier)?.id
                recorder.liveTranslation.installSnapshotEnabledIdle()
                recorder.liveTranslation.installSnapshotTargets(sample.targets, source: sample.pair.source)
            },
        ]
    }

    /// The menu-bar panel while recording with Live Translation in a state that also shows in the captions panel.
    private static func translationStatusScene(_ name: String, _ status: CaptionStatus, failed: Bool = false) -> SnapshotScene {
        panelScene(name) { recorder, fixture in
            let content = fixture.content
            recorder.phase = .recording
            recorder.startedAt = AppClock.now.addingTimeInterval(-754)
            recorder.elapsedSeconds = 754
            recorder.levels = [.me: 0.35, .others: 0.7]
            let sample = fixture.captionSample
            recorder.recordingLanguage = SnapshotMode.catalog?.language(matching: sample.pair.source.minimalIdentifier)
            recorder.recordingSource = .apps([.zoom])
            recorder.recordingApp = CallDescription(appName: content.callApp, family: .zoom, service: nil)
            recorder.liveTranslation.installSnapshotRecording(pair: sample.pair, targets: sample.targets)
            recorder.liveTranslation.installSnapshotStatus(status, failed: failed)
        }
    }

    // MARK: Settings

    static func settingsScene(_ name: String, _ pane: SettingsModel.Pane, size: CGSize = settingsSize,
                                      hotKeys: [String: SnapshotHotKeyState] = [:], showsLinksLine: Bool? = nil,
                                      prepare: @escaping @MainActor (RecorderModel, SnapshotFixture) async -> Void = { _, _ in })
        -> SnapshotScene {
        SnapshotScene(name: "settings-\(name)", size: size) { fixture in
            let recorder = await fixture.makeRecorder()
            // Old copies are staged by the scenes that show them, never left for the next one.
            if pane == .status || pane == .privacy { fixture.world.clearLeftovers() }
            if pane == .status {
                fixture.settings.resetSnapshotStatus()
                // The normal Status screen is the same in every language: the speech model is one that is installed (the sample catalog's
                // English, Spanish and Japanese), not whatever this Mac has. "status-speech-model-missing" shows the other state.
                let own = SnapshotMode.catalog?.language(matching: fixture.world.locale.identifier(.bcp47))
                let installed = own.map { $0.isInstalled } ?? false ? own : SnapshotMode.catalog?.language(matching: "en-US")
                fixture.preferences.transcriptionLanguage = installed?.id
            }
            // With meetings open the model service exists; Settings → Models reads it for "Write Missing Minutes".
            if pane == .models {
                recorder.llm = LLMService(store: fixture.world.store)
                // The same Mac for every Models scene, whatever the render machine has; the small-Mac scenes override it.
                fixture.settings.models.physicalMemory = 16 * ModelRecommendation.gibibyte
            }
            await prepare(recorder, fixture)
            let settings = fixture.settings
            settings.pane = pane
            let view = SettingsWindow(recorder: recorder, preferences: fixture.preferences, model: settings)
                .environment(\.copyProtection, false)
                .environment(\.snapshotHotKeyStates, hotKeys)
                .environment(\.showsLinksLine, showsLinksLine ?? LinksRelease.shipsOnAnyBackend)
            // Status runs its checks when it appears: wait for the list.
            let ready: @MainActor () -> Bool = { pane != .status || (!settings.statusItems.isEmpty && !settings.checking) }
            return .init(view: AnyView(view), title: pane.title, ready: ready)
        }
    }

    static var settings: [SnapshotScene] {
        [
            settingsScene("general", .general),
            settingsScene("recording", .recording),
            settingsScene("translation", .translation, size: CGSize(width: 1020, height: 700)) { recorder, fixture in
                fixture.preferences.translationRefinementEnabled = true
                fixture.preferences.translationModel = ""
                recorder.liveTranslation.installSnapshotTargets(fixture.captionSample.targets, source: fixture.captionSample.pair.source)
            },
            settingsScene("models", .models, size: CGSize(width: 1020, height: 760)) { recorder, fixture in
                fixture.settings.models.installSnapshotState(recorder, discovered: SampleWorld.discoveredServers())
            },
            settingsScene("models-apple", .models, size: CGSize(width: 1020, height: 760)) { recorder, fixture in
                fixture.settings.models.installSnapshotState(recorder, discovered: [], saved: ModelProviderSettings(chat: .onDevice, embeddings: .none))
                fixture.settings.models.physicalMemory = 16 * ModelRecommendation.gibibyte
            },
            // A Mac with too little memory for a model server on it: the card offers the options instead.
            settingsScene("models-apple-small-mac", .models, size: CGSize(width: 1020, height: 760)) { recorder, fixture in
                fixture.settings.models.installSnapshotState(recorder, discovered: [], saved: ModelProviderSettings(chat: .onDevice, embeddings: .none))
                fixture.settings.models.physicalMemory = 8 * ModelRecommendation.gibibyte
            },
            settingsScene("privacy", .privacy, size: CGSize(width: 1020, height: 700)),
            // While recording: one Stop Recording control for the whole data card.
            settingsScene("privacy-recording", .privacy, size: CGSize(width: 1020, height: 1180)) { recorder, _ in
                recorder.phase = .recording
            },
            settingsScene("context", .context, size: CGSize(width: 1020, height: SettingsWindow.defaultHeight)) { recorder, fixture in
                await recorder.context?.reload()
                recorder.context?.show(entityID: fixture.world.peopleIDs[1])
            },
            settingsScene("status", .status, size: CGSize(width: 1020, height: 640)),
            // The language of the next meeting has no speech model on this Mac: the row is red with its two ways out.
            // It is the interface language's own model that is missing (as in setup), whatever the sample catalog installs.
            settingsScene("status-speech-model-missing", .status, size: CGSize(width: 1020, height: 640)) { recorder, fixture in
                let tag = fixture.world.locale.identifier(.bcp47)
                if let own = SnapshotMode.catalog?.language(matching: tag), own.isInstalled {
                    SnapshotMode.catalog = SampleWorld.speechCatalog(notInstalled: [own.id], rendering: fixture.world.locale.identifier(.bcp47))
                    recorder.speechCatalog = SnapshotMode.catalog
                }
                fixture.preferences.transcriptionLanguage = SnapshotMode.catalog?.language(matching: tag)?.id
            },
            settingsScene("about", .about, size: CGSize(width: 1020, height: 640)),
        ]
    }

    // MARK: Onboarding

    static let qwen9ID = "qwen/qwen3.5-9b"
    static let guideSummary = ModelGuideModel.Summary(serverName: "LM Studio", mainModel: "Qwen3.5-9B", fastModel: nil, embeddingsOff: false,
                                                      keywordSearch: true, warning: nil)

    /// `guide`: the model guide sheet over the window, at the size it really has there.
    /// The speech model download a last-page scene shows.
    enum SpeechDownloadSample { case downloading(Double), failed }

    static func onboardingScene(_ name: String, _ step: OnboardingStep, guide: Bool = false, hotKeyTaken: Bool = false,
                                        speechModelMissing: Bool = false, speechDownload: SpeechDownloadSample? = nil,
                                        configure: @escaping @MainActor (OnboardingModel) -> Void = { _ in }) -> SnapshotScene {
        // The guide scene is fitted to its content: the window is as tall as the sheet reports, like the real one.
        SnapshotScene(name: "onboarding-\(name)", size: guide ? CGSize(width: onboardingSize.width, height: OnboardingMetrics.guideWindowHeight) : onboardingSize,
                      fitHeight: guide || step == .done) { fixture in
            let recorder = await fixture.makeRecorder()
            recorder.hotKeyAvailable = !hotKeyTaken
            let model = OnboardingModel()
            model.flow = OnboardingFlow(step: step)
            model.models.physicalMemory = 16 * ModelRecommendation.gibibyte
            // The same on every Mac: Apple Intelligence ready, minutes on the Apple model.
            model.appleAvailabilityOverride = .available
            model.chatProviderOverride = .onDevice
            // The last page reports the microphone: fixed, so it doesn't depend on this Mac (a scene may change it).
            if step == .done { model.installSnapshotPermissions(microphone: .granted, notifications: .granted) }
            // The first run has asked for nothing yet (a scene may change it).
            if step == .permissions { model.installSnapshotPermissions(microphone: .notDetermined, notifications: .notDetermined) }
            let own = SnapshotMode.catalog?.language(matching: fixture.world.locale.identifier(.bcp47))
            // The Language and Speech Model pages are only on the way for a language whose model is missing (an installed one skips the
            // speech page and drops the flow to 5 steps), so both always show that state: "Step 2 of 6", "Not downloaded", in every language.
            // Permissions and Minutes are on the same run, so the whole set reads one flow: 2, 3, 4 (Speech Model) and 5 of 6.
            if speechModelMissing || speechDownload != nil || step == .language || step == .speechModel || step == .permissions || step == .models {
                // The interface language's own speech model is the one that is missing, whatever the sample catalog installs (English, Spanish and
                // Japanese): the scene shows the language the person chose on the page before, and every language gets the same number of steps.
                if let own, own.isInstalled {
                    SnapshotMode.catalog = SampleWorld.speechCatalog(notInstalled: [own.id], rendering: fixture.world.locale.identifier(.bcp47))
                    recorder.speechCatalog = SnapshotMode.catalog
                }
                let missing = SnapshotMode.catalog?.language(matching: fixture.world.locale.identifier(.bcp47))
                fixture.preferences.transcriptionLanguage = missing?.id
                switch speechDownload {
                case .downloading(let progress)?: model.speech.installSnapshotState(downloading: missing, progress: progress)
                case .failed?: model.speech.installSnapshotState(downloading: nil, progress: 0, failed: missing)
                case nil: break
                }
            } else if step == .done {
                // The last page of the happy path has no speech problem to fix, in every language.
                // The happy path is the same in every language: a speech model that is installed (the sample catalog's
                // English, Spanish and Japanese), not what this Mac has.
                let installed = own.map { $0.isInstalled } ?? false ? own : SnapshotMode.catalog?.language(matching: "en-US")
                fixture.preferences.transcriptionLanguage = installed?.id
            }
            configure(model)
            let window = OnboardingView(recorder: recorder, preferences: fixture.preferences, settings: fixture.settings, snapshotModel: model,
                                        guideDrawnOver: guide)
            guard guide else {
                return .init(view: AnyView(window), title: String(localized: "Set Up Vauta", comment: "Window title of the first-run setup"))
            }
            // A sheet hangs from the title bar, dimming the window under it.
            let sheet = ModelGuideSheet(recorder: recorder, settings: model.models,
                                        // A fixed amount of free space and no installed app, so the render doesn't depend on this Mac.
                                        guide: ModelGuideModel(physicalMemory: model.models.physicalMemory, polls: false,
                                                               locate: { _ in nil }, freeSpace: { 180 * 1_000_000_000 }),
                                        close: {}, maxHeight: OnboardingMetrics.guideSheetHeight,
                                        onHeightChange: { model.guideSheetHeight = $0 })
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 12, y: 4)
                .fixedSize()
            let stack = ZStack(alignment: .top) {
                window
                Color.black.opacity(0.25)
                sheet
            }
            return .init(view: AnyView(stack), title: String(localized: "Set Up Vauta", comment: "Window title of the first-run setup"))
        }
    }

    static var onboarding: [SnapshotScene] {
        [
            onboardingScene("welcome", .welcome), onboardingScene("language", .language), onboardingScene("permissions", .permissions),
            onboardingScene("speech-model", .speechModel), onboardingScene("models", .models),
            onboardingScene("models-small-mac", .models) { $0.models.physicalMemory = 8 * ModelRecommendation.gibibyte },
            // Apple Intelligence is still downloading: the reason, the hint and the button to System Settings.
            onboardingScene("models-apple-downloading", .models) { $0.appleAvailabilityOverride = .modelNotReady },
            onboardingScene("models-no-apple", .models) { $0.appleAvailabilityOverride = .deviceNotEligible },
            onboardingScene("models-no-apple-off", .models) { $0.appleAvailabilityOverride = .appleIntelligenceNotEnabled },
            onboardingScene("models-small-mac-no-apple", .models) {
                $0.models.physicalMemory = 8 * ModelRecommendation.gibibyte
                $0.appleAvailabilityOverride = .deviceNotEligible
            },
            onboardingScene("models-servers-found", .models) {
                $0.installSnapshotServers([server(.lmStudio, model: qwen9ID, context: 32768), server(.ollama, model: nil, context: nil)], message: nil)
            },
            onboardingScene("models-no-server-found", .models) { $0.installSnapshotServers([], message: nil) },
            onboardingScene("models-server-selected", .models) {
                $0.installSnapshotServers([server(.lmStudio, model: qwen9ID, context: 32768)], message: nil, selected: "LM Studio", summary: String(localized: "\("Qwen3.5-9B") in \("LM Studio")",
                                                                                                                                   comment: "Setup: the model and the app that now write minutes; arguments are a model name and an app name"))
            },
            onboardingScene("guide-open", .models, guide: true),
            onboardingScene("done", .done),
            onboardingScene("done-server", .done) {
                $0.chatProviderOverride = .server
                $0.guideFinished(guideSummary)
            },
            // A Mac with little memory: the recommendation points to a server, not to a model server on this Mac.
            onboardingScene("done-small-mac", .done) { $0.models.physicalMemory = 8 * ModelRecommendation.gibibyte },
            onboardingScene("done-no-model", .done) { $0.appleAvailabilityOverride = .deviceNotEligible },
            // Another app holds the recording shortcut: the page says how to record instead.
            onboardingScene("done-hotkey-taken", .done, hotKeyTaken: true),
            // The microphone was not allowed: the page says Vauta cannot record yet and offers System Settings.
            onboardingScene("done-mic-denied", .done) { $0.installSnapshotPermissions(microphone: .denied, notifications: .granted) },
            // The speech model of the meeting language is missing (the download failed or was skipped).
            onboardingScene("done-speech-missing", .done, speechModelMissing: true),
            // "Download" was pressed (or "Download and Continue" started it): progress, and Vauta is not "all set" yet.
            onboardingScene("done-speech-downloading", .done, speechDownload: .downloading(0.42)),
            // The download failed (the disk is full): the warning says why and offers another try and the pane that frees space.
            onboardingScene("done-speech-failed", .done, speechDownload: .failed),
            onboardingScene("done-problems", .done, hotKeyTaken: true, speechModelMissing: true) {
                $0.installSnapshotPermissions(microphone: .denied, notifications: .granted)
            },
        ]
    }

    // MARK: Meetings

    static func meetingsScene(_ name: String, size: CGSize = meetingsSize, keepsTranslatedTranscript: Bool = false, prepare: @escaping @MainActor (MeetingsModel, SnapshotFixture) async -> Void,
                              configureRecorder: @escaping @MainActor (RecorderModel, SnapshotFixture) -> Void = { _, _ in },
                              after: (@MainActor (MeetingsModel, SnapshotFixture) async -> Void)? = nil)
        -> SnapshotScene {
        SnapshotScene(name: "meetings-\(name)", size: size) { fixture in
            let recorder = await fixture.makeRecorder()
            configureRecorder(recorder, fixture)
            guard let history = recorder.history else { return .init(view: AnyView(EmptyView())) }
            history.llm = nil
            // An earlier scene may have swapped the transcript for a translated one.
            if !keepsTranslatedTranscript { try? await fixture.world.restoreTranscript() }
            await history.reload()
            await prepare(history, fixture)
            // A meeting with notes opens on its Notes tab; these scenes are about the other tabs unless they say so.
            if history.tab == .notes { history.tab = .summary }
            let view = MeetingsWindow(model: history, recorder: recorder, preferences: fixture.preferences, settings: fixture.settings)
            var prepared = SnapshotScene.Prepared(view: AnyView(view), title: String(localized: "Meetings", comment: "Window title"))
            if let after { prepared.after = { await after(history, fixture) } }
            return prepared
        }
    }

    static var meetings: [SnapshotScene] {
        [
            meetingsScene("summary") { history, fixture in
                history.selectedID = fixture.world.featuredMeetingID
                await history.loadDetail()
            },
            meetingsScene("transcript-translated", keepsTranslatedTranscript: true) { history, fixture in
                // The others speak another language; each line has its stored translation into the interface language.
                try? await fixture.world.useForeignSourceTranscript(translatedInto: fixture.language)
                history.selectedID = fixture.world.featuredMeetingID
                await history.loadDetail()
                history.tab = .transcript
            },
            meetingsScene("tasks-tab") { history, fixture in
                history.selectedID = fixture.world.featuredMeetingID
                await history.loadDetail()
                history.tab = .tasks
            },
            meetingsScene("transcript") { history, fixture in
                // The plain transcript: no stored translations (an earlier scene may have added them).
                try? await fixture.world.restoreTranscript()
                history.selectedID = fixture.world.featuredMeetingID
                await history.loadDetail()
                history.tab = .transcript
            },
            // What the model proposed that the passage it cites does not back, in the Minutes tab: an unconfirmed decision with
            // its word and glyph (the tasks and their owners are in the Tasks tab scenes below).
            meetingsScene("summary-unconfirmed") { history, fixture in
                try? await fixture.world.seedVerificationMarks()
                await history.reload()
                history.selectedID = fixture.world.featuredMeetingID
                await history.loadDetail()
            },
            // The Tasks tab with its marks, no task selected (so the whole table shows at the usual window size).
            meetingsAfterScene("tasks-unconfirmed", prepare: { history, fixture in
                try? await fixture.world.seedVerificationMarks()
                await history.reload()
                history.selectedID = fixture.world.featuredMeetingID
                await history.loadDetail()
            }) { history, _ in
                history.tab = .tasks
            },
            // The same with the first task selected: its editor says in words what is not confirmed. Built like
            // "task-selected" (the selection is set once the view exists). The window is tall because, with an editor
            // open, the Meetings window content sits higher than the window in some languages (see task-selected in
            // German), which would hide the first row.
            meetingsAfterScene("task-unconfirmed-selected", size: CGSize(width: 1040, height: 1060), prepare: { history, fixture in
                try? await fixture.world.seedVerificationMarks()
                await history.reload()
                history.selectedID = fixture.world.featuredMeetingID
                await history.loadDetail()
            }) { history, _ in
                history.tab = .tasks
                history.taskSelection = history.sortedTasks.first?.id
                try? await Task.sleep(for: .milliseconds(300))
            },
            // A task owned by a speaker nobody has named, the owner not confirmed: the editor's note, and the cross-meeting list.
            meetingsAfterScene("task-speaker-owner-selected", size: CGSize(width: 1040, height: 1060), prepare: { history, fixture in
                try? await fixture.world.seedSpeakerOwner()
                await history.reload()
                history.selectedID = fixture.world.featuredMeetingID
                await history.loadDetail()
            }) { history, _ in
                history.tab = .tasks
                history.taskSelection = history.sortedTasks.first?.id
                try? await Task.sleep(for: .milliseconds(300))
            },
            meetingsScene("open-tasks-speaker-owner") { history, fixture in
                try? await fixture.world.seedSpeakerOwner()
                history.mode = .tasks
                await history.reloadMode()
            },
            meetingsScene("open-tasks-unconfirmed") { history, fixture in
                try? await fixture.world.seedVerificationMarks()
                history.mode = .tasks
                await history.reloadMode()
            },
            // Open tasks of one person: the Owner column is hidden, so the mark moves next to the task text.
            meetingsScene("open-tasks-unconfirmed-by-owner") { history, fixture in
                try? await fixture.world.seedVerificationMarks()
                history.mode = .tasks
                await history.reloadMode()
                history.ownerFilter = history.openTasks.first { $0.ownerID != nil && $0.ownerUncertain }?.ownerID
            },
            // The same owner's card: the open tasks list carries the mark too.
            meetingsScene("people-unconfirmed-owner") { history, fixture in
                try? await fixture.world.seedVerificationMarks()
                history.mode = .tasks
                await history.reloadMode()
                history.mode = .people
                history.selectedEntityID = history.openTasks.first { $0.ownerID != nil && $0.ownerUncertain }?.ownerID
                await history.loadEntity()
            },
            // A long owner name: the name gives way, the mark stays.
            meetingsScene("open-tasks-long-owner") { history, fixture in
                try? await fixture.world.seedLongOwnerName()
                history.mode = .tasks
                await history.reloadMode()
            },
            meetingsScene("ask") { history, fixture in
                history.mode = .ask
                await prepareAsk(history.ask, fixture)
            },
            meetingsScene("open-tasks") { history, _ in
                history.mode = .tasks
                await history.reloadMode()
            },
            meetingsScene("people") { history, fixture in
                history.mode = .people
                history.selectedEntityID = fixture.world.peopleIDs[1]
                await history.loadEntity()
            },
        ]
    }

    /// An answer with verified citations, as the model would return it.
    static func prepareAsk(_ ask: AskModel, _ fixture: SnapshotFixture) async {
        let content = fixture.content
        let world = fixture.world
        let store = world.store
        ask.question = content.askQuestion
        ask.answeredQuestion = content.askQuestion
        let ids = content.askClaims.map { world.featuredSegmentIDs[$0.1] }
        let cited = (try? await store.segmentsByIDs(ids)) ?? []
        for segment in cited {
            ask.segments[segment.id] = segment
            ask.segmentMeeting[segment.id] = world.featuredMeetingID
        }
        ask.passages = (try? await store.retrieve(content.searchQuery, queryVector: nil, within: nil)) ?? []
        for passage in ask.passages {
            for segment in passage.segments {
                ask.segments[segment.id] = segment
                ask.segmentMeeting[segment.id] = passage.meeting.id
            }
        }
        ask.answer = VerifiedAnswer(
            answer: content.askAnswer,
            claims: content.askClaims.enumerated().map { i, claim in
                .init(id: "claim-\(i)", text: claim.0, citations: [world.featuredSegmentIDs[claim.1]], verified: true)
            })
    }

    // MARK: Sheets

    private static func exportSheet(_ name: String, prepare: @escaping @MainActor (SnapshotFixture) async -> Void) -> SnapshotScene {
        SnapshotScene(name: name, size: CGSize(width: 440, height: 330), fitHeight: true, isSheet: true) { fixture in
            let recorder = await fixture.makeRecorder()
            guard let history = recorder.history else { return .init(view: AnyView(EmptyView())) }
            try? await fixture.world.restoreTranscript()
            try? await fixture.world.resetSpeakerSamples()
            fixture.appDefaults.removeObject(forKey: "exportSpeakerLabelsWithSpeakers")
            await prepare(fixture)
            await history.reload()
            history.selectedID = fixture.world.featuredMeetingID
            await history.loadDetail()
            let view = ExportSheet(model: history).background(Color(nsColor: .windowBackgroundColor))
            return .init(view: AnyView(view))
        }
    }

    static var sheets: [SnapshotScene] {
        [
            exportSheet("sheet-export") { $0.appDefaults.set(false, forKey: "exportIncludesTranslation") },
            // A meeting with speakers starts on their names, even for somebody who chose "Me and Others" before.
            exportSheet("sheet-export-speakers") { fixture in
                fixture.appDefaults.set(false, forKey: "exportIncludesTranslation")
                fixture.appDefaults.set("channels", forKey: "exportSpeakerLabels")
                try? await fixture.world.seedFeaturedSpeakers()
            },
            // The same person, a meeting without speakers: their stored choice stands.
            exportSheet("sheet-export-channels") { fixture in
                fixture.appDefaults.set(false, forKey: "exportIncludesTranslation")
                fixture.appDefaults.set("channels", forKey: "exportSpeakerLabels")
            },
            // A meeting with stored translations, the translation included.
            exportSheet("sheet-export-translation") { fixture in
                fixture.appDefaults.set(true, forKey: "exportIncludesTranslation")
                try? await fixture.world.useForeignSourceTranscript(translatedInto: fixture.language)
            },
        ]
    }

    // MARK: Local model guide


    /// A server as the guide's scan would report it, with one chat model.
    static func server(_ kind: ServerKind, model: String?, context: Int?) -> DiscoveredServer {
        let models = model.map { [DiscoveredModel(id: $0, kind: .chat, contextLength: context, loaded: context != nil)] } ?? []
        return DiscoveredServer(kind: kind, baseURL: URL(string: "http://127.0.0.1:\(kind.defaultPort)/v1/")!, version: nil, models: models)
    }

    static func guideScene(_ name: String, memoryGB: UInt64 = 16, app: LocalModelApp = .lmStudio, installed: Bool = true,
                                   freeGB: Int64 = 180, servers: [DiscoveredServer] = [], includeFast: Bool = true,
                                   phase: ModelGuideModel.Phase = .guide, appleAvailable: Bool = true,
                                   offersNetworkServer: Bool = true, searching: Bool = false, copied: Bool = false,
                           collapsed: Bool = false) -> SnapshotScene {
        // The size the sheet has: steps need room, the other pages are short.
        let recommendation = ModelRecommendation(physicalMemory: memoryGB * ModelRecommendation.gibibyte)
        let isDone = { if case .done = phase { true } else { false } }()
        let ideal = ModelGuideSheet.idealHeight(showsSteps: recommendation.hasRecommendation && !isDone && !collapsed)
        // The finished page and the low-memory page are as tall as their text: the window is fitted to it.
        return SnapshotScene(name: "guide-\(name)", size: CGSize(width: recommendation.hasRecommendation || isDone ? ModelGuideSheet.idealWidth : ModelGuideSheet.lowMemoryWidth, height: ideal ?? 300), fitHeight: true, isSheet: true) { fixture in
            let recorder = await fixture.makeRecorder()
            let guide = ModelGuideModel(physicalMemory: memoryGB * ModelRecommendation.gibibyte, polls: false,
                                        locate: { _ in installed ? URL(fileURLWithPath: "/Applications/\(app.bundleFileName)") : nil },
                                        freeSpace: { freeGB * 1_000_000_000 })
            guide.app = app
            guide.includeFastModel = includeFast
            guide.start(existing: nil)
            guide.status = SetupEvaluation.evaluate(servers, configuration: SetupConfiguration(
                app: app, recommendation: guide.recommendation, includeFastModel: includeFast))
            if searching { guide.status = .searching }
            guide.phase = phase
            CommandBlock.snapshotCopied = copied
            let view = ModelGuideSheet(recorder: recorder, settings: fixture.settings.models, guide: guide, close: {},
                                       useNetworkServer: {},
                                       // First-run setup (no `offersNetworkServer`) is where "Keep Apple Intelligence" records the choice.
                                       keepApple: offersNetworkServer ? nil : {}, appleAvailableOverride: appleAvailable)
                .background(Color(nsColor: .windowBackgroundColor))
            return .init(view: AnyView(view))
        }
    }

    static var guide: [SnapshotScene] {
        let qwen9 = qwen9ID, qwen27 = "qwen/qwen3.8-27b"
        let done = guideSummary
        return [
            guideScene("no-app", installed: false),
            guideScene("ollama-no-app", app: .ollama, installed: false),
            guideScene("searching", searching: true),
            guideScene("copied", servers: [server(.lmStudio, model: "google/gemma-3-4b", context: 32768)], copied: true),
            guideScene("ollama-not-running", app: .ollama),
            // Ollama is open (the server runs) but the model isn't downloaded: the download is the step to do.
            guideScene("ollama-no-model", app: .ollama, servers: [server(.ollama, model: "llama3.2:3b", context: 4096)]),
            guideScene("no-model", servers: [server(.lmStudio, model: "google/gemma-3-4b", context: 32768)]),
            guideScene("context-small", servers: [server(.lmStudio, model: qwen9, context: 4096)]),
            guideScene("ollama-context-large", memoryGB: 64, app: .ollama, servers: [server(.ollama, model: "qwen3.8:27b", context: 4096)]),
            guideScene("found", servers: [server(.lmStudio, model: qwen9, context: 32768)], collapsed: true),
            guideScene("found-large", memoryGB: 64, servers: [
                DiscoveredServer(kind: .lmStudio, baseURL: URL(string: "http://127.0.0.1:1234/v1/")!, version: nil, models: [
                    DiscoveredModel(id: qwen27, kind: .chat, contextLength: 32768, loaded: true),
                    DiscoveredModel(id: qwen9, kind: .chat, contextLength: 32768, loaded: true),
                ])], collapsed: true),
            guideScene("ollama-found", app: .ollama, servers: [server(.ollama, model: "qwen3.5:9b", context: nil)], collapsed: true),
            guideScene("failed", servers: [server(.lmStudio, model: qwen9, context: 32768)],
                       phase: .failed(String(localized: "Couldn’t save the server settings.", comment: "Settings → Models apply error")), collapsed: true),
            guideScene("applying", servers: [server(.lmStudio, model: qwen9, context: 32768)], phase: .applying, collapsed: true),
            guideScene("done", servers: [server(.lmStudio, model: qwen9, context: 32768)], phase: .done(done)),
            guideScene("done-large", memoryGB: 64, servers: [server(.lmStudio, model: qwen27, context: 32768)],
                       phase: .done(.init(serverName: "LM Studio", mainModel: "Qwen3.8-27B", fastModel: "Qwen3.5-9B", embeddingsOff: true,
                                          keywordSearch: true, warning: nil))),
            guideScene("done-meaning", servers: [server(.lmStudio, model: qwen9, context: 32768)],
                       phase: .done(.init(serverName: "LM Studio", mainModel: "Qwen3.5-9B", fastModel: nil, embeddingsOff: false,
                                          keywordSearch: false, warning: nil))),
            guideScene("low-disk", memoryGB: 32, freeGB: 14),
            guideScene("low-memory", memoryGB: 8),
            guideScene("low-memory-no-apple", memoryGB: 8, appleAvailable: false),
        ]
    }
}
#endif
