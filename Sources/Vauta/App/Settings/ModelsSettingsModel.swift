// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import Observation
import UniformTypeIdentifiers

/// Settings → Models: where the models run, and the server draft. Nothing is
/// saved until "Save"; "Test connection" talks to the draft server without
/// saving it.
@MainActor
@Observable
final class ModelsSettingsModel {
    struct Feedback: Equatable {
        enum Kind { case success, warning, error }
        let kind: Kind
        let text: String
        /// What to do about it, shown under the text in secondary type.
        var note: String?
        /// The note is a value (a pin), shown in a monospaced font.
        var noteIsValue = false
        /// The text is a title over something else on screen (not a note of this label): bold, no final stop.
        var isTitle = false
    }

    var provider: ModelProviderChoice = .onDevice {
        didSet {
            guard provider != oldValue else { return }
            embeddings = provider.embeddings(keeping: embeddings)
            if let mode = provider.serverMode { draft.switchMode(to: mode) }
            testedServer = nil
            testFeedback = nil
        }
    }
    var embeddings: ModelProviderSettings.Embeddings = .none
    var draft = ServerDraft(config: nil)
    /// The server key being typed (never read back from the Keychain).
    var keyDraft = ""

    private(set) var savedSettings = ModelProviderSettings(chat: .onDevice, embeddings: .none)
    private(set) var loaded = false

    private(set) var scanning = false
    /// Servers found on this Mac; nil = not searched yet.
    private(set) var discovered: [DiscoveredServer]?
    private(set) var testing = false
    /// The server the draft points to, as last tested or detected.
    private(set) var testedServer: DiscoveredServer?
    private(set) var testFeedback: Feedback?
    private(set) var applying = false
    private(set) var applyFeedback: Feedback?
    /// The apply bar's result. When the test result in the card already gives the same advice, the bar keeps
    /// only its title, so one explanation is not on screen twice.
    var applyBarFeedback: Feedback? {
        guard var feedback = applyFeedback, let note = feedback.note, note == testFeedback?.note else { return applyFeedback }
        feedback.note = nil
        return feedback
    }
    private(set) var keyFeedback: Feedback?
    private(set) var pinFeedback: Feedback?

    let appleModel = AppleChatModel()
    /// For `Vauta render-ui`: pretends Apple Intelligence is (or is not) available. Nil outside the snapshots.
    var appleAvailableOverride: Bool?
    /// Apple Intelligence can write minutes (and so stand in while the integrated model is not ready).
    var appleAvailable: Bool { appleAvailableOverride ?? (appleModel.availability == .available) }

    /// The "Set up a model server" guide is open (a sheet over Settings → Models).
    var guidePresented = false
    /// The memory the model server recommendation is based on (snapshots set another one).
    var physicalMemory = ProcessInfo.processInfo.physicalMemory

    #if VAUTA_DIAGNOSTICS
    /// For `Vauta render-ui`: the recorder's (sample) saved state, plus the servers "found on this Mac".
    /// `saved` is what was saved before (the sample server by default), so a pane that wasn't edited doesn't look edited.
    func installSnapshotState(_ recorder: RecorderModel, discovered: [DiscoveredServer],
                              saved: ModelProviderSettings = ModelProviderSettings(chat: .server, embeddings: .server)) {
        saved.save()
        revert(recorder)
        self.discovered = discovered
    }

    /// For `Vauta render-ui`: the results shown under Test Connection, Save and the key field, and the server a test reached.
    func installSnapshotScanning() { scanning = true; discovered = nil }

    func installSnapshotFeedback(test: Feedback? = nil, apply: Feedback? = nil, key: Feedback? = nil, tested: DiscoveredServer? = nil,
                                 pins: Feedback? = nil) {
        testFeedback = test
        applyFeedback = apply
        keyFeedback = key
        testedServer = tested
        pinFeedback = pins
    }
    #endif

