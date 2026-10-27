// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The three ways to run the models, as Settings offers them.
public enum ModelProviderChoice: String, CaseIterable, Identifiable, Sendable {
    /// Apple's on-device model: no setup.
    case onDevice
    /// The integrated Gemma 4 E4B (optional, 16 GB or more, a 15 GB download).
    case integrated
    /// An OpenAI-compatible server on this Mac.
    case localServer
    /// An OpenAI-compatible server on another computer of the local network (HTTPS).
    case networkServer

    public var id: String { rawValue }

    /// The choice that describes the saved settings and server mode.
    public init(settings: ModelProviderSettings, serverMode: LLMServerConfig.Mode?) {
        switch (settings.chat, serverMode) {
        case (.onDevice, _): self = .onDevice
        case (.integrated, _): self = .integrated
        case (.server, .remote): self = .networkServer
        case (.server, _): self = .localServer
        }
    }

    public var chat: ModelProviderSettings.Chat {
        switch self {
        case .onDevice: .onDevice
        case .integrated: .integrated
        case .localServer, .networkServer: .server
        }
    }

    /// The server mode this choice needs; nil for the on-device model.
    public var serverMode: LLMServerConfig.Mode? {
        switch self {
        case .onDevice, .integrated: nil
        case .localServer: .local
        case .networkServer: .remote
        }
    }

    /// Search options that make sense with this choice.
    public var embeddingOptions: [ModelProviderSettings.Embeddings] {
        runsOnThisMac ? [.onDeviceModel, .none] : [.server, .onDeviceModel, .none]
    }

    /// `current` if this choice allows it, else the natural option.
    public func embeddings(keeping current: ModelProviderSettings.Embeddings) -> ModelProviderSettings.Embeddings {
        if embeddingOptions.contains(current) { return current }
        return runsOnThisMac ? .none : .server
    }

    /// Apple's model and the integrated one run in this app, with no server.
    public var runsOnThisMac: Bool { self == .onDevice || self == .integrated }

    public func settings(embeddings: ModelProviderSettings.Embeddings) -> ModelProviderSettings {
        ModelProviderSettings(chat: chat, embeddings: self.embeddings(keeping: embeddings))
    }
}
