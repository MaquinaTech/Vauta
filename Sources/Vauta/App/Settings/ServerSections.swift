// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// The model server form: address and trust, key, models and advanced options.
struct ServerSections: View {
    @Bindable var recorder: RecorderModel
    @Bindable var models: ModelsSettingsModel
    @ViewLocalState private var confirmForget = false
    @ViewLocalState private var confirmRemoveKey = false

    private var local: Bool { models.provider == .localServer }

    var body: some View {
        if models.serverLocked(recorder) {
            Section {
                Label(String(localized: "The Keychain is locked, so Vauta can’t read the model server settings. Unlock your Mac, then try again.",
                             comment: "Settings → Models"), systemImage: "lock.fill")
                // ModelsPane reloads the draft once the configuration can be read.
                Button("Try Again") {
                    recorder.retryServerConfigIfUnavailable()
                    if recorder.serverConfigUnavailable { Task { await recorder.checkServer() } }
                }
            }
        }
        if local { detectSection }
        serverSection
        modelsSection
        advancedSection
    }

    // MARK: Detection

    private var detectSection: some View {
        Section {
            // The result first, then the guide for a Mac with nothing running.
            if let found = models.discovered {
                if found.isEmpty {
                    NoticeLabel(Text("No server found. Open LM Studio, Ollama, llama.cpp, MLX, vLLM, Jan or LocalAI, start its server, then search again.",
                                     comment: "Settings → Models detection empty state"), status: .info)
                }
                ForEach(found, id: \.baseURL) { server in
                    LabeledContent {
                        // Two separate facts: the saved server (what Vauta uses now) and the one the address field points to.
                        let address = server.baseURL.absoluteString
                        let saved = recorder.serverConfig.map { Self.sameAddress(address, $0.baseURL) } ?? false
                        let pending = !saved && Self.sameAddress(address, models.draft.baseURL)
                        if saved {
                            TrailingStatus(text: Text("In use", comment: "Settings → Models; the detected server that is the current address")) {
                                StatusSymbol.ok.image
                            }
                        } else if pending {
                            TrailingStatus(text: Text("Selected, not saved", comment: "Settings → Models; the detected server the address field points to, before Save")) {
                                StatusSymbol.info.image
                            }
                        } else {
                            Button("Use") { models.use(server) }
                        }
                    } label: {
                        Text(server.kind.displayName)
                        Text(description: Self.describe(server))
                    }
                }
            }
            if models.discovered?.isEmpty ?? true {
                // Nothing running yet: this is the user the setup guide is for.
                LabeledContent {
                    Button("Set Up a Model Server…") { models.guidePresented = true }
                } label: {
                    Text("No server yet?")
                    Text(description: String(localized: "Install LM Studio or Ollama, and Vauta shows you the model that fits this Mac."))
                }
            }
        } header: {
            SectionHeaderWithAction {
                Text("Servers on this Mac", comment: "Settings → Models section: the button that looks for model servers")
            } action: {
                // The button already says “Searching…”.
                if models.scanning { ProgressView().controlSize(.small).accessibilityHidden(true) }
                // In the header, after the results it refreshes: like Status → Check Again.
                Button(models.scanning ? String(localized: "Searching…", comment: "Detect servers button while busy")
                                       : models.discovered != nil
                                           ? String(localized: "Search Again", comment: "Detect servers button after a search")
                                           : String(localized: "Find Model Servers", comment: "Detect servers button before the first search; the section title says where")) {
                    Task { await models.detect() }
                }
                .disabled(models.scanning)
            }
        }
    }

    /// Whether two server addresses are the same one (a trailing slash or letter case doesn't make another server).
    static func sameAddress(_ a: String, _ b: String) -> Bool {
        func normalized(_ text: String) -> String {
            var t = text.trimmingCharacters(in: .whitespaces).lowercased()
            while t.hasSuffix("/") { t.removeLast() }
            // localhost, 127.0.0.1 and ::1 are this Mac: one server whichever way the address spells it.
            for alias in ["//localhost", "//[::1]", "//::1"] { t = t.replacingOccurrences(of: alias, with: "//127.0.0.1") }
            return t
        }
        let left = normalized(a)
        return !left.isEmpty && left == normalized(b)
    }

