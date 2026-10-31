// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import Observation
import ServiceManagement

/// Transcription languages, global shortcuts and launch at login.
extension RecorderModel {
    // MARK: Languages

    /// Reads the supported and installed languages again (for the menus).
    func refreshLanguages() async {
        #if VAUTA_DIAGNOSTICS
        if let sample = SnapshotMode.catalog {
            speechCatalog = sample
            return
        }
        #endif
        speechCatalog = await SpeechLanguages.catalog()
    }

    /// The language the next recording will use (nil until the catalog is read).
    var nextRecordingLanguage: SpeechLanguage? {
        guard let speechCatalog else { return nil }
        if let id = preferences.transcriptionLanguage { return speechCatalog.language(matching: id) }
        return speechCatalog.defaultLanguage()
    }

    /// The language Live Translation translates into: the running meeting's, else the one the next meeting will get
    /// (nil = none chosen yet and none can be picked automatically). The panel's row and the shortcut both ask this.
    var translationTargetName: String? {
        liveTranslation.targetName(source: nextRecordingLanguage?.locale.language)
    }

    /// The language and engines for a new recording. Throws `ModelMissing`
    /// (after setting `missingModel`) when a model must be downloaded first.
    func languagePlan() async throws -> RecordingLanguagePlan {
        let catalog = await SpeechLanguages.catalog()
        speechCatalog = catalog
        switch RecordingLanguagePlan.make(preferred: preferences.transcriptionLanguage, catalog: catalog,
                                          dictationMe: dictationMe, dictationOthers: dictationOthers) {
        case .failure(.unsupported(let id)):
            throw catalog.languages.isEmpty ? CaptureError(.speechUnavailable) : CaptureError(.localeUnsupported, localeIdentifier: id)
        case .success(let plan):
            guard plan.missingEngines.isEmpty else {
                missingModel = MissingSpeechModel(language: plan.language, engines: plan.missingEngines)
                throw ModelMissing()
            }
            return plan
        }
    }

    /// Downloads the missing speech model from Apple, with progress. The download is the app's shared one
    /// (`speechDownloads`), so Settings and setup show it too, and one already running is not started again.
    func installMissingModel() {
        guard let missing = missingModel, modelInstall == nil, speechDownloadProgress == nil else { return }
        lastError = nil
        let active = Set([recordingLanguage?.id].compactMap { $0 })
        modelInstall = Task {
            // One engine after the other, as before.
            for engine in missing.engines where !Task.isCancelled {
                await speechDownloads.install(missing.language, engine: engine, keeping: active)?.value
            }
            modelInstall = nil
        }
    }

    func cancelModelInstall() {
        modelInstall?.cancel()
        guard let missing = missingModel else { return }
        for engine in missing.engines { speechDownloads.cancelInstall(missing.language, engine: engine) }
    }

    /// 0…1 while the model the panel is waiting for downloads, wherever the download was started (setup, Settings or
    /// the panel); nil when nothing is downloading.
    var speechDownloadProgress: Double? {
        guard let missing = missingModel else { return nil }
        let language = speechDownloads.catalog?.languages.first { $0.id == missing.language.id } ?? missing.language
        let parts = missing.engines.map { speechDownloads.progress(language, engine: $0) }
        guard parts.contains(where: { $0 != nil }) || modelInstall != nil else { return nil }
        let total = parts.enumerated().reduce(0.0) { sum, part in
            sum + (part.element ?? (language.installed.contains(missing.engines[part.offset]) ? 1 : 0))
        }
        return total / Double(missing.engines.count)
    }

    /// A download ended: read the languages again, and settle the banner that was waiting for it.
    func speechDownloadFinished() async {
        await refreshLanguages()
        guard let missing = missingModel else { return }
        let language = speechCatalog?.languages.first { $0.id == missing.language.id }
        if let language, missing.engines.allSatisfy({ language.installed.contains($0) }) {
            missingModel = nil
        } else if speechDownloadProgress == nil, let failure = speechDownloads.errorMessage {
            lastError = failure
        }
    }

