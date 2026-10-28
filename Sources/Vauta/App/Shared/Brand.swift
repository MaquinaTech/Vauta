// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import SwiftUI

/// Vauta's own colours, the same as the website's: indigo, blue and teal for the app, red into magenta while it records.
/// Used for the record button, the orb and the light behind them, never for text.
enum Brand {
    static let indigo = rgb(0x7B, 0x6D, 0xFF)
    static let blue = rgb(0x3A, 0x6F, 0xF0)
    static let teal = rgb(0x17, 0xB3, 0xA3)
    static let rose = rgb(0xFF, 0x4F, 0x7A)
    static let red = rgb(0xE5, 0x24, 0x5A)
    static let magenta = rgb(0xC4, 0x2F, 0xB8)
    /// The website's speaker colours and two warm accents, for light that moves inside the sphere and its orbit.
    static let pink = rgb(0xFF, 0x4F, 0xD8)
    static let cyan = rgb(0x3F, 0xE0, 0xFF)
    static let violet = rgb(0xA7, 0xA2, 0xFF)
    static let amber = rgb(0xFF, 0xB3, 0x6B)

    /// The record button at rest. White on the blue in the middle, where the glyph sits, is 4.3:1.
    static let idle = [indigo, blue, teal]
    /// The record button while recording. White on the red in the middle is 4.4:1.
    static let recording = [rose, red, magenta]

    /// The mark of what the model wrote (the sparkles next to a decision or a task): Vauta's indigo, darker on a light
    /// background so it keeps 4.5:1 there, lighter on a dark one.
    static let sparkle = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x9D / 255, green: 0x95 / 255, blue: 0xFF / 255, alpha: 1)
            : NSColor(srgbRed: 0x55 / 255, green: 0x4A / 255, blue: 0xE0 / 255, alpha: 1)
    })

    /// The fill of a symbol: indigo into blue into teal, like the record button; deeper on a light background, where
    /// the website's teal would look pale.
    static let symbolGradient = LinearGradient(colors: [adaptive(light: 0x5A4FE0, dark: 0x7B6DFF),
                                                        adaptive(light: 0x2F66E0, dark: 0x3A6FF0),
                                                        adaptive(light: 0x0F8F84, dark: 0x17B3A3)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        func ns(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light) })
    }

    /// Renders keep one still frame: an animation would make two renders of the same scene differ.
    static var freezesMotion: Bool {
        #if VAUTA_DIAGNOSTICS
        return Bundle.main.bundleIdentifier?.hasPrefix("local.vauta.snapshots") == true
        #else
        return false
        #endif
    }

    private static func rgb(_ red: Int, _ green: Int, _ blue: Int) -> Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }
}
