// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

// Renders the Vauta app icon with Core Graphics. No assets, fonts or Xcode needed.
//
//   swift tools/make-icon.swift <outdir>
//
// Writes <outdir>/AppIcon.iconset/*.png (16–1024 px, @1x and @2x), compiles it with
// iconutil into <outdir>/AppIcon.icns and copies the 1024 px master to
// <outdir>/icon-1024.png. To refresh the committed assets:
//
//   swift tools/make-icon.swift build/icon
//   cp build/icon/AppIcon.icns Resources/AppIcon.icns
//   cp build/icon/icon-1024.png docs/assets/icon-1024.png
//
// Design: the macOS squircle on the standard 1024 grid (824 pt body, 100 pt margin), the
// website's night sky (deep indigo into near black, with indigo and teal glows) and a lit
// sphere in Vauta's indigo → blue → teal gradient carrying a white waveform, with a tilted
// orbit around it, like the record button and the site's rings. Everything is drawn in
// 1024-unit space and scaled, with less detail at the smallest sizes so they stay legible.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: colorSpace,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255,
            CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255,
            alpha,
        ])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(
        colorsSpace: colorSpace, colors: stops.map(\.1) as CFArray,
        locations: stops.map(\.0))!
}

/// A superellipse (|x|^n + |y|^n = 1), which approximates Apple's continuous-corner squircle.
func squircle(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0..<steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * copysign(pow(abs(c), 2 / n), c)
        let y = rect.midY + b * copysign(pow(abs(s), 2 / n), s)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// A rounded vertical bar centred on `cy`.
func bar(x: CGFloat, cy: CGFloat, width: CGFloat, height: CGFloat) -> CGPath {
    CGPath(
        roundedRect: CGRect(x: x, y: cy - height / 2, width: width, height: height),
        cornerWidth: width / 2, cornerHeight: width / 2, transform: nil)
}

/// Fills `path` with Vauta's gradient: indigo → blue → teal, from `start` to `end`.
func fillBrand(_ ctx: CGContext, _ path: CGPath, from start: CGPoint, to end: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(0x8B7DFF)), (0.5, rgb(0x3D8BFF)), (1, rgb(0x2EE6CF))]), start: start, end: end, options: [])
    ctx.restoreGState()
}

/// A tilted orbit around the sphere: a thin ellipse, lavender on the left fading to teal on the right.
func drawOrbit(_ ctx: CGContext, center: CGPoint) {
    let (rx, ry, angle): (CGFloat, CGFloat, CGFloat) = (340, 120, 0.38)
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle)
    ctx.addEllipse(in: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
    ctx.setLineWidth(7)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(0xC9CBFF, 0.85)), (0.5, rgb(0x7A72FF, 0.42)), (1, rgb(0x63F0DD, 0.85))]),
        start: CGPoint(x: -rx, y: 0), end: CGPoint(x: rx, y: 0), options: [])
    ctx.restoreGState()
}

