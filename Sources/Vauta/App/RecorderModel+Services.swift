// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit

/// The model server, job events and notifications.
extension RecorderModel {
    func startLLM(_ store: MeetingStore) {
        let service = LLMService(store: store)
        llm = service
        startDocuments(store, service)
        startSearchModel(service)
        startIntegratedModel(service)
        Task {
            // A question in another language than the transcripts is translated on this Mac (installed languages only) when the
            // meetings are searched by keywords.
            await service.setQueryTranslation(AppleTranslationBackend())
            await service.setStatusHandler { [weak recorder = self] status in
                Task { @MainActor in recorder?.statusChanged(status) }
            }
            await service.setJobEventHandler { [weak recorder = self] event in
                Task { @MainActor in recorder?.jobFinished(event) }
            }
            // A link pass wrote suggestions: the open meeting shows them without being selected again.
            await service.setLinksChangedHandler { [weak recorder = self] meetingID in
                Task { @MainActor in await recorder?.history?.linksChanged(meetingID) }
            }
            // Speakers of a recording that crashed are finalized before anything else reads its transcript.
            await SpeakerFinalizer.recoverInterrupted(in: store, enabled: preferences.separateSpeakers,
                                                       recognizeVoices: preferences.recognizesVoices)
            // Then the echoes of the meetings recorded before they were marked, and of one a crash left open: once, before the
            // minutes, answers or links read them.
            if ((try? await store.markPendingEchoes()) ?? 0) > 0 { await history?.reloadIfShowing() }
            await maintainVoices()
            // The search model's files are looked at (no network) before the service reads its providers.
            await SearchModelController.shared.start()
            await LanguageModelController.shared.start()
            await service.start()
            await recoverInterruptedMeeting(store, service)
            // Safety net at launch: minutes of the meetings about to lose their text.
            for id in (try? await store.meetingsNeedingDistill()) ?? [] { await service.regenerateMinutes(id) }
        }
    }

