// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Reading the queue of files: one at a time, in the background.
extension DocumentIndexer {
    /// Starts the loop if it is not running.
    func kick() {
        guard started else { return }
        // A loop that is waiting (for the charger, for tomorrow's OCR budget, for the end of a recording) looks again at once.
        // A loop that is already finishing (past its last look at the queue) is asked to look again once it has: a file added at that
        // moment is never left waiting for the next scan.
        guard runner == nil else {
            rerunRequested = true
            wake()
            return
        }
        runGeneration += 1
        let generation = runGeneration
        runner = Task(priority: .background) { [weak self] in
            await self?.run()
            await self?.runFinished(generation)
        }
    }

    func runFinished(_ generation: Int) {
        guard generation == runGeneration else { return }
        runner = nil
        processing = false
        currentSource = nil
        publish(force: true)
        if rerunRequested {
            rerunRequested = false
            kick()
        }
    }

    /// Waits `seconds`, or less when `wake()` is called or the loop is cancelled.
    func pause(seconds: TimeInterval) async {
        let sleeper = Task<Void, Never> { try? await Task.sleep(for: .seconds(seconds)) }
        self.sleeper = sleeper
        await withTaskCancellationHandler { await sleeper.value } onCancel: { sleeper.cancel() }
        self.sleeper = nil
    }

    func wake() { sleeper?.cancel() }

    /// Pages of a scanned file read in one step of the loop, so the loop looks at the Mac's state every few pages.
    static let ocrBatch = 5

    /// The sources whose files may be read now: not paused and reachable.
    func readable() -> [Int64] {
        sources.values.filter { !$0.paused && resolved[$0.id] != nil && (lastPolicy.network || !nonLocal.contains($0.id)) }.map(\.id)
    }

    func run() async {
        while !Task.isCancelled {
            // Anything asked from here on (a new file, a source added) is seen by the look at the queue below, or starts the loop again.
            rerunRequested = false
            let policy = IndexerPolicy.decide(await environment())
            lastPolicy = policy
            // Scans that waited for a recording or the charger.
            if policy.text, !dirty.isEmpty {
                await syncDirty()
                continue
            }
            let ids = readable()
            let pending = (try? await index.queue(limit: 1, sources: ids)) ?? []
            // With the day's OCR budget spent the images wait for tomorrow without keeping the loop alive: the periodic scan
            // starts it again, and a new file is read at once.
            let budgetLeft = await index.ocrPagesToday() < DocumentLimits.maxOCRPagesPerDay
            let images = ocrEnabled && budgetLeft ? ((try? await index.ocrQueue(limit: 1, sources: ids)) ?? []) : []
            if pending.isEmpty && images.isEmpty && dirty.isEmpty { break }
            // A file that would go to a parser that is stuck on earlier files waits: those threads still run, and each stuck
            // parser ties up a core for as long as the session lasts.
            let nextIsAppleParser = pending.first.map { policy.text && $0.format.usesAppleParser } ?? (policy.text && policy.ocr && images.first != nil)
            if extractions.live >= Self.maxStuckParsers, nextIsAppleParser {
                processing = false
                currentSource = nil
                publish(force: true)
                await pause(seconds: 15)
                continue
            }
            // Waiting for the Mac (a recording, Low Power Mode, a hot Mac, the charger): look again in a little while.
            if let record = pending.first, policy.text {
                processing = true
                currentSource = record.sourceID
                await readText(record)
            } else if let record = images.first, policy.ocr, policy.text {
                guard await readPixels(record) else {
                    // The daily OCR budget is used: the rest waits for tomorrow.
                    await pause(seconds: 3600)
                    continue
                }
            } else {
                processing = false
                currentSource = nil
                publish(force: true)
                await pause(seconds: policy.pause == nil ? 120 : 30)
                continue
            }
            await batchSave()
            publish()
            // Yield to Ask and the pane between files.
            await Task.yield()
        }
        lastPolicy = IndexerPolicy.decide(await environment())
        if lastPolicy.text || !unsaved { unsaved = false; try? await index.save() }
    }

    func batchSave(force: Bool = false) async {
        sinceSave += 1
        let interval = Self.saveInterval(imageBytes: await index.lastImageBytes)
        if force || sinceSave >= 50 || Date().timeIntervalSince(lastSave) >= interval {
            sinceSave = 0
            lastSave = .now
            try? await index.save()
        }
    }

    /// Every save writes the whole image: the larger it is, the longer the wait (a minute for a small index, five once it is over
    /// 20 MB). At most one interval of work is lost to a crash.
    static func saveInterval(imageBytes: Int) -> TimeInterval { imageBytes > 20 << 20 ? 300 : 60 }

    func url(of record: DocumentFileRecord, source: DocumentSource, root: URL) -> URL {
        source.kind == .file ? root : root.appendingPathComponent(record.relPath)
    }

