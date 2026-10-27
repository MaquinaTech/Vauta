// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// An error shown in the meetings window: what happened, what to do, and a
/// button that does it when possible.
struct MeetingsAlert: Identifiable {
    enum Recovery {
        /// Open Vauta's Settings window on this pane.
        case openSettings(SettingsModel.Pane)
        /// Try the operation again.
        case retry(@MainActor () async -> Void)
    }

    let id = UUID()
    var title: String
    var message: String
    var recovery: Recovery?

    init(title: String, message: String, recovery: Recovery? = nil) {
        self.title = title
        self.message = message
        self.recovery = recovery
    }

    /// `title` plus the error's localized description and recovery suggestion.
    init(_ title: String, error: Error, recovery: Recovery? = nil) {
        var parts = [error.localizedDescription]
        if let suggestion = (error as? LocalizedError)?.recoverySuggestion, !suggestion.isEmpty { parts.append(suggestion) }
        self.init(title: title, message: parts.joinedAsSentences(), recovery: recovery)
    }

    /// An export that could not be written: what happened (the system's own words) and what to do.
    static func exportFailure(_ error: Error, retry: @escaping @MainActor () async -> Void) -> MeetingsAlert {
        let step = (error as? LocalizedError)?.recoverySuggestion
            ?? String(localized: "Choose another location and try again.", comment: "Export error: what to do when the file could not be written")
        return MeetingsAlert(title: String(localized: "Couldn’t export the meeting", comment: "Alert title"),
                             message: [error.localizedDescription, step].joinedAsSentences(), recovery: .retry(retry))
    }

    /// The meetings could not be read from the store: what happened and what to do.
    static func loadFailure(_ error: Error, retry: @escaping @MainActor () async -> Void) -> MeetingsAlert {
        let step = (error as? LocalizedError)?.recoverySuggestion ?? SaveFailure.nextStep(for: error)
        return MeetingsAlert(title: String(localized: "Couldn’t load your meetings", comment: "Alert title"),
                             message: [error.localizedDescription, step].joinedAsSentences(), recovery: .retry(retry))
    }

    /// Exporting or copying while copy protection is on.
    static var copyProtected: MeetingsAlert {
        MeetingsAlert(title: String(localized: "Meeting text is protected", comment: "Alert title when exporting or copying with copy protection on"),
                      message: String(localized: "Meeting text can’t be copied or exported while “Protect meeting text from copying” is on. You can turn it off in the Privacy & Security pane.",
                                      comment: "Alert message when exporting or copying with copy protection on; the quoted name is the setting’s label; the default button opens that pane"),
                      recovery: .openSettings(.privacy))
    }
}
