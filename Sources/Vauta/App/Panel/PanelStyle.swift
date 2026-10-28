// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import SwiftUI

/// The look shared by everything in the menu-bar panel: one neutral card and
/// one banner for things that need attention, so the same kind of content
/// always looks the same.
enum PanelBannerStyle {
    /// A question or an offer (accent tint).
    case info
    /// Something is wrong or about to happen (orange tint).
    case warning
    /// Something is wrong and blocks the work (red tint), like a problem in Settings → Status.
    case error

    var tint: Color {
        switch self {
        case .info: .accentColor
        case .warning: .orange
        case .error: .red
        }
    }
}

/// The surface of a card or banner. With Increase Contrast (or Reduce Transparency) a tinted fill
/// alone has no edge on the panel's material, so it gets a stroke.
private struct PanelSurface: ViewModifier {
    let tint: Color
    let fill: AnyShapeStyle
    let strokeOpacity: Double
    /// What Vauta writes on its own (live notes, answers, the brief, the follow-up): a hairline edge in Vauta's colours.
    var isVautaWork = false
    @Environment(\.colorSchemeContrast) private var systemContrast
    private var contrast: ColorSchemeContrast { systemContrast.snapshotResolved }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    private var reduceTransparency: Bool {
        #if VAUTA_DIAGNOSTICS
        if SnapshotMode.reduceTransparency { return true }
        #endif
        return systemReduceTransparency
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: CardStyle.radius)
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: shape)
            .overlay {
                if contrast == .increased || reduceTransparency {
                    shape.strokeBorder(tint.opacity(strokeOpacity), lineWidth: 1)
                } else if isVautaWork {
                    shape.strokeBorder(AngularGradient(colors: [Brand.indigo, Brand.cyan, Brand.teal, Brand.pink, Brand.indigo], center: .center)
                        .opacity(colorScheme == .dark ? 0.55 : 0.45), lineWidth: 1)
                }
            }
    }
}

extension View {
    /// Neutral content: live notes, tools, translation.
    func panelCard() -> some View {
        modifier(PanelSurface(tint: .primary, fill: AnyShapeStyle(.quinary), strokeOpacity: 0.4))
    }

    /// A card with what Vauta writes on its own (live notes, answers, the brief, the follow-up): the neutral card with a
    /// hairline edge in Vauta's colours.
    func panelVautaCard() -> some View {
        modifier(PanelSurface(tint: .primary, fill: AnyShapeStyle(.quinary), strokeOpacity: 0.4, isVautaWork: true))
    }

    /// A banner: suggestions, warnings and the stop notices.
    func panelBanner(_ style: PanelBannerStyle) -> some View {
        modifier(PanelSurface(tint: style.tint, fill: AnyShapeStyle(style.tint.opacity(style == .warning ? 0.15 : 0.12)), strokeOpacity: 0.7))
    }

    /// The title of a card: same size and weight everywhere, with the icon in Vauta's colours.
    func panelCardTitle() -> some View {
        font(.callout.weight(.medium))
            .labelStyle(PanelCardTitleLabelStyle())
    }

    /// The icon column of a banner: the icon in the banner's colour, the text in one column, so the
    /// buttons below (`panelBannerActions()`) can line up with the text.
    func panelBannerLabel(_ style: PanelBannerStyle) -> some View {
        labelStyle(PanelBannerLabelStyle(tint: style.tint))
    }

    /// The next step is the prominent button; once it is done the emphasis moves on (the other one stays a plain bordered button).
    @ViewBuilder func prominentButton(_ isProminent: Bool) -> some View {
        if isProminent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
    }

    /// Buttons or progress under a banner's text: they start where the text starts, not under the icon.
    func panelBannerActions() -> some View {
        padding(.leading, PanelMetrics.bannerTextIndent)
    }
}

/// The buttons under a banner or in a card: side by side when they fit, one under the other when a long
/// translation would otherwise cut a label.
struct PanelActionRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content() }
            VStack(alignment: .leading, spacing: 6) { content() }
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PanelCardTitleLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            // Every title's icon in the same square, scale and weight, so the symbols weigh the same.
            configuration.icon
                .imageScale(.medium)
                // Vauta's colours, as on the record button: the cards are what Vauta does while it listens.
                .foregroundStyle(Brand.symbolGradient)
                .frame(width: PanelMetrics.titleIconWidth, height: PanelMetrics.titleIconWidth, alignment: .center)
            configuration.title
        }
    }
}

