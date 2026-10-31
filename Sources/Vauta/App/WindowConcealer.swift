// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import Observation

/// What the concealer orders out and back in: an `NSWindow`, or a stand-in in tests.
@MainActor
protocol ConcealableWindow: AnyObject {
    var isVisible: Bool { get }
    func orderOut(_ sender: Any?)
    func orderFrontRegardless()
}

extension NSWindow: ConcealableWindow {}

/// Hides Vauta's windows for presenting and brings the same ones back (`WindowConcealment` decides which). They are ordered
/// out, not closed: a window comes back as it was, with its sheet, and nothing in it is saved or read again. A window that
/// closes meanwhile (a relock, the person) is not brought back.
@MainActor @Observable
final class WindowConcealer {
    /// Vauta's windows are hidden: the menu-bar icon and the panel say so until they come back.
    private(set) var isOn = false
    @ObservationIgnored private var state = WindowConcealment<ObjectIdentifier>()
    @ObservationIgnored private var windows: [ObjectIdentifier: Held] = [:]
    @ObservationIgnored private var closing: (any NSObjectProtocol)?

    private struct Held { weak var window: (any ConcealableWindow)? }

    /// Orders out `onScreen`, given front to back. With nothing on screen the windows still count as hidden, so nothing of
    /// Vauta comes up by itself until they are shown again.
    func conceal(_ onScreen: [any ConcealableWindow]) {
        guard !state.isOn else { return }
        _ = state.conceal(onScreen: onScreen.map { ObjectIdentifier($0) })
        windows = Dictionary(onScreen.map { (ObjectIdentifier($0), Held(window: $0)) }, uniquingKeysWith: { first, _ in first })
        for window in onScreen { window.orderOut(nil) }
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            let id = ObjectIdentifier(window)
            MainActor.assumeIsolated { self?.closed(id) }
        }
        isOn = true
    }

    /// Brings back the hidden windows that are still there, back to front; one the person opened again meanwhile stays as it is.
    func reveal() {
        guard state.isOn else { return }
        for id in state.reveal() {
            if let window = windows[id]?.window, !window.isVisible { window.orderFrontRegardless() }
        }
        windows = [:]
        if let closing { NotificationCenter.default.removeObserver(closing) }
        closing = nil
        isOn = false
    }

    /// A window closed while hidden, or after the person opened it again: it is not brought back.
    func closed(_ id: ObjectIdentifier) {
        state.closed(id)
        windows[id] = nil
    }
}
