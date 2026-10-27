// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Synchronization

/// Why a model provider cannot be used right now, shown in the status
/// instead of failing silently.
public enum ProviderIssue: Sendable, Equatable {
    /// The chosen provider is a model server and none is set up.
    case serverNotConfigured
    /// The Keychain is locked, so the server settings cannot be read yet.
    case keychainLocked
    /// Apple's on-device model cannot run (the reason says why).
    case onDeviceModel(AppleChatModel.Availability)
    /// Search by meaning on this Mac is chosen but the search model is not installed.
    case searchModelNotInstalled
    /// The search model is installed but cannot be used (see the reason).
    case searchModelUnavailable(SearchModelUnavailableReason)
    /// The integrated model is chosen but cannot be used, and neither can Apple's.
    case integratedModel(IntegratedModelIssue)

    public var localizedDescription: String {
        switch self {
        case .serverNotConfigured:
            String(localized: "No model chosen", comment: "Model provider status: neither Apple Intelligence nor a model server is set up")
        case .keychainLocked:
            String(localized: "The Keychain is locked, so Vauta can’t read the model server settings. Unlock your Mac, then try again.", comment: "Model provider status")
        case .onDeviceModel(.deviceNotEligible):
            String(localized: "This Mac can’t run Apple Intelligence.", comment: "Model provider status")
        case .onDeviceModel(.appleIntelligenceNotEnabled):
            String(localized: "Apple Intelligence is turned off.", comment: "Model provider status")
        case .onDeviceModel(.modelNotReady):
            String(localized: "Apple Intelligence is still downloading.", comment: "Model provider status")
        case .onDeviceModel:
            String(localized: "Apple Intelligence isn’t available right now.", comment: "Model provider status")
        case .searchModelNotInstalled:
            String(localized: "The search model isn’t installed.", comment: "Model provider status: search by meaning on this Mac is chosen but its model was not downloaded")
        case .searchModelUnavailable:
            String(localized: "The search model can’t run on this Mac.", comment: "Model provider status: the downloaded search model cannot be used")
        case .integratedModel(.damaged):
            String(localized: "The integrated model files are damaged.", comment: "Model provider status: the integrated model’s files no longer match what Vauta pinned")
        case .integratedModel(.unsupported):
            String(localized: "The integrated model can’t run on this Mac.", comment: "Model provider status: this Mac cannot run the integrated model")
        case .integratedModel(.notReady):
            String(localized: "The integrated model isn’t ready.", comment: "Model provider status: the integrated model is chosen but not downloaded or still downloading")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .serverNotConfigured:
            String(localized: "Set up a model server for better minutes, or choose “Apple Intelligence on this Mac”.", comment: "Model provider recovery")
        case .keychainLocked:
            String(localized: "Unlock your Mac; Vauta will try again.", comment: "Model error recovery")
        case .onDeviceModel(.appleIntelligenceNotEnabled):
            String(localized: "Turn on Apple Intelligence in System Settings, or choose a model server in Settings\u{00A0}→\u{00A0}Models.",
                   comment: "Model provider recovery")
        case .onDeviceModel(.modelNotReady):
            String(localized: "Vauta will use it as soon as the download finishes.", comment: "Model provider recovery")
        case .onDeviceModel:
            String(localized: "Choose a model server in Settings\u{00A0}→\u{00A0}Models.", comment: "Model provider recovery")
        case .searchModelNotInstalled:
            String(localized: "Download it in Settings\u{00A0}→\u{00A0}Models, or choose keyword search.", comment: "Model provider recovery")
        case .searchModelUnavailable:
            String(localized: "Ask uses keyword search instead.", comment: "Model provider recovery")
        case .integratedModel(.damaged):
            String(localized: "Repair it in Settings\u{00A0}→\u{00A0}Models.", comment: "Model provider recovery")
        case .integratedModel(.unsupported):
            String(localized: "Choose Apple Intelligence or a model server in Settings\u{00A0}→\u{00A0}Models.", comment: "Model provider recovery")
        case .integratedModel(.notReady):
            String(localized: "Download it in Settings\u{00A0}→\u{00A0}Models, or choose another provider.", comment: "Model provider recovery")
        }
    }
}

/// Why the integrated model is not what answers right now.
public enum IntegratedModelIssue: Sendable, Equatable {
    /// Not downloaded, or the download is not finished.
    case notReady
    /// Its files no longer match what Vauta pinned.
    case damaged
    /// This Mac cannot run it.
    case unsupported
}

