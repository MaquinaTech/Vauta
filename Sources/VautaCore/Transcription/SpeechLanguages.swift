// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Speech

/// The two on-device recognition modules.
public enum SpeechEngineKind: String, Sendable, Codable, CaseIterable {
    /// SpeechTranscriber: best quality, fewer languages. Preferred.
    case speech
    /// DictationTranscriber: more languages, custom vocabulary.
    case dictation
}

/// A transcription language and the engines that support it on this Mac.
public struct SpeechLanguage: Sendable, Hashable, Identifiable {
    public let locale: Locale
    /// Supporting engines, best first.
    public let engines: [SpeechEngineKind]
    /// Engines whose model for this language is installed.
    public let installed: Set<SpeechEngineKind>

    /// BCP-47 identifier (e.g. `es-ES`).
    public var id: String { locale.identifier(.bcp47) }
    /// SpeechTranscriber when it supports the language, else DictationTranscriber.
    public var preferredEngine: SpeechEngineKind { engines.first ?? .dictation }
    public var isInstalled: Bool { installed.contains(preferredEngine) }
    public var displayName: String { Locale.current.localizedString(forIdentifier: id) ?? id }
}

/// The languages available for transcription, built from the lists the system
/// reports (pure, so the selection logic is testable with injected lists).
public struct SpeechLanguageCatalog: Sendable {
    /// Sorted by identifier.
    public let languages: [SpeechLanguage]

    public init(speech: [Locale], dictation: [Locale], installedSpeech: [Locale] = [], installedDictation: [Locale] = []) {
        func ids(_ locales: [Locale]) -> Set<String> { Set(locales.map { $0.identifier(.bcp47) }) }
        let speechIDs = ids(speech), dictationIDs = ids(dictation)
        let installedSpeechIDs = ids(installedSpeech), installedDictationIDs = ids(installedDictation)
        languages = speechIDs.union(dictationIDs).sorted().map { id in
            var engines: [SpeechEngineKind] = []
            if speechIDs.contains(id) { engines.append(.speech) }
            if dictationIDs.contains(id) { engines.append(.dictation) }
            var installed: Set<SpeechEngineKind> = []
            if installedSpeechIDs.contains(id) { installed.insert(.speech) }
            if installedDictationIDs.contains(id) { installed.insert(.dictation) }
            return SpeechLanguage(locale: Locale(identifier: id), engines: engines, installed: installed)
        }
    }

    /// The language that best matches `identifier` (see `LocaleMatcher`).
    public func language(matching identifier: String) -> SpeechLanguage? {
        guard let id = LocaleMatcher.bestMatch(for: identifier, in: languages.map(\.id)) else { return nil }
        return languages.first { $0.id == id }
    }

    /// The first of `preferredLanguages` that is supported (by either engine),
    /// else en-US, else the first language.
    public func defaultLanguage(preferredLanguages: [String] = Locale.preferredLanguages) -> SpeechLanguage? {
        for preferred in preferredLanguages {
            if let language = language(matching: preferred) { return language }
        }
        return language(matching: SpeechLanguages.fallbackIdentifier) ?? languages.first
    }
}

/// Matches a requested language against supported locale identifiers.
enum LocaleMatcher {
    /// The exact identifier if supported; else one with the same language and
    /// script, preferring the same region, then the language's default region
    /// (es-AR → es-ES, pt → pt-BR, zh-TW → zh-TW, zh → zh-CN). Nil if the
    /// language isn't supported at all.
    static func bestMatch(for requested: String, in candidates: [String]) -> String? {
        let want = Parts(requested)
        if let exact = candidates.first(where: { Parts($0).bcp47 == want.bcp47 }) { return exact }
        let sameLanguage = candidates.filter {
            let p = Parts($0)
            return p.language == want.language && p.script == want.script
        }.sorted()
        if let sameRegion = sameLanguage.first(where: { Parts($0).region == want.region }) { return sameRegion }
        let defaultRegion = Parts([want.language, want.script].compactMap { $0 }.joined(separator: "-")).region
        return sameLanguage.first { Parts($0).region == defaultRegion } ?? sameLanguage.first
    }

    /// Language, script and region with likely subtags filled in.
    private struct Parts {
        let bcp47: String
        let language: String?
        let script: String?
        let region: String?

        init(_ identifier: String) {
            let normalized = identifier.replacingOccurrences(of: "_", with: "-")
            bcp47 = Locale(identifier: normalized).identifier(.bcp47).lowercased()
            let maximal = Locale.Language(identifier: Locale.Language(identifier: normalized).maximalIdentifier)
            language = maximal.languageCode?.identifier.lowercased()
            script = maximal.script?.identifier.lowercased()
            region = maximal.region?.identifier.uppercased()
        }
    }
}

/// System speech-language queries and model management.
public enum SpeechLanguages {
    /// Used when none of the user's preferred languages is supported.
    public static let fallbackIdentifier = "en-US"

    /// Supported and installed locales of both engines. A model counts as installed only when this app can use it, by the
    /// check a recording makes before it starts (`SpeechAssets.requireInstalled`). The system can list a model as installed
    /// that this app can't use: an ad-hoc build loses its reservations when an update signs it again. Settings then offered
    /// no download while the recording didn't start for want of that model.
    public static func catalog() async -> SpeechLanguageCatalog {
        async let speech = SpeechTranscriber.supportedLocales
        async let dictation = DictationTranscriber.supportedLocales
        async let installedSpeech = SpeechTranscriber.installedLocales
        async let installedDictation = DictationTranscriber.installedLocales
        let (speechLocales, dictationLocales) = await (speech, dictation)
        return SpeechLanguageCatalog(speech: SpeechTranscriber.isAvailable ? speechLocales : [], dictation: dictationLocales,
                                     installedSpeech: await usable(await installedSpeech, .speech),
                                     installedDictation: await usable(await installedDictation, .dictation))
    }

