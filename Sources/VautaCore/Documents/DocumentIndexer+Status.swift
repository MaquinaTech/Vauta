// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

extension DocumentIndexer {
    /// Everything the pane shows. Cheap: a few counts.
    public func snapshot() async -> DocumentsSnapshot {
        var snapshot = DocumentsSnapshot()
        snapshot.ocrEnabled = ocrEnabled
        snapshot.indexFull = indexFull
        snapshot.pause = lastPolicy.pause
        snapshot.totalFiles = (try? await index.totalFiles()) ?? 0
        snapshot.rebuilding = index.wasRebuilt && started && snapshot.totalFiles == 0 && !sources.isEmpty
        snapshot.totalCharacters = (try? await index.totalCharacters()) ?? 0
        snapshot.totalPassages = (try? await index.totalPassages()) ?? 0
        for source in sources.values.filter({ $0.attachedMeetingID == nil }).sorted(by: { ($0.addedAt, $0.id) < ($1.addedAt, $1.id) }) {
            let counts = (try? await index.counts(source: source.id)) ?? DocumentSourceCounts()
            let state = state(for: source, counts: counts)
            snapshot.sources.append(DocumentSourceStatus(source: source, state: state, counts: counts, truncated: truncated.contains(source.id)))
        }
        for source in sources.values where source.paused == false && unreachable[source.id] == nil {
            let counts = (try? await index.counts(source: source.id)) ?? DocumentSourceCounts()
            snapshot.pendingFiles += counts.pending
            snapshot.readableFiles += counts.files
        }
        return snapshot
    }

    func state(for source: DocumentSource, counts: DocumentSourceCounts) -> DocumentSourceStatus.State {
        if let problem = unreachable[source.id] {
            switch problem {
            case .disconnected: return .disconnected
            case .noPermission: return .noPermission
            default: return .notFound
            }
        }
        if source.paused { return .paused }
        // A scan that waits for the end of a recording (or for the charger): the source says so.
        if counts.pending == 0, dirty.contains(source.id) {
            if let pause = lastPolicy.pause { return .pausedForPower(pause) }
            return .waiting
        }
        if counts.pending > 0 {
            if let pause = lastPolicy.pause { return .pausedForPower(pause) }
            return processing && currentSource == source.id ? .indexing(done: counts.files - counts.pending, total: counts.files) : .waiting
        }
        if counts.ocrPending > 0, ocrEnabled { return .readingImages(left: counts.ocrPending) }
        if indexFull, counts.skipped > 0 { return .indexFull }
        return .upToDate(checked: checked[source.id])
    }

    /// How a file attached to (or linked to) a meeting is doing: the Materials rows say it, so a file Vauta could not read is
    /// not mistaken for one Ask is using. `relPath` is nil for a material that is a source of its own.
    public func materialState(source id: Int64, relPath: String?) async -> MaterialState {
        guard sources[id] != nil else { return .unavailable(.notFound) }
        if let problem = unreachable[id] {
            switch problem {
            case .disconnected: return .unavailable(.disconnected)
            case .noPermission: return .unavailable(.noPermission)
            default: return .unavailable(.notFound)
            }
        }
        let records = (try? await index.files(source: id)) ?? []
        guard let record = relPath.flatMap({ path in records.first { $0.relPath == path } }) ?? (relPath == nil ? records.first : nil) else {
            return .waiting
        }
        switch record.state {
        case .pending: return processing && currentSource == id ? .indexing : .waiting
        case .indexed: return .ready
        case .partial: return .partial
        case .ocrPending: return ocrEnabled ? .readingImages(left: record.ocrPages.count) : .ready
        case .skipped: return .skipped(record.reason ?? .unreadable, record.format)
        }
    }

    /// Tells the observer, at most twice a second while files are being read.
    func publish(force: Bool = false) {
        guard onChange != nil else { return }
        let now = Date()
        if !force, now.timeIntervalSince(lastPublish) < 0.5 {
            guard !publishScheduled else { return }
            publishScheduled = true
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                await self?.flushPublish()
            }
            return
        }
        lastPublish = now
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.snapshot()
            await self.deliver(snapshot)
        }
    }

    private func flushPublish() {
        publishScheduled = false
        publish(force: true)
    }

    private func deliver(_ snapshot: DocumentsSnapshot) {
        onChange?(snapshot)
    }
}
