// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// The content of the captions panel: up to three captions, bottom-aligned
/// like subtitles. The panel never changes height and the hover bar floats
/// over the padding above the first line, so a caption that is still being
/// spoken updates in place without moving anything else, and the pointer
/// arriving changes nothing you are reading.
struct CaptionsView: View {
    let model: LiveTranslationModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    private var reduceTransparency: Bool {
        #if VAUTA_DIAGNOSTICS
        if SnapshotMode.reduceTransparency { return true }
        #endif
        return systemReduceTransparency
    }
    @Environment(\.colorSchemeContrast) private var systemContrast
    private var contrast: ColorSchemeContrast { systemContrast.snapshotResolved }

    private static let cardCorner: CGFloat = 22
    private static let corner = cardCorner
    /// How far the hover bar and the paused badge sit from the panel's edge. The bar is a capsule 28 pt tall (a corner
    /// radius of 14), so with the card's 22 pt corner an 8 pt inset makes the two shapes concentric.
    private static let barInset: CGFloat = cardCorner - 14
    /// From this panel width on, the hover bar spells out the server status.
    private static let statusTextWidth: CGFloat = 600
    /// From this panel width on, the "Paused" badge has room for its word beside the hover bar; narrower it is a symbol.
    private static let pausedBadgeWidth: CGFloat = 540
    @ViewLocalState private var width: CGFloat = 0
    @ViewLocalState private var alwaysShowsControls = CaptionsView.assistiveTechnologyIsOn

    /// With VoiceOver or Full Keyboard Access the controls can't be found by moving the pointer: they stay.
    static var assistiveTechnologyIsOn: Bool {
        NSWorkspace.shared.isVoiceOverEnabled || NSApp.isFullKeyboardAccessEnabled
    }

    var body: some View {
        let preferences = model.preferences
        let snapshot = model.snapshot
        let controlsShown = model.controlsVisible || alwaysShowsControls || snapshot.status == .paused
        let hasLines = CaptionContent.hasVisibleLines(snapshot, showOriginal: preferences.captionShowOriginal)
        ZStack(alignment: .topTrailing) {
            CaptionContent(snapshot: snapshot, size: preferences.captionTextSize, showOriginal: preferences.captionShowOriginal,
                           isRightToLeft: snapshot.pair?.target.characterDirection == .rightToLeft,
                           isOriginalRightToLeft: snapshot.pair?.source.characterDirection == .rightToLeft,
                           reduceMotion: reduceMotion, contrast: contrast, model: model)
                // The captions change while the person listens: VoiceOver treats them as a live region (finished captions are also announced by the model).
                .accessibilityAddTraits(.updatesFrequently)
            // Tucked into the top-trailing corner, clear of the border; it floats over the padding above the captions.
            // The same inset from the top and from the side, so the bar sits evenly in the rounded corner.
            // The bar has the same buttons in every state (play while paused, even when the message has its own "Resume").
            CaptionControls(model: model, showsStatusText: width >= Self.statusTextWidth)
                .offset(x: CaptionTextSize.horizontalPadding - Self.barInset, y: -(CaptionTextSize.topPadding - Self.barInset))
                .opacity(controlsShown ? 1 : 0)
                .allowsHitTesting(controlsShown)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: controlsShown)
            // Paused with captions on screen: the dimmed text says "old", the badge says why (a symbol alone when narrow).
            if snapshot.status == .paused, hasLines {
                PausedBadge(isCompact: width < Self.pausedBadgeWidth)
                    .offset(x: -(CaptionTextSize.horizontalPadding - Self.barInset), y: -(CaptionTextSize.topPadding - Self.barInset))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        // Voice Over and Full Keyboard Access can be switched on while the panel is up.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            alwaysShowsControls = Self.assistiveTechnologyIsOn
        }
        .onReceive(NSWorkspace.shared.publisher(for: \.isVoiceOverEnabled)) { _ in
            alwaysShowsControls = Self.assistiveTechnologyIsOn
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            alwaysShowsControls = Self.assistiveTechnologyIsOn
        }
        .padding(.horizontal, CaptionTextSize.horizontalPadding)
        .padding(.top, CaptionTextSize.topPadding)
        .padding(.bottom, CaptionTextSize.bottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { background }
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.7 : 0.14), lineWidth: contrast == .increased ? 1.5 : 1)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Live Translation"))
        // The captions panel hosts the session that shows Apple's download sheet for the pair it asked for.
        .translationDownloads(model.downloader, host: .panel)
    }

    @ViewBuilder private var background: some View {
        if reduceTransparency || contrast == .increased {
            Rectangle().fill(Color(nsColor: .windowBackgroundColor))
        } else {
            Rectangle().fill(.regularMaterial)
        }
    }
}

/// Either the captions or, when there are none, what the panel is waiting for.
private struct CaptionContent: View {
    let snapshot: CaptionSnapshot
    let size: CaptionTextSize
    let showOriginal: Bool
    let isRightToLeft: Bool
    let isOriginalRightToLeft: Bool
    let reduceMotion: Bool
    let contrast: ColorSchemeContrast
    let model: LiveTranslationModel

