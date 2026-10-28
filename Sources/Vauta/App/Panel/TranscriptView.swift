// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// The live transcript, hidden by default (in case the screen is shared). One card: the header with its
/// switch and, when it is on, the passages under it, on the same edge as the text of the other cards.
/// It sits under the scrolling part of the panel, not inside it, so the passages are the only thing a
/// scroll over them moves.
struct TranscriptSection: View {
    @Bindable var model: RecorderModel
    /// The tallest the passages may be (the panel gives the rest of the screen to the part above).
    var maxBoxHeight: CGFloat = TranscriptView.defaultMaxHeight
    /// The screen is too short for even one passage: the card shows its header only, never a sliver of text.
    var isCollapsed = false
    @ViewLocalState private var previewWidth: CGFloat = 0
    @ViewLocalState private var hintHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The end of the newest passage that fits the room beside the title, cut at a word.
    private func previewTail(of text: String, name: String) -> String {
        let font = NSFont.preferredFont(forTextStyle: .caption1)
        let nameWidth = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)]).width
        let room = previewWidth - nameWidth - 4 - 3
        guard room > 24 else { return text }
        return CaptionTail.lastLines(of: text, lines: 1, width: room, points: font.pointSize, weight: .regular)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The same header as the other cards: title with a quiet icon, disclosure at the trailing edge.
            HStack {
                Label("Transcript", systemImage: "text.quote")
                    .panelCardTitle()
                    // The disclosure carries the name for VoiceOver.
                    .accessibilityHidden(true)
                    .layoutPriority(1)
                if model.showTranscript, isCollapsed, let latest = model.volatileSegments.last ?? model.segments.last?.segment {
                    // No room for the passages: the newest one stays in the header as one line (who said it, then the end of what was said), so the open card visibly has content.
                    // The end of the line, like the captions: the words being said now stay, the start is the ellipsis, and the cut is
                    // always at a word, never inside one.
                    HStack(spacing: 4) {
                        Text(verbatim: model.liveLabel(for: latest)).font(.caption.weight(.semibold))
                            .foregroundStyle(latest.channel.tint(ordinal: latest.speaker?.ordinal ?? 1))
                            .lineLimit(1).fixedSize()
                        Text(verbatim: previewTail(of: latest.text, name: model.liveLabel(for: latest))).lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { previewWidth = $0 }
                    .accessibilityHidden(true)
                } else {
                    Spacer(minLength: 0)
                }
                // A disclosure, as in Meetings' Live notes: it opens or closes the passages (a switch that is on with
                // nothing under it, on a short screen, would read as a fault).
                Button { model.showTranscript.toggle() } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(model.showTranscript ? 90 : 0))
                        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: model.showTranscript)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.showTranscript ? Text("Hide the transcript") : Text("Show the transcript"))
                .accessibilityLabel(model.showTranscript ? Text("Hide Transcript") : Text("Show Transcript"))
            }
            if model.showTranscript, !isCollapsed {
                let hinted = model.showsProvisionalSpeakers
                // The hint takes room from the passages, not from the panel: the card is never taller than its limit.
                TranscriptView(model: model, maxHeight: max(0, maxBoxHeight - (hinted ? hintHeight + 8 : 0)))
                    .padding(.leading, PanelMetrics.titleTextIndent)
                if hinted {
                    ProvisionalSpeakersHint()
                        .padding(.leading, PanelMetrics.titleTextIndent)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { hintHeight = $0 }
                }
            }
        }
        .panelCard()
    }
}

struct TranscriptView: View {
    let model: RecorderModel
    var maxHeight: CGFloat = TranscriptView.defaultMaxHeight
    @ViewLocalState private var contentHeight: CGFloat = 0
    @ViewLocalState private var rowHeights: [String: CGFloat] = [:]
    @ViewLocalState private var canScrollUp = false
    @ViewLocalState private var canScrollDown = false

    static let defaultMaxHeight: CGFloat = 220
    private static let fade: CGFloat = 18
    private static let spacing: CGFloat = 10

    /// One passage in the list: where it is, so its height can be looked up.
    private struct Row: Identifiable {
        let id: String
        let segment: Segment
        let isProvisional: Bool
    }

    private var rows: [Row] {
        model.segments.suffix(100).map { Row(id: "s\($0.id)", segment: $0.segment, isProvisional: false) }
            + model.volatileSegments.map { Row(id: "v\($0.channel.rawValue)", segment: $0, isProvisional: true) }
    }

    /// The box shows whole passages: as many of the newest ones as fit in `maxHeight`, so no passage is ever cut at
    /// the top (a cut passage leaves the descenders of its last line under the edge). nil while the passages are not
    /// measured yet, or when not even the newest one fits (then the box is `maxHeight` and the edge fades).
    private func snappedHeight(_ rows: [Row]) -> CGFloat? {
        var sum: CGFloat = 0
        var count = 0
        for row in rows.reversed() {
            guard let height = rowHeights[row.id] else { return nil }
            let next = sum + height + (count > 0 ? Self.spacing : 0)
            if next > maxHeight + 0.5 { break }
            sum = next
            count += 1
        }
        return count > 0 ? sum : nil
    }

