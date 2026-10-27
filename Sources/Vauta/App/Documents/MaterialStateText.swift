// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// What the Materials list says about a file: whether Ask can use it yet, and if not, why (words and a symbol; colour never
/// carries the state alone).
extension MaterialState {
    var symbol: String {
        switch self {
        case .waiting: "clock"
        case .indexing, .readingImages: "arrow.triangle.2.circlepath"
        case .ready: "checkmark.circle"
        case .partial: "exclamationmark.circle"
        case .skipped: "exclamationmark.triangle"
        case .unavailable(.disconnected): "externaldrive"
        case .unavailable(.noPermission): "lock"
        case .unavailable: "questionmark.circle"
        }
    }

    /// The file can't be used by Ask (yet): it is shown in orange.
    var isProblem: Bool {
        switch self {
        case .skipped, .unavailable: true
        default: false
        }
    }

    var text: String {
        switch self {
        case .waiting: String(localized: "Waiting to index", comment: "Documents pane: a source whose files are queued")
        case .indexing: String(localized: "Indexing…", comment: "Materials: the attached file is being read now")
        case .readingImages(let left):
            String(localized: "Reading text in images, \(left) left", comment: "Documents pane: the second pass reads text in images and scanned pages with text recognition; the argument is how many are left")
        case .ready: String(localized: "Up to date", comment: "Documents pane: the source is indexed")
        case .partial: DocumentSkipReason.partial.localizedText
        case .skipped(let reason, let format): reason.sheetText(format: format)
        case .unavailable(let state):
            switch state {
            case .disconnected: String(localized: "Drive not connected", comment: "Documents pane: the source is on a drive that is not connected; its index is kept")
            case .noPermission: String(localized: "Vauta no longer has access", comment: "Documents pane: macOS no longer lets Vauta read this source")
            default: String(localized: "Can’t find this file", comment: "Documents pane: the file was moved or deleted")
            }
        }
    }
}
