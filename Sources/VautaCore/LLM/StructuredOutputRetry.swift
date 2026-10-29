// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// A model server that does not understand the `response_format` it was sent answers 400, 415 or 422. The request is then sent once more
/// without it: the prompt carries the same shape, and the reply is validated either way. Every request with a schema goes through here
/// (Ask, the question check, the brief, the minutes and the live notes).
enum StructuredOutputRetry {
    static let rejectingStatuses: Set<Int> = [400, 415, 422]

    /// Whether `error` is a server refusing the structured output of `options` (and not, say, a prompt that was too long).
    static func rejects(_ error: any Error, _ options: ChatOptions) -> Bool {
        guard options.responseFormat != nil, case LLMError.http(let status, _) = error else { return false }
        return rejectingStatuses.contains(status)
    }

    /// Sends with `options`; when the server rejects the structured output, sends once more without it. `options` is left without it,
    /// so a later request of the same caller (a larger limit, the next stage) does not send it again.
    static func run<T>(_ options: inout ChatOptions, isolation: isolated (any Actor)? = #isolation,
                       _ send: (ChatOptions) async throws -> T) async throws -> T {
        do {
            return try await send(options)
        } catch let error where rejects(error, options) {
            try Task.checkCancellation()
            options.responseFormat = nil
            return try await send(options)
        }
    }
}

/// A chat model that retries without `response_format` as `StructuredOutputRetry` does, and after one rejection sends none for its
/// lifetime: a minutes run makes many requests (blocks, merges, the closing request) and the server's answer does not change.
final class StructuredOutputFallback: ChatModel, @unchecked Sendable {
    let base: any ChatModel
    private let lock = NSLock()
    private var rejected = false

    init(_ base: any ChatModel) { self.base = base }

    var contextTokens: Int? { get async { await base.contextTokens } }

    func chat(_ messages: [ChatMessage], _ options: ChatOptions, onProgress: (@Sendable (Int) -> Void)?) async throws -> ChatResult {
        var sent = options
        if lock.withLock({ rejected }) { sent.responseFormat = nil }
        let asked = sent.responseFormat != nil
        let result = try await StructuredOutputRetry.run(&sent) { try await base.chat(messages, $0, onProgress: onProgress) }
        if asked, sent.responseFormat == nil { lock.withLock { rejected = true } }
        return result
    }
}