    // MARK: Loading

    /// Loads the saved state, unless there are unsaved changes.
    func loadIfNeeded(_ recorder: RecorderModel) {
        guard !loaded else { return }
        revert(recorder)
    }

    func revert(_ recorder: RecorderModel) {
        let hasConfig = recorder.serverConfig != nil || recorder.serverConfigUnavailable
        savedSettings = ModelProviderSettings.load(hasServerConfig: hasConfig)
        draft = ServerDraft(config: recorder.serverConfig)
        // Set after the draft: the didSet only switches the draft to the mode the choice needs.
        provider = ModelProviderChoice(settings: savedSettings, serverMode: recorder.serverConfig?.mode)
        embeddings = provider.embeddings(keeping: savedSettings.embeddings)
        keyDraft = ""
        testedServer = nil
        testFeedback = nil
        applyFeedback = nil
        pinFeedback = nil
        loaded = true
    }

    /// The search model was installed or deleted and the controller changed the saved choice: show it, unless the person is
    /// editing that choice (then the edit stays and only the saved copy is refreshed).
    func adoptSavedEmbeddings(_ recorder: RecorderModel) {
        guard loaded else { return }
        let fresh = ModelProviderSettings.load(hasServerConfig: recorder.serverConfig != nil || recorder.serverConfigUnavailable)
        guard fresh.embeddings != savedSettings.embeddings else { return }
        let untouched = embeddings == savedSettings.embeddings
        savedSettings.embeddings = fresh.embeddings
        if untouched { embeddings = provider.embeddings(keeping: fresh.embeddings) }
    }

    /// The integrated model was chosen by a download, an import or "Use for Minutes", and the controller saved the chat choice: show it,
    /// unless the person is editing that choice (then the edit stays and only the saved copy is refreshed). When the model is not
    /// ready, the apply bar says who writes minutes until it is, like the Save that makes the same choice.
    func adoptSavedChat(_ recorder: RecorderModel) {
        guard loaded else { return }
        let fresh = ModelProviderSettings.load(hasServerConfig: recorder.serverConfig != nil || recorder.serverConfigUnavailable)
        guard fresh.chat != savedSettings.chat else { return }
        let before = ModelProviderChoice(settings: savedSettings, serverMode: recorder.serverConfig?.mode)
        let untouched = provider == before && keyDraft.isEmpty
        savedSettings.chat = fresh.chat
        if untouched {
            provider = ModelProviderChoice(settings: fresh, serverMode: recorder.serverConfig?.mode)
            embeddings = provider.embeddings(keeping: savedSettings.embeddings)
            if fresh.chat == .integrated, recorder.integratedModel.status.state != .ready {
                applyFeedback = Feedback(kind: .success, text: IntegratedModelText.appliedFallback(appleAvailable: appleAvailable))
            }
        }
    }

    /// "Use This Mac Instead" (the search model is installed and search used the model server): this one choice is saved at once,
    /// like an install, so the card never says "ready" while the saved choice is still the server. Other edits stay unsaved.
    func useSearchModelHere(_ recorder: RecorderModel) async {
        ModelProviderSettings.saveEmbeddings(.onDeviceModel)
        savedSettings.embeddings = .onDeviceModel
        embeddings = .onDeviceModel
        await recorder.llm?.configurationChanged()
        recorder.documents?.embeddingChoiceChanged()
    }

    /// Forgets unsaved edits when the window closes, so they never look saved later.
    func discardDraft() {
        loaded = false
        keyDraft = ""
        guidePresented = false
    }

    // MARK: State

    var usesServer: Bool { provider == .localServer || provider == .networkServer }

