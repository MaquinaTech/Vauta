// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Live translation refinement: finished sentences re-translated by the model
/// server while a meeting runs. A caption is useful for a few seconds, so
/// these requests go straight to the server and do not queue in the lane;
/// live notes (which can wait) hold back while any is in flight.
extension LLMService {
    /// The longest live notes wait for translations: a continuous conversation must not starve them.
    static let maxWaitForRefinements: Duration = .seconds(20)

    /// Translator for `source` → `target` that uses the model server through the
    /// same client as everything else, with `model` (nil or empty = the fast model).
    /// nil when no server is set up. `purpose` is what the Network Activity list shows.
    public func refinementTranslator(source: Locale.Language, target: Locale.Language, model: String?,
                                     purpose: NetworkPurpose = .translation) -> ServerTranslator? {
        guard let chat = providers.refinementChat else { return nil }
        return ServerTranslator(chat: RefinementChat(service: self, inner: chat), source: source, target: target, model: model,
                                purpose: purpose)
    }

    /// Live notes wait here while translations are in flight (at most `maxWaitForRefinements`).
    func waitForRefinements() async throws {
        let deadline = ContinuousClock.now + Self.maxWaitForRefinements
        while refinementsInFlight > 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    fileprivate func refinementBegan() { refinementsInFlight += 1 }
    fileprivate func refinementEnded() { refinementsInFlight = max(0, refinementsInFlight - 1) }

    /// How many translation requests are in flight (tests and diagnostics).
    var activeRefinements: Int { refinementsInFlight }
}

/// The server chat model, counted by the service while a request is in flight.
private struct RefinementChat: ChatModel {
    let service: LLMService
    let inner: any ChatModel

    var contextTokens: Int? { get async { await inner.contextTokens } }

    func chat(_ messages: [ChatMessage], _ options: ChatOptions, onProgress: (@Sendable (Int) -> Void)?) async throws -> ChatResult {
        await service.refinementBegan()
        do {
            let result = try await inner.chat(messages, options, onProgress: onProgress)
            await service.refinementEnded()
            return result
        } catch {
            await service.refinementEnded()
            throw error
        }
    }
}
