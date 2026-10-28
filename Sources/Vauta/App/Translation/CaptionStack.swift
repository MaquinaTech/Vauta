// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

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
struct CaptionStack: View {
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
