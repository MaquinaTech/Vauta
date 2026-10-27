// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import IOKit.ps
import Observation
import UniformTypeIdentifiers

/// The documents the person added as knowledge sources: what Settings → Documents shows and does, what Ask and the meeting's
/// Materials use. It owns the index, the indexer and the background embedding of passages.
@MainActor
@Observable
final class DocumentsModel {
    /// Something to say after an add or a drop.
    enum Note: Equatable {
        case added(String)
        case alreadyIncluded(String)
        case containsExisting(String)
        case ownData
        case unsupported
        case failed

        /// The note for a failed add, attach or locate.
        static func note(for error: Error) -> Note {
            switch error as? DocumentSourceError {
            case .alreadyIncluded(let name)?: .alreadyIncluded(name)
            case .containsExisting(let name)?: .containsExisting(name)
            case .ownData?: .ownData
            case .unsupportedFile?: .unsupported
            case .wrongKind?, nil: .failed
            }
        }

        var text: String {
            switch self {
            case .added(let name): String(localized: "Added “\(name)”. Indexing started.", comment: "Documents pane: shown after a folder or file was added; the argument is its name")
            case .alreadyIncluded(let name): String(localized: "Already included in “\(name)”.", comment: "Documents pane: the folder or file is inside a source that was added before; the argument is that source's name")
            case .containsExisting(let name): String(localized: "This folder contains “\(name)”, which is already a source. Remove it first, or add a folder inside it.", comment: "Documents pane: the folder holds a source that was added before; the argument is that source's name")
            case .ownData: String(localized: "This folder is or contains Vauta’s own data. Choose another one.", comment: "Documents pane: the folder chosen is Vauta's own container, or a folder that holds it (for example the home folder)")
            case .unsupported: String(localized: "Vauta can’t read this kind of file.", comment: "Documents pane: a dropped or chosen file is of a kind Vauta does not read")
            case .failed: String(localized: "Couldn’t add it. Try again.", comment: "Documents pane: adding a source failed")
            }
        }
    }

    /// The Skipped Files sheet: a source and its files that were not (fully) indexed.
    struct SkippedList: Identifiable {
        let source: DocumentSourceStatus
        let files: [SkippedEntry]
        var id: Int64 { source.id }
    }

    struct SkippedEntry: Identifiable, Equatable {
        let id: Int64
        let name: String
        let folder: String
        let reason: DocumentSkipReason
        let size: Int64
        /// The kind of file: "too large" names the limit of that kind.
        var format: DocumentFormat = .pdf
        /// A whole folder that a cloud service keeps online only (stored as `Folder/`): nothing inside it was read.
        var isFolder = false
    }

    private(set) var snapshot = DocumentsSnapshot()
    /// What to say after adds, drops and failed Locate… attempts: one line for each item, not only the last.
    var notes: [Note] = []
    var removing: DocumentSourceStatus?
    var skipped: SkippedList?
    /// The help sheet of the line that counts files the Mac does not hold (Google Drive shortcuts, files kept online only).
    var cloudHelp: DocumentSourceStatus?
    /// A drop is over the list: it highlights.
    var dropTargeted = false

    var ocrEnabled: Bool {
        didSet {
            defaults.set(ocrEnabled, forKey: Self.ocrKey)
            Task { await indexer?.setOCR(enabled: ocrEnabled) }
        }
    }

    /// Search by meaning on a model server on the network also embeds every passage: only when the person turns it on.
    var networkEmbeddings: Bool {
        didSet {
            defaults.set(networkEmbeddings, forKey: Self.networkKey)
            if networkEmbeddings { scheduleEmbedding() }
        }
    }

    /// The embedding model runs on another computer: the toggle is offered (and the privacy note says so).
    var embeddingsOnNetwork = false

    /// The confirmation of Remove…: one place for the pane and its snapshot.
    static func removeTitle(_ name: String) -> String {
        String(localized: "Remove “\(name)”?", comment: "Documents pane: confirmation title; the argument is the name of the folder or file")
    }

