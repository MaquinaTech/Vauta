// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Errors from model providers (server, on-device). Shown to users through
/// `LocalizedError`; callers branch on the cases, never on the text.
public enum LLMError: Error, Equatable, Sendable {
    case notConfigured
    case unauthorized
    /// 429/503 or a local model that is busy. `retryAfter` in seconds (1–300).
    case busy(retryAfter: Double)
    /// Any other non-success status, with the server's explanation when it gave one.
    case http(Int, message: String?)
    /// The prompt does not fit in the model's context window.
    case contextLengthExceeded(message: String?)
    /// The server does not know the requested model.
    case modelNotFound(message: String?)
    /// The server reported an error in the middle of a stream.
    case server(message: String)
    /// Generation stopped at `max_tokens` (`finish_reason: "length"`), when the
    /// caller asked for complete answers only.
    case outputTruncated
    case invalidResponse(String)
    /// The embedding model returned vectors shorter than Vauta supports.
    case embeddingDimensions(Int, minimum: Int)
    case tooLarge
    case network(String)
    /// The Keychain is locked or refused access; trying later may work.
    case keychainUnavailable
    /// The stored server key contains characters that cannot go in a header.
    case invalidStoredToken
    /// A host name resolved to an address outside the local network.
    case untrustedPeerAddress(String)
    /// The on-device model cannot be used now (see `AppleChatModel.Availability`).
    case modelUnavailable
    /// The on-device model does not support the language of the request.
    case unsupportedLanguage
    /// The model refused to answer (safety guardrails).
    case refused
    /// Search by meaning on this Mac is chosen, but the search model is not installed or cannot run.
    case searchModelUnavailable

    /// Worth retrying later without user action.
    public var isRetryable: Bool {
        switch self {
        case .busy, .network, .keychainUnavailable: true
        case .http(let c, _): c == 429 || c == 502 || c == 503 || c == 504
        default: false
        }
    }

    /// Kept for existing callers.
    var retryable: Bool { isRetryable }

    /// Seconds the server asked to wait, for busy responses. Callers cap how
    /// many busy retries they make.
    public var retryAfter: Double? {
        if case .busy(let s) = self { return s }
        return nil
    }

    /// The user has to change something in Settings before this can work.
    public var needsConfiguration: Bool {
        switch self {
        case .notConfigured, .unauthorized, .invalidStoredToken: true
        default: false
        }
    }
}

extension LLMError {
    /// A network failure with a localized reason. The system's own text is English on many
    /// errors ("Connection refused"), so it is never shown.
    public static func network(from error: Error) -> LLMError {
        .network(networkReason(of: error))
    }

    static func networkDescription(_ detail: String) -> String {
        let reason = detail == LLMClient.destinationNotAllowed
            ? String(localized: "that address isn’t allowed", comment: "Network error reason: the destination check refused the address; lowercase, no final period")
            : detail
        return String(localized: "Can’t reach the model server: \(reason).", comment: "Model error; the argument says why, in lowercase and without a final period (for example: nothing is answering at that address)")
    }

