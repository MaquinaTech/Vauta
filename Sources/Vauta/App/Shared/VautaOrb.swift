// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import SwiftUI

/// Vauta's core, as on the website: a lit sphere with colours drifting inside it, and a ring of particles in orbit
/// around it. At rest it turns slowly; while listening it turns red into magenta, the orbit speeds up and two soft rings
/// ripple with the loudest channel; while working (starting, saving) the orbit spins faster and the colours dim.
/// With Reduce Motion, and in renders, it is one still frame. Purely decorative: the view that holds it gives it a name.
struct VautaOrb: View {
    enum Mode: Equatable {
        case idle, listening, working
        /// A quieter disc: another call to action is on screen. No orbit, no glow.
        case muted
        /// The fix comes first (a permission, the store): an opaque grey disc, nothing moves.
        case blocked(Color)
    }

    let mode: Mode
    let diameter: CGFloat
    /// The loudest channel now, from 0 to 1 (only used while listening).
    var level: Double = 0
    var outlined = false
    /// Draws the particle orbit (off where the orb is small or the room is tight).
    var showsOrbit = true
    /// A glyph sits on the sphere: its centre is a little darker so white reads on it.
    var carriesGlyph = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var systemContrast
    private var contrast: ColorSchemeContrast { systemContrast.snapshotResolved }
    @ViewLocalState private var appeared = false

    private var still: Bool {
        if reduceMotion || Brand.freezesMotion { return true }
        if case .blocked = mode { return true }
        return false
    }

