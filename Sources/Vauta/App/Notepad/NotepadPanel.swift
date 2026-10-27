// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// The floating notepad. The menu-bar panel closes as soon as the user clicks into the meeting app, so this is the
/// surface for typing during a call: it floats over every app and every Space, takes typing WITHOUT activating Vauta (the
/// meeting app stays the front app, as with Spotlight) and is hidden from screen sharing and screenshots.
final class NotepadPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Creates, places and remembers the notepad window.
@MainActor
final class NotepadPanelController: NSObject, NSWindowDelegate {
    static let frameName = "VautaNotepad"
    static let defaultSize = CGSize(width: 340, height: 320)
    private(set) var panel: NotepadPanel?
    private weak var model: RecorderModel?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// The user is looking at it or typing in it, so it does not close by itself.
    var hasInteraction: Bool {
        guard let panel else { return false }
        return panel.isKeyWindow || panel.frame.contains(NSEvent.mouseLocation)
    }

    /// Opens the notepad. With `takesKeyboard` the field has the keyboard at once (the meeting app keeps being the
    /// active app); without it (it opened by itself when the recording started) the keyboard stays where it was.
    func show(model: RecorderModel, takesKeyboard: Bool) {
        self.model = model
        let panel = self.panel ?? makePanel(model)
        self.panel = panel
        if !panel.isVisible { place(panel) }
        if takesKeyboard {
            panel.makeKeyAndOrderFront(nil)
            model.notepadFocusRequest += 1
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// The shortcut: closed → open with the keyboard; open and in use → close; open but behind → bring it to the keyboard.
    func toggle(model: RecorderModel) {
        guard let panel, panel.isVisible else { show(model: model, takesKeyboard: true); return }
        if panel.isKeyWindow { hide() } else { show(model: model, takesKeyboard: true) }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.saveFrame(usingName: Self.frameName)
        panel.orderOut(nil)
        model?.notepadWindowClosed()
    }

    /// The window as it must be: floating, key-capable without activating Vauta, out of screen sharing.
    static func makeBarePanel() -> NotepadPanel {
        let panel = NotepadPanel(contentRect: CGRect(origin: .zero, size: defaultSize),
                                 styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.isRestorable = false
        panel.minSize = CGSize(width: 260, height: 180)
        // What the user writes about the meeting stays out of screen shares and screenshots, like the captions.
        panel.sharingType = .none
        panel.title = String(localized: "Notepad", comment: "Window title of the floating notepad where the user types short notes during a recording (read by VoiceOver)")
        return panel
    }

    private func makePanel(_ model: RecorderModel) -> NotepadPanel {
        let panel = Self.makeBarePanel()
        panel.onEscape = { [weak self] in self?.hide() }
        let host = NSHostingView(rootView: NotepadWindowView(model: model) { [weak self] in self?.hide() })
        host.sizingOptions = []
        panel.contentView = host
        panel.delegate = self
        // A move or resize is remembered however the window closes (Esc, the shortcut or the title bar's button).
        panel.setFrameAutosaveName(Self.frameName)
        return panel
    }

    private func place(_ panel: NotepadPanel) {
        if panel.setFrameUsingName(Self.frameName), NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = Self.defaultSize
        panel.setFrame(CGRect(x: visible.maxX - size.width - 24, y: visible.minY + 24, width: size.width, height: size.height), display: true)
    }

    func windowWillClose(_ notification: Notification) {
        (notification.object as? NSWindow)?.saveFrame(usingName: Self.frameName)
        model?.notepadWindowClosed()
    }
}

/// The content of the notepad window: the notes, and after the recording where to keep adding them.
struct NotepadWindowView: View {
    @Bindable var model: RecorderModel
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NotesSection(model: model, large: true, maxListHeight: nil, onEscape: close)
            if model.notepadSavedMeeting != nil {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Label { Text("Meeting saved. Keep adding notes in Meetings.").fixedSize(horizontal: false, vertical: true) } icon: { StatusSymbol.ok.image }
                        .font(.callout)
                    Button("Open in Meetings") { model.openNotesInMeetings() }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.copyProtection, model.preferences.copyProtection)
        .writingToolsBehavior(.disabled)
    }
}
