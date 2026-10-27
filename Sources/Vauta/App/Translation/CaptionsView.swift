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

/// The voices of the other participants, for the captions: from two voices on, each caption says who said it.
///
/// The name is drawn inline, at the start of the caption's own text, so a caption is never taller than its words and the
/// panel's room is shared by the layout that already exists. For that layout (which cuts a caption to its last lines and
/// pairs it with its original) to count the name's width, the caption's translation is given a marker of the name's
/// length first (`marked`), and the row replaces the marker by the real, tinted name when the caption is shown whole.
struct CaptionSpeakers: Equatable {
    var count = 0
    var names: [Int: String] = [:]

    /// The label of a caption: the voice's name, cut so it never takes the room of the sentence; nil when the
    /// recording has one voice only, or the caption has no speaker yet (a sentence still being spoken).
    func label(for line: CaptionLine, size: CaptionTextSize) -> CaptionSpeakerLabel? {
        guard count >= 2, let ordinal = line.speaker else { return nil }
        let full = names[ordinal] ?? MeetingSpeaker.defaultLabel(channel: .others, ordinal: ordinal)
        return CaptionSpeakerLabel(full: full, short: CaptionSpeakerName.short(full), ordinal: ordinal, size: size)
    }
}

struct CaptionSpeakerLabel: Equatable {
    let full: String
    let short: String
    let ordinal: Int
    /// The width the name takes, in bold at the size of the original line.
    let nameWidth: CGFloat

    /// The gap between the name and its text.
    static let gap: CGFloat = 8
    /// The name never takes more than this share of the row, so the sentence keeps most of it.
    static let maxShare: CGFloat = 0.4
    /// How much of the row sharing a column with the other names may take.
    static let sharedShare: CGFloat = 0.28

    init(full: String, short: String, ordinal: Int, size: CaptionTextSize) {
        self.full = full
        self.short = short
        self.ordinal = ordinal
        nameWidth = ceil((short as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size.originalPoints, weight: .bold)]).width)
    }

    /// The width of the name's column in a row `rowWidth` wide: what the translation gives up, so its lines (the first and
    /// the wrapped ones) all start at the same place.
    /// `shared` is the widest name of the stack: every caption uses the same column, so the texts line up under each other.
    /// A name wider than this share of the row does not hang beside the text (that would leave the sentence a few words
    /// per line, or cut the name): it stands on a line of its own above it.
    static let stackShare: CGFloat = 0.3
    /// The room between a stacked name and its text.
    static let stackedSpacing: CGFloat = 1

    /// Whether the names stand above their texts in a row `rowWidth` wide, given the widest name of the stack.
    static func stacks(in rowWidth: CGFloat, shared: CGFloat) -> Bool {
        rowWidth > 0 && shared > 0 && shared + gap > rowWidth * stackShare
    }

    /// The inset of the text of a caption: its name's column; a caption with no name among named ones uses the shared column.
    static func textInset(_ label: CaptionSpeakerLabel?, in rowWidth: CGFloat, shared: CGFloat) -> CGFloat {
        if stacks(in: rowWidth, shared: shared) { return 0 }
        if let label { return label.column(in: rowWidth, shared: shared) }
        guard shared > 0 else { return 0 }
        guard rowWidth > 0 else { return shared + gap }
        return min((rowWidth * sharedShare).rounded(.down), shared, (rowWidth * maxShare).rounded(.down)) + gap
    }

    func column(in rowWidth: CGFloat, shared: CGFloat) -> CGFloat {
        guard rowWidth > 0 else { return max(nameWidth, shared) + Self.gap }
        // Sharing widens a column only up to a smaller share of the row, so a narrow card never loses its text to a name
        // that is not even on screen; a name of its own may take more.
        let widened = max(nameWidth, min(shared, (rowWidth * Self.sharedShare).rounded(.down)))
        return min(widened, (rowWidth * Self.maxShare).rounded(.down)) + Self.gap
    }
}

/// Subtitle-style stack: the newest caption at the bottom, the room filled from the bottom up. Whole captions that
/// fit are shown whole. When the captions are taller than the room (long sentences wrap), the caption before the newest
/// never disappears: it keeps its last lines under an ellipsis (or from the start of its last sentence), and a
/// partial caption still being spoken leaves it at least one line. Older captions that do not fit whole run out at the
/// top, so no orphan tail of an old sentence stays and an original never stays without its translation.
private struct CaptionStack: View {
    let lines: [CaptionLine]
    let size: CaptionTextSize
    let showOriginal: Bool
    let isRightToLeft: Bool
    let isOriginalRightToLeft: Bool
    /// Paused: the translated lines are dimmed ("old"); the originals keep their contrast.
    let dimmed: Bool
    let reduceMotion: Bool
    let contrast: ColorSchemeContrast
    let sourceLanguage: Locale.Language?
    let targetLanguage: Locale.Language?
    let speakers: CaptionSpeakers

    /// The measured natural height of each caption, of its translation alone, of one line of the translation, and of the room they have.
    @ViewLocalState private var heights: [Int: CGFloat] = [:]
    @ViewLocalState private var translationHeights: [Int: CGFloat] = [:]
    @ViewLocalState private var lineHeight: CGFloat = 0
    @ViewLocalState private var room: CGFloat = 0
    /// The width the captions are laid out at, to know how many lines an original needs.
    @ViewLocalState private var rowWidth: CGFloat = 0

    /// What is shown: from which caption on, and how many lines of the translation of a caption that is too tall.
    private struct Shown: Equatable {
        var first = 0
        var limits: [Int: Int] = [:]
        /// The height the shown captions take.
        var used: CGFloat = 0
    }

    private var spacing: CGFloat { CaptionTextSize.rowSpacing(showOriginal: showOriginal) }

