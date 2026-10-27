// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit

/// When setup ends the window closes and Vauta leaves the Dock. Opening the menu bar panel once shows
/// where it lives. Nothing happens if the status item can't be found.
@MainActor
enum MenuBarReveal {
    static func showOnce(recorder: RecorderModel) {
        Task { @MainActor in
            // After the window has closed and the activation policy has settled.
            try? await Task.sleep(for: .milliseconds(500))
            if let button = statusButton(), isVisible(button) {
                button.performClick(nil)
            } else {
                // The icon is hidden (behind the notch, or by a menu bar manager): don't leave the user
                // with nothing. Settings → General says where it went and how to come back.
                recorder.settingsModel?.menuBarIconMayBeHidden = true
                recorder.showSettings(.general)
            }
        }
    }

    /// Whether the icon is on a screen and not covered.
    private static func isVisible(_ button: NSStatusBarButton) -> Bool {
        guard let window = button.window, window.isVisible, window.screen != nil else { return false }
        return window.occlusionState.contains(.visible)
    }

    private static func statusButton() -> NSStatusBarButton? {
        for window in NSApp.windows where String(describing: type(of: window)).contains("StatusBar") {
            if let button = button(in: window.contentView) { return button }
        }
        return nil
    }

    private static func button(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let found = button(in: subview) { return found }
        }
        return nil
    }
}
