// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Why a model job failed, as stored in `llm_jobs.last_error_code`. The raw
/// values are persisted: never change them, only add new ones. The text is
/// produced when shown, in the current UI language.
public enum JobErrorCode: String, Sendable, CaseIterable {
    case notConfigured = "not_configured"
    case unauthorized
    case busy
    case http
    case contextLengthExceeded = "context_length"
    case modelNotFound = "model_not_found"
    case server
    case outputTruncated = "output_truncated"
    case invalidResponse = "invalid_response"
    case embeddingDimensions = "embedding_dimensions"
    case tooLarge = "too_large"
    case network
    case keychainLocked = "keychain_locked"
    case invalidStoredKey = "invalid_key"
    case untrustedPeer = "untrusted_peer"
    case modelUnavailable = "model_unavailable"
    case unsupportedLanguage = "unsupported_language"
    case refused
    case searchModelUnavailable = "search_model_unavailable"
    case unknown

    /// The code and a short technical detail (server message, status) for an error.
    public init(_ error: Error) {
        guard let e = error as? LLMError else {
            self = error is URLError ? .network : .unknown
            return
        }
        self = switch e {
        case .notConfigured: .notConfigured
        case .unauthorized: .unauthorized
        case .busy: .busy
        case .http: .http
        case .contextLengthExceeded: .contextLengthExceeded
        case .modelNotFound: .modelNotFound
        case .server: .server
        case .outputTruncated: .outputTruncated
        case .invalidResponse: .invalidResponse
        case .embeddingDimensions: .embeddingDimensions
        case .tooLarge: .tooLarge
        case .network: .network
        case .keychainUnavailable: .keychainLocked
        case .invalidStoredToken: .invalidStoredKey
        case .untrustedPeerAddress: .untrustedPeer
        case .modelUnavailable: .modelUnavailable
        case .unsupportedLanguage: .unsupportedLanguage
        case .refused: .refused
        case .searchModelUnavailable: .searchModelUnavailable
        }
    }

    /// Technical detail worth keeping next to the code (not localized).
    static func detail(_ error: Error) -> String? {
        switch error as? LLMError {
        case .http(let status, let message): message.map { "\(status): \($0)" } ?? "\(status)"
        case .contextLengthExceeded(let message), .modelNotFound(let message): message
        case .server(let message), .invalidResponse(let message), .network(let message): message
        case .embeddingDimensions(let n, let minimum): "\(n) < \(minimum)"
        case .untrustedPeerAddress(let address): address
        case .none: (error as? URLError).map { "URLError \($0.code.rawValue)" }
        default: nil
        }
    }

    /// What happened, in the UI language.
    public var localizedDescription: String {
        switch self {
        case .notConfigured: String(localized: "The model server isn’t set up.", comment: "Model error")
        case .unauthorized: String(localized: "The model server rejected the key.", comment: "Model error (HTTP 401/403)")
        case .busy: String(localized: "The model server was busy for too long.", comment: "Model job error")
        case .http: String(localized: "The model server reported an error.", comment: "Model job error")
        case .contextLengthExceeded:
            String(localized: "The text is too long for the model’s context length.", comment: "Model error")
        case .modelNotFound: String(localized: "The model server doesn’t have the selected model.", comment: "Model error")
        case .server: String(localized: "The model server reported an error.", comment: "Model job error")
        case .outputTruncated: String(localized: "The model’s answer was cut off at the length limit.", comment: "Model error")
        case .invalidResponse: String(localized: "The model’s answer couldn’t be read.", comment: "Model job error")
        case .embeddingDimensions:
            String(localized: "The model for search by meaning returns vectors that are too short.", comment: "Model job error")
        case .tooLarge: String(localized: "The model server’s response is too large.", comment: "Model error")
        case .network: String(localized: "Can’t reach the model server.", comment: "Model job error")
        case .keychainLocked:
            String(localized: "The Keychain is locked, so Vauta can’t read the model server key. Unlock your Mac, then try again.", comment: "Model error")
        case .invalidStoredKey: String(localized: "The saved model server key contains invalid characters.", comment: "Model error")
        case .untrustedPeer:
            String(localized: "The model server name resolved to an address outside your local network.", comment: "Model job error")
        case .modelUnavailable: String(localized: "Apple Intelligence isn’t available right now.", comment: "Model error")
        case .unsupportedLanguage:
            String(localized: "Apple Intelligence doesn’t support this language.", comment: "Model error")
        case .refused: String(localized: "The model declined to answer.", comment: "Model error")
        case .searchModelUnavailable:
            String(localized: "The search model isn’t available.", comment: "Model error: search by meaning on this Mac needs the downloaded search model")
        case .unknown: String(localized: "Something went wrong while talking to the model.", comment: "Model job error")
        }
    }
}
