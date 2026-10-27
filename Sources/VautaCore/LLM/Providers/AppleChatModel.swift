// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
internal import FoundationModels

/// Apple's on-device language model (Apple Intelligence). Needs no setup or
/// server, runs entirely on this Mac, and has a small context window (4K
/// tokens on macOS 26), so long inputs must be split by the caller.
///
/// Only `SystemLanguageModel` is used; Private Cloud Compute is never used.
public struct AppleChatModel: ChatModel {
    public enum Availability: Equatable, Sendable {
        case available
        /// This Mac cannot run Apple Intelligence.
        case deviceNotEligible
        /// Apple Intelligence is turned off in System Settings.
        case appleIntelligenceNotEnabled
        /// The model is still downloading or preparing.
        case modelNotReady
        /// Unavailable for a reason this version does not know.
        case unavailable
    }

    public init() {}

    private var model: SystemLanguageModel { .default }

    public var availability: Availability {
        switch model.availability {
        case .available: .available
        case .unavailable(.deviceNotEligible): .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady): .modelNotReady
        case .unavailable: .unavailable
        }
    }

    public var isAvailable: Bool { availability == .available }

    /// Context window in tokens (4096 on macOS 26; reported by the system on later versions).
    /// The system can report 0 while the model is busy or updating: fall back to the
    /// macOS 26 size so context budgets never collapse.
    public var contextSize: Int {
        let reported = model.contextSize
        return reported > 0 ? reported : Self.fallbackContextSize
    }

    static let fallbackContextSize = 4096

    public var contextTokens: Int? { contextSize }

    /// Languages the model can read and write.
    public var supportedLanguages: Set<Locale.Language> { model.supportedLanguages }

    public func supports(_ locale: Locale) -> Bool { model.supportsLocale(locale) }

    /// System messages become the session instructions; the other messages,
    /// in order, become one prompt (earlier answers are marked as such).
    public func chat(_ messages: [ChatMessage], _ options: ChatOptions,
                     onProgress: (@Sendable (Int) -> Void)? = nil) async throws -> ChatResult {
        let started = Date()
        guard isAvailable else { throw LLMError.modelUnavailable }
        let (instructions, prompt) = Self.render(messages)
        let session = LanguageModelSession(model: model, instructions: instructions.isEmpty ? nil : instructions)
        let generation = GenerationOptions(maximumResponseTokens: options.maxTokens)
        var content = ""
        var snapshots = 0
        var firstToken: Double?
        do {
            if options.purpose == .ask || options.purpose == .liveAnswers, let shape = options.outputSchema, let schema = AppleGuidedSchema.make(shape) {
                // An answer is held to its shape by guided generation (found first, a cited claim under found, bounded claims). The
                // prompt already shows the shape in words, so the schema is not added to it again: the window is only 4,096 tokens.
                for try await snapshot in session.streamResponse(to: prompt, schema: schema, includeSchemaInPrompt: false, options: generation) {
                    content = snapshot.rawContent.jsonString
                    snapshots += 1
                    if snapshots == 1 { firstToken = Date().timeIntervalSince(started) }
                    if snapshots % 16 == 0 { onProgress?(snapshots) }
                }
            } else {
                for try await snapshot in session.streamResponse(to: prompt, options: generation) {
                    content = snapshot.content
                    snapshots += 1
                    if snapshots == 1 { firstToken = Date().timeIntervalSince(started) }
                    if snapshots % 16 == 0 { onProgress?(snapshots) }
                }
            }
        } catch {
            throw Self.map(error)
        }
        try Task.checkCancellation()
        // The framework stops silently at `maximumResponseTokens`; an answer
        // that ends inside its JSON was cut there.
        let answer = LLMClient.strippingThinking(content)
        return ChatResult(content: answer, promptTokens: 0, cachedTokens: 0, completionTokens: snapshots,
                          finishReason: ModelOutput.endsInsideJSON(answer) ? .length : nil, firstTokenSeconds: firstToken)
    }

    static func render(_ messages: [ChatMessage]) -> (instructions: String, prompt: String) {
        let instructions = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
        let prompt = messages.filter { $0.role != "system" }.map { m in
            m.role == "assistant" ? "Your previous answer:\n\(m.content)" : m.content
        }.joined(separator: "\n\n")
        return (instructions, prompt)
    }

    /// Maps framework errors to `LLMError` so callers handle every provider alike.
    static func map(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if #available(macOS 27, *) {
            if let e = error as? LanguageModelError {
                switch e {
                case .contextSizeExceeded: return LLMError.contextLengthExceeded(message: nil)
                case .rateLimited: return LLMError.busy(retryAfter: 10)
                case .guardrailViolation, .refusal: return LLMError.refused
                case .unsupportedLanguageOrLocale: return LLMError.unsupportedLanguage
                default: return LLMError.server(message: e.localizedDescription)
                }
            }
            if error is SystemLanguageModel.Error { return LLMError.modelUnavailable }
            if let e = error as? LanguageModelSession.Error, e == .concurrentRequests { return LLMError.busy(retryAfter: 5) }
        }
        if let e = error as? LanguageModelSession.GenerationError {
            switch e {
            case .exceededContextWindowSize: return LLMError.contextLengthExceeded(message: nil)
            case .assetsUnavailable: return LLMError.modelUnavailable
            case .guardrailViolation, .refusal: return LLMError.refused
            case .unsupportedLanguageOrLocale: return LLMError.unsupportedLanguage
            case .rateLimited, .concurrentRequests: return LLMError.busy(retryAfter: 10)
            default: return LLMError.server(message: e.localizedDescription)
            }
        }
        return error
    }
}