    /// The text pass of one file.
    func readText(_ record: DocumentFileRecord) async {
        let epoch = self.epoch
        guard let source = sources[record.sourceID], let root = resolved[record.sourceID] else {
            await removeIndexedFile(record)
            return
        }
        let fileURL = url(of: record, source: source, root: root)
        // The total cap: past it nothing more is indexed.
        if await indexedCharacters() >= DocumentLimits.maxTotalCharacters {
            indexFull = true
            try? await index.markSkipped(fileID: record.id, reason: .indexFull)
            return
        }
        indexFull = false
        // The file may have changed (or gone) since it was listed.
        let outcome = await statFile(fileURL)
        guard isCurrent(source.id, epoch) else { return }
        guard case .found(let nowSize, let nowMtime) = outcome else {
            if outcome == .gone { await removeIndexedFile(record); forgetCharacterTotal() } else { markUnresponsive(source.id) }
            return
        }
        if nowSize != record.size || nowMtime != record.mtime {
            let scanned = ScannedDocumentFile(relPath: record.relPath, size: nowSize, mtime: nowMtime, fileID: record.fileID, format: record.format)
            await queueFile(source.id, epoch: epoch, scanned, format: record.format)
            return
        }
        // Never a download: the file may have become a placeholder since it was listed (Optimize Storage, a provider evicting it).
        if let reason = await offlineReason(fileURL) {
            if isCurrent(source.id, epoch) { try? await index.markSkipped(fileID: record.id, reason: reason) }
            forgetCharacterTotal()
            return
        }
        writeMarker(CrashMarker(source: source.id, relPath: record.relPath, size: record.size, mtime: record.mtime, key: await markerKey()))
        defer { clearMarker() }
        let extractor = extractor
        let format = record.format
        let started = access.begin(root)
        defer { if started { access.end(root) } }
        do {
            let hash = await hashFile(fileURL, size: record.size)
            let tracker = extractions
            tracker.begin()
            let document = try await withDeadline(seconds: textDeadline) {
                defer { tracker.end() }
                return try await extractor.extract(fileURL, format: format)
            }
            // A file that changes while it is read is read again, never half of each.
            switch await statFile(fileURL) {
            case .found(let size, let mtime) where size != record.size || mtime != record.mtime:
                let scanned = ScannedDocumentFile(relPath: record.relPath, size: size, mtime: mtime, fileID: record.fileID, format: format)
                await queueFile(source.id, epoch: epoch, scanned, format: format)
                return
            case .noAnswer:
                markUnresponsive(source.id)
                return
            default: break
            }
            let name = (record.relPath as NSString).lastPathComponent
            let (passages, _) = await Self.passages(of: document, fileName: name)
            // The source may have been removed (a deleted meeting's material) while the file was read.
            guard isCurrent(record.sourceID, epoch) else { return }
            try await index.replacePassages(fileID: record.id, with: passages)
            // At most 300 pages of a file are read with OCR; the file says it is partial.
            let ocrPages = Array(document.pagesNeedingOCR.prefix(DocumentLimits.maxOCRPagesPerFile))
            let ocrCapped = document.pagesNeedingOCR.count > ocrPages.count
            if passages.isEmpty && ocrPages.isEmpty {
                try await index.markSkipped(fileID: record.id, reason: .noText)
                return
            }
            let state: DocumentFileRecord.State = !ocrPages.isEmpty ? .ocrPending : (document.partial || ocrCapped ? .partial : .indexed)
            let pageCount = document.units.compactMap { $0.locator.pageNumber }.max() ?? document.units.count
            try await index.finish(fileID: record.id, state: state, title: document.title, pages: pageCount, characters: document.characterCount, ocrPages: ocrPages,
                                   reason: document.partial || ocrCapped ? .partial : nil, hash: hash, extractorVersion: format.extractorVersion)
            charTotal = charTotal.map { max(0, $0 + document.characterCount - record.characters) }
        } catch is CancellationError {
            // Left pending: the next run reads it.
        } catch let error as DocumentExtractionError {
            // Opening a placeholder fails (downloads are forbidden on this thread): that is "not downloaded", not a broken file.
            let why = await offlineReason(fileURL) ?? error.reason
            if isCurrent(record.sourceID, epoch) { try? await index.markSkipped(fileID: record.id, reason: why) }
            forgetCharacterTotal()
        } catch {
            let why = await offlineReason(fileURL) ?? .unreadable
            if isCurrent(record.sourceID, epoch) { try? await index.markSkipped(fileID: record.id, reason: why) }
            forgetCharacterTotal()
        }
    }

