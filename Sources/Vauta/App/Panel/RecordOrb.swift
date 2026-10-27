// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import SwiftUI

/// The disc of the record button, drawn as a lit sphere like the website's: Vauta's colours at rest, red into magenta
/// while recording. A thin ring in the same colours sits around it; while recording, rings breathe out from it and the
/// glow follows the loudest channel. With Reduce Motion the rings stay still.
struct RecordOrb: View {
    enum Look { case idle, recording, blocked(Color) }

    let look: Look
    let diameter: CGFloat
    /// The loudest channel now, from 0 to 1 (only used while recording).
    var level: Double = 0
    /// Smaller and without glow or rings: another call to action is on screen.
    var isMuted = false
    var outlined = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The rings go on top: under the sphere its glow would hide them (they sit outside the disc, never on it).
        ZStack {
            sphere
            if showsRings { rings }
        }
        .frame(width: diameter, height: diameter)
    }

    private var colors: [Color] {
        switch look {
        case .idle: Brand.idle
        case .recording: Brand.recording
        case .blocked(let grey): [grey, grey]
        }
    }

    private var isRecording: Bool { if case .recording = look { true } else { false } }
    private var isBlocked: Bool { if case .blocked = look { true } else { false } }
    private var showsRings: Bool { !isMuted && !isBlocked }

    private var sphere: some View {
        Circle()
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            // The light from the top left and the shade at the bottom make the disc read as a sphere.
            .overlay {
                Circle().fill(RadialGradient(colors: [.white.opacity(isBlocked ? 0.18 : 0.42), .white.opacity(0)],
                                             center: UnitPoint(x: 0.32, y: 0.24), startRadius: 0, endRadius: diameter * 0.42))
            }
            .overlay {
                Circle().fill(RadialGradient(colors: [.black.opacity(0), .black.opacity(0.22)],
                                             center: UnitPoint(x: 0.5, y: 0.35), startRadius: diameter * 0.3, endRadius: diameter * 0.62))
            }
            .overlay { Circle().strokeBorder(.white.opacity(0.28), lineWidth: 1) }
            .overlay { if outlined { Circle().strokeBorder(Color.primary, lineWidth: 1) } }
            .shadow(color: isMuted || isBlocked ? .clear : (colors[1]).opacity(0.45 + 0.35 * level), radius: 10 + 8 * level, y: 3)
    }

    @ViewBuilder private var rings: some View {
        let ring = Circle().strokeBorder(AngularGradient(colors: colors + [colors[0]], center: .center), lineWidth: 1.5)
        ring
            .frame(width: diameter + 12, height: diameter + 12)
            .opacity(0.7)
        if isRecording {
            if reduceMotion || Brand.freezesMotion {
                ring.frame(width: diameter + 26, height: diameter + 26).opacity(0.25)
            } else {
                TimelineView(.animation) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ForEach(0..<2, id: \.self) { index in
                            let phase = (time / 2.4 + Double(index) / 2).truncatingRemainder(dividingBy: 1)
                            ring
                                .frame(width: diameter + 12, height: diameter + 12)
                                .scaleEffect(1 + 0.32 * phase)
                                .opacity(0.6 * (1 - phase))
                        }
                    }
                }
            }
        }
    }
}

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
        .opacity(contrast == .increased ? 0 : 1)
        .animation(.easeInOut(duration: 0.6), value: isRecording)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
