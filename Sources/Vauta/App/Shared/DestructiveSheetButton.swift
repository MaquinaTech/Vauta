// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import SwiftUI

extension View {
    /// The irreversible action of a confirmation sheet. It looks like the destructive button of an alert:
    /// a red label on a light red fill. The label is a red that keeps at least 4.5:1 against the fill
    /// (darker in light appearance, lighter in dark), and Increase Contrast adds an outline.
    /// Disabled, it keeps the system's plain disabled look.
    func destructiveSheetButton() -> some View {
        buttonStyle(DestructiveSheetButtonStyle())
    }
}

private struct DestructiveSheetButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var systemContrast
    private var contrast: ColorSchemeContrast { systemContrast.snapshotResolved }

    func makeBody(configuration: Configuration) -> some View {
        let dark = scheme == .dark
        let label = dark ? Color(red: 1.0, green: 0.55, blue: 0.51) : Color(red: 0.77, green: 0.10, blue: 0.09)
        let fill = Color(nsColor: .systemRed).opacity(dark ? 0.25 : 0.14)
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return configuration.label
            .padding(.horizontal, 10)
            .frame(minHeight: 22)
            .foregroundStyle(isEnabled ? AnyShapeStyle(label) : AnyShapeStyle(.secondary))
            .background(shape.fill(isEnabled ? fill : Color.secondary.opacity(0.12)))
            .overlay(shape.strokeBorder(label.opacity(contrast == .increased && isEnabled ? 0.9 : 0), lineWidth: 1))
            .overlay(shape.fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0)))
            .contentShape(shape)
    }
}
