// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// The transcript with marks and notes in time order. A passage is
/// highlighted (to cite it in a new decision or task) by clicking it or with
/// the arrow keys; with copy protection off its text can also be selected.
struct TranscriptTab: View {
    @Bindable var model: MeetingsModel
    let meeting: MeetingStore.Meeting
    @Environment(\.copyProtection) private var copyProtection
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    private enum Item: Identifiable {
        case segment(MeetingStore.StoredSegment), mark(MeetingMark), note(MeetingNote), pause(MeetingPause)
        var id: String {
            switch self {
            case .segment(let s): "s\(s.id)"
            case .mark(let m): "m\(m.id)"
            case .note(let n): "n\(n.id)"
            case .pause(let p): "p\(p.start)"
            }
        }
        var t: Double {
            switch self {
            case .segment(let s): s.start
            case .mark(let m): m.t
            case .note(let n): n.t
            case .pause(let p): p.start
            }
        }
    }

    private var items: [Item] {
        (model.transcript.map(Item.segment) + model.marks.map(Item.mark) + model.notes.map(Item.note) + model.pauses.map(Item.pause)).sorted { $0.t < $1.t }
    }

    var body: some View {
        // Measured once per update, not once per row.
        let cols = columns
        return VStack(spacing: 0) {
            if model.findShown {
                TranscriptFindBar(model: model)
                Divider()
            }
            transcript(cols)
        }
    }

