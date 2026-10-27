// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import EventKit
import Foundation
import ServiceManagement

/// One row of Settings → Status.
struct StatusItem: Identifiable {
    enum Kind: String {
        case microphone, systemAudio, speechModel, store, leftovers, models, integratedModel, notifications, shortcuts, calendar, meetingApp, launchAtLogin
    }

    enum Level {
        case ok, attention, problem, info
        /// Optional and not asked yet.
        case pending

        var symbol: String {
            switch self {
            case .ok: StatusSymbol.ok.name
            case .attention: StatusSymbol.warning.name
            case .problem: StatusSymbol.error.name
            case .info: StatusSymbol.info.name
            // "Not asked yet" is information, like the Calendar pane's notice: one symbol for it everywhere.
            case .pending: StatusSymbol.info.name
            }
        }

        /// Spoken with the row, so the state never depends on color alone.
        var accessibilityLabel: String {
            switch self {
            case .ok: String(localized: "status.ok", defaultValue: "OK", comment: "Status level, accessibility; not the OK button of an alert")
            case .attention: String(localized: "Needs attention", comment: "Status level, accessibility")
            case .problem: String(localized: "Problem", comment: "Status level, accessibility")
            case .info: String(localized: "Information", comment: "Status level, accessibility")
            case .pending: String(localized: "Not asked yet", comment: "Status level, accessibility")
            }
        }
    }

    enum Action {
        case systemSettings(SystemSettingsPane)
        case showPane(SettingsModel.Pane)
        /// Opens the guided model setup (the first step wherever a model is missing).
        case setUpModel
        case requestMicrophone
        case requestNotifications
        case retryStore
        /// Opens General, where the shortcuts are.
        case changeShortcut
        /// Opens the pane of an optional feature that is off.
        case setUp(SettingsModel.Pane)
        case change(SettingsModel.Pane)
        /// Selects old encrypted copies in the Finder.
        case showInFinder([URL])
        /// Deletes old encrypted copies, after a confirmation.
        case deleteLeftovers
        /// Starts the download of the transcription language's speech model.
        case downloadSpeechModel(SpeechLanguage)
        /// Repairs the damaged integrated model (fetches only the damaged part again).
        case repairIntegratedModel

        var title: String {
            switch self {
            case .systemSettings: String(localized: "Open System Settings", comment: "Status action button")
            case .showPane(let pane): pane.openTitle
            case .setUpModel: String(localized: "Set Up…", comment: "Button that opens the guided model setup")
            case .requestMicrophone: String(localized: "Allow Microphone…", comment: "Status action button that shows the microphone permission prompt")
            case .requestNotifications: String(localized: "Allow Notifications…", comment: "Button that shows the notifications permission prompt")
            case .setUp(let pane), .change(let pane): pane.openTitle
            case .changeShortcut: String(localized: "Change Shortcut")
            case .retryStore: String(localized: "Try Again", comment: "Status action button")
            case .showInFinder: String(localized: "Show in Finder", comment: "Status action button that reveals files in the Finder")
            case .downloadSpeechModel: String(localized: "Download", comment: "Status action button that downloads the speech model")
            case .repairIntegratedModel: String(localized: "Repair", comment: "Status action button that repairs the damaged integrated model")
            case .deleteLeftovers: String(localized: "Delete…", comment: "Status action button that asks to delete old copies of the meetings")
            }
        }
    }

    let kind: Kind
    let level: Level
    let title: String
    let detail: String
    var action: Action?
    /// A second button beside `action`.
    var secondaryAction: Action?
    /// The old copies this row is about (only the `.leftovers` row).
    var leftovers: StoreLeftovers?
    /// English, for the copied diagnostics: states and counts, never content.
    let diagnostic: String

    var id: String { kind.rawValue }
}

/// Builds the status checklist from the live state.
@MainActor
struct StatusChecks {
    let recorder: RecorderModel
    let preferences: Preferences
    let speech: SpeechSettingsModel
    let loginItem: SMAppService.Status

    func run() async -> [StatusItem] {
        [microphone(), systemAudio(), speechModel(), await store(), await leftovers(), withSearchIssue(models()), integratedModel(), await notifications(), shortcuts(),
         calendar(), meetingApp(), launchAtLogin()].compactMap { $0 }
    }