    /// Only the last 100 (the whole transcript is in Meetings). The box is as tall as its text, up to a limit
    /// (a whole number of passages), then scrolls, with the newest passage in view as text arrives.
    var body: some View {
        let rows = rows
        let snapped = snappedHeight(rows)
        let boxHeight = snapped ?? (contentHeight > 0 ? min(contentHeight, maxHeight) : nil)
        ScrollViewReader { proxy in
            ScrollView {
                // A plain stack (the list is capped at 100 passages): the height of the content is exact, so the end is too.
                VStack(alignment: .leading, spacing: Self.spacing) {
                    ForEach(rows) { row in
                        SegmentRow(segment: row.segment, label: model.liveLabel(for: row.segment), isProvisional: row.isProvisional)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { rowHeights[row.id] = $0 }
                    }
                }
                // The end is the bottom edge of the content, not a view in the stack (it would add a gap of its own).
                .overlay(alignment: .bottom) { Color.clear.frame(height: 0).id(Self.endID) }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            // The fade below is the only one: no system edge effect on top of it.
            .scrollEdgeEffectHidden(true, for: .all)
            // The newest passage is in view when the box appears, when the room it has changes and when text arrives
            // (once the layout has settled, so the end is where the content really ends).
            .onAppear { scrollToEnd(proxy) }
            .onChange(of: maxHeight) { scrollToEnd(proxy) }
            .onChange(of: contentHeight) { scrollToEnd(proxy) }
            .onChange(of: model.segments.count) { scrollToEnd(proxy) }
            .onScrollGeometryChange(for: TranscriptEdges.self) { geometry in
                let top = geometry.contentOffset.y + geometry.contentInsets.top
                let bottom = geometry.contentSize.height - geometry.containerSize.height - top
                return TranscriptEdges(up: top > 1, down: bottom > 1)
            } action: { _, edges in
                canScrollUp = edges.up
                canScrollDown = edges.down
            }
            // Where more text is hidden the edge fades out. At the end the top edge lies between two passages (the box
            // is a whole number of them), so it needs no fade: nothing is cut there.
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(canScrollUp && snapped == nil ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.fade)
                    Rectangle()
                    LinearGradient(colors: [.black, .black.opacity(canScrollDown ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.fade)
                }
            }
            .frame(height: boxHeight)
            // The cap only stands in until the passages are measured: next to a fixed height it would grow the box to the
            // room it was offered and leave a blank band around the passages.
            .frame(maxHeight: boxHeight == nil ? maxHeight : nil)
        }
    }

    private static let endID = "transcript-end"

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.endID, anchor: .bottom)
        DispatchQueue.main.async { proxy.scrollTo(Self.endID, anchor: .bottom) }
    }
}

/// Whether there is more transcript to scroll to above or below.
private struct TranscriptEdges: Equatable {
    var up: Bool
    var down: Bool
}

/// One passage: when and who said it on the first line, the text under it, so every
/// text shares one left edge whatever the name's width. With voices told apart the name is the voice's (a provisional
/// guess, see `ProvisionalSpeakersHint`); a voice the app is unsure of gets a question mark (and italics, in scripts that have them), not colour alone.
struct SegmentRow: View {
    let segment: Segment
    /// Who said it, as printed.
    let label: String
    /// Still being recognized: only the text is dimmed, never the name or time.
    let isProvisional: Bool

    private var unsure: Bool { segment.speaker?.isLowConfidence ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(verbatim: ElapsedTime.stamp(Int(segment.start)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    Text(verbatim: label)
                        .font(.caption.weight(.semibold))
                        // Italic does not exist for Japanese, Chinese or Korean (only a digit or Latin letter would slant): the
                        // question mark carries the meaning there.
                        .italic(unsure && !label.usesUnspacedScript && !label.containsHangul)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if unsure { Image(systemName: "questionmark.circle").imageScale(.small) }
                    if segment.speaker?.overlap == true { Image(systemName: "person.2.wave.2").imageScale(.small) }
                }
                .foregroundStyle(segment.channel.tint(ordinal: segment.speaker?.ordinal ?? 1))
                // The same words as the Meetings transcript's tooltip, one per line.
                .help(notesList.joined(separator: "\n"))
            }
            Text(verbatim: segment.text)
                .font(.callout)
                .foregroundStyle(isProvisional ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(verbatim: notes))
    }

    /// What is uncertain about the speaker (the tooltip lists these; VoiceOver reads them as a value).
    private var notesList: [String] {
        var out: [String] = []
        if unsure { out.append(String(localized: "Not sure who said this", comment: "Tooltip and VoiceOver: the app is not sure which speaker said this transcript line")) }
        if segment.speaker?.overlap == true { out.append(String(localized: "Several people spoke at once", comment: "Tooltip and VoiceOver: several people talked at the same time in this transcript line")) }
        return out
    }

    private var notes: String { SpokenLabel.join(notesList) }
}

/// Under the live transcript, once voices are told apart: the labels are guesses until the meeting ends.
struct ProvisionalSpeakersHint: View {
    var body: some View {
        Label {
            Text(description: String(localized: "Speaker names may change when the meeting ends.",
                                     comment: "Hint under the live transcript in the panel: the speaker labels are provisional while recording"))
                .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}
