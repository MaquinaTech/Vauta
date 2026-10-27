// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

// MARK: Pieces

/// One choice in the popover: a plain button with a hover fill, like a menu item that stays open.
struct PopoverRow: View {
    let title: Text
    var subtitle: String?
    var symbol: String?
    var detail: Text?
    var tint: Color?
    var drills = false
    var checked = false
    let action: () -> Void
    @ViewLocalState private var hovering = false

    init(title: Text, subtitle: String? = nil, symbol: String? = nil, detail: Text? = nil, tint: Color? = nil,
         drills: Bool = false, checked: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.detail = detail
        self.tint = tint
        self.drills = drills
        self.checked = checked
        self.action = action
    }

    /// A row whose title is text that is already localized (a name).
    init(verbatim title: String, subtitle: String? = nil, symbol: String? = nil, tint: Color? = nil, drills: Bool = false, checked: Bool = false, action: @escaping () -> Void) {
        self.title = Text(verbatim: title)
        self.subtitle = subtitle
        self.symbol = symbol
        self.detail = nil
        self.tint = tint
        self.drills = drills
        self.checked = checked
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    title.foregroundStyle(tint ?? Color.primary).fixedSize(horizontal: false, vertical: true)
                    if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
                    if let detail { detail.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 0)
                if checked { Image(systemName: "checkmark").accessibilityHidden(true) }
                if drills { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityHidden(true) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

/// The way back to the popover's first page, with the page's title.
struct BackBar: View {
    let title: Text
    let back: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: back) { Label("Back", systemImage: "chevron.left").labelStyle(.iconOnly) }
                .buttonStyle(.borderless)
                .help("Back")
                .keyboardShortcut(.cancelAction)
            title.font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct SectionLabel: View {
    let title: Text

    var body: some View {
        title
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}