    /// One line of an original in this size.
    private var originalLineHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: size.originalPoints)
        return ceil(font.ascender - font.descender + font.leading)
    }

    /// The widest name of the captions that can be on screen (the room holds three): the column every caption puts its text in.
    private var sharedNameWidth: CGFloat { lines.suffix(3).compactMap { speakers.label(for: $0, size: size)?.nameWidth }.max() ?? 0 }

    /// The height of the name above a caption's text, when the names are stacked (a named caption only).
    private func nameLine(_ index: Int) -> CGFloat {
        guard CaptionSpeakerLabel.stacks(in: rowWidth, shared: sharedNameWidth), !lines[index].translation.isEmpty, speakers.label(for: lines[index], size: size) != nil else { return 0 }
        return originalLineHeight + CaptionSpeakerLabel.stackedSpacing
    }

    /// Where the text of a caption starts: after its speaker's name, or, for a caption with no name yet (a sentence still
    /// being spoken) among named ones, at the same column, so the stack has one left edge.
    private func textInset(of line: CaptionLine) -> CGFloat {
        CaptionSpeakerLabel.textInset(speakers.label(for: line, size: size), in: rowWidth, shared: sharedNameWidth)
    }

    private func context(line: CaptionLine) -> CaptionPairing.Context {
        CaptionPairing.Context(width: rowWidth, inset: textInset(of: line), size: size, isRightToLeft: isRightToLeft, isOriginalRightToLeft: isOriginalRightToLeft,
                               sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
    }

    /// The captions that fit the room (a caption that has not been measured counts as zero, so a new one never
    /// hides the others before it is laid out).
    private var shown: Shown {
        guard room > 0, lineHeight > 0, !lines.isEmpty else { return Shown() }
        let last = lines.count - 1
        func height(_ i: Int) -> CGFloat { heights[lines[i].id] ?? 0 }
        func translation(_ i: Int) -> CGFloat { min(translationHeights[lines[i].id] ?? 0, height(i)) }
        /// What a caption has besides its translation (the original under it).
        func extra(_ i: Int) -> CGFloat { height(i) - translation(i) - nameLine(i) }
        func count(_ i: Int) -> Int { translation(i) > 0 ? max(1, Int((translation(i) / lineHeight).rounded())) : 1 }
        func step(_ i: Int) -> CGFloat { translation(i) > 0 ? translation(i) / CGFloat(count(i)) : lineHeight }
        /// What a caption whose translation is cut to `n` lines keeps besides it: the original that goes with the
        /// translation's tail (a fragment is one line; whole sentences get the lines they need, and where even that does
        /// not fit, none: the caption is shown without its original).
        func cutExtra(_ i: Int, _ n: Int) -> CGFloat {
            let name = nameLine(i)
            guard showOriginal, extra(i) > 0 else { return name }
            guard n < count(i) else { return name + extra(i) }
            guard rowWidth > 0 else { return name + min(extra(i), CaptionTextSize.originalSpacing + originalLineHeight) }
            let pair = CaptionPairing.layout(translation: lines[i].translation, original: lines[i].original, lineLimit: n, originalLines: 1,
                                             showOriginal: true, context(line: lines[i]))
            if pair.dropsOriginal { return name }
            let used = min(pair.originalLines, CaptionTail.lineCount(of: pair.original, width: max(1, rowWidth - textInset(of: lines[i])), points: size.originalPoints,
                                                                     weight: .regular, language: sourceLanguage))
            return name + min(extra(i), CaptionTextSize.originalSpacing + CGFloat(used) * originalLineHeight)
        }
        /// How many lines of its translation fit in `available` (nil: not even one).
        func fitting(_ i: Int, _ available: CGFloat) -> Int? {
            for n in stride(from: count(i), through: 1, by: -1) where CGFloat(n) * step(i) + cutExtra(i, n) <= available + 0.001 {
                return n
            }
            return nil
        }

        var out = Shown(first: last)
        // The newest caption. While it is still being spoken it leaves the finished one before it one line.
        var available = room
        if last > 0, lines[last].state != .final { available = room - (cutExtra(last - 1, 1) + step(last - 1) + spacing) }
        var used = min(height(last), room)
        if height(last) > available + 0.5, translation(last) > 0 {
            let fit = fitting(last, available) ?? fitting(last, room) ?? 1
            if fit < count(last) {
                // The newest caption has to be cut: it gets all of the room (an older caption above a cut one would read
                // as continuous with it), and an ellipsis stands for the words before it.
                let whole = min(fitting(last, room) ?? fit, count(last) - 1)
                out.limits[last] = max(fit, whole)
                used = cutExtra(last, max(fit, whole)) + CGFloat(max(fit, whole)) * step(last)
            }
        }
        for index in stride(from: last - 1, through: 0, by: -1) {
            if out.limits[last] != nil { break }
            let remaining = room - used - spacing
            if height(index) <= remaining + 0.5 {
                used += spacing + height(index)
                out.first = index
                continue
            }
            // The first caption that does not fit whole keeps its last lines (under an ellipsis or from its last
            // sentence) with their original in the room that is left; older ones are dropped whole. With no room for a
            // translation line and its original the caption is dropped too: every translation shown is paired the same
            // way, a tail with no original would read as a missing line.
            if translation(index) > 0, let fit = fitting(index, remaining) {
                if fit < count(index) { out.limits[index] = fit }
                out.first = index
                used += spacing + cutExtra(index, fit) + CGFloat(fit) * step(index)
            }
            break
        }
        out.used = used
        return out
    }

    /// The room is sized for three lines of a font a little taller than the one drawn, so a bottom-aligned stack would
    /// leave the spare height above it. Half of it goes below instead: the margins above and below the captions are
    /// equal when the card is full, and the newest caption keeps its place as older ones arrive.
    private func centeringShift(_ shown: Shown) -> CGFloat {
        guard lineHeight > 0, room > 0 else { return 0 }
        var block = lineHeight * 3 + spacing * 2
        if showOriginal { block += (CaptionTextSize.originalSpacing + originalLineHeight) * 3 }
        // A card that is already full (less than a line to spare) is never lifted into the bar.
        guard room - shown.used >= lineHeight else { return 0 }
        // Older captions that did not fit whole were dropped, so what is shown can be much shorter than the room: the
        // spare room is shared evenly above and below, not left as an empty band on top.
        // The content box starts lower than it ends, so half the difference goes below as well: the gaps measured from
        // the card's edges are equal.
        if shown.first > 0 {
            let spare = room - shown.used
            return min(spare, (spare + CaptionTextSize.topPadding - CaptionTextSize.bottomPadding) / 2)
        }
        return min(max(0, room - block) / 2, max(0, room - shown.used))
    }

    var body: some View {
        let shown = shown
        // The captions are drawn in an overlay of a view that takes exactly the room it is given:
        // whatever does not fit never makes the card taller.
        Color.clear
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { room = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
            .background(alignment: .topLeading) { lineProbe }
            .overlay(alignment: .bottom) {
                VStack(alignment: .leading, spacing: spacing) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        let isShown = index >= shown.first
                        CaptionRow(line: line, size: size, showOriginal: showOriginal, isRightToLeft: isRightToLeft,
                                   isOriginalRightToLeft: isOriginalRightToLeft, dimmed: dimmed, contrast: contrast,
                                   sourceLanguage: sourceLanguage, targetLanguage: targetLanguage,
                                   speaker: speakers.label(for: line, size: size), nameWidth: sharedNameWidth,
                                   translationLineLimit: isShown ? shown.limits[index] : nil,
                                   measureHeight: { heights[line.id] = $0 }, measureTranslation: { translationHeights[line.id] = $0 })
                        // A caption that does not fit is out of sight and out of VoiceOver; it comes back when there is room.
                        .opacity(isShown ? 1 : 0)
                        .accessibilityHidden(!isShown)
                        .transition(reduceMotion ? .opacity
                                    : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .bottomLeading)
                .offset(y: -centeringShift(shown))
            }
            .clipped()
            // Only a new or removed caption animates; text changing inside a caption never does.
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: lines.map(\.id))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: shown.first)
    }

    /// One line of the translation, laid out out of sight, to know how tall a line is in this size and font. The
    /// probe has a character of the caption's script: Japanese, Chinese and Korean lines are taller than Latin ones.
    private var lineProbe: some View {
        Text(verbatim: CaptionText.probe(for: lines.last { !$0.translation.isEmpty }?.translation ?? ""))
            .font(.system(size: size.points, weight: .semibold))
            .fixedSize()
            .hidden()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { lineHeight = $0 }
            .accessibilityHidden(true)
    }
}