    /// Whether Save will remove the saved key because the draft points to a
    /// different server (mode, address, CA, pins). The key is never sent to a
    /// destination the user didn't enter it for.
    func willClearKey(_ recorder: RecorderModel) -> Bool {
        usesServer && recorder.hasServerKey && !draft.sharesDestination(with: recorder.serverConfig)
            && (recorder.serverConfig != nil || !draft.baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    func hasChanges(_ recorder: RecorderModel) -> Bool {
        if provider.settings(embeddings: embeddings) != savedSettings { return true }
        if usesServer && draft.differs(from: recorder.serverConfig) { return true }
        return !keyDraft.isEmpty
    }

    /// The Keychain was locked when the configuration was read: saving now
    /// could overwrite a configuration Vauta cannot see.
    func serverLocked(_ recorder: RecorderModel) -> Bool { recorder.serverConfigUnavailable }

    /// Models to pick from: the tested server's, or the saved server's list
    /// when the draft still points to it.
    func modelOptions(_ recorder: RecorderModel) -> [DiscoveredModel] {
        if let server = testedServer, Self.sameBase(server.baseURL.absoluteString, draft.baseURL) { return server.models }
        if let saved = recorder.serverConfig, Self.sameBase(saved.baseURL, draft.baseURL) {
            return recorder.llmStatus.models.map { DiscoveredModel(id: $0) }
        }
        return []
    }

    static func sameBase(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while t.hasSuffix("/") { t.removeLast() }
            return t
        }
        return !norm(a).isEmpty && norm(a) == norm(b)
    }

    // MARK: Detection and testing

    func detect() async {
        scanning = true
        discovered = await ServerDiscovery.scanLoopback()
        scanning = false
    }

    /// Uses a detected server: address, request options, models and context.
    func use(_ server: DiscoveredServer) {
        provider = .localServer
        draft.adopt(server)
        testedServer = server
        testFeedback = Self.contextWarning(server, draft) ?? Feedback(kind: .success, text: Self.summary(server))
    }

    /// A chosen model the server loads with less context than Vauta supports: said, never hidden behind a raised value.
    static func contextWarning(_ server: DiscoveredServer, _ draft: ServerDraft) -> Feedback? {
        guard let short = ServerDraft.contextShortfall(server, fast: draft.fastModel, deep: draft.deepModel) else { return nil }
        return Feedback(kind: .warning, text: ModelGuideModel.contextTitle(current: short.context, name: short.model),
                        note: ModelGuideModel.contextDetail(required: LLMServerConfig.contextRange.lowerBound))
    }

    /// Connects to the draft server without saving anything. The saved key is
    /// sent only to the saved server; a typed key is sent to the draft server.
    func testConnection(_ recorder: RecorderModel) async {
        if let invalid = draft.destinationError {
            testFeedback = Feedback(kind: .error, text: invalid.localizedDescription)
            return
        }
        testing = true
        defer { testing = false }
        let typedKey = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let sameServer = draft.sharesDestination(with: recorder.serverConfig)
        let client = LLMClient(config: draft.probeConfig) {
            if !typedKey.isEmpty { return typedKey }
            return sameServer ? try ServerCredentials.sessionBearer() : nil
        }
        defer { client.reset() }
        do {
            let server = try await client.inspect()
            testedServer = server
            if draft.profile == nil && recorder.serverConfig == nil { draft.setKind(server.kind) }
            if let context = ServerDraft.detectedContext(server, fast: draft.fastModel, deep: draft.deepModel) {
                draft.contextTokens = context
            }
            testFeedback = Self.contextWarning(server, draft) ?? Feedback(kind: .success, text: Self.summary(server))
        } catch {
            testedServer = nil
            testFeedback = Self.feedback(for: error)
        }
    }

    /// What happened, then what to do (on its own line) when the error knows.
    /// The pane the user is in is Settings → Models: the generic "check Settings → Models" is replaced by what
    /// can be checked from here.
    static func feedback(for error: Error) -> Feedback {
        let note: String?
        switch error as? LLMError {
        case .unauthorized:
            note = String(localized: "Check the key in the model server app, or leave it empty for LM Studio and Ollama.",
                          comment: "Settings → Models; what to do after the server rejected the key")
        case .invalidStoredToken:
            note = String(localized: "Type a new key to replace the saved one.", comment: "Settings → Models key help when a key is saved")
        case .notConfigured:
            note = nil
        default:
            note = (error as? LocalizedError)?.recoverySuggestion
        }
        return Feedback(kind: .error, text: error.localizedDescription, note: note)
    }

    /// Whether search by meaning runs on the server with the current choices.
    var embeddingsOnServer: Bool { provider.settings(embeddings: embeddings).embeddings == .server }

    static func summary(_ server: DiscoveredServer) -> String {
        let name = server.kind.displayName
        let count = server.models.count
        return String(localized: "Connected to \(name). It offers \(count) models.",
                      comment: "Model server test result; arguments are the server name and a model count")
    }

    // MARK: Saving

    func apply(_ recorder: RecorderModel) async {
        applyFeedback = nil
        if usesServer {
            guard !serverLocked(recorder) else { return }
            if let invalid = draft.validationError(embeddingsOnServer: embeddingsOnServer) {
                applyFeedback = Feedback(kind: .error, text: invalid.localizedDescription)
                return
            }
        }
        applying = true
        defer { applying = false }
        // The server first, then the key: the last check then uses both.
        var result: String?
        var clearedKey = false
        if usesServer && draft.differs(from: recorder.serverConfig) {
            let wanted = draft.config
            let previousBase = recorder.serverConfig?.baseURL
            // A new destination never receives the saved key, not even in the
            // check that follows saving: remove it first.
            if willClearKey(recorder) {
                try? ServerCredentials.saveBearer(nil)
                recorder.hasServerKey = false
                clearedKey = true
            }
            result = await recorder.setServerConfig(wanted, embeddingsOnServer: embeddingsOnServer)
            guard recorder.serverConfig == wanted else {
                applyFeedback = Feedback(kind: .error, text: result ?? String(localized: "Couldn’t save the server settings.",
                                                                              comment: "Settings → Models apply error"))
                return
            }
            draft = ServerDraft(config: wanted)
            // A translation model picked on another server would fail on this one: back to its fast model.
            if let previousBase, !Self.sameBase(previousBase, wanted.baseURL) { recorder.preferences.translationModel = "" }
        }
        var didSetKey = false
        if !keyDraft.isEmpty {
            let typed = keyDraft
            keyDraft = ""
            didSetKey = true
            result = await recorder.setServerKey(typed)
        }
        let settings = provider.settings(embeddings: embeddings)
        settings.save()
        savedSettings = settings
        await recorder.llm?.configurationChanged()
        if usesServer { await recorder.checkServer() }
        if clearedKey && keyDraft.isEmpty && !didSetKey {
            let notice = String(localized: "The server changed, so its saved key was removed. Enter the key for the new server.",
                                comment: "Settings → Models; shown after the server address or trust changed")
            applyFeedback = Feedback(kind: .warning, text: [notice, result].compactMap { $0 }.joinedAsSentences())
            return
        }
        applyFeedback = result.map { Self.warning(for: $0) }
            ?? Feedback(kind: .success, text: provider == .integrated && recorder.integratedModel.status.state != .ready
                        ? IntegratedModelText.appliedFallback(appleAvailable: appleAvailable)
                        : String(localized: "Saved.", comment: "Settings → Models apply result"))
    }

    /// A warning after saving. A rejected key says that the settings were saved and what to check, since the bar
    /// has no other control for it (and the test result above already says the same thing without that).
    static func warning(for text: String) -> Feedback {
        guard text == LLMError.unauthorized.localizedDescription else { return Feedback(kind: .warning, text: text) }
        return Feedback(kind: .warning,
                        text: String(localized: "Saved, but the model server rejected the key.",
                                     comment: "Settings → Models; the settings were applied, but the server refused the key"),
                        note: String(localized: "Check the key in the model server app, or leave it empty for LM Studio and Ollama.",
                                     comment: "Settings → Models; what to do after the server rejected the key"))
    }

    /// Deletes the saved server and its key (the on-device model stays available).
    func forgetServer(_ recorder: RecorderModel) async {
        let failure = await recorder.setServerConfig(nil)
        guard recorder.serverConfig == nil else {
            applyFeedback = Feedback(kind: .error, text: failure ?? String(localized: "Couldn’t remove the server settings.",
                                                                           comment: "Settings → Models remove error"))
            return
        }
        _ = await recorder.setServerKey(nil)
        if savedSettings.chat == .server || savedSettings.embeddings == .server {
            ModelProviderSettings(chat: .onDevice, embeddings: .none).save()
            await recorder.llm?.configurationChanged()
        }
        loaded = false
        revert(recorder)
        applyFeedback = Feedback(kind: .success, text: String(localized: "The server and its key were removed.",
                                                              comment: "Settings → Models result"))
    }

    func deleteKey(_ recorder: RecorderModel) async {
        keyDraft = ""
        let failure = await recorder.setServerKey(nil)
        keyFeedback = failure.map { Feedback(kind: .warning, text: $0) }
            ?? Feedback(kind: .success, text: String(localized: "The key was removed from the Keychain.", comment: "Settings → Models result"))
    }

    /// Reads a CA certificate file chosen by the user into the draft.
    func importCA() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "pem"), UTType(filenameExtension: "crt"), .x509Certificate]
            .compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose the private certificate authority of your model server (PEM).", comment: "Open panel message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), data.count < 1 << 20, let text = String(data: data, encoding: .utf8),
              text.contains("-----BEGIN CERTIFICATE-----") else {
            applyFeedback = Feedback(kind: .error, text: String(localized: "That file isn’t a PEM certificate.",
                                                                comment: "Settings → Models CA import error"))
            return
        }
        draft.caPEM = text
    }

    /// Adds the pin of the server's certificate, read from a file the user chooses.
    func addPinFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "pem"), UTType(filenameExtension: "crt"), .x509Certificate]
            .compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose the server’s certificate (PEM).", comment: "Open panel message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), data.count < 1 << 20, let text = String(data: data, encoding: .utf8) else {
            pinFeedback = Feedback(kind: .error, text: Self.notACertificate)
            return
        }
        addPin(fromPEM: text)
    }

    /// Adds the pin of a server certificate pasted from the clipboard.
    func addPinFromClipboard() {
        addPin(fromPEM: NSPasteboard.general.string(forType: .string) ?? "")
    }

    private func addPin(fromPEM text: String) {
        if draft.addPin(fromCertificatePEM: text) != nil {
            pinFeedback = Feedback(kind: .success, text: String(localized: "Pin added.", comment: "Settings → Models; the pin itself is in the field above"))
        } else {
            pinFeedback = Feedback(kind: .error, text: Self.notACertificate)
        }
    }

    private static var notACertificate: String {
        String(localized: "That isn’t a PEM certificate (-----BEGIN CERTIFICATE-----…).", comment: "Settings → Models pin error")
    }

    /// Loads a configuration (JSON, never the key) from the clipboard into the
    /// draft. Nothing is saved.
    func importFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let config = try? JSONDecoder().decode(LLMServerConfig.self, from: Data(text.utf8)) else {
            applyFeedback = Feedback(kind: .error, text: String(localized: "The clipboard doesn’t contain a Vauta server configuration.",
                                                                comment: "Settings → Models import error"))
            return
        }
        provider = config.mode == .remote ? .networkServer : .localServer
        draft = ServerDraft(config: config)
        applyFeedback = Feedback(kind: .warning, text: String(localized: "Configuration loaded. Review it, then click Save.",
                                                              comment: "Settings → Models import result"))
    }
}