    static func networkReason(of error: Error) -> String {
        var code: URLError.Code?
        var posix: Int?
        var current: NSError? = error as NSError
        while let ns = current {
            if ns.domain == NSURLErrorDomain { code = code ?? URLError.Code(rawValue: ns.code) }
            if ns.domain == NSPOSIXErrorDomain { posix = ns.code }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        if posix == Int(ECONNREFUSED) || code == .cannotConnectToHost {
            return String(localized: "nothing is answering at that address", comment: "Network error reason: the connection was refused; lowercase, no final period")
        }
        switch code {
        case .timedOut:
            return String(localized: "it didn’t answer in time", comment: "Network error reason: timeout; lowercase, no final period")
        case .notConnectedToInternet, .networkConnectionLost:
            return String(localized: "the network connection was lost", comment: "Network error reason; lowercase, no final period")
        case .cannotFindHost, .dnsLookupFailed:
            return String(localized: "the server’s name can’t be found", comment: "Network error reason: DNS; lowercase, no final period")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired:
            return String(localized: "the secure connection failed", comment: "Network error reason: TLS; lowercase, no final period")
        default:
            return String(localized: "the connection failed", comment: "Network error reason: anything else; lowercase, no final period")
        }
    }
}

extension LLMError: LocalizedError, CustomStringConvertible {
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            String(localized: "The model server isn’t set up.", comment: "Model error")
        case .unauthorized:
            String(localized: "The model server rejected the key.", comment: "Model error (HTTP 401/403)")
        case .busy(let s):
            String(localized: "The model server is busy. Retrying in \(Int(s)) s.", comment: "Model error; argument is seconds")
        case .http(let code, let message):
            if let message {
                String(localized: "The model server answered \(code): \(message)", comment: "Model error; HTTP status and the server's message")
            } else {
                String(localized: "The model server answered \(code).", comment: "Model error; HTTP status")
            }
        case .contextLengthExceeded:
            String(localized: "The text is too long for the model’s context length.", comment: "Model error")
        case .modelNotFound(let message):
            if let message {
                String(localized: "The model server doesn’t have the selected model: \(message)", comment: "Model error; server message")
            } else {
                String(localized: "The model server doesn’t have the selected model.", comment: "Model error")
            }
        case .server(let message):
            String(localized: "The model server reported an error: \(message)", comment: "Model error; server message")
        case .outputTruncated:
            String(localized: "The model’s answer was cut off at the length limit.", comment: "Model error")
        case .invalidResponse(let detail):
            String(localized: "The model server sent an invalid response (\(detail)).", comment: "Model error; technical detail")
        case .embeddingDimensions(let n, let minimum):
            String(localized: "The model for search by meaning returns \(n) dimensions; Vauta needs at least \(minimum).",
                   comment: "Model error; dimensions returned and minimum")
        case .tooLarge:
            String(localized: "The model server’s response is too large.", comment: "Model error")
        case .network(let detail):
            Self.networkDescription(detail)
        case .keychainUnavailable:
            String(localized: "The Keychain is locked, so Vauta can’t read the model server key. Unlock your Mac, then try again.", comment: "Model error")
        case .invalidStoredToken:
            String(localized: "The saved model server key contains invalid characters.", comment: "Model error")
        case .untrustedPeerAddress(let address):
            String(localized: "The model server name resolved to \(address), which isn’t on your local network.",
                   comment: "Model error; IP address")
        case .modelUnavailable:
            String(localized: "Apple Intelligence isn’t available right now.", comment: "Model error")
        case .unsupportedLanguage:
            String(localized: "Apple Intelligence doesn’t support this language.", comment: "Model error")
        case .refused:
            String(localized: "The model declined to answer.", comment: "Model error")
        case .searchModelUnavailable:
            String(localized: "The search model isn’t available.", comment: "Model error: search by meaning on this Mac needs the downloaded search model")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .notConfigured, .invalidStoredToken, .unauthorized:
            String(localized: "Check the server and its key in Settings\u{00A0}→\u{00A0}Models.", comment: "Model error recovery")
        case .contextLengthExceeded:
            String(localized: "Load the model with a longer context length or lower the context length in Settings\u{00A0}→\u{00A0}Models.", comment: "Model error recovery")
        case .modelNotFound:
            String(localized: "Download the model or pick another one in Settings\u{00A0}→\u{00A0}Models.", comment: "Model error recovery")
        case .network:
            String(localized: "Make sure the model server app is open and its server is running.", comment: "Model error recovery")
        case .keychainUnavailable:
            String(localized: "Unlock your Mac; Vauta will try again.", comment: "Model error recovery")
        case .embeddingDimensions:
            String(localized: "Pick another model for search by meaning in Settings\u{00A0}→\u{00A0}Models.", comment: "Model error recovery")
        case .searchModelUnavailable:
            String(localized: "Check the search model in Settings\u{00A0}→\u{00A0}Models.", comment: "Model error recovery")
        default: nil
        }
    }

    public var description: String { errorDescription ?? "LLMError" }
}

