// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation
import Observation

/// State of the first-run setup.
@MainActor
@Observable
final class OnboardingModel {
    enum ModelSetup: Equatable {
        case onDevice
        case server(String)
    }

    var flow = OnboardingFlow()
    /// The app's speech downloads (the recorder's), so the download setup starts goes on, and is seen, after the window closes.
    let speech: SpeechSettingsModel
    let micTest = MicLevelTest()
    let appleModel = AppleChatModel()
    /// Settings → Models' state, used by the model server guide to save the server it found.
    let models = ModelsSettingsModel()
    var guidePresented = false {
        didSet { if !guidePresented { guideSheetHeight = nil; guideApp = nil } }
    }
    /// The app the guide opens on (the found server that has no model yet); nil: the guide's own first choice.
    var guideApp: LocalModelApp?
    /// The height the open guide sheet reports, so the window is as tall as the sheet needs and no dimmed band is left under it.
    var guideSheetHeight: CGFloat?
    /// What the guide or "Find Model Servers" saved, for the model page and the last page.
    private(set) var serverSummary: String?

    private(set) var microphone = Permissions.microphone
    private(set) var notifications = PermissionState.notDetermined

    private(set) var scanning = false
    private(set) var discovered: [DiscoveredServer]?
    private(set) var modelSetup: ModelSetup?
    private(set) var modelMessage: String?
    /// The server `modelMessage` is about, so the page shows it under that server's row.
    private(set) var messageServer: URL?
    /// The server being saved: its button shows progress and the others wait.
    private(set) var usingServer: URL?
    private var storedAppleAvailability = AppleChatModel().availability

    init(speech: SpeechSettingsModel = SpeechSettingsModel()) {
        self.speech = speech
    }

    #if VAUTA_DIAGNOSTICS
    /// For `Vauta render-ui`: permission states that do not depend on this Mac. They stay as installed.
    func installSnapshotPermissions(microphone: PermissionState, notifications: PermissionState) {
        self.microphone = microphone
        self.notifications = notifications
        permissionsAreFixed = true
    }

    private var permissionsAreFixed = false

    /// For `Vauta render-ui`: Apple Intelligence availability that does not depend on this Mac.
    var appleAvailabilityOverride: AppleChatModel.Availability?

    /// For `Vauta render-ui`: the result of "Find Model Servers".
    func installSnapshotServers(_ servers: [DiscoveredServer]?, message: String?, messageServer: ServerKind? = nil,
                                selected: String? = nil, summary: String? = nil) {
        discovered = servers
        modelMessage = message
        self.messageServer = servers?.first { $0.kind == messageServer }?.baseURL
        if let selected { modelSetup = .server(selected); serverSummary = summary ?? selected }
    }

    /// For `Vauta render-ui`: who writes minutes, regardless of this Mac's saved settings.
    var chatProviderOverride: ModelProviderSettings.Chat?

    /// For `Vauta render-ui`: the guide's choice, as the page shows it.
    func installSnapshotApple(selected: Bool) { modelSetup = selected ? .onDevice : nil }
    #endif

    /// Whether Apple Intelligence can write minutes on this Mac.
    var appleAvailability: AppleChatModel.Availability {
        #if VAUTA_DIAGNOSTICS
        if let appleAvailabilityOverride { return appleAvailabilityOverride }
        #endif
        return storedAppleAvailability
    }

    /// Looks again: the user may have turned Apple Intelligence on in System Settings.
    func refreshAppleAvailability() {
        let current = appleModel.availability
        if current != storedAppleAvailability { storedAppleAvailability = current }
    }

    /// Bumped when Settings may have saved something: `chatProvider` reads the saved choice, which nothing observable changes.
    private(set) var settingsRevision = 0

    func settingsMayHaveChanged() { settingsRevision += 1 }

    /// Something will write minutes: the saved server, or Apple Intelligence.
    func minutesAreReady(_ recorder: RecorderModel) -> Bool {
        chatProvider(hasServerConfig: recorder.serverConfig != nil) == .server || appleAvailability == .available
    }

    /// The microphone is not allowed (or was never asked for): Vauta cannot record yet.
    var microphoneBlocksRecording: Bool { microphone != .granted }

    /// The language Vauta transcribes with, when its speech model is not on this Mac (and is not being downloaded).
    func missingSpeechLanguage(_ preferences: Preferences) -> SpeechLanguage? {
        guard let language = speech.effectiveLanguage(preferences.transcriptionLanguage), speech.state(language) == .notInstalled else { return nil }
        return language
    }

    /// The language whose speech model is being downloaded now (the Download button of the last page, or the
    /// download "Download and Continue" started), with the fraction done.
    func downloadingSpeech(_ preferences: Preferences) -> (language: SpeechLanguage, progress: Double)? {
        guard let language = speech.effectiveLanguage(preferences.transcriptionLanguage), speech.state(language) == .downloading else { return nil }
        return (language, speech.progress(language) ?? 0)
    }

    /// Why the last download of this language's speech model failed, in words for its row: nil when it did not.
    func speechFailure(_ language: SpeechLanguage) -> String? { speech.failure(language) ?? (speech.failedInstall?.id == language.id ? speech.errorMessage : nil) }

    /// Nothing stands between the first meeting and a recording: the microphone is allowed and the speech model is there
    /// (a download that is still running does not count).
    func canRecord(_ preferences: Preferences) -> Bool {
        !microphoneBlocksRecording && missingSpeechLanguage(preferences) == nil && downloadingSpeech(preferences) == nil
    }