    /// The OCR pass of one file. Returns false when the day's OCR budget is spent.
    func readPixels(_ record: DocumentFileRecord) async -> Bool {
        let epoch = self.epoch
        currentSource = record.sourceID
        guard let source = sources[record.sourceID], let root = resolved[record.sourceID] else {
            await removeIndexedFile(record)
            return true
        }
        let used = await index.ocrPagesToday()
        let room = DocumentLimits.maxOCRPagesPerDay - used
        guard room > 0 else { return false }
        let fileURL = url(of: record, source: source, root: root)
        let outcome = await statFile(fileURL)
        guard isCurrent(source.id, epoch) else { return true }
        guard case .found(let nowSize, let nowMtime) = outcome, nowSize == record.size, nowMtime == record.mtime else {
            // Changed or gone since the text pass: it goes back through it.
            switch outcome {
            case .found(let size, let mtime):
                let scanned = ScannedDocumentFile(relPath: record.relPath, size: size, mtime: mtime, fileID: record.fileID, format: record.format)
                await queueFile(source.id, epoch: epoch, scanned, format: record.format)
            case .gone:
                await removeIndexedFile(record)
                forgetCharacterTotal()
            case .noAnswer:
                markUnresponsive(source.id)
            }
            return true
        }
        // A few pages at a time, so the loop looks at the Mac's state between steps (a recording stops the work within a batch);
        // of those, as many as the day's budget allows now and the rest tomorrow.
        if let reason = await offlineReason(fileURL) {
            // Placeholder now: the text already indexed stays (the file is partial, with the reason); a file with none is skipped.
            if isCurrent(source.id, epoch) { try? await index.ocrFailed(fileID: record.id, reason: reason) }
            forgetCharacterTotal()
            return true
        }
        let pages = Array(record.ocrPages.prefix(min(room, Self.ocrBatch)))
        let left = Array(record.ocrPages.dropFirst(pages.count))
        writeMarker(CrashMarker(source: source.id, relPath: record.relPath, size: record.size, mtime: record.mtime, key: await markerKey()))
        defer { clearMarker() }
        let started = access.begin(root)
        defer { if started { access.end(root) } }
        do {
            let format = record.format
            let extractor = extractor
            let tracker = extractions
            tracker.begin()
            // Opening the file and drawing its pages are inside the deadline too: a page that never finishes drawing ends as
            // "took too long" for these pages, so the file is finished (partial) and not tried again at every launch.
            let budget = VisionOCR.pageDeadline + DocumentLimits.ocrPageSeconds * Double(pages.count) + 30
            let units = try await withDeadline(seconds: ocrDeadline ?? budget) {
                defer { tracker.end() }
                return try await extractor.recognize(fileURL, format: format, pages: pages)
            }
            try? await index.recordOCR(pages: pages.count)
            let name = (record.relPath as NSString).lastPathComponent
            let (passages, _) = await Self.passages(of: ExtractedDocument(title: record.title, units: units), fileName: name)
            guard isCurrent(record.sourceID, epoch) else { return true }
            try await index.addPassages(fileID: record.id, passages)
            let characters = record.characters + units.reduce(0) { $0 + $1.text.count }
            charTotal = charTotal.map { $0 + characters - record.characters }
            if left.isEmpty, units.isEmpty, characters == 0 {
                try await index.markSkipped(fileID: record.id, reason: .noText)
            } else {
                // The cap on a file's OCR pages was applied (and recorded as `partial`) by the text pass.
                let state: DocumentFileRecord.State = !left.isEmpty ? .ocrPending : (record.reason == .partial ? .partial : .indexed)
                try await index.finish(fileID: record.id, state: state, title: record.title, pages: record.pages, characters: characters, ocrPages: left,
                                       reason: record.reason == .partial ? .partial : nil)
            }
        } catch is CancellationError {
            // Left as it is: the next run reads these pages.
        } catch let error as DocumentExtractionError {
            let why = await offlineReason(fileURL) ?? error.reason
            if isCurrent(record.sourceID, epoch) { try? await index.ocrFailed(fileID: record.id, reason: why) }
            forgetCharacterTotal()
        } catch {
            let why = await offlineReason(fileURL) ?? .unreadable
            if isCurrent(record.sourceID, epoch) { try? await index.ocrFailed(fileID: record.id, reason: why) }
            forgetCharacterTotal()
        }
        return true
    }

    /// Passages and their terms, computed off the actor (language detection and segmentation are not free).
    static func passages(of document: ExtractedDocument, fileName: String) async -> ([IndexedPassage], Int) {
        await Task.detached(priority: .background) {
            let drafts = PassageChunker.chunk(document, fileName: fileName)
            return (drafts.map { IndexedPassage(draft: $0, terms: DocumentTerms.terms(for: $0.text)) }, drafts.count)
        }.value
    }

    /// Size and modification date, read fresh from the file system every time (a `URL` caches its resource values, which would
    /// hide a file that changed while it was read).
    static func stat(_ url: URL) -> (size: Int64, mtime: Double)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, let date = attributes[.modificationDate] as? Date else { return nil }
        return (size.int64Value, date.timeIntervalSince1970)
    }
}
