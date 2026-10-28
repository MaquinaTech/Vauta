// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// The Answers card of the menu-bar panel: answers to the questions heard in the meeting, each with where it was verified. It
/// appears only while an answer or the first-run hint exists, never takes the keyboard, makes no sound and never speaks the answer.
struct AnswersCard: View {
    let model: LiveAnswersModel
    /// The tallest an open answer may be to be seen whole in the scrolling part; a taller one is drawn compact.
    var rowLimit: CGFloat = .infinity
    /// Where the card starts in the scrolling content.
    var onTop: (CGFloat) -> Void = { _ in }
    var openSettings: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if model.isVisible {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Label(String(localized: "Answers", comment: "Answers card in the menu-bar panel: its title. The card holds short answers, with their sources, to questions heard in the meeting"), systemImage: "text.bubble")
                        .panelCardTitle()
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 4)
                    // Finding an answer: a spinner of the size of the title, no row; pressing it stops the work.
                    if model.isWorking {
                        Button { model.stopWorking() } label: { ThinkingOrb() }
                            .buttonStyle(.plain)
                            .frame(width: 16, height: 16)
                            .help(String(localized: "Stop", comment: "Button that stops finding an answer"))
                            .accessibilityLabel(Text("Stop", comment: "Button that stops finding an answer"))
                            .accessibilityValue(Text("Finding an answer…", comment: "VoiceOver value of the Stop button in the Answers card while an answer to a question heard is being worked out"))
                    }
                }
                if model.showsHint { hint.panelRowStop() }
                // Each row is a place where the panel's scrolling part may end. An open answer taller than the room of a short screen is drawn compact
                // (fewer lines, one line per source) so that it, with its actions, is seen whole.
                ForEach(model.rows) { row in
                    AnswerRowView(model: model, row: row, limit: rowLimit).panelRowStop()
                }
                if let pause = model.visiblePause { pauseLine(pause).panelRowStop() }
            }
            .panelVautaCard()
            .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named(PanelRowStop.space)).minY }) { onTop($0) }
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: model.rows)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            .accessibilityElement(children: .contain)
        }
    }

    private var hint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Vauta now answers questions it hears, from this meeting, your past meetings and your documents. Answers appear only in this panel, which Vauta asks macOS to keep out of screen sharing; that is not guaranteed.", comment: "Answers card: first-run notice shown once, in the panel, before the first answer")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            PanelActionRow {
                Button("OK") { model.answerHint(accepted: true) }.prominentButton(true)
                Button("Settings…") { model.answerHint(accepted: true); openSettings() }.prominentButton(false)
                Button { model.turnOffFromHint() } label: { Text("Turn Off", comment: "Answers card first-run notice: button that switches live answers off") }.prominentButton(false)
            }
        }
        .padding(.leading, PanelMetrics.titleTextIndent)
        // Only a hint that reached the screen counts as read.
        .onScrollVisibilityChange(threshold: 0.5) { visible in if visible { model.hintAppeared() } }
    }

    private func pauseLine(_ pause: LiveAnswerPause) -> some View {
        Label {
            Text(Self.pauseText(pause)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "pause.circle").foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    static func pauseText(_ pause: LiveAnswerPause) -> String {
        switch pause {
        case .modelUnavailable: String(localized: "Live answers paused: the model isn’t available.", comment: "Answers card in the panel: live answers are paused because no model can answer now")
        case .tooWarm: String(localized: "Live answers paused: the Mac is too warm.", comment: "Answers card in the panel: live answers are paused because the Mac is hot")
        case .transcriptBehind: String(localized: "Live answers paused: the transcript is falling behind.", comment: "Answers card in the panel: live answers are paused until the transcription catches up")
        case .noSources: String(localized: "Live answers paused: no sources are on.", comment: "Answers card in the panel: live answers are paused because the three sources are off in Settings")
        }
    }
}

/// The glyph and the words of a source, shared by the card and tested without a view.
enum QuestionsGlyphs {
    static func symbol(_ kind: AutoAnswerContent.Cite.Kind) -> String { AnswerRowView.symbol(kind) }
    static func label(_ cite: AutoAnswerContent.Cite) -> String { AnswerRowView.label(cite) }
}

/// "Asked by you at 12:03" / "Asked by Others at 12:03".
private func askedBy(_ channel: Channel, t: Double) -> String {
    let time = ElapsedTime.stamp(t)
    return channel == .me
        ? String(localized: "Asked by you at \(time)", comment: "Answers card: who asked the question and when; the argument is the time in the meeting")
        : String(localized: "Asked by \(channel.displayName) at \(time)", comment: "Answers card: who asked the question and when; the first argument is the speaker (Others), the second the time in the meeting")
}

/// The question between the quotation marks of the language (the VoiceOver sentences use the same ones).
private func quoted(_ text: String) -> String {
    String(localized: "“\(text)”", comment: "Words heard in the meeting between quotation marks (a question, or the line that names the next meeting); the argument is the quote. Use the quotation marks of the language")
}

/// The question on one line between the quotation marks of the language: the question is what is cut when it is too long, never the
/// closing mark.
private struct OneLineQuotedQuestion: View {
    let text: String

    var body: some View {
        // The marks come from the localized template, so each language keeps its own («…», 「…」).
        let parts = quoted("\u{1}").components(separatedBy: "\u{1}")
        HStack(spacing: 0) {
            Text(verbatim: parts.first ?? "").layoutPriority(1)
            Text(verbatim: text).lineLimit(1)
            Text(verbatim: parts.count > 1 ? parts[1] : "").layoutPriority(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: quoted(text)))
    }
}

struct AnswerRowView: View {
    let model: LiveAnswersModel
    let row: AnswerRow
    /// The tallest the open row may be before it is drawn compact.
    var limit: CGFloat = .infinity
    @ViewLocalState private var fullText = false
    @ViewLocalState private var fullHeight: CGFloat = 0
    @ViewLocalState private var shownHeight: CGFloat = 0

    /// The height of the open row in its full layout, measured on a hidden copy so that choosing the compact layout never changes it.
    @ViewLocalState private var naturalHeight: CGFloat = 0

    /// An open row taller than the room of the scrolling part is drawn compact (never while the person has opened the whole text).
    private var isCompact: Bool { limit.isFinite && !fullText && naturalHeight > limit }

    var body: some View {
        if model.isOpen(row.id) {
            open(compact: isCompact, measuring: false)
                .background {
                    if limit.isFinite && !fullText {
                        open(compact: false, measuring: true)
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden()
                            .accessibilityHidden(true)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { naturalHeight = $0 }
                    }
                }
        } else {
            folded
        }
    }

    private var folded: some View {
        Button { model.toggleOpen(row.id) } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(width: PanelMetrics.titleIconWidth)
                OneLineQuotedQuestion(text: row.question).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                sourceGlyphs
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The label is what is on screen (the question) and where the answer comes from; the answer itself is read only on the open row.
        .accessibilityLabel(Text(foldedLabel))
        .accessibilityHint(Text("Shows the answer", comment: "Hint of a folded answer in the Answers card"))
    }

    /// `measuring` is the hidden copy that only takes the height of the full layout: no stops, no measurements of its own.
    private func open(compact: Bool, measuring: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: quoted(row.question)).font(.callout.weight(.medium)).lineLimit(compact ? 1 : 2).fixedSize(horizontal: false, vertical: true)
                    Text(askedBy(row.channel, t: row.t))
                        .font(.caption2).foregroundStyle(.secondary)
                    if row.late {
                        // A late answer says so, in the text colour and with a glyph: it answers a question from a while ago.
                        Label(String(localized: "Late answer", comment: "Answers card: the answer came some time after the question was asked; the line above it says when"),
                              systemImage: "clock.badge.exclamationmark")
                            .font(.caption.weight(.medium))
                    }
                }
                Spacer(minLength: 4)
                // Compact: Keep, Copy and Open in Ask sit beside Dismiss, so they are seen whenever the top of the answer is.
                if compact { actions.fixedSize() }
                IconButton(label: String(localized: "Dismiss", comment: "Answers card: closes the answer"), systemImage: "xmark") { model.dismiss(row.id) }
                    .foregroundStyle(.secondary)
            }
            .panelRowStop(if: !measuring)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(.green).accessibilityHidden(true)
                    .help(LiveAnswersText.canBeWrong)
                Text(verbatim: row.content.answer)
                    .font(.callout)
                    .lineLimit(fullText ? nil : (compact ? 2 : 3))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { if !measuring { shownHeight = $0 } }
                    .background {
                        // The same text without a limit: it is cut when it is taller than what is shown.
                        Text(verbatim: row.content.answer).font(.callout).fixedSize(horizontal: false, vertical: true).hidden()
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { if !measuring { fullHeight = $0 } }
                    }
            }
            .panelRowStop(if: !measuring)
            if fullText || fullHeight > shownHeight + 1 {
                Button { fullText.toggle() } label: { Text(verbatim: fullText ? Self.lessText : Self.moreText).font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, PanelMetrics.titleTextIndent)
            }
            sourceLabels(compact: compact, stops: !measuring)
            if !compact { actions }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(spokenLabel))
        .accessibilityHint(Text(LiveAnswersText.canBeWrong))
        .focusable()
        .onKeyPress(.escape) { model.dismiss(row.id); return .handled }
        // ⌘C copies the answer only while this row has the keyboard; elsewhere in the panel it copies what is selected.
        .onCopyCommand {
            guard let text = model.copyableText(row.id) else { return [] }
            return [NSItemProvider(object: text as NSString)]
        }
    }

    private static let moreText = String(localized: "More", comment: "Answers card: shows the rest of a long answer that is cut after three lines (the opposite of Less)")
    private static let lessText = String(localized: "Less", comment: "Answers card: shows a long answer in three lines again (the opposite of More)")

    // MARK: Sources

    /// One label for each source of the verified citations: this meeting, a past meeting (title, date), a document (file name).
    /// Each has its own glyph, so colour is never the only difference.
    private func sourceLabels(compact: Bool, stops: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(row.content.labels.enumerated()), id: \.offset) { _, cite in
                HStack(spacing: 6) {
                    Image(systemName: Self.symbol(cite.kind)).font(.caption).frame(width: PanelMetrics.titleIconWidth).accessibilityHidden(true)
                    Text(Self.label(cite)).font(.caption).lineLimit(compact ? 1 : 2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 2)
                    chips(for: cite)
                }
                .foregroundStyle(.secondary)
                .panelRowStop(if: stops)
            }
        }
    }

    private var sourceGlyphs: some View {
        HStack(spacing: 3) {
            ForEach(Array(Set(row.content.sources.map(\.kind)).sorted { $0.rawValue < $1.rawValue }), id: \.self) { kind in
                Image(systemName: Self.symbol(kind)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func chips(for cite: AutoAnswerContent.Cite) -> some View {
        let same = row.content.claims.flatMap(\.cites).filter { $0.labelKey == cite.labelKey }
        switch cite.kind {
        case .thisMeeting, .pastMeeting:
            HStack(spacing: 4) {
                ForEach(Array(Set(same.compactMap(\.t).map { Int($0) })).sorted().prefix(3), id: \.self) { second in
                    let moment = same.first { Int($0.t ?? -1) == second } ?? cite
                    Button { model.onOpenMoment?(moment) } label: { Text(verbatim: ElapsedTime.stamp(second)).font(.caption.monospacedDigit()) }
                        .buttonStyle(.bordered).controlSize(.mini)
                        .accessibilityLabel(Text(verbatim: ElapsedTime.stamp(second)))
                        .accessibilityHint(Text("Opens the transcript at this moment", comment: "Hint of a citation chip"))
                }
            }
        case .document:
            if cite.documentCitation != nil {
                Button { model.onOpenDocument?(cite) } label: {
                    // Where in the document (the page, the sheet's rows...), so the chip says what it opens.
                    HStack(spacing: 3) {
                        if let place = cite.locator, !place.isEmpty { Text(verbatim: place).font(.caption) }
                        Image(systemName: "arrow.up.forward.square").font(.caption)
                    }
                }
                .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: cite.fileName ?? ""))
                    .accessibilityHint(Text("Opens the document at this passage", comment: "Hint of a citation chip that opens a document"))
            }
        }
    }

    static func symbol(_ kind: AutoAnswerContent.Cite.Kind) -> String {
        switch kind {
        case .thisMeeting: "clock"
        case .pastMeeting: "clock.arrow.circlepath"
        case .document: "doc.text"
        }
    }

    static func label(_ cite: AutoAnswerContent.Cite) -> String {
        switch cite.kind {
        case .thisMeeting:
            String(localized: "From this meeting", comment: "Answers card: the answer was verified in the meeting being recorded")
        case .pastMeeting:
            String(localized: "From a past meeting: \(cite.title ?? ""), \(pastDate(cite))", comment: "Answers card: the answer was verified in an earlier meeting; the arguments are its title and its date")
        case .document:
            String(localized: "From a document: \(cite.fileName ?? "")", comment: "Answers card: the answer was verified in one of the person's documents; the argument is the file name")
        }
    }

    static func pastDate(_ cite: AutoAnswerContent.Cite) -> String {
        cite.date.map { Date(timeIntervalSince1970: $0).formatted(.dateTime.day().month(.abbreviated)) } ?? ""
    }

    /// The question as it is on screen, then every source it was verified in; never the answer.
    private var foldedLabel: String {
        let sources = SpokenLabel.join(row.content.labels.map { Self.label($0) })
        return String(localized: "\(quoted(row.question)). \(sources)", comment: "VoiceOver label of a folded row in the Answers card; the arguments are the question between quotation marks and the places its answer was verified in, like “From this meeting, From a document: Budget.xlsx”")
    }

    /// The answer, then every source it was verified in (not only the first), so a mixed answer says so.
    private var spokenLabel: String {
        let sources = SpokenLabel.join(row.content.labels.map { Self.label($0) })
        let answer = row.content.answer.trimmingCharacters(in: CharacterSet(charactersIn: ".。 "))
        return String(localized: "Answer: \(answer). \(sources)", comment: "VoiceOver label of an answer in the Answers card; the arguments are the answer and the places it was verified in, like “From this meeting, From a document: Budget.xlsx”")
    }

    // MARK: Actions

    private static let copyOffReason = String(localized: "Copying is off while “Protect meeting text from copying” is on.",
                                             comment: "Answers card: tooltip of the disabled Copy button; the quoted name is the label of the setting in Privacy & Security")

    /// Keep, Copy and Open in Ask are icons with a label for VoiceOver and a tooltip (a row of words does not fit every language in the
    /// panel); Dismiss is the cross in the header.
    private var actions: some View {
        let kept = model.isKept(row.id)
        return HStack(spacing: 14) {
            Button { model.toggleKeep(row.id) } label: { Image(systemName: kept ? "pin.fill" : "pin") }
                .foregroundStyle(kept ? Color.accentColor : .secondary)
                .help(kept ? String(localized: "Kept", comment: "Answers card: the answer is kept with the meeting") : String(localized: "Keep", comment: "Answers card: button that keeps the answer with the meeting"))
                .accessibilityLabel(Text("Keep", comment: "Answers card: button that keeps the answer with the meeting"))
                .accessibilityValue(kept ? Text("Kept", comment: "Answers card: the answer is kept with the meeting") : Text(verbatim: ""))
                .accessibilityAddTraits(kept ? .isSelected : [])
            // With "Protect meeting text from copying" on (the default) Copy is off, and its tooltip and hint say why; no notice stays on the card.
            // "Copied" stands next to the button it confirms.
            HStack(spacing: 4) {
                Button { model.copy(row.id) } label: { Image(systemName: model.copiedID == row.id ? "checkmark" : "doc.on.doc") }
                    .foregroundStyle(.secondary)
                    .opacity(model.copyProtected() ? 0.4 : 1)
                    .disabled(model.copyProtected())
                    .help(model.copyProtected() ? Self.copyOffReason : String(localized: "Copy", comment: "Answers card: copies the answer"))
                    .accessibilityLabel(Text("Copy", comment: "Answers card: copies the answer"))
                    .accessibilityHint(model.copyProtected() ? Text(Self.copyOffReason) : Text(verbatim: ""))
                    .accessibilityValue(model.copiedID == row.id ? Text("Copied", comment: "Answers card: the answer was copied") : Text(verbatim: ""))
                if model.copiedID == row.id {
                    Text("Copied", comment: "Answers card: the answer was copied").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button { model.openInAsk(row.id) } label: { Image(systemName: "arrow.up.forward.app") }
                .foregroundStyle(.secondary)
                .help(String(localized: "Open in Ask", comment: "Answers card: opens the answer in Ask"))
                .accessibilityLabel(Text("Open in Ask", comment: "Answers card: opens the answer in Ask"))
            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
        .imageScale(.medium)
    }
}