    /// The microphone is not allowed or the speech model is missing (not downloading): recording cannot work yet.
    func hasBlockingProblem(_ preferences: Preferences) -> Bool {
        microphoneBlocksRecording || missingSpeechLanguage(preferences) != nil
    }

    /// The last page is a success only when something writes minutes and Vauta can record.
    func isAllSet(_ recorder: RecorderModel, _ preferences: Preferences) -> Bool {
        minutesAreReady(recorder) && canRecord(preferences)
    }

    /// The last page's title: "You're All Set" only when Vauta can record and something writes minutes.
    func finishedTitle(_ recorder: RecorderModel, _ preferences: Preferences) -> String {
        if isAllSet(recorder, preferences) {
            return String(localized: "You’re All Set", comment: "Setup last page title; the sheet of the model guide is titled differently")
        }
        // A speech model that is still downloading also keeps the first recording waiting: that page is not "finished" yet.
        if hasBlockingProblem(preferences) || !canRecord(preferences) {
            return String(localized: "Almost Ready", comment: "Setup last page title when the microphone or the speech model stops the first recording, or while the speech model is still downloading")
        }
        return String(localized: "Setup Finished", comment: "Setup last page title when something is still missing: a model that writes minutes, the microphone or the speech model")
    }

    /// Who writes minutes now (the saved choice, or the default for this install).
    func chatProvider(hasServerConfig: Bool) -> ModelProviderSettings.Chat {
        _ = settingsRevision
        #if VAUTA_DIAGNOSTICS
        if let chatProviderOverride, modelSetup == nil { return chatProviderOverride }
        #endif
        // A choice made on the model page counts at once, before the saved settings are read again.
        switch modelSetup {
        case .onDevice?: return .onDevice
        case .server?: return .server
        case nil: break
        }
        return ModelProviderSettings.load(hasServerConfig: hasServerConfig).chat
    }

    func load(_ preferences: Preferences? = nil) async {
        await speech.refresh()
        if let preferences { updateSkips(preferences) }
        await refreshPermissions()
    }

    func refreshPermissions() async {
        #if VAUTA_DIAGNOSTICS
        if permissionsAreFixed { return }
        #endif
        microphone = Permissions.microphone
        notifications = await Permissions.notifications()
    }

    func requestMicrophone() async {
        microphone = await Permissions.requestMicrophone()
    }

    func requestNotifications() async {
        notifications = await Permissions.requestNotifications()
    }

    /// The speech model page is skipped when the chosen language is installed.
    func updateSkips(_ preferences: Preferences) {
        if let language = speech.effectiveLanguage(preferences.transcriptionLanguage), speech.state(language) == .installed {
            flow.skipped.insert(.speechModel)
        } else {
            flow.skipped.remove(.speechModel)
        }
    }

    // MARK: Models

    func useOnDevice(_ recorder: RecorderModel) async {
        ModelProviderSettings(chat: .onDevice, embeddings: .none).save()
        await recorder.llm?.configurationChanged()
        modelSetup = .onDevice
        serverSummary = nil
        modelMessage = nil
        messageServer = nil
    }

    /// The guide saved a server: the page shows it as chosen.
    func guideFinished(_ summary: ModelGuideModel.Summary) {
        modelSetup = .server(summary.serverName)
        serverSummary = String(localized: "\(summary.mainModel) in \(summary.serverName)",
                               comment: "Setup: the model and the app that now write minutes; arguments are a model name and an app name")
        modelMessage = nil
        messageServer = nil
    }

    func detect() async {
        scanning = true
        discovered = await ServerDiscovery.scanLoopback()
        scanning = false
    }

    /// The chat model a found server would write minutes with, as people know it ("Qwen3.5-9B"), if it has one.
    static func modelName(of server: DiscoveredServer) -> String? {
        let id = server.suggestedConfig().deepModel
        guard !id.isEmpty else { return nil }
        return [LocalModel.qwen35_9B, .qwen38_27B].first { $0.matches(modelID: id) }?.displayName ?? id
    }

    /// Saves a detected server with its suggested models. Search by meaning is not part of setup (keyword search is
    /// the default, as in the model guide): an install that already used it keeps it, only when the server has the model.
    func use(_ server: DiscoveredServer, _ recorder: RecorderModel) async {
        guard usingServer == nil else { return }
        usingServer = server.baseURL
        defer { usingServer = nil }
        let config = server.suggestedConfig()
        let name = server.kind.displayName
        let hadEmbeddings = ModelProviderSettings.load(hasServerConfig: recorder.serverConfig != nil).embeddings == .server
        let hasEmbeddings = hadEmbeddings && !config.embeddingModel.isEmpty
        do {
            _ = try config.validatedEndpoints(embeddingsOnServer: hasEmbeddings)
        } catch {
            modelMessage = String(localized: "\(name) is running, but no model is loaded. Load one, then finish in Settings\u{00A0}→\u{00A0}Models.",
                                  comment: "Setup model step; argument is a server name")
            messageServer = server.baseURL
            return
        }
        let failure = await recorder.setServerConfig(config, embeddingsOnServer: hasEmbeddings)
        guard recorder.serverConfig == config else {
            modelMessage = failure
            messageServer = server.baseURL
            return
        }
        ModelProviderSettings(chat: .server, embeddings: hasEmbeddings ? .server : .none).save()
        await recorder.llm?.configurationChanged()
        modelSetup = .server(name)
        serverSummary = Self.modelName(of: server).map {
            String(localized: "\($0) in \(name)", comment: "Setup: the model and the app that now write minutes; arguments are a model name and an app name")
        } ?? name
        // Saved, but the check found something to fix (for example a model that isn't loaded).
        modelMessage = failure
        messageServer = server.baseURL
    }
}
