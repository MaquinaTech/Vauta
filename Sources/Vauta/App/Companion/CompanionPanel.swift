// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// A click on the bar acts at once, though the bar never becomes the key window.
final class CompanionHostingView: NSHostingView<CompanionBar> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The meeting companion's window: a borderless floating bar that never activates Vauta and never takes the keyboard (the
/// meeting app keeps both), on every Space and over full-screen apps. It asks macOS to stay out of screen sharing, which is not
/// guaranteed (Hide Vauta Windows takes it off the screen). It is dragged by its time and keeps the place it was put in.
@MainActor
final class CompanionPanelController: NSObject {
    static let frameName = "VautaCompanion"
    private(set) var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(model: RecorderModel, close: @escaping () -> Void) {
        let panel = self.panel ?? makePanel(model, close: close)
        self.panel = panel
        guard !panel.isVisible else { return }
        place(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.saveFrame(usingName: Self.frameName)
        panel.orderOut(nil)
    }

    /// The window as it must be (see the type's description).
    static func makeBarePanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 300, height: 40), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isRestorable = false
        panel.sharingType = .none
        panel.title = CompanionBar.title
        return panel
    }

    private func makePanel(_ model: RecorderModel, close: @escaping () -> Void) -> NSPanel {
        let panel = Self.makeBarePanel()
        let host = CompanionHostingView(rootView: CompanionBar(model: model, close: close) { [weak self] size in self?.fit(size) })
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrameAutosaveName(Self.frameName)
        return panel
    }

    /// The bar's own size, keeping its centre and its top edge where they were (the time grows by a digit after an hour).
    private func fit(_ size: CGSize) {
        guard let panel, size.width > 0, size.height > 0, panel.frame.size != size else { return }
        var frame = panel.frame
        frame.origin.x = frame.midX - size.width / 2
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    /// Where it was put, if that is still on a screen; otherwise at the top of the main screen, centred under the menu bar.
    private func place(_ panel: NSPanel) {
        if panel.setFrameUsingName(Self.frameName), NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrame(CGRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 8, width: size.width, height: size.height), display: true)
    }
}

/// The meeting companion: the recording's state and time, and the commands used during a call, one click each. It reads the
/// recording as the menu-bar panel does, so the two always agree.
struct CompanionBar: View {
    @Bindable var model: RecorderModel
    var close: () -> Void
    var onSize: (CGSize) -> Void = { _ in }

    static var title: String {
        String(localized: "Meeting Companion", comment: "Name of the small floating bar with the recording’s time and controls, shown beside the meeting app while recording (window title read by VoiceOver)")
    }

    var body: some View {
        HStack(spacing: 10) {
            // Not by colour alone: the glyph changes with the state, and VoiceOver reads it. The bar is dragged from here.
            HStack(spacing: 5) {
                Image(systemName: model.isPaused ? "pause.circle.fill" : "record.circle.fill")
                    .foregroundStyle(model.isPaused ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                Text(verbatim: model.elapsed).monospacedDigit()
            }
            .gesture(WindowDragGesture())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.isPaused ? Text("Paused") : Text("Recording"))
            .accessibilityValue(Text(verbatim: ElapsedTime.spoken(model.elapsedSeconds)))
            Divider().frame(height: 16)
            CompanionButton("Mark a Moment", symbol: "bookmark.fill", tint: .orange) { model.markMoment() }
            CompanionButton("Open Notepad", symbol: "square.and.pencil") { model.openNotepad() }
            CompanionButton(model.isPaused ? "Resume Recording" : "Pause Recording", symbol: model.isPaused ? "play.fill" : "pause.fill") {
                model.togglePause()
            }
            .disabled(!model.canTogglePause)
            CompanionButton("Stop Recording", symbol: "stop.fill") { model.stop() }
            Divider().frame(height: 16)
            CompanionButton("Close", symbol: "xmark") { close() }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .fixedSize()
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { onSize($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: Self.title))
    }
}

/// A command of the bar: its glyph, with its name in the tooltip and for VoiceOver, and a target of at least 20 × 20 points.
private struct CompanionButton: View {
    let title: LocalizedStringKey
    let symbol: String
    var tint: Color?
    let action: () -> Void

    init(_ title: LocalizedStringKey, symbol: String, tint: Color? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                .frame(minWidth: 20, minHeight: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(Text(title))
        .accessibilityLabel(Text(title))
    }
}
