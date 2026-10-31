// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation

/// Keeps the document index in step with the sources the person added: finds files, reads them one at a time in the
/// background, and notices changes (at launch, while running with FSEvents, and with a periodic scan).
///
/// Rules, all of them tested as pure policy or against a temporary folder:
/// - one file at a time, off the main actor, never while a meeting records (see `IndexerPolicy`);
/// - read-only access through `SourceAccessing`, only inside a source's scope;
/// - every limit of `DocumentLimits`;
/// - a crash guard: before a file is read its identity is written to `vauta.docs.extracting`; a marker found at launch means
///   Vauta died reading that file, so it is skipped ("Vauta closed while reading it") until it changes;
/// - the index is saved after every batch (50 files or 60 seconds) and at quit.
public actor DocumentIndexer {
    let store: MeetingStore
    let index: DocumentIndex
    let access: any SourceAccessing
    let extractor: any DocumentExtracting
    let environment: @Sendable () async -> IndexerEnvironment
    let markerURL: URL

    var sources: [Int64: DocumentSource] = [:]
    /// Where each readable source is now (a resolved bookmark), and why the others are not.
    var resolved: [Int64: URL] = [:]
    var unreachable: [Int64: SourceResolution] = [:]
    var checked: [Int64: Date] = [:]
    var truncated: Set<Int64> = []
    var watchers: [Int64: SourceWatcher] = [:]
    var runner: Task<Void, Never>?
    var runGeneration = 0
    /// `kick()` came while the loop was winding down: it runs once more when it ends.
    var rerunRequested = false
    /// The longest one file's text pass may take (a test shortens it).
    var textDeadline = DocumentLimits.textExtractionSeconds
    /// A test shortens the OCR step's deadline.
    var ocrDeadline: TimeInterval?
    /// The reads in flight, abandoned ones included.
    let extractions = ExtractionTracker()
    /// With this many Apple-parser reads stuck past their deadline no other one is started (until one ends).
    static let maxStuckParsers = 2
    var sleeper: Task<Void, Never>?
    var periodic: Task<Void, Never>?
    var processing = false
    /// The source whose file is being read now (the others that have files waiting say so).
    var currentSource: Int64?
    var ocrEnabled = true
    var indexFull = false
    var lastPolicy = IndexerPolicy()
    var crash: CrashMarker?
    var sinceSave = 0
    var lastSave = Date()
    var onChange: (@Sendable (DocumentsSnapshot) -> Void)?
    var lastPublish = Date.distantPast
    var publishScheduled = false
    /// The source scans in flight (with the ticket of each), so a burst of events does one scan.
    var scanning: [Int64: Int] = [:]
    /// Sources changed while their scan was in flight, which may have listed the folder before the change: scanned again after it
    /// (true: also with the skipped files queued again, as Reindex asked).
    var rescan: [Int64: Bool] = [:]
    var ticket = 0
    /// Counts the times the store was replaced (Erase Everything, Restore): work that started before it writes nothing.
    var epoch = 0
    /// Counts the changes to the list of sources, so a list read while one was removed is read again.
    var sourceChanges = 0
    /// Sources whose scan waits for the end of a recording (or for the charger, on a network volume).
    var dirty: Set<Int64> = []
    /// Sources on a network volume: rescanned every 30 minutes, never worked on while on battery.
    var nonLocal: Set<Int64> = []
    /// The image has changes that were not written because a meeting was recording.
    var unsaved = false
    var probe = FileProbe()
    var ioDeadline: TimeInterval = 15
    var charTotal: Int?
    var charReads = 0
    var started = false

    public init(store: MeetingStore, index: DocumentIndex, access: any SourceAccessing = SecurityScopedAccess(), extractor: any DocumentExtracting = DocumentExtractor(),
                environment: @escaping @Sendable () async -> IndexerEnvironment = { IndexerEnvironment() }) {
        self.store = store
        self.index = index
        self.access = access
        self.extractor = extractor
        self.environment = environment
        markerURL = store.storeDirectory.appendingPathComponent(StoreFiles.documentsMarker)
    }

    public func setOnChange(_ handler: @escaping @Sendable (DocumentsSnapshot) -> Void) {
        onChange = handler
    }

    // MARK: Crash guard

    /// Identifies the file being read without naming it: its source, a keyed hash of its relative path (HMAC with a key derived from
    /// the documents key, so a common name can't be confirmed by hashing guesses), and its size and date.
    struct CrashMarker: Codable, Equatable, Sendable {
        var source: Int64
        var path: String
        var size: Int64
        var mtime: Double

        /// The label the marker's HMAC key is derived with; never the documents key itself.
        static let keyLabel = "vauta.documents.marker.v1"

        init(source: Int64, relPath: String, size: Int64, mtime: Double, key: SymmetricKey) {
            self.source = source
            self.path = Self.hash(relPath, key: key)
            self.size = size
            self.mtime = mtime
        }

        static func hash(_ relPath: String, key: SymmetricKey) -> String {
            HMAC<SHA256>.authenticationCode(for: Data(relPath.utf8), using: key).prefix(8).map { String(format: "%02x", $0) }.joined()
        }

        func matches(source: Int64, relPath: String, size: Int64, mtime: Double, key: SymmetricKey) -> Bool {
            self.source == source && path == Self.hash(relPath, key: key) && self.size == size && self.mtime == mtime
        }
    }

    func writeMarker(_ marker: CrashMarker) {
        guard let data = try? JSONEncoder().encode(marker) else { return }
        try? AtomicFile.write(data, to: markerURL, tempPrefix: StoreFiles.documentsMarker + ".tmp-")
    }

    func clearMarker() { unlink(markerURL.path) }

    /// A marker found at launch: Vauta died reading that file.
    func recoverMarker() {
        guard let data = try? Data(contentsOf: markerURL), let marker = try? JSONDecoder().decode(CrashMarker.self, from: data) else {
            clearMarker()
            return
        }
        crash = marker
        clearMarker()
    }

    // MARK: Lifecycle

    /// Reads the sources, recovers from a crash, scans everything and starts reading. Call once at launch.
    public func start(background: Bool = true) async {
        guard !started else { return }
        started = true
        recoverMarker()
        // A deleted meeting takes its attached materials with it: their text goes from the index at once.
        await store.setMeetingsDeletedHandler { [weak self] in Task { await self?.meetingsDeleted() } }
        await reloadSources()
        await syncAll()
        if background { startPeriodicScan() }
        kick()
    }

    /// Stops the background work and saves the index (quit, or the store is locked).
    public func stop() async {
        await store.setMeetingsDeletedHandler(nil)
        periodic?.cancel()
        runner?.cancel()
        for watcher in watchers.values { watcher.stop() }
        watchers = [:]
        // A parser that never returns must not hold up quitting.
        _ = await waitForTask(runner, seconds: Self.stopWait)
        try? await index.save()
        started = false
    }

    /// Network volumes and single files are scanned this often (seconds) while mounted.
    static let networkScanInterval: TimeInterval = 1800

    /// The longest `stop()` and the reset after a replacement wait for the loop to wind down.
    static let stopWait: TimeInterval = 5

    func setTextDeadline(_ seconds: TimeInterval) { textDeadline = seconds }
    func setOCRDeadline(_ seconds: TimeInterval?) { ocrDeadline = seconds }

    func startPeriodicScan() {
        periodic?.cancel()
        periodic = Task { [weak self] in
            // The safety net for what FSEvents missed: every six hours all sources are scanned. Network volumes and single files
            // (no events for them) are scanned every 30 minutes.
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.networkScanInterval))
                guard !Task.isCancelled else { return }
                ticks += 1
                if ticks % 12 == 0 { await self?.syncAll() } else { await self?.syncPolled() }
                await self?.kick()
            }
        }
    }

    /// Meetings were deleted (by the person, retention or the knowledge window): the sources that went with them are removed from
    /// the index now and the image is saved, so their text is not left on the disk until the next scan.
    public func meetingsDeleted() async {
        await reloadSources()
        for id in Array(resolved.keys) where sources[id] == nil { resolved[id] = nil }
        for id in Array(unreachable.keys) where sources[id] == nil { unreachable[id] = nil }
        for id in Array(watchers.keys) where sources[id] == nil {
            watchers[id]?.stop()
            watchers[id] = nil
        }
        forgetCharacterTotal()
        var removed = false
        if let known = try? await index.allFileSourceIDs() {
            for orphan in known.subtracting(sources.keys) {
                try? await index.deleteSource(orphan)
                removed = true
            }
        }
        if removed { try? await index.save() }
        publish(force: true)
    }

    func reloadSources() async {
        // A source removed while the list was being read must not come back from it.
        while true {
            let seen = sourceChanges
            let all = (try? await store.documentSources()) ?? []
            guard seen == sourceChanges else { continue }
            sources = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            return
        }
    }

    // MARK: Changing sources

    /// Adds a folder or a file. `url` comes from an open panel or a drop (it carries the sandbox extension a bookmark needs).
    public func addSource(_ url: URL, isDirectory: Bool, attachedMeeting: Int64? = nil, ownData: [URL] = []) async throws -> DocumentSource {
        // A material attached to a meeting is its own source even when a library folder holds the file (attachMaterial decided
        // that the folder does not index it); the library's duplicate rules are for the library.
        try verify(url, isDirectory: isDirectory, existing: attachedMeeting == nil ? Array(sources.values) : [], ownData: ownData)
        let started = access.begin(url)
        defer { if started { access.end(url) } }
        let (bookmark, uuid) = try access.makeBookmark(for: url)
        let source = try await store.addDocumentSource(kind: isDirectory ? .folder : .file, displayName: url.lastPathComponent, path: url.path, bookmark: bookmark,
                                                       volumeUUID: uuid, attachedMeeting: attachedMeeting)
        sourceChanges += 1
        sources[source.id] = source
        await sync(source.id)
        kick()
        return source
    }

    /// The rules every source follows (own data, a kind Vauta reads, duplicates and nesting).
    func verify(_ url: URL, isDirectory: Bool, existing: [DocumentSource], ownData: [URL]) throws {
        switch DocumentSourceRules.check(url, isDirectory: isDirectory, existing: existing, ownData: ownData + [store.storeDirectory]) {
        case .ok: break
        case .alreadyIncluded(let name): throw DocumentSourceError.alreadyIncluded(name)
        case .containsExisting(let name): throw DocumentSourceError.containsExisting(name)
        case .ownData: throw DocumentSourceError.ownData
        case .unsupportedFile: throw DocumentSourceError.unsupportedFile
        }
    }

    /// Attaches a file to a meeting as its material. A file that is already inside a source of the library is linked to the meeting
    /// (it is indexed once); any other file becomes a single-file source that belongs to the meeting and goes with it.
    public func attachMaterial(_ url: URL, to meeting: Int64) async throws {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard DocumentFormat.format(forExtension: url.pathExtension) != nil else { throw DocumentSourceError.unsupportedFile }
        for source in sources.values.sorted(by: { $0.id < $1.id }) where source.attachedMeetingID == nil {
            let root = URL(fileURLWithPath: source.path).standardizedFileURL.resolvingSymlinksInPath().path
            // The file is itself a source of the library: linked under the name its row has.
            if source.kind == .file, path == root {
                try await store.linkMaterial(meeting: meeting, source: source.id, relPath: url.lastPathComponent)
                publish(force: true)
                return
            }
            guard source.kind == .folder, path.hasPrefix(root + "/") else { continue }
            let relPath = String(path.dropFirst(root.count + 1))
            // Linked only when the folder's scan lists the file (not a hidden one, nor under node_modules, nor past the depth or
            // file limits); otherwise Ask would never find a passage of it. Any other file is attached as a source of its own.
            let known = (try? await index.file(source: source.id, relPath: relPath)) != nil
            if known || (!truncated.contains(source.id) && DocumentScanner.listsRelativePath(relPath)) {
                try await store.linkMaterial(meeting: meeting, source: source.id, relPath: relPath)
                publish(force: true)
                return
            }
        }
        // The same file attached twice to one meeting is one attachment.
        if sources.values.contains(where: { $0.attachedMeetingID == meeting && $0.path == url.path }) { return }
        _ = try await addSource(url, isDirectory: false, attachedMeeting: meeting)
    }

    /// A file left the index (deleted, gone or its source unreachable for good): the answers stored with meetings lose the claims
    /// that cited it.
    func removeIndexedFile(_ record: DocumentFileRecord) async {
        try? await index.deleteFile(id: record.id)
        try? await store.purgeQuestionAnswers(documentSource: record.sourceID, relPath: record.relPath)
    }

    /// Removes the source: its bookmark (journaled) and then, at once, everything of its files in the index.
    public func removeSource(_ id: Int64) async throws {
        try await store.removeDocumentSource(id)
        sourceChanges += 1
        sources[id] = nil
        dirty.remove(id)
        nonLocal.remove(id)
        scanning[id] = nil
        rescan[id] = nil
        forgetCharacterTotal()
        resolved[id] = nil
        unreachable[id] = nil
        watchers[id]?.stop()
        watchers[id] = nil
        try await index.deleteSource(id)
        // Saved now, so the removed text is gone from the disk at this write and not at the next.
        try await index.save()
        publish(force: true)
    }

    public func setPaused(_ id: Int64, _ paused: Bool) async throws {
        try await store.setDocumentSourcePaused(id, paused)
        sources[id]?.paused = paused
        publish(force: true)
        if !paused { kick() }
    }

    public func setAllPaused(_ paused: Bool) async throws {
        for source in sources.values where source.attachedMeetingID == nil && source.paused != paused { try await setPaused(source.id, paused) }
    }

    /// Reads every file of the source again.
    public func reindex(_ id: Int64) async throws {
        try await index.requeue(source: id)
        await sync(id, requeueSkipped: true)
        kick()
    }

    /// The person found a moved source: the bookmark is replaced and the files are matched again by path, size and date, so
    /// the ones that did not change are not read again.
    public func relocate(_ id: Int64, to url: URL, ownData: [URL] = []) async throws {
        guard let source = sources[id] else { return }
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard isDirectory == (source.kind == .folder) else { throw DocumentSourceError.wrongKind }
        // The same rules as adding: not Vauta's own data, not a place another source already covers.
        let others = sources.values.filter { $0.id != id }
        try verify(url, isDirectory: isDirectory, existing: source.attachedMeetingID == nil ? others : [], ownData: ownData)
        let started = access.begin(url)
        defer { if started { access.end(url) } }
        let (bookmark, uuid) = try access.makeBookmark(for: url)
        try await store.updateDocumentSource(id, bookmark: bookmark, path: url.path, displayName: url.lastPathComponent, volumeUUID: uuid)
        await reloadSources()
        unreachable[id] = nil
        watchers[id]?.stop()
        watchers[id] = nil
        await sync(id)
        kick()
    }

    /// Erase Everything or a restore replaced the store. The index (sealed with a key that no longer exists) is emptied and takes
    /// the new key; the sources are read from the store as it is now and indexed again.
    public func resetAfterReplacement() async {
        // Scans and reads in flight belong to the old store: from here on they write nothing.
        epoch += 1
        sourceChanges += 1
        scanning = [:]
        rescan = [:]
        dirty = []
        nonLocal = []
        unsaved = false
        forgetCharacterTotal()
        runner?.cancel()
        _ = await waitForTask(runner, seconds: Self.stopWait)
        runner = nil
        runGeneration += 1
        for watcher in watchers.values { watcher.stop() }
        watchers = [:]
        sources = [:]
        resolved = [:]
        unreachable = [:]
        checked = [:]
        truncated = []
        indexFull = false
        crash = nil
        try? await index.eraseAll()
        await index.rekey(store.documentsKey())
        await syncAll()
        kick()
    }

    public func setOCR(enabled: Bool) {
        ocrEnabled = enabled
        publish(force: true)
        if enabled { kick() }
    }

    /// The Mac's state changed (a recording started or stopped, Low Power Mode, power source): look again.
    public func environmentChanged() async {
        let policy = IndexerPolicy.decide(await environment())
        lastPolicy = policy
        // A recording (or any other reason not to read) stops the file being read at once; it stays pending.
        if !policy.text, let current = runner {
            current.cancel()
            runner = nil
            runGeneration += 1
            processing = false
        }
        kick()
        publish(force: true)
    }

    /// The periodic scan of what has no file-system events: network volumes and single files, and what waited for a pause.
    func syncPolled() async {
        for id in sources.keys.sorted() where nonLocal.contains(id) || sources[id]?.kind == .file { await sync(id) }
        await syncDirty()
        kick()
    }

    /// A drive was mounted: sources that waited for it are looked at again.
    public func volumesChanged() async {
        let waiting = unreachable.filter { $0.value == .disconnected }.map(\.key)
        for id in waiting { await sync(id) }
        if !waiting.isEmpty { kick() }
    }

    // MARK: Reading a source's files for the viewer

    /// Runs `body` with the URL of a file of a source, inside the source's scope. nil when the source can't be reached.
    public func withFile<T>(source id: Int64, relPath: String, _ body: (URL) async throws -> T) async rethrows -> T? {
        guard let root = resolveRoot(id), let url = fileURL(source: id, root: root, relPath: relPath) else { return nil }
        let started = access.begin(root)
        defer { if started { access.end(root) } }
        return try await body(url)
    }

    /// The file at `relPath` in a source. A folder's path comes from the store and must be one the scan lists (no `..`,
    /// nothing hidden), so it never leads outside the folder the person chose.
    private func fileURL(source id: Int64, root: URL, relPath: String) -> URL? {
        if sources[id]?.kind == .file { return root }
        guard DocumentScanner.listsRelativePath(relPath) else { return nil }
        return root.appendingPathComponent(relPath)
    }

    /// A file open in the passage viewer: its access stays open until `closeViewing`.
    public struct ViewedFile: Sendable {
        public let url: URL
        let root: URL
        /// Whether `begin` opened an access that `closeViewing` must end.
        let began: Bool
    }

    /// The URL of a source's file with its sandbox access held open (a PDF reads from its file while it is shown). nil when
    /// the source can't be reached (a drive that is not connected, a moved folder).
    public func openForViewing(source id: Int64, relPath: String) -> ViewedFile? {
        guard let root = resolveRoot(id), let url = fileURL(source: id, root: root, relPath: relPath) else { return nil }
        let began = access.begin(root)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if began { access.end(root) }
            return nil
        }
        return ViewedFile(url: url, root: root, began: began)
    }

    /// Whether the file being viewed is only a placeholder of a cloud service. Vauta does not open it then: that would download it.
    public func isNotOnThisMac(_ file: ViewedFile) async -> Bool { await offlineReason(file.url) != nil }

    public func closeViewing(_ file: ViewedFile) { if file.began { access.end(file.root) } }

    /// Whether the file is still the one that was indexed (same size and date). A citation of a file that changed shows the stored
    /// passage with a note instead of the file.
    public func fileIsCurrent(source id: Int64, relPath: String) async -> Bool {
        guard let record = try? await index.file(source: id, relPath: relPath), let root = resolveRoot(id),
              let url = fileURL(source: id, root: root, relPath: relPath) else { return false }
        let started = access.begin(root)
        defer { if started { access.end(root) } }
        guard case .found(let size, let mtime) = await statFile(url) else { return false }
        return size == record.size && mtime == record.mtime
    }

    /// A source as the pane knows it (name, kind) for a citation's source id.
    public func source(_ id: Int64) -> DocumentSource? { sources[id] }

    func resolveRoot(_ id: Int64) -> URL? {
        if let url = resolved[id] { return url }
        guard let source = sources[id] else { return nil }
        if case .resolved(let url, _) = access.resolve(source) {
            resolved[id] = url
            return url
        }
        return nil
    }

    /// The status of one source now (also for a source that was never resolved).
    public func sourceReachability(_ id: Int64) -> SourceResolution? {
        if resolved[id] != nil { return .resolved(url: resolved[id]!, renewed: nil) }
        return unreachable[id]
    }
}

public enum DocumentSourceError: Error, Equatable, Sendable {
    case alreadyIncluded(String)
    case containsExisting(String)
    case ownData
    case unsupportedFile
    case wrongKind
}
