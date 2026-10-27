// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation
import Observation
import Speech

/// Transcription languages and their on-device models, for Settings and the
/// setup. Downloads come from Apple and start only when the user asks.
@MainActor
@Observable
final class SpeechSettingsModel {
    /// Supported and installed languages; nil until loaded.
    private(set) var catalog: SpeechLanguageCatalog?
    /// Languages Vauta has reserved with the system (BCP-47).
    private(set) var reserved: [String] = []
    /// Downloads in progress: "<engine>:<language id>" → fraction completed.
    private(set) var downloads: [String: Double] = [:]
    private(set) var errorMessage: String?
    /// The language whose download failed (for "Try Again"), and whether it ran out of disk space.
    private(set) var failedInstall: SpeechLanguage?
    private(set) var failureNeedsSpace = false
    /// The engine of the failed download.
    private(set) var failedEngine: SpeechEngineKind?
    /// Why the last download failed, in words that fit a row of its own language (setup page).
    private(set) var rowErrorMessage: String?

    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    /// Called after a download ended (installed, failed or cancelled) and the catalog was read again, so the owner of
    /// this model (the recorder) can settle what it was waiting for.
    @ObservationIgnored var onInstallFinished: (@MainActor () async -> Void)?

    #if VAUTA_DIAGNOSTICS
    /// A download in progress or a failed one, as the snapshot renderer shows them (nothing is downloaded).
    func installSnapshotState(downloading language: SpeechLanguage?, progress: Double, failed: SpeechLanguage? = nil) {
        downloads = language.map { [Self.key($0.id, $0.preferredEngine): progress] } ?? [:]
        errorMessage = failed.map { snapshotFailure($0) }
        failedInstall = failed
        failureNeedsSpace = failed != nil
        failedEngine = failed?.preferredEngine
        rowErrorMessage = failed != nil ? Self.rowMessage(for: CocoaError(.fileWriteOutOfSpace)) : nil
    }

    private func snapshotFailure(_ language: SpeechLanguage) -> String {
        let name = language.displayName
        let error = CocoaError(.fileWriteOutOfSpace)
        return String(localized: "Couldn’t download the \(name) speech model. \(error.localizedDescription)",
                      comment: "Speech model download error; arguments are a language and the system error")
    }
    #endif

    /// How many languages the system lets one app reserve.
    var reservationLimit: Int { AssetInventory.maximumReservedLocales }

    func refresh() async {
        #if VAUTA_DIAGNOSTICS
        if SnapshotMode.languagesLoading { return }
        if let sample = SnapshotMode.catalog {
            catalog = sample
            reserved = SnapshotMode.reservedLanguages
            return
        }
        #endif
        async let catalog = SpeechLanguages.catalog()
        async let reserved = SpeechLanguages.reservedIdentifiers()
        self.catalog = await catalog
        self.reserved = await reserved
    }

    /// The language transcription uses: the saved choice, else the best match
    /// for the user's preferred languages.
    func effectiveLanguage(_ preferred: String?) -> SpeechLanguage? {
        guard let catalog else { return nil }
        if let preferred, let match = catalog.language(matching: preferred) { return match }
        return catalog.defaultLanguage()
    }

    /// Installed and reserved languages, for the "on this Mac" list.
    var languagesOnThisMac: [SpeechLanguage] {
        guard let catalog else { return [] }
        let reservedIDs = Set(reserved)
        // One alphabetical list, the language being downloaded included.
        return catalog.languages.filter { !$0.installed.isEmpty || reservedIDs.contains($0.id) || isDownloading($0) || failedInstall?.id == $0.id }
            .sorted { LanguageNameSort.precedes($0.displayName, $1.displayName) }
    }

    /// Why the download of this language and engine failed, when it did (for its own row).
    func failure(_ language: SpeechLanguage, engine: SpeechEngineKind? = nil) -> String? {
        guard failedInstall?.id == language.id, failedEngine == (engine ?? language.preferredEngine) else { return nil }
        return rowErrorMessage
    }

    /// The download of this language failed because the disk is full: "Open Storage Settings" is the way out.
    func failureNeedsSpace(_ language: SpeechLanguage, engine: SpeechEngineKind? = nil) -> Bool {
        failure(language, engine: engine) != nil && failureNeedsSpace
    }

    /// Languages without a model yet, for "Add a language".
    var languagesToAdd: [SpeechLanguage] {
        guard let catalog else { return [] }
        return catalog.sortedForDisplay().filter { !$0.isInstalled && !isDownloading($0) }
    }

