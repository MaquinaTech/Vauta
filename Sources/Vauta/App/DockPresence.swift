// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit

/// Vauta lives in the menu bar (`LSUIElement`), but while one of its windows
/// (Meetings, Settings, Welcome) is open it behaves like a regular app: Dock
/// icon, ⌘Tab and the full menu bar. When the last one closes, it goes back to
/// menu-bar only.
///
/// Titled windows register themselves through `WindowHardening` (the menu-bar
/// panel is excluded). A window counts as
/// open while it is visible or minimized (a minimized window lives in the
/// Dock, which needs the icon). The decision is re-evaluated, debounced, on
/// every window event, so closing several windows, minimizing, restoring, or
/// the Meetings window closing when it relocks all end in the right policy.
@MainActor
final class DockPresence {
    static let shared = DockPresence()

    private let windows = NSHashTable<NSWindow>.weakObjects()
    private var started = false
    private var pending: Task<Void, Never>?

    /// Starts watching window events. Call once at launch.
    func start() {
        guard !started else { return }
        started = true
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didExposeNotification,
            NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DockPresence.shared.scheduleUpdate() }
            }
        }
    }

    /// Counts `window` as one of Vauta's windows.
    /// The menu-bar panel (an untitled `NSPanel`) is not counted: opening it
    /// must not put Vauta in the Dock.
    func track(_ window: NSWindow) {
        guard !(window is NSPanel), window.styleMask.contains(.titled), !windows.contains(window) else { return }
        windows.add(window)
        scheduleUpdate()
    }

    /// Whether any tracked window is open.
    var hasOpenWindow: Bool {
        windows.allObjects.contains { $0.isVisible || $0.isMiniaturized }
    }

    /// Whether `window` is one of Vauta's windows (Meetings, Settings, Network Activity, the setup), the ones Hide Vauta
    /// Windows takes off the screen.
    func isTracked(_ window: NSWindow) -> Bool { windows.contains(window) }

    private func scheduleUpdate() {
        pending?.cancel()
        // After the event settles: a closing window is still visible when its
        // notification is posted.
        pending = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            update()
        }
    }

    private func update() {
        // A hidden app (⌘H) reports its windows as not visible: leave the policy alone.
        guard !NSApp.isHidden else { return }
        if hasOpenWindow {
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate()
            }
        } else if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
