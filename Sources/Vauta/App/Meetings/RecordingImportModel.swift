// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import Observation
import UniformTypeIdentifiers

/// "Import Recording…": the user picks an audio or video file and its
/// language; Vauta transcribes it on this Mac into a new meeting, then the
/// minutes are written as for a live meeting. The file is only read.
@MainActor
@Observable
final class RecordingImportModel {
    enum Phase: Equatable {
        case idle
        case inspecting
        /// File read: choose the language.
        case ready
        case downloading(Double)
        case transcribing(Double)
        case saving
    }

    var phase: Phase = .idle
    var file: RecordingTranscriber.FileInfo?
    var languages: [SpeechLanguage] = []
    var languageID = "" { didSet { if languageID != oldValue { failureIsModelMissing = false } } }
    /// The last failure, shown in the sheet (the user can retry or cancel).
    var failure: String?
    /// The failure is about the transcription language (so the advice is to choose another one).
    var failureIsLanguage = false
    /// The failure is that the speech model isn't installed: the next try downloads it first (the button says so).
    var failureIsModelMissing = false

    var isPresented: Bool { phase != .idle }
    var isWorking: Bool {
        switch phase {
        case .downloading, .transcribing, .saving: true
        default: false
        }
    }
    var selectedLanguage: SpeechLanguage? { languages.first { $0.id == languageID } }
    /// The file's date will not be the meeting's (`RecordingImportPlan`): the sheet says so before the import starts.
    var redating: RecordingImportPlan.Redating? {
        file.flatMap { RecordingImportPlan.redating(recordedAt: $0.recordedAt, duration: $0.duration) }
    }

    @ObservationIgnored var llm: LLMService?
    @ObservationIgnored var preferences: Preferences?
    /// Called with the new meeting once it is stored.
    @ObservationIgnored var onImported: ((Int64) async -> Void)?
    @ObservationIgnored private let store: MeetingStore
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var scoped = false
    @ObservationIgnored private var task: Task<Void, Never>?

    init(store: MeetingStore) {
        self.store = store
    }

    /// Shows the open panel, then the import sheet.
    func chooseFile() async {
        guard !isPresented else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Recording", comment: "Open panel title")
        panel.message = String(localized: "Choose an audio or video recording of a meeting. Vauta transcribes it on this Mac; the file isn’t changed or copied.",
                               comment: "Open panel message when importing a recording")
        panel.prompt = String(localized: "Choose", comment: "Open panel button")
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let response: NSApplication.ModalResponse
        let window = NSApp.keyWindow.map { $0.sheetParent ?? $0 }
        if let window, window.attachedSheet == nil {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return }
        await begin(url)
    }

    /// The recording among files dropped on the Meetings window: exactly one audio or video file on this Mac, the types the
    /// open panel offers. Anything else (several files, a folder, a document) is not taken, so the drop is refused.
    nonisolated static func importable(_ urls: [URL]) -> URL? {
        guard urls.count == 1, let url = urls.first, url.isFileURL else { return nil }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
        guard let type, type.conforms(to: .audio) || type.conforms(to: .movie) else { return nil }
        return url
    }

    func begin(_ url: URL) async {
        finishAccess()
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
        failure = nil
        phase = .inspecting
        do {
            async let info = RecordingTranscriber.inspect(url)
            async let catalog = SpeechLanguages.catalog()
            let (fileInfo, languages) = try await (info, catalog)
            file = fileInfo
            self.languages = languages.languages.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            let preferred = preferences?.transcriptionLanguage.flatMap(languages.language(matching:)) ?? languages.defaultLanguage()
            languageID = preferred?.id ?? self.languages.first?.id ?? ""
            phase = .ready
        } catch {
            failure = Self.describe(error)
            failureIsLanguage = Self.isLanguageFailure(error)
            phase = .ready
            file = nil
        }
    }

    func start() {
        guard phase == .ready, let url, let file, let language = selectedLanguage else { return }
        failure = nil
        failureIsLanguage = false
        let modelMissing = failureIsModelMissing
        failureIsModelMissing = false
        let store = store, llm = llm, template = preferences?.minutesTemplate
        let separate = preferences?.separateSpeakers ?? true
        let recognize = preferences?.recognizesVoices ?? false
        let output: Locale? = switch preferences?.outputLanguage {
        case .fixed(let id): Locale(identifier: id)
        default: nil
        }
        task = Task {
            do {
                if !language.isInstalled || modelMissing {
                    phase = .downloading(0)
                    try await SpeechLanguages.install(language.locale, engine: language.preferredEngine) { p in
                        Task { @MainActor in
                            if case .downloading = self.phase { self.phase = .downloading(p) }
                        }
                    }
                }
                phase = .transcribing(0)
                // The speakers are found while the speech is recognized (two reads of the same file, side by side). A
                // failure there only leaves the meeting without speakers.
                async let diarization: Diarization? = separate ? try? await OfflineDiarization.diarize(url: url) : nil
                let segments = try await RecordingTranscriber.transcribe(url, locale: language.locale, engine: language.preferredEngine,
                                                                         collectWords: separate) { p in
                    Task { @MainActor in
                        if case .transcribing = self.phase { self.phase = .transcribing(p) }
                    }
                }
                try Task.checkCancellation()
                phase = .saving
                // Some containers don't report their length: use the transcript's end.
                let duration = file.duration > 0 ? file.duration : (segments.map(\.end).max() ?? 0)
                let plan = RecordingImportPlan(fileName: file.fileName, recordedAt: file.recordedAt, duration: duration)
                let id = try await store.importMeeting(plan, segments: segments, locale: language.locale, outputLocale: output,
                                                       diarization: await diarization, recognizeVoices: recognize)
                close()
                await llm?.meetingEnded(id, template: template, speakersEnabled: separate, recognizeVoices: recognize)   // embeddings and minutes, as for a live meeting
                await onImported?(id)
            } catch where error is CancellationError || Task.isCancelled {
                phase = .ready
            } catch {
                failure = Self.describe(error)
                failureIsLanguage = Self.isLanguageFailure(error)
                failureIsModelMissing = Self.isModelMissing(error)
                phase = .ready
            }
        }
    }

    /// Stops the work in progress, or closes the sheet.
    func cancel() {
        if isWorking {
            task?.cancel()
            task = nil
            phase = .ready
        } else {
            close()
        }
    }

    private func close() {
        task = nil
        phase = .idle
        file = nil
        failure = nil
        failureIsModelMissing = false
        finishAccess()
    }

    private func finishAccess() {
        if scoped { url?.stopAccessingSecurityScopedResource() }
        scoped = false
        url = nil
    }

    private static func isModelMissing(_ error: Error) -> Bool {
        guard let error = error as? CaptureError else { return false }
        return error.code == .speechModelMissing || error.code == .dictationModelMissing
    }

    private static func isLanguageFailure(_ error: Error) -> Bool {
        guard let error = error as? CaptureError else { return false }
        return [.localeUnsupported, .speechModelMissing, .dictationModelMissing, .analyzerFormatUnavailable, .languageLimitReached].contains(error.code)
    }

    private static func describe(_ error: Error) -> String {
        var parts = [error.localizedDescription]
        if let suggestion = (error as? LocalizedError)?.recoverySuggestion { parts.append(suggestion) }
        return parts.joinedAsSentences()
    }
}
