// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Finding out what changed in each source.
extension DocumentIndexer {
    func syncAll() async {
        let epoch = self.epoch
        await reloadSources()
        for id in sources.keys.sorted() { await sync(id) }
        guard epoch == self.epoch else { return }
        // Files of sources that no longer exist (a removed source, a meeting deleted with its attachments).
        if let known = try? await index.allFileSourceIDs() {
            for orphan in known.subtracting(sources.keys) { try? await index.deleteSource(orphan) }
        }
        publish(force: true)
    }

    /// Opens the source, lists its files and brings the index in line. Reading the files themselves happens later, one at a time.
    ///
    /// A scan can take seconds and the actor is free meanwhile, so the source may be removed, or the whole store replaced (Erase
    /// Everything, Restore), before it ends. Every step after a wait checks that (`isCurrent`) and writes nothing otherwise.
    /// While a meeting records, or on battery for a network volume, nothing is scanned or saved: the source waits (`dirty`).
    ///
    /// One scan per source at a time. A change that arrives during a scan may come after the folder was listed, so it is not dropped:
    /// the scan in flight lists the folder again when it ends (`rescan`).
    func sync(_ id: Int64, requeueSkipped: Bool = false) async {
        guard await scan(id, requeueSkipped: requeueSkipped) else { return }
        while let requeue = rescan.removeValue(forKey: id) {
            guard await scan(id, requeueSkipped: requeue) else { return }
        }
    }

    /// One scan of the source; false when another one was in flight (the change is then left to it).
    private func scan(_ id: Int64, requeueSkipped: Bool = false) async -> Bool {
        guard let source = sources[id] else { return false }
        let epoch = self.epoch
        let policy = IndexerPolicy.decide(await environment())
        lastPolicy = policy
        guard isCurrent(id, epoch) else { return false }
        guard scanning[id] == nil else {
            rescan[id] = (rescan[id] ?? false) || requeueSkipped
            return false
        }
        guard policy.text else {
            dirty.insert(id)
            publish(force: true)
            return false
        }
        ticket += 1
        let mine = ticket
        scanning[id] = mine
        defer { if scanning[id] == mine { scanning[id] = nil } }
        switch access.resolve(source) {
        case .resolved(let url, let renewed):
            resolved[id] = url
            unreachable[id] = nil
            if let renewed { try? await store.updateDocumentSource(id, bookmark: renewed, path: url.path, volumeUUID: source.volumeUUID) }
        case let other:
            resolved[id] = nil
            unreachable[id] = other
            watchers[id]?.stop()
            watchers[id] = nil
            publish(force: true)
            return true
        }
        guard let root = resolved[id] else { return true }
        let started = access.begin(root)
        defer { if started { access.end(root) } }
        let local = await volumeIsLocal(root)
        guard isCurrent(id, epoch) else { return true }
        if local { nonLocal.remove(id) } else { nonLocal.insert(id) }
        // A network volume is not worked on while the Mac runs on battery.
        guard local || policy.network else {
            dirty.insert(id)
            publish(force: true)
            return true
        }
        if local && source.kind == .folder { watch(id, url: root) } else { watchers[id]?.stop(); watchers[id] = nil }
        // Listing a large folder is slow disk work: off the actor, so Ask and the pane are never queued behind it.
        let scanned = await scanFolder(root, kind: source.kind)
        guard !Task.isCancelled else {
            if isCurrent(id, epoch) { dirty.insert(id) }
            return true
        }
        guard isCurrent(id, epoch) else { return true }
        guard let result = scanned else {
            markUnresponsive(id)
            return true
        }
        dirty.remove(id)
        truncated = result.truncated ? truncated.union([id]) : truncated.subtracting([id])
        guard let known = try? await index.files(source: id), isCurrent(id, epoch) else { return true }
        let room = ((try? await index.totalCharacters()) ?? 0) < DocumentLimits.maxTotalCharacters
        guard isCurrent(id, epoch) else { return true }
        var plan = DocumentSync.plan(scanned: result.files, known: known, indexHasRoom: room)
        // A source folder that is not on this Mac is not an empty one: what was indexed from it stays.
        if result.rootNotOnThisMac { plan.removed = [] }
        await apply(&plan, source: source, root: root, epoch: epoch)
        guard isCurrent(id, epoch) else { return true }
        if requeueSkipped {
            for record in known where record.state == .skipped && record.reason != .crashed && record.reason != .exportAsPDF && record.reason != .googleDriveShortcut && record.reason != .unsupported {
                if let scanned = result.files.first(where: { $0.relPath == record.relPath }), scanned.skip == nil, let format = scanned.format {
                    await queueFile(id, epoch: epoch, scanned, format: format)
                }
            }
        }
        forgetCharacterTotal()
        checked[id] = .now
        guard isCurrent(id, epoch) else { return true }
        // The image is not written while a meeting records (capture comes first); the loop saves it when the pause ends.
        if IndexerPolicy.decide(await environment()).text, isCurrent(id, epoch) { try? await index.save() } else { unsaved = true }
        publish(force: true)
        return true
    }

