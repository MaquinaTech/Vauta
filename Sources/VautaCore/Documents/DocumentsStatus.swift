// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What the Documents pane shows about one source.
public struct DocumentSourceStatus: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        case waiting
        case indexing(done: Int, total: Int)
        case readingImages(left: Int)
        case upToDate(checked: Date?)
        case paused
        case pausedForPower(IndexerPolicy.PauseReason)
        case notFound
        case disconnected
        case noPermission
        case indexFull
    }

    public var source: DocumentSource
    public var state: State
    public var counts: DocumentSourceCounts
    /// A folder with more files than Vauta reads.
    public var truncated = false
    public var id: Int64 { source.id }

    public init(source: DocumentSource, state: State, counts: DocumentSourceCounts = DocumentSourceCounts(), truncated: Bool = false) {
        self.source = source
        self.state = state
        self.counts = counts
        self.truncated = truncated
    }

    /// The source can't be reached: Locate… is offered, or the drive is waited for.
    public var needsLocate: Bool { state == .notFound || state == .noPermission }
}

/// Everything the Documents pane and Ask show about the index.
public struct DocumentsSnapshot: Sendable, Equatable {
    public var sources: [DocumentSourceStatus] = []
    public var totalFiles = 0
    public var totalCharacters = 0
    public var totalPassages = 0
    public var indexFull = false
    /// The index was lost and is being built again from the sources.
    public var rebuilding = false
    public var ocrEnabled = true
    public var pause: IndexerPolicy.PauseReason?
    /// Files not read yet and the files of all the sources that can be read: "Still indexing your documents (120 of 412)".
    public var pendingFiles = 0
    public var readableFiles = 0

    public init() {}

    public var hasSources: Bool { !sources.isEmpty }
    /// Files skipped in all the sources because they are Google Drive shortcuts, and because a cloud service keeps them online only.
    public var googleShortcuts: Int { sources.reduce(0) { $0 + $1.counts.googleShortcuts } }
    public var onlineOnly: Int { sources.reduce(0) { $0 + $1.counts.onlineOnly } }
    public var onlineOnlyFolders: Int { sources.reduce(0) { $0 + $1.counts.onlineOnlyFolders } }
    public var isIndexing: Bool { pendingFiles > 0 }
    public var characterCapacityUsed: Double { Double(totalCharacters) / Double(DocumentLimits.maxTotalCharacters) }
}

/// How one material of a meeting is doing in the index.
public enum MaterialState: Sendable, Equatable {
    case waiting
    case indexing
    case readingImages(left: Int)
    case ready
    /// Only the first part was indexed.
    case partial
    case skipped(DocumentSkipReason, DocumentFormat)
    /// The file or its drive can't be reached (`notFound`, `disconnected` or `noPermission`).
    case unavailable(DocumentSourceStatus.State)

    /// Ask can use passages of it now.
    public var isUsable: Bool {
        switch self {
        case .ready, .partial, .readingImages: true
        default: false
        }
    }
}
