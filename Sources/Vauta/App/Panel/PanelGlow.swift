// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import SwiftUI

/// The soft light behind the top of the panel: Vauta's indigo and teal at rest, red and magenta while recording.
/// Faint in light appearance, where colour on the material would look like a stain; gone with Increase Contrast.
struct PanelGlow: View {
    let isRecording: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var systemContrast
    private var contrast: ColorSchemeContrast { systemContrast.snapshotResolved }

    var body: some View {
        let strength = colorScheme == .dark ? 0.3 : 0.12
        let (left, right) = isRecording ? (Brand.red, Brand.magenta) : (Brand.indigo, Brand.teal)
        GeometryReader { geo in
            ZStack {
                RadialGradient(colors: [left.opacity(strength), left.opacity(0)], center: UnitPoint(x: 0.2, y: 0.3),
                               startRadius: 0, endRadius: geo.size.width * 0.6)
                RadialGradient(colors: [right.opacity(strength * 0.8), right.opacity(0)], center: UnitPoint(x: 0.85, y: 0.75),
                               startRadius: 0, endRadius: geo.size.width * 0.55)
            }
        }
        // Fades out towards the bottom, so the light never ends on a straight edge under the meters.
        .mask { LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.45), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom) }
        .opacity(contrast == .increased ? 0 : 1)
        .animation(.easeInOut(duration: 0.6), value: isRecording)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