// MARK: Error bodies

enum ServerErrorBody {
    /// Bytes read from a non-success response body.
    static let maxBytes = 16 << 10

    /// The human-readable message in an error body: OpenAI `{"error": {"message"}}`,
    /// `{"error": "…"}`, FastAPI `{"detail": "…"}`, `{"message": "…"}`, or plain text.
    static func message(from data: Data) -> String? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return message(in: obj)
        }
        let text = String(decoding: data.prefix(maxBytes), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text.hasPrefix("<") ? nil : clip(text)
    }

    static func message(in obj: [String: Any]) -> String? {
        if let e = obj["error"] as? [String: Any] {
            return (e["message"] as? String).map(clip) ?? (e["code"] as? String) ?? (e["type"] as? String)
        }
        if let e = obj["error"] as? String { return clip(e) }
        if let d = obj["detail"] as? String { return clip(d) }
        if let d = (obj["detail"] as? [[String: Any]])?.first?["msg"] as? String { return clip(d) }
        if let m = obj["message"] as? String { return clip(m) }
        return nil
    }

    /// Error code or type from an OpenAI-style body.
    static func code(in obj: [String: Any]) -> String? {
        guard let e = obj["error"] as? [String: Any] else { return nil }
        return (e["code"] as? String) ?? (e["type"] as? String)
    }

    /// Maps a non-success status and its body to the most useful error.
    static func error(status: Int, body: Data, retryAfter: String?, now: Date = .now) -> LLMError {
        let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let msg = obj.flatMap(message(in:)) ?? message(from: body)
        let code = obj.flatMap(code(in:))
        switch status {
        case 401, 403: return .unauthorized
        case 429, 503: return .busy(retryAfter: parseRetryAfter(retryAfter, now: now))
        default: break
        }
        if isContextOverflow(msg) || isContextOverflow(code) { return .contextLengthExceeded(message: msg) }
        if code == "model_not_found" || (status == 404 && (msg?.lowercased().contains("model") ?? false)) {
            return .modelNotFound(message: msg)
        }
        return .http(status, message: msg)
    }

    /// Maps an error reported inside a stream.
    static func streamError(_ obj: [String: Any]) -> LLMError {
        let msg = message(in: obj) ?? "unknown error"
        if isContextOverflow(msg) || isContextOverflow(code(in: obj)) { return .contextLengthExceeded(message: msg) }
        return .server(message: msg)
    }

    /// Context overflow wording of OpenAI, vLLM, llama.cpp, LM Studio, MLX and Ollama.
    static func isContextOverflow(_ text: String?) -> Bool {
        guard let t = text?.lowercased() else { return false }
        return ["context_length_exceeded", "exceed_context_size", "context length", "context window", "context size",
                "maximum context", "too many tokens", "prompt is too long", "exceeds the available context",
                "n_ctx", "input is too long", "context overflow", "overflows"].contains { t.contains($0) }
    }

    /// `Retry-After` as delta-seconds or an HTTP-date, clamped to 1–300 s (default 10).
    static func parseRetryAfter(_ value: String?, now: Date = .now) -> Double {
        let raw = value?.trimmingCharacters(in: .whitespaces) ?? ""
        var seconds: Double?
        if let s = Double(raw), s.isFinite {
            seconds = s
        } else if let date = httpDate(raw) {
            seconds = date.timeIntervalSince(now)
        }
        return min(max(seconds ?? 10, 1), 300)
    }

    /// RFC 9110 IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`), plus the obsolete RFC 850 and asctime forms.
    static func httpDate(_ s: String) -> Date? {
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "GMT")
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    private static func clip(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 300 ? String(t.prefix(300)) + "…" : t
    }
}