    private func microphone() -> StatusItem {
        let title = String(localized: "Microphone", comment: "Status row")
        return switch Permissions.microphone {
        case .granted:
            StatusItem(kind: .microphone, level: .ok, title: title, detail: PermissionState.granted.label, diagnostic: "granted")
        case .notDetermined:
            StatusItem(kind: .microphone, level: .pending, title: title,
                       detail: String(localized: "Vauta asks the first time you record. You can allow it now.", comment: "Status detail"),
                       action: .requestMicrophone, diagnostic: "not determined")
        case .denied, .unknown:
            StatusItem(kind: .microphone, level: .problem, title: title,
                       detail: CaptureError.microphoneDeniedMessage,
                       action: .systemSettings(.microphone), diagnostic: "denied")
        }
    }

    private func systemAudio() -> StatusItem {
        StatusItem(kind: .systemAudio, level: .info, title: String(localized: "System audio recording", comment: "Status row"),
                   detail: String(localized: "macOS asks the first time you record and doesn’t let apps check this permission. If “\(Channel.others.displayName)” stays empty, turn on Vauta in System Settings\u{00A0}→\u{00A0}Privacy & Security\u{00A0}→\u{00A0}Screen & System Audio Recording.",
                                  comment: "Status detail; argument is the name of the other participants' channel"),
                   action: .systemSettings(.systemAudio), diagnostic: "not queryable")
    }

    private func speechModel() -> StatusItem {
        let title = String(localized: "Speech model", comment: "Status row")
        guard let language = speech.effectiveLanguage(preferences.transcriptionLanguage) else {
            return StatusItem(kind: .speechModel, level: .problem, title: title,
                              detail: String(localized: "Speech recognition isn’t available on this Mac.", comment: "Status detail"),
                              diagnostic: "unavailable")
        }
        let name = language.displayName
        let state = speech.state(language)
        let diagnostic = "\(language.id) \(language.preferredEngine.rawValue) \(state.rawValue)"
        return switch state {
        case .installed:
            StatusItem(kind: .speechModel, level: .ok, title: title,
                       detail: String(localized: "\(name) is installed and runs on this Mac.", comment: "Status detail; argument is a language"),
                       diagnostic: diagnostic)
        case .downloading:
            StatusItem(kind: .speechModel, level: .info, title: title,
                       detail: String(localized: "Downloading the \(name) speech model…", comment: "Status detail; argument is a language"),
                       diagnostic: diagnostic)
        case .notInstalled, .unsupported:
            StatusItem(kind: .speechModel, level: .problem, title: title,
                       detail: String(localized: "Download the \(name) model to transcribe meetings.", comment: "Status detail; argument is a language"),
                       action: .downloadSpeechModel(language), secondaryAction: .showPane(.recording), diagnostic: diagnostic)
        }
    }

    private func store() async -> StatusItem {
        let title = String(localized: "Encrypted store", comment: "Status row")
        guard recorder.storeAvailable, let stats = await recorder.storeStats() else {
            return StatusItem(kind: .store, level: .problem, title: title,
                              detail: String(localized: "Vauta couldn’t open your encrypted meetings. If macOS asks for Keychain access, allow it, then try again.",
                                             comment: "Status detail"),
                              action: .retryStore, diagnostic: "not open")
        }
        let count = stats.meetings
        var bytes = stats.fileBytes + stats.journalBytes
        #if VAUTA_DIAGNOSTICS
        if let sample = SnapshotMode.storeBytes { bytes = sample }
        #endif
        let size = ByteSize.string(Int64(bytes))
        return StatusItem(kind: .store, level: .ok, title: title,
                          detail: String(localized: "\(count) meetings (\(size)) on this Mac.",
                                         comment: "Status detail; arguments are a meeting count and a file size"),
                          diagnostic: "open, \(count) meetings, \(bytes) bytes")
    }

    /// Encrypted copies kept by the earlier-version migration. Shown only while they exist, so they are not invisible.
    private func leftovers() async -> StatusItem? {
        guard let found = await recorder.storeLeftovers(), !found.isEmpty else { return nil }
        let title = String(localized: "Old copies of your meetings", comment: "Status row")
        let size = ByteSize.string(found.totalBytes)
        // The day the last copy set aside is deleted automatically.
        let when = (found.lastAutomaticDeletion ?? AppClock.now.addingTimeInterval(Double(MeetingStore.retentionDays) * 86_400))
            .formatted(.dateTime.day().month(.wide).year())
        let detail: String
        if found.hasOldFolder && found.setAsideCount > 0 {
            detail = String(localized: "When Vauta replaced an earlier version, it kept a copy of your meetings (\(size)) just in case. The copy in Vauta’s folder is deleted on \(when); the folder from the earlier version stays until you delete it.",
                            comment: "Status detail; the arguments are a file size and a date")
        } else if found.hasOldFolder {
            detail = String(localized: "A folder from an earlier version still holds a copy of your meetings (\(size)). Vauta doesn’t use it, so you can delete it.",
                            comment: "Status detail; the argument is a file size")
        } else {
            detail = String(localized: "When Vauta replaced an earlier version, it kept a copy of your meetings (\(size)) just in case. The copy is deleted on \(when), or you can delete it now.",
                            comment: "Status detail; the arguments are a file size and a date")
        }
        return StatusItem(kind: .leftovers, level: .info, title: title, detail: detail, action: .showInFinder(found.urls),
                          secondaryAction: .deleteLeftovers, leftovers: found,
                          diagnostic: "\(found.setAsideCount) set aside\(found.hasOldFolder ? ", old folder" : ""), \(found.totalBytes) bytes")
    }

