// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import SwiftUI

/// A short label in a capsule beside a title: "Quick start · Basic quality", "Better minutes".
/// One rendering everywhere, so the same badge never reads as two different things.
struct BadgeCapsule: View {
    /// A fact (the quality of Apple's model) is neutral; advice (better minutes) is in the accent colour.
    enum Style { case neutral, recommended }

    /// `compact` is for a row of caption-sized text (the panel's status line): the same fill and shape, one size smaller. The regular size is subheadline (11 pt, scales with text size): the badge carries content (the quality label).
    enum Size { case regular, compact }

    let text: String
    var style: Style = .neutral
    var size: Size = .regular
    @Environment(\.colorSchemeContrast) private var systemContrast
    private var contrast: ColorSchemeContrast { systemContrast.snapshotResolved }
    @Environment(\.colorScheme) private var scheme

    init(_ text: String, style: Style = .neutral, size: Size = .regular) {
        self.text = text
        self.style = style
        self.size = size
    }

    var body: some View {
        let recommended = style == .recommended
        Text(text)
            .font((size == .compact ? Font.caption2 : Font.subheadline).weight(.medium))
            .foregroundStyle(recommended ? AnyShapeStyle(recommendedText) : AnyShapeStyle(Color.primary.opacity(contrast == .increased ? 1 : 0.75)))
            .padding(.horizontal, size == .compact ? 6 : 8)
            .padding(.vertical, size == .compact ? 1 : 2)
            .background(Capsule().fill(recommended ? Color.accentColor.opacity(scheme == .dark ? 0.22 : 0.14) : Color.primary.opacity(0.08)))
            .fixedSize()
    }

    /// The accent colour, pushed toward black (light) or white (dark) so small text keeps at least 4.5:1 on its capsule;
    /// with Increase Contrast it is the plain primary colour.
    private var recommendedText: Color {
        if contrast == .increased { return .primary }
        let accent = NSColor.controlAccentColor
        let mixed = accent.blended(withFraction: scheme == .dark ? 0.45 : 0.3, of: scheme == .dark ? .white : .black) ?? accent
        return Color(nsColor: mixed)
    }
}