    // MARK: Global shortcuts

    var recordHotKeyText: String {
        _ = keyboardLayoutRevision
        return GlobalHotKey.displayString(preferences.recordHotKey)
    }

    var markHotKeyText: String {
        _ = keyboardLayoutRevision
        return GlobalHotKey.displayString(preferences.markHotKey)
    }

    var noteHotKeyText: String {
        _ = keyboardLayoutRevision
        return GlobalHotKey.displayString(preferences.noteHotKey)
    }

    var pauseHotKeyText: String {
        _ = keyboardLayoutRevision
        return GlobalHotKey.displayString(preferences.pauseHotKey)
    }

    var translationHotKeyText: String {
        _ = keyboardLayoutRevision
        return GlobalHotKey.displayString(preferences.translationHotKey)
    }

    /// Registers the record shortcut (and the mark one while recording) from
    /// the preferences. A combination another app holds stays unregistered and
    /// the panel and Settings say so.
    func applyHotKeys() {
        // Unregister both first: the new record shortcut may be the old mark one.
        hotKey = nil
        markHotKey = nil
        noteHotKey = nil
        pauseHotKey = nil
        translationHotKey = nil
        guard !hotKeysSuspended else { return }
        hotKey = GlobalHotKey(preferences.recordHotKey, id: 1) { [weak self] in self?.toggleFromShortcut() }
        hotKeyAvailable = hotKey?.isRegistered ?? false
        if preferences.translationHotKey != preferences.recordHotKey {
            translationHotKey = GlobalHotKey(preferences.translationHotKey, id: 3) { [weak self] in self?.toggleTranslationFromShortcut() }
        }
        translationHotKeyAvailable = translationHotKey?.isRegistered ?? false
        if Self.takesInMeetingKeys(recording: phase == .recording) { registerMarkHotKey(); registerNoteHotKey(); registerPauseHotKey() }
    }

    /// The shortcuts for use during a meeting (Mark a Moment, Take a Note, Pause) are taken only while recording, so the rest of the
    /// time the combinations belong to the other apps.
    static func takesInMeetingKeys(recording: Bool) -> Bool { recording }

    /// Whether a shortcut may be registered: Vauta's own shortcuts never share a combination, and none is taken while a
    /// shortcut field is recording a new one. (A combination another app holds is found out by registering it.)
    static func mayRegister(_ combo: HotKeyCombo, besides others: [HotKeyCombo], suspended: Bool) -> Bool {
        !suspended && !others.contains(combo)
    }

