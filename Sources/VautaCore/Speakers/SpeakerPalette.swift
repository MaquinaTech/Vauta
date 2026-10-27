// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The colours of speakers beyond the first of each channel. The first speaker keeps the channel's own colour
/// (teal for the user, purple for the others, see `ChannelStyle`); the rest turn the channel's hue by fixed
/// steps, so a call reads as "the purple family" and the user's room as "the teal family" while neighbours stay
/// apart. A colour is never the only sign of a speaker: the name is always printed next to it.
/// Plain numbers here so the contrast can be tested; the interface turns them into colours.
public enum SpeakerPalette {
    public struct RGB: Sendable, Equatable {
        public let red: Double, green: Double, blue: Double

        /// WCAG relative luminance.
        public var luminance: Double {
            func linear(_ value: Double) -> Double { value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        /// WCAG contrast ratio against another colour.
        public func contrast(with other: RGB) -> Double {
            let (a, b) = (luminance, other.luminance)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
    }

    /// One speaker's colour before the light or dark treatment: a hue and how much of it is kept (a neutral keeps little).
    struct Swatch: Equatable { let hue: Double; let chroma: Double }

    /// The colours of the first eight speakers of a channel. Neighbours are far apart on the hue circle (never a step of a
    /// few tenths of a turn, which two rose shades made look the same), the others keep away from the teal of the user's
    /// own voice and from the blue of links and the accent, and the last two of the others are a paler terracotta and a blue-grey, chosen away from the greens, olives and pinks
    /// before them (never a grey or a near-white, which read as plain or disabled text).
    /// The first colour of each channel is its own (teal, purple); the table cycles, softer, from the ninth.
    static func swatches(_ channel: Channel) -> [Swatch] {
        let hues: [Double] = channel == .me
            ? [0.49, 0.12, 0.93, 0.72, 0.30, 0.85]
            : [0.78, 0.06, 0.30, 0.91, 0.17, 0.75]
        let muted = channel == .me
            ? [Swatch(hue: 0.55, chroma: 0.2), Swatch(hue: 0.12, chroma: 0.55)]
            : [Swatch(hue: 0.03, chroma: 0.45), Swatch(hue: 0.58, chroma: 0.45)]
        return hues.map { Swatch(hue: $0, chroma: 1) } + muted
    }

    /// The contrast a light-appearance colour keeps against white (see `color`).
    static let lightContrast = 5.4

    /// The colour of speaker `ordinal` (from 1) of a channel. `dark` is for dark appearance (light text on a dark
    /// background); otherwise dark text on a light background.
    public static func color(channel: Channel, ordinal: Int, dark: Bool) -> RGB {
        let table = swatches(channel)
        let index = max(ordinal, 1) - 1
        let swatch = table[index % table.count]
        // Second and later rounds of the table are less saturated, so they read as "another shade of the same family".
        let softer = index >= table.count ? 0.7 : 1.0
        let chroma = swatch.chroma * softer
        if dark { return hsb(swatch.hue, 0.5 * chroma, 1.0) }
        // On a light background each hue is as bright as still reads: 5.4 against white, which is still 4.7 against the
        // light grey (about 0.945) of the captions panel and the cards, where the names are small. One fixed brightness
        // turned the warm hues (orange, rose, olive) into near-identical browns and maroons; this keeps them apart.
        let saturation = 0.85 * chroma
        let white = RGB(red: 1, green: 1, blue: 1)
        var (low, high) = (0.3, 0.9)
        for _ in 0..<20 {
            let middle = (low + high) / 2
            if hsb(swatch.hue, saturation, middle).contrast(with: white) >= lightContrast { low = middle } else { high = middle }
        }
        return hsb(swatch.hue, saturation, low)
    }

    static func hsb(_ hue: Double, _ saturation: Double, _ brightness: Double) -> RGB {
        let sector = (hue * 6).truncatingRemainder(dividingBy: 6)
        let fraction = sector - sector.rounded(.down)
        let p = brightness * (1 - saturation), q = brightness * (1 - saturation * fraction), t = brightness * (1 - saturation * (1 - fraction))
        switch Int(sector) {
        case 0: return RGB(red: brightness, green: t, blue: p)
        case 1: return RGB(red: q, green: brightness, blue: p)
        case 2: return RGB(red: p, green: brightness, blue: t)
        case 3: return RGB(red: p, green: q, blue: brightness)
        case 4: return RGB(red: t, green: p, blue: brightness)
        default: return RGB(red: brightness, green: p, blue: q)
        }
    }
}
