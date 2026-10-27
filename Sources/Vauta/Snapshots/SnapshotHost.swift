// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import AppKit
import SwiftUI

/// Renders a SwiftUI view to PNG data inside an offscreen AppKit window, so
/// list, form and text controls (which `ImageRenderer` cannot draw) look as
/// they do on screen. The window is never shown.
/// A window that always reports being the key window, so controls draw their
/// active state (accent colors, selection) although nothing is on screen.
private final class ActiveWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    // Tall scenes (a whole Settings pane) must not be cut to the height of this Mac's screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// An application that reports being frontmost, so AppKit draws the active
/// state of controls although nothing is on screen.
final class ActiveApplication: NSApplication {
    override var isActive: Bool { true }
}

@MainActor
enum SnapshotHost {
    enum Chrome {
        /// A titled window (Settings, Meetings, Welcome).
        case window(title: String)
        /// The menu-bar panel: no title bar, rounded corners.
        case panel
        /// A sheet: a rounded card.
        case sheet
        /// A floating panel that draws its own shape (the captions): captured as is.
        case floating
    }

    struct Options {
        var dark: Bool
        var scale: CGFloat
        /// Where `@AppStorage` reads and writes: the fixture's own suite, so renders running
        /// side by side (one process per language) never see each other's values.
        var defaults: UserDefaults
    }

    /// How long a scene waits before it is captured. A scene is ready when `ready` holds and
    /// its pixels stop changing; a view that never stops (an animation) is captured after `animated`.
    private enum Settle {
        static let first = Duration.milliseconds(env("VAUTA_SETTLE_FIRST_MS", 200))
        static let poll = Duration.milliseconds(env("VAUTA_SETTLE_POLL_MS", 50))
        static let stableFrames = env("VAUTA_SETTLE_STABLE", 6)
        static let animated = Duration.milliseconds(env("VAUTA_SETTLE_ANIMATED_MS", 1500))
        static let deadline = Duration.seconds(20)

        private static func env(_ name: String, _ fallback: Int) -> Int {
            ProcessInfo.processInfo.environment[name].flatMap(Int.init) ?? fallback
        }
    }

