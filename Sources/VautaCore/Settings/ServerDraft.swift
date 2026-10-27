// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The model server configuration being edited in Settings. Nothing is stored
/// until the user applies it; fields the form does not edit (`roleBaseURLs`,
/// `embedding`) are carried over unchanged, so saving never drops them.
public struct ServerDraft: Equatable, Sendable {
    public var mode: LLMServerConfig.Mode
    public var baseURL: String
    /// Private CA bundle (PEM) as typed or imported; used in remote mode only.
    public var caPEM: String
    /// Certificate pins separated by commas, spaces or new lines; remote mode only.
    public var pins: String
    public var fastModel: String
    public var deepModel: String
    public var embeddingModel: String
    public var contextTokens: Int
    /// Request dialect. nil keeps the exact the earlier version behaviour (`ServerProfile.legacy`).
    public var profile: ServerProfile?
    public var roleBaseURLs: RoleBaseURLs?
    public var embedding: EmbeddingSettings?

    /// A draft of `config`, or an empty local draft when there is none.
    public init(config: LLMServerConfig?) {
        let c = config ?? LLMServerConfig(mode: .local, baseURL: "", fastModel: "", deepModel: "", embeddingModel: "")
        mode = c.mode
        baseURL = c.baseURL
        caPEM = c.caPEM ?? ""
        pins = c.pins.joined(separator: ", ")
        fastModel = c.fastModel
        deepModel = c.deepModel
        embeddingModel = c.embeddingModel
        contextTokens = c.contextTokens
        profile = c.profile
        roleBaseURLs = c.roleBaseURLs
        embedding = c.embedding
    }

    /// The configuration this draft describes (whitespace trimmed).
    public var config: LLMServerConfig {
        let remote = mode == .remote
        let ca = caPEM.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : caPEM
        return LLMServerConfig(mode: mode, baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                               caPEM: remote ? ca : nil,
                               pins: remote ? Self.parsePins(pins) : [],
                               fastModel: fastModel.trimmingCharacters(in: .whitespaces),
                               deepModel: deepModel.trimmingCharacters(in: .whitespaces),
                               embeddingModel: embeddingModel.trimmingCharacters(in: .whitespaces),
                               contextTokens: contextTokens, profile: profile, roleBaseURLs: roleBaseURLs, embedding: embedding)
    }

    /// The same destination with placeholder model names, so the connection
    /// can be tested (and the model list read) before any model is chosen.
    public var probeConfig: LLMServerConfig {
        var c = config
        if c.fastModel.isEmpty { c.fastModel = Self.placeholderModel }
        if c.deepModel.isEmpty { c.deepModel = Self.placeholderModel }
        if c.embeddingModel.isEmpty { c.embeddingModel = Self.placeholderModel }
        return c
    }

    static let placeholderModel = "model"

    /// Whether the draft differs from what is saved.
    public func differs(from saved: LLMServerConfig?) -> Bool {
        config != ServerDraft(config: saved).config
    }

