// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import SwiftUI

/// Asks before the Settings window closes with unsaved model server changes (⌘W and the close button both
/// go through `windowShouldClose`). Everything else the window's own delegate does is forwarded to it.
struct ModelsCloseGuard: NSViewRepresentable {
    let hasChanges: @MainActor () -> Bool
    let apply: @MainActor () async -> Void
    let discard: @MainActor () -> Void
    /// Goes to the Models pane, where the Save bar (and the message of a failed apply) is.
    let showModels: @MainActor () -> Void
    /// The message of a failed apply, for VoiceOver.
    let failure: @MainActor () -> String?

    /// Whether Quit must wait: the Settings window is open with unsaved model server changes. Asks the same
    /// question as closing the window; `completion(true)` means the quit may go on.
    @MainActor
    static func confirmQuit(completion: @escaping @MainActor (Bool) -> Void) -> Bool {
        guard let view = GuardView.current, let window = view.window, window.isVisible,
              view.owner?.hasChanges() == true else { return false }
        view.ask(window, completion: completion)
        return true
    }

    func makeNSView(context: Context) -> NSView {
        let view = GuardView()
        view.owner = self
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? GuardView)?.owner = self
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        (view as? GuardView)?.release()
    }

    final class GuardView: NSView {
        /// The guard of the open Settings window, if any.
        static weak var current: GuardView?
        var owner: ModelsCloseGuard?
        private var asking = false
        /// Questions that arrived while the alert was already up (⌘Q over the close sheet): they get the same answer.
        private var waiting: [@MainActor (Bool) -> Void] = []
        private var proxy: Proxy?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, proxy == nil else { return }
            let proxy = Proxy(previous: window.delegate, view: self)
            self.proxy = proxy
            window.delegate = proxy
            Self.current = self
        }

        func release() {
            if let window, let proxy, window.delegate === proxy { window.delegate = proxy.previous }
            proxy = nil
            if Self.current === self { Self.current = nil }
        }

        @MainActor
        fileprivate func shouldClose(_ window: NSWindow) -> Bool {
            guard let owner, owner.hasChanges() else { return true }
            ask(window) { proceed in if proceed { window.close() } }
            return false
        }

        /// The alert, on the Models pane so the Save bar is in view whatever the answer. `completion(true)`:
        /// the changes were applied or dropped and the window (or the app) may go.
        @MainActor
        fileprivate func ask(_ window: NSWindow, completion: @escaping @MainActor (Bool) -> Void) {
            guard let owner else { return completion(true) }
            guard !asking else { waiting.append(completion); return }
            asking = true
            owner.showModels()
            window.makeKeyAndOrderFront(nil)
            let alert = NSAlert()
            alert.messageText = String(localized: "Save your model server changes?", comment: "Alert when closing Settings or quitting with unsaved Models changes")
            alert.informativeText = String(localized: "You changed the model server settings but haven’t saved them. If you don’t save them, your changes are lost.", comment: "Alert when closing Settings or quitting with unsaved Models changes; the second sentence says what Don’t Save does")
            alert.addButton(withTitle: String(localized: "Save", comment: "Button"))
            let dontSave = alert.addButton(withTitle: String(localized: "Don’t Save", comment: "Alert button: drops the unsaved changes and goes on (closing Settings or quitting)"))
            dontSave.keyEquivalent = "d"
            dontSave.keyEquivalentModifierMask = .command
            alert.addButton(withTitle: String(localized: "Cancel", comment: "Button")).keyEquivalent = "\u{1b}"
            alert.beginSheetModal(for: window) { [weak self] response in
                Task { @MainActor in
                    guard let self else { return }
                    self.asking = false
                    let queued = self.waiting
                    self.waiting = []
                    let completion: @MainActor (Bool) -> Void = { proceed in
                        completion(proceed)
                        for other in queued { other(proceed) }
                    }
                    switch response {
                    case .alertFirstButtonReturn:
                        await owner.apply()
                        if owner.hasChanges() {
                            // A failed apply stays on the Models pane, where its message is, and says so aloud.
                            owner.showModels()
                            if let message = owner.failure() {
                                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                                     userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
                            }
                            completion(false)
                        } else {
                            completion(true)
                        }
                    case .alertSecondButtonReturn:
                        owner.discard()
                        completion(true)
                    default:
                        completion(false)
                    }
                }
            }
        }
    }

    final class Proxy: NSObject, NSWindowDelegate {
        let previous: NSWindowDelegate?
        weak var view: GuardView?

        init(previous: NSWindowDelegate?, view: GuardView) {
            self.previous = previous
            self.view = view
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            let allowed = MainActor.assumeIsolated { view?.shouldClose(sender) ?? true }
            return allowed && (previous?.windowShouldClose?(sender) ?? true)
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (previous as? NSObject)?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            (previous as? NSObject)?.responds(to: selector) == true ? previous : nil
        }
    }
}
