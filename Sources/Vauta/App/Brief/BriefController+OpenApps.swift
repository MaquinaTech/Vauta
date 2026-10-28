// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import EventKit
import Foundation
import Observation

extension BriefController {
    // MARK: Opening other apps (read-only)

    /// Shows the event in Calendar when it has an identifier, else launches Calendar. Nothing is created or changed.
    func openCalendar(_ event: BriefEvent? = nil) { openCalendar(eventIdentifier: event?.eventIdentifier) }

    func openCalendar(eventIdentifier: String?) {
        if let url = BriefOpenURL.event(eventIdentifier: eventIdentifier), BriefController.openShowing(url, in: "com.apple.iCal") { return }
        BriefController.openApp("com.apple.iCal")
    }

    /// Shows the reminder in Reminders when its identifier is known, else launches Reminders.
    func openReminders(id: String? = nil) {
        if let url = BriefOpenURL.reminder(id: id), BriefController.openShowing(url, in: "com.apple.reminders") { return }
        BriefController.openApp("com.apple.reminders")
    }

    /// Opens `url` with the Apple app that owns it; false when that app is not there.
    private static func openShowing(_ url: URL, in bundleID: String) -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    static func openApp(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
