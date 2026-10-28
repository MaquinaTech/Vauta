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

extension String {
    /// Written in kana or Han characters, which have no spaces between words and break between characters.
    var usesUnspacedScript: Bool {
        unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) }
    }

    /// The same sentence without its closing full stop, for a title ("No system audio is arriving." becomes a title);
    /// a question or exclamation mark and an ellipsis stay.
    var withoutTerminalPunctuation: String {
        guard let last, last == "." || last == "。", !hasSuffix("..") else { return self }
        return String(dropLast())
    }

    /// Keeps a paragraph from breaking badly: the last words stay together (never one word alone on the last
    /// line) and a short word (an article, a preposition, "¿Ha") never ends a line, because it joins the word
    /// after it with a no-break space. Scripts without spaces keep a number with its counter ("1:30後に") and the
    /// last few characters together with word joiners.
    var avoidingWidow: String { avoidingWidow(pathOnItsOwnLine: false) }

    /// With `pathOnItsOwnLine` (a panel message, whose line is narrow and known) a path in System Settings that fits one
    /// line starts a line of its own, so it is read whole instead of being split after its first arrow.
    ///
    /// A short sentence that follows another one is tied into one unbreakable run by default ("Nothing is uploaded."); a
    /// text that is a few lines long on its own (the consent notice) passes `tyingSentences: false` so it fills its lines.
    func avoidingWidow(pathOnItsOwnLine: Bool, tyingSentences: Bool = true, font: NSFont.TextStyle = .caption1, width: CGFloat = PanelMetrics.bannerTextWidth) -> String {
        // Hangul is written with spaces and breaks at them: a path tied with no-break spaces would be a chunk too long
        // for the line and be split inside a word, so Korean only keeps each arrow with the step before it.
        if containsHangul {
            let plain = replacingOccurrences(of: "\u{2060}", with: "")
            // A path that fits one line starts a line of its own, as in the other languages.
            let placed = pathOnItsOwnLine ? plain.puttingSettingsPathOnItsOwnLine(font: .preferredFont(forTextStyle: font), width: width) : plain
            return placed.replacingOccurrences(of: "[ \u{00A0}]*\u{2192}[ \u{00A0}]*", with: "\u{00A0}\u{2192} ", options: .regularExpression)
        }
        let protected = protectingSettingsPaths
        let paths = pathOnItsOwnLine ? protected.puttingSettingsPathOnItsOwnLine(font: .preferredFont(forTextStyle: font), width: width) : protected.breakingBeforeOrphanedSettingsPath
        return paths.split(separator: "\n", omittingEmptySubsequences: false).map { String($0).joiningForWidow(tyingSentences: tyingSentences) }.joined(separator: "\n")
    }

    /// The path "System Settings → … → Microphone" starts a line of its own when it fits one line (the words before it,
    /// with a lead-in such as "unter" or "in", end the line above); a path too long for a line keeps its steps whole and
    /// breaks only after an arrow. The width is measured with the real font.
    fileprivate func puttingSettingsPathOnItsOwnLine(font: NSFont, width lineWidth: CGFloat) -> String {
        let arrow = "\u{2192}"
        // The path starts at its first step: the name of a place that comes right before the first arrow ("System
        // Settings", "Privacy & Security", "개인정보 보호 및 보안"), with its opening quote when it has one.
        guard !contains("\n"), let firstArrow = range(of: arrow), let lastArrow = range(of: arrow, options: .backwards) else { return self }
        var head = self[..<firstArrow.lowerBound]
        while let last = head.last, last == " " || last == "\u{00A0}" || last == "\u{2060}" { head = head.dropLast() }
        let closers: Set<Character> = ["”", "」", "\"", "』", "’", ")"]
        if let last = head.last, closers.contains(last) { head = head.dropLast() }
        var firstStep: String.Index?
        for name in SettingsPathNames.all.sorted(by: { $0.count > $1.count }) {
            for candidate in [SettingsPathNames.tied(name), name] where head.hasSuffix(candidate) {
                let begin = head.index(head.endIndex, offsetBy: -candidate.count)
                if firstStep == nil || begin < firstStep! { firstStep = begin }
            }
        }
        guard let nameStart = firstStep, nameStart > startIndex else { return self }
        let nameRange = nameStart..<firstArrow.lowerBound
        guard lastArrow.lowerBound > nameRange.lowerBound else { return self }
        // The path starts at its opening quote, when it has one.
        var start = nameRange.lowerBound
        let openers: Set<Character> = ["“", "「", "\"", "『", "‘", "("]
        if openers.contains(self[index(before: start)]) { start = index(before: start) }
        guard start > startIndex else { return self }
        // It ends with its last step (and the quote that closes it).
        var end = lastArrow.upperBound
        while end < endIndex, ![" ", "\u{00A0}", ".", "。", ",", "，", "、"].contains(self[end]) {
            let closes = closers.contains(self[end])
            end = index(after: end)
            if closes { break }
        }
        let path = String(self[start..<end]).replacingOccurrences(of: "\u{2060}", with: "").replacingOccurrences(of: "\u{00A0}", with: " ")
        let width = (path as NSString).size(withAttributes: [.font: font]).width
        guard width <= lineWidth - 6 else { return self }
        var text = self
        let before = text.index(before: start)
        if text[before] == " " || text[before] == "\u{00A0}" {
            text.replaceSubrange(before..<start, with: "\n")
        } else {
            text.insert("\n", at: start)
        }
        return text
    }

    var containsHangul: Bool {
        unicodeScalars.contains { (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value) || (0x3130...0x318F).contains($0.value) }
    }

    /// The place names of System Settings ("System Settings → Privacy & Security → Microphone") are what the
    /// user has to find, so a name never breaks in the middle: the words of a multi-word name are tied with
    /// no-break spaces and the characters of a name written without spaces (Japanese, Chinese) with word joiners.
    /// Only the names themselves are tied (they come from `SettingsPathNames`, localized), never the sentence
    /// around them, so the line can still break before or after a path. Each arrow stays with the name before
    /// it and the line may break after it.
    var protectingSettingsPaths: String {
        let joiner = "\u{2060}", noBreak = "\u{00A0}", arrow = "\u{2192}"
        guard contains(arrow) else { return self }
        var text = replacingOccurrences(of: joiner, with: "")
        text = text.replacingOccurrences(of: "[ \u{00A0}]*\(arrow)[ \u{00A0}]*", with: noBreak + arrow + " ", options: .regularExpression)
        // A step may be written between quotes ("「…」", "“…”"): the quotes do not hide it.
        let quotes = [("", ""), ("「", "」"), ("“", "”"), ("\"", "\""), ("『", "』")]
        for name in SettingsPathNames.all.sorted(by: { $0.count > $1.count }) {
            let tied = SettingsPathNames.tied(name)
            guard tied != name else { continue }
            if name == SettingsPathNames.systemSettings {
                text = text.replacingOccurrences(of: name, with: tied)
            } else {
                for (open, close) in quotes {
                    text = text.replacingOccurrences(of: name + close + noBreak + arrow, with: tied + close + noBreak + arrow)
                    text = text.replacingOccurrences(of: arrow + " " + open + name, with: arrow + " " + open + tied)
                }
            }
        }
        // The short word that leads into the path ("unter", "in", "dans") stays with its first step, so the first line
        // of the path is never the bare name of the app.
        let first = SettingsPathNames.tied(SettingsPathNames.systemSettings)
        if let range = text.range(of: first), range.lowerBound > text.startIndex {
            let before = text[..<range.lowerBound]
            if before.last == " ", let wordStart = before.dropLast().lastIndex(of: " ").map({ before.index(after: $0) }),
               before.distance(from: wordStart, to: before.index(before: before.endIndex)) <= 6,
               before[wordStart..<before.index(before: before.endIndex)].allSatisfy({ $0.isLetter }) {
                text.replaceSubrange(before.index(before: before.endIndex)..<range.lowerBound, with: noBreak)
            }
        }
        // The last step never ends up alone on a line: the final arrow holds on to it ("… Privacy & Security →
        // Microphone." breaks before "Privacy", never between the arrow and "Microphone.").
        if let last = text.range(of: arrow + " ", options: .backwards) {
            text.replaceSubrange(last, with: arrow + noBreak)
        }
        return text
    }

    /// A long path in System Settings that would leave its first name ("Systemeinstellungen →") alone on a line
    /// starts a line of its own instead: the sentence breaks before the path, never inside its first step. A panel
    /// line holds about 44 characters, so the sentence is wrapped here the way it will be, word by word, to see it.
    fileprivate var breakingBeforeOrphanedSettingsPath: String {
        let name = SettingsPathNames.tied(SettingsPathNames.systemSettings)
        guard !contains("\n"), let range = range(of: name), range.lowerBound > startIndex,
              self[index(before: range.lowerBound)] == " ", distance(from: range.lowerBound, to: endIndex) > 40 else { return self }
        let lineWidth = 44
        // Each word, with the line it lands on and whether it is the last one on that line.
        var lines: [[Substring]] = [[]]
        var length = 0
        for word in split(separator: " ", omittingEmptySubsequences: true) {
            if length > 0, length + 1 + word.count > lineWidth {
                lines.append([])
                length = 0
            }
            lines[lines.count - 1].append(word)
            length += (length > 0 ? 1 : 0) + word.count
        }
        // The first step of the path (the name and the arrow after it) is the only thing on its line.
        let first = String(name.dropLast(0))
        let alone = lines.contains { $0.count == 1 && $0[0].hasPrefix(first) }
        guard alone else { return self }
        return replacingCharacters(in: index(before: range.lowerBound)..<range.lowerBound, with: "\n")
    }

    private func joiningForWidow(tyingSentences: Bool) -> String {
        let noBreak = "\u{00A0}", joiner = "\u{2060}"
        guard contains(" ") else { return joiningUnspaced(joiner, tail: true) }
        var words = split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard words.count > 1 else { return self }
        if tyingSentences { words = Self.tyingShortSentences(words) }
        // A short word joins the word after it (an article, a preposition, "¿Ha"): one pair, never a chain, so a line
        // is never left ragged by a long run. It does not join a long word or a tied name (a path in System Settings):
        // gluing "in" to "System Settings" or "the" to "microphone." would force an early break with a third of the
        // line empty. A short English verb or particle ("is", "up", "on") joins the word BEFORE it instead
        // ("Nothing is", "Free up", "Turn on"), so a subject is not parted from its verb nor a phrasal verb from its particle.
        var out: [String] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            if word.isAuxiliary, index + 1 < words.count, words[index + 1].canJoinBackwards {
                // An auxiliary stays with the participle it helps ("is uploaded"), two words, never a chain with the subject.
                out.append(word + noBreak + words[index + 1])
                index += 2
            } else if word.isTrailingParticle, let previous = out.last, !previous.contains(joiner) {
                out[out.count - 1] = previous + noBreak + word
                index += 1
            } else if word.isShortWord, index + 1 < words.count, words[index + 1].canJoinBackwards {
                out.append(word + noBreak + words[index + 1])
                index += 2
            } else {
                out.append(word)
                index += 1
            }
        }
        // The last two words stay together when the end is short (never one word alone on the last line), unless that
        // makes one long block that would leave the line before it half empty (the end of a path in System Settings).
        if out.count >= 2, out[out.count - 1].count <= 14, out[out.count - 1].count + out[out.count - 2].count <= 24 {
            let last = out.removeLast()
            let previous = out[out.count - 1]
            // A short word tied to the next one ("auf meinem") would make a four-word block with the end and pull its first
            // word down, leaving the line before it ragged: the pair gives way, so only the end stays together.
            if previous.count + last.count + 1 > 18, let gap = previous.firstIndex(of: Character(noBreak)),
               previous[..<gap].count <= 3, !previous.contains(joiner) {
                out[out.count - 1] = String(previous[..<gap])
                out.append(String(previous[previous.index(after: gap)...]) + noBreak + last)
            } else {
                out[out.count - 1] += noBreak + last
            }
        }
        // A last line of only a few characters ("to this Mac.") still looks like a widow: with one more word the end is
        // a third of a line at least, as long as the block stays short enough not to leave the line before it ragged.
        if out.count >= 3, let last = out.last, last.count < 14, !last.contains(joiner) {
            let previous = out[out.count - 2]
            if previous.count + last.count + 1 <= 20, !previous.contains(joiner), !previous.contains("\u{2192}") {
                out.removeLast()
                out[out.count - 1] = previous + noBreak + last
            }
        }
        // A long last word without spaces (a sentence in Japanese after a Latin name) keeps its tail together.
        return out.joined(separator: " ").joiningUnspaced(joiner, tail: (out.last?.count ?? 0) > 14)
    }

    /// A sentence of up to three short words that follows another sentence stays on one line ("Nothing is uploaded."): its
    /// first word is never left at the end of the line above, with its verb on the next.
    private static func tyingShortSentences(_ words: [String]) -> [String] {
        let enders: Set<Character> = [".", "!", "?", "…"]
        var out: [String] = []
        var start = 0
        func flush(_ end: Int) {
            let sentence = Array(words[start..<end])
            let tied = sentence.joined(separator: "\u{00A0}")
            let isSeparate = start > 0 || end < words.count
            let plain = sentence.allSatisfy { !$0.contains("\u{00A0}") && !$0.contains("\u{2060}") }
            if isSeparate, plain, (2...3).contains(sentence.count), tied.count <= 24 { out.append(tied) } else { out += sentence }
            start = end
        }
        for (index, word) in words.enumerated() where word.last.map(enders.contains) == true && word.count > 2 { flush(index + 1) }
        if start < words.count { flush(words.count) }
        return out
    }

    /// With two or more sentences that do not fit one line, the paragraph breaks between sentences instead of in the
    /// middle of one: every sentence that fits one line starts a line of its own (two short ones that fit one line
    /// together share it). A sentence too long for a line wraps as usual. The width is measured with `font`, by default
    /// the caption font.
    func breakingBeforeLastSentence(fittingIn width: CGFloat, font: NSFont = .preferredFont(forTextStyle: .caption1)) -> String {
        guard !contains("\n") else { return self }
        let enders: Set<Character> = [".", "!", "?", "。", "！", "？"]
        let characters = Array(self)
        // Sentences with the separator that followed each one (a space, or nothing after a CJK full stop).
        var sentences: [(text: String, separator: String)] = []
        var start = 0
        var index = 0
        while index < characters.count {
            if enders.contains(characters[index]), index + 1 < characters.count {
                if characters[index + 1] == " ", index + 2 < characters.count, !characters[index + 2].isLowercase {
                    sentences.append((String(characters[start...index]), " "))
                    start = index + 2
                    index = start
                    continue
                } else if "。！？".contains(characters[index]) {
                    sentences.append((String(characters[start...index]), ""))
                    start = index + 1
                    index = start
                    continue
                }
            }
            index += 1
        }
        if start < characters.count { sentences.append((String(characters[start...]).trimmingCharacters(in: .whitespaces), "")) }
        guard sentences.count > 1 else { return self }
        let measured = { (text: String) in (text as NSString).size(withAttributes: [.font: font]).width }
        guard measured(self) > width else { return self }
        let limit = width - 4
        var out = sentences[0].text
        // Whether the text so far ends on a line that is known to be a single line (so a short sentence may join it).
        var line = sentences[0].text
        var lineIsOpen = measured(line) <= limit
        // A first sentence of two lines is cut in the middle, not left with a short last line.
        if !lineIsOpen, let broken = sentences[0].text.brokenInTheMiddle(limit: width - 6, measured: measured) {
            out = broken
            line = ""
        }
        for (offset, sentence) in sentences.enumerated().dropFirst() {
            let previousSeparator = sentences[offset - 1].separator
            if lineIsOpen, measured(line + previousSeparator + sentence.text) <= limit {
                out += previousSeparator + sentence.text
                line += previousSeparator + sentence.text
            } else if measured(sentence.text) <= limit {
                out += "\n" + sentence.text
                line = sentence.text
                lineIsOpen = true
            } else if let broken = sentence.text.puttingSettingsPathOnItsOwnLine(font: font, width: width).nilIfUnchanged(from: sentence.text)
                        ?? sentence.text.brokenInTheMiddle(limit: width - 6, measured: measured) {
                // A sentence of two lines starts its own line and breaks in the middle (or before its path in System
                // Settings), so no sentence ends with a short line and none starts in the middle of another.
                out += "\n" + broken
                lineIsOpen = false
            } else {
                out += previousSeparator + sentence.text
                lineIsOpen = false
            }
        }
        return out
    }

    private func nilIfUnchanged(from original: String) -> String? { self == original ? nil : self }

    /// A sentence that takes two lines, cut where both halves are as even as possible (never after a short word, such as
    /// an article, and never inside a path in System Settings). Text without spaces (Japanese, Chinese) is cut after a
    /// particle or a comma. Nil when it does not fit two lines or has no good place to cut.
    fileprivate func brokenInTheMiddle(limit: CGFloat, measured: (String) -> CGFloat) -> String? {
        guard !contains("\n") else { return nil }
        let hasPath = contains("\u{2192}")
        var candidates: [(left: String, right: String)] = []
        if contains(" ") {
            let words = split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            // A path in System Settings has spaces inside its steps: it is left to its own rule.
            for cut in 1..<max(words.count, 1) where !hasPath {
                let left = words[..<cut].joined(separator: " "), right = words[cut...].joined(separator: " ")
                if words[cut - 1].isShortWord || right.split(separator: " ").count < 2 { continue }
                candidates.append((left, right))
            }
        } else {
            let particles: Set<Character> = ["で", "を", "は", "が", "に", "の", "と", "も", "へ", "、", "，", "」", "。"]
            let characters = Array(self)
            for cut in 4..<max(characters.count - 3, 4) where particles.contains(characters[cut - 1]) {
                let next = characters[cut]
                // Never before a particle, a small kana, a closing mark or an arrow.
                if "ゃゅょっー、。，」）\u{2192}".contains(next) || particles.contains(next) || characters[cut - 1] == "\u{2192}" { continue }
                candidates.append((String(characters[..<cut]), String(characters[cut...])))
            }
        }
        let best = candidates.map { (pair: $0, width: max(measured($0.left), measured($0.right))) }
            .filter { $0.width <= limit }
            .min { $0.width < $1.width }
        guard let best else { return nil }
        return best.pair.left + "\n" + best.pair.right
    }

    /// A word of up to three letters, ignoring opening punctuation ("¿Ha", "(a").
    private var isShortWord: Bool {
        let letters = drop { !$0.isLetter && !$0.isNumber }
        return !letters.isEmpty && letters.count <= 3 && !(last?.isPunctuation ?? false) && !isTrailingParticle
    }

    /// The short words that finish the phrase before them instead of starting the one after.
    fileprivate var isTrailingParticle: Bool {
        ["is", "are", "up", "on", "off", "out", "was", "has"].contains(lowercased())
    }

    fileprivate var isAuxiliary: Bool { ["is", "are", "was", "has"].contains(lowercased()) }

    /// A short word may join the next word when that word is short enough to fit beside it and is not already a tied
    /// unit (a name of System Settings, joined by no-break spaces or word joiners).
    fileprivate var canJoinBackwards: Bool {
        !contains("\u{00A0}") && !contains("\u{2060}") && count <= 10
    }

    private func joiningUnspaced(_ joiner: String, tail: Bool) -> String {
        let characters = Array(self)
        var bound = Set<Int>()  // positions after which no break is allowed
        // A number with what follows it (counter, particle): "1:30後に", "3分間".
        var index = 0
        while index < characters.count {
            if characters[index].isASCII, characters[index].isNumber {
                var end = index
                while end + 1 < characters.count, characters[end + 1].isASCII, characters[end + 1].isNumber || ":.,".contains(characters[end + 1]) { end += 1 }
                if end + 1 < characters.count, !characters[end + 1].isASCII {
                    for position in index...min(end + 1, characters.count - 2) { bound.insert(position) }
                }
                index = end + 1
            } else {
                index += 1
            }
        }
        // A particle or the copula never starts a line in Japanese ("…アプリ / で、…", "…いっぱい / です。"): it stays
        // with the word it follows (a katakana word or a few kanji, whole, so the word is not split either).
        // A particle after a hiragana word is already part of that word.
        func isHiragana(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { (0x3040...0x309F).contains($0.value) } }
        func scriptClass(_ c: Character) -> Int {
            guard let value = c.unicodeScalars.first?.value else { return 0 }
            if (0x30A0...0x30FF).contains(value) { return 1 }   // katakana
            if (0x3400...0x9FFF).contains(value) { return 2 }   // kanji
            if c.isASCII, c.isLetter || c.isNumber { return 3 } // Latin word or number
            return 0
        }
        for position in characters.indices where position > 0 {
            let character = characters[position]
            if "でをにがはも".contains(character), !isHiragana(characters[position - 1]) {
                let kind = scriptClass(characters[position - 1])
                var start = position - 1
                if kind != 0 {
                    let limit = kind == 2 ? 3 : 8
                    while start > 0, position - start < limit, scriptClass(characters[start - 1]) == kind { start -= 1 }
                }
                for bind in start..<position { bound.insert(bind) }
            }
            if position + 1 < characters.count, (character == "で" || character == "ま") && characters[position + 1] == "す" {
                bound.insert(position - 1)
                bound.insert(position)
            }
        }
        // A Chinese demonstrative stays with its measure word ("这台 Mac", "每个"): a line never ends after 这, 那, 每 or 该.
        for position in 0..<max(characters.count - 1, 0) where "这那每该".contains(characters[position]) {
            if characters[position + 1].unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) { bound.insert(position) }
        }
        // The last few characters.
        if tail, count > 8 { for position in max(0, characters.count - 6)..<(characters.count - 1) { bound.insert(position) } }
        guard !bound.isEmpty else { return self }
        var out = ""
        for (position, character) in characters.enumerated() {
            out.append(character)
            if bound.contains(position), position < characters.count - 1 { out += joiner }
        }
        return out
    }

    /// Ends with a full stop when a system message left it out (a reason appended to a sentence).
    var withTerminalPunctuation: String {
        guard let last = last, !last.isPunctuation, !last.isSymbol else { return self }
        let cjk = last.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
        return self + (cjk ? "。" : ".")
    }
}

