// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Translation

/// Which of Apple's two model families a session uses.
public enum TranslationStrategy: Sendable, Equatable {
    /// Smaller and faster; macOS 26.4 and later. Made for live use.
    case lowLatency
    /// The family every macOS 26 has.
    case highFidelity
}

/// Apple's Translation framework, on device. Nothing here touches the network:
/// `TranslationSession(installedSource:target:)` only works with language
/// models already on this Mac, and downloads go through the system's own
/// consent sheet (see `TranslationDownloader` in the app).
public struct AppleTranslationBackend: TranslationBackend {
    public init() {}

    /// Every language Apple can translate, as the system reports them.
    public func supportedLanguages() async -> [Locale.Language] {
        await LanguageAvailability().supportedLanguages
    }

    public func availability(from source: Locale.Language, to target: Locale.Language) async -> PairAvailability {
        guard !source.isSameLanguage(as: target) else { return .unsupported }
        let statuses = await [status(.lowLatency, source, target), status(.highFidelity, source, target)]
        if statuses.contains(.installed) { return .installed }
        return statuses.contains(.supported) ? .downloadable : .unsupported
    }

    /// "low-latency: supported, high-fidelity: installed", for diagnostics.
    public func describeStatuses(from source: Locale.Language, to target: Locale.Language) async -> String {
        let low = await status(.lowLatency, source, target), high = await status(.highFidelity, source, target)
        return "low-latency: \(low), high-fidelity: \(high)"
    }

    /// The family to download for a pair that is not installed: the faster one when the Mac offers it.
    public func downloadStrategy(from source: Locale.Language, to target: Locale.Language) async -> TranslationStrategy {
        await status(.lowLatency, source, target) == .supported ? .lowLatency : .highFidelity
    }

    public func makeTranslator(from source: Locale.Language, to target: Locale.Language) async throws -> any Translator {
        // The faster family when it is installed, otherwise the one that is.
        let strategy: TranslationStrategy = await status(.lowLatency, source, target) == .installed ? .lowLatency : .highFidelity
        return try await makeTranslator(from: source, to: target, strategy: strategy)
    }

    public func makeTranslator(from source: Locale.Language, to target: Locale.Language, strategy: TranslationStrategy) async throws -> any Translator {
        let session: TranslationSession
        // Explicit even for high fidelity: the default depends on how the app was built.
        if #available(macOS 26.4, *) {
            session = TranslationSession(installedSource: source, target: target,
                                         preferredStrategy: strategy == .lowLatency ? .lowLatency : .highFidelity)
        } else {
            session = TranslationSession(installedSource: source, target: target)
        }
        guard await session.isReady else { throw TranslationError.notInstalled }
        return GuardedTranslator(AppleTranslator(session: session), target: target)
    }

    private func status(_ strategy: TranslationStrategy, _ source: Locale.Language, _ target: Locale.Language) async -> LanguageAvailability.Status {
        if strategy == .lowLatency {
            guard #available(macOS 26.4, *) else { return .unsupported }
            return await LanguageAvailability(preferredStrategy: .lowLatency).status(from: source, to: target)
        }
        if #available(macOS 26.4, *) {
            return await LanguageAvailability(preferredStrategy: .highFidelity).status(from: source, to: target)
        }
        return await LanguageAvailability().status(from: source, to: target)
    }
}

/// One long-lived `TranslationSession`. The session is used from one pair of
/// tasks at most (a final and a provisional translation), and the framework
/// serializes its own work.
private final class AppleTranslator: Translator, @unchecked Sendable {
    private let session: TranslationSession

    init(session: TranslationSession) { self.session = session }

    func translate(_ text: String) async throws -> String {
        let response = try await session.translate(text)
        try Task.checkCancellation()
        return response.targetText
    }

    func translate(batch: [String]) async throws -> [String] {
        guard batch.count > 1 else { return try await batch.isEmpty ? [] : [translate(batch[0])] }
        let requests = batch.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
        var out = [String?](repeating: nil, count: batch.count)
        for try await response in session.translate(batch: requests) {
            if let id = response.clientIdentifier.flatMap(Int.init), out.indices.contains(id) { out[id] = response.targetText }
        }
        try Task.checkCancellation()
        // A text the framework skipped comes back empty (not stored) rather than failing the batch;
        // its source text must never be stored as if it were the translation.
        return out.map { $0 ?? "" }
    }
}