/// What a chat request is for: live work during a recording (notes, answers about the meeting in progress) or everything else.
enum ChatTask: Sendable { case live, main }

/// The chat model to use now, with what the service needs to size requests.
struct ChatProvider: Sendable {
    let model: any ChatModel
    let contextTokens: Int
    /// Runs on this Mac (a single model; no fast/deep roles, no reasoning switch).
    let onDevice: Bool
    /// Whether the model can write `locale` (nil = assume it can).
    let supports: (@Sendable (Locale) -> Bool)?
    /// The model is the integrated Gemma 4 (it reads a grammar and keeps a warm prefix).
    var integrated = false
    /// The person chose the integrated model but it is not usable now: this provider (Apple's) stands in, and the status says why.
    var fallbackReason: IntegratedModelIssue?
    /// Apple's on-device model, or any other small-window model that stands in for it: the backends the harness phase measured besides the
    /// integrated one. A model server is neither, and keeps the minutes, live notes and Ask it had.
    var measuredSmallWindow: Bool { onDevice && !integrated && contextTokens < 12_000 }
    /// Whether the harness phase measured this backend (Apple's model or the integrated one).
    var releasedHarness: Bool { integrated || measuredSmallWindow }
}

/// Where embeddings come from now.
enum EmbeddingProvider: Sendable {
    /// Keyword search only (chosen in Settings).
    case disabled
    case unavailable(ProviderIssue)
    /// `model(language)` gives the model for text in a language (nil when
    /// none exists); `expectedModel(language)` the `chunks.model` its vectors
    /// are stored under, to detect meetings embedded in another space.
    case available(model: @Sendable (Locale.Language) -> (any EmbeddingModel)?,
                   expectedModel: @Sendable (Locale.Language) -> String?)
}

/// Resolves the providers chosen in Settings. Tests supply their own.
protocol ModelProviding: Sendable {
    /// Reads the settings again (server config, provider choice).
    func reload() -> ProviderIssue?
    var settings: ModelProviderSettings { get }
    /// The chat model, or why there is none.
    func chat() -> Result<ChatProvider, ProviderUnavailable>
    /// The chat model for one kind of work: with the integrated model chosen, live work can go to Apple's (Settings → Models).
    func chat(for task: ChatTask) -> Result<ChatProvider, ProviderUnavailable>
    func embeddings() -> EmbeddingProvider
    /// The configured model server, if any (to check its models).
    var server: (client: LLMClient, config: LLMServerConfig)? { get }
    /// The configured model server as a chat model for live-translation refinement, if any.
    var refinementChat: (any ChatModel)? { get }
    /// The embedding model runs on another computer of the network, so what is embedded leaves this Mac.
    var embeddingsLeaveThisMac: Bool { get }
}

extension ModelProviding {
    func chat(for task: ChatTask) -> Result<ChatProvider, ProviderUnavailable> { chat() }
    var refinementChat: (any ChatModel)? { server?.client }
    var embeddingsLeaveThisMac: Bool { settings.embeddings == .server && server?.config.mode == .remote }
}

struct ProviderUnavailable: Error, Equatable {
    let issue: ProviderIssue
}

/// The real providers: the configured server (`LLMClient`), Apple's on-device
/// model and on-device embeddings.
final class SystemModelProviders: ModelProviding, @unchecked Sendable {
    private struct State {
        var config: LLMServerConfig?
        var configLocked = false
        var settings: ModelProviderSettings
    }

    let client: LLMClient
    private let searchModel: SearchModelAccess
    private let languageModel: LanguageModelAccess
    private let defaults: UserDefaults
    private let loadConfig: @Sendable () throws -> LLMServerConfig?
    private let state: Mutex<State>

    init(client: LLMClient, defaults: UserDefaults = .standard, searchModel: SearchModelAccess = .shared,
         languageModel: LanguageModelAccess = .shared,
         loadConfig: @escaping @Sendable () throws -> LLMServerConfig? = { try LLMServerConfig.load() }) {
        self.client = client
        self.searchModel = searchModel
        self.languageModel = languageModel
        self.defaults = defaults
        self.loadConfig = loadConfig
        state = Mutex(State(settings: ModelProviderSettings.load(defaults: defaults, hasServerConfig: false)))
        _ = reload()
    }

