// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import SwiftUI

extension View {
    /// A button whose title may take a second line instead of being cut ("Einstellungen „Anmeldeobjekte & Erweiterungen“ öffnen"):
    /// the "Open <Pane> Settings" buttons keep one pattern per language, so the longest ones wrap rather than get reworded.
    func wrapsToTwoLines() -> some View {
        lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A bordered button whose title wraps. A native macOS push button is a single-line control, so `lineLimit(2)` on it only
/// truncates; this style draws the same shape around a title that may take several lines.
struct WrappingButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let small = controlSize == .small || controlSize == .mini
        configuration.label
            .font(.system(size: small ? 11 : 13))
            .multilineTextAlignment(.leading)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, small ? 8 : 10)
            .padding(.vertical, small ? 3 : 4)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.primary.opacity(prominent ? 0 : 0.18), lineWidth: 0.5)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.5)
            .contentShape(Rectangle())
    }
}

/// The normal button when its title fits the width it is given, a button that wraps when it does not (de "Einstellungen
/// „Anmeldeobjekte & Erweiterungen“ öffnen"): the title is never cut and short titles keep the native look.
struct FittingButton: View {
    let title: Text
    var prominent = false
    let action: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Button(action: action) { title }.prominentButton(prominent).lineLimit(1)
            Button(action: action) { title }.buttonStyle(WrappingButtonStyle(prominent: prominent))
        }
    }
}
