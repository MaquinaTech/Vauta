// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation
import SwiftUI
import Observation
import ServiceManagement

/// State of the Settings window that is not a preference: the selected pane,
/// the status checklist, speech models, the models draft and confirmations.
@MainActor
@Observable
final class SettingsModel {
    enum Pane: String, CaseIterable, Identifiable {
        case general, recording, speakers, translation, models, privacy, context, documents, calendar, status, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: String(localized: "General", comment: "Settings pane")
            case .recording: String(localized: "Recording", comment: "Settings pane")
            case .speakers: String(localized: "Speakers", comment: "Settings pane: telling the voices of a meeting apart")
            case .translation: String(localized: "Translation", comment: "Settings pane: live translation of the other participants")
            case .models: String(localized: "Models", comment: "Settings pane: model provider, minutes and Ask")
            case .privacy: String(localized: "Privacy & Security", comment: "Settings pane")
            case .context: String(localized: "Context", comment: "Settings pane: people, projects and glossary")
            case .documents: String(localized: "Documents", comment: "Settings pane: the folders and files Ask can answer from")
            case .calendar: String(localized: "Calendar & Reminders", comment: "Settings pane: Calendar, the pre-meeting brief and Reminders")
            case .status: String(localized: "Status", comment: "Settings pane: setup checklist")
            case .about: String(localized: "About", comment: "Settings pane")
            }
        }

        /// The label of a button that goes to this pane of Vauta's own Settings: "Show Models Pane". One place, so every
        /// such button reads the same. "Open <Pane> Settings" is reserved for the panes of System Settings.
        var openTitle: String {
            String(localized: "Show \(title) Pane", comment: "Button that goes to a pane of Vauta's own Settings; the argument is the pane name, e.g. Calendar, so it reads \"Show Calendar Pane\". Not System Settings, whose buttons read \"Open Sound Settings\"")
        }

        /// The colour of the pane's icon in the sidebar: Vauta's own for what is Vauta's (recording, speakers, models,
        /// translation), the system's usual ones for the rest.
        var tint: Color {
            switch self {
            case .general, .about: .gray
            case .recording: Brand.red
            case .speakers: Brand.magenta
            case .translation: Brand.teal
            case .models: Brand.indigo
            case .privacy: .blue
            case .context: .purple
            case .documents: .brown
            case .calendar: .orange
            case .status: .green
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .recording: "waveform"
            case .speakers: "person.2"
            case .translation: "character.bubble"
            case .models: "cpu"
            case .privacy: "hand.raised"
            case .context: "books.vertical"
            case .documents: "doc.on.doc"
            case .calendar: "calendar"
            case .status: "checkmark.circle"
            case .about: "info.circle"
            }
        }
    }

    /// The selected pane is remembered (it reveals nothing).
    var pane: Pane {
        didSet { UserDefaults.standard.set(pane.rawValue, forKey: Self.paneKey) }
    }

    /// Setup ended and the menu bar icon couldn't be seen (behind the notch, or hidden by a menu bar manager):
    /// Settings → General says so and how to get back in.
    var menuBarIconMayBeHidden = false

    /// The app's speech downloads (the recorder's), so a download begun in setup or the panel shows here.
    let speech: SpeechSettingsModel
    let models = ModelsSettingsModel()
    /// Settings › Calendar & Reminders › After meetings (the lists and calendars a new item can start in).
    let afterMeetings = AfterMeetingsSettings()
    let backup = BackupModel()
    let savedVoices = SavedVoicesModel()
    let minutesTemplates = MinutesTemplatesModel()

    private(set) var statusItems: [StatusItem] = []
    private(set) var checking = false
    private(set) var loginItemStatus = SMAppService.mainApp.status

    /// A shorter retention waiting for confirmation, and how many meetings it
    /// deletes now (nil = unknown because the store is not open).
    var pendingRetention: RetentionChange?
    private(set) var pendingRetentionCount: Int?
    private(set) var eraseError: String?
    /// The last erase worked: the pane says so (the sheet closes either way).
    private(set) var eraseDone = false
    private(set) var erasing = false
    /// The Erase Everything sheet is open (a flag here, so locking the history can close it).
    var showErase = false
    /// The meetings the erase sheet names, read before it opens so its first sentence does not change under the reader.
    var eraseMeetings: Int?
    /// The size of the old copies from the earlier version the erase also deletes (nil or 0: none), read at the same time.
    var eraseLeftoverBytes: Int64?
    /// The document sources the erase also removes (nil or 0: none), read at the same time.
    var eraseDocumentSources: Int?

    func presentErase(_ recorder: RecorderModel) async {
        eraseMeetings = await recorder.storeStats()?.meetings
        eraseLeftoverBytes = await recorder.storeLeftovers()?.totalBytes
        eraseDocumentSources = await recorder.documents?.snapshot.sources.count
        showErase = true
    }

    private static let paneKey = "settingsPane"

    init(speech: SpeechSettingsModel = SpeechSettingsModel()) {
        self.speech = speech
        pane = UserDefaults.standard.string(forKey: Self.paneKey).flatMap(Pane.init(rawValue:)) ?? .general
        // A restore may bring other model settings: Settings → Models reads them again the next time it opens.
        backup.onSettingsRestored = { [models] in models.discardDraft() }
    }

    // MARK: Launch at login

    func refreshLoginItem() {
        loginItemStatus = SMAppService.mainApp.status
        #if VAUTA_DIAGNOSTICS
        if let sample = SnapshotMode.loginItem { loginItemStatus = sample }
        #endif
    }

    func setLaunchAtLogin(_ on: Bool, _ recorder: RecorderModel) {
        recorder.launchAtLogin = on
        refreshLoginItem()
    }

    // MARK: Retention

    /// Applies a longer retention at once; a shorter one waits for the
    /// confirmation sheet, which shows how many meetings it deletes.
    func requestRetention(_ value: KnowledgeRetention, _ recorder: RecorderModel) async {
        let change = RetentionChange(from: KnowledgeRetention(days: recorder.knowledgeRetentionDays), to: value)
        guard change.from != change.to else { return }
        guard change.isShorter else {
            recorder.knowledgeRetentionDays = value.rawValue
            return
        }
        let count = await recorder.meetingStartDates().map { change.meetingsDeleted(startDates: $0) }
        if count == 0 {
            recorder.knowledgeRetentionDays = value.rawValue
            return
        }
        // Deleting meetings is as protected as reading them.
        guard await recorder.authorizeHistory(for: .deleteOlder) else { return }
        pendingRetentionCount = count
        pendingRetention = change
    }

    func confirmRetention(_ recorder: RecorderModel) {
        guard let change = pendingRetention else { return }
        recorder.knowledgeRetentionDays = change.to.rawValue
        pendingRetention = nil
    }

    // MARK: Erase everything

    /// Erases every meeting and all context (crypto-shred). Returns whether it worked.
    func eraseEverything(_ recorder: RecorderModel) async -> Bool {
        guard let history = recorder.history else { return false }
        erasing = true
        recorder.isErasing = true
        eraseDone = false
        defer { erasing = false; recorder.isErasing = false }
        let result = await history.eraseAll()
        eraseDone = result.erased
        eraseError = result.alert.map { [$0.title, $0.message].joinedAsSentences() }
        return result.erased
    }

    func clearEraseError() { eraseError = nil; eraseDone = false }

    // MARK: Status

    #if VAUTA_DIAGNOSTICS
    /// For `Vauta render-ui`: the erase sheet while it erases (`false` puts back the sheet before the erase).
    func installSnapshotErasing(_ on: Bool = true) { erasing = on }

    /// Forgets the last checklist, so the snapshot renderer waits for a fresh run.
    func resetSnapshotStatus() { statusItems = [] }

    /// For `Vauta render-ui`: the line under Erase after it worked or failed.
    func installSnapshotEraseResult(done: Bool, error: String?) { eraseDone = done; eraseError = error }

    /// For `Vauta render-ui`: Status while its checks run (no list yet).
    func installSnapshotChecking() { statusItems = []; checking = true }
    #endif

    func runChecks(_ recorder: RecorderModel, _ preferences: Preferences) async {
        // One run at a time: an older run finishing last would show stale rows.
        guard !checking else { return }
        checking = true
        defer { checking = false }
        refreshLoginItem()
        await speech.refresh()
        statusItems = await StatusChecks(recorder: recorder, preferences: preferences, speech: speech,
                                         loginItem: loginItemStatus).run()
    }

    /// The checklist as text for a support request (no meeting content).
    func diagnostics() -> String {
        let info = Bundle.main.infoDictionary
        let report = DiagnosticsReport(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "dev",
            build: info?["CFBundleVersion"] as? String ?? "0",
            system: "macOS " + ProcessInfo.processInfo.operatingSystemVersionString,
            entries: statusItems.map { DiagnosticsReport.Entry($0.kind.rawValue, $0.diagnostic) }
                + [DiagnosticsReport.Entry("sqlite", SQLiteLibrary.version)])
        return report.text
    }
}
