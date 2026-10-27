// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import SwiftUI

/// Sizes shared by every setup page, so cards line up from one page to the next.
enum OnboardingMetrics {
    /// The setup window. Wide enough for the footer's counter between the buttons of the longest language (the
    /// compound "Allow Microphone and Continue" labels). Tall enough for the longest page (two found servers) in every language; anything longer
    /// scrolls inside it.
    static let windowSize = CGSize(width: 640, height: 610)
    /// The window while the model server guide is open: taller, so the four steps are not mostly below the fold. It goes
    /// back to `windowSize` when the guide closes.
    static let guideWindowHeight: CGFloat = 800
    /// What the window keeps under the guide sheet: the footer (its rule, buttons and padding) in full, and a small gap.
    /// The window is as tall as the sheet and this, so no dimmed band is left between the two.
    static let guideFooterBand: CGFloat = 57 + 8
    /// The tallest the guide sheet gets in the setup window: the window's height less the footer, so more of the four
    /// steps is in view.
    static let guideSheetHeight: CGFloat = guideWindowHeight - guideFooterBand
    /// The shortest the window gets on a small screen: the footer and a few lines of the page.
    static let minimumWindowHeight: CGFloat = 440
    /// The title bar, which the screen's visible frame has to leave room for.
    private static let titleBarHeight: CGFloat = 32

    /// The tallest the window can be on this screen (its visible frame, less the title bar): on a small or scaled
    /// display the footer must stay on screen, so the page scrolls instead.
    @MainActor
    static func screenLimit(_ screen: NSScreen? = NSScreen.main) -> CGFloat {
        max(minimumWindowHeight, (screen?.visibleFrame.height ?? .greatestFiniteMagnitude) - titleBarHeight)
    }

    /// The setup window's height: `wanted`, or less when the screen is shorter.
    @MainActor
    static func windowHeight(wanted: CGFloat, screenLimit: CGFloat) -> CGFloat { min(wanted, screenLimit) }

    /// The tallest the guide sheet gets in a window that fits the screen.
    @MainActor
    static func guideSheetMaxHeight(screenLimit: CGFloat = screenLimit()) -> CGFloat {
        min(guideSheetHeight, screenLimit - guideFooterBand)
    }
    /// Space between the window edge and every card, and between the window edge and the footer buttons.
    static let pageMargin: CGFloat = 24
    /// Inner metrics of every card: the same inset (as `OnboardingCard`'s rows), so edges and buttons line up
    /// from one card to the next. The large cards (choices, the Apple Intelligence notice) share one text column.
    static let cardInset: CGFloat = 14
    static let choicePadding = cardInset
    static let choiceIconWidth: CGFloat = 28
    static let choiceIconGap: CGFloat = 12
    /// Height of the icon at the top of a page, so the title never moves between pages.
    static let headerIconHeight: CGFloat = 40
    static let cardRadius: CGFloat = CardStyle.radius
    /// Space above the first element of every page: the header sits at the same height on all of them.
    static let pageTopInset: CGFloat = 30
    /// The text column of a permission row: the card inside the page margins, minus the row's insets and its icon column
    /// (24 pt and the 12 pt gap).
    static let permissionTextWidth: CGFloat = windowSize.width - 2 * pageMargin - 2 * cardInset - 24 - 12
    /// Width of centred sentences (subtitles, the welcome text): about two balanced lines.
    static let readableWidth: CGFloat = 440
    /// Space between two cards of a page (and between a card and the message between them): the same on every page.
    static let cardSpacing: CGFloat = 12
}

extension String {
    /// A sentence that never ends on a line of one or two words: the shared widow rule, which keeps Korean's natural
    /// breaks (Hangul breaks between syllables) and joins the ending of Japanese and Chinese with word joiners.
    var keepingLastWordsTogether: String { avoidingWidow }

    var hasHangul: Bool {
        unicodeScalars.contains { (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value) || (0x3130...0x318F).contains($0.value) }
    }

    /// The last `words` words joined with no-break spaces (a closing sentence such as "You can’t undo this." stays whole).
    func keepingLast(words: Int) -> String {
        // Korean breaks only at its spaces, and a no-break chunk too long for the line would be split inside a word.
        if hasHangul { return self }
        var characters = Array(self)
        var joined = 0
        var index = characters.count - 1
        while index > 0, joined < words - 1 {
            if characters[index] == " " { characters[index] = "\u{00A0}"; joined += 1 }
            index -= 1
        }
        return String(characters)
    }
}

