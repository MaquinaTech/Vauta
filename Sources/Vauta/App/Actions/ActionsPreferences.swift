// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Observation
import VautaCore

/// The choices for what Vauta does after a meeting (Settings › Calendar & Reminders › After meetings, Settings › General and the
/// Follow-up sheet). Non-sensitive: switches, a time of day and opaque list identifiers. There is no switch for adding reminders:
/// pressing Add, and answering the macOS prompt, is the consent. The list and calendar identifiers and the notice marker belong to
/// this Mac's accounts and are not in a backup.
@MainActor
@Observable
final class ActionsPreferences {
    enum Keys {
        static let reminderListID = "actionsReminderListID"
        static let reminderListName = "actionsReminderListName"
        static let lastReminderListID = "actionsLastReminderListID"
        static let eventCalendarID = "actionsEventCalendarID"
        static let eventCalendarName = "actionsEventCalendarName"
        static let lastEventCalendarID = "actionsLastEventCalendarID"
        static let alertMinute = "actionsAlertMinute"
        static let includeMeetingName = "actionsIncludeMeetingName"
        static let calendarWriteNoticeShown = "actionsCalendarWriteNoticeShown"
        static let followUpCardEnabled = "followUpCardEnabled"
        static let emailMode = "followUpEmailMode"
        static let emailSummary = "followUpEmailSummary"
        static let emailOpenQuestions = "followUpEmailOpenQuestions"
        static let emailUnconfirmed = "followUpEmailUnconfirmed"
    }

    /// The list chosen in Settings (nil: the system's default list). Its name is kept only to say which list is gone.
    var reminderListID: String? { didSet { store(reminderListID, Keys.reminderListID) } }
    var reminderListName: String? { didSet { store(reminderListName, Keys.reminderListName) } }
    var lastReminderListID: String? { didSet { store(lastReminderListID, Keys.lastReminderListID) } }
    var eventCalendarID: String? { didSet { store(eventCalendarID, Keys.eventCalendarID) } }
    var eventCalendarName: String? { didSet { store(eventCalendarName, Keys.eventCalendarName) } }
    var lastEventCalendarID: String? { didSet { store(lastEventCalendarID, Keys.lastEventCalendarID) } }
    /// Minutes after midnight of the alert on the due day; nil is Off (the default).
    var alertMinute: Int? { didSet { defaults.set(alertMinute ?? -1, forKey: Keys.alertMinute) } }
    var includeMeetingName: Bool { didSet { defaults.set(includeMeetingName, forKey: Keys.includeMeetingName) } }
    var calendarWriteNoticeShown: Bool { didSet { defaults.set(calendarWriteNoticeShown, forKey: Keys.calendarWriteNoticeShown) } }
    /// The panel's Follow-up card after a meeting (on by default).
    var followUpCardEnabled: Bool { didSet { defaults.set(followUpCardEnabled, forKey: Keys.followUpCardEnabled) } }
    var emailMode: FollowUpEmailOptions.Mode { didSet { defaults.set(emailMode.rawValue, forKey: Keys.emailMode) } }
    /// Off by default: the summary is the one part of the minutes with no citation.
    var emailSummary: Bool { didSet { defaults.set(emailSummary, forKey: Keys.emailSummary) } }
    var emailOpenQuestions: Bool { didSet { defaults.set(emailOpenQuestions, forKey: Keys.emailOpenQuestions) } }
    var emailUnconfirmed: Bool { didSet { defaults.set(emailUnconfirmed, forKey: Keys.emailUnconfirmed) } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reminderListID = defaults.string(forKey: Keys.reminderListID)
        reminderListName = defaults.string(forKey: Keys.reminderListName)
        lastReminderListID = defaults.string(forKey: Keys.lastReminderListID)
        eventCalendarID = defaults.string(forKey: Keys.eventCalendarID)
        eventCalendarName = defaults.string(forKey: Keys.eventCalendarName)
        lastEventCalendarID = defaults.string(forKey: Keys.lastEventCalendarID)
        alertMinute = Self.minute(defaults.object(forKey: Keys.alertMinute) as? Int)
        includeMeetingName = defaults.object(forKey: Keys.includeMeetingName) as? Bool ?? true
        calendarWriteNoticeShown = defaults.bool(forKey: Keys.calendarWriteNoticeShown)
        followUpCardEnabled = defaults.object(forKey: Keys.followUpCardEnabled) as? Bool ?? true
        emailMode = defaults.string(forKey: Keys.emailMode).flatMap(FollowUpEmailOptions.Mode.init(rawValue:)) ?? .one
        emailSummary = defaults.bool(forKey: Keys.emailSummary)
        emailOpenQuestions = defaults.object(forKey: Keys.emailOpenQuestions) as? Bool ?? true
        emailUnconfirmed = defaults.bool(forKey: Keys.emailUnconfirmed)
    }

    private static func minute(_ raw: Int?) -> Int? {
        guard let raw, (0..<1440).contains(raw) else { return nil }
        return raw
    }

    private func store(_ value: String?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// A restore wrote the keys of a backup: read them again, only what changed.
    func reload() {
        func update<T: Equatable>(_ path: ReferenceWritableKeyPath<ActionsPreferences, T>, _ value: T) {
            if self[keyPath: path] != value { self[keyPath: path] = value }
        }
        update(\.alertMinute, Self.minute(defaults.object(forKey: Keys.alertMinute) as? Int))
        update(\.includeMeetingName, defaults.object(forKey: Keys.includeMeetingName) as? Bool ?? true)
        update(\.followUpCardEnabled, defaults.object(forKey: Keys.followUpCardEnabled) as? Bool ?? true)
        update(\.emailMode, defaults.string(forKey: Keys.emailMode).flatMap(FollowUpEmailOptions.Mode.init(rawValue:)) ?? .one)
        update(\.emailSummary, defaults.bool(forKey: Keys.emailSummary))
        update(\.emailOpenQuestions, defaults.object(forKey: Keys.emailOpenQuestions) as? Bool ?? true)
        update(\.emailUnconfirmed, defaults.bool(forKey: Keys.emailUnconfirmed))
    }
}
