// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI
import Observation
import UniformTypeIdentifiers

/// The Network Activity window's state: a live copy of the in-memory log.
@MainActor
@Observable
final class NetworkActivityModel {
    /// Oldest first, as the log keeps them.
    private(set) var entries: [NetworkActivityEntry] = []
    /// Show only this purpose (nil = all).
    var filter: NetworkPurpose?
    var exportFeedback: ModelsSettingsModel.Feedback?
    /// The file the last export wrote, for Show in Finder.
    private(set) var exportedFile: URL?

    private let log: NetworkActivityLog
    /// Whether `run()` follows the log (off for the snapshot scenes, which show fixed entries).
    private let follows: Bool

    init(log: NetworkActivityLog = .shared) {
        self.log = log
        follows = true
    }

    /// A fixed list, for snapshots.
    init(entries: [NetworkActivityEntry], filter: NetworkPurpose? = nil) {
        log = .shared
        follows = false
        self.entries = entries
        self.filter = filter
    }

    /// Follows the log until the window closes (call from `.task`). Updates are
    /// coalesced to about ten per second.
    func run() async {
        guard follows else { return }
        entries = await log.snapshot()
        for await _ in await log.changes() {
            entries = await log.snapshot()
            // A purpose whose requests all scrolled out of the list would leave an empty table and a blank menu.
            if let filter, !entries.contains(where: { $0.purpose == filter }) { self.filter = nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Newest first, narrowed by the filter.
    var visible: [NetworkActivityEntry] {
        entries.reversed().filtered(by: filter)
    }

    /// Requests behind the listed rows (identical discovery probes are one row with a count).
    var visibleRequests: Int { visible.requestCount }
    /// Some rows stand for several requests, so the rows are fewer than the requests the counter says.
    var groupsRepeats: Bool { visible.count < visibleRequests }
    var totalRequests: Int { entries.requestCount }
    /// A purpose filter is on, so the count reads "N of M requests".
    var isFiltering: Bool { filter != nil }

    var destinations: [NetworkDestination] { NetworkDestination.summarize(entries) }

    /// Requests refused before they were sent (the summary names where they were headed).
    var blocked: [NetworkActivityEntry] { entries.reversed().filter { $0.blocked != nil } }

    /// The purposes that appear in the log, in a stable order, for the filter menu.
    var purposes: [NetworkPurpose] {
        let present = Set(entries.map(\.purpose))
        return NetworkPurpose.allCases.filter { present.contains($0) }
    }

    func clear() async {
        await log.clear()
        entries = []
        filter = nil
        exportFeedback = nil
        exportedFile = nil
    }

    /// Asks where to save, then writes the JSON export. Nothing is written unless the user picks a place.
    func export() async {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Network Activity", comment: "Save panel title")
        let day = Date.now.formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = String(localized: "Vauta Network Activity \(day)", comment: "Default file name of the Network Activity export; the argument is the date as yyyy-MM-dd") + ".json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let window = NSApp.keyWindow.map { $0.sheetParent ?? $0 }
        let response: NSApplication.ModalResponse
        if let window, window.attachedSheet == nil {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return }
        do {
            try await log.exportJSON().write(to: url, options: .atomic)
            let text = String(localized: "Exported “\(url.lastPathComponent)”", comment: "Confirmation after exporting a meeting; the argument is the file name")
            exportedFile = url
            exportFeedback = .init(kind: .success, text: text)
            AccessibilityNotification.Announcement(text).post()
        } catch {
            exportedFile = nil
            let text = String(localized: "Couldn’t save the file. \(error.localizedDescription)",
                              comment: "Network Activity export error; argument is the reason")
            exportFeedback = .init(kind: .error, text: text)
            AccessibilityNotification.Announcement(text).post()
        }
    }
}

extension NetworkPurpose {
    var displayName: String {
        switch self {
        case .minutes: String(localized: "Minutes", comment: "Network Activity purpose: writing the minutes of a meeting")
        case .liveNotes: String(localized: "Live notes", comment: "Network Activity purpose")
        case .notes: String(localized: "Expanding notes", comment: "Network Activity purpose: the model turns the user’s short notes into complete notes from the transcript")
        case .ask: String(localized: "Ask", comment: "Network Activity purpose: questions about meetings")
        case .liveAnswers: String(localized: "Live answers", comment: "Network Activity purpose: checking and answering questions heard in the meeting being recorded")
        case .brief: String(localized: "Preparing a brief", comment: "Network Activity purpose: the model server writes the suggested agenda of the brief shown before a meeting")
        case .embeddings: String(localized: "Search by meaning", comment: "Network Activity purpose: building the search index with the embedding model")
        case .documents: String(localized: "Indexing your documents", comment: "Network Activity purpose: sending the passages of the user's documents to the model server's embedding model, which the user turned on")
        case .translation: String(localized: "Translation", comment: "Network Activity purpose: improving live translation with the model server")
        case .modelDownload: String(localized: "Search model download", comment: "Network Activity purpose: the user chose to download the search model (EmbeddingGemma 2) from Hugging Face")
        case .languageModelDownload: String(localized: "Integrated model download", comment: "Network Activity purpose: the user chose to download the integrated language model (Gemma 4 E4B) from Hugging Face")
        case .discovery: String(localized: "Server discovery", comment: "Network Activity purpose: looking for model servers on this Mac")
        case .connectionTest: String(localized: "Connection test", comment: "Network Activity purpose: the user tested a model server")
        case .statusCheck: String(localized: "Status check", comment: "Network Activity purpose: checking that the model server answers")
        case .other: String(localized: "Other", comment: "Network Activity purpose: anything else")
        }
    }
}

extension NetworkBlockReason {
    var displayName: String {
        switch self {
        case .destinationNotAllowed: String(localized: "Destination not allowed", comment: "Network Activity: why a request was blocked before it was sent")
        case .untrustedAddress: String(localized: "Address outside your network", comment: "Network Activity: why a request was blocked before it was sent")
        case .pathNotAllowed: String(localized: "Address not allowed", comment: "Network Activity: why a request was blocked before it was sent; the path is not one this kind of server uses")
        }
    }
}

extension NetworkErrorKind {
    var displayName: String {
        switch self {
        case .timedOut: String(localized: "Timed out", comment: "Network Activity result")
        case .unreachable: String(localized: "Not reachable", comment: "Network Activity result: nothing answered at the address")
        case .connectionLost: String(localized: "Connection lost", comment: "Network Activity result")
        case .tls: String(localized: "Certificate problem", comment: "Network Activity result: the secure connection failed")
        case .cancelled: String(localized: "Canceled", comment: "Network Activity result")
        case .other: String(localized: "Failed", comment: "Network Activity result")
        }
    }
}

extension NetworkDestination.Scope {
    var displayName: String {
        switch self {
        case .thisMac: String(localized: "On this Mac", comment: "Network Activity: where a destination is")
        case .localNetwork: String(localized: "On your local network", comment: "Network Activity: where a destination is")
        case .outside: String(localized: "Outside your local network", comment: "Network Activity: where a destination is; should never happen")
        case .download: String(localized: "A download you started", comment: "Network Activity: where a destination is; the person clicked Download for the search model")
        }
    }
}