    func apply(_ plan: inout DocumentSyncPlan, source: DocumentSource, root: URL, epoch: Int) async {
        let id = source.id
        func alive() -> Bool { isCurrent(id, epoch) }
        func url(_ relPath: String) -> URL { source.kind == .file ? root : root.appendingPathComponent(relPath) }
        for (scanned, reason) in plan.skipped {
            guard alive() else { return }
            try? await index.markSkipped(source: id, scanned: scanned, reason: reason)
        }
        for (_, scanned) in plan.retry {
            if let format = scanned.format { await queueFile(id, epoch: epoch, scanned, format: format) }
        }
        // A format whose extractor got better: its files are read again, behind the new ones, once.
        for format in Set(plan.outdated.map(\.format)) where alive() {
            try? await index.requeue(source: id, onlyFormat: format, olderThan: format.extractorVersion)
        }
        for (record, scanned) in plan.renamed {
            guard alive() else { return }
            try? await index.rename(fileID: record.id, to: scanned.relPath, mtime: scanned.mtime, size: scanned.size)
            if record.size != scanned.size || record.mtime != scanned.mtime, let format = scanned.format {
                await queueFile(id, epoch: epoch, scanned, format: format)
            }
        }
        for (record, scanned) in plan.changed {
            guard let format = scanned.format, alive() else { continue }
            // The same bytes under a new date (a touch, a sync tool): only the date is refreshed.
            var hash: String?
            if await offlineReason(url(scanned.relPath)) == nil { hash = await hashFile(url(scanned.relPath), size: scanned.size) }
            guard alive() else { return }
            if let hash, hash == record.hash, record.state != .pending {
                try? await index.refresh(fileID: record.id, size: scanned.size, mtime: scanned.mtime, hash: hash)
            } else {
                await queueFile(id, epoch: epoch, scanned, format: format)
            }
        }
        // A new file with the size and the bytes of one that vanished is that file, moved: its passages stay.
        var gone = plan.removed
        for scanned in plan.added {
            guard let format = scanned.format, alive() else { continue }
            let candidates = gone.filter { $0.size == scanned.size && $0.hash != nil && $0.state != .skipped }
            if !candidates.isEmpty {
                var hash: String?
                if await offlineReason(url(scanned.relPath)) == nil { hash = await hashFile(url(scanned.relPath), size: scanned.size) }
                guard alive() else { return }
                if let hash, let match = candidates.first(where: { $0.hash == hash }) {
                    try? await index.rename(fileID: match.id, to: scanned.relPath, mtime: scanned.mtime, size: scanned.size)
                    gone.removeAll { $0.id == match.id }
                    continue
                }
            }
            // The crash guard: this very file (same name, size and date) killed Vauta while it was read.
            if let crash, crash.matches(source: id, relPath: scanned.relPath, size: scanned.size, mtime: scanned.mtime, key: await markerKey()) {
                guard alive() else { return }
                try? await index.markSkipped(source: id, scanned: scanned, reason: .crashed)
                self.crash = nil
                continue
            }
            await queueFile(id, epoch: epoch, scanned, format: format)
        }
        guard alive() else { return }
        for record in gone { await removeIndexedFile(record) }
        // A marker for a file that was already known (pending): it is skipped too.
        let key = await markerKey()
        guard alive() else { return }
        if let crash, crash.source == id, let record = (try? await index.files(source: id))?.first(where: {
            crash.matches(source: id, relPath: $0.relPath, size: $0.size, mtime: $0.mtime, key: key) }), alive() {
            try? await index.markSkipped(fileID: record.id, reason: .crashed)
            self.crash = nil
        }
    }

    /// SHA-256 (first 16 bytes) of a file, or nil when it is large or unreadable.
    static func hash(_ url: URL, size: Int64) -> String? {
        size <= DocumentLimits.maxPDFBytes ? DocumentScanner.contentHash(url) : nil
    }

    // MARK: Watching

    /// FSEvents for a folder on a local volume. Events only mark a source as changed; a scan finds out what. Files and network
    /// volumes have none: the scan every 30 minutes covers them (a file's parent folder is outside the bookmark's scope), and
    /// the six-hourly scan covers everything.
    func watch(_ id: Int64, url: URL) {
        guard watchers[id] == nil else { return }
        watchers[id] = SourceWatcher(url: url) { [weak self] in
            Task { await self?.changed(id) }
        }
    }

    func changed(_ id: Int64) async {
        await sync(id)
        kick()
    }

    /// Sources that waited for a recording (or for the charger) are scanned now.
    func syncDirty() async {
        for id in dirty.sorted() { await sync(id) }
    }
}
