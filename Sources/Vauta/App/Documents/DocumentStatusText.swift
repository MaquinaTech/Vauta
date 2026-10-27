// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// What the Documents pane says about a source: a symbol and words (colour never carries the state alone).
extension DocumentSourceStatus {
    var symbol: String {
        switch state {
        case .waiting: "clock"
        case .indexing, .readingImages: "arrow.triangle.2.circlepath"
        case .upToDate: "checkmark.circle"
        case .paused: "pause.circle"
        case .pausedForPower: "bolt.slash"
        case .notFound: source.kind == .folder ? "questionmark.folder" : "questionmark.circle"
        // The plain drive: a badge is too small to read at this size (it looked like a car); the words say what is wrong.
        case .disconnected: "externaldrive"
        case .noPermission: "lock"
        case .indexFull: "exclamationmark.triangle"
        }
    }

    /// Problems (the source can't be read or the index is full) are orange; everything else is quiet.
    var isProblem: Bool {
        switch state {
        case .notFound, .noPermission, .indexFull, .disconnected: true
        default: false
        }
    }

    var statusText: String {
        switch state {
        case .waiting:
            String(localized: "Waiting to index", comment: "Documents pane: a source whose files are queued")
        case .indexing(let done, let total):
            String(localized: "Indexing \(done) of \(total)", comment: "Documents pane: progress of a source; the arguments are the files read so far and the files of the source")
        case .readingImages(let left):
            String(localized: "Reading text in images, \(left) left", comment: "Documents pane: the second pass reads text in images and scanned pages with text recognition; the argument is how many are left")
        case .upToDate(let checked):
            if let checked {
                String(localized: "Up to date · checked \(Self.checkedText(checked))", comment: "Documents pane: the source is indexed and was checked at a time; the argument is the time, or the date and time when it was not today")
            } else {
                String(localized: "Up to date", comment: "Documents pane: the source is indexed")
            }
        case .paused:
            String(localized: "Paused", comment: "Documents pane: the person paused indexing of this source")
        case .pausedForPower(let reason):
            switch reason {
            case .recording: String(localized: "Waiting to index", comment: "Documents pane: a source whose files are queued")
            case .lowPower: String(localized: "Paused while on Low Power Mode", comment: "Documents pane: indexing waits because the Mac is in Low Power Mode")
            case .thermal: String(localized: "Paused while the Mac is hot", comment: "Documents pane: indexing waits because the Mac is too hot")
            }
        case .notFound:
            source.kind == .folder
                ? String(localized: "Can’t find this folder", comment: "Documents pane: the folder was moved or deleted")
                : String(localized: "Can’t find this file", comment: "Documents pane: the file was moved or deleted")
        case .disconnected:
            String(localized: "Drive not connected", comment: "Documents pane: the source is on a drive that is not connected; its index is kept")
        case .noPermission:
            String(localized: "Vauta no longer has access", comment: "Documents pane: macOS no longer lets Vauta read this source")
        case .indexFull:
            String(localized: "Index full: some files were not indexed", comment: "Documents pane: the index reached its size limit")
        }
    }

    /// "11:00 AM" for today, "Oct 9, 11:00 AM" for another day: a check from last week must not look like one from this morning.
    static func checkedText(_ checked: Date, now: Date = AppClock.now, calendar: Calendar = .current) -> String {
        calendar.isDate(checked, inSameDayAs: now)
            ? checked.formatted(date: .omitted, time: .shortened)
            : checked.formatted(date: .abbreviated, time: .shortened)
    }

    /// The VoiceOver value of the whole row: "Projects, folder, Indexing 120 of 412, 12 skipped".
    var spokenSummary: String {
        let kind = source.kind == .folder ? String(localized: "folder", comment: "VoiceOver: a document source is a folder") : String(localized: "file", comment: "VoiceOver: a document source is a file")
        var parts = [source.displayName, kind, statusText]
        if counts.skipped > 0 { parts.append(String(localized: "\(counts.skipped) skipped", comment: "Documents pane: how many files of a source were skipped")) }
        let notHere = counts.notOnThisMac
        if notHere > 0 { parts.append(String(localized: "\(notHere) not on this Mac", comment: "VoiceOver: how many of a source's skipped files are Google Drive shortcuts or kept online only by a cloud service")) }
        return parts.joined(separator: ", ")
    }
}

extension DocumentSkipReason {
    /// A sentence for the Skipped Files sheet; "Too large" says how large.
    func sheetText(format: DocumentFormat, isFolder: Bool = false) -> String {
        switch self {
        case .cloudNotDownloaded where isFolder: String(localized: "Folder online only, not downloaded", comment: "Documents: why a whole folder was skipped; a cloud service keeps it online and the Mac holds only a placeholder, so nothing inside it was read")
        case .tooLarge: String(localized: "Too large (over \(ByteSize.string(DocumentLimits.maxBytes(for: format))))", comment: "Documents: why a file was skipped; the argument is the size limit")
        default: localizedText
        }
    }
}
