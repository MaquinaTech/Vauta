// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

extension Channel {
    /// Speaker colour in the panel and in Meetings; always shown next to the speaker's name, never alone.
    var tint: Color { self == .me ? Self.meTint : Self.othersTint }

    /// "Me" is teal, not the accent blue of links and times, so a speaker's name never reads as clickable. The system
    /// teal and purple are under 4.5:1 on a light background: darker there, unchanged in dark mode.
    private static let meTint = adaptive(.systemTeal, darkening: 0.4)
    private static let othersTint = adaptive(.systemPurple, darkening: 0.22)

    /// The colour of a speaker: the channel's own for the first one, a turn of its hue (`SpeakerPalette`) for the rest.
    /// Always printed next to the speaker's name, never alone.
    func tint(ordinal: Int) -> Color {
        guard ordinal > 1 else { return tint }
        func ns(_ rgb: SpeakerPalette.RGB) -> NSColor { NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1) }
        let light = ns(SpeakerPalette.color(channel: self, ordinal: ordinal, dark: false))
        let dark = ns(SpeakerPalette.color(channel: self, ordinal: ordinal, dark: true))
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }

    private static func adaptive(_ base: NSColor, darkening: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? base : (base.blended(withFraction: darkening, of: .black) ?? base)
        })
    }

    /// Width of the widest speaker label ("Me" or "Others" in the interface language) at the
    /// panel's caption size, so the text column of every transcript line starts at the same x.
    @MainActor static var labelWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .semibold)
        let widest = [Channel.me, .others].map { ($0.displayName as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return ceil(widest) + 1
    }
}
