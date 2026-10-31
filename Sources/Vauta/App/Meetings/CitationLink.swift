// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// A citation of an Ask answer: a link that opens the moment, and a preview of the passage it cites, without leaving the answer. The
/// preview opens when the pointer rests on the link for a moment, with Space while the link has the keyboard focus, and with the
/// "Preview Passage" action of VoiceOver. It shows the citation, then who said it and the words, the question's words marked; its button
/// opens the transcript there (or the minutes, for a line of an older meeting's minutes).
struct CitationLink: View {
    /// "Weekly sync · 12:34 · Ana", as the answer shows the citation.
    let label: String
    /// The cited line, when the answer has it (nil: a plain link, with no preview).
    let segment: CitableSegment?
    /// The question, whose words are marked in the preview.
    let question: String
    let open: () -> Void

    @ViewLocalState private var previewing = false
    @ViewLocalState private var resting: Task<Void, Never>?
    @Environment(\.colorScheme) private var colorScheme

    /// How long the pointer rests on the link before the preview opens: long enough not to open on the way to something else.
    nonisolated static let restDelay: Duration = .milliseconds(700)

    private var isMinutes: Bool { segment.map { MinutesEvidence.isMinutes($0.id) } ?? false }

    var body: some View {
        Button(label, action: open)
            .buttonStyle(.link)
            .lineLimit(1)
            .accessibilityHint(isMinutes ? Text("Opens the meeting’s minutes", comment: "VoiceOver: hint of a citation of the minutes of an older meeting")
                                         : Text("Opens the transcript at this moment"))
            .onHover { inside in
                resting?.cancel()
                guard inside, segment != nil else { return }
                resting = Task { @MainActor in
                    try? await Task.sleep(for: Self.restDelay)
                    if !Task.isCancelled { previewing = true }
                }
            }
            .onKeyPress(.space) {
                guard segment != nil else { return .ignored }
                previewing.toggle()
                return .handled
            }
            .accessibilityAction(named: Text("Preview Passage", comment: "VoiceOver: action on a citation of an Ask answer that shows the passage it cites")) {
                if segment != nil { previewing = true }
            }
            .popover(isPresented: $previewing, arrowEdge: .bottom) {
                if let segment { preview(segment) }
            }
    }

    private func preview(_ segment: CitableSegment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            ProtectedText(Text(words(of: segment))).font(.callout).fixedSize(horizontal: false, vertical: true)
            Button {
                previewing = false
                open()
            } label: {
                isMinutes ? Text("Open Minutes", comment: "Ask: button of the preview of a citation of an older meeting's minutes, which opens them")
                          : Text("Show in Transcript")
            }
            .buttonStyle(.link)
        }
        .padding(12)
        .frame(width: 380, alignment: .leading)
    }

    /// "Ana: words", the speaker in bold and its color as in the transcript, the question's words marked; a line of the minutes was said by
    /// nobody and has no speaker.
    private func words(of segment: CitableSegment) -> AttributedString {
        let who = MinutesEvidence.isMinutes(segment.id) ? AttributedString()
            : segment.channel.quotePrefix(for: segment.speaker, tint: segment.channel.tint(ordinal: segment.speaker?.ordinal ?? 1))
        var text = AttributedString(segment.text)
        for range in MeetingStore.matchedRanges(of: question, in: segment.text) {
            if let lower = AttributedString.Index(range.lowerBound, within: text), let upper = AttributedString.Index(range.upperBound, within: text) {
                text.markMatch(lower..<upper, dark: colorScheme == .dark)
            }
        }
        return who + text
    }
}
