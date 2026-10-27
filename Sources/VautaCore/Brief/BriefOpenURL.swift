// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The links that open an event in Calendar or a reminder in Reminders. They only show the item: nothing is created or changed. When
/// the item has no identifier, the caller opens the app instead.
public enum BriefOpenURL {
    private static let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))

    public static func event(eventIdentifier: String?) -> URL? {
        guard let id = eventIdentifier, !id.isEmpty, let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "ical://ekevent/\(encoded)?method=show&options=more")
    }

    public static func reminder(id: String?) -> URL? {
        guard let id, !id.isEmpty, let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "x-apple-reminderkit://REMCDReminder/\(encoded)")
    }
}