/// The footer: buttons on both edges and a counter that always sits in the same place: right after the leading
/// button, 24 pt from it. It never follows the changing title of Continue ("Allow Microphone and Continue"), so the
/// progress indicator does not move from one page to the next. When the buttons of a long language leave it no room
/// (24 pt from each button) it is offered what is free and its `ViewThatFits` falls back to nothing.
struct SetupFooterLayout: Layout {
    /// The least space between the counter and a button.
    private static let clearance: CGFloat = 24

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return CGSize(width: proposal.width ?? sizes.reduce(0) { $0 + $1.width },
                      height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let leading = subviews[0].sizeThatFits(.unspecified)
        let trailing = subviews[2].sizeThatFits(.unspecified)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
        let low = bounds.minX + leading.width + Self.clearance
        let high = bounds.maxX - trailing.width - Self.clearance
        let room = ProposedViewSize(width: max(0, high - low), height: nil)
        subviews[1].place(at: CGPoint(x: low, y: bounds.midY), anchor: .leading, proposal: room)
    }
}

/// Places the page scrolls to.
enum OnboardingAnchor: Hashable {
    case pageEnd
}

/// A rounded card with rows separated by hairlines: the one container of every setup page.
struct OnboardingCard<Content: View>: View {
    /// A warning card is tinted like the warning banners of Meetings and the panel; the others are neutral.
    var warning = false
    @ViewBuilder var content: Content
    @Environment(\.colorSchemeContrast) private var systemContrast
    private var contrast: ColorSchemeContrast { systemContrast.snapshotResolved }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(subviews) { subview in
                    subview
                        .padding(.horizontal, OnboardingMetrics.cardInset)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if subview.id != subviews.last?.id { Divider().padding(.horizontal, OnboardingMetrics.cardInset) }
                }
            }
        }
        .modifier(OnboardingCardBackground(warning: warning))
    }
}

private struct OnboardingCardBackground: ViewModifier {
    let warning: Bool

    func body(content: Content) -> some View {
        if warning { content.bannerBackground(StatusSymbol.warning.color) } else { content.cardBackground() }
    }
}

/// An icon in a fixed-width column followed by text, so a list of bullets starts every line at the same x.
struct SetupBulletStyle: LabelStyle {
    /// Where the text starts: the icon column plus the gap. Text below a bullet lines up with it.
    static let textIndent: CGFloat = 32
    /// The space between two bullets.
    static let spacing: CGFloat = 10
    /// Icons keep their own colour (status icons) instead of the tint.
    var keepsIconColor = false
    /// A heavier stroke for thin outline glyphs (the privacy promises).
    var iconWeight: Font.Weight?

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // The icon column is exactly one text line tall (a blank line of the same font holds it), so a tall glyph
            // (the lock) never makes its row taller than the others: every row of a list is one line apart.
            Text(verbatim: " ")
                .frame(width: 22)
                .overlay {
                    configuration.icon
                        .fontWeight(iconWeight)
                        .foregroundStyle(keepsIconColor ? AnyShapeStyle(.foreground) : AnyShapeStyle(.tint))
                        .fixedSize()
                }
                .accessibilityHidden(true)
            configuration.title
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A result with a coloured icon and normal-contrast text: the meaning is in the text, not in the colour.
struct SetupStatusLabel: View {
    enum Kind { case success, warning, info }

    let text: String
    var kind: Kind = .warning
    /// A capsule after the text ("Quick start · Basic quality").
    var badge: String?
    /// What follows the first sentence, as secondary text under it ("No model chosen." / "Vauta still records…").
    var detail: String?
    /// Draws the icon in the bullet column of the cards (22 pt wide, 10 pt gap), so text lines up with other bullets.
    var onBulletGrid = true

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            SentenceLines(text: text)
                .fontWeight(detail == nil ? .regular : .semibold)
                .fixedSize(horizontal: false, vertical: true)
            if let badge { BadgeCapsule(badge) }
        }
    }

    var body: some View {
        let label = Label {
            if let detail {
                // The metrics of the choice cards (a 6 pt gap under a row that is as tall as a badge, with or without one), so the
                // title and its detail are the same distance apart in every notice of the setup pages.
                ChoiceCardLayout(spacing: 6, minimumRow: 20) {
                    titleRow
                    SentenceLines(text: detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                titleRow
            }
        } icon: {
            switch kind {
            case .success: StatusSymbol.ok.image
            case .warning: StatusSymbol.warning.image
            case .info: StatusSymbol.info.image
            }
        }
        if onBulletGrid {
            label.labelStyle(SetupBulletStyle(keepsIconColor: true))
        } else {
            label
        }
    }
}

/// Width that a classic (always visible) scroller takes from a scroll view's content; 0 with overlay scrollers.
/// Content that moves left by this much when a page starts to scroll is moved back, so margins stay equal.
@MainActor
enum ScrollerMetrics {
    static var reservedWidth: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }
}

/// A label on the left and its control on the right edge of the card.
struct SetupFieldRow<Content: View>: View {
    let title: String
    /// How the title and the control line up: centred, or on their first baseline when the control is text.
    var alignment: VerticalAlignment = .center
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: alignment, spacing: 12) {
            Text(title).lineLimit(2)
            Spacer(minLength: 12)
            // The control keeps its size (a button never truncates); the label gives way.
            content.fixedSize().layoutPriority(1)
        }
        // As tall as a regular button, so a row doesn't change height when its control does.
        .frame(minHeight: 28)
    }
}
