// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import SwiftUI

/// Secondary text in a sidebar-style list. The list washes `.secondary` out to the primary colour, so an explicit
/// system colour keeps the hierarchy; a selected row (increased prominence, or `isSelected` where the list doesn't
/// report it) takes the primary style, which the selection makes white.
struct SidebarSecondary: ViewModifier {
    var isSelected = false
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        if prominence == .increased {
            // The selection's own text colour, opaque: `.primary` is a hierarchical level that multi-layer symbols
            // (folder, building) draw half transparent on the accent fill.
            content.foregroundStyle(activeState != .inactive ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor)) : AnyShapeStyle(.primary))
        } else if isSelected && activeState != .inactive {
            content.foregroundStyle(Color(nsColor: .alternateSelectedControlTextColor))
        } else {
            content.foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
    }
}

extension View {
    /// See `SidebarSecondary`.
    func sidebarSecondary(isSelected: Bool = false) -> some View { modifier(SidebarSecondary(isSelected: isSelected)) }
}

/// A count with the icon of what it counts, so a bare number never stands alone at the trailing edge.
struct CountBadge: View {
    let symbol: String
    let count: Int
    var isSelected = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).imageScale(.small).accessibilityHidden(true)
            Text(count, format: .number).monospacedDigit()
        }
        .font(.caption)
        .sidebarSecondary(isSelected: isSelected)
    }
}

/// The 20 pt icon column of a list row: secondary, or the selection's text colour on a selected row.
/// A sidebar list washes a hierarchical grey out, so the colour is explicit.
struct RowIcon: View {
    let symbol: String
    var isSelected = false
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.controlActiveState) private var activeState

    private var style: Color {
        // The text of a selected row is white on the selection colour while the window is active.
        if (isSelected || prominence == .increased) && activeState != .inactive { return Color(nsColor: .alternateSelectedControlTextColor) }
        return Color(nsColor: .secondaryLabelColor)
    }

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(prominence == .increased && activeState == .inactive ? AnyShapeStyle(.primary) : AnyShapeStyle(style))
            .frame(width: 20)
            .accessibilityHidden(true)
    }
}

/// The content of a row that lists a person, project or other entry: the same icon (secondary, 20 pt wide), name
/// and mentions count in Meetings › People, Meetings › Tasks › By person and Settings › Context.
struct EntityRowLabel: View {
    let name: String
    let symbol: String
    var aliases: [String] = []
    /// Shown as a count badge when above zero.
    var mentions = 0
    /// A list that doesn't report increased prominence for its selected row (Settings › Context) says it here.
    var isSelected = false

    var body: some View {
        HStack(spacing: 8) {
            RowIcon(symbol: symbol, isSelected: isSelected)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1)
                if !aliases.isEmpty {
                    Text(aliases.formatted(.list(type: .and, width: .narrow)))
                        .font(.caption).sidebarSecondary(isSelected: isSelected).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if mentions > 0 {
                CountBadge(symbol: "text.quote", count: mentions, isSelected: isSelected)
                    .help("Mentions in your meetings")
                    .accessibilityLabel(Text("\(mentions) mentions"))
            }
        }
    }
}