    /// The optional search model: the Mac's state for its pause rules, what happens when it is installed or deleted, and the
    /// observable status Settings reads. Nothing here starts a download.
    private func startSearchModel(_ service: LLMService) {
        let box = searchEnvironment
        SearchModelAccess.shared.setEnvironment { box.snapshot() }
        searchModel.start()
        Task { [weak self] in
            await service.setEnvironmentProvider { box.snapshot() }
            // A person who never chose how search works and has a model server keeps the server when the model is installed.
            await SearchModelController.shared.setServerConfigProvider { [weak self] in
                await MainActor.run { self.map { $0.serverConfig != nil || $0.serverConfigUnavailable } ?? false }
            }
            await SearchModelController.shared.setHooks(SearchModelHooks(
                installed: { [weak self] in
                    await service.configurationChanged()
                    await service.refreshSearchCoverage()
                    await MainActor.run { self?.documents?.embeddingChoiceChanged() }
                },
                removing: { await service.searchModelRemoving() },
                removed: { await service.searchModelRemoved() }))
        }
        // Power, Low Power Mode and heat release or hold the embedding jobs.
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            searchObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { await service.environmentChanged() }
            })
        }
        // The charger being plugged in or out posts neither of those.
        powerSourceWatcher = PowerSourceWatcher { Task { await service.environmentChanged() } }
    }

    /// The optional integrated language model: what happens when it is chosen, installed or deleted, and the observable status Settings
    /// reads. Nothing here starts a download.
    private func startIntegratedModel(_ service: LLMService) {
        integratedModel.start()
        integratedModel.onLiveTasksChanged = { [weak self] in self?.liveAnswersBackendMayHaveChanged() }
        Task { [weak self] in
            await LanguageModelController.shared.setHooks(LanguageModelHooks(
                chosen: { await service.configurationChanged(); await MainActor.run { self?.integratedModel.chatChoiceChanged() } },
                installed: { await service.configurationChanged() },
                removed: { await service.configurationChanged() }))
        }
    }

    /// The documents index (its own encrypted image next to the store) and the indexer that keeps it in step with the sources.
    private func startDocuments(_ store: MeetingStore, _ service: LLMService) {
        Task { [weak self] in
            guard let self else { return }
            do {
                // Opening the image decrypts and decompresses it (up to about 150 MB): off the main actor, so launch never waits for it.
                let directory = store.storeDirectory
                let key = await store.documentsKey()
                let index = try await Task.detached(priority: .utility) { try DocumentIndex(directory: directory, key: key) }.value
                let model = DocumentsModel(store: store, index: index) { [weak self] in
                    let (recording, stopped) = await MainActor.run { (self?.phase == .recording || self?.phase == .starting, self?.recordingStoppedAt) }
                    return await DocumentsModel.environment(recording: recording, stoppedAt: stopped)
                }
                documents = model
                model.start(llm: service)
            } catch {
                // The index is derived data: without it Ask still answers from meetings.
                documents = nil
            }
        }
    }

    /// A recording that never reached Stop (crash, forced quit, the quit cap):
    /// the store's recovery closed the meeting at launch, and its minutes are
    /// queued here unless it already has minutes or a minutes job.
    private func recoverInterruptedMeeting(_ store: MeetingStore, _ service: LLMService) async {
        let defaults = UserDefaults.standard
        guard let id = defaults.object(forKey: Self.recordingMeetingKey) as? Int64 else { return }
        defaults.removeObject(forKey: Self.recordingMeetingKey)
        guard (try? await store.meeting(id)) != nil else { return }
        // Chunks that typed questions stored before the app died are a partial set (and `onDemandMeetings` died with it): a meeting
        // with only some of its lines embedded must not count as covered, so they go and the embedding job (or the reconcile) rewrites all.
        await service.discardLivePrefixChunks(id)
        guard (try? await store.cardSource(id)) == nil,
              let jobs = try? await store.jobs(for: id), !jobs.contains(where: { $0.kind == .minutes }) else { return }
        await service.meetingEnded(id, template: preferences.minutesTemplate, speakersEnabled: preferences.separateSpeakers,
                                   recognizeVoices: preferences.recognizesVoices)
    }

    private func statusChanged(_ status: LLMService.Status) {
        let wasReachable = llmStatus.reachable
        llmStatus = status
        searchModel.llmStatusChanged(status)
        notepad.modelConfigured = status.configured
        liveAnswersBackendMayHaveChanged()
        retryServerConfigIfUnavailable()
        // While recording, only live notes use the server: say once that they paused.
        if phase == .recording, status.configured, status.reachable == false, wasReachable != false, !serverDownNotified {
            serverDownNotified = true
            post(.serverUnreachable())
        }
    }

    private func jobFinished(_ event: LLMService.JobEvent) {
        guard event.kind == .minutes, let store else { return }
        Task {
            guard let meeting = try? await store.meeting(event.meetingID) else { return }
            let title = calendar.showTitleInNotifications ? meeting.title : nil
            switch event.outcome {
            case .succeeded:
                post(.minutesReady(meetingID: meeting.id, meetingTitle: title, startedAt: meeting.startedAt))
                notifier.remove(.minutesFailed, meetingID: meeting.id)
                await noteMinutesReady(meeting.id)
            case .failed:
                post(.minutesFailed(meetingID: meeting.id, meetingTitle: title, startedAt: meeting.startedAt))
            case .cancelled:
                break
            }
        }
    }

    /// The Keychain was locked at launch: read the configuration again (the
    /// model service retries on its own; this keeps Settings in step).
    func retryServerConfigIfUnavailable() {
        guard serverConfigUnavailable else { return }
        do {
            serverConfig = try LLMServerConfig.load()
            serverConfigUnavailable = false
        } catch {
            // Still locked: tried again on the next status update.
        }
    }

    /// Settings › Models: saves (or deletes) the server and models in the
    /// Keychain and checks them. Returns a message on failure.
    func setServerConfig(_ config: LLMServerConfig?, embeddingsOnServer: Bool = true) async -> String? {
        do {
            try LLMServerConfig.save(config, embeddingsOnServer: embeddingsOnServer)
        } catch {
            return error.localizedDescription
        }
        serverConfig = config   // what was just saved (save() validates and stores exactly this)
        serverConfigUnavailable = false
        await llm?.configurationChanged()
        if config != nil, let failure = await llm?.check() { return failure }
        return nil
    }

    /// Settings › Models: saves (or deletes) the server key in the Keychain and checks it.
    func setServerKey(_ key: String?) async -> String? {
        let clean = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if clean.isEmpty {
            try? ServerCredentials.saveBearer(nil)
        } else {
            guard LLMClient.isValidToken(clean) else {
                return String(localized: "The key contains characters that aren’t allowed.", comment: "Server key error")
            }
            do {
                try ServerCredentials.saveBearer(clean)
            } catch {
                return String(localized: "The key couldn’t be saved in the Keychain. \(error.localizedDescription)",
                              comment: "Server key error; the argument is the error")
            }
        }
        hasServerKey = !clean.isEmpty
        await llm?.configurationChanged()
        if serverConfig != nil, let failure = await llm?.check() { return failure }
        return nil
    }

    func checkServer() async { _ = await llm?.check() }
    func generatePendingMinutes() async { await llm?.backfill(template: preferences.minutesTemplate) }

    // MARK: Notifications

    /// Posts unless the user turned that kind off in Settings.
    func post(_ notification: AppNotification) {
        guard AppNotification.isAllowed(notification.kind, notifyMinutesReady: preferences.notifyMinutesReady,
                                        notifyProblems: preferences.notifyProblems,
                                        notifyBrief: BriefPreferences(defaults: .standard).notifies) else { return }
        notifier.post(notification)
    }

    /// Onboarding: asks for notification permission (never before a recording).
    func requestNotificationPermission() async {
        await notifier.requestAuthorization()
    }

    func handle(_ action: AppNotification.Action, meetingID: Int64?, occurrence: BriefOccurrence? = nil) {
        switch action {
        case .keepRecording: keepRecording()
        case .stopRecording: stop()
        case .transcribe: acceptSuggestion()
        case .openMeeting:
            Task { await openMeeting(meetingID) }
        case .retryMinutes:
            if let meetingID {
                notifier.remove(.minutesFailed, meetingID: meetingID)
                Task { await llm?.regenerateMinutes(meetingID) }
            }
        case .showModels: showSettings(.models)
        case .showStatus: showSettings(.status)
        case .showSpeakers: showSettings(.speakers)
        case .openSystemSettings:
            if let pane = permissionProblem { NSWorkspace.shared.open(pane.url) }
        case .installModel: installMissingModel()
        case .openBrief: brief.openBrief()
        case .recordAtStart: brief.armRecordAtStart(occurrence: occurrence)
        }
    }

    /// Opens a meeting (or, without one, the list) in the Meetings window,
    /// after Touch ID or the password.
    func openMeeting(_ meetingID: Int64?) async {
        guard await authorizeHistory() else { return }
        if let meetingID {
            history?.open(meeting: meetingID)
        } else if !NSApp.windows.contains(where: { $0.isVisible && $0.identifier?.rawValue.hasPrefix("meetings") == true }) {
            // Only a window that is not open starts on the list: an open one just comes forward, in the mode it is in.
            history?.mode = .meetings
        }
        showWindow("meetings")
    }

    /// Notification permission as shown in Settings › Status.
    func notificationStatus() async -> String {
        switch await notifier.status() {
        case .authorized, .provisional:
            String(localized: "Allowed", comment: "Notification permission status")
        case .denied:
            String(localized: "Off — warnings appear only in the menu-bar panel and icon", comment: "Notification permission status")
        case .notDetermined:
            String(localized: "Not asked yet — asked during setup or when you first record", comment: "Notification permission status")
        default:
            String(localized: "Unknown", comment: "Notification permission status")
        }
    }

    // MARK: Windows

    /// Opens (or brings forward) a window scene by id.
    func showWindow(_ id: String) {
        openWindowAction?(id: id)
        NSApp.activate()
    }

    /// Opens Settings on `pane` (the pane that was last open when nil).
    func showSettings(_ pane: SettingsModel.Pane? = nil) {
        if let pane { settingsModel?.pane = pane }
        showWindow("settings")
    }
}