    /// A locked Keychain keeps the current server config (it may still be
    /// valid) and reports the issue; the caller tries again later.
    func reload() -> ProviderIssue? {
        let loaded: Result<LLMServerConfig?, Error> = Result { try loadConfig() }
        let config: LLMServerConfig? = state.withLock { s in
            switch loaded {
            case .success(let c):
                s.config = c
                s.configLocked = false
            case .failure:
                s.configLocked = true
            }
            s.settings = ModelProviderSettings.load(defaults: defaults, hasServerConfig: s.config != nil || s.configLocked)
            return s.config
        }
        client.apply(config)
        return state.withLock { $0.configLocked } ? .keychainLocked : nil
    }

    var settings: ModelProviderSettings { state.withLock { $0.settings } }
    var config: LLMServerConfig? { state.withLock { $0.config } }

    var server: (client: LLMClient, config: LLMServerConfig)? {
        guard client.isConfigured, let config else { return nil }
        return (client, config)
    }
    private var configLocked: Bool { state.withLock { $0.configLocked } }

    func chat() -> Result<ChatProvider, ProviderUnavailable> {
        switch settings.chat {
        case .server:
            guard client.isConfigured else {
                return .failure(ProviderUnavailable(issue: configLocked ? .keychainLocked : .serverNotConfigured))
            }
            return .success(ChatProvider(model: client, contextTokens: config?.contextTokens ?? LLMServerConfig.defaultContext,
                                         onDevice: false, supports: nil))
        case .onDevice:
            // Developer tools only: `VAUTA_INTEGRATED_LLM=1` makes Apple's option the integrated model when it is installed.
            if ProcessInfo.processInfo.environment["VAUTA_INTEGRATED_LLM"] == "1" {
                LanguageModelAccess.shared.refreshOnce()
                if LanguageModelAccess.shared.availability == .installed, let integrated = LanguageModelAccess.shared.chatModel {
                    return .success(Self.integratedProvider(integrated))
                }
            }
            return apple(fallback: nil)
        case .integrated:
            if languageModel === LanguageModelAccess.shared { languageModel.refreshOnce() }
            switch languageModel.availability {
            case .installed:
                guard let integrated = languageModel.chatModel else { return apple(fallback: .notReady) }
                return .success(Self.integratedProvider(integrated))
            case .notInstalled:
                return apple(fallback: .notReady)
            case .unavailable(let reason):
                return apple(fallback: reason == LanguageModelAccess.damagedReason ? .damaged : .unsupported)
            }
        }
    }

    private static func integratedProvider(_ model: IntegratedChatModel) -> ChatProvider {
        ChatProvider(model: model, contextTokens: IntegratedChatModel.contextWindow, onDevice: true, supports: { model.supports($0) }, integrated: true)
    }

    /// Apple's model, as the choice or as the stand-in for the integrated one (`fallback` says why).
    private func apple(fallback: IntegratedModelIssue?) -> Result<ChatProvider, ProviderUnavailable> {
        let apple = AppleChatModel()
        let availability = apple.availability
        guard availability == .available else {
            if let fallback { return .failure(ProviderUnavailable(issue: .integratedModel(fallback))) }
            return .failure(ProviderUnavailable(issue: .onDeviceModel(availability)))
        }
        var provider = ChatProvider(model: apple, contextTokens: apple.contextSize, onDevice: true, supports: { apple.supports($0) })
        provider.fallbackReason = fallback
        return .success(provider)
    }

    /// Live work goes to Apple's model when the integrated one is chosen and the person said so ("While recording"); everything
    /// else uses the chosen provider.
    func chat(for task: ChatTask) -> Result<ChatProvider, ProviderUnavailable> {
        guard task == .live, settings.chat == .integrated, ModelProviderSettings.liveTasks(defaults: defaults) == .apple,
              case .success(let main) = chat(), main.integrated else { return chat() }
        if case .success(let apple) = self.apple(fallback: nil) { return .success(apple) }
        return .success(main)
    }

    func embeddings() -> EmbeddingProvider {
        switch settings.embeddings {
        case .none:
            return .disabled
        case .server:
            guard client.isConfigured, let model = config?.model(for: .embedding), !model.isEmpty else {
                return .unavailable(configLocked ? .keychainLocked : .serverNotConfigured)
            }
            let client = client
            return .available(model: { _ in client }, expectedModel: { _ in model })
        case .onDeviceModel:
            switch searchModel.availability {
            case .notInstalled:
                return .unavailable(.searchModelNotInstalled)
            case .unavailable(let reason):
                return .unavailable(.searchModelUnavailable(reason))
            case .installed:
                guard let gemma = searchModel.model else { return .unavailable(.searchModelNotInstalled) }
                // One model for every language.
                return .available(model: { _ in gemma }, expectedModel: { _ in GemmaEmbeddingModel.space.model })
            }
        }
    }
}
