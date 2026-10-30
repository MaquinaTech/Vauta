// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Speech

/// On-device speech models. The only connection the system makes outside your
/// machines is the model download from Apple, and only through `install(...)`,
/// which the user starts: transcribing never downloads anything.
public enum SpeechAssets {
    /// The SpeechTranscriber locale equivalent to `identifier` (BCP-47).
    public static func locale(for identifier: String) async throws -> Locale {
        guard SpeechTranscriber.isAvailable else { throw CaptureError(.speechUnavailable) }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            throw CaptureError(.localeUnsupported, localeIdentifier: identifier)
        }
        return locale
    }

    public static func status(_ locale: Locale) async -> AssetInventory.Status {
        await status(locale, engine: .speech)
    }

    public static func status(_ locale: Locale, engine: SpeechEngineKind) async -> AssetInventory.Status {
        await AssetInventory.status(forModules: [module(locale, engine)])
    }

    /// Fails if the model isn't installed, instead of transcribing with a model
    /// that doesn't match (quality silently collapses).
    public static func requireInstalled(_ locale: Locale, engine: SpeechEngineKind = .speech) async throws {
        guard await status(locale, engine: engine) == .installed else {
            throw CaptureError(engine == .speech ? .speechModelMissing : .dictationModelMissing, locale: locale)
        }
    }

    /// Downloads and installs the SpeechTranscriber model from Apple (once).
    public static func install(_ locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await SpeechLanguages.install(locale, engine: .speech, progress: progress)
    }

    /// `confidence` also asks for each word's confidence: only the evaluation of public audio does (`transcribeFileScored`).
    static func module(_ locale: Locale, _ engine: SpeechEngineKind, confidence: Bool = false) -> any SpeechModule {
        switch engine {
        case .speech: speechModule(locale, confidence: confidence)
        case .dictation: dictationModule(locale, confidence: confidence)
        }
    }

    static func speechModule(_ locale: Locale, confidence: Bool = false) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
                          attributeOptions: confidence ? [.audioTimeRange, .transcriptionConfidence] : [.audioTimeRange])
    }

    static func dictationModule(_ locale: Locale, confidence: Bool = false) -> DictationTranscriber {
        DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation], reportingOptions: [.volatileResults],
                             attributeOptions: confidence ? [.audioTimeRange, .transcriptionConfidence] : [.audioTimeRange])
    }

    // MARK: Dictation (custom vocabulary, or languages SpeechTranscriber lacks)

    public static func dictationStatus(_ locale: Locale) async -> AssetInventory.Status {
        await status(locale, engine: .dictation)
    }

    /// Downloads the DictationTranscriber model from Apple (once, on request).
    public static func installDictation(_ locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await SpeechLanguages.install(locale, engine: .dictation, progress: progress)
    }
}