/// The names macOS (and Vauta) give to the places a message sends the user to ("System Settings → Privacy &
/// Security → Microphone"), written the way the sentences write them in each language, so a line never breaks
/// inside one of them. They are the same words as in the sentences; `check-strings` keeps the tables in step.
enum SettingsPathNames {
    /// Without word joiners, which a translation may already carry: the names are tied here, and a name that carried its
    /// own would never match the text it is looked up in (the joiners are removed from the text first).
    static let systemSettings = String(localized: "path.system.settings", defaultValue: "System Settings",
                                       comment: "Name of the macOS System Settings app, as macOS says it in this language; the same words as in the sentences that send the user there")
        .replacingOccurrences(of: "\u{2060}", with: "")

    static var all: [String] {
        [
            systemSettings,
            String(localized: "path.privacy.security", defaultValue: "Privacy & Security",
                   comment: "System Settings pane name, as macOS says it in this language"),
            String(localized: "Microphone"),
            String(localized: "path.screen.recording", defaultValue: "Screen & System Audio Recording",
                   comment: "System Settings pane name, as macOS says it in this language"),
            String(localized: "path.sound", defaultValue: "Sound",
                   comment: "System Settings pane name, as macOS says it in this language"),
            String(localized: "General"),
            String(localized: "path.login.items", defaultValue: "Login Items & Extensions",
                   comment: "System Settings pane name, as macOS says it in this language"),
            String(localized: "path.users.groups", defaultValue: "Users & Groups",
                   comment: "System Settings pane name, as macOS says it in this language"),
            String(localized: "path.calendars", defaultValue: "Calendars",
                   comment: "System Settings Privacy & Security list name, as macOS says it in this language"),
            String(localized: "path.apple.intelligence", defaultValue: "Apple Intelligence & Siri",
                   comment: "System Settings pane name, as macOS says it in this language"),
            String(localized: "path.vauta.settings", defaultValue: "Settings",
                   comment: "Name of Vauta's own Settings window, as the sentences that send the user to Settings → Models write it"),
            String(localized: "Models"),
        ]
    }

    /// The name with its words tied by no-break spaces (when it is short enough to fit a line) and, in Japanese and
    /// Chinese, its characters tied by word joiners. Korean breaks between any two syllables in SwiftUI text and
    /// ignores both joiners and no-break spaces, so its names are left alone.
    static func tied(_ name: String) -> String {
        let noBreak: Character = "\u{00A0}", joiner: Character = "\u{2060}"
        func isUnspaced(_ c: Character) -> Bool {
            c.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) }
        }
        let characters = Array(name)
        var out = ""
        for (index, character) in characters.enumerated() {
            out.append(character == " " ? (name.count <= 28 ? noBreak : " ") : character)
            if index + 1 < characters.count, character != " ", characters[index + 1] != " ",
               isUnspaced(character) || isUnspaced(characters[index + 1]) {
                out.append(joiner)
            }
        }
        return out
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
