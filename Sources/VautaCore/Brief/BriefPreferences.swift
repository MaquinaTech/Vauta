// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The brief's switches and opaque identifiers (non-sensitive: no title, name or text). New keys only; no existing key changes meaning.
/// The brief is on once Calendar is on (decided before 0.9.0), with the notification 10 minutes before: `enabled` below is
/// the one place to change the default. Reminders are off until the person allows them. The notification is chosen with the lead time
/// (Off, 5, 10, 15 or 30 minutes), in one place only.
public struct BriefPreferences: Sendable, Equatable {
    public enum Keys {
        public static let enabled = "briefEnabled"
        public static let leadMinutes = "briefLeadMinutes"
        public static let inPerson = "briefInPersonEvents"
        public static let readInvitationNotes = "briefReadInvitationNotes"
        public static let remindersEnabled = "remindersEnabled"
        public static let reminderListIDs = "reminderListIDs"
        public static let hintSeen = "briefHintSeen"
        public static let remindersHintDismissed = "briefRemindersHintDismissed"
    }

    public var enabled = true
    /// Minutes before the meeting; 0 is Off. One of `BriefEventSelector.leadOptions`.
    public var leadMinutes = BriefEventSelector.defaultLeadMinutes
    /// "Also for meetings without a video link".
    public var inPerson = true
    /// "Use the invitation's notes".
    public var readInvitationNotes = true
    public var remindersEnabled = false
    public var reminderListIDs: Set<String> = []
    public var hintSeen = false
    /// The quiet line about Reminders in Upcoming was closed (it is shown until then).
    public var remindersHintDismissed = false

    public init() {}

    public init(defaults: UserDefaults) {
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        let lead = defaults.object(forKey: Keys.leadMinutes) as? Int
        leadMinutes = lead.flatMap { BriefEventSelector.leadOptions.contains($0) ? $0 : nil } ?? BriefEventSelector.defaultLeadMinutes
        inPerson = defaults.object(forKey: Keys.inPerson) as? Bool ?? true
        readInvitationNotes = defaults.object(forKey: Keys.readInvitationNotes) as? Bool ?? true
        remindersEnabled = defaults.object(forKey: Keys.remindersEnabled) as? Bool ?? false
        reminderListIDs = Set(defaults.stringArray(forKey: Keys.reminderListIDs) ?? [])
        hintSeen = defaults.object(forKey: Keys.hintSeen) as? Bool ?? false
        remindersHintDismissed = defaults.object(forKey: Keys.remindersHintDismissed) as? Bool ?? false
    }

    public func write(to defaults: UserDefaults) {
        defaults.set(enabled, forKey: Keys.enabled)
        defaults.set(leadMinutes, forKey: Keys.leadMinutes)
        defaults.set(inPerson, forKey: Keys.inPerson)
        defaults.set(readInvitationNotes, forKey: Keys.readInvitationNotes)
        defaults.set(remindersEnabled, forKey: Keys.remindersEnabled)
        defaults.set(reminderListIDs.sorted(), forKey: Keys.reminderListIDs)
        defaults.set(hintSeen, forKey: Keys.hintSeen)
        defaults.set(remindersHintDismissed, forKey: Keys.remindersHintDismissed)
    }

    public var settings: BriefSettings {
        BriefSettings(remindersEnabled: remindersEnabled, reminderListIDs: reminderListIDs, useInvitationNotes: readInvitationNotes)
    }

    /// The notification goes out at all: the brief is on and the lead time is not Off.
    public var notifies: Bool { enabled && leadMinutes > 0 }
}