private struct CaptionRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let line: CaptionLine
    let size: CaptionTextSize
    let showOriginal: Bool
    let isRightToLeft: Bool
    let isOriginalRightToLeft: Bool
    let dimmed: Bool
    let contrast: ColorSchemeContrast
    let sourceLanguage: Locale.Language?
    let targetLanguage: Locale.Language?
    /// Who said it, when the recording tells several voices apart. Shown at the start of the caption, in the same line as
    /// its words, so the caption's height is whatever the text measures (it is never a row of its own).
    var speaker: CaptionSpeakerLabel?
    /// The widest name of the stack, which sets the column of every caption.
    var nameWidth: CGFloat = 0
    /// The caption is taller than the room: only its last lines are shown, the words before them are an ellipsis.
    var translationLineLimit: Int?
    /// Reports the natural height of the caption and of its translation (an unseen copy is measured, so showing fewer
    /// lines never changes what the stack knows about this caption).
    let measureHeight: (CGFloat) -> Void
    let measureTranslation: (CGFloat) -> Void

    @ViewLocalState private var width: CGFloat = 0

    var body: some View {
        content(lineLimit: translationLineLimit)
            .background(alignment: .top) {
                content(lineLimit: nil, measuring: true)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measureHeight($0) }
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: accessibilityText))
    }

    private func pairing(lineLimit: Int?, originalLines: Int, showOriginal: Bool) -> CaptionPairLayout {
        CaptionPairing.layout(translation: line.translation, original: line.original, lineLimit: lineLimit, originalLines: originalLines,
                              showOriginal: showOriginal,
                              CaptionPairing.Context(width: width, inset: CaptionSpeakerLabel.textInset(speaker, in: width, shared: nameWidth), size: size, isRightToLeft: isRightToLeft, isOriginalRightToLeft: isOriginalRightToLeft,
                                                     sourceLanguage: sourceLanguage, targetLanguage: targetLanguage))
    }

    private func content(lineLimit: Int?, measuring: Bool = false) -> some View {
        // A translation cut to its last lines is paired with a one-line original that is cut the same way.
        let originalLines = (lineLimit != nil && !measuring) ? 1 : 2
        let wantsOriginal = showOriginal
        // The caption's natural height is measured on the whole text: the pairing below cuts sentences, and a measure that
        // followed it would shrink the caption it is deciding about.
        let pair = measuring ? CaptionPairLayout(translation: line.translation, original: line.original, originalLines: 2)
                             : pairing(lineLimit: lineLimit, originalLines: originalLines, showOriginal: wantsOriginal)
        // A cut that shows whole sentences whose original would not fit beside it shows no original at all, never a fragment.
        let showsOriginal = wantsOriginal && !pair.dropsOriginal
        return VStack(alignment: .leading, spacing: CaptionTextSize.originalSpacing) {
            if !line.translation.isEmpty {
                // Right-to-left text hugs the trailing edge too, so the whole line is laid out in its own direction.
                translationRow(pair.translation, lineLimit: lineLimit, measuring: measuring)
                    .environment(\.layoutDirection, isRightToLeft ? .rightToLeft : .leftToRight)
                    // A caption still being spoken updates in place; Apple's text replaced by the server's cross-fades.
                    .contentTransition(.opacity)
                    .transaction(value: line.translation) { transaction in
                        transaction.animation = (line.isRefined && !reduceMotion) ? .easeInOut(duration: 0.3) : nil
                    }
            }
            if showsOriginal {
                CaptionText.view(pair.original, language: sourceLanguage)
                    .font(.system(size: size.originalPoints))
                    // A tier of its own: regular weight in the secondary colour, apart from the dimmed partial translation.
                    .foregroundStyle(contrast == .increased ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(pair.originalLines)
                    .multilineTextAlignment(originalAlignment == .trailing ? .trailing : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, originalInset)
                    .frame(maxWidth: .infinity, alignment: originalAlignment)
                    .environment(\.layoutDirection, isOriginalRightToLeft ? .rightToLeft : .leftToRight)
                    .animation(nil, value: line.original)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { if !measuring { width = $0 } }
    }

    /// The translation; with a speaker, the name stands in a column of its own and every line of the text, the wrapped ones
    /// too, starts after it (a hanging indent), so the names read as a column and each turn is easy to find.
    @ViewBuilder private func translationRow(_ shown: String, lineLimit: Int?, measuring: Bool) -> some View {
        let text = CaptionText.view(CaptionTail.joiningEllipsis(shown), language: targetLanguage)
            .font(.system(size: size.points, weight: .semibold))
            .foregroundStyle(translationStyle)
            .lineLimit(lineLimit)
            .truncationMode(.head)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if measuring { measureTranslation($0) } }
        if let speaker, CaptionSpeakerLabel.stacks(in: width, shared: nameWidth) {
            // A name too wide to hang beside the text stands above it, so the sentence has the whole row.
            VStack(alignment: .leading, spacing: CaptionSpeakerLabel.stackedSpacing) {
                nameLabel(speaker)
                    .frame(maxWidth: .infinity, alignment: .leading)
                text.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let speaker {
            let column = speaker.column(in: width, shared: nameWidth)
            HStack(alignment: .firstTextBaseline, spacing: CaptionSpeakerLabel.gap) {
                nameLabel(speaker)
                    .frame(width: column - CaptionSpeakerLabel.gap, alignment: .leading)
                text.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // A caption with no name yet among named ones starts at their text column.
            text.padding(.leading, CaptionSpeakerLabel.textInset(nil, in: width, shared: nameWidth))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The speaker's name, in the voice's colour. A generic name ("Speaker 3") that does not fit loses its middle, never its
    /// number: the number is what tells two unnamed voices apart.
    private func nameLabel(_ speaker: CaptionSpeakerLabel) -> some View {
        Text(speaker.short)
            .font(.system(size: size.originalPoints, weight: .bold))
            .foregroundStyle(contrast == .increased ? Color.primary : Channel.others.tint(ordinal: speaker.ordinal))
            .lineLimit(1)
            .truncationMode(speaker.short.last?.isNumber == true ? .middle : .tail)
    }

    /// The original sits on the same edge as its translation (in its own writing direction), so the pair reads
    /// as one block instead of zig-zagging across the card when one is right-to-left and the other is not.
    /// The original starts where its translation's text does (after the speaker column), so a stack of named captions has
    /// one left edge; with the two in opposite directions it keeps to its own edge.
    private var originalInset: CGFloat {
        guard isRightToLeft == isOriginalRightToLeft else { return 0 }
        return CaptionSpeakerLabel.textInset(speaker, in: width, shared: nameWidth)
    }

    private var originalAlignment: Alignment {
        isRightToLeft == isOriginalRightToLeft ? .leading : .trailing
    }

    /// Final text is fully opaque; text still being spoken or translated is dimmed.
    private var translationStyle: Color {
        // Increase Contrast: nothing is dimmed.
        if contrast == .increased { return line.state == .final || dimmed ? .primary : Color.primary.opacity(0.85) }
        if dimmed { return Color.primary.opacity(0.6) }
        return line.state == .final ? .primary : Color.primary.opacity(0.7)
    }

    private var accessibilityText: String {
        guard let speaker, !line.translation.isEmpty else { return line.translation.isEmpty ? line.original : line.translation }
        let text = line.translation
        return String(localized: "\(speaker.full): \(text)", comment: "VoiceOver for a caption: who said it, then the translated sentence")
    }
}

/// What a caption's translation and original show together when the translation is cut to `lineLimit` lines: the two
/// start at the same place. Used by the row that draws them and by the stack that reserves their height.
struct CaptionPairLayout {
    var translation: String
    var original: String
    /// The lines the original may take.
    var originalLines: Int
    /// The translation is whole sentences but their original does not fit beside them: no original is shown.
    var dropsOriginal = false
}

enum CaptionPairing {
    struct Context {
        var width: CGFloat
        /// What the translation gives up of the width (the column of a speaker's name); the original has the whole width.
        var inset: CGFloat = 0
        var size: CaptionTextSize
        var isRightToLeft: Bool
        var isOriginalRightToLeft: Bool
        var sourceLanguage: Locale.Language?
        var targetLanguage: Locale.Language?

        /// The width the original has: it starts at the translation's own edge (after the speaker column) when both are
        /// written in the same direction, and has the whole row otherwise.
        var originalWidth: CGFloat { isRightToLeft == isOriginalRightToLeft ? max(1, width - inset) : width }
    }

    /// The most lines an original takes beside whole sentences of the translation (as many as an uncut caption shows).
    static let wholeSentenceLines = 2

    /// What the pair shows. When one of them is cut to its last sentences, the other loses the same number of sentences,
    /// and when the translation is cut under an ellipsis, the original keeps about the same share of its words under an
    /// ellipsis too, so neither carries a sentence the other lacks. A translation that is whole sentences gets as many
    /// lines of original as those sentences need (up to `wholeSentenceLines`); where even that does not fit, the original
    /// is dropped rather than shown as a fragment under whole sentences.
    static func layout(translation fullTranslation: String, original fullOriginal: String, lineLimit: Int?, originalLines: Int,
                       showOriginal: Bool, _ c: Context) -> CaptionPairLayout {
        var translation = fullTranslation
        if let lineLimit, c.width > 0, !c.isRightToLeft {
            translation = CaptionTail.lastLines(of: fullTranslation, lines: lineLimit, width: max(1, c.width - c.inset), points: c.size.points,
                                                language: c.targetLanguage)
        }
        func tail(_ text: String, lines: Int) -> String {
            guard c.width > 0, !c.isOriginalRightToLeft else { return text }
            return CaptionTail.lastLines(of: text, lines: lines, width: c.originalWidth, points: c.size.originalPoints, weight: .regular,
                                         language: c.sourceLanguage)
        }
        guard showOriginal, !fullTranslation.isEmpty, c.width > 0, !c.isRightToLeft, !c.isOriginalRightToLeft else {
            return CaptionPairLayout(translation: translation, original: showOriginal ? tail(fullOriginal, lines: originalLines) : fullOriginal,
                                     originalLines: originalLines)
        }
        var original = fullOriginal
        var wholeSentences = false
        if translation != fullTranslation {
            if translation.hasPrefix("…") {
                let kept = String(translation.dropFirst())
                if let dropped = CaptionTail.sentencesDropped(by: kept, from: fullTranslation) {
                    // The translation starts at a sentence: the original drops the same whole sentences, marked the same way.
                    let rest = CaptionTail.droppingSentences(dropped, of: original)
                    original = rest
                    wholeSentences = true
                } else {
                    original = CaptionTail.keepingShare(of: original, share: Double(translation.count - 1) / Double(max(1, fullTranslation.count)))
                }
            } else {
                let dropped = CaptionTail.sentenceCount(of: fullTranslation) - CaptionTail.sentenceCount(of: translation)
                original = CaptionTail.droppingSentences(dropped, of: original)
                wholeSentences = true
            }
        }
        var lines = originalLines
        if wholeSentences, lineLimit != nil {
            lines = max(originalLines, wholeSentenceLines)
            let needed = CaptionTail.lineCount(of: original, width: c.originalWidth, points: c.size.originalPoints, weight: .regular, language: c.sourceLanguage)
            if needed > lines { return CaptionPairLayout(translation: translation, original: original, originalLines: 0, dropsOriginal: true) }
        }
        let cut = tail(original, lines: lines)
        if translation == fullTranslation, !cut.hasPrefix("…"), cut != original {
            // Only the original was cut, at a sentence: the translation starts at the same sentence.
            let dropped = CaptionTail.sentenceCount(of: original) - CaptionTail.sentenceCount(of: cut)
            translation = CaptionTail.droppingSentences(dropped, of: translation)
        }
        return CaptionPairLayout(translation: translation, original: cut, originalLines: lines)
    }
}

/// The end of a caption that is taller than the room: the last words that fit in `lines` lines. It starts at the
/// beginning of a sentence when the last sentence fits (no ellipsis: it is a clean cut), otherwise at a word, after an
/// ellipsis; never on punctuation ("…? Reportons").
enum CaptionTail {
    /// A word joiner after a leading ellipsis, so the line may not break between "…" and the word: the ellipsis never ends
    /// a line on its own.
    static func joiningEllipsis(_ text: String) -> String {
        text.hasPrefix("…") && !text.hasPrefix("…\u{2060}") ? "…\u{2060}" + text.dropFirst() : text
    }

    /// How many lines `text` takes at `width`, measured in the script of the text.
    static func lineCount(of text: String, width: CGFloat, points: CGFloat, weight: NSFont.Weight = .semibold,
                          language: Locale.Language? = nil) -> Int {
        let font = NSFont.systemFont(ofSize: points, weight: weight)
        let script = language.flatMap(CaptionText.unspacedScript)
        func height(_ string: String) -> CGFloat {
            let laidOut = script?.protecting(string) ?? string
            return (laidOut as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                      options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
        }
        return max(1, Int((height(text) / max(1, height(CaptionText.probe(for: text)))).rounded()))
    }

    static func lastLines(of text: String, lines: Int, width: CGFloat, points: CGFloat, weight: NSFont.Weight = .semibold,
                          language: Locale.Language? = nil) -> String {
        let font = NSFont.systemFont(ofSize: points, weight: weight)
        let script = language.flatMap(CaptionText.unspacedScript)
        func measured(_ string: String) -> CGSize {
            let laidOut = script?.protecting(string) ?? string
            return (laidOut as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                      options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).size
        }
        // The line is measured in the script of the text: Japanese lines are taller than Latin ones.
        let lineHeight = measured(CaptionText.probe(for: text)).height
        func lineCount(_ string: String) -> Int { max(1, Int((measured(string).height / lineHeight).rounded())) }
        guard lineCount(text) > lines else { return text }

        let allStarts = wordStarts(of: text, wholeWordsOnly: false)
        guard !allStarts.isEmpty else { return text }
        // Japanese has no spaces: the tail starts at a word (after a clause mark or a particle), never inside a run of kanji.
        let wordsOnly = wordStarts(of: text, wholeWordsOnly: true)
        let starts = wordsOnly.isEmpty ? allStarts : wordsOnly
        /// The first of `candidates` (the most text kept) whose text, after `prefix`, fits.
        func firstFitting(_ candidates: [String.Index], prefix: String) -> String.Index? {
            guard let last = candidates.last, lineCount(prefix + text[last...]) <= lines else { return nil }
            var low = 0, high = candidates.count - 1
            while low < high {
                let mid = (low + high) / 2
                if lineCount(prefix + text[candidates[mid]...]) <= lines { high = mid } else { low = mid + 1 }
            }
            return candidates[low]
        }
        let sentenceStarts = starts.filter { isSentenceStart($0, in: text) }
        // The tail starts at a sentence whenever the last sentence(s) fit the lines given, with no fragment of the sentence
        // before it; only when even the last sentence is too long does the tail start at a word under an ellipsis.
        if let start = firstFitting(sentenceStarts, prefix: "") { return String(text[start...]) }
        if let start = firstFitting(starts, prefix: "…") ?? firstFitting(allStarts, prefix: "…") { return "…" + text[start...] }
        return "…" + text[starts[starts.count - 1]...]
    }

    /// The positions where a sentence of `text` begins (the first one included): after a full stop, question or
    /// exclamation mark and a space (and not before a lowercase letter, as in "e.g. this"), or right after a
    /// full-width one, which leaves no space.
    static func sentenceStarts(in text: String) -> [String.Index] {
        var out = [text.startIndex]
        let enders: Set<Character> = [".", "?", "!", "。", "？", "！"]
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if enders.contains(character), next < text.endIndex {
                var after = next
                while after < text.endIndex, text[after] == " " || text[after] == "\u{00A0}" { after = text.index(after: after) }
                let fullWidth = "。？！".contains(character)
                if after < text.endIndex, fullWidth || after > next, !text[after].isLowercase { out.append(after) }
            }
            index = next
        }
        return out
    }

    /// How many whole sentences of `full` come before `tail`, when `tail` is its end and starts at a sentence (nil when
    /// it starts inside one, or is not its end).
    static func sentencesDropped(by tail: String, from full: String) -> Int? {
        guard !tail.isEmpty, tail != full, full.hasSuffix(tail) else { return nil }
        let start = full.index(full.endIndex, offsetBy: -tail.count)
        return sentenceStarts(in: full).firstIndex(of: start)
    }

    static func sentenceCount(of text: String) -> Int { sentenceStarts(in: text).count }

    /// `text` without its first `count` sentences (all of it when it has fewer than that many plus one).
    static func droppingSentences(_ count: Int, of text: String) -> String {
        let starts = sentenceStarts(in: text)
        guard count > 0, count < starts.count else { return text }
        return String(text[starts[count]...])
    }

    /// About `share` of the end of `text`, from a word, under an ellipsis (the whole text when the share is nearly all of it).
    static func keepingShare(of text: String, share: Double) -> String {
        guard share < 0.95 else { return text }
        let target = Int((Double(text.count) * (1 - share)).rounded())
        let starts = wordStarts(of: text, wholeWordsOnly: true)
        let candidates = starts.isEmpty ? wordStarts(of: text, wholeWordsOnly: false) : starts
        guard let start = candidates.first(where: { text.distance(from: text.startIndex, to: $0) >= target }) else { return text }
        return "…" + text[start...]
    }

    private static let closing: Set<Character> = Set("?!.,;:)]}»”’…、。，．！？；：）］｝」』〉》%")
    private static let sentenceEnd: Set<Character> = Set(".?!。？！…")

    /// Where the shown part may begin: after a space (or at any character when the text has no spaces), never on
    /// closing punctuation or a character that may not start a line.
    private static func wordStarts(of text: String, wholeWordsOnly: Bool) -> [String.Index] {
        let spaced = text.contains(" ")
        let japanese = wholeWordsOnly && text.unicodeScalars.contains { (0x3040...0x309F).contains($0.value) }
        func isKana(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { (0x3040...0x309F).contains($0.value) } }
        func isHan(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { (0x30A0...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) } }
        var out: [String.Index] = []
        for index in text.indices.dropFirst() {
            let character = text[index]
            if spaced {
                guard text[text.index(before: index)] == " ", character != " " else { continue }
            }
            if closing.contains(character) || CaptionText.UnspacedScript.japanese.cannotStartLine(character) { continue }
            if japanese {
                let previous = text[text.index(before: index)]
                // Inside a run of kanji or katakana ("金|曜日") or of hiragana, a start would cut a word.
                if isHan(character), isHan(previous) { continue }
                if isKana(character), isKana(previous) { continue }
                if isKana(character), isHan(previous), !"、。，".contains(previous) { continue }
            }
            out.append(index)
        }
        return out
    }

    /// The start of a sentence: the character before it (ignoring spaces) ends one.
    private static func isSentenceStart(_ index: String.Index, in text: String) -> Bool {
        var before = index
        while before > text.startIndex {
            before = text.index(before: before)
            if text[before] == " " || text[before] == "\u{00A0}" { continue }
            return sentenceEnd.contains(text[before])
        }
        return false
    }
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
                    ProgressView().controlSize(.regular)
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

/// The small bar that appears when the pointer is over the panel.
struct CaptionControls: View {
    let model: LiveTranslationModel
    /// The panel is wide enough to say in words how the server is doing.
    var showsStatusText = false

    var body: some View {
        @Bindable var preferences = model.preferences
        HStack(spacing: 2) {
            RefinementIndicator(status: model.refinementStatus, showsText: showsStatusText)
            languageMenu
            Divider().frame(height: 16).padding(.horizontal, 4)
            GlyphMenuButton(symbol: "textformat.size", font: .system(size: 12, weight: .semibold), size: 24) {
                CaptionTextSize.allCases.map { size in
                    .item(size.title, checked: preferences.captionTextSize == size) { preferences.captionTextSize = size }
                }
            }
            .help(Text("Change the text size"))
            .accessibilityLabel(Text("Text Size"))

            iconButton("character.textbox",
                       label: Text("Show Original Words"),
                       help: preferences.captionShowOriginal ? Text("Hide the original words") : Text("Show the original words"),
                       selected: preferences.captionShowOriginal) {
                preferences.captionShowOriginal.toggle()
            }
            iconButton(isPaused ? "play.fill" : "pause.fill",
                       label: isPaused ? Text("Resume Translation") : Text("Pause Translation"),
                       help: isPaused ? Text("Resume the translation") : Text("Pause the translation")) {
                model.setPaused(!isPaused)
            }
            iconButton("xmark", label: Text("Turn Off Live Translation"),
                       help: Text("Turn off Live Translation (\(model.hotKeyText))")) { model.setEnabled(false) }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        // Opaque: the captions underneath must not show through the controls. The 1 pt rim is a shape behind the
        // fill (a stroke drawn over the menus left stray ticks at both ends).
        .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
        .background(Capsule().fill(Color.primary.opacity(0.14)).padding(-1))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }

    /// Paused by the user, or showing the paused state.
    private var isPaused: Bool { model.showsPaused }

    private var pairName: String { model.snapshot.pair?.labelName ?? "" }

    private var languageMenu: some View {
        Menu {
            TranslationTargetPicker(model: model)
        } label: {
            // The chevron is part of the text (a menu label turns separate views into an icon before the title), a clear gap
            // after the name like the chips of the panel; the menu's own sat against the last letter.
            (Text(verbatim: model.pairName() ?? String(localized: "Language", comment: "Captions panel: language menu title"))
                + Text(verbatim: "\u{2004}")
                + Text(Image(systemName: "chevron.down")).font(.system(size: 8, weight: .semibold)).foregroundColor(.secondary))
                .padding(.horizontal, 4)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(Text("Choose the language to translate into"))
        .accessibilityLabel(Text("Translate into"))
        .accessibilityValue(Text(verbatim: pairName))
    }

    private func iconButton(_ symbol: String, label: Text, help: Text? = nil, selected: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .symbolVariant(selected ? .fill : .none)
                .imageScale(.medium)
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 24)
                .background(selected ? Color.accentColor.opacity(0.22) : .clear, in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// How the model server's refinement is going, in the hover bar: a symbol (and, when there is room, words).
/// Silent otherwise: nothing here is an alert, and Apple's caption always stays when the server can't help.
struct RefinementIndicator: View {
    let status: RefinementStatus
    let showsText: Bool

    /// What the indicator says for a status; nil when it has nothing to say.
    struct Content {
        let symbol: String
        /// A few words, for the bar and Settings.
        let text: String
        /// The full explanation, for the tooltip and VoiceOver.
        let help: String

        init?(_ status: RefinementStatus) {
            switch status {
            case .improved:
                symbol = "sparkles"
                text = String(localized: "Improved by your model server", comment: "Captions panel: the model server improved the latest translation")
                help = String(localized: "Your model server improved the latest sentence. Its version is the one saved.",
                              comment: "Captions panel tooltip and VoiceOver: the model server improved the latest translation")
            case .unavailable:
                // Calm and secondary: the server was not reached (a minus circle reads as "removed" on macOS).
                symbol = "exclamationmark.circle"
                text = String(localized: "Model server didn’t answer", comment: "Captions panel and Settings: the model server did not answer in time, so Apple's translation is shown")
                help = String(localized: "Your model server didn’t answer in time, so Apple’s translation stays.",
                              comment: "Captions panel tooltip and VoiceOver: the model server did not answer in time")
            case .off, .active:
                return nil
            }
        }
    }

    private var content: Content? { Content(status) }

    var body: some View {
        if let content {
            HStack(spacing: 4) {
                Image(systemName: content.symbol).foregroundStyle(.secondary).frame(width: 24, height: 24)
                if showsText {
                    Text(content.text).foregroundStyle(.secondary).lineLimit(1).padding(.trailing, 2)
                }
            }
            .help(Text(content.help))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(content.help))
            Divider().frame(height: 16).padding(.horizontal, 4)
        }
    }
}

/// Caption text tagged with the language it is written in, so lines break by that language's rules: Japanese and
/// Chinese text is laid out by the language of the caption, not by the language of the app. Latin text is left
/// untagged (a tag would also switch hyphenation on).
enum CaptionText {
    static func view(_ string: String, language: Locale.Language?) -> Text {
        guard let language, Self.unspacedScript(language) != nil else { return Text(verbatim: string) }
        return Text(attributed(string, language: language))
    }

    /// The same text as an attributed string, to put something before it in the same line.
    static func attributed(_ string: String, language: Locale.Language?) -> AttributedString {
        guard let language, let script = Self.unspacedScript(language) else { return AttributedString(string) }
        var text = AttributedString(script.protecting(string))
        text.languageIdentifier = language.minimalIdentifier
        return text
    }

    /// What one line is measured with: "Ag" and, for text in another script, its first character, so the line has
    /// the height of that script's lines (Japanese, Chinese and Korean fall back to a taller font).
    static func probe(for text: String) -> String {
        let other = text.first { character in character.unicodeScalars.contains { $0.value >= 0x2E80 } }
        return "Ag" + (other.map(String.init) ?? "")
    }

    enum UnspacedScript {
        case japanese, chinese, korean

        /// A small kana, the long-vowel mark or the iteration mark: a line never starts with it.
        func cannotStartLine(_ character: Character) -> Bool { Self.noLineStart.contains(character) }

        /// Word joiners where a line must not break: before a small kana, the long-vowel mark and the iteration mark
        /// (Japanese), and after a demonstrative (这, 那, 每, 该) so it stays with its measure word (Chinese).
        func protecting(_ string: String) -> String {
            let joiner: Character = "\u{2060}"
            if self == .korean { return Self.tyingBoundNouns(string) }
            let characters = Array(string)
            guard characters.count > 1 else { return string }
            let tiedEnding = self == .japanese ? Self.sentenceEndings(in: characters).union(Self.inflections(in: characters)) : []
            var out = ""
            for (index, character) in characters.enumerated() {
                if index > 0, tiedEnding.contains(index) || needsJoinerBefore(character, after: characters[index - 1]) {
                    out.append(joiner)
                }
                out.append(character)
            }
            return out
        }

        /// Positions that get a joiner before them so a Japanese sentence never ends with a stray run of kana: the
        /// last hiragana before 。！？ (up to five) stay together, so the verb ending "しましょう。" moves as one unit.
        private static func sentenceEndings(in characters: [Character]) -> Set<Int> {
            func isHiragana(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { (0x3041...0x309F).contains($0.value) } }
            var positions = Set<Int>()
            for (index, character) in characters.enumerated() where "。！？".contains(character) && index > 0 {
                var start = index
                while start > 0, index - start < 5, isHiragana(characters[start - 1]) { start -= 1 }
                guard start < index else { continue }
                // The kanji stem before them ("延期" of "延期しましょう") stays too, so the verb is never cut.
                var stem = start
                while stem > 0, start - stem < 3, (0x3400...0x9FFF).contains(characters[stem - 1].unicodeScalars.first?.value ?? 0) { stem -= 1 }
                start = stem
                // A particle before the stem ("に延期") stays with the word before it (a line never starts with a particle);
                // the line may still break after it, so a long phrase never becomes one chunk too wide for the line.
                if start > 0, "でをにがはもと".contains(characters[start - 1]) { positions.insert(start - 1) }
                for position in (start + 1)...index { positions.insert(position) }
            }
            return positions
        }

        /// Hiragana that follow a kanji (okurigana and inflection: "確認する", "延期し") stay with it, up to three, so a
        /// line never starts with "る" or "し". A particle after a kanji is tied the same way.
        private static func inflections(in characters: [Character]) -> Set<Int> {
            func isHiragana(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { (0x3041...0x309F).contains($0.value) } }
            func isKanji(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains($0.value) } }
            var positions = Set<Int>()
            for index in characters.indices where isKanji(characters[index]) {
                guard index + 1 < characters.count, isHiragana(characters[index + 1]) else { continue }
                // The kanji stem before the hiragana (up to three) is one word with them: "確認する" is never cut.
                var stem = index
                while stem > 0, index - stem < 2, isKanji(characters[stem - 1]) { stem -= 1 }
                for position in stem..<index { positions.insert(position + 1) }
                var next = index + 1
                while next < characters.count, next - index <= 3, isHiragana(characters[next]) {
                    positions.insert(next)
                    next += 1
                }
            }
            return positions
        }

        /// Korean bound nouns (수, 것, 때, 줄, 데) stay with the word before them, and 있다/없다 after 수 with 수:
        /// "주실 수 있나요?" is not split. The spaces become no-break spaces.
        private static func tyingBoundNouns(_ string: String) -> String {
            let bound: Set<String> = ["수", "것", "때", "줄", "데"]
            let words = string.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard words.count > 1 else { return string }
            var out = words[0]
            for index in 1..<words.count {
                let word = words[index]
                let core = word.trimmingCharacters(in: .punctuationCharacters)
                let previousCore = words[index - 1].trimmingCharacters(in: .punctuationCharacters)
                let tied = !out.isEmpty && !word.isEmpty
                    && (bound.contains(core) || (previousCore == "수" && (word.hasPrefix("있") || word.hasPrefix("없"))))
                out += (tied ? "\u{00A0}" : " ") + word
            }
            return out
        }

        private func needsJoinerBefore(_ character: Character, after previous: Character) -> Bool {
            if previous == " " || previous == "\u{00A0}" || previous == "\u{2060}" { return false }
            switch self {
            case .japanese: return Self.noLineStart.contains(character) || Self.numberWithCounter(character, after: previous)
            case .chinese:
                return (Self.demonstratives.contains(previous) && character.unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains($0.value) })
                    || Self.numberWithCounter(character, after: previous)
            case .korean: return false
            }
        }

        /// A number stays with its counter ("3分", "2週") and with the ordinal mark before it ("第2").
        private static func numberWithCounter(_ character: Character, after previous: Character) -> Bool {
            if previous.isASCII, previous.isNumber {
                return character.unicodeScalars.allSatisfy { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) }
            }
            return previous == "第" && character.isASCII && character.isNumber
        }

        private static let noLineStart: Set<Character> = Set("ぁぃぅぇぉっゃゅょゎゕゖァィゥェォッャュョヮヵヶー々ゝゞヽヾ")
        private static let demonstratives: Set<Character> = Set("这那每该")
    }

    static func unspacedScript(_ language: Locale.Language) -> UnspacedScript? {
        switch language.languageCode?.identifier {
        case "ja": .japanese
        case "zh": .chinese
        case "ko": .korean
        default: nil
        }
    }
}