    /// A chat model that works while search by meaning doesn't: the row
    /// asks for attention and says why (keyword search still works).
    private func withSearchIssue(_ item: StatusItem) -> StatusItem {
        guard item.level == .ok, let issue = recorder.llmStatus.searchIssue else { return item }
        let detail = [item.detail,
                      String(localized: "Search by meaning: \(issue.localizedDescription)",
                             comment: "Status detail; the argument says why search by meaning is unavailable"),
                      issue.recoverySuggestion].compactMap { $0 }.joinedAsSentences()
        return StatusItem(kind: item.kind, level: .attention, title: item.title, detail: detail,
                          action: .showPane(.models), diagnostic: item.diagnostic + ", search unavailable")
    }

    /// "Integrated model", only when it is the chosen provider: ready, downloading, damaged or not downloaded.
    func integratedModel() -> StatusItem? {
        let settings = ModelProviderSettings.load(hasServerConfig: recorder.serverConfig != nil || recorder.serverConfigUnavailable)
        guard settings.chat == .integrated else { return nil }
        let title = String(localized: "Integrated model", comment: "Status row for the integrated language model; only shown when it is chosen")
        let status = recorder.integratedModel.status
        let appleAvailable = settingsAppleAvailable
        func row(_ level: StatusItem.Level, _ detail: String, _ diagnostic: String, action: StatusItem.Action? = .showPane(.models),
                 secondary: StatusItem.Action? = nil) -> StatusItem {
            StatusItem(kind: .integratedModel, level: level, title: title, detail: detail, action: action, secondaryAction: secondary, diagnostic: "integrated \(diagnostic)")
        }
        let percent = Int(((status.fraction ?? 0) * 100).rounded(.down))
        switch status.state {
        case .ready:
            return row(.ok, IntegratedModelText.statusReady, "ready", action: nil)
        case .downloading:
            return row(.info, IntegratedModelText.statusDownloading(percent), "downloading \(percent)%")
        case .pausedForRecording:
            return row(.info, IntegratedModelText.statusPausedForRecording(percent), "paused for recording \(percent)%")
        case .repairing:
            return row(.info, IntegratedModelText.statusRepairing(percent), "repairing \(percent)%")
        case .importing(let fraction):
            let imported = Int((fraction * 100).rounded(.down))
            if status.importPaused { return row(.info, IntegratedModelText.statusImportPaused(imported), "import paused for recording \(imported)%") }
            return row(.info, IntegratedModelText.statusImporting(imported), "importing \(imported)%")
        case .checkingPartial, .verifying:
            return row(.info, IntegratedModelText.statusChecking, "checking")
        case .preparing:
            return row(.info, IntegratedModelText.statusPreparing, "preparing")
        case .deleting:
            return row(.info, IntegratedModelText.deleting, "deleting")
        case .partial(let verified, let total):
            return row(.attention, IntegratedModelText.statusPaused(verified: verified, total: total), "paused")
        case .needsFile(let missing):
            return row(.attention, IntegratedModelText.statusNeeds(missing), "needs \(missing == .tokenizer ? "tokenizer" : "weights")")
        case .damaged:
            return row(.attention, IntegratedModelText.statusDamaged, "damaged", action: .repairIntegratedModel, secondary: .showPane(.models))
        case .failed(let error):
            return row(.attention, IntegratedModelText.failure(error, appleAvailable: appleAvailable), "failed \(error)")
        case .unsupported(let reason):
            return row(.attention, IntegratedModelText.unsupportedNote(reason), "unsupported")
        case .notInstalled:
            return row(.attention, IntegratedModelText.statusNotDownloaded, "not downloaded")
        }
    }

    /// Apple Intelligence can write minutes while the integrated model is not ready.
    private var settingsAppleAvailable: Bool { AppleChatModel().availability == .available }

