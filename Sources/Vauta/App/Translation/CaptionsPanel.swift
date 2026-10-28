// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// The floating captions window. It never takes focus (so the meeting app
/// keeps the keyboard), is not in ⌘Tab, follows the user to every Space and
/// shows over full-screen apps.
final class CaptionsPanel: NSPanel {
    /// Only with Full Keyboard Access, so its controls can be reached with Tab, or while Apple's download sheet
    /// hangs from the panel; otherwise the meeting app keeps the keyboard.
    var acceptsKey = false
    override var canBecomeKey: Bool { acceptsKey || NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeMain: Bool { false }
}

/// Reports the pointer entering and leaving even though Vauta is not the
/// active app (SwiftUI's `onHover` waits for activation) and lets the first
/// click reach the controls.
final class CaptionsHostingView: NSHostingView<CaptionsView> {
    var onPointer: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onPointer?(true) }
    override func mouseExited(with event: NSEvent) { onPointer?(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Creates, places and remembers the captions panel.
@MainActor
final class CaptionsPanelController: NSObject, NSWindowDelegate {
    weak var model: LiveTranslationModel?
    private var panel: CaptionsPanel?
    private let frames = CaptionFrameStore()
    private var saveTask: Task<Void, Never>?
    private var placing = false

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        guard let model else { return }
        let panel = self.panel ?? makePanel(model)
        self.panel = panel
        guard !panel.isVisible else { return }
        place(panel, model: model)
        panel.orderFrontRegardless()
    }

    func hide() {
        saveTask?.cancel()
        if let panel, panel.isVisible {
            save(panel)
            panel.orderOut(nil)
        }
    }

    /// While the download sheet of the system is on the panel it must be able to take the keyboard.
    func setAcceptsKey(_ accepts: Bool) {
        panel?.acceptsKey = accepts
    }

    /// The text size or the original line changed: the panel gets the height it needs.
    func layoutChanged() {
        guard let panel, let model else { return }
        let height = model.panelHeight
        applyLimits(panel, height: height)
        var frame = panel.frame
        guard abs(frame.height - height) > 0.5 else { return }
        // The bottom edge stays: captions grow upwards, like subtitles do.
        frame.size.height = height
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            frame = CaptionFrameStore.fit(frame, height: height, in: visible)
        }
        placing = true
        panel.setFrame(frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        placing = false
        panel.invalidateShadow()
    }

    // MARK: Creation and placement

    private func makePanel(_ model: LiveTranslationModel) -> CaptionsPanel {
        let panel = CaptionsPanel(contentRect: CGRect(x: 0, y: 0, width: CaptionTextSize.defaultWidth, height: model.panelHeight),
                                  styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        // What the other people say: asks macOS to keep it out of screen sharing (not guaranteed against ScreenCaptureKit).
        panel.sharingType = .none
        panel.isRestorable = false
        panel.title = String(localized: "Live Translation", comment: "Window title of the captions panel (read by VoiceOver)")
        let host = CaptionsHostingView(rootView: CaptionsView(model: model))
        host.sizingOptions = []
        host.onPointer = { [weak model] inside in model?.pointerMoved(inside: inside) }
        panel.contentView = host
        panel.delegate = self
        return panel
    }

    private func place(_ panel: CaptionsPanel, model: LiveTranslationModel) {
        let screens = NSScreen.screens
        let screen = screens.first { $0.captionID == frames.lastScreen } ?? NSScreen.main ?? screens.first
        guard let screen else { return }
        let height = model.panelHeight
        let frame: CGRect
        if let saved = frames.frame(forScreen: screen.captionID) {
            frame = CaptionFrameStore.fit(saved, height: height, in: screen.visibleFrame)
        } else {
            frame = CaptionFrameStore.defaultFrame(in: screen.visibleFrame, height: height)
        }
        applyLimits(panel, height: height)
        placing = true
        panel.setFrame(frame, display: true)
        placing = false
        panel.invalidateShadow()
    }

    /// The width can be changed by dragging an edge; the height follows the text size.
    private func applyLimits(_ panel: CaptionsPanel, height: CGFloat) {
        panel.contentMinSize = CGSize(width: CaptionTextSize.minimumWidth, height: height)
        panel.contentMaxSize = CGSize(width: CaptionTextSize.maximumWidth, height: height)
    }

    // MARK: Remembering

    func windowDidMove(_ notification: Notification) { scheduleSave() }
    func windowDidResize(_ notification: Notification) {
        scheduleSave()
        panel?.invalidateShadow()
    }

    private func scheduleSave() {
        guard !placing, let panel else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.save(panel)
        }
    }

    private func save(_ panel: CaptionsPanel) {
        guard let screen = panel.screen else { return }
        frames.save(panel.frame, forScreen: screen.captionID)
    }
}

extension NSScreen {
    /// A stable identifier of the display (it survives restarts and re-plugging).
    var captionID: String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = deviceDescription[key] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return "main" }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

extension LiveTranslationModel {
    /// The panel height for the chosen text size and original line.
    var panelHeight: CGFloat { preferences.captionTextSize.panelHeight(showOriginal: preferences.captionShowOriginal) }
}