    private var visibleLines: [CaptionLine] { Self.visibleLines(snapshot, showOriginal: showOriginal) }

    static func visibleLines(_ snapshot: CaptionSnapshot, showOriginal: Bool) -> [CaptionLine] {
        snapshot.lines.filter { !$0.translation.isEmpty || (showOriginal && !$0.original.isEmpty) }
    }

    static func hasVisibleLines(_ snapshot: CaptionSnapshot, showOriginal: Bool) -> Bool {
        !visibleLines(snapshot, showOriginal: showOriginal).isEmpty
    }

    var body: some View { content }

    @ViewBuilder private var content: some View {
        let lines = visibleLines
        switch snapshot.status {
        case .listening:
            if lines.isEmpty {
                CaptionMessage(size: size, symbol: "waveform", title: Text("Listening…"), detail: nil, isWaiting: true, pulses: !reduceMotion)
            } else {
                stack(lines)
            }
        case .starting:
            if lines.isEmpty {
                CaptionMessage(size: size, symbol: nil, title: Text("Getting ready…"), detail: nil, isWaiting: true)
            } else {
                stack(lines)
            }
        case .needsDownload:
            if model.downloadFailed {
                // A failed download is an error, as in Settings → Translation: the error symbol and a button that says what to do.
                CaptionMessage(size: size, symbol: StatusSymbol.error.name, symbolColor: StatusSymbol.error.color,
                               title: Text("\(pairName): download didn’t finish"),
                               detail: String(localized: "Check your internet connection and try again.")) {
                    Button { if let pair = snapshot.pair { model.download(pair, from: .panel) } } label: { Text("Try Again…", comment: "Captions: retry the language download. The ellipsis is on purpose: it asks for Apple’s download confirmation again, unlike the retry of a stopped translation (“Try Again”)") }
                        .buttonStyle(.borderedProminent)
                    languageChooser(prominent: false)
                }
            } else {
                // The same notice as the speech model's in the menu-bar panel: the same symbol, in the accent colour.
                CaptionMessage(size: size, symbol: "arrow.down.circle.fill", symbolColor: .accentColor, title: Text("\(pairName) needs a download"),
                               detail: String(localized: "It downloads once from Apple. After that, translation runs on this Mac.")) {
                    Button { if let pair = snapshot.pair { model.download(pair, from: .panel) } } label: { Text("Download…") }
                        .buttonStyle(.borderedProminent)
                }
            }
        case .downloading:
            CaptionMessage(size: size, symbol: nil, title: Text("Downloading \(pairName)…"),
                           detail: String(localized: "You can keep using your Mac. Captions start when it finishes.")) {
                Button { model.cancelDownload() } label: { Text("Cancel") }
            }
        case .unsupported:
            CaptionMessage(size: size, symbol: StatusSymbol.warning.name, symbolColor: StatusSymbol.warning.color, title: Text("\(pairName) isn’t available"),
                           detail: String(localized: "Choose another language to translate into.")) { languageChooser(prominent: true) }
        case .sameLanguage:
            CaptionMessage(size: size, symbol: "globe", title: Text("Choose a language to translate into"),
                           detail: sameLanguageName.map { String(localized: "The meeting is already in \($0), so there is nothing to translate yet.") }) { languageChooser(prominent: true) }
        case .paused:
            if lines.isEmpty {
                CaptionMessage(size: size, symbol: "pause.circle", title: Text("Paused"), detail: String(localized: "Nothing is being translated.")) {
                    Button { model.setPaused(false) } label: { Text("Resume") }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                stack(lines, dimmed: true)
            }
        case .failed:
            CaptionMessage(size: size, symbol: StatusSymbol.error.name, symbolColor: StatusSymbol.error.color, title: Text("Translation stopped"),
                           detail: String(localized: "Vauta couldn’t translate \(pairName). Try again, or choose another language.")) {
                Button { model.setPaused(false); model.retry() } label: { Text("Try Again") }
                    .buttonStyle(.borderedProminent)
                languageChooser(prominent: false)
            }
        }
    }

    /// The way out of "unsupported" and "same language": the list of languages, right in the message.
    /// It is the main action when it is the only one (prominent, like the other states' main button) and a secondary
    /// one next to "Try Again".
    @ViewBuilder private func languageChooser(prominent: Bool) -> some View {
        let menu = Menu {
            TranslationTargetPicker(model: model)
        } label: {
            Text("Choose Language")
        }
        .menuStyle(.button)
        .fixedSize()
        if prominent { menu.buttonStyle(.borderedProminent) } else { menu }
    }

    /// "Spanish → English" as a label, every name with its capital, the same in the title, the hover bar and the
    /// download status, whatever comes before or after it.
    private var pairName: String { snapshot.pair?.labelName ?? "" }

    /// The language of the meeting, as it is written inside a sentence.
    private var sameLanguageName: String? {
        model.sourceLanguage.map { TranslationPair.name(of: $0) }
    }

    private func stack(_ lines: [CaptionLine], dimmed: Bool = false) -> some View {
        CaptionStack(lines: lines, size: size, showOriginal: showOriginal, isRightToLeft: isRightToLeft,
                     isOriginalRightToLeft: isOriginalRightToLeft, dimmed: dimmed, reduceMotion: reduceMotion, contrast: contrast,
                     sourceLanguage: snapshot.pair?.source, targetLanguage: snapshot.pair?.target,
                     speakers: speakers)
    }

    private var speakers: CaptionSpeakers { CaptionSpeakers(count: model.speakerCount, names: model.speakerNames) }
}

/// A state that needs a sentence and sometimes buttons: always the same layout, whatever the language.
/// The icon leads; the title, the explanation (wrapping) and the buttons share one text column.
private struct CaptionMessage<Action: View>: View {
    let size: CaptionTextSize
    let symbol: String?
    /// The symbol's colour: quiet grey for a hint, the status colour for a warning.
    let symbolColor: Color
    let title: Text
    let detail: String?
    /// A quiet waiting state ("Listening…", "Getting ready…"): the title is secondary, and the two share one layout.
    let isWaiting: Bool
    /// The symbol pulses (Listening, unless Reduce Motion is on).
    let pulses: Bool
    let action: Action
    @ViewLocalState private var detailWidth: CGFloat = 0

