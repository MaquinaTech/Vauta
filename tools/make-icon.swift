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
// Design: the macOS squircle on the standard 1024 grid (824 pt body, 100 pt margin),
// a deep indigo → teal gradient and a white page carrying a waveform, which reads as
// "notes taken from a conversation". Everything is drawn in 1024-unit space and scaled,
// with less detail at the smallest sizes so they stay legible.

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

/// A sheet of paper with a folded top-right corner.
func pagePath(_ r: CGRect, fold: CGFloat, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX + radius, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
    p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + radius), control: CGPoint(x: r.maxX, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - fold))
    p.addLine(to: CGPoint(x: r.maxX - fold, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
    p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - radius), control: CGPoint(x: r.minX, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
    p.addQuadCurve(to: CGPoint(x: r.minX + radius, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
    p.closeSubpath()
    return p
}

func drawIcon(in ctx: CGContext, pixels: Int) {
    let scale = CGFloat(pixels) / canvas
    ctx.scaleBy(x: scale, y: scale)
    // Shadow offsets and blur are in device pixels (the scale above doesn't apply to them): each one is
    // multiplied by `scale`, or the small sizes get a shadow eight times too wide, cut at the canvas edge.
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let small = pixels <= 32

    // Body with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(in: body)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 28 * scale, color: rgb(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x2A2470))
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient: deep indigo (top left) → teal (bottom right).
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(0x2A1A7C)), (0.52, rgb(0x2D58B0)), (1, rgb(0x12B8A6))]),
        start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    // Top sheen and bottom shade for a little depth.
    ctx.drawRadialGradient(
        gradient([(0, rgb(0xFFFFFF, 0.22)), (1, rgb(0xFFFFFF, 0))]),
        startCenter: CGPoint(x: 400, y: 930), startRadius: 0,
        endCenter: CGPoint(x: 400, y: 930), endRadius: 620, options: [])
    ctx.drawLinearGradient(
        gradient([(0, rgb(0x000000, 0.18)), (1, rgb(0x000000, 0))]),
        start: CGPoint(x: 512, y: body.minY), end: CGPoint(x: 512, y: body.minY + 260), options: [])
    ctx.restoreGState()

    // Hairline inner edge.
    if !small {
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.addPath(shape)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.16))
        ctx.setLineWidth(6)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // The page.
    let page =
        small
        ? CGRect(x: 262, y: 232, width: 500, height: 590)
        : CGRect(x: 287, y: 222, width: 450, height: 580)
    let fold: CGFloat = small ? 120 : 112
    let sheet = pagePath(page, fold: fold, radius: 34)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18 * scale), blur: 40 * scale, color: rgb(0x0B0830, 0.40))
    ctx.addPath(sheet)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    // Faint vertical shading on the paper.
    ctx.saveGState()
    ctx.addPath(sheet)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(0xE8ECF8)), (1, rgb(0xFFFFFF))]),
        start: CGPoint(x: 512, y: page.minY), end: CGPoint(x: 512, y: page.maxY), options: [])
    ctx.restoreGState()

    // Folded corner.
    let corner = CGMutablePath()
    corner.move(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    corner.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY - fold + 18))
    corner.addQuadCurve(
        to: CGPoint(x: page.maxX - fold + 18, y: page.maxY - fold),
        control: CGPoint(x: page.maxX - fold, y: page.maxY - fold))
    corner.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    corner.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: -4 * scale, height: -6 * scale), blur: 14 * scale, color: rgb(0x0B0830, 0.25))
    ctx.addPath(corner)
    ctx.setFillColor(rgb(0xC9D0EE))
    ctx.fillPath()
    ctx.restoreGState()

    // Waveform: rounded bars filled with the background gradient.
    // Fewer, wider bars at the smallest sizes so the motif survives downsampling.
    let tiny = pixels <= 16
    let heights: [CGFloat] =
        tiny
        ? [0.5, 1.0, 0.7, 0.35]
        : small
            ? [0.38, 0.78, 1.0, 0.62, 0.34]
            : [0.22, 0.46, 0.80, 0.56, 1.0, 0.70, 0.88, 0.44, 0.24]
    let barWidth: CGFloat = tiny ? 64 : small ? 56 : 26
    let gap: CGFloat = tiny ? 64 : small ? 30 : 15
    let maxHeight: CGFloat = small ? 300 : 210
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    let waveCenterY = small ? page.midY - 10 : page.minY + 372
    // Snap the start to the pixel grid so one-pixel bars stay crisp at 16 px.
    let waveStartX = ((page.midX - total / 2) * scale).rounded() / scale
    let bars = CGMutablePath()
    for (i, h) in heights.enumerated() {
        let height = max(barWidth, h * maxHeight)
        let x = waveStartX + CGFloat(i) * (barWidth + gap)
        bars.addRoundedRect(
            in: CGRect(x: x, y: waveCenterY - height / 2, width: barWidth, height: height),
            cornerWidth: barWidth / 2, cornerHeight: barWidth / 2)
    }
    ctx.saveGState()
    ctx.addPath(bars)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(0x3B2E9E)), (1, rgb(0x0E9C98))]),
        start: CGPoint(x: waveStartX, y: waveCenterY),
        end: CGPoint(x: waveStartX + total, y: waveCenterY), options: [])
    ctx.restoreGState()

    // Text lines under the waveform.
    if !small {
        let inset: CGFloat = 70
        let lineHeight: CGFloat = 24
        let widths: [CGFloat] = [1.0, 0.86, 0.58]
        let usable = page.width - 2 * inset
        for (i, w) in widths.enumerated() {
            let y = page.minY + 170 - CGFloat(i) * 52
            ctx.addPath(
                CGPath(
                    roundedRect: CGRect(x: page.minX + inset, y: y, width: usable * w, height: lineHeight),
                    cornerWidth: lineHeight / 2, cornerHeight: lineHeight / 2, transform: nil))
        }
        ctx.setFillColor(rgb(0xB9C1E2))
        ctx.fillPath()
    }
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
