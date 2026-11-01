// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import SwiftUI

/// A bordered pop-up (a filled button with the chevron inside, like the task editor's Owner and Status and the
/// list-header pop-ups), also inside a grouped form, whose own picker and menu styles draw a borderless menu with a
/// separate chevron capsule. A bordered button keeps its bezel there, and opens the same native menu.
struct ContextPopUp<Value: Hashable>: View {
    struct Item {
        let title: String
        let symbol: String?
        let value: Value
        init(_ title: String, symbol: String? = nil, value: Value) {
            self.title = title; self.symbol = symbol; self.value = value
        }
    }

    let label: String
    @Binding var selection: Value
    let items: [Item]
    /// Above the item at an index: a line, or the title of the group it starts.
    var breaks: [Int: MenuBreak] = [:]
    /// The button takes the whole width it is given; otherwise it is as wide as its longest item.
    var fillsWidth = false
    /// A cap for a pop-up whose longest item could be very long (a task name): it shrinks, truncating its title,
    /// instead of widening the form beyond its column.
    var maxWidth: CGFloat?
    /// With a cap: the width the pop-up asks for when it has room to spare (a layout that picks by what fits sees this,
    /// not the longest item), so it can shrink to the room left.
    var idealWidth: CGFloat?
    @ViewLocalState private var anchor = MenuAnchor()

    private var current: Item? { items.first { $0.value == selection } }

    var body: some View {
        Button {
            anchor.open(items: items.map { ($0.title, $0.symbol) }, selected: items.firstIndex { $0.value == selection }, breaks: breaks) { index in
                if items.indices.contains(index) { selection = items[index].value }
            }
        } label: {
            HStack(spacing: 6) {
                if let symbol = current?.symbol { Image(systemName: symbol) }
                if maxWidth != nil {
                    // A capped pop-up shrinks with the room it is given: its title truncates, and the bezel keeps its
                    // padding (a label wider than the button would make AppKit squeeze it).
                    Text(current?.title ?? "").lineLimit(1).truncationMode(.tail)
                } else {
                    // The widest title sets the width, so the button doesn't change size with its selection.
                    ZStack(alignment: .leading) {
                        ForEach(items.indices, id: \.self) { Text(items[$0].title).lineLimit(1).hidden() }
                        Text(current?.title ?? "").lineLimit(1).truncationMode(.tail)
                    }
                }
                if fillsWidth || maxWidth != nil { Spacer(minLength: 0) }
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: fillsWidth || maxWidth != nil ? .infinity : nil, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .background(MenuAnchorView(anchor: anchor))
        .modifier(PopUpWidth(fillsWidth: fillsWidth, maxWidth: maxWidth, idealWidth: idealWidth))
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(current?.title ?? ""))
        .accessibilityAddTraits(.isButton)
    }
}

private struct PopUpWidth: ViewModifier {
    let fillsWidth: Bool
    let maxWidth: CGFloat?
    let idealWidth: CGFloat?

    func body(content: Content) -> some View {
        if fillsWidth {
            content.frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)
        } else if let maxWidth {
            content.frame(minWidth: 110, idealWidth: idealWidth, maxWidth: maxWidth, alignment: .leading)
        } else {
            content.fixedSize()
        }
    }
}

/// What separates the groups of a pop-up's menu.
enum MenuBreak: Hashable {
    case line
    case title(String)
}

/// Finds the button's view, so the menu opens right over it like a pop-up button's.
final class MenuAnchor {
    weak var view: NSView?
    private var handler: MenuHandler?

    @MainActor
    func open(items: [(String, String?)], selected: Int?, breaks: [Int: MenuBreak] = [:], choose: @escaping (Int) -> Void) {
        guard let view else { return }
        let handler = MenuHandler(choose: choose)
        self.handler = handler
        let menu = NSMenu()
        for (index, item) in items.enumerated() {
            switch breaks[index] {
            case .line?: menu.addItem(.separator())
            case .title(let title)?: menu.addItem(.sectionHeader(title: title))
            case nil: break
            }
            let entry = NSMenuItem(title: item.0, action: #selector(MenuHandler.picked(_:)), keyEquivalent: "")
            entry.target = handler
            entry.tag = index
            if let symbol = item.1 { entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            entry.state = index == selected ? .on : .off
            menu.addItem(entry)
        }
        menu.minimumWidth = view.bounds.width
        let origin = NSPoint(x: 0, y: view.isFlipped ? view.bounds.height + 4 : -4)
        menu.popUp(positioning: nil, at: origin, in: view)
    }
}

private final class MenuHandler: NSObject {
    let choose: (Int) -> Void
    init(choose: @escaping (Int) -> Void) { self.choose = choose }
    @objc func picked(_ sender: NSMenuItem) { choose(sender.tag) }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}