    /// ⌃⌥T from another app. The panel may be out of sight (and VoiceOver cannot see it), so the press says what
    /// it did in words; with no recording nothing is on screen, so it also plays a sound.
    func toggleTranslationFromShortcut() {
        // The panel's switch is grey while the data is closed: the shortcut does not change what the switch shows.
        if panelDataUnavailable {
            NSSound.beep()
            if let reason = PanelUnavailable.reason(for: self) {
                AccessibilityNotification.Announcement(reason).post()
            }
            return
        }
        liveTranslation.toggle()
        let on = liveTranslation.isEnabled
        if phase == .recording {
            guard on else {
                AccessibilityNotification.Announcement(String(localized: "Live Translation off.", comment: "VoiceOver announcement after the shortcut turned Live Translation off")).post()
                return
            }
            // The captions panel is not followed by VoiceOver: when the pair cannot start, the announcement says what is needed.
            Task { [weak self] in
                // The first status arrives within a moment of turning it on.
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if self?.liveTranslation.snapshot.status != .starting { break }
                }
                guard let self, self.liveTranslation.isEnabled else { return }
                AccessibilityNotification.Announcement(self.translationOnAnnouncement).post()
            }
            return
        }
        NSSound(named: on ? "Purr" : "Bottle")?.play()
        let message: String
        if !on {
            message = String(localized: "Live Translation off.", comment: "VoiceOver announcement after the shortcut turned Live Translation off")
        } else if translationTargetName == nil {
            message = String(localized: "Live Translation on. Choose a language to translate into in the Vauta menu or in Settings\u{00A0}→\u{00A0}Translation.", comment: "VoiceOver announcement after the shortcut turned Live Translation on while nothing is recording and no language to translate into is chosen")
        } else {
            message = String(localized: "Live Translation on. Captions start with your next recording.", comment: "VoiceOver announcement after the shortcut turned Live Translation on while nothing is recording")
        }
        AccessibilityNotification.Announcement(message).post()
    }

    /// What VoiceOver hears after the shortcut turned Live Translation on during a recording: the plain news when captions
    /// will appear, and what is missing when they cannot start (the captions panel shows the same states).
    private var translationOnAnnouncement: String {
        let live = liveTranslation
        let pair = live.snapshot.pair?.labelName ?? ""
        switch live.snapshot.status {
        case .needsDownload:
            return String(localized: "Live Translation on. \(pair) needs a one-time download: use Download in the captions, or Settings\u{00A0}→\u{00A0}Translation.",
                          comment: "VoiceOver announcement after the shortcut turned Live Translation on during a recording, when the language pair must be downloaded first; the argument is a pair such as English → Spanish")
        case .unsupported:
            return String(localized: "Live Translation on. \(pair) isn’t available. Choose another language.",
                          comment: "VoiceOver announcement after the shortcut turned Live Translation on during a recording, when the language pair is not available; the argument is a pair such as English → Spanish")
        case .sameLanguage:
            return String(localized: "Live Translation on. Same language: nothing to translate. Choose another language.",
                          comment: "VoiceOver announcement after the shortcut turned Live Translation on during a recording, when the meeting is already in the language to translate into")
        default:
            return String(localized: "Live Translation on.", comment: "VoiceOver announcement after the shortcut turned Live Translation on during a recording")
        }
    }

    func registerMarkHotKey() {
        markHotKey = nil
        guard Self.mayRegister(preferences.markHotKey, besides: [preferences.recordHotKey, preferences.translationHotKey, preferences.noteHotKey,
                                                                 preferences.pauseHotKey],
                               suspended: hotKeysSuspended) else {
            markHotKeyAvailable = false
            return
        }
        markHotKey = GlobalHotKey(preferences.markHotKey, id: 2) { [weak self] in self?.markMoment() }
        markHotKeyAvailable = markHotKey?.isRegistered ?? false
    }

    /// "Take a Note": opens the floating notepad. Taken only while recording, like the mark shortcut.
    func registerNoteHotKey() {
        noteHotKey = nil
        guard Self.mayRegister(preferences.noteHotKey, besides: [preferences.recordHotKey, preferences.translationHotKey, preferences.markHotKey,
                                                                 preferences.pauseHotKey],
                               suspended: hotKeysSuspended) else {
            noteHotKeyAvailable = false
            return
        }
        noteHotKey = GlobalHotKey(preferences.noteHotKey, id: 4) { [weak self] in self?.toggleNotepadFromShortcut() }
        noteHotKeyAvailable = noteHotKey?.isRegistered ?? false
    }

    /// Pause and Resume. Taken only while recording, like the mark shortcut.
    func registerPauseHotKey() {
        pauseHotKey = nil
        guard Self.mayRegister(preferences.pauseHotKey, besides: [preferences.recordHotKey, preferences.translationHotKey, preferences.markHotKey,
                                                                  preferences.noteHotKey],
                               suspended: hotKeysSuspended) else {
            pauseHotKeyAvailable = false
            return
        }
        pauseHotKey = GlobalHotKey(preferences.pauseHotKey, id: 5) { [weak self] in self?.togglePauseFromShortcut() }
        pauseHotKeyAvailable = pauseHotKey?.isRegistered ?? false
    }

    /// While a shortcut field records a new combination, the current ones
    /// must not fire.
    /// Calls are balanced (one `false` per `true`): the shortcuts come back
    /// when the last field stops listening.
    func setHotKeysSuspended(_ suspended: Bool) {
        let wasSuspended = hotKeysSuspended
        hotKeySuspensions = max(0, hotKeySuspensions + (suspended ? 1 : -1))
        if hotKeysSuspended != wasSuspended { applyHotKeys() }
    }

    /// Re-applies the preferences that need work when they change.
    func observePreferences() {
        withObservationTracking {
            _ = preferences.recordHotKey
            _ = preferences.markHotKey
            _ = preferences.noteHotKey
            _ = preferences.pauseHotKey
            _ = preferences.translationHotKey
            _ = preferences.relockPolicy
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.hotKey?.combo != self.preferences.recordHotKey
                    || (Self.takesInMeetingKeys(recording: self.phase == .recording) && self.markHotKey?.combo != self.preferences.markHotKey)
                    || (Self.takesInMeetingKeys(recording: self.phase == .recording) && self.noteHotKey?.combo != self.preferences.noteHotKey)
                    || (Self.takesInMeetingKeys(recording: self.phase == .recording) && self.pauseHotKey?.combo != self.preferences.pauseHotKey)
                    || self.translationHotKey?.combo != self.preferences.translationHotKey {
                    self.applyHotKeys()
                }
                if self.unlock.interval != self.preferences.relockPolicy.interval { self.relockPolicyChanged() }
                self.observePreferences()
            }
        }
    }

    // MARK: After a restore

    /// A restore wrote the settings of a backup to UserDefaults: the running app reads them again (the preferences, the
    /// recorder's own settings and the calendar's). Nothing is assigned that did not change.
    func reloadSettingsFromDefaults() {
        let defaults = UserDefaults.standard
        preferences.reloadFromDefaults()
        let scope = SystemAudioScope(defaults: defaults)
        if audioSource != scope { audioSource = scope }
        let minutes = defaults.integer(forKey: Self.autoStopKey)
        let autoStop = (2...30).contains(minutes) ? minutes : 5
        if autoStopMinutes != autoStop { autoStopMinutes = autoStop }
        if dictationMe != defaults.bool(forKey: Self.dictationMeKey) { dictationMe = defaults.bool(forKey: Self.dictationMeKey) }
        if dictationOthers != defaults.bool(forKey: Self.dictationOthersKey) { dictationOthers = defaults.bool(forKey: Self.dictationOthersKey) }
        let suggest = !defaults.bool(forKey: Self.noCallSuggestionKey)
        if suggestOnCall != suggest { suggestOnCall = suggest }
        let keep = defaults.object(forKey: Self.knowledgeKey) as? Int ?? MeetingStore.retentionDays
        let days = [0, MeetingStore.retentionDays, 365, 730].contains(keep) ? keep : MeetingStore.retentionDays
        if knowledgeRetentionDays != days { knowledgeRetentionDays = days }
        calendar.reloadShowTitleInNotifications()
        brief.prefs.reload()
    }

    // MARK: Launch at login

    /// Mirrors `SMAppService.mainApp.status` (refreshed after changes, when
    /// the panel appears and when Vauta becomes active).
    var launchAtLogin: Bool {
        get { launchAtLoginStatus == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                lastError = String(localized: "Open Vauta at login couldn’t be changed. \(error.localizedDescription)",
                                   comment: "Error; the argument is the error")
            }
            refreshLaunchAtLogin()
        }
    }

    /// The user must allow Vauta in System Settings › General › Login Items.
    var launchAtLoginNeedsApproval: Bool { launchAtLoginStatus == .requiresApproval }

    func refreshLaunchAtLogin() {
        var status = SMAppService.mainApp.status
        #if VAUTA_DIAGNOSTICS
        if let sample = SnapshotMode.loginItem { status = sample }
        #endif
        if status != launchAtLoginStatus { launchAtLoginStatus = status }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