private struct PanelBannerLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PanelMetrics.bannerIconSpacing) {
            // One weight for every banner icon: the filled variant wherever the symbol has one.
            configuration.icon
                .symbolVariant(.fill)
                .foregroundStyle(tint)
                .frame(width: PanelMetrics.bannerIconWidth, alignment: .center)
            configuration.title
        }
    }
}

extension AttributedString {
    /// Short UI messages are never hyphenated ("Speicher-/platz", "Mikro-/fon"): a word that does not fit moves to
    /// the next line. SwiftUI hyphenates by the text's language and ignores the paragraph style's hyphenation
    /// factor, so an alphabetic message is tagged with no particular language (there is no dictionary to
    /// hyphenate by). Japanese, Chinese and Korean have no hyphenation and keep their language, which their line
    /// breaking depends on.
    mutating func disableHyphenation(of string: String) {
        let unspaced = string.unicodeScalars.contains {
            (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value)
        }
        if !unspaced { self.languageIdentifier = "und" }
    }
}

extension Text {
    /// A paragraph of a panel message: no word alone on the last line, no break inside the names of places in
    /// System Settings, and no hyphenation.
    ///
    /// The path is measured with `font` against `width`, the text column it is set in; the defaults are those of a
    /// panel banner.
    init(paragraph string: String, font: NSFont.TextStyle = .caption1, width: CGFloat = PanelMetrics.bannerTextWidth) {
        let widowFree = string.avoidingWidow(pathOnItsOwnLine: true, font: font, width: width)
        var text = string.containsHangulSyllables ? AttributedString.hangulWordPriority(widowFree) : AttributedString(widowFree)
        text.disableHyphenation(of: string)
        self.init(text)
    }
}

extension Text {
    /// A panel message in `style` whose sentences break between them instead of inside the last one, measured with the
    /// font of that style and the text column of a banner.
    init(sentences string: String, style: NSFont.TextStyle = .caption1, width: CGFloat = PanelMetrics.bannerTextWidth) {
        self.init(paragraph: string.breakingBeforeLastSentence(fittingIn: width, font: .preferredFont(forTextStyle: style)))
    }
}

/// A banner's text: a semibold title and, under it, what it means or what to do, in the secondary colour. Every
/// banner of the panel is set this way.
struct PanelNoticeText: View {
    let title: String
    var detail: String?

    var body: some View {
        NoticeStack(title: Text(paragraph: title).font(.callout),
                    detail: detail.map { Text(sentences: $0).font(.caption) })
    }
}

/// The tallest the panel may be, so Settings and Quit never fall off the
/// screen. Scenes can set it to show a smaller screen.
private struct PanelMaxHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

/// The time the panel's stopwatches show, when a scene needs the same picture on every render.
private struct PanelClockKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

/// The live notes card opens with all its notes (a scene shows the "Show all" state).
private struct PanelNotesExpandedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var panelNotesExpanded: Bool {
        get { self[PanelNotesExpandedKey.self] }
        set { self[PanelNotesExpandedKey.self] = newValue }
    }

    var panelMaxHeight: CGFloat? {
        get { self[PanelMaxHeightKey.self] }
        set { self[PanelMaxHeightKey.self] = newValue }
    }

    var panelClock: Date? {
        get { self[PanelClockKey.self] }
        set { self[PanelClockKey.self] = newValue }
    }
}

enum PanelMetrics {
    /// The icon column of a card title, and the room between it and the title.
    static let titleIconWidth: CGFloat = 16
    static let titleIconSpacing: CGFloat = 6
    /// What sits under a card title lines up with the title's text, not with its icon.
    static let titleTextIndent: CGFloat = titleIconWidth + titleIconSpacing
    /// A hint's warning symbol (caption size) and the gap to its text.
    static let hintTextIndent: CGFloat = 18
    /// The icon column of a banner and the gap to its text; actions line up with the text. Same as a card
    /// title, so the text of a banner and of the card below it start on one edge.
    static let bannerIconWidth: CGFloat = 16
    static let bannerIconSpacing: CGFloat = titleIconSpacing
    static let bannerTextIndent: CGFloat = bannerIconWidth + bannerIconSpacing
    /// The width of the text column of a banner or a card: the panel (360 pt) minus its margins, the card padding and the title's indent.
    static let bannerTextWidth: CGFloat = 360 - 32 - 24 - titleTextIndent

    /// The screen that has the menu bar, minus room for the menu bar gap.
    static var screenLimit: CGFloat {
        let screen = NSScreen.screens.first ?? NSScreen.main
        return max(360, (screen?.visibleFrame.height ?? 800) - 40)
    }
}