    /// Whether the draft reaches the saved server exactly as the saved
    /// configuration does: same mode, address and trust (CA and pins). Only
    /// then may the saved key be sent with a test request.
    public func sharesDestination(with saved: LLMServerConfig?) -> Bool {
        guard let saved else { return false }
        let draft = config
        func base(_ s: String) -> String {
            var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while t.hasSuffix("/") { t.removeLast() }
            return t
        }
        let ca = { (pem: String?) in pem?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        return !base(draft.baseURL).isEmpty && base(draft.baseURL) == base(saved.baseURL) && draft.mode == saved.mode
            && ca(draft.caPEM) == ca(saved.caPEM) && draft.pins == saved.pins
            && draft.roleBaseURLs == saved.roleBaseURLs
    }

    /// Why the configuration cannot be saved, or nil.
    public var validationError: LLMServerConfig.Invalid? { validationError(embeddingsOnServer: true) }

    /// `embeddingsOnServer`: search by meaning runs on this server, so the
    /// embedding model is required.
    public func validationError(embeddingsOnServer: Bool) -> LLMServerConfig.Invalid? {
        do {
            _ = try config.validatedEndpoints(embeddingsOnServer: embeddingsOnServer)
            return nil
        } catch let invalid as LLMServerConfig.Invalid {
            return invalid
        } catch {
            return .invalidURL
        }
    }

    /// Why the destination itself is unusable (models aside), or nil.
    public var destinationError: LLMServerConfig.Invalid? {
        do {
            _ = try probeConfig.validatedEndpoints()
            return nil
        } catch let invalid as LLMServerConfig.Invalid {
            return invalid
        } catch {
            return .invalidURL
        }
    }

    /// Takes a detected server: its address, request profile, suggested models
    /// (only for roles left empty or naming a model the server does not have)
    /// and the context its chat models are loaded with.
    public mutating func adopt(_ server: DiscoveredServer) {
        let suggested = server.suggestedConfig()
        let ids = Set(server.models.map(\.id))
        if mode == .local { baseURL = suggested.baseURL }
        if profile?.kind != server.kind { profile = suggested.profile }
        if fastModel.isEmpty || !ids.contains(fastModel) { fastModel = suggested.fastModel }
        if deepModel.isEmpty || !ids.contains(deepModel) { deepModel = suggested.deepModel }
        if embeddingModel.isEmpty || !ids.contains(embeddingModel) { embeddingModel = suggested.embeddingModel }
        if let context = Self.detectedContext(server, fast: fastModel, deep: deepModel) { contextTokens = context }
    }

    /// The context the chosen chat models are loaded with (the smaller), clamped
    /// to the supported range; nil when the server does not say.
    public static func detectedContext(_ server: DiscoveredServer, fast: String, deep: String) -> Int? {
        let lengths = [fast, deep].compactMap { name in server.models.first { $0.id == name }?.contextLength }
        guard let smallest = lengths.min() else { return nil }
        return min(max(smallest, LLMServerConfig.contextRange.lowerBound), LLMServerConfig.contextRange.upperBound)
    }

    /// Switches between this Mac and the network, clearing an address that
    /// cannot be valid in the new mode.
    public mutating func switchMode(to newMode: LLMServerConfig.Mode) {
        guard newMode != mode else { return }
        mode = newMode
        let host = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]")) ?? ""
        let loopback = !host.isEmpty && ServerAddress.isLoopback(host)
        if (newMode == .remote) == loopback { baseURL = "" }
    }

    /// Context sizes offered in the picker, including the current value.
    public var contextChoices: [Int] {
        Array(Set([8_192, 16_384, 32_768, 65_536, 131_072, 262_144, contextTokens])).sorted()
    }

    /// Adds the SPKI pin of the first certificate in `pem` (the server's own
    /// certificate) to the pins. Returns the pin, or nil when `pem` holds no
    /// usable certificate.
    @discardableResult
    public mutating func addPin(fromCertificatePEM pem: String) -> String? {
        guard let pin = LLMClient.spkiPin(pem: pem) else { return nil }
        if !Self.parsePins(pins).contains(pin) {
            pins = (Self.parsePins(pins) + [pin]).joined(separator: ", ")
        }
        return pin
    }

    public static func parsePins(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
    }
}

/// Sampling choices offered in Settings (`SamplingPreset` without its values).
public enum SamplingChoice: String, CaseIterable, Identifiable, Sendable {
    case serverDefault
    case qwenRecommended
    /// Values written by hand in the configuration; kept as they are.
    case custom

    public var id: String { rawValue }

    public init(_ preset: SamplingPreset) {
        switch preset {
        case .none: self = .serverDefault
        case .qwenNonThinking: self = .qwenRecommended
        case .custom: self = .custom
        }
    }
}

extension ServerDraft {
    /// The sampling choice of the profile (server default without a profile is
    /// never shown: legacy drafts keep their implicit preset).
    public var sampling: SamplingChoice {
        get { SamplingChoice(profile?.sampling ?? ServerProfile.legacy.sampling) }
        set {
            guard profile != nil else { return }
            switch newValue {
            case .serverDefault: profile?.sampling = .none
            case .qwenRecommended: profile?.sampling = .qwenNonThinking
            case .custom: break   // only kept, never created here
            }
        }
    }

    /// Sets the server kind: nil returns to the the earlier version behaviour; a kind
    /// takes that kind's default request options.
    public mutating func setKind(_ kind: ServerKind?) {
        guard kind != profile?.kind else { return }
        profile = kind.map(ServerProfile.defaults(for:))
    }
}
