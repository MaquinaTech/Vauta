// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import SwiftUI

/// Korean is written with spaces and breaks at them (어절), but with the interface in Korean SwiftUI's Text may break
/// a Hangul word between two syllables. SwiftUI has no setting for it; an attributed string with the paragraph style
/// `hangulWordPriority` is what it honors. Other languages are not touched.
extension AttributedString {
    /// The text with word-based line breaking for Hangul.
    static func hangulWordPriority(_ string: String) -> AttributedString {
        var text = AttributedString(string)
        let style = NSMutableParagraphStyle()
        style.lineBreakStrategy = .hangulWordPriority
        text.paragraphStyle = style
        return text
    }
}

extension Text {
    /// A running text (a note, a paragraph) that breaks Korean at its spaces.
    init(wrapping string: String) {
        if string.containsHangulSyllables {
            self.init(AttributedString.hangulWordPriority(string))
        } else {
            self.init(verbatim: string)
        }
    }
}

extension String {
    var containsHangulSyllables: Bool {
        unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
    }
}

/// Korean text that breaks only at its spaces, for a footnote or a paragraph. SwiftUI's `Text` may break a Hangul word
/// between two syllables (the `hangulWordPriority` paragraph style and U+2060 are not honored in every rendering path),
/// so each word is its own `Text` and a layout wraps them, like a browser does. Text without Hangul is a plain `Text`.
struct WordWrappedText: View {
    let text: String

    var body: some View {
        if text.containsHangulSyllables {
            // Each line of the text (a "\n" in the string) is its own flow, left-aligned, in reading order.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: true).enumerated()), id: \.offset) { _, line in
                    WordFlowLayout(spacing: 4) {
                        ForEach(Array(line.split(separator: " ", omittingEmptySubsequences: true).enumerated()), id: \.offset) { _, word in
                            Text(verbatim: String(word))
                        }
                    }
                }
            }
            // One paragraph for VoiceOver, not one element per word.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: text))
        } else {
            Text(verbatim: text)
        }
    }
}

/// Places its subviews left to right and starts a new line when the next one does not fit.
struct WordFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in rows.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], width: CGFloat, height: CGFloat) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            usedWidth = max(usedWidth, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return (frames, usedWidth, y + lineHeight)
    }
}
