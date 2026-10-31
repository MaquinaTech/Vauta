// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// A citation of an Ask answer: a link that opens the moment, and a preview of the passage it cites, without leaving the answer
/// (`passagePreview`). Its button opens the transcript there (or the minutes, for a line of an older meeting's minutes).
struct CitationLink: View {
    /// "Weekly sync · 12:34 · Ana", as the answer shows the citation.
    let label: String
    /// The cited line, when the answer has it (nil: a plain link, with no preview).
    let segment: CitableSegment?
    /// The question, whose words are marked in the preview.
    let question: String
    let open: () -> Void

    /// How long the pointer rests on the link before the preview opens: long enough not to open on the way to something else.
    nonisolated static let restDelay: Duration = .milliseconds(700)

    private var isMinutes: Bool { segment.map { MinutesEvidence.isMinutes($0.id) } ?? false }

    var body: some View {
        Button(label, action: open)
            .buttonStyle(.link)
            .lineLimit(1)
            .accessibilityHint(isMinutes ? Text("Opens the meeting’s minutes", comment: "VoiceOver: hint of a citation of the minutes of an older meeting")
                                         : Text("Opens the transcript at this moment"))
            .passagePreview(label, passage: segment.map(PreviewedPassage.init), marking: question, open: open)
    }
}

/// The line a link points to, for its preview: a cited segment of Ask, or a line of the meeting's own transcript.
struct PreviewedPassage: Equatable {
    let id: Int64
    let channel: Channel
    let speaker: SpeakerTag?
    let text: String

    init(_ segment: CitableSegment) {
        (id, channel, speaker, text) = (segment.id, segment.channel, segment.speaker, segment.text)
    }

    init(_ segment: MeetingStore.StoredSegment) {
        (id, channel, speaker, text) = (segment.id, segment.channel, segment.speaker, segment.text)
    }

    /// A line of an older meeting's minutes (`MinutesEvidence`), said by nobody.
    var isMinutes: Bool { MinutesEvidence.isMinutes(id) }
}

extension View {
    /// The preview of the passage a link points to. It opens when the pointer rests on the link for a moment, with Space while the
    /// link has the keyboard focus, and with VoiceOver's "Preview Passage" action. It shows `label`, then who said it and the words
    /// (`marking`'s words marked); its button does what the link does. Without a passage the link is a plain link.
    func passagePreview(_ label: String, passage: PreviewedPassage?, marking: String = "", open: @escaping () -> Void) -> some View {
        modifier(PassagePreview(label: label, passage: passage, marking: marking, open: open))
    }
}

private struct PassagePreview: ViewModifier {
    let label: String
    let passage: PreviewedPassage?
    let marking: String
    let open: () -> Void

    @ViewLocalState private var previewing = false
    @ViewLocalState private var resting: Task<Void, Never>?
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                resting?.cancel()
                guard inside, passage != nil else { return }
                resting = Task { @MainActor in
                    try? await Task.sleep(for: CitationLink.restDelay)
                    if !Task.isCancelled { previewing = true }
                }
            }
            .onKeyPress(.space) {
                guard passage != nil else { return .ignored }
                previewing.toggle()
                return .handled
            }
            // Only a link with a passage has the action: a plain one would offer an action that does nothing.
            .accessibilityActions {
                if passage != nil {
                    Button { previewing = true } label: {
                        Text("Preview Passage", comment: "VoiceOver: action on a citation of an Ask answer that shows the passage it cites")
                    }
                }
            }
            .popover(isPresented: $previewing, arrowEdge: .bottom) {
                if let passage { preview(passage) }
            }
    }

    private func preview(_ passage: PreviewedPassage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            ProtectedText(Text(words(of: passage))).font(.callout).fixedSize(horizontal: false, vertical: true)
            Button {
                previewing = false
                open()
            } label: {
                passage.isMinutes ? Text("Open Minutes", comment: "Ask: button of the preview of a citation of an older meeting's minutes, which opens them")
                                  : Text("Show in Transcript")
            }
            .buttonStyle(.link)
        }
        .padding(12)
        .frame(width: 380, alignment: .leading)
    }

    /// "Ana: words", the speaker in bold and its color as in the transcript, `marking`'s words marked; a line of the minutes was said by
    /// nobody and has no speaker.
    private func words(of passage: PreviewedPassage) -> AttributedString {
        let who = passage.isMinutes ? AttributedString()
            : passage.channel.quotePrefix(for: passage.speaker, tint: passage.channel.tint(ordinal: passage.speaker?.ordinal ?? 1))
        var text = AttributedString(passage.text)
        for range in MeetingStore.matchedRanges(of: marking, in: passage.text) {
            if let lower = AttributedString.Index(range.lowerBound, within: text), let upper = AttributedString.Index(range.upperBound, within: text) {
                text.markMatch(lower..<upper, dark: colorScheme == .dark)
            }
        }
        return who + text
    }
}