    init(size: CaptionTextSize, symbol: String?, symbolColor: Color = .secondary, title: Text, detail: String?,
         isWaiting: Bool = false, pulses: Bool = false, @ViewBuilder action: () -> Action) {
        self.size = size
        self.symbol = symbol
        self.symbolColor = symbolColor
        self.title = title
        self.detail = detail
        self.isWaiting = isWaiting
        self.pulses = pulses
        self.action = action()
    }

    /// The explanation as a panel paragraph (no hyphenation, no short last line), with each sentence that fits one line on
    /// a line of its own, measured at the detail font and the width of the text column.
    private func detailText(_ string: String) -> Text {
        let font = NSFont.systemFont(ofSize: detailSize)
        let broken = detailWidth > 0 ? string.breakingBeforeLastSentence(fittingIn: detailWidth, font: font) : string
        return Text(paragraph: broken)
    }

    private var titleSize: CGFloat { max(15, size.points * 0.75) }
    private var detailSize: CGFloat { max(13, size.points * 0.6) }

    var body: some View {
        // The icon sits level with the title (its first line), like the symbol of every other notice.
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: titleSize * 1.4)).foregroundStyle(symbolColor)
                        .symbolEffect(.pulse, options: .repeating, isActive: pulses)
                        .accessibilityHidden(true)
                } else {
                    // Vauta's sphere turning, as everywhere Vauta is getting something ready.
                    ThinkingOrb(diameter: titleSize * 1.2)
                }
            }
            .frame(width: titleSize * 1.8, height: titleSize * 1.4)
            VStack(alignment: .leading, spacing: 2) {
                title.font(.system(size: titleSize, weight: .semibold))
                    .foregroundStyle(isWaiting ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: titleSize * 1.4, alignment: .leading)
                if let detail {
                    detailText(detail).font(.system(size: detailSize)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !(Action.self == EmptyView.self) {
                    HStack(spacing: 8) { action }
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailWidth = $0 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // The card's content box starts lower than it ends (room for the hover bar); a message has no bar, so it is
        // lifted by half the difference and sits at the card's optical centre.
        .offset(y: -(CaptionTextSize.topPadding - CaptionTextSize.bottomPadding) / 2)
        .accessibilityElement(children: .contain)
    }
}

extension CaptionMessage where Action == EmptyView {
    init(size: CaptionTextSize, symbol: String?, symbolColor: Color = .secondary, title: Text, detail: String?,
         isWaiting: Bool = false, pulses: Bool = false) {
        self.init(size: size, symbol: symbol, symbolColor: symbolColor, title: title, detail: detail,
                  isWaiting: isWaiting, pulses: pulses) { EmptyView() }
    }
}

/// "Paused", on the captions that are still shown. A state, not a control: the outlined symbol (the one of the Paused
/// message), with its word when there is room, flat and with no capsule or shadow, so it never reads as a button
/// like the hover bar beside it.
private struct PausedBadge: View {
    /// A narrow panel has no room for the word: the symbol alone, still named for VoiceOver and the tooltip.
    var isCompact = false

    var body: some View {
        Group {
            if isCompact {
                Image(systemName: "pause.circle")
                    .font(.system(size: 20, weight: .regular))
                    .frame(width: 28)
                    .accessibilityLabel(Text("Paused"))
                    .help(Text("Paused"))
            } else {
                Label {
                    Text("Paused")
                } icon: {
                    Image(systemName: "pause.circle").font(.system(size: 16, weight: .regular))
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 6)
            }
        }
        .foregroundStyle(.secondary)
        .frame(height: 28)
        .accessibilityElement(children: .combine)
    }
}
