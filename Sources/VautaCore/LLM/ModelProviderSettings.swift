// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Where the chat and embedding models run. Not secret, so it lives in
/// UserDefaults; the server address, CA, pins and key stay in the Keychain.
public struct ModelProviderSettings: Sendable, Equatable {
    public enum Chat: String, Sendable, CaseIterable, Identifiable {
        /// The configured OpenAI-compatible server (this Mac or the network).
        case server
        /// Apple's on-device model (Foundation Models).
        case onDevice
        /// The integrated Gemma 4 E4B on this Mac (optional, Macs with 16 GB or more). New raw value in 11b: an older build reads it as
        /// an unknown value and falls back to its default.
        case integrated
        public var id: String { rawValue }
    }

    public enum Embeddings: String, Sendable, CaseIterable, Identifiable {
        case server
        /// EmbeddingGemma 2 on this Mac (needs the downloaded search model). Raw value new in 0.9. The retired raw value
        /// `"onDevice"` (Apple's NaturalLanguage embeddings) is never reused: `load` maps it to `.none`.
        case onDeviceModel = "searchModel"
        /// Keyword search only.
        case none
        public var id: String { rawValue }
    }

    public var chat: Chat
    public var embeddings: Embeddings

    public init(chat: Chat, embeddings: Embeddings) {
        self.chat = chat
        self.embeddings = embeddings
    }

    static let chatKey = "modelProviderChat"
    /// Which model does the live work of a recording when the integrated model is the provider: `"integrated"` (default) or `"apple"`.
    public static let liveTasksKey = "integratedLiveTasks"
    /// The hidden flag for the integrated model (`defaults write … integratedLanguageModel -bool YES`), migrated once to the provider choice.
    static let hiddenFlagKey = "integratedLanguageModel"

    /// Who writes live notes and answers questions during a recording.
    public enum LiveTasks: String, Sendable, CaseIterable, Identifiable {
        case integrated, apple
        public var id: String { rawValue }
    }

    public static func liveTasks(defaults: UserDefaults = .standard) -> LiveTasks {
        defaults.string(forKey: liveTasksKey).flatMap(LiveTasks.init(rawValue:)) ?? .integrated
    }

    public static func saveLiveTasks(_ tasks: LiveTasks, defaults: UserDefaults = .standard) {
        defaults.set(tasks.rawValue, forKey: liveTasksKey)
    }

    /// Saves the chat choice alone (a one-click action such as starting the model's download): the embeddings choice is not touched.
    public static func saveChat(_ chat: Chat, defaults: UserDefaults = .standard) {
        defaults.set(chat.rawValue, forKey: chatKey)
    }
    static let embeddingsKey = "modelProviderEmbeddings"
    /// The raw value of Apple's removed on-device embeddings.
    static let retiredOnDevice = "onDevice"
    /// Set once when the retired value was migrated; Settings shows a notice and clears it.
    public static let retiredAppleNLKey = "searchModelRetiredAppleNL"

    /// The saved choice always wins. Without one, installs that already have a
    /// server configuration keep using it (0.1.0 behaviour); new installs start
    /// on Apple's on-device model with keyword search only: in the project's
    /// benchmark keyword search beat on-device embeddings for Ask.
    public static func load(defaults: UserDefaults = .standard, hasServerConfig: Bool) -> ModelProviderSettings {
        // Apple's on-device embeddings were removed (worse than keyword search in every benchmark): the saved choice becomes
        // keyword search, once, and Settings tells the person why.
        if defaults.string(forKey: embeddingsKey) == retiredOnDevice {
            defaults.set(Embeddings.none.rawValue, forKey: embeddingsKey)
            defaults.set(true, forKey: retiredAppleNLKey)
        }
        // The hidden flag becomes the provider choice, once: it only ever meant "the integrated model instead of Apple's".
        if defaults.bool(forKey: hiddenFlagKey) {
            let current = defaults.string(forKey: chatKey).flatMap(Chat.init(rawValue:))
            if current == nil || current == .onDevice { defaults.set(Chat.integrated.rawValue, forKey: chatKey) }
            defaults.removeObject(forKey: hiddenFlagKey)
        }
        let fallback: ModelProviderSettings = hasServerConfig ? .init(chat: .server, embeddings: .server)
                                                              : .init(chat: .onDevice, embeddings: .none)
        return ModelProviderSettings(
            chat: defaults.string(forKey: chatKey).flatMap(Chat.init(rawValue:)) ?? fallback.chat,
            embeddings: defaults.string(forKey: embeddingsKey).flatMap(Embeddings.init(rawValue:)) ?? fallback.embeddings)
    }

    /// Saves the embeddings choice alone (a one-click action such as "Use This Mac Instead"): the chat choice is not touched.
    public static func saveEmbeddings(_ embeddings: Embeddings, defaults: UserDefaults = .standard) {
        defaults.set(embeddings.rawValue, forKey: embeddingsKey)
    }

    public func save(defaults: UserDefaults = .standard) {
        defaults.set(chat.rawValue, forKey: Self.chatKey)
        defaults.set(embeddings.rawValue, forKey: Self.embeddingsKey)
    }
}
