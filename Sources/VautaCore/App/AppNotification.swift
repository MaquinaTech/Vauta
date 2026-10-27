// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Why a recording stopped without the user pressing Stop.
public enum RecordingStopReason: Equatable, Sendable {
    /// Neither channel was heard for this many minutes.
    case silence(minutes: Int)
    case screenLocked
    case sleep
    case userSwitched

    /// A full sentence explaining the stop.
    public var explanation: String {
        switch self {
        case .silence(let minutes):
            String(localized: "No one was heard for \(Duration.seconds(minutes * 60).formatted(.units(allowed: [.minutes], width: .wide))), so the meeting seems to be over.",
                   comment: "Why a recording stopped automatically; the argument is a length of time in words, like 10 minutes")
        case .screenLocked:
            String(localized: "The screen was locked.", comment: "Why a recording stopped automatically")
        case .sleep:
            String(localized: "The Mac went to sleep.", comment: "Why a recording stopped automatically")
        case .userSwitched:
            String(localized: "You switched to another user.", comment: "Why a recording stopped automatically")
        }
    }
}

/// A local notification, built without touching UserNotifications so the
/// wording and the rules are testable. Notifications never carry transcript
/// text; meeting titles only when the user allows it.
public struct AppNotification: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case autoStopWarning = "vauta.autostop"
        case hangup = "vauta.hangup"
        case suggestion = "vauta.suggestion"
        case recordingStopped = "vauta.stopped"
        case serverUnreachable = "vauta.server"
        case minutesReady = "vauta.minutes.ready"
        case minutesFailed = "vauta.minutes.failed"
        case recordingImported = "vauta.imported"
        case startFailed = "vauta.start.failed"
        case startBlocked = "vauta.start.blocked"
        case startNeedsModel = "vauta.start.model"
        case voicesUnused = "vauta.voices.unused"
        /// Shortly before a meeting: "Brief ready". Never carries brief content, and the event's title only when titles may be shown.
        case brief = "vauta.brief"

        /// The buttons of the notification, in order.
        public var actions: [Action] {
            switch self {
            case .autoStopWarning: [.keepRecording]
            case .hangup: [.stopRecording, .keepRecording]
            case .suggestion: [.transcribe]
            case .recordingStopped: [.openMeeting]
            case .serverUnreachable: [.showModels]
            case .minutesReady, .recordingImported: [.openMeeting]
            case .minutesFailed: [.openMeeting, .retryMinutes]
            case .startFailed: [.showStatus]
            case .startBlocked: [.openSystemSettings]
            case .startNeedsModel: [.installModel]
            case .voicesUnused: [.showSpeakers]
            case .brief: [.openBrief, .recordAtStart]
            }
        }

        /// What a click on the notification itself does.
        public var defaultAction: Action? {
            switch self {
            case .autoStopWarning, .hangup: nil
            case .suggestion: .transcribe
            case .recordingStopped, .minutesReady, .minutesFailed, .recordingImported: .openMeeting
            case .serverUnreachable: .showModels
            case .startFailed: .showStatus
            case .startBlocked: .openSystemSettings
            case .startNeedsModel: .installModel
            case .voicesUnused: .showSpeakers
            case .brief: .openBrief
            }
        }

        /// Which preference allows it.
        public var gate: Gate {
            switch self {
            case .brief: .brief
            case .autoStopWarning, .hangup, .suggestion: .always
            case .minutesReady, .recordingImported: .minutesReady
            case .recordingStopped, .serverUnreachable, .minutesFailed, .startFailed, .startBlocked, .startNeedsModel, .voicesUnused: .problems
            }
        }
    }

    public enum Action: String, CaseIterable, Sendable {
        case keepRecording = "keep"
        case stopRecording = "stop"
        case transcribe
        case openMeeting = "open"
        case retryMinutes = "retry"
        /// Settings → Models (the model server can’t be reached).
        case showModels = "models"
        /// Settings → Status (it explains why recording didn’t start).
        case showStatus = "status"
        case openSystemSettings = "system"
        case installModel = "install"
        /// Settings → Speakers (saved voices that had no suggestion accepted for a year).
        case showSpeakers = "speakers"
        /// Shows the brief of the event (after unlocking Meetings).
        case openBrief = "brief"
        /// Asks Vauta to suggest recording when the event starts (it does not record by itself).
        case recordAtStart = "recordAtStart"
    }

    public enum Gate: Sendable {
        /// Prompts about the recording in progress (they have their own settings).
        case always
        case minutesReady
        case problems
        case brief
    }

    public let kind: Kind
    public let title: String
    public let body: String
    /// The meeting the notification is about (for Open and Retry).
    public let meetingID: Int64?
    /// The calendar occurrence the brief notification is about (identifier and start, never content), so "Record at Start" still works
    /// after Vauta relaunched: the buttons of a delivered notification outlive the app.
    public let occurrence: BriefOccurrence?

    public init(kind: Kind, title: String, body: String, meetingID: Int64? = nil, occurrence: BriefOccurrence? = nil) {
        self.kind = kind
        self.title = title
        self.body = body
        self.meetingID = meetingID
        self.occurrence = occurrence
    }

    /// One notification per kind, or per kind and meeting: a new one replaces
    /// the previous one with the same identifier.
    public var identifier: String {
        meetingID.map { "\(kind.rawValue).\($0)" } ?? kind.rawValue
    }

    public static func isAllowed(_ kind: Kind, notifyMinutesReady: Bool, notifyProblems: Bool, notifyBrief: Bool = true) -> Bool {
        switch kind.gate {
        case .always: true
        case .brief: notifyBrief
        case .minutesReady: notifyMinutesReady
        case .problems: notifyProblems
        }
    }

    // MARK: Builders

    public static func autoStopWarning(secondsLeft: Int) -> AppNotification {
        AppNotification(
            kind: .autoStopWarning,
            title: String(localized: "Vauta will stop recording soon", comment: "Notification title before an automatic stop"),
            body: String(localized: "The meeting hasn’t been heard for a while. Recording stops in \(secondsLeft) s unless you keep recording.",
                         comment: "Notification body before an automatic stop; the argument is seconds"))
    }

    /// - Parameter appName: the app that released the microphone, if known.
    public static func hangup(appName: String?) -> AppNotification {
        let body = if let appName {
            String(localized: "\(appName) stopped using the microphone. Vauta is still recording.",
                   comment: "Notification body; the argument is an app name such as Zoom or Google Chrome")
        } else {
            String(localized: "The meeting app stopped using the microphone. Vauta is still recording.",
                   comment: "Notification body when the app is unknown")
        }
        return AppNotification(kind: .hangup,
                               title: String(localized: "Has the meeting ended?", comment: "Notification title"),
                               body: body)
    }

    /// - Parameters:
    ///   - callDescription: `CallDescription.sentence(…)`, e.g. "Zoom is using the microphone."
    ///   - eventTitle: the calendar event's title, only when titles may be shown.
    public static func suggestion(callDescription: String, eventTitle: String?) -> AppNotification {
        let body = if let eventTitle, !eventTitle.isEmpty {
            String(localized: "“\(eventTitle)” is in progress. \(callDescription)",
                   comment: "Notification body; the first argument is a calendar event title, the second a sentence such as “Zoom is using the microphone.”")
        } else {
            callDescription
        }
        return AppNotification(kind: .suggestion,
                               title: String(localized: "Record this meeting?", comment: "Notification title"),
                               body: body)
    }

    public static func recordingStopped(_ reason: RecordingStopReason, meetingID: Int64?) -> AppNotification {
        AppNotification(kind: .recordingStopped,
                        title: String(localized: "Recording stopped", comment: "Notification title after an automatic stop"),
                        body: reason.explanation, meetingID: meetingID)
    }

    /// A recording that did not start. `reason` says what happened and what to do; it never
    /// carries meeting text.
    public static func startFailed(_ kind: Kind, reason: String) -> AppNotification {
        AppNotification(kind: kind,
                        title: String(localized: "Recording didn’t start", comment: "Notification title when a recording could not start"),
                        body: reason)
    }

    public static func serverUnreachable() -> AppNotification {
        AppNotification(
            kind: .serverUnreachable,
            title: String(localized: "Can’t reach the model server", comment: "Notification title"),
            body: String(localized: "Live notes are paused. Recording continues, and the minutes will be written when the server is back.",
                         comment: "Notification body when the model server is unreachable while recording"))
    }

    /// - Parameter meetingTitle: shown only when titles may be shown (else the start date is used).
    public static func minutesReady(meetingID: Int64, meetingTitle: String?, startedAt: Date) -> AppNotification {
        let body = if let meetingTitle, !meetingTitle.isEmpty {
            String(localized: "The minutes of “\(meetingTitle)” are ready.", comment: "Notification body; the argument is a meeting title")
        } else {
            String(localized: "The minutes of your meeting of \(startedAt.formatted(date: .abbreviated, time: .shortened)) are ready.",
                   comment: "Notification body; the argument is the meeting's date and time")
        }
        return AppNotification(kind: .minutesReady,
                               title: String(localized: "Minutes ready", comment: "Notification title"),
                               body: body, meetingID: meetingID)
    }

    /// The brief of an event that starts in `minutes` minutes is ready. The text never carries anything from the brief: only the
    /// event's title, and only when `eventTitle` is given (the person allows titles in notifications).
    public static func brief(minutesBefore minutes: Int, eventTitle: String?, occurrence: BriefOccurrence? = nil) -> AppNotification {
        let title = if let eventTitle, !eventTitle.isEmpty {
            String(localized: "\(eventTitle) in \(minutes) minutes", comment: "Notification title before a meeting; the first argument is the calendar event's title, the second a number of minutes")
        } else {
            String(localized: "Meeting in \(minutes) minutes", comment: "Notification title before a meeting; the argument is a number of minutes")
        }
        return AppNotification(kind: .brief, title: title, body: String(localized: "Brief ready", comment: "Notification body: the brief of the meeting about to start is ready; it says nothing about its content"),
                               occurrence: occurrence)
    }

    /// Saved voices that have had no suggestion accepted for a year: Vauta only asks. It names nobody (notifications are stored
    /// outside the encrypted store and appear on the lock screen); the Speakers pane shows whose voices they are.
    public static func voicesUnused() -> AppNotification {
        AppNotification(kind: .voicesUnused,
                        title: String(localized: "Some saved voices are unused", comment: "Notification title: saved voices that have had no suggestion accepted in a year"),
                        body: String(localized: "Saved voices that haven’t had a suggestion accepted in over a year are waiting for you in the Speakers pane. Keep or delete them there.",
                                     comment: "Notification body: the reminder to review saved voices unused for a year; it never names a person"))
    }

    /// A recording imported from a file finished transcribing while the Meetings window was closed or locked.
    /// It names no meeting: the title and the text stay in the store.
    public static func recordingImported(meetingID: Int64) -> AppNotification {
        AppNotification(kind: .recordingImported,
                        title: String(localized: "Recording imported", comment: "Notification title when an imported recording has been transcribed"),
                        body: String(localized: "The transcript is ready. Open the meeting to read it.",
                                     comment: "Notification body when an imported recording has been transcribed"),
                        meetingID: meetingID)
    }

    /// The error itself is never shown: a server's error text can quote the
    /// request (meeting text), and notifications are stored outside the
    /// encrypted store and appear on the lock screen. The meeting shows it.
    public static func minutesFailed(meetingID: Int64, meetingTitle: String?, startedAt: Date) -> AppNotification {
        let body = if let meetingTitle, !meetingTitle.isEmpty {
            String(localized: "The minutes of “\(meetingTitle)” couldn’t be written. Open the meeting to see why, or try again.",
                   comment: "Notification body; the argument is a meeting title")
        } else {
            String(localized: "The minutes of your meeting of \(startedAt.formatted(date: .abbreviated, time: .shortened)) couldn’t be written. Open the meeting to see why, or try again.",
                   comment: "Notification body; the argument is the meeting's date and time")
        }
        return AppNotification(kind: .minutesFailed,
                               title: String(localized: "Minutes failed", comment: "Notification title"),
                               body: body, meetingID: meetingID)
    }
}