    /// The first window of a process is not yet treated as the key window: open and close
    /// a throwaway one so the images drawn next already show the active state.
    static func warmUp() async {
        let window = ActiveWindow(contentRect: NSRect(x: 40, y: 40, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        window.makeKey()
        try? await Task.sleep(for: .milliseconds(800))
        window.orderOut(nil)
    }

    /// Renders `view`. `size` is the content size; nil fits the view's height at `width`.
    /// What the last render's layout check found wrong, if anything (see `SnapshotScene.Prepared.verify`).
    @MainActor static var lastLayoutProblem: String?

    static func render(_ view: AnyView, size: CGSize, fitHeight: Bool = false, fitWidth: Bool = false, chrome: Chrome, options: Options,
                       ready: @MainActor () -> Bool = { true }, after: (@MainActor () async -> Void)? = nil,
                       verify: (@MainActor () -> String?)? = nil) async -> Data? {
        let appearance = NSAppearance(named: SnapshotMode.highContrast ? (options.dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
                                                                      : (options.dark ? .darkAqua : .aqua))
        let dark = options.dark
        defer { SnapshotMode.highContrast = false; SnapshotMode.reduceTransparency = false }
        NSApp.appearance = appearance
        let controller = NSHostingController(rootView: AnyView(view
            .environment(\.colorScheme, options.dark ? .dark : .light)
            .environment(\.controlActiveState, .key)
            .defaultAppStorage(options.defaults)))
        let window = ActiveWindow(contentViewController: controller)
        switch chrome {
        case .window(let title):
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.title = title
        case .panel, .sheet, .floating:
            window.styleMask = [.borderless]
        }
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        // Visible to AppKit (so SwiftUI runs onAppear and tasks) but fully transparent on screen.
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        // Never activate the app: a render runs for an hour while the Mac is in use, and
        // activating would take the keyboard focus from the frontmost app on every scene.
        // ActiveApplication and ActiveWindow already make controls draw their active state.
        window.orderFrontRegardless()
        window.makeKey()
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: Settle.first)
        if let after {
            // Let the window's own loading finish first, then apply the state on top.
            await settle(window, ready: { true })
            await after()
        }
        // Let the view model tasks (.task) run and the layout settle.
        await settle(window, ready: ready)
        if fitHeight || fitWidth {
            let fitting = controller.view.fittingSize
            window.setContentSize(NSSize(width: fitWidth ? ceil(fitting.width) : size.width, height: fitHeight ? ceil(fitting.height) : size.height))
            await settle(window, ready: ready)
        }
        // A layout problem does not stop the render (the image is how it is looked at): it is listed and fails the command at the end.
        lastLayoutProblem = verify?()
        var sidebars: [NSRect] = [], selections: [NSRect] = []
        if case .window(let title) = chrome, dark, let root = window.contentView?.superview {
            // Offscreen, a plain title bar draws its title in the inactive grey in dark mode (the window is key, as in
            // the light pass and as on screen): give it the active colour, as the Meetings toolbar title already has.
            activateTitle(title, in: root)
        }
        if let root = window.contentView?.superview {
            paintSelections(in: root, root: root, into: &selections)
            if dark { collectSidebars(in: root, root: root, into: &sidebars) }
        }
        return capture(window, chrome: chrome, scale: options.scale, dark: options.dark, sidebars: sidebars, selections: selections)
    }


    /// Renders a system alert or confirmation dialog with AppKit's own `NSAlert`, so its metrics, icon and
    /// buttons are the real ones (a SwiftUI `.alert` or `.confirmationDialog` is an `NSAlert` underneath).
    static func renderAlert(_ spec: SnapshotAlert, options: Options) async -> Data? {
        let appearance = NSAppearance(named: options.dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        let alert = NSAlert()
        alert.alertStyle = spec.warning ? .warning : .informational
        // The icon redrawn on a transparent bitmap: drawn live, its view shows a grey plate behind it offscreen.
        let icon = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            if let name = spec.symbol,
               let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 44, weight: .light)) {
                let tinted = symbol.copy() as? NSImage ?? symbol
                tinted.lockFocus()
                NSColor.systemRed.set()
                NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
                tinted.unlockFocus()
                tinted.draw(in: NSRect(x: (rect.width - tinted.size.width) / 2, y: (rect.height - tinted.size.height) / 2, width: tinted.size.width, height: tinted.size.height))
            } else {
                (NSApp.applicationIconImage ?? NSImage()).draw(in: rect)
            }
            return true
        }
        alert.icon = icon
        alert.messageText = spec.title
        alert.informativeText = SheetFootnote.keepingLastWordsTogether(spec.message)
        for button in spec.buttons {
            let added = alert.addButton(withTitle: button.title)
            added.hasDestructiveAction = button.destructive
        }
        alert.layout()
        // Offscreen the default button draws as in a window that is not the key one (pale); give it the fill it has on screen.
        for (index, button) in alert.buttons.enumerated() {
            button.keyEquivalent = index == spec.defaultIndex ? "\r" : ""
        }
        if alert.buttons.indices.contains(spec.defaultIndex) {
            let chosen = alert.buttons[spec.defaultIndex]
            chosen.bezelColor = spec.buttons[spec.defaultIndex].destructive ? .systemRed : .controlAccentColor
            chosen.attributedTitle = NSAttributedString(string: chosen.title, attributes: [.foregroundColor: NSColor.white, .font: chosen.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        }
        let window = alert.window
        window.appearance = appearance
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        // As for every scene: shown to AppKit without activating the app or taking the keyboard focus.
        window.orderFrontRegardless()
        window.makeKey()
        defer { window.orderOut(nil) }
        await settle(window, ready: { true })
        guard let frame = window.contentView?.superview ?? window.contentView else { return nil }
        let bounds = frame.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * options.scale), pixelsHigh: Int(bounds.height * options.scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        frame.cacheDisplay(in: bounds, to: rep)
        if let iconView = findImageView(in: frame) {
            clearPlate(in: rep, rect: iconView.convert(iconView.bounds, to: frame), flipped: frame.isFlipped, height: bounds.height, scale: options.scale)
        }
        return rounded(rep, radius: 26, dark: options.dark)
    }

    private static func activateTitle(_ title: String, in view: NSView) {
        for child in view.subviews {
            if let field = child as? NSTextField, field.stringValue == title {
                field.textColor = .labelColor
            } else {
                activateTitle(title, in: child)
            }
        }
    }

    private static func findImageView(in view: NSView) -> NSImageView? {
        for child in view.subviews {
            if let image = child as? NSImageView { return image }
            if let found = findImageView(in: child) { return found }
        }
        return nil
    }

    /// Offscreen, the alert's glass leaves a slightly different shade behind the icon. Flood the corners of the icon's
    /// square with the colour next to it (what the window draws on screen), stopping at the icon's own pixels.
    private static func clearPlate(in rep: NSBitmapImageRep, rect: NSRect, flipped: Bool, height: CGFloat, scale: CGFloat) {
        guard let data = rep.bitmapData, rep.bitsPerPixel == 32 else { return }
        let rowBytes = rep.bytesPerRow
        let top = flipped ? rect.minY : height - rect.maxY
        let x0 = max(0, Int(rect.minX * scale)), x1 = min(rep.pixelsWide, Int(rect.maxX * scale))
        let y0 = max(0, Int(top * scale)), y1 = min(rep.pixelsHigh, Int((top + rect.height) * scale))
        guard x1 - x0 > 8, y1 - y0 > 8, x0 > 4 else { return }
        let background = data + ((y0 + y1) / 2) * rowBytes + (x0 / 2) * 4
        let plate = data + y0 * rowBytes + x0 * 4
        let reference = (plate[0], plate[1], plate[2])
        func near(_ p: UnsafeMutablePointer<UInt8>) -> Bool {
            abs(Int(p[0]) - Int(reference.0)) < 5 && abs(Int(p[1]) - Int(reference.1)) < 5 && abs(Int(p[2]) - Int(reference.2)) < 5
        }
        var stack = [(x0, y0), (x1 - 1, y0), (x0, y1 - 1), (x1 - 1, y1 - 1)]
        var seen = Set<Int>()
        while let (x, y) = stack.popLast() {
            guard x >= x0, x < x1, y >= y0, y < y1, seen.insert(y * rep.pixelsWide + x).inserted else { continue }
            let pixel = data + y * rowBytes + x * 4
            guard near(pixel) else { continue }
            pixel[0] = background[0]; pixel[1] = background[1]; pixel[2] = background[2]
            stack.append((x + 1, y)); stack.append((x - 1, y)); stack.append((x, y + 1)); stack.append((x, y - 1))
        }
    }

    /// Waits until `ready` holds and the window's pixels stay the same for a few polls in a row.
    private static func settle(_ window: NSWindow, ready: @MainActor () -> Bool) async {
        let start = ContinuousClock.now
        var readySince: ContinuousClock.Instant?
        var last: Int?
        var stable = 0
        while ContinuousClock.now - start < Settle.deadline {
            try? await Task.sleep(for: Settle.poll)
            window.contentView?.layoutSubtreeIfNeeded()
            guard ready() else { readySince = nil; last = nil; stable = 0; continue }
            let now = ContinuousClock.now
            if readySince == nil { readySince = now }
            let print = fingerprint(window)
            stable = print == last ? stable + 1 : 0
            last = print
            if stable >= Settle.stableFrames { return }
            if let readySince, now - readySince >= Settle.animated { return }
        }
    }

    /// A hash of what the window draws now (at 1x: enough to see any change).
    private static func fingerprint(_ window: NSWindow) -> Int? {
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0, let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.bitmapData else { return nil }
        var hasher = Hasher()
        hasher.combine(bytes: UnsafeRawBufferPointer(start: data, count: rep.bytesPerRow * rep.pixelsHigh))
        hasher.combine(rep.pixelsWide)
        return hasher.finalize()
    }

    /// Selection highlights are `NSVisualEffectView`s that blend with what is behind the
    /// window; drawn offscreen they come out black. Replace each with the solid accent
    /// fill the real window shows.
    private static func paintSelections(in view: NSView, root: NSView, into rects: inout [NSRect]) {
        for child in view.subviews {
            if let effect = child as? NSVisualEffectView, effect.material == .selection, let parent = effect.superview {
                effect.isHidden = true
                let fill = NSView(frame: effect.frame)
                fill.wantsLayer = true
                fill.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
                fill.layer?.cornerRadius = min(effect.frame.height / 2, 10)
                fill.layer?.cornerCurve = .continuous
                parent.addSubview(fill, positioned: .above, relativeTo: effect)
                rects.append(parent.convert(fill.frame, to: root))
            } else if let tabs = child as? NSSegmentedControl, String(describing: type(of: tabs)).contains("TabView") {
                paintTabSelection(tabs)
            } else {
                paintSelections(in: child, root: root, into: &rects)
            }
        }
    }

    /// A tab bar draws its selected tab in a layer the offscreen capture misses (white
    /// text on white), and adding a view to it turns the rest black. Hide it and draw an
    /// equivalent bar next to it: a rounded track, the accent pill and every title.
    private static func paintTabSelection(_ tabs: NSSegmentedControl) {
        let count = tabs.segmentCount
        guard count > 0, tabs.selectedSegment >= 0, let parent = tabs.superview else { return }
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let labels = (0..<count).map { tabs.label(forSegment: $0) ?? "" }
        let widths = labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }
        let padding = max(0, (tabs.bounds.width - widths.reduce(0, +)) / CGFloat(count))
        tabs.isHidden = true
        let bar = NSView(frame: tabs.frame.insetBy(dx: -2.5, dy: -2.5))
        bar.wantsLayer = true
        // Resolve the dynamic colors in the window's appearance (not whichever one is current).
        tabs.effectiveAppearance.performAsCurrentDrawingAppearance {
            bar.layer?.backgroundColor = NSColor.windowBackgroundColor.blended(withFraction: 0.1, of: NSColor.labelColor)?.cgColor
        }
        bar.layer?.cornerRadius = bar.frame.height / 2
        var x: CGFloat = 0
        for index in 0..<count {
            let width = widths[index] + padding
            let selected = index == tabs.selectedSegment
            let cell = NSView(frame: NSRect(x: x + 4.5, y: 4.5, width: width - 4, height: bar.frame.height - 9))
            if selected {
                cell.wantsLayer = true
                cell.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
                cell.layer?.cornerRadius = cell.frame.height / 2
            }
            let title = NSTextField(labelWithString: labels[index])
            title.font = font
            title.textColor = selected ? NSColor.white : NSColor.labelColor
            title.sizeToFit()
            title.frame.origin = NSPoint(x: (cell.frame.width - title.frame.width) / 2, y: (cell.frame.height - title.frame.height) / 2)
            cell.addSubview(title)
            bar.addSubview(cell)
            x += width
        }
        parent.addSubview(bar, positioned: .above, relativeTo: tabs)
    }

    /// The areas of the window drawn through a sidebar's glass (in the frame view's coordinates).
    private static func collectSidebars(in view: NSView, root: NSView, into rects: inout [NSRect]) {
        for child in view.subviews {
            if child is NSGlassEffectView, child.frame.height > 200 {
                rects.append(child.convert(child.bounds, to: root))
            } else {
                collectSidebars(in: child, root: root, into: &rects)
            }
        }
    }

    /// A sidebar draws its text and icons dark and lets vibrancy lighten them against the
    /// window behind; offscreen that step is missing, so in dark mode they come out near
    /// black. Turn every pixel darker than the sidebar's own background into light, in
    /// proportion to how much darker it is (anti-aliased edges stay smooth).
    private enum Sample { case corner, rightEdge }

    private static func lightenDarkContent(in rep: NSBitmapImageRep, rects: [NSRect], flipped: Bool, height: CGFloat, scale: CGFloat, sample mode: Sample, dark: Bool = true) {
        guard let data = rep.bitmapData, rep.bitsPerPixel == 32 else { return }
        let rowBytes = rep.bytesPerRow
        for full in rects {
            let rect = full
            let radius = min(10, full.height / 2) * scale
            let top = flipped ? rect.minY : height - rect.maxY
            let x0 = max(0, Int(rect.minX * scale)), x1 = min(rep.pixelsWide, Int(rect.maxX * scale))
            let y0 = max(0, Int(top * scale)), y1 = min(rep.pixelsHigh, Int((top + rect.height) * scale))
            guard x1 > x0, y1 > y0 else { continue }
            // The background is the colour of the sidebar's empty area (its bottom-right corner).
            let sample = mode == .corner ? data + (y1 - 2) * rowBytes + (x1 - 2) * 4 : data + ((y0 + y1) / 2) * rowBytes + (x1 - 6) * 4
            let background = (Double(sample[0]) + Double(sample[1]) + Double(sample[2])) / 3
            guard background > 4 else { continue }
            for y in y0..<y1 {
                let row = data + y * rowBytes
                for x in x0..<x1 {
                    let pixel = row + x * 4
                    let r = Double(pixel[0]), g = Double(pixel[1]), b = Double(pixel[2])
                    // Inside a selection, stay clear of the rounded corners.
                    if mode == .rightEdge {
                        let dx = Double(min(x - x0, x1 - 1 - x)), dy = Double(min(y - y0, y1 - 1 - y))
                        if dx < radius, dy < radius, ((radius - dx) * (radius - dx) + (radius - dy) * (radius - dy)).squareRoot() > radius { continue }
                    }
                    // Coloured pixels (selection, badges) are left alone.
                    guard mode == .rightEdge || max(r, g, b) - min(r, g, b) < 12 else { continue }
                    let level = (r + g + b) / 3
                    guard level < background - 1 else { continue }
                    // On the light accent fill AppKit draws selected text white (secondary text translucent white), so
                    // even mid-grey text goes most of the way to white.
                    let strength = min(1, (background - level) / (dark ? background : background * 0.5))
                    if mode == .rightEdge {
                        // Towards white, keeping the blend with the selection colour at the edges.
                        pixel[0] = UInt8(r + (255 - r) * strength); pixel[1] = UInt8(g + (255 - g) * strength); pixel[2] = UInt8(b + (255 - b) * strength)
                    } else {
                        let value = UInt8(min(255, background + strength * (236 - background)))
                        pixel[0] = value; pixel[1] = value; pixel[2] = value
                    }
                }
            }
        }
    }

    private static func capture(_ window: NSWindow, chrome: Chrome, scale: CGFloat, dark: Bool, sidebars: [NSRect], selections: [NSRect]) -> Data? {
        let frame: NSView
        switch chrome {
        case .window: frame = window.contentView?.superview ?? window.contentView!
        case .panel, .sheet, .floating: frame = window.contentView!
        }
        let bounds = frame.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        frame.cacheDisplay(in: bounds, to: rep)
        lightenDarkContent(in: rep, rects: sidebars, flipped: frame.isFlipped, height: bounds.height, scale: scale, sample: .corner)
        lightenDarkContent(in: rep, rects: selections, flipped: frame.isFlipped, height: bounds.height, scale: scale, sample: .rightEdge, dark: dark)
        if case .floating = chrome { return rep.representation(using: .png, properties: [:]) }
        guard case .window = chrome else { return rounded(rep, radius: 12, dark: dark) }
        return rounded(rep, radius: 10, dark: dark)
    }

    /// Clips to rounded corners and draws a hairline, like a window or popover.
    private static func rounded(_ rep: NSBitmapImageRep, radius: CGFloat, dark: Bool) -> Data? {
        let size = rep.size
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        NSGraphicsContext.current = context
        let rect = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        path.addClip()
        image.draw(in: rect)
        (dark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.18)).setStroke()
        path.lineWidth = 1
        path.stroke()
        return out.representation(using: .png, properties: [:])
    }
}
#endif