    static func describe(_ server: DiscoveredServer) -> String {
        let address = server.baseURL.absoluteString
        let chats = server.models.filter { $0.kind != .embedding }.count
        let embeddings = server.models.filter { $0.kind == .embedding }.count
        return String(localized: "\(address) · \(chats) chat models, \(embeddings) for search by meaning",
                      comment: "Detected server; arguments are the address and two model counts")
    }

    // MARK: Address, trust and key

    private var serverSection: some View {
        Section {
            Noted(local
                ? String(localized: "The address up to /v1. Only 127.0.0.1, ::1 or localhost are accepted. Set the server to listen on 127.0.0.1 only.",
                         comment: "Settings → Models local address help")
                : String(localized: "The address up to /v1, with https://. Use a local network address (192.168.x, 10.x, 172.16–31.x, Tailscale, *.local…), or add a private certificate authority or pin for other names.",
                         comment: "Settings → Models network address help")) {
                LabeledContent(String(localized: "Address", comment: "Server base URL field")) {
                    TrailingField(title: String(localized: "Address", comment: "Server base URL field"), text: $models.draft.baseURL,
                                  placeholder: local ? LLMServerConfig.lmStudio.baseURL : LLMServerConfig.remoteTemplate.baseURL)
                        .autocorrectionDisabled()
                }
            }
            if !local {
                // Right under the address it is about.
                ForEach(Array(models.draft.config.securityWarnings.enumerated()), id: \.offset) { _, warning in
                    NoticeLabel(Text(verbatim: warning.message), status: .warning)
                }
                trustRows
            }

            let replacing = models.willClearKey(recorder)
            // The saved key belongs to the saved server: for a new destination the field starts empty.
            let keySaved = recorder.hasServerKey && !replacing
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent(String(localized: "Key (optional)", comment: "Server API key field")) {
                    TrailingField(title: String(localized: "Key (optional)", comment: "Server API key field"), text: $models.keyDraft,
                                  placeholder: keySaved
                                      ? String(localized: "Saved in the Keychain", comment: "Key field placeholder when a key is saved")
                                      : replacing
                                          ? String(localized: "Key for the new server", comment: "Key field placeholder after the server address was edited")
                                          : String(localized: "No key", comment: "Key field placeholder when there is no key"),
                                  secure: true)
                }
                SettingsNote(keyNote(saved: keySaved, replacing: replacing))
            }
            // One message about the key at a time: a result replaces the notice.
            if let feedback = models.keyFeedback {
                FeedbackLabel(feedback: feedback)
            } else if replacing {
                NoticeLabel(Text("The saved key won’t be sent to a different server.",
                                 comment: "Settings → Models; shown when the server address or trust was edited"),
                            status: .info)
            }

            HStack {
                Button(String(localized: "Test Connection", comment: "Settings → Models")) { Task { await models.testConnection(recorder) } }
                    .disabled(models.testing || models.draft.baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
                if models.testing { ProgressView().controlSize(.small).accessibilityLabel(String(localized: "Testing…", comment: "Accessibility label of the spinner while the connection is tested")) }
                Spacer()
                // Both removals together, on the action row: no control stands alone under a field.
                if keySaved {
                    Button("Remove Key…", role: .destructive) { confirmRemoveKey = true }
                        .confirmationDialog(String(localized: "Remove the saved key?", comment: "Confirmation title"), isPresented: $confirmRemoveKey) {
                            Button("Remove Key", role: .destructive) { Task { await models.deleteKey(recorder) } }
                            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
                        } message: {
                            Text("Vauta will stop sending a key to the server until you enter one again.")
                        }
                }
                if recorder.serverConfig != nil {
                    Button("Remove Server…", role: .destructive) { confirmForget = true }
                }
            }
            if let feedback = models.testFeedback { FeedbackLabel(feedback: feedback) }
        } header: {
            Text("Server")
        } footer: {
            // The info row above already says the saved key stays with the saved server.
            SettingsNote(models.willClearKey(recorder)
                ? String(localized: "Testing doesn’t save anything.", comment: "Settings → Models test help while the server was edited")
                : String(localized: "Testing doesn’t save anything. The saved key is only sent to the saved server.",
                         comment: "Settings → Models test help"))
        }
        .confirmationDialog(String(localized: "Remove the model server?", comment: "Confirmation title"), isPresented: $confirmForget) {
            Button("Remove Server", role: .destructive) { Task { await models.forgetServer(recorder) } }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: {
            Text("Vauta forgets the server address, models and key. Minutes will use Apple Intelligence on this Mac until you set up a server again.")
        }
    }

    /// What the key field is for; with a saved key, how to replace it.
    private func keyNote(saved: Bool, replacing: Bool) -> String {
        if replacing {
            return String(localized: "Enter the key for this server, if it needs one.", comment: "Settings → Models key help after the server address was edited")
        }
        if saved {
            return String(localized: "Type a new key to replace the saved one.", comment: "Settings → Models key help when a key is saved")
        }
        return local
            ? String(localized: "LM Studio and Ollama on this Mac don’t need one.", comment: "Settings → Models key help for a server on this Mac")
            : String(localized: "Use a key that only Vauta uses, so you can revoke it on its own.", comment: "Settings → Models key help for a server on the network")
    }

    @ViewBuilder
    private var trustRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Private certificate authority (optional)")
                Spacer()
                Button("Import…") { models.importCA() }
                if !models.draft.caPEM.isEmpty {
                    Button("Clear") { models.draft.caPEM = "" }
                }
            }
            TextEditor(text: $models.draft.caPEM)
                // Only the pasted PEM text is monospaced; the placeholder is a sentence-sized callout like the pins field's.
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .padding(4)
                .frame(height: 80)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .overlay(alignment: .topLeading) {
                    if models.draft.caPEM.isEmpty {
                        Text(verbatim: "-----BEGIN CERTIFICATE-----")
                            .font(.callout)
                            .foregroundStyle(Color(nsColor: .placeholderTextColor))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel(String(localized: "Private certificate authority in PEM format", comment: "Accessibility label"))
            SettingsNote(String(localized: "Paste the certificate (PEM text) of the authority that signed your server’s certificate. When set, Vauta trusts only that authority.",
                                comment: "Settings → Models CA help"))
        }
        // Like the CA above: the label, a field as wide as the card, then its note straight under it.
        VStack(alignment: .leading, spacing: 6) {
            Text("Certificate pins (optional)", comment: "Server pins field")
            ZStack(alignment: .leading) {
                TextField(String(localized: "Certificate pins (optional)", comment: "Server pins field"), text: $models.draft.pins)
                    .labelsHidden()
                // The system prompt is drawn like entered text in grouped forms: overlaid like the CA editor's.
                if models.draft.pins.isEmpty {
                    Text("Paste a pin, or compute one below", comment: "Settings → Models; placeholder of the certificate pins field")
                        // A sentence, not a value: the system font; only typed text is monospaced.
                        .font(.callout)
                        .foregroundStyle(Color(nsColor: .placeholderTextColor))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .font(.system(.callout, design: .monospaced))
            .textFieldStyle(.plain)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            .autocorrectionDisabled()
            .help(String(localized: "Each pin is the SHA-256 hash of the certificate’s public key (SPKI), in base64.", comment: "Settings → Models; help of the certificate pins field"))
            SettingsNote(String(localized: "Pins fix the exact server certificate. Separate several with commas.",
                                comment: "Settings → Models pins help"))
        }
        HStack {
            Text("Compute a pin from the server’s certificate")
            Spacer()
            Button("Choose File…") { models.addPinFromFile() }
            Button("Paste Certificate") { models.addPinFromClipboard() }
        }
        if let feedback = models.pinFeedback { FeedbackLabel(feedback: feedback) }
    }

    // MARK: Models

    private var modelsSection: some View {
        let options = models.modelOptions(recorder)
        return Section {
            ModelField(title: String(localized: "Fast model", comment: "Model role"),
                       help: String(localized: "Writes live notes while you record. A small, quick model works best; it can be the same as the main model.", comment: "Model role help"),
                       text: $models.draft.fastModel, options: options.filter { $0.kind != .embedding })
            ModelField(title: String(localized: "Main model", comment: "Model role"),
                       help: String(localized: "Writes the minutes and answers Ask. Use the best model this computer can run.", comment: "Model role help"),
                       text: $models.draft.deepModel, options: options.filter { $0.kind != .embedding })
            if models.embeddings == .server {
                ModelField(title: String(localized: "Model for search by meaning", comment: "Model role: the embedding model"),
                           help: String(localized: "Finds the passages Ask needs. Use a multilingual model made for search, such as nomic‑embed‑text or Qwen3‑Embedding.", comment: "Model role help"),
                           text: $models.draft.embeddingModel, options: options.filter { $0.kind != .chat })
            }
            Picker(selection: $models.draft.contextTokens) {
                ForEach(models.draft.contextChoices, id: \.self) { tokens in
                    Text("\(tokens / 1024)K tokens").tag(tokens)
                }
            } label: {
                Text("Context length", comment: "Settings → Models")
                Text(description: String(localized: "The context length the server loads the chat models with. Filled in from the server when it reports it.",
                     comment: "Settings → Models context help"))
            }
            if options.isEmpty && models.testFeedback?.kind != .success {
                SettingsNote(hasModelNames
                    ? String(localized: "These names haven’t been checked on this server. Test the connection to choose from its models.", comment: "Settings → Models; the typed model names were not checked against this server")
                    : String(localized: "Test the connection to choose from the server’s models.", comment: "Settings → Models empty model list"))
            }
            if !recorder.llmStatus.missingModels.isEmpty && !models.draft.differs(from: recorder.serverConfig) {
                let missing = recorder.llmStatus.missingModels.joined(separator: ", ")
                NoticeLabel(Text("The server doesn’t list: \(missing)", comment: "Settings → Models; argument is a list of model names"), status: .warning)
            }
        } header: {
            Text("Models")
        }
    }

    private var hasModelNames: Bool {
        ![models.draft.fastModel, models.draft.deepModel].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: Advanced

    private var advancedSection: some View {
        Section {
            DisclosureGroup(String(localized: "Advanced", comment: "Settings → Models disclosure")) {
                Picker(String(localized: "Server type", comment: "Settings → Models advanced"),
                       selection: Binding(get: { models.draft.profile?.kind }, set: { models.draft.setKind($0) })) {
                    Text("Original format (version 0.1)", comment: "Settings → Models advanced: the server type that sends requests as version 0.1 did").tag(ServerKind?.none)
                    Divider()
                    ForEach(ServerKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(Optional(kind))
                    }
                }
                if models.draft.profile != nil {
                    Picker(String(localized: "Thinking control", comment: "Settings → Models advanced"),
                           selection: Binding(get: { models.draft.profile?.thinking ?? .none }, set: { models.draft.profile?.thinking = $0 })) {
                        ForEach(ThinkingControl.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Picker(String(localized: "Sampling", comment: "Settings → Models advanced"), selection: $models.draft.sampling) {
                        Text("Server default").tag(SamplingChoice.serverDefault)
                        Text("Qwen recommended (0.7 / 0.8 / 20)").tag(SamplingChoice.qwenRecommended)
                        if models.draft.sampling == .custom {
                            Text("Custom (from the configuration)").tag(SamplingChoice.custom)
                        }
                    }
                    Picker(String(localized: "Structured output", comment: "Settings → Models advanced"),
                           selection: Binding(get: { models.draft.profile?.structuredOutput ?? .none },
                                              set: { models.draft.profile?.structuredOutput = $0 })) {
                        ForEach(StructuredOutputSupport.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    SettingsNote(String(localized: "Choosing a server type sets the usual options for it. Change them only if the server rejects requests or the model keeps “thinking”.",
                                        comment: "Settings → Models advanced help"))
                } else {
                    SettingsNote(String(localized: "Requests are sent in the original format of version 0.1. Choose the server type to use its own options.",
                                        comment: "Settings → Models advanced help"))
                }
                HStack {
                    Spacer()
                    Button("Paste Configuration") { models.importFromClipboard() }
                        .help(String(localized: "Load a server configuration (JSON) from the clipboard, for a setup prepared by someone else. The key is never included.",
                                     comment: "Settings → Models import help"))
                }
            }
        }
    }
}

/// A model name with a menu of the server's models.
private struct ModelField: View {
    let title: String
    let help: String
    @Binding var text: String
    let options: [DiscoveredModel]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                // The same field as Address and Key; the server's models, when known, are a menu inside its trailing edge.
                TrailingField(title: title, text: $text, placeholder: String(localized: "Exact name the server lists", comment: "Model name field placeholder"))
                    .autocorrectionDisabled()
                    .overlay(alignment: .trailing) {
                        if !options.isEmpty {
                            // The system popup's indicator (a circled chevron): the circle is drawn behind the menu
                            // because a menu's label is flattened to a template image.
                            ZStack {
                                Circle().fill(Color.primary.opacity(0.1))
                                Menu {
                                    ForEach(options) { model in
                                        Button(Self.label(model)) { text = model.id }
                                    }
                                } label: {
                                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .help(String(localized: "Choose from the server’s models", comment: "Model menu help"))
                                .accessibilityLabel(String(localized: "Choose \(title)", comment: "Accessibility label; argument is a model role"))
                            }
                            .frame(width: 16, height: 16)
                            .padding(.trailing, 5)
                        }
                    }
            }
            SettingsNote(help)
        }
    }

    static func label(_ model: DiscoveredModel) -> String {
        var parts = [model.id]
        if model.kind == .embedding { parts.append(String(localized: "search by meaning", comment: "Model kind tag in a menu")) }
        if let context = model.contextLength { parts.append(String(localized: "\(context / 1024)K tokens", comment: "Token count")) }
        if model.loaded == true { parts.append(String(localized: "loaded", comment: "Model state tag in a menu")) }
        return parts.joined(separator: " · ")
    }
}

extension ThinkingControl {
    var displayName: String {
        switch self {
        case .rootEnableThinking: String(localized: "enable_thinking at the root", comment: "Thinking control option (technical)")
        case .chatTemplateKwargs: "chat_template_kwargs"
        case .reasoningEffort: "reasoning_effort"
        case .ollamaThink: "Ollama think"
        case .none: String(localized: "Don’t send", comment: "Thinking control option")
        }
    }
}

extension StructuredOutputSupport {
    var displayName: String {
        switch self {
        case .jsonSchema: String(localized: "JSON schema", comment: "Structured output option")
        case .jsonObject: String(localized: "JSON object", comment: "Structured output option")
        case .none: String(localized: "Off", comment: "Structured output option")
        }
    }
}

extension LLMServerConfig.SecurityWarning {
    var message: String {
        switch self {
        case .hostNameWithoutPinnedTrust(let host):
            String(localized: "“\(host)” is a name that could point outside your network. Add the server’s private certificate authority or a certificate pin.",
                   comment: "Server security warning; argument is a host name")
        }
    }
}

/// A control with its explanation underneath, in one form row (no divider between them).
struct Noted<Content: View>: View {
    let note: String
    @ViewBuilder let content: Content

    init(_ note: String, @ViewBuilder content: () -> Content) {
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
            SettingsNote(note)
        }
    }
}