    func state(_ language: SpeechLanguage, engine: SpeechEngineKind? = nil) -> SpeechModelState {
        let engine = engine ?? language.preferredEngine
        guard language.engines.contains(engine) else { return .unsupported }
        if downloads[Self.key(language.id, engine)] != nil { return .downloading }
        return language.installed.contains(engine) ? .installed : .notInstalled
    }

    func progress(_ language: SpeechLanguage, engine: SpeechEngineKind? = nil) -> Double? {
        downloads[Self.key(language.id, engine ?? language.preferredEngine)]
    }

    func isDownloading(_ language: SpeechLanguage) -> Bool {
        language.engines.contains { downloads[Self.key(language.id, $0)] != nil }
    }

    func isReserved(_ language: SpeechLanguage) -> Bool { reserved.contains(language.id) }

    /// Downloads the model of `language` for `engine` (its preferred engine by
    /// default). `keeping` lists languages that must not be released to make room.
    /// Returns the download task (the one already running when there is one), which ends when the model is installed
    /// or the download stopped.
    @discardableResult
    func install(_ language: SpeechLanguage, engine: SpeechEngineKind? = nil, keeping: Set<String> = []) -> Task<Void, Never>? {
        let engine = engine ?? language.preferredEngine
        let key = Self.key(language.id, engine)
        if let running = tasks[key] { return running }
        errorMessage = nil
        rowErrorMessage = nil
        failedInstall = nil
        failedEngine = nil
        downloads[key] = 0
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            let model = self
            Task { @MainActor in model?.updateProgress(key, fraction) }
        }
        tasks[key] = Task { [weak self] in
            do {
                try await SpeechLanguages.install(language.locale, engine: engine, keeping: keeping.union([language.id]), progress: report)
            } catch is CancellationError {
                // Cancelled by the user: nothing to report.
            } catch {
                if !Task.isCancelled {
                    self?.failedInstall = language
                    self?.failedEngine = engine
                    self?.failureNeedsSpace = (error as? CocoaError)?.code == .fileWriteOutOfSpace
                    self?.rowErrorMessage = Self.rowMessage(for: error)
                    let name = language.displayName
                    self?.errorMessage = String(localized: "Couldn’t download the \(name) speech model. \(error.localizedDescription)",
                                                comment: "Speech model download error; arguments are a language and the system error")
                }
            }
            self?.downloads[key] = nil
            self?.tasks[key] = nil
            await self?.refresh()
            await self?.onInstallFinished?()
        }
        return tasks[key]
    }

    private func updateProgress(_ key: String, _ fraction: Double) {
        if downloads[key] != nil { downloads[key] = fraction }
    }

    func cancelInstall(_ language: SpeechLanguage, engine: SpeechEngineKind? = nil) {
        let key = Self.key(language.id, engine ?? language.preferredEngine)
        tasks[key]?.cancel()
    }

    /// Releases Vauta's reservation; macOS removes the model when no other app uses it.
    func remove(_ language: SpeechLanguage) async {
        await SpeechLanguages.release(language.locale)
        await refresh()
    }

    func clearError() { errorMessage = nil; rowErrorMessage = nil; failedInstall = nil; failedEngine = nil }

    /// The failure for a row that already names the language: the cause and what to do, never the system's raw text
    /// unless the cause is unknown.
    static func rowMessage(for error: Error) -> String {
        if (error as? CocoaError)?.code == .fileWriteOutOfSpace || (error as NSError).code == NSFileWriteOutOfSpaceError {
            return String(localized: "Not enough disk space. Free up space, then try again.",
                          comment: "Speech model download failed because the disk is full; next to the language's own row")
        }
        if let url = error as? URLError,
           [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff].contains(url.code) {
            return String(localized: "You’re offline. Connect to the internet, then try again.",
                          comment: "Speech model download failed because there is no internet connection; next to the language's own row")
        }
        let reason = error.localizedDescription
        return String(localized: "Couldn’t download the speech model. \(reason)",
                      comment: "Speech model download error next to the language's own row; the argument is the system's reason")
    }

    private static func key(_ id: String, _ engine: SpeechEngineKind) -> String { "\(engine.rawValue):\(id)" }
}

extension SpeechEngineKind {
    var displayName: String {
        switch self {
        case .speech: String(localized: "Speech recognition", comment: "Transcription engine (SpeechTranscriber)")
        case .dictation: String(localized: "Dictation", comment: "Transcription engine (DictationTranscriber)")
        }
    }
}

extension SpeechModelState {
    var label: String {
        switch self {
        case .installed: String(localized: "Installed", comment: "Speech model state")
        case .downloading: String(localized: "Downloading…", comment: "Speech model state")
        case .notInstalled: String(localized: "Not downloaded", comment: "Speech model state")
        case .unsupported: String(localized: "Not available", comment: "Speech model state")
        }
    }
}
