// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Everything that is read from a document is untrusted text. Before it is indexed, shown or put in a prompt it is
/// normalized (NFC) and stripped of the characters that hide text or change how it reads: control characters,
/// bidirectional overrides, zero-width characters, the byte order mark and the "tag" characters that can carry an
/// invisible message.
public enum TextSanitizer {
    /// Whether a scalar is removed. Newline and tab stay (the caller decides what to do with them).
    static func isRemoved(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09, 0x0A: false
        case 0x00...0x1F, 0x7F...0x9F: true            // C0 and C1 controls (carriage return is folded before, see `clean`)
        case 0x202A...0x202E, 0x2066...0x2069: true    // bidi embeddings, overrides and isolates
        case 0x200B...0x200F, 0x2060...0x2064: true    // zero-width space, joiners, marks and invisible operators
        case 0x061C, 0x180E, 0xFEFF, 0xFFF9...0xFFFB: true
        case 0xE0000...0xE007F: true                   // tag characters
        case 0xFE00...0xFE0F, 0xE0100...0xE01EF: true  // variation selectors (can hide a payload)
        default: false
        }
    }

    /// NFC text without the removed scalars; carriage returns become newlines, other whitespace runs of spaces stay.
    public static func clean(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(text.unicodeScalars.count)
        var previousCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\r" {
                out.append("\n")
                previousCR = true
                continue
            }
            if scalar == "\n", previousCR { previousCR = false; continue }
            previousCR = false
            if isRemoved(scalar) {
                // Line and paragraph separators and the form feed read as a break; the rest vanishes.
                continue
            }
            if scalar == "\u{2028}" || scalar == "\u{2029}" { out.append("\n"); continue }
            out.append(scalar)
        }
        return String(out).precomposedStringWithCanonicalMapping
    }

    /// Collapses runs of blank lines to one and trims the ends. Lines are trimmed of trailing spaces.
    public static func tidy(_ text: String) -> String {
        var lines: [Substring] = []
        var blank = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                blank += 1
                if blank > 1 { continue }
            } else {
                blank = 0
            }
            lines.append(Substring(line))
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A single line safe to show or put in a prompt: no breaks, clipped to `limit` characters.
    public static func oneLine(_ text: String, limit: Int) -> String {
        let flat = clean(text).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        let collapsed = flat.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String(PromptText.defang(collapsed).prefix(limit))
    }
}