    static func removeMessage(_ kind: DocumentSource.Kind) -> String {
        switch kind {
        case .folder: String(localized: "Vauta deletes its index of this folder. Your files are not touched.", comment: "Documents pane: what removing a folder source does")
        case .file: String(localized: "Vauta deletes its index of this file. Your files are not touched.", comment: "Documents pane: what removing a file source does")
        }
    }

    /// The menu item (not the speech models' "Remove…": a source is only taken out of Vauta's index, never deleted).
    static var removeMenuLabel: String { String(localized: "Remove Source…", comment: "Documents pane: the menu item that removes a folder or file from the sources; the files themselves are never deleted") }

    static var removeLabel: String { String(localized: "Remove", comment: "Documents pane: the destructive button that removes a source") }

    static let ocrKey = "documentsOCR"
    static let networkKey = "documentsNetworkEmbeddings"

    @ObservationIgnored let store: MeetingStore?
    @ObservationIgnored let index: DocumentIndex?
    @ObservationIgnored let indexer: DocumentIndexer?
    @ObservationIgnored weak var llm: LLMService?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var embedding: Task<Void, Never>?
    @ObservationIgnored private var announced = Set<String>()
    @ObservationIgnored private var lastAnnouncement = Date.distantPast
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var environment: @Sendable () async -> IndexerEnvironment = { await DocumentsModel.environment() }

    /// The home folder that paths are written relative to (`~`): this Mac's, or the invented one of a rendering.
    @ObservationIgnored var displayHome = DocumentsModel.realHome

    /// A model for a rendering (snapshot scenes): fixed state, no index and no indexer.
    init(preview snapshot: DocumentsSnapshot, skipped: SkippedList? = nil, defaults: UserDefaults = .standard) {
        displayHome = "/Users/maya"
        self.snapshot = snapshot
        self.skipped = skipped
        self.defaults = defaults
        store = nil
        index = nil
        indexer = nil
        ocrEnabled = snapshot.ocrEnabled
        networkEmbeddings = false
    }

    init(store: MeetingStore, index: DocumentIndex, access: any SourceAccessing = SecurityScopedAccess(),
         environment: @escaping @Sendable () async -> IndexerEnvironment, defaults: UserDefaults = .standard) {
        self.store = store
        self.index = index
        self.defaults = defaults
        indexer = DocumentIndexer(store: store, index: index, access: access, environment: environment)
        self.environment = environment
        ocrEnabled = defaults.object(forKey: Self.ocrKey) as? Bool ?? true
        networkEmbeddings = defaults.object(forKey: Self.networkKey) as? Bool ?? false
    }

    // MARK: Lifecycle

