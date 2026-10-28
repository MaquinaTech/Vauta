// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import SwiftUI

// The states beyond the main scenes: warnings and banners, errors, empty and
// busy states, long content, forms and sheets. Names stay "<area>-<state>".
// Native alerts and confirmation dialogs are separate windows that cannot be
// drawn offscreen; docs of what they say live in the code (see the inventory).

extension SnapshotScenes {
    // MARK: Menu-bar panel states

    static func recording(_ recorder: RecorderModel, _ fixture: SnapshotFixture) {
        let content = fixture.content
        recorder.phase = .recording
        recorder.startedAt = AppClock.now.addingTimeInterval(-754)
        recorder.elapsedSeconds = 754
        recorder.levels = [.me: 0.35, .others: 0.7]
        recorder.recordingLanguage = SnapshotMode.catalog?.language(matching: fixture.world.locale.identifier(.bcp47))
        recorder.recordingSource = .apps([.zoom])
        recorder.recordingApp = CallDescription(appName: content.callApp, family: .zoom, service: nil)
    }

    static var panelStates: [SnapshotScene] {
        [
            panelScene("saving") { recorder, fixture in
                recording(recorder, fixture)
                recorder.phase = .stopping
            },
            // A backup is being restored: the record button is grey with the state in words, and Quit waits.
            panelScene("restoring") { recorder, _ in
                recorder.isRestoring = true
            },
            panelScene("erasing") { recorder, _ in
                recorder.isErasing = true
            },
            panelScene("failed-microphone") { recorder, _ in
                recorder.phase = .failed(RecorderModel.describe(CaptureError(.microphonePermissionDenied), inPanel: true))
                recorder.permissionProblem = .microphone
            },
            // The store did not open: the title says so, with the cause under it and Try Again.
            panelScene("failed-store") { recorder, _ in
                recorder.history = nil
                // A real failure of the panel: the disk refused the write (the "already running" case quits the app).
                let error = StoreError(.fileSystem, detail: "errno 28: No space left on device")
                (recorder.phase, recorder.storeOpenRecovery) = RecorderModel.storeOpenFailure(error)
                recorder.storeOpenIsDiskFull = SaveFailure.cause(of: error) == .diskFull
            },
            panelScene("warnings") { recorder, _ in
                recorder.lastStopReason = .silence(minutes: 10)
                recorder.lastError = recorder.saveFailure(String(localized: "The note couldn’t be saved.", comment: "Warning while recording"),
                                                          NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError))
            },
            panelScene("recording-warnings") { recorder, fixture in
                recording(recorder, fixture)
                recorder.channelWarnings[.others] = CaptureError(.systemAudioLost).localizedDescription
                // The same story in every part of the still: nothing arrives from the meeting, so its level is empty.
                recorder.levels[.others] = 0
                recorder.recordingSource = .auto
                recorder.silenceWarning = recorder.silenceMessage
            },
            // A meeting app is in a call, but nothing reaches Others: what is wrong and what to check (once per silent stretch).
            panelScene("capture-alert") { recorder, fixture in
                recording(recorder, fixture)
                recorder.levels[.others] = 0
                recorder.callInProgress = true
                recorder.callApp = .zoom
                recorder.currentCall = CallDescription(appName: fixture.content.callApp, family: .zoom, service: nil)
                recorder.captureAlert = recorder.captureAlertMessage
            },
            // The same alert when no app name resolves: the generic title and detail.
            panelScene("capture-alert-generic") { recorder, fixture in
                recording(recorder, fixture)
                recorder.levels[.others] = 0
                recorder.callInProgress = true
                recorder.callApp = nil
                recorder.currentCall = nil
                recorder.recordingApp = nil
                // Auto names no app in the header either, as in the app when no meeting app is known.
                recorder.recordingSource = .auto
                recorder.captureAlert = recorder.captureAlertMessage
            },
            // The tap already reported why Others is silent (the channels banner): the capture alert, which can only
            // guess, stays out of the way, so the panel shows one card for one cause.
            panelScene("capture-alert-explained") { recorder, fixture in
                recording(recorder, fixture)
                recorder.levels[.others] = 0
                recorder.callInProgress = true
                recorder.callApp = .zoom
                recorder.currentCall = CallDescription(appName: fixture.content.callApp, family: .zoom, service: nil)
                recorder.channelWarnings[.others] = CaptureError(.systemAudioLost).localizedDescription
                recorder.captureAlert = recorder.captureAlertMessage
            },
            // The recorded source is Safari but the call runs in Zoom: Vauta is not capturing the call, so the alert stays
            // out and the silence banner (which names the recorded source) is the warning.
            panelScene("capture-wrong-source") { recorder, fixture in
                recording(recorder, fixture)
                recorder.levels[.others] = 0
                recorder.callInProgress = true
                recorder.callApp = .zoom
                recorder.currentCall = CallDescription(appName: fixture.content.callApp, family: .zoom, service: nil)
                recorder.recordingSource = .apps([.webkit])
                recorder.recordingApp = CallDescription(appName: "Safari", family: .webkit, service: nil)
                recorder.silenceWarning = recorder.silenceMessage
            },
            panelScene("nothing-recorded") { recorder, _ in
                recorder.nothingRecorded = true
            },
            panelScene("stop-countdown") { recorder, fixture in
                recording(recorder, fixture)
                // Nothing reaches Vauta from either side, which is why it is about to stop.
                recorder.levels[.me] = 0
                recorder.levels[.others] = 0
                recorder.autoStopRemaining = 90
            },
            panelScene("meeting-app-released-mic") { recorder, fixture in
                recording(recorder, fixture)
                recorder.hangupNotice = true
            },
            panelScene("speech-model-missing") { recorder, fixture in
                fixture.preferences.transcriptionLanguage = foreignSpeechID(fixture)
                recorder.missingModel = Self.missingModel(fixture)
            },
            panelScene("speech-model-downloading") { recorder, fixture in
                fixture.preferences.transcriptionLanguage = foreignSpeechID(fixture)
                let missing = Self.missingModel(fixture)
                recorder.missingModel = missing
                recorder.speechDownloads.installSnapshotState(downloading: missing?.language, progress: 0.42)
            },
            panelScene("no-model") { recorder, _ in
                var status = LLMService.Status()
                status.configured = false
                status.issue = .serverNotConfigured
                recorder.llmStatus = status
            },
            panelScene("server-unreachable") { recorder, _ in
                recorder.llmStatus.reachable = false
                recorder.llmStatus.lastError = LLMError.network(from: URLError(.cannotConnectToHost)).localizedDescription
            },
            panelScene("on-device-model") { recorder, _ in
                recorder.llmStatus.chatProvider = .onDevice
                recorder.llmStatus.embeddingsProvider = .none
            },
            panelScene("model-busy", clock: Date(timeIntervalSince1970: 1_800_000_185)) { recorder, fixture in
                recorder.llmStatus.activity = String(localized: "Writing minutes", comment: "Model server activity in the menu bar panel")
                recorder.llmStatus.activityStarted = Date(timeIntervalSince1970: 1_800_000_000)
                recorder.llmStatus.activityMeeting = fixture.world.featuredMeetingID
                recorder.llmStatus.queued = 2
            },
            // A long meeting: many transcript lines (the notes are not repeated: a duplicate would read as a bug), to check how the panel grows and scrolls.
            // The same meeting on three screens: the visible area of the scrolling cards must end between two rows on all of them.
            panelScene("recording-long", maxHeight: 800, checksCuts: true, notesOnScreen: true) { recorder, fixture in longRecording(recorder, fixture, autoStop: false) },
            panelScene("recording-long-short-screen", maxHeight: 640, checksCuts: true) { recorder, fixture in longRecording(recorder, fixture) },
            panelScene("recording-notes-expanded", maxHeight: 800, notesExpanded: true, checksCuts: true, notesOnScreen: true) { recorder, fixture in longRecording(recorder, fixture, autoStop: false) },
        ]
    }

    /// A long recording: 40 transcript lines, the live notes, a channel warning and the automatic-stop countdown.
    /// `autoStop`: the "stops in 1:30" banner is shown. In some languages its buttons wrap to three rows, which moves the tools to
    /// the top of the scroll and the notes below the fold; the scenes that show where the notes end leave it out.
    private static func longRecording(_ recorder: RecorderModel, _ fixture: SnapshotFixture, autoStop: Bool = true) {
        let content = fixture.content
        recording(recorder, fixture)
        recorder.elapsedSeconds = 5_412
        let base = content.liveSegments
        // The sample lines repeat, but each one is stamped further along, so the last passage sits near the 1:30:12 on the timer.
        recorder.segments = (0..<40).map { i in
            let line = base[i % base.count]
            let offset = Double(i) * 138
            return LiveSegment(id: i, segment: Segment(channel: line.channel, start: line.start + offset, end: line.end + offset,
                                                       text: line.text, isFinal: true))
        }
        // The line being recognized now is stamped just before the elapsed time too.
        recorder.volatileSegments = content.liveVolatileSegment.map {
            [Segment(channel: $0.channel, start: 5_380, end: 5_385, text: $0.text, isFinal: false)]
        } ?? []
        recorder.showTranscript = true
        recorder.livePoints = content.livePoints
        recorder.liveDecisions = content.liveDecisions
        recorder.liveTasks = content.liveTasks
        recorder.channelWarnings[.others] = CaptureError(.systemAudioLost).localizedDescription
        recorder.levels[.others] = 0
        if autoStop { recorder.autoStopRemaining = 90 }
    }

    /// A server on another computer of the local network.
    private static func networkServer(address: String = "https://192.168.1.50:8443/v1") -> DiscoveredServer {
        let models = SampleWorld.discoveredServers().first?.models ?? []
        return DiscoveredServer(kind: .lmStudio, baseURL: URL(string: address)!, version: "0.3.30", models: models)
    }

    /// The calendars macOS provides itself (the holiday calendar and its "Subscribed Calendars" source) carry the system
    /// language; the person's own ("Work", "Personal") keep the names they gave them, in their language.
    private static let calendarNames: [String: (work: String, personal: String, holidays: String, subscribed: String)] = [
        "en": ("Work", "Personal", "Holidays in the United States", "Subscribed Calendars"),
        "es": ("Trabajo", "Personal", "Festivos de España", "Calendarios suscritos"),
        "fr": ("Travail", "Personnel", "Jours fériés en France", "Calendriers auxquels vous êtes abonné"),
        "de": ("Arbeit", "Privat", "Feiertage in Deutschland", "Abonnierte Kalender"),
        "it": ("Lavoro", "Personale", "Festività in Italia", "Calendari sottoscritti"),
        "pt-BR": ("Trabalho", "Pessoal", "Feriados no Brasil", "Calendários assinados"),
        "ja": ("仕事", "個人", "日本の祝日", "照会カレンダー"),
        "ko": ("업무", "개인", "대한민국 공휴일", "구독한 캘린더"),
        "zh-Hans": ("工作", "个人", "中国大陆节假日", "订阅的日历"),
    ]

    static func sampleCalendars(_ fixture: SnapshotFixture) -> [CalendarWatcher.CalendarChoice] {
        let names = calendarNames[fixture.language] ?? calendarNames["en"]!
        let account = SampleNames.forLanguage(fixture.language)
        return [
            .init(id: "work", title: names.work, source: "Exchange · \(account.email)", color: .blue),
            .init(id: "team", title: account.teamCalendar, source: "Google · \(account.email)", color: .purple),
            .init(id: "personal", title: names.personal, source: "iCloud", color: .green),
            .init(id: "holidays", title: names.holidays, source: names.subscribed, color: .orange),
        ]
    }

    /// A speech language other than the one being rendered (that one is installed on the sample Mac): the one a scene shows as missing,
    /// downloading or failed. `index` picks another one.
    static func foreignSpeechID(_ fixture: SnapshotFixture, _ index: Int = 0) -> String {
        let own = fixture.world.locale.language.languageCode?.identifier
        let others = ["fr-FR", "de-DE", "it-IT", "pt-BR", "ko-KR", "zh-CN"].filter { !$0.hasPrefix((own ?? "") + "-") }
        return others[min(index, others.count - 1)]
    }

    private static func missingModel(_ fixture: SnapshotFixture) -> MissingSpeechModel? {
        SnapshotMode.catalog?.language(matching: foreignSpeechID(fixture)).map { MissingSpeechModel(language: $0, engines: [.speech]) }
    }

    // MARK: Settings states

    static var settingsStates: [SnapshotScene] {
        [
            settingsScene("models-local-server", .models, size: CGSize(width: 1020, height: 1150)) { recorder, fixture in
                let models = fixture.settings.models
                models.installSnapshotState(recorder, discovered: SampleWorld.discoveredServers())
                models.provider = .localServer
            },
            settingsScene("models-local-not-found", .models, size: CGSize(width: 1020, height: 1150)) { recorder, fixture in
                let models = fixture.settings.models
                models.installSnapshotState(recorder, discovered: [])
                models.provider = .localServer
            },
            settingsScene("models-local-test-failed", .models, size: CGSize(width: 1020, height: 1150)) { recorder, fixture in
                let models = fixture.settings.models
                models.installSnapshotState(recorder, discovered: Array(SampleWorld.discoveredServers().prefix(1)))
                models.provider = .localServer
                // A saved key that the server rejects: the key field says a key is saved, and the bar says what to check.
                recorder.hasServerKey = true
                models.installSnapshotFeedback(test: ModelsSettingsModel.feedback(for: LLMError.unauthorized),
                                               apply: ModelsSettingsModel.warning(for: LLMError.unauthorized.localizedDescription))
            },
            // The state after a successful test: address filled, the server's models to choose from.
            settingsScene("models-network-server", .models, size: CGSize(width: 1020, height: 1250)) { recorder, fixture in
                let models = fixture.settings.models
                models.installSnapshotState(recorder, discovered: [])
                models.provider = .networkServer
                models.draft.baseURL = "https://192.168.1.50:8443/v1"
                let server = networkServer()
                models.installSnapshotFeedback(test: .init(kind: .success, text: ModelsSettingsModel.summary(server)), tested: server)
            },
            // A saved key (the field says so; the note says how to replace it), and a destination that was just edited.
            settingsScene("models-key-saved", .models, size: CGSize(width: 1020, height: 1150)) { recorder, fixture in
                let models = fixture.settings.models
                models.installSnapshotState(recorder, discovered: SampleWorld.discoveredServers())
                recorder.hasServerKey = true
            },
            settingsScene("models-key-replaced", .models, size: CGSize(width: 1020, height: 1150)) { recorder, fixture in
                let models = fixture.settings.models
                models.installSnapshotState(recorder, discovered: SampleWorld.discoveredServers())
                recorder.hasServerKey = true
                models.draft.baseURL = "http://localhost:11434/v1"
            },
            // After Remove Key: no key is saved any more, and the result says so.
            settingsScene("models-key-removed", .models, size: CGSize(width: 1020, height: 1150)) { recorder, fixture in
                let models = fixture.settings.models
                models.installSnapshotState(recorder, discovered: SampleWorld.discoveredServers())
                recorder.hasServerKey = false
                models.installSnapshotFeedback(key: .init(kind: .success, text: String(localized: "The key was removed from the Keychain.", comment: "Settings → Models result")))
            },
            // Private CA and pins filled in, plus the warning for a host name that isn't pinned.
            settingsScene("models-network-trust", .models, size: CGSize(width: 1020, height: 1350)) { recorder, fixture in
                let models = fixture.settings.models
                models.installSnapshotState(recorder, discovered: [])
                models.provider = .networkServer
                models.draft.baseURL = "https://meetings.example.com:8443/v1"
                models.draft.caPEM = "-----BEGIN CERTIFICATE-----\nMIIBszCCAVmgAwIBAgIUQm9ndXNTYW1wbGVDQUZvclJlbmRlcjAKBggqhkjOPQQD\nAjAXMRUwEwYDVQQDDAxBY3RhIFNhbXBsZSBDQTAeFw0yNjAxMDEwMDAwMDBaFw0z\n-----END CERTIFICATE-----"
                models.draft.pins = "q3SmZkIuTzA1ZGhvZG9sbG9yc2l0YW1ldGNvbnNlY3RldHVy="
                let server = networkServer(address: models.draft.baseURL)
                models.installSnapshotFeedback(test: .init(kind: .success, text: ModelsSettingsModel.summary(server)), tested: server,
                                               pins: .init(kind: .success, text: String(localized: "Pin added.", comment: "Settings → Models; the pin itself is in the field above")))
            },
            settingsScene("models-network-host-warning", .models, size: CGSize(width: 1020, height: 1250)) { recorder, fixture in
                let models = fixture.settings.models
                models.installSnapshotState(recorder, discovered: [])
                models.provider = .networkServer
                models.draft.baseURL = "https://meetings.example.com:8443/v1"
            },
            // The narrowest Settings window (820 pt): long labels beside popups, the Context list and editor.
            settingsScene("models-narrow", .models, size: CGSize(width: 820, height: 1150)) { recorder, fixture in
                let models = fixture.settings.models
                models.installSnapshotState(recorder, discovered: SampleWorld.discoveredServers())
                models.provider = .localServer
            },
            settingsScene("context-narrow", .context, size: CGSize(width: 820, height: SettingsWindow.defaultHeight)) { recorder, fixture in
                await recorder.context?.reload()
                recorder.context?.show(entityID: fixture.world.peopleIDs[1])
            },
            settingsScene("recording-narrow", .recording, size: CGSize(width: 820, height: 1340)),
            settingsScene("calendar", .calendar),
            settingsScene("calendar-needs-access", .calendar) { recorder, _ in
                recorder.calendar.installSnapshotState(enabled: true, access: false, calendars: [], selected: [])
            },
            settingsScene("calendar-denied", .calendar) { recorder, _ in
                recorder.calendar.installSnapshotState(enabled: true, access: false, calendars: [], selected: [], canRequest: false)
            },
            settingsScene("calendar-list", .calendar, size: CGSize(width: 1020, height: 640)) { recorder, fixture in
                recorder.calendar.installSnapshotState(enabled: true, access: true, calendars: sampleCalendars(fixture), selected: ["work", "team"])
            },
            settingsScene("calendar-empty", .calendar) { recorder, _ in
                recorder.calendar.installSnapshotState(enabled: true, access: true, calendars: [], selected: [])
            },
            settingsScene("calendar-off-with-access", .calendar) { recorder, _ in
                recorder.calendar.installSnapshotState(enabled: false, access: true, calendars: [], selected: [])
            },
        ]
    }

    // MARK: Context

    private static func contextScene(_ name: String, size: CGSize = CGSize(width: 1020, height: SettingsWindow.defaultHeight),
                                     prepare: @escaping @MainActor (ContextModel, SnapshotFixture) async -> Void) -> SnapshotScene {
        settingsScene("context-\(name)", .context, size: size) { recorder, fixture in
            guard let context = recorder.context else { return }
            await context.reload()
            await prepare(context, fixture)
        }
    }

    static var context: [SnapshotScene] {
        [
            contextScene("glossary") { context, _ in
                context.section = .glossary
                context.open(context.glossary.first?.id.map { .term($0) })
            },
            contextScene("glossary-new") { context, _ in
                context.section = .glossary
                context.navigate(.create)
            },
            contextScene("series") { context, fixture in
                let title = (try? await fixture.world.store.meetings().first?.displayTitle) ?? ""
                _ = try? await fixture.world.store.saveSeries(MeetingSeries(titlePattern: title, defaultEntities: Array(fixture.world.peopleIDs.dropFirst().prefix(2))))
                await context.reload()
                context.section = .series
                context.open(context.series.first?.id.map { .series($0) })
            },
            contextScene("projects") { context, fixture in
                context.section = .work
                context.show(entityID: fixture.world.projectID)
            },
            contextScene("new-person") { context, _ in
                context.section = .people
                context.navigate(.create)
            },
            contextScene("search-empty") { context, _ in
                context.section = .people
                context.searchText = "zzzz"
            },
        ]
    }

    // MARK: Onboarding states

    static var onboardingStates: [SnapshotScene] {
        [
            onboardingScene("permissions-allowed", .permissions) { $0.installSnapshotPermissions(microphone: .granted, notifications: .granted) },
            onboardingScene("permissions-denied", .permissions) { $0.installSnapshotPermissions(microphone: .denied, notifications: .denied) },
            onboardingScene("permissions-mic-listening", .permissions) {
                $0.installSnapshotPermissions(microphone: .granted, notifications: .granted)
                $0.micTest.installSnapshot(level: 0.15, running: true, heardSound: false)
            },
            onboardingScene("permissions-mic-heard", .permissions) {
                $0.installSnapshotPermissions(microphone: .granted, notifications: .notDetermined)
                $0.micTest.installSnapshot(level: 0.62, running: true, heardSound: true)
            },
            onboardingScene("permissions-mic-finished-heard", .permissions) {
                $0.installSnapshotPermissions(microphone: .granted, notifications: .granted)
                $0.micTest.installSnapshot(level: 0, running: false, heardSound: true, finished: true)
            },
            onboardingScene("permissions-mic-silent", .permissions) {
                $0.installSnapshotPermissions(microphone: .granted, notifications: .granted)
                $0.micTest.installSnapshot(level: 0, running: false, heardSound: false, finished: true)
            },
            onboardingScene("permissions-mic-failed", .permissions) {
                $0.installSnapshotPermissions(microphone: .granted, notifications: .granted)
                $0.micTest.installSnapshot(level: 0, running: false, heardSound: false,
                                           failure: MicLevelTest.noMicrophoneMessage)
            },
        ]
    }

    // MARK: Meetings states

    static var meetingStates: [SnapshotScene] {
        [
            // The window opens on the latest meeting, so the prompt is only seen after the selection is cleared.
            meetingsAfterScene("select-prompt") { history, _ in
                try? await Task.sleep(for: .milliseconds(500))
                history.selectedID = nil
            },
            meetingsScene("suggestions-tab") { history, fixture in
                history.selectedID = fixture.world.featuredMeetingID
                await history.loadDetail()
                history.tab = .suggestions
            } after: { history, fixture in
                // After the window's own load, which would replace them with the (empty) stored list.
                history.suggestions = fixture.world.sampleSuggestions
                history.suggestionCounts = [fixture.world.featuredMeetingID: history.suggestions.count]
            },
            meetingsScene("search") { history, fixture in
                history.query = fixture.content.searchQuery
                try? await Task.sleep(for: .milliseconds(900))
            } after: { history, fixture in
                // A transcript result is open: its row is selected in the list and its meeting shows on the right.
                // Always the featured meeting's first hit (not the first of each language's ranking), so every language shows the same state.
                if history.hits.isEmpty { try? await Task.sleep(for: .milliseconds(900)) }
                if let hit = history.hits.first(where: { $0.meeting.id == fixture.world.featuredMeetingID }) ?? history.hits.first {
                    history.openedHit = "t\(hit.id)"
                }
                try? await Task.sleep(for: .milliseconds(400))
            },
            meetingsScene("ask-empty") { history, _ in
                history.mode = .ask
            },
            meetingsScene("ask-working") { history, fixture in
                history.mode = .ask
                history.ask.question = fixture.content.askQuestion
                history.ask.busy = true
                history.ask.progressTokens = 412
            },
            // No model: the question is answered by local keyword search, with the reason and the way out.
            meetingsScene("ask-no-model") { history, fixture in
                history.mode = .ask
                history.ask.question = fixture.content.askQuestion
                history.ask.ask()
                try? await Task.sleep(for: .milliseconds(800))
            } configureRecorder: { recorder, _ in
                var status = LLMService.Status()
                status.issue = .serverNotConfigured
                recorder.llmStatus = status
            },
            meetingsScene("tasks-person") { history, fixture in
                history.mode = .tasks
                await history.reloadMode()
                history.ownerFilter = fixture.world.peopleIDs[1]
            },
            meetingsScene("minutes-running") { history, fixture in
                history.selectedID = fixture.world.featuredMeetingID
                await history.loadDetail()
            } configureRecorder: { recorder, fixture in
                recorder.llmStatus.activity = String(localized: "Writing minutes", comment: "Model server activity in the menu bar panel")
                recorder.llmStatus.activityStarted = AppClock.now.addingTimeInterval(-95)
                recorder.llmStatus.activityMeeting = fixture.world.featuredMeetingID
                recorder.llmStatus.progressTokens = 1_240
            },
            meetingsScene("no-model") { history, fixture in
                history.selectedID = fixture.world.featuredMeetingID
                await history.loadDetail()
            } configureRecorder: { recorder, _ in
                var status = LLMService.Status()
                status.issue = .serverNotConfigured
                recorder.llmStatus = status
            } after: { history, _ in
                // Minutes written by hand: with minutes from the model the bar says so instead.
                history.cardSource = nil
            },
            meetingsScene("on-device-model") { history, fixture in
                history.selectedID = fixture.world.featuredMeetingID
                await history.loadDetail()
            } configureRecorder: { recorder, _ in
                recorder.llmStatus.chatProvider = .onDevice
                recorder.llmStatus.embeddingsProvider = .none
            },
        ]
    }
}
#endif