func drawIcon(in ctx: CGContext, pixels: Int) {
    let scale = CGFloat(pixels) / canvas
    ctx.scaleBy(x: scale, y: scale)
    // Shadow offsets and blur are in device pixels (the scale above doesn't apply to them): each one is
    // multiplied by `scale`, or the small sizes get a shadow eight times too wide, cut at the canvas edge.
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let small = pixels <= 32
    let tiny = pixels <= 16

    // Body with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(in: body)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 28 * scale, color: rgb(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x070818))
    ctx.fillPath()
    ctx.restoreGState()

    // The night sky of the website: deep indigo into near black, with an indigo glow at the top left and a teal one
    // at the bottom right.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(0x15123F)), (0.55, rgb(0x0A0B22)), (1, rgb(0x050611))]),
        start: CGPoint(x: 200, y: body.maxY), end: CGPoint(x: body.maxX - 100, y: body.minY), options: [])
    ctx.drawRadialGradient(
        gradient([(0, rgb(0x6C63FF, 0.55)), (1, rgb(0x6C63FF, 0))]),
        startCenter: CGPoint(x: 330, y: 700), startRadius: 0, endCenter: CGPoint(x: 330, y: 700), endRadius: 470, options: [])
    ctx.drawRadialGradient(
        gradient([(0, rgb(0x1FD6C1, 0.38)), (1, rgb(0x1FD6C1, 0))]),
        startCenter: CGPoint(x: 740, y: 300), startRadius: 0, endCenter: CGPoint(x: 740, y: 300), endRadius: 430, options: [])
    ctx.restoreGState()

    // Hairline inner edge.
    if !small {
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.addPath(shape)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.14))
        ctx.setLineWidth(6)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // The sphere: a glow around it, Vauta's gradient, light from the top left and shade towards the edge. Larger at
    // the small sizes, where the orbit is left out.
    let center = CGPoint(x: 512, y: 512)
    let radius: CGFloat = tiny ? 300 : small ? 270 : 230
    let disc = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    let sphere = CGPath(ellipseIn: disc, transform: nil)
    // The back half of the orbit, behind the sphere.
    if !small { drawOrbit(ctx, center: center) }
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 90 * scale, color: rgb(0x5A6BFF, 0.75))
    ctx.addPath(sphere)
    ctx.setFillColor(rgb(0x3D6BF0))
    ctx.fillPath()
    ctx.restoreGState()
    fillBrand(ctx, sphere, from: CGPoint(x: disc.minX, y: disc.maxY), to: CGPoint(x: disc.maxX, y: disc.minY))
    ctx.saveGState()
    ctx.addPath(sphere)
    ctx.clip()
    let light = CGPoint(x: center.x - radius * 0.35, y: center.y + radius * 0.45)
    ctx.drawRadialGradient(
        gradient([(0, rgb(0xFFFFFF, 0.55)), (1, rgb(0xFFFFFF, 0))]),
        startCenter: light, startRadius: 0, endCenter: light, endRadius: radius * 0.9, options: [])
    let shade = CGPoint(x: center.x, y: center.y + radius * 0.2)
    ctx.drawRadialGradient(
        gradient([(0, rgb(0x000000, 0)), (1, rgb(0x050611, 0.45))]),
        startCenter: shade, startRadius: radius * 0.55, endCenter: shade, endRadius: radius * 1.25, options: [])
    ctx.restoreGState()
    // The front half of the orbit passes in front of the sphere.
    if !small {
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: canvas, height: center.y - 10))
        drawOrbit(ctx, center: center)
        ctx.restoreGState()
    }

    // The waveform in white, with a soft glow. Fewer, wider bars at the smallest sizes so the motif survives
    // downsampling.
    let heights: [CGFloat] =
        tiny
        ? [0.5, 1.0, 0.7]
        : small
            ? [0.45, 1.0, 0.7, 0.4]
            : [0.3, 0.62, 1.0, 0.72, 0.9, 0.5, 0.28]
    let barWidth: CGFloat = tiny ? 80 : small ? 52 : 30
    let gap: CGFloat = tiny ? 56 : small ? 32 : 20
    let maxHeight: CGFloat = tiny ? 300 : small ? 270 : 230
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    // Snap the start to the pixel grid so the bars stay crisp at 16 px.
    let waveStartX = ((center.x - total / 2) * scale).rounded() / scale
    let bars = CGMutablePath()
    for (i, h) in heights.enumerated() {
        bars.addPath(
            bar(x: waveStartX + CGFloat(i) * (barWidth + gap), cy: center.y, width: barWidth,
                height: max(barWidth, h * maxHeight)))
    }
    ctx.saveGState()
    if !small { ctx.setShadow(offset: .zero, blur: 18 * scale, color: rgb(0xFFFFFF, 0.6)) }
    ctx.addPath(bars)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
}

func renderPNG(pixels: Int, to url: URL) throws {
    guard
        let ctx = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw IconError("cannot create a \(pixels)px bitmap context") }
    drawIcon(in: ctx, pixels: pixels)
    guard let image = ctx.makeImage(),
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw IconError("cannot encode \(url.lastPathComponent)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw IconError("cannot write \(url.path)") }
}

struct IconError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func run() throws {
    let args = CommandLine.arguments.dropFirst()
    guard args.count == 1, let outPath = args.first else {
        throw IconError("usage: swift tools/make-icon.swift <outdir>")
    }
    let fm = FileManager.default
    let out = URL(fileURLWithPath: outPath, isDirectory: true)
    let iconset = out.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    try? fm.removeItem(at: iconset)
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

    for points in [16, 32, 128, 256, 512] {
        try renderPNG(pixels: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
        try renderPNG(pixels: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
    }
    let master = out.appendingPathComponent("icon-1024.png")
    try? fm.removeItem(at: master)
    try fm.copyItem(at: iconset.appendingPathComponent("icon_512x512@2x.png"), to: master)

    let icns = out.appendingPathComponent("AppIcon.icns")
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else { throw IconError("iconutil failed (\(iconutil.terminationStatus))") }
    print("Wrote \(icns.path) and \(master.path)")
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