    private func transcript(_ cols: Columns) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    header
                    ForEach(items) { item in
                        switch item {
                        case .segment(let segment): row(segment, cols).id(segment.id)
                        case .mark(let m): markRow(m, cols)
                        case .note(let n): noteRow(n, cols)
                        case .pause(let p): pauseRow(p, cols)
                        }
                    }
                }
                .padding(PaneLayout.pane)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onMoveCommand { direction in
                switch direction {
                case .up: model.moveHighlight(by: -1)
                case .down: model.moveHighlight(by: 1)
                default: break
                }
            }
            // Return corrects the highlighted line, as it renames in Finder.
            .onKeyPress(.return) {
                guard model.canCorrectHighlight else { return .ignored }
                model.correctHighlight()
                return .handled
            }
            .onChange(of: model.highlighted, initial: true) {
                if let h = model.highlighted { withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(h, anchor: .center) } }
            }
            .onChange(of: model.transcript) {
                if let h = model.highlighted { proxy.scrollTo(h, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        if model.transcript.isEmpty && meeting.endedAt != nil {
            let expired = meeting.startedAt < AppClock.now.addingTimeInterval(-Double(MeetingStore.retentionDays) * 86_400)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // A status symbol and the shared notice text, like the other notices of the window.
                Group {
                    StatusSymbol.info.image
                }
                .frame(width: SourceBadge.columnWidth)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    if expired {
                        NoticeText(title: String(localized: "Transcript deleted after \(MeetingStore.retentionDays) days",
                                                 comment: "Transcript tab: title of the notice for a transcript purged by the retention period; the argument is a number of days"),
                                   detail: String(localized: "The minutes, decisions, notes and tasks are kept.",
                                                  comment: "Transcript tab: what remains after the transcript was purged"))
                    } else {
                        // What to check, and a button to the place where the input is chosen.
                        NoticeText(title: String(localized: "Nothing was transcribed in this meeting"),
                                   detail: String(localized: "Check that your microphone wasn’t muted and that the transcription language is the one spoken.",
                                                  comment: "Transcript tab: what to check when nothing was transcribed"))
                        Button("Open Sound Settings") { Permissions.open(.sound) }
                            .controlSize(.small)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: CardStyle.radius))
            // Set apart from the marks and notes under it, which would otherwise read as one more row.
            .padding(.bottom, 8)
        } else if !model.transcript.isEmpty {
            // The controls, then the hint on the row under them in every language (where it sits never depends on
            // whether a translation happens to fit next to the controls).
            VStack(alignment: .leading, spacing: 6) {
                controls
                // The notice that explains the checkbox sits right under it, above the hint about passages.
                SpeakerSeparationNote(model: model)
                hint.fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 4)
        }
    }

    private var hint: some View {
        Text(copyProtection ? "Click a passage or use ↑↓ to highlight it."
                            : "Click a time or use ↑↓ to highlight a passage.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var controls: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if model.offersSpeakerSwitch { SpeakerSeparationSwitch(model: model) }
            if !model.translations.isEmpty, let preferences = model.preferences {
                @Bindable var preferences = preferences
                Toggle("Show translation", isOn: $preferences.showTranslationsInTranscript)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Show the stored translation in gray under each line of “Others”")
            }
            if model.reanalyzing {
                ThinkingOrb().accessibilityElement().accessibilityLabel(Text("Finding names…"))
            }
            Button("Find Names in This Meeting") { Task { await model.reanalyze() } }
                .controlSize(.small)
                .disabled(model.reanalyzing)
                .help("Look again for the people, projects and terms of your context in this meeting")
        }
        .fixedSize()
    }

    typealias Columns = (time: CGFloat, speaker: CGFloat)

    /// Column widths from the widest time ("1:02:03" in long meetings) and the widest speaker name,
    /// so the text starts at the same x in every row. The speaker column is measured over every name the
    /// transcript can print, up to a limit (a longer name wraps to a second line and is whole in the popover).
    private var columns: Columns {
        let last = max(model.transcript.last?.start ?? 0, model.marks.map(\.t).max() ?? 0, model.notes.map(\.t).max() ?? 0)
        let digits = NSFont.monospacedDigitSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
        let time = (ElapsedTime.stamp(last) as NSString).size(withAttributes: [.font: digits]).width
        let semibold = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .semibold)
        // Only the labels the transcript prints, each with the signs of its own lines (a name that never carries a sign
        // needs no room for one), so the text starts where the longest visible label ends and never further right.
        var widths: [String: CGFloat] = [:]
        var widest: CGFloat = 0
        for line in model.transcript {
            let label = line.speakerLabel
            let width = widths[label] ?? (label as NSString).size(withAttributes: [.font: semibold]).width
            widths[label] = width
            let signs = (line.hasUncertainSpeaker ? 1 : 0) + (line.speaker?.overlap == true ? 1 : 0)
            widest = max(widest, width + CGFloat(signs) * SpeakerLabel.flagWidth)
        }
        // With no speech there is no speaker name: the column is only as wide as the glyph, so the text follows it.
        let speaker = model.transcript.isEmpty ? SourceBadge.columnWidth : min(SpeakerLabel.maxWidth, max(56, ceil(widest) + SpeakerLabel.gutter))
        return (max(44, ceil(time) + 2), speaker)
    }

    private static let annotationFill = Color(nsColor: .quaternaryLabelColor).opacity(0.5)

    /// A mark in the same time / speaker / text columns as the passages.
    private func markRow(_ m: MeetingMark, _ cols: Columns) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TranscriptTime(text: ElapsedTime.stamp(m.t), width: cols.time, help: "Highlight the passage at this moment", plain: model.transcript.isEmpty) {
                model.open(meeting: meeting.id, at: m.t)
            }
            Image(systemName: "bookmark.fill").foregroundStyle(.orange).frame(width: cols.speaker, alignment: .leading)
                .accessibilityHidden(true)
            Text("Mark").frame(maxWidth: .infinity, alignment: .leading)
        }
        .rowInset(fill: Self.annotationFill, flush: model.transcript.isEmpty)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Mark at \(ElapsedTime.stamp(m.t))"))
    }

    /// Where the recording was paused: nothing was captured until it resumed, so the gap in the times is not a silence.
    private func pauseRow(_ p: MeetingPause, _ cols: Columns) -> some View {
        let text = Self.pauseText(p)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: ElapsedTime.stamp(p.start)).monospacedDigit().foregroundStyle(.secondary).frame(width: cols.time, alignment: .leading)
            Image(systemName: "pause.circle").foregroundStyle(.secondary).frame(width: cols.speaker, alignment: .leading)
                .accessibilityHidden(true)
            Text(verbatim: text).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .rowInset(fill: Self.annotationFill, flush: model.transcript.isEmpty)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: text))
    }

    /// "Paused 12:03 – 12:10 (7 min)"; "Paused from 12:03 to the end" when the recording stopped during the pause.
    static func pauseText(_ p: MeetingPause) -> String { p.text() }

    /// A note in the same columns, tinted so it stands out from the speech.
    private func noteRow(_ n: MeetingNote, _ cols: Columns) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TranscriptTime(text: ElapsedTime.stamp(n.t), width: cols.time, help: "Highlight the passage at this moment", plain: model.transcript.isEmpty) {
                model.open(meeting: meeting.id, at: n.t)
            }
            Image(systemName: "note.text").foregroundStyle(Color(nsColor: .systemYellow)).frame(width: cols.speaker, alignment: .leading)
                .accessibilityHidden(true)
            ProtectedText(n.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Notes and marks share one look: a neutral fill and their own glyph, no bar (the bar is only the
        // highlighted passage's), and yellow stays the colour of a search match.
        .rowInset(fill: Self.annotationFill, flush: model.transcript.isEmpty)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Note at \(ElapsedTime.stamp(n.t)): \(n.text)"))
    }

    /// The text with the places of Find in Meeting marked while its bar is open (the chosen one solid), else the search
    /// words found in it, when the meeting was opened from a search.
    private func matched(_ segment: MeetingStore.StoredSegment) -> Text {
        let text = segment.text
        let found = model.findRanges(of: segment.id)
        let ranges = model.findShown ? found.all : MeetingStore.matchedRanges(of: model.query, in: text)
        guard !ranges.isEmpty else { return Text(text) }
        var out = AttributedString(text)
        for range in ranges {
            if let lower = AttributedString.Index(range.lowerBound, within: out), let upper = AttributedString.Index(range.upperBound, within: out) {
                if range == found.current {
                    // The place ⌘G is on: a solid marker with dark text in both appearances, as in other apps' Find.
                    out[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
                    out[lower..<upper].backgroundColor = Color(nsColor: .systemYellow)
                    out[lower..<upper].swiftUI.foregroundColor = .black
                } else {
                    out.markMatch(lower..<upper, dark: colorScheme == .dark)
                }
            }
        }
        return Text(out)
    }

    private var showsTranslations: Bool { model.preferences?.showTranslationsInTranscript ?? true }

    private func row(_ segment: MeetingStore.StoredSegment, _ cols: Columns) -> some View {
        let isHighlighted = segment.id == model.highlighted
        let isEditing = model.lineDraft?.segmentID == segment.id
        let canCorrect = model.canCorrect(segment)
        let translation = showsTranslations ? model.translations[segment.id] : nil
        let time = ElapsedTime.stamp(segment.start)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            TranscriptTime(text: time, width: cols.time, help: "Highlight this passage") { model.highlight(segment) }
            SpeakerLabel(model: model, segment: segment, width: cols.speaker)
            VStack(alignment: .leading, spacing: 2) {
                if isEditing {
                    TranscriptLineEditor(model: model)
                } else {
                    // Not by color alone: an echo is dimmed and says what it is, with the way to take the mark back.
                    ProtectedText(matched(segment))
                        .foregroundStyle(segment.isEcho ? .secondary : .primary)
                }
                if let original = segment.originalText {
                    CorrectedNote(original: original) { Task { await model.restoreOriginal(segment) } }
                }
                if segment.isEcho {
                    EchoNote(channel: segment.channel) { Task { await model.setEcho(segment, false) } }
                }
                if let translation {
                    FilledText(text: translation, selectable: !copyProtection)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isHighlighted, canCorrect, !isEditing {
                CorrectLineButton { model.beginCorrecting(segment) }
            }
        }
        // Not by color alone: a bar marks the highlighted passage.
        .rowInset(fill: isHighlighted ? Color.accentColor.opacity(0.18) : nil, bar: isHighlighted ? Color.accentColor : nil)
        .contentShape(Rectangle())
        // With copy protection off, clicks select text; the time highlights. A click in the line being corrected places the caret.
        .onTapGesture { if copyProtection, !isEditing { model.highlight(segment) } }
        .contextMenu {
            if canCorrect, !isEditing { Button(CorrectLineButton.title + "…") { model.beginCorrecting(segment) } }
            if segment.originalText != nil { Button(CorrectedNote.restoreTitle) { Task { await model.restoreOriginal(segment) } } }
        }
        // The field of the line being corrected stays reachable.
        .accessibilityElement(children: isEditing ? .contain : .ignore)
        .accessibilityLabel(SpeakerLabel.spoken(segment, time: time))
        .accessibilityValue(Text(verbatim: [segment.originalText.map { CorrectedNote.title + ". " + CorrectedNote.transcribed($0) },
                                            segment.isEcho ? EchoNote.title(for: segment.channel) : nil, SpeakerLabel.spokenNotes(segment, translation: translation)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")))
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.highlight(segment) }
        .accessibilityActions {
            // Only a line with stored speaker data has options; the others would offer an action that does nothing.
            if segment.speaker?.id != nil {
                Button("Speaker options") { model.speakerPopover = .line(segment.id) }
            }
            if segment.isEcho {
                Button(EchoNote.restore(for: segment.channel)) { Task { await model.setEcho(segment, false) } }
            }
            if canCorrect { Button(CorrectLineButton.title) { model.beginCorrecting(segment) } }
            if segment.originalText != nil { Button(CorrectedNote.restoreTitle) { Task { await model.restoreOriginal(segment) } } }
        }
        .accessibilityHint(Text("Highlights the passage to cite it"))
    }
}

/// The time of a transcript line, drawn like the other "go to this moment" times: accent-colored, a pointing hand,
/// underlined under the pointer. With no transcript to go to, it is plain text.
private struct TranscriptTime: View {
    let text: String
    let width: CGFloat
    let help: LocalizedStringKey
    var plain = false
    let action: () -> Void
    @ViewLocalState private var hovering = false

    var body: some View {
        if plain {
            Text(text)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: width, alignment: .leading)
        } else {
            Button(action: action) { Text(text).underline(hovering) }
                .buttonStyle(.plain)
                .font(.callout.monospacedDigit())
                .foregroundStyle(Color(nsColor: .linkColor))
                .frame(width: width, alignment: .leading)
                .help(help)
                // The system keeps the cursor balanced when the row goes away under the pointer.
                .pointerStyle(.link)
                .onHover { hovering = $0 }
                .onDisappear { hovering = false }
        }
    }
}

extension View {
    /// A transcript row: 10 pt of padding inside a rounded fill, with the text kept on the pane's margin (the fill
    /// hangs 10 pt into the gutter) and the optional 3 pt bar drawn inside the fill, 2 pt from its leading edge,
    /// which leaves about 5 pt of air between the bar and the time.
    fileprivate func rowInset(fill: Color? = nil, bar: Color? = nil, flush: Bool = false) -> some View {
        self
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .background {
                RoundedRectangle(cornerRadius: 6).fill(fill ?? .clear)
            }
            .overlay(alignment: .leading) {
                if let bar { Capsule().fill(bar).frame(width: 3).padding(.vertical, 5).padding(.leading, 2) }
            }
            // With no speech the rows sit under the notice card: their fill takes the card's edges.
            .padding(.horizontal, flush ? 0 : -10)
    }
}

/// A running secondary-text paragraph whose lines fill up to the column's edge. SwiftUI's Text moves a word down
/// to avoid a short last line, so a translation would wrap earlier than the original line above it; the AppKit
/// text field here turns that line-breaking strategy off.
private struct FilledText: NSViewRepresentable {
    let text: String
    let selectable: Bool

    /// Drawn without vibrancy: inside SwiftUI a vibrant label paints the dynamic secondary colour almost as bright
    /// as the primary text.
    private final class PlainField: NSTextField {
        override var allowsVibrancy: Bool { false }
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = PlainField(wrappingLabelWithString: "")
        field.drawsBackground = false
        field.isBordered = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        // The system's secondary label colour, resolved against the pane's own appearance (and Increase Contrast): the
        // dynamic colour would otherwise resolve against the field's appearance, which can differ from the pane's.
        let dark = context.environment.colorScheme == .dark
        let name: NSAppearance.Name = context.environment.colorSchemeContrast.snapshotResolved == .increased
            ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (dark ? .darkAqua : .aqua)
        var secondary = NSColor.secondaryLabelColor
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            // The system colour is translucent; drawn without vibrancy it would read as bright as the primary text, so
            // it is laid over the pane's background into one opaque colour.
            if let fg = NSColor.secondaryLabelColor.usingColorSpace(.sRGB), let bg = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) {
                let a = fg.alphaComponent
                secondary = NSColor(srgbRed: fg.redComponent * a + bg.redComponent * (1 - a),
                                    green: fg.greenComponent * a + bg.greenComponent * (1 - a),
                                    blue: fg.blueComponent * a + bg.blueComponent * (1 - a), alpha: 1)
            }
        }
        // One step smaller than the original line, so the difference is not carried by colour alone.
        let font = NSFont.preferredFont(forTextStyle: .subheadline)
        let style = NSMutableParagraphStyle()
        style.lineBreakStrategy = []
        style.lineBreakMode = .byWordWrapping
        // Selectable first: turning it on afterwards makes the field re-draw with its own label colour.
        field.isSelectable = selectable
        field.allowsEditingTextAttributes = true
        field.appearance = nil
        field.font = font
        field.textColor = secondary
        field.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: secondary,
            .paragraphStyle: style,
        ])
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTextField, context: Context) -> CGSize? {
        let width = max(proposal.width ?? 400, 20)
        let bounds = field.attributedStringValue.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: width, height: ceil(bounds.height))
    }
}
