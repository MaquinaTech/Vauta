// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import SwiftUI

/// An icon-only button that opens a native menu. A SwiftUI `Menu` re-tints its label and dims its own focus ring, so its glyph
/// never matched the plain buttons beside it; this is an ordinary plain button (the glyph is `.secondary`, like theirs,
/// and follows Increase Contrast) that pops the same NSMenu up under itself.
struct GlyphMenuButton: View {
    enum Entry {
        case item(String, checked: Bool, action: () -> Void)
        case separator
    }

    let symbol: String
    // The text-size glyph (AA) is drawn thin and small: a heavier weight and a larger scale match the filled pause bars beside it.
    var font: Font = .callout.weight(.semibold)
    var size: CGFloat = 22
    /// Where the glyph sits in its square: `.trailing` for the last control of a row, so the glyph (not its hit area) meets the edge.
    var alignment: Alignment = .center
    let entries: () -> [Entry]
    @ViewLocalState private var anchor = GlyphMenuAnchor()

    var body: some View {
        Button {
            anchor.open(entries())
        } label: {
            Image(systemName: symbol)
                .font(font)
                .imageScale(.large)
                .foregroundStyle(.secondary)
                .frame(width: size, height: size, alignment: alignment)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A Menu would be announced as a menu button; this plain button says what it does.
        .accessibilityHint(Text("Opens a menu", comment: "VoiceOver hint of an icon button that opens a menu"))
        .background(GlyphMenuAnchorView(anchor: anchor))
    }
}

final class GlyphMenuAnchor {
    weak var view: NSView?
    private var actions: [() -> Void] = []

    @MainActor
    func open(_ entries: [GlyphMenuButton.Entry]) {
        guard let view else { return }
        actions = []
        let menu = NSMenu()
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case let .item(title, checked, action):
                let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
                item.target = self
                item.tag = actions.count
                item.state = checked ? .on : .off
                actions.append(action)
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.height + 4 : -4), in: view)
    }

    @objc private func run(_ sender: NSMenuItem) {
        if actions.indices.contains(sender.tag) { actions[sender.tag]() }
    }
}

private struct GlyphMenuAnchorView: NSViewRepresentable {
    let anchor: GlyphMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}
