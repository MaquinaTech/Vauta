// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation
import UserNotifications

/// Local notifications (never remote). They carry no transcript text; meeting
/// and event titles only when the user allows it in Settings.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// A button (or the notification itself) was clicked.
    var onAction: ((AppNotification.Action, _ meetingID: Int64?, _ occurrence: BriefOccurrence?) -> Void)?
    /// Whether the Meetings window is frontmost and shows this meeting: its notifications then stay in the list
    /// (no banner, no sound over what the person is already looking at).
    var isShowingMeeting: ((Int64) -> Bool)?

    private let center = UNUserNotificationCenter.current()
    /// Bumped by `remove`, so a delivery still waiting for the permission
    /// status doesn't show a notification that was withdrawn meanwhile.
    private var generations: [String: Int] = [:]

    nonisolated private static let meetingIDKey = "meetingID"
    nonisolated private static let eventKey = "briefEvent"
    nonisolated private static let eventStartKey = "briefStart"

    override init() {
        super.init()
        center.delegate = self
        center.setNotificationCategories(Set(AppNotification.Kind.allCases.map { kind in
            UNNotificationCategory(identifier: kind.rawValue, actions: kind.actions.map(Self.action), intentIdentifiers: [])
        }))
    }

    static func action(_ action: AppNotification.Action) -> UNNotificationAction {
        let title = switch action {
        case .keepRecording: String(localized: "Keep Recording", comment: "Notification button")
        case .stopRecording: String(localized: "Stop and Save", comment: "Notification button")
        case .resumeRecording: String(localized: "Resume", comment: "Notification button: resumes the paused recording")
        case .transcribe: String(localized: "Record", comment: "Notification button: start recording the meeting")
        case .openMeeting: String(localized: "Open Meeting", comment: "Notification button: open the meeting")
        case .retryMinutes: String(localized: "Try Again", comment: "Notification button: write the minutes again")
        case .showModels: SettingsModel.Pane.models.openTitle
        case .showStatus: SettingsModel.Pane.status.openTitle
        case .showSpeakers: SettingsModel.Pane.speakers.openTitle
        case .openSystemSettings: String(localized: "Open System Settings", comment: "Notification button")
        case .installModel: String(localized: "Download", comment: "Notification button: download the missing speech model")
        case .openBrief: String(localized: "Open Brief", comment: "Notification button: show the brief of the meeting about to start")
        case .recordAtStart: String(localized: "Record at Start", comment: "Notification button: suggest recording when the meeting starts; it does not start a recording by itself")
        }
        // Actions that show a window bring Vauta to the front.
        let options: UNNotificationActionOptions = switch action {
        case .transcribe, .openMeeting, .showModels, .showStatus, .showSpeakers, .openSystemSettings, .openBrief: [.foreground]
        default: []
        }
        return UNNotificationAction(identifier: action.rawValue, title: title, options: options)
    }

    /// Asks for permission if it was never asked. Never awaited before a
    /// recording starts: if the user denies it, the panel and the menu-bar
    /// icon still show every warning.
    func requestAuthorization() async {
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func status() async -> UNAuthorizationStatus { await center.notificationSettings().authorizationStatus }

    /// Delivers `notification` if permission is granted (never prompts). The
    /// status is read each time: the user can allow or deny notifications in
    /// System Settings while Vauta runs.
    func post(_ notification: AppNotification) {
        let id = notification.identifier
        let generation = generations[id, default: 0]
        Task {
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional, generations[id, default: 0] == generation else { return }
            deliver(notification)
        }
    }

    private func deliver(_ notification: AppNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.categoryIdentifier = notification.kind.rawValue
        if let meetingID = notification.meetingID { content.userInfo = [Self.meetingIDKey: meetingID] }
        if let occurrence = notification.occurrence { content.userInfo = [Self.eventKey: occurrence.identifier, Self.eventStartKey: occurrence.startSeconds] }
        content.sound = .default
        content.interruptionLevel = .active
        center.add(UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil))
    }

    func remove(_ kind: AppNotification.Kind, meetingID: Int64? = nil) {
        let id = AppNotification(kind: kind, title: "", body: "", meetingID: meetingID).identifier
        generations[id, default: 0] += 1
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        let content = notification.request.content
        if content.categoryIdentifier == AppNotification.Kind.minutesReady.rawValue,
           let meetingID = (content.userInfo[Self.meetingIDKey] as? NSNumber)?.int64Value,
           await MainActor.run(body: { isShowingMeeting?(meetingID) ?? false }) {
            return [.list]
        }
        return [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let actionID = response.actionIdentifier
        let content = response.notification.request.content
        let category = content.categoryIdentifier
        let meetingID = (content.userInfo[Self.meetingIDKey] as? NSNumber)?.int64Value
        let occurrence: BriefOccurrence? = if let id = content.userInfo[Self.eventKey] as? String, let start = (content.userInfo[Self.eventStartKey] as? NSNumber)?.int64Value {
            BriefOccurrence(identifier: id, start: Date(timeIntervalSince1970: TimeInterval(start)))
        } else {
            nil
        }
        await MainActor.run {
            let action: AppNotification.Action? = if actionID == UNNotificationDefaultActionIdentifier {
                AppNotification.Kind(rawValue: category)?.defaultAction
            } else {
                AppNotification.Action(rawValue: actionID)
            }
            if let action { onAction?(action, meetingID, occurrence) }
        }
    }
}
