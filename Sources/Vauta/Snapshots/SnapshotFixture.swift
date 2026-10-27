// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import Foundation

/// Everything the scenes share: a sample store, private preferences and
/// recorders built on them. Nothing here reads the real store or the Keychain.
@MainActor
final class SnapshotFixture {
    let language: String
    let world: SampleWorld
    let preferences: Preferences
    let settings = SettingsModel()
    private let base: String
    private let suite: String
    /// The fixture's own preferences suite, also used for the views' `@AppStorage`.
    let appDefaults: UserDefaults
    private var scratchSuites: [String] = []

    init(language: String, world: SampleWorld) {
        self.language = language
        self.world = world
        // Fixed names under the render's own bundle ID: macOS keeps the file of an emptied
        // domain, so new names on every run would leave one more file behind each time.
        base = Bundle.main.bundleIdentifier ?? "local.vauta.snapshots"
        suite = "\(base).fixture"
        appDefaults = UserDefaults(suiteName: suite) ?? .standard
        appDefaults.removePersistentDomain(forName: suite)
        preferences = Preferences(defaults: appDefaults, legacyInstall: false)
        preferences.copyProtection = false
        preferences.onboardingCompletedVersion = Preferences.currentOnboardingVersion
        preferences.transcriptionLanguage = world.locale.identifier(.bcp47)
        SnapshotMode.catalog = SampleWorld.speechCatalog(rendering: world.locale.identifier(.bcp47))
        SnapshotMode.reservedLanguages = SampleWorld.installedSpeechIDs(rendering: world.locale.identifier(.bcp47))
    }

    var content: SampleContent { world.content }

    /// Preferences of their own, for a scene that changes settings (removed with the fixture).
    func makeScratchPreferences() -> Preferences {
        let name = "\(base).scratch\(scratchSuites.count + 1)"
        scratchSuites.append(name)
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return Preferences(defaults: defaults, legacyInstall: false)
    }

    func cleanUp() {
        for name in scratchSuites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        SnapshotMode.catalog = nil
    }

    /// A recorder on the sample store, idle, as after a normal launch.
    func makeRecorder() async -> RecorderModel {
        // A scene that made its own language missing gives it back to the next one.
        SnapshotMode.catalog = SampleWorld.speechCatalog(rendering: world.locale.identifier(.bcp47))
        preferences.transcriptionLanguage = world.locale.identifier(.bcp47)
        // The same on every Mac: a Mac that has recorded these meetings has the microphone allowed. The scenes about a permission problem
        // (or a login item that needs approval) set their own state; none depends on the render Mac's real permissions.
        SnapshotMode.microphone = .granted
        SnapshotMode.notifications = .granted
        SnapshotMode.loginItem = .notRegistered
        SnapshotMode.voiceOver = nil
        SnapshotMode.languagesLoading = false
        SnapshotMode.consentExpanded = false
        SnapshotMode.storeBytes = 21_504
        // The hidden-icon banner belongs to its own scene; it must not carry over to the next General scene.
        settings.menuBarIconMayBeHidden = false
        settings.speech.installSnapshotState(downloading: nil, progress: 0)
        let recorder = RecorderModel(snapshotPreferences: preferences, store: world.store)
        recorder.speechCatalog = SnapshotMode.catalog
        recorder.serverConfig = Self.serverConfig
        recorder.llmStatus = Self.modelStatus
        return recorder
    }

    /// LM Studio on this Mac, matching `modelStatus` (so Status and Models agree with the panel).
    private static var serverConfig: LLMServerConfig {
        LLMServerConfig(mode: .local, baseURL: "http://127.0.0.1:1234/v1", fastModel: "qwen3-30b-a3b-instruct",
                        deepModel: "qwen3-30b-a3b-instruct", embeddingModel: "text-embedding-nomic-embed-text-v1.5",
                        profile: .defaults(for: .lmStudio))
    }

    /// A model server answering normally.
    private static var modelStatus: LLMService.Status {
        var status = LLMService.Status()
        status.configured = true
        status.serverConfigured = true
        status.chatProvider = .server
        status.embeddingsProvider = .server
        status.reachable = true
        status.queued = 0
        status.models = ["qwen3-30b-a3b-instruct", "text-embedding-nomic-embed-text-v1.5"]
        return status
    }
}
#endif
