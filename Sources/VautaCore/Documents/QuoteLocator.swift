// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CoreGraphics
import Foundation

/// Finds a quote inside the text of one page, tolerating what the extraction and the model change without changing the words:
/// case, accents, width, whitespace, hyphenation at a line end and punctuation. Only letters and digits are compared.
public enum QuoteLocator {
    /// Letters and digits of `text`, folded, each with the UTF-16 range of the character it came from.
    private static func fold(_ text: String) -> (folded: String, origins: [NSRange]) {
        var folded = String.UnicodeScalarView()
        var origins: [NSRange] = []
        var offset = 0
        for character in text {
            let length = character.utf16.count
            let piece = String(character).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            for scalar in piece.unicodeScalars where scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                folded.append(scalar)
                origins.append(NSRange(location: offset, length: length))
            }
            offset += length
        }
        return (String(folded), origins)
    }

    /// The range, in UTF-16 units of `text`, of `quote` (the whole quote, else its first `prefixLength` characters).
    public static func range(of quote: String, in text: String, prefixLength: Int = 40) -> NSRange? {
        let (haystack, origins) = fold(text)
        func locate(_ needle: String) -> NSRange? {
            let wanted = fold(needle).folded
            guard wanted.unicodeScalars.count >= 3, let found = haystack.range(of: wanted) else { return nil }
            let start = haystack.unicodeScalars.distance(from: haystack.unicodeScalars.startIndex, to: found.lowerBound)
            let length = wanted.unicodeScalars.count
            guard start < origins.count, start + length - 1 < origins.count else { return nil }
            let first = origins[start], last = origins[start + length - 1]
            return NSRange(location: first.location, length: last.location + last.length - first.location)
        }
        return locate(quote) ?? locate(String(quote.prefix(prefixLength)))
    }
}

extension QuoteLocator {
    /// The passage of `passages` that holds `quote` (in its own text, not in its context line), in the order given. Used when a
    /// citation's passage key no longer exists (the file was edited and indexed again) but the words may still be in the file.
    public static func passage(quoting quote: String, in passages: [DocumentPassage]) -> DocumentPassage? {
        passages.first { range(of: quote, in: VautaPrompts.body(of: $0)) != nil }
    }

    /// `range(of:in:)` as a Swift range of `text`.
    public static func swiftRange(of quote: String, in text: String) -> Range<String.Index>? {
        range(of: quote, in: text).flatMap { Range($0, in: text) }
    }
}

/// An image file decoded at a bounded size (a 100-megapixel photo is never held whole just to be shown).
public enum DocumentImage {
    public static func thumbnail(of url: URL, maxPixel: Int = 1600) -> CGImage? { VisionOCR.thumbnail(of: url, maxPixel: maxPixel) }

    /// The same, decoded on a thread of its own and given up after `seconds` (nil): a slow or hung disk does not hold a thread of the
    /// cooperative pool.
    public static func loadThumbnail(of url: URL, maxPixel: Int = 1600, seconds: TimeInterval = 8) async -> CGImage? {
        struct Box: @unchecked Sendable { let image: CGImage? }
        let box = try? await runWithDeadline(seconds: seconds) { Box(image: VisionOCR.thumbnail(of: url, maxPixel: maxPixel)) }
        return box?.image
    }
}