    var body: some View {
        ZStack {
            Color.clear.frame(width: diameter, height: diameter)
            TimelineView(.animation(minimumInterval: frameInterval, paused: still)) { context in
                // A fixed moment when still, so the frame is always the same one.
                let time = still ? 2.6 : context.date.timeIntervalSinceReferenceDate
                Canvas { canvas, size in
                    draw(in: &canvas, size: size, time: time)
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
            }
            .allowsHitTesting(false)
            // A new state fades in over the old one (the colours can't be interpolated inside the canvas).
            .id(modeKey)
            .transition(.opacity)
        }
        .frame(width: diameter, height: diameter)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: modeKey)
        // It comes in with a slight grow and fade when it appears (the panel opening, a page of Setup).
        .scaleEffect(appeared ? 1 : 0.86)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            guard !appeared else { return }
            if still { appeared = true; return }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) { appeared = true }
        }
        .accessibilityHidden(true)
    }

    private var modeKey: String {
        switch mode {
        case .idle: "idle"
        case .listening: "listening"
        case .working: "working"
        case .muted: "muted"
        case .blocked: "blocked"
        }
    }

    /// Smooth while listening or working; slower at rest and when quiet, where the motion is slow anyway, to save energy.
    private var frameInterval: Double {
        switch mode {
        case .listening, .working: 1 / 60
        case .idle: 1 / 30
        default: 1 / 15
        }
    }

    /// The canvas reaches past the sphere for the orbit and the corona; the layout is only the sphere.
    private var canvasSize: CGSize { CGSize(width: diameter * 2.4, height: diameter * 2.4) }

    // MARK: Colours

    private var palette: (base: [Color], aurora: [Color], glow: Color) {
        switch mode {
        case .listening:
            return ([Brand.rose, Brand.red, Brand.magenta], [Brand.pink, Brand.amber, Brand.violet], Brand.red)
        case .blocked(let grey):
            return ([grey, grey], [], .clear)
        default:
            return ([Brand.indigo, Brand.blue, Brand.teal], [Brand.cyan, Brand.pink, Brand.violet], Brand.blue)
        }
    }

    private var orbitColors: (left: Color, right: Color) {
        mode == .listening ? (Brand.amber, Brand.pink) : (Brand.pink, Brand.cyan)
    }

    // MARK: Drawing

    private func draw(in canvas: inout GraphicsContext, size: CGSize, time: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = diameter / 2
        let isBlocked = { if case .blocked = mode { true } else { false } }()
        let isQuiet = mode == .muted || isBlocked
        // A quieter sphere keeps a faint orbit, so the button looks the same kind of thing whatever sits above it.
        let orbit = showsOrbit && !isBlocked

        // No halo with Increase Contrast, like the panel's glow.
        if !isQuiet && contrast != .increased { drawGlow(in: &canvas, center: center, radius: radius) }
        if orbit { drawOrbit(in: &canvas, center: center, radius: radius, time: time, front: false) }
        if mode == .listening { drawCorona(in: &canvas, center: center, radius: radius, time: time) }
        drawSphere(in: &canvas, center: center, radius: radius, time: time)
        if orbit { drawOrbit(in: &canvas, center: center, radius: radius, time: time, front: true) }
    }

    private func drawGlow(in canvas: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        let strength = (colorScheme == .dark ? 0.45 : 0.22) + (colorScheme == .dark ? 0.3 : 0.15) * level
        let reach = radius * (1.75 + 0.35 * level)
        let rect = CGRect(x: center.x - reach, y: center.y - reach, width: reach * 2, height: reach * 2)
        canvas.fill(Path(ellipseIn: rect), with: .radialGradient(
            Gradient(colors: [palette.glow.opacity(strength), palette.glow.opacity(0)]),
            center: center, startRadius: radius * 0.6, endRadius: reach))
    }

    private func drawSphere(in canvas: inout GraphicsContext, center: CGPoint, radius: CGFloat, time: Double) {
        let disc = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let circle = Path(ellipseIn: disc)
        let colors = palette
        var sphere = canvas
        sphere.clip(to: circle)
        sphere.fill(circle, with: .linearGradient(Gradient(colors: colors.base),
                                                  startPoint: CGPoint(x: disc.minX, y: disc.minY),
                                                  endPoint: CGPoint(x: disc.maxX, y: disc.maxY)))
        // Colours drifting inside, blurred into one another.
        if !colors.aurora.isEmpty {
            let dim = mode == .working ? 0.45 : mode == .muted ? 0.55 : 0.8
            sphere.drawLayer { layer in
                layer.addFilter(.blur(radius: radius * 0.42))
                for (index, color) in colors.aurora.enumerated() {
                    let phase = time * (0.23 + 0.07 * Double(index)) + Double(index) * 2.1
                    let x = center.x + radius * 0.55 * CGFloat(cos(phase))
                    let y = center.y + radius * 0.5 * CGFloat(sin(phase * 1.3 + Double(index)))
                    let blob = radius * (0.62 + 0.08 * CGFloat(sin(phase * 0.7)))
                    layer.fill(Path(ellipseIn: CGRect(x: x - blob, y: y - blob, width: blob * 2, height: blob * 2)),
                               with: .color(color.opacity(dim)))
                }
            }
        }
        // Light from the top left, shade towards the rim, a darker centre so the white glyph reads.
        let light = CGPoint(x: center.x - radius * 0.38, y: center.y - radius * 0.46)
        sphere.fill(circle, with: .radialGradient(Gradient(colors: [.white.opacity(0.5), .white.opacity(0)]),
                                                  center: light, startRadius: 0, endRadius: radius * 0.85))
        sphere.fill(circle, with: .radialGradient(Gradient(colors: [.black.opacity(0), .black.opacity(0.32)]),
                                                  center: CGPoint(x: center.x, y: center.y - radius * 0.15),
                                                  startRadius: radius * 0.55, endRadius: radius * 1.15))
        if carriesGlyph {
            // Measured over the glyph's box through a whole cycle: white on it keeps at least 3:1.
            sphere.fill(circle, with: .radialGradient(Gradient(colors: [.black.opacity(0.5), .black.opacity(0.38), .black.opacity(0)]),
                                                      center: center, startRadius: 0, endRadius: radius * 0.72))
        }
        // A thin rim of light.
        canvas.stroke(Path(ellipseIn: disc.insetBy(dx: 0.5, dy: 0.5)), with: .color(.white.opacity(0.32)), lineWidth: 1)
        if outlined {
            canvas.stroke(Path(ellipseIn: disc.insetBy(dx: 0.5, dy: 0.5)), with: .color(.primary), lineWidth: 1)
        }
    }

    /// A tilted ring of particles. Each particle has its own speed, size and distance, so the ring reads as dust in
    /// orbit, not a line. The half behind the sphere is drawn first and dimmer.
    private func drawOrbit(in canvas: inout GraphicsContext, center: CGPoint, radius: CGFloat, time: Double, front: Bool) {
        let count = diameter >= 100 ? 320 : 200
        let speed = mode == .listening ? 0.42 : mode == .working ? 0.9 : 0.16
        let tilt = -0.3
        let (left, right) = orbitColors
        let scale = max(1, diameter / 90)
        func place(_ angle: Double, _ spread: Double) -> CGPoint {
            let x = cos(angle) * Double(radius) * 1.9 * spread
            let y = sin(angle) * Double(radius) * 0.46 * spread
            return CGPoint(x: center.x + CGFloat(x * cos(tilt) - y * sin(tilt)), y: center.y + CGFloat(x * sin(tilt) + y * cos(tilt)))
        }
        // A faint line under the dust, so the orbit reads as one ring.
        var line = Path()
        let steps = 90
        for step in 0...steps {
            let angle = (front ? 0 : Double.pi) + Double(step) / Double(steps) * .pi
            let point = place(angle, 1)
            if step == 0 { line.move(to: point) } else { line.addLine(to: point) }
        }
        canvas.stroke(line, with: .linearGradient(Gradient(colors: [left.opacity(front ? 0.35 : 0.12), right.opacity(front ? 0.35 : 0.12)]),
                                                  startPoint: place(.pi, 1), endPoint: place(0, 1)),
                      lineWidth: 0.6 * scale)
        for index in 0..<count {
            let seed = Double(index)
            let jitter = Self.noise(seed * 12.9898)
            let angle = seed / Double(count) * 2 * .pi + jitter * 0.2 + time * speed * (0.85 + 0.3 * Self.noise(seed * 3.7))
            let depth = sin(angle)
            if (depth > 0) != front { continue }
            // Most particles hug the line; a few stray further, as dust does.
            let offset = Self.noise(seed * 7.13) - 0.5
            let spread = 1 + 0.1 * offset * abs(offset) * 4
            let point = place(angle, spread)
            let twinkle = 0.6 + 0.4 * sin(time * (1.3 + jitter * 1.4) + seed)
            let near = (depth + 1) / 2
            let size = CGFloat(0.5 + 1.2 * pow(Self.noise(seed * 5.31), 2)) * CGFloat(0.8 + 0.4 * near) * scale
            let opacity = (front ? 0.5 + 0.5 * near : 0.15 + 0.25 * near) * twinkle * (mode == .muted ? 0.5 : 1)
            let mix = (cos(angle) + 1) / 2
            canvas.fill(Path(ellipseIn: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)),
                        with: .color((mix > 0.5 ? right : left).opacity(opacity)))
        }
    }

    /// Two soft rings that ripple with the voice, just outside the sphere.
    private func drawCorona(in canvas: inout GraphicsContext, center: CGPoint, radius: CGFloat, time: Double) {
        let rings: [(color: Color, lobes: Double, speed: Double, offset: CGFloat)] = [(Brand.pink, 5, 2.4, 1.13), (Brand.amber, 3, -1.7, 1.2)]
        for ring in rings {
            var path = Path()
            let steps = 120
            for step in 0...steps {
                let angle = Double(step) / Double(steps) * 2 * .pi
                let ripple = sin(ring.lobes * angle + time * ring.speed) * sin((ring.lobes - 2) * angle - time * ring.speed * 0.6)
                let distance = radius * (ring.offset + CGFloat((0.025 + 0.11 * level) * ripple))
                let point = CGPoint(x: center.x + CGFloat(cos(angle)) * distance, y: center.y + CGFloat(sin(angle)) * distance)
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
            var glow = canvas
            glow.addFilter(.blur(radius: max(2, diameter / 28)))
            // Calmer on a light background, where the same pink reads as neon.
            let calm = colorScheme == .dark ? 1.0 : 0.6
            glow.stroke(path, with: .color(ring.color.opacity((0.3 + 0.35 * level) * calm)), lineWidth: max(1.5, diameter / 36))
            canvas.stroke(path, with: .color(ring.color.opacity((0.45 + 0.3 * level) * calm)), lineWidth: max(0.7, diameter / 110))
        }
    }

    /// A fixed pseudo-random number from 0 to 1, so every particle keeps its own character from frame to frame.
    private static func noise(_ value: Double) -> Double {
        let x = sin(value) * 43_758.5453
        return x - x.rounded(.down)
    }
}

/// Vauta at work, in the size of a small spinner: the sphere with its colours turning faster, no orbit.
struct ThinkingOrb: View {
    var diameter: CGFloat = 16

    var body: some View {
        VautaOrb(mode: .working, diameter: diameter, showsOrbit: false, carriesGlyph: false)
            .frame(width: diameter, height: diameter)
    }
}
