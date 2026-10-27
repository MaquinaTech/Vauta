// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import AVFoundation
import UserNotifications

/// Permission states and requests shared by Settings and the setup. Asking
/// for a permission never records anything.
@MainActor
enum Permissions {
    static var microphone: PermissionState {
        #if VAUTA_DIAGNOSTICS
        if let sample = SnapshotMode.microphone { return sample }
        #endif
        return switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }

    /// Shows the system prompt the first time; afterwards only System Settings can change it.
    static func requestMicrophone() async -> PermissionState {
        if microphone == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        return microphone
    }

    static func notifications() async -> PermissionState {
        #if VAUTA_DIAGNOSTICS
        if let sample = SnapshotMode.notifications { return sample }
        #endif
        return switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }

    static func requestNotifications() async -> PermissionState {
        if await notifications() == .notDetermined {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
        return await notifications()
    }

    /// Opens a System Settings pane (the notifications pane opens on Vauta's entry).
    static func open(_ pane: SystemSettingsPane) {
        var url = pane.url
        if pane == .notifications, let id = Bundle.main.bundleIdentifier {
            url = URL(string: url.absoluteString + "?id=" + id) ?? url
        }
        NSWorkspace.shared.open(url)
    }
}

extension PermissionState {
    /// Short state for lists ("Allowed", "Not allowed"…).
    var label: String {
        switch self {
        case .granted: String(localized: "Allowed", comment: "Permission state")
        case .denied: String(localized: "Not allowed", comment: "Permission state")
        case .notDetermined: String(localized: "Not asked yet", comment: "Permission state")
        case .unknown: String(localized: "Asked when you first record", comment: "Permission state for system audio, which apps cannot read")
        }
    }

    var symbol: String {
        switch self {
        case .granted: StatusSymbol.ok.name
        case .denied: StatusSymbol.error.name
        case .notDetermined: StatusSymbol.info.name
        case .unknown: StatusSymbol.info.name
        }
    }
}