    func start(llm: LLMService?) {
        guard let indexer else { return }
        self.llm = llm
        Task { [weak self] in
            guard let self else { return }
            await llm?.setDocuments(index)
            await indexer.setOCR(enabled: ocrEnabled)
            await indexer.setOnChange { [weak self] snapshot in
                Task { @MainActor in self?.received(snapshot) }
            }
            await indexer.start()
            await refreshEmbeddingRoute()
            received(await indexer.snapshot())
        }
        // A recording starting or stopping, Low Power Mode, a hot Mac, the charger, a drive that comes back.
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { await self?.indexer?.environmentChanged() }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { await self?.indexer?.volumesChanged() }
        })
    }

    func stop() async { await indexer?.stop() }

    /// The Mac's state changed (the recorder's phase).
    func environmentChanged() {
        // Embedding stops with the indexer when a recording starts; it starts again when the pause ends.
        Task { [weak self] in
            guard let self else { return }
            if !IndexerPolicy.decide(await environment()).embeddings { embedding?.cancel() }
            await indexer?.environmentChanged()
        }
    }

    /// Erase Everything or a restore replaced the store: the index belonged to the old data and its key is gone. It starts over
    /// from the sources the store has now (none after an erase; a restored backup brings its own, indexed again).
    func dataReplaced() {
        Task {
            await indexer?.resetAfterReplacement()
            if let indexer { received(await indexer.snapshot()) }
        }
    }

    private func received(_ new: DocumentsSnapshot) {
        let before = snapshot
        snapshot = new
        announce(from: before, to: new)
        if !new.isIndexing { scheduleEmbedding() }
    }

    /// VoiceOver: when a source finishes ("Documents indexed: Projects."), throttled to one per 30 seconds. Per-file progress is never announced.
    private func announce(from before: DocumentsSnapshot, to new: DocumentsSnapshot) {
        for status in new.sources {
            guard case .upToDate = status.state, let previous = before.sources.first(where: { $0.id == status.id }) else { continue }
            // A source whose last step was reading text in images finishes the same way.
            let wasWorking: Bool = switch previous.state {
            case .indexing, .readingImages: true
            default: false
            }
            if wasWorking, Date().timeIntervalSince(lastAnnouncement) >= 30 {
                lastAnnouncement = .now
                let text = String(localized: "Documents indexed: \(status.source.displayName).", comment: "VoiceOver announcement when a source has been indexed; the argument is its name")
                AccessibilityNotification.Announcement(text).post()
                if status.counts.skipped > 0 {
                    let more = String(localized: "Couldn’t read \(status.counts.skipped) files in \(status.source.displayName).", comment: "VoiceOver announcement: some files of a source were skipped; the arguments are the number of files and the source's name")
                    AccessibilityNotification.Announcement(more).post()
                }
            }
        }
    }

    // MARK: Adding

    func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add", comment: "Open panel button that adds the chosen folders as document sources")
        panel.message = String(localized: "Choose folders Vauta may read. Your files are never changed.", comment: "Open panel message when adding document folders")
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = DocumentFormat.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = String(localized: "Add", comment: "Open panel button that adds the chosen files as document sources")
        panel.message = String(localized: "Choose files Vauta may read. Your files are never changed.", comment: "Open panel message when adding document files")
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    /// Folders and files from the panel or a drop.
    func add(_ urls: [URL]) {
        guard let indexer else { return }
        Task {
            var results: [Note] = []
            for url in urls {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                do {
                    let source = try await indexer.addSource(url, isDirectory: isDirectory, ownData: [URL(fileURLWithPath: NSHomeDirectory())])
                    results.append(.added(source.displayName))
                } catch {
                    results.append(Note.note(for: error))
                }
            }
            // Every item says what became of it; an error is not hidden by a success after it, nor the other way round.
            notes = results
            // Problems first: they are what the person has to act on.
            let problems = results.filter { if case .added = $0 { false } else { true } }
            var speech = problems.map(\.text)
            if case .added(let name)? = results.first(where: { if case .added = $0 { true } else { false } }) {
                speech.append(String(localized: "Added \(name). Indexing started.", comment: "VoiceOver announcement after a source was added; the argument is its name"))
            }
            if !speech.isEmpty { AccessibilityNotification.Announcement(speech.joined(separator: " ")).post() }
            received(await indexer.snapshot())
        }
    }

    // MARK: Row actions

    /// Marks (or unmarks) a folder as holding notes exported from Notes: the brief labels its excerpts "Note". Nothing is read from Notes.
    func setNotesExport(_ status: DocumentSourceStatus, _ isNotes: Bool) {
        guard let store else { return }
        Task {
            try? await store.setDocumentSourceNotesExport(status.id, isNotes)
            if let indexer { received(await indexer.snapshot()) }
        }
    }

    /// Changes whenever the documents the brief searches change: files indexed or removed, or a source marked as notes. A cached brief
    /// is built again then.
    var briefGeneration: Int {
        var hasher = Hasher()
        hasher.combine(snapshot.totalFiles)
        hasher.combine(snapshot.totalCharacters)
        hasher.combine(snapshot.totalPassages)
        for status in snapshot.sources { hasher.combine(status.id); hasher.combine(status.source.isNotesExport); hasher.combine(status.source.paused) }
        return hasher.finalize()
    }

    func setPaused(_ status: DocumentSourceStatus, _ paused: Bool) {
        Task { try? await indexer?.setPaused(status.id, paused) }
    }

    func setAllPaused(_ paused: Bool) {
        Task { try? await indexer?.setAllPaused(paused) }
    }

    func reindex(_ status: DocumentSourceStatus) {
        Task { try? await indexer?.reindex(status.id) }
    }

    func remove(_ status: DocumentSourceStatus) {
        removing = nil
        Task {
            try? await indexer?.removeSource(status.id)
            if let indexer { received(await indexer.snapshot()) }
        }
    }

    /// `completion` gets the note of a failed locate (nil on success or cancel), for a caller that shows it itself.
    func locate(_ status: DocumentSourceStatus, completion: ((Note?) -> Void)? = nil) {
        let panel = NSOpenPanel()
        let isFolder = status.source.kind == .folder
        panel.canChooseDirectories = isFolder
        panel.canChooseFiles = !isFolder
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: status.source.path).deletingLastPathComponent()
        panel.prompt = String(localized: "Choose", comment: "Open panel button when locating a moved folder or file")
        panel.message = String(localized: "Choose the new place of “\(status.source.displayName)”.", comment: "Open panel message when locating a moved source; the argument is its name")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await indexer?.relocate(status.id, to: url, ownData: [URL(fileURLWithPath: NSHomeDirectory())])
                notes = []
                completion?(nil)
            } catch {
                // The wrong kind of item, a folder another source covers, Vauta's own data: said, not swallowed.
                notes = [Note.note(for: error)]
                completion?(notes.first)
            }
        }
    }

    func showInFinder(_ status: DocumentSourceStatus) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: status.source.path)])
    }

    func showSkipped(_ status: DocumentSourceStatus) {
        guard let index else { return }
        Task {
            let records = (try? await index.skipped(source: status.id)) ?? []
            skipped = SkippedList(source: status, files: records.map { record in
                let folder = (record.relPath as NSString).deletingLastPathComponent
                return SkippedEntry(id: record.id, name: record.name, folder: folder, reason: record.reason ?? .partial, size: record.size, format: record.format,
                                    isFolder: record.relPath.hasSuffix("/"))
            })
        }
    }

    // MARK: Display helpers

    /// The person's home folder as the file system says it: `NSHomeDirectory()` is the sandbox container.
    nonisolated static var realHome: String {
        getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    }

    /// A path with the home folder written as `~`.
    nonisolated static func abbreviated(_ path: String, home: String = realHome) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Indexed text as pages (the index holds up to about 25,000 pages: 2,400 characters each).
    nonisolated static func pages(characters: Int) -> Int { max(characters > 0 ? 1 : 0, characters / 2_400) }

    // MARK: Embeddings (search by meaning)

    /// Whether passages would go to a model server on the network: the switch for it only shows then.
    func refreshEmbeddingRoute() async {
        guard let llm else { return }
        embeddingsOnNetwork = await llm.documentEmbeddingRoute() == .network
    }

    /// The search model was installed (or the choice changed): the passages without a vector are embedded.
    func embeddingChoiceChanged() {
        Task { [weak self] in
            await self?.refreshEmbeddingRoute()
            self?.scheduleEmbedding()
        }
    }

    private func scheduleEmbedding() {
        guard embedding == nil, let llm else { return }
        embedding = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let allow = networkEmbeddings
                let route = await llm.documentEmbeddingRoute()
                embeddingsOnNetwork = route == .network
                // The same environment the indexer uses (a recording, Low Power Mode, the charger); embedding waits it out.
                let environment = self.environment
                let policy = IndexerPolicy.decide(await environment())
                if !policy.embeddings {
                    // Looked at again in a little while when the pause is temporary (the two minutes after a recording).
                    guard policy.pause != nil else { break }
                    try? await Task.sleep(for: .seconds(30))
                    continue
                }
                let done = await llm.embedDocumentPassages(allowNetwork: allow) { IndexerPolicy.decide(await environment()).embeddings }
                guard done > 0 else { break }
                try? await index?.save()
            }
            self?.embedding = nil
        }
    }

    // MARK: Environment

    /// The Mac's own state; the recorder adds whether a meeting records.
    nonisolated static func environment(recording: Bool = false, stoppedAt: Date? = nil) async -> IndexerEnvironment {
        IndexerEnvironment(isRecording: recording, recordingStoppedAt: stoppedAt, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                           thermalState: ProcessInfo.processInfo.thermalState, onBattery: onBattery)
    }

    nonisolated static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }
}
