// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What a scan changes in the index. A pure comparison of the files on disk with the files the index knows.
public struct DocumentSyncPlan: Sendable, Equatable {
    /// Files that are not in the index.
    public var added: [ScannedDocumentFile] = []
    /// Same path, other size or date: read the bytes to tell a touch from a change.
    public var changed: [(record: DocumentFileRecord, scanned: ScannedDocumentFile)] = []
    /// Skipped for a reason that may have gone away (it is now downloaded, it fits now).
    public var retry: [(record: DocumentFileRecord, scanned: ScannedDocumentFile)] = []
    /// A file that is skipped before reading (iCloud, too large, export it as PDF) and is not recorded as such yet.
    public var skipped: [(scanned: ScannedDocumentFile, reason: DocumentSkipReason)] = []
    /// A path that is gone and another path that has its identity: the passages are kept.
    public var renamed: [(record: DocumentFileRecord, scanned: ScannedDocumentFile)] = []
    public var removed: [DocumentFileRecord] = []
    /// Read with an older version of its extractor.
    public var outdated: [DocumentFileRecord] = []

    public var isEmpty: Bool { added.isEmpty && changed.isEmpty && retry.isEmpty && skipped.isEmpty && renamed.isEmpty && removed.isEmpty && outdated.isEmpty }

    public static func == (a: DocumentSyncPlan, b: DocumentSyncPlan) -> Bool {
        a.added == b.added && a.skipped.map(\.scanned) == b.skipped.map(\.scanned) && a.removed == b.removed && a.outdated == b.outdated
            && a.changed.map(\.record) == b.changed.map(\.record) && a.renamed.map(\.record) == b.renamed.map(\.record)
            && a.retry.map(\.record) == b.retry.map(\.record)
    }
}

public enum DocumentSync {
    /// Reasons that can clear without the file changing.
    static let transient: Set<DocumentSkipReason> = [.iCloudNotDownloaded, .cloudNotDownloaded, .indexFull, .tooManyFiles]

    public static func plan(scanned: [ScannedDocumentFile], known: [DocumentFileRecord], indexHasRoom: Bool = true) -> DocumentSyncPlan {
        var plan = DocumentSyncPlan()
        let byPath = Dictionary(known.map { ($0.relPath, $0) }, uniquingKeysWith: { first, _ in first })
        let paths = Set(scanned.map(\.relPath))
        // A folder that a cloud service keeps online only is listed as one "folder/" entry and not enumerated: what was indexed under it
        // is not gone (like the source folder itself, whose files stay), it is just not on this Mac until the person downloads it.
        let evicted = scanned.filter { $0.relPath.hasSuffix("/") && $0.skip == .cloudNotDownloaded }.map(\.relPath)
        var gone = known.filter { record in
            !paths.contains(record.relPath) && !evicted.contains { record.relPath.hasPrefix($0) }
        }
        var unmatched: [ScannedDocumentFile] = []
        for file in scanned {
            guard let record = byPath[file.relPath] else { unmatched.append(file); continue }
            if let reason = file.skip {
                if record.state != .skipped || record.reason != reason || record.size != file.size || record.mtime != file.mtime {
                    plan.skipped.append((file, reason))
                }
                continue
            }
            if record.state == .skipped {
                let changed = record.size != file.size || record.mtime != file.mtime
                let clears = record.reason.map { transient.contains($0) && ($0 != .indexFull || indexHasRoom) } ?? false
                if changed || clears { plan.retry.append((record, file)) }
                continue
            }
            if record.size != file.size || record.mtime != file.mtime {
                plan.changed.append((record, file))
            } else if let format = file.format, record.extractorVersion < format.extractorVersion {
                plan.outdated.append(record)
            }
        }
        // A path that moved: the same identity under a new name.
        for file in unmatched {
            if let id = file.fileID, file.skip == nil, let index = gone.firstIndex(where: { $0.fileID == id && $0.state != .skipped }) {
                plan.renamed.append((gone.remove(at: index), file))
            } else if let reason = file.skip {
                plan.skipped.append((file, reason))
            } else {
                plan.added.append(file)
            }
        }
        plan.removed = gone
        return plan
    }
}