    private func models() -> StatusItem {
        let title = String(localized: "Minutes and Ask", comment: "Status row for the model provider")
        let settings = ModelProviderSettings.load(hasServerConfig: recorder.serverConfig != nil || recorder.serverConfigUnavailable)
        let search = "search \(settings.embeddings.rawValue)"
        if settings.chat == .onDevice || settings.chat == .integrated {
            if settings.chat == .integrated, recorder.integratedModel.status.state == .ready {
                return StatusItem(kind: .models, level: .ok, title: title, detail: String(localized: "Integrated model on this Mac.", comment: "Status detail"),
                                  diagnostic: "integrated available, \(search)")
            }
            let availability = AppleChatModel().availability
            if availability == .available, settings.chat == .integrated {
                // A stand-in for the chosen provider, not the provider itself: information, not a green check.
                return StatusItem(kind: .models, level: .info, title: title, detail: IntegratedModelText.activityFallback(appleAvailable: true),
                                  diagnostic: "integrated chosen, apple stands in, \(search)")
            }
            if availability == .available {
                return StatusItem(kind: .models, level: .ok, title: title,
                                  detail: String(localized: "Apple Intelligence on this Mac.", comment: "Status detail: the minutes use Apple's on-device model; a full sentence like the other details"),
                                  diagnostic: "on-device available, \(search)")
            }
            return StatusItem(kind: .models, level: .problem, title: title, detail: availability.explanation,
                              action: availability.action, diagnostic: "on-device \(availability), \(search)")
        }
        if recorder.serverConfigUnavailable {
            return StatusItem(kind: .models, level: .attention, title: title,
                              detail: String(localized: "The Keychain is locked, so Vauta can’t read the model server settings. Unlock your Mac, then try again.", comment: "Status detail"),
                              action: .showPane(.models), diagnostic: "server config locked, \(search)")
        }
        guard let config = recorder.serverConfig else {
            return StatusItem(kind: .models, level: .attention, title: title,
                              detail: String(localized: "No model chosen. Vauta still records and transcribes, but writes no minutes.",
                                             comment: "Status detail"),
                              action: .setUpModel, secondaryAction: .showPane(.models),
                              diagnostic: "server not configured, \(search)")
        }
        let s = recorder.llmStatus
        let kind = config.effectiveProfile.kind
        let place = config.mode == .local ? "local" : "network"
        let facts = "server \(place) \(config.profile == nil ? "legacy" : kind.rawValue)"
        if s.reachable == true && s.missingModels.isEmpty {
            let name = kind.displayName
            let detail = config.mode == .local
                ? String(localized: "Connected to \(name) on this Mac.", comment: "Status detail; argument is a server name")
                : String(localized: "Connected to \(name) on your network over HTTPS.", comment: "Status detail; argument is a server name")
            return StatusItem(kind: .models, level: .ok, title: title, detail: detail,
                              diagnostic: "\(facts) reachable, \(s.models.count) models, \(search)")
        }
        let detail = s.lastError ?? String(localized: "Not checked yet.", comment: "Status detail for the model server")
        return StatusItem(kind: .models, level: s.reachable == nil ? .info : .problem, title: title, detail: detail,
                          action: config.mode == .remote && s.reachable == false ? .systemSettings(.localNetwork) : .showPane(.models),
                          diagnostic: "\(facts) \(s.reachable == nil ? "unchecked" : "unreachable"), \(s.missingModels.count) missing, \(search)")
    }

    private func notifications() async -> StatusItem {
        let title = String(localized: "Notifications", comment: "Status row")
        return switch await Permissions.notifications() {
        case .granted:
            StatusItem(kind: .notifications, level: .ok, title: title, detail: PermissionState.granted.label, diagnostic: "granted")
        case .notDetermined:
            StatusItem(kind: .notifications, level: .pending, title: title,
                       detail: String(localized: "Allow notifications to know when minutes are ready or a recording is about to stop.", comment: "Status detail"),
                       action: .requestNotifications, diagnostic: "not determined")
        case .denied, .unknown:
            StatusItem(kind: .notifications, level: .attention, title: title,
                       detail: String(localized: "Off. Alerts appear only in the menu bar.", comment: "Status detail"),
                       action: .systemSettings(.notifications), diagnostic: "denied")
        }
    }

