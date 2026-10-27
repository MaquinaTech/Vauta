// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import SwiftUI

/// The one card look: a quiet fill and a 10 pt radius, in the panel, Ask, Tasks, onboarding,
/// the model guide and Network Activity. Call-to-action cards use a tinted banner instead.
enum CardStyle {
    static let radius: CGFloat = 10
}

/// The card fill, with an edge for Increase Contrast and a outline for a chosen option.
private struct CardBackground: ViewModifier {
    let selected: Bool
    let tint: Color
    @Environment(\.colorSchemeContrast) private var systemContrast
    private var contrast: ColorSchemeContrast { systemContrast.snapshotResolved }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: CardStyle.radius)
        content
            .background(.quinary, in: shape)
            .overlay {
                if selected {
                    shape.strokeBorder(tint.opacity(0.8), lineWidth: 1.5)
                } else if contrast == .increased {
                    shape.strokeBorder(Color.primary.opacity(0.5), lineWidth: 1)
                }
            }
    }
}

/// The tinted fill of a banner, with an outline in the tint for Increase Contrast, like `CardBackground`.
private struct BannerBackground: ViewModifier {
    let tint: Color
    let opacity: Double
    @Environment(\.colorSchemeContrast) private var systemContrast
    private var contrast: ColorSchemeContrast { systemContrast.snapshotResolved }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: CardStyle.radius)
        content
            .background(tint.opacity(opacity), in: shape)
            .overlay {
                if contrast == .increased { shape.strokeBorder(tint.opacity(0.6), lineWidth: 1) }
            }
    }
}

extension View {
    /// The card background. `selected` adds a 1.5 pt outline in `tint` (a chosen option).
    func cardBackground(selected: Bool = false, tint: Color = .accentColor) -> some View {
        modifier(CardBackground(selected: selected, tint: tint))
    }

    /// A tinted card for a call to action or a notice.
    func bannerBackground(_ tint: Color, opacity: Double = 0.12) -> some View {
        modifier(BannerBackground(tint: tint, opacity: opacity))
    }
}