    /// The installed locales whose model `ready` says this app can use now.
    static func usable(_ locales: [Locale], _ engine: SpeechEngineKind,
                       ready: (Locale, SpeechEngineKind) async -> Bool = { await SpeechAssets.status($0, engine: $1) == .installed }) async -> [Locale] {
        var out: [Locale] = []
        for locale in locales where await ready(locale, engine) { out.append(locale) }
        return out
    }

    /// The default transcription language for this user (BCP-47).
    public static func defaultIdentifier() async -> String {
        await catalog().defaultLanguage()?.id ?? fallbackIdentifier
    }

    /// Model status of `locale` for `engine`.
    public static func status(_ locale: Locale, engine: SpeechEngineKind) async -> AssetInventory.Status {
        await SpeechAssets.status(locale, engine: engine)
    }

    /// Model status of `language` for its preferred engine.
    public static func status(of language: SpeechLanguage) async -> AssetInventory.Status {
        await status(language.locale, engine: language.preferredEngine)
    }

    /// The engine to transcribe `language` with: SpeechTranscriber when it
    /// supports the language, unless a vocabulary is wanted and dictation can
    /// use it (only DictationTranscriber takes a vocabulary).
    public static func engine(for language: SpeechLanguage, vocabulary: [String] = []) -> TranscriptionEngine {
        let speech = language.engines.contains(.speech), dictation = language.engines.contains(.dictation)
        if speech && (vocabulary.isEmpty || !dictation) { return .speech }
        return .dictation(vocabulary: vocabulary)
    }

    /// Downloads and installs the model of `locale` for `engine` from Apple,
    /// reserving the locale first. When the reservation limit is reached, the
    /// least recently used reservation outside `active` is released.
    /// Cancelling the task cancels the download.
    public static func install(_ locale: Locale, engine: SpeechEngineKind, keeping active: Set<String> = [],
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        try await reserve(locale, keeping: active)
        SpeechLanguageUsage().noteUsed([locale.identifier(.bcp47)])
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [SpeechAssets.module(locale, engine)]) else {
            progress(1)   // already installed
            return
        }
        let observation = request.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
        defer { observation.invalidate() }
        try await withTaskCancellationHandler {
            try await request.downloadAndInstall()
        } onCancel: {
            request.progress.cancel()
        }
    }

    /// Reserves `locale` for this app, releasing old reservations if needed.
    public static func reserve(_ locale: Locale, keeping active: Set<String> = []) async throws {
        let reserved = await AssetInventory.reservedLocales
        let plan = try ReservationPlanner.plan(reserving: locale.identifier(.bcp47), reserved: reserved.map { $0.identifier(.bcp47) },
                                               maximum: AssetInventory.maximumReservedLocales, active: active,
                                               lastUsed: SpeechLanguageUsage().lastUsed())
        for id in plan.release {
            if let match = reserved.first(where: { $0.identifier(.bcp47) == id }) {
                await AssetInventory.release(reservedLocale: match)
            }
        }
        if plan.reserve { try await AssetInventory.reserve(locale: locale) }
    }

    /// Releases this app's reservation of `locale` (the system may then
    /// remove its model if no other app uses it).
    public static func release(_ locale: Locale) async {
        let id = locale.identifier(.bcp47)
        for reserved in await AssetInventory.reservedLocales where reserved.identifier(.bcp47) == id {
            await AssetInventory.release(reservedLocale: reserved)
        }
    }

    /// BCP-47 identifiers this app has reserved.
    public static func reservedIdentifiers() async -> [String] {
        await AssetInventory.reservedLocales.map { $0.identifier(.bcp47) }
    }
}

/// What to release and whether to reserve, to fit within the system limit.
struct ReservationPlanner {
    struct Plan: Equatable {
        var release: [String]
        var reserve: Bool
    }

    /// Throws `languageLimitReached` if every reservation is in `active`.
    static func plan(reserving target: String, reserved: [String], maximum: Int, active: Set<String>,
                     lastUsed: [String: Date]) throws -> Plan {
        if reserved.contains(target) { return Plan(release: [], reserve: false) }
        let excess = reserved.count - max(maximum, 1) + 1
        guard excess > 0 else { return Plan(release: [], reserve: true) }
        let candidates = reserved.filter { !active.contains($0) }.sorted {
            let a = lastUsed[$0] ?? .distantPast, b = lastUsed[$1] ?? .distantPast
            return a != b ? a < b : $0 < $1
        }
        guard candidates.count >= excess else { throw CaptureError(.languageLimitReached, localeIdentifier: target) }
        return Plan(release: Array(candidates.prefix(excess)), reserve: true)
    }
}

/// When each transcription language was last used (for releasing the least
/// recently used reservation). Stored in UserDefaults as BCP-47 → timestamp.
struct SpeechLanguageUsage {
    static let defaultsKey = "speechLanguageLastUsed"
    var defaults: UserDefaults = .standard

    func lastUsed() -> [String: Date] {
        let raw = defaults.dictionary(forKey: Self.defaultsKey) as? [String: Double] ?? [:]
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    func noteUsed(_ identifiers: [String], at date: Date = .now) {
        var raw = defaults.dictionary(forKey: Self.defaultsKey) as? [String: Double] ?? [:]
        for id in identifiers { raw[id] = date.timeIntervalSince1970 }
        defaults.set(raw, forKey: Self.defaultsKey)
    }
}