    private func shortcuts() -> StatusItem {
        let title = String(localized: "Keyboard shortcuts", comment: "Status row")
        let record = recorder.recordHotKeyText
        if !recorder.hotKeyAvailable {
            // A warning, as in General: recording still starts from the panel.
            return StatusItem(kind: .shortcuts, level: .attention, title: title,
                              detail: String(localized: "\(record) is used by another app. Choose a different shortcut to start and stop recording.",
                                             comment: "Status detail; argument is a shortcut"),
                              action: .changeShortcut, diagnostic: "record shortcut unavailable")
        }
        if recorder.isRecording && !recorder.markHotKeyAvailable {
            let mark = recorder.markHotKeyText
            return StatusItem(kind: .shortcuts, level: .attention, title: title,
                              detail: String(localized: "\(mark) is used by another app, so marking moments works only from the panel.",
                                             comment: "Status detail; argument is a shortcut"),
                              action: .changeShortcut, diagnostic: "mark shortcut unavailable")
        }
        return StatusItem(kind: .shortcuts, level: .ok, title: title,
                          detail: String(localized: "\(record) starts and stops recording in any app.", comment: "Status detail; argument is a shortcut"),
                          diagnostic: "available")
    }

    private func calendar() -> StatusItem {
        let title = String(localized: "Calendar", comment: "Status row")
        guard recorder.calendar.enabled else {
            return StatusItem(kind: .calendar, level: .info, title: title,
                              detail: String(localized: "Not used. It’s optional.", comment: "Status detail"),
                              action: .setUp(.calendar), diagnostic: "off")
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return StatusItem(kind: .calendar, level: .problem, title: title,
                              detail: String(localized: "Vauta has no access. Turn on Vauta in System Settings\u{00A0}→\u{00A0}Privacy & Security\u{00A0}→\u{00A0}Calendars.", comment: "Status detail"),
                              action: .systemSettings(.calendars), diagnostic: "no access")
        }
        let count = recorder.calendar.selected.count
        return StatusItem(kind: .calendar, level: .ok, title: title,
                          detail: String(localized: "\(count) calendars selected.", comment: "Status detail; argument is a count"),
                          diagnostic: "access, \(count) selected")
    }

    private func meetingApp() -> StatusItem {
        let title = String(localized: "Call detection", comment: "Status row")
        if let app = recorder.callApp {
            let name = app.displayName
            return StatusItem(kind: .meetingApp, level: .info, title: title,
                              detail: String(localized: "In a call now: \(name).", comment: "Status detail; argument is an app or browser family"),
                              diagnostic: "in call (\(app.rawValue))")
        }
        return StatusItem(kind: .meetingApp, level: .info, title: title,
                          detail: String(localized: "No meeting app is using the microphone right now.", comment: "Status detail"),
                          diagnostic: "no call")
    }

    private func launchAtLogin() -> StatusItem {
        let title = String(localized: "Open Vauta at login", comment: "Status row")
        return switch loginItem {
        case .enabled:
            StatusItem(kind: .launchAtLogin, level: .ok, title: title, detail: String(localized: "Vauta opens when you log in.", comment: "Status detail"), diagnostic: "on")
        case .requiresApproval:
            StatusItem(kind: .launchAtLogin, level: .attention, title: title,
                       detail: String(localized: "Approve Vauta in System Settings\u{00A0}→\u{00A0}General\u{00A0}→\u{00A0}Login Items & Extensions.", comment: "Status detail"),
                       action: .systemSettings(.loginItems), diagnostic: "requires approval")
        default:
            StatusItem(kind: .launchAtLogin, level: .info, title: title, detail: String(localized: "Vauta doesn’t open when you log in.", comment: "Status detail"),
                       action: .change(.general), diagnostic: "off")
        }
    }
}

extension AppleChatModel.Availability {
    /// Why the on-device model can't be used, and what to do.
    var explanation: String {
        switch self {
        case .available: String(localized: "Ready on this Mac", comment: "Apple Intelligence availability")
        case .deviceNotEligible:
            String(localized: "This Mac can’t run Apple Intelligence. Use a model server instead.", comment: "Apple Intelligence availability")
        case .appleIntelligenceNotEnabled:
            String(localized: "Apple Intelligence is turned off. Turn it on in System Settings\u{00A0}→\u{00A0}Apple Intelligence & Siri.",
                   comment: "Apple Intelligence availability")
        case .modelNotReady:
            String(localized: "Apple Intelligence is still downloading. Try again later.", comment: "Apple Intelligence availability")
        case .unavailable:
            String(localized: "Apple Intelligence isn’t available right now.", comment: "Apple Intelligence availability")
        }
    }

    var action: StatusItem.Action? {
        switch self {
        case .appleIntelligenceNotEnabled, .modelNotReady: .systemSettings(.appleIntelligence)
        case .deviceNotEligible: .showPane(.models)
        default: nil
        }
    }
}
