// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// To review: ambiguous names (two people called “John”) and words the
/// recognizer may have misheard. Vauta never corrects them on its own.
struct SuggestionsTab: View {
    @Bindable var model: MeetingsModel

    var body: some View {
        if model.suggestions.isEmpty && model.dismissedLinks.isEmpty {
            EmptyStateView(Text("Nothing to Review"), symbol: "checkmark.circle", message: String(localized: "Unclear names and likely misheard words appear here. Vauta never changes them on its own."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: PaneLayout.section) {
                    ForEach(model.suggestions) { card($0) }
                    if !model.dismissedLinks.isEmpty { DismissedLinksSection(model: model) }
                }
                .padding(PaneLayout.pane)
                .frame(maxWidth: 760, alignment: .leading)
            }
        }
    }

    private func card(_ s: Suggestion) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: s.kind == .ambiguous ? "person.fill.questionmark" : "character.book.closed")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    // One bold title line for both kinds.
                    Text(s.kind == .ambiguous ? "Who is “\(s.surface)”?" : "Did you mean “\(s.surface)”?").font(.headline)
                    Spacer()
                    if s.occurrences > 1 {
                        Text("Heard \(s.occurrences) times").font(.callout).foregroundStyle(.secondary)
                    }
                    if let segment = s.segmentID {
                        TimeButton(t: s.t) { model.open(meeting: s.meetingID, segment: segment) }
                    }
                }
                HStack {
                    ForEach(Array(s.candidates.enumerated()), id: \.offset) { index, c in
                        let choice = Button(c.label) { Task { await model.resolve(s, candidate: c) } }
                        // The likeliest choice is the prominent one in both kinds.
                        if index == 0 {
                            choice.buttonStyle(.borderedProminent)
                        } else {
                            choice.buttonStyle(.bordered)
                        }
                    }
                    Button(s.kind == .ambiguous ? "None of These" : "Keep as Heard") { Task { await model.resolve(s, entity: nil) } }
                }
                .controlSize(.small)
                Text(s.kind == .ambiguous ? "Your choice helps Vauta recognize this name next time."
                                          : "Your choice helps Vauta spell this term next time.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
        .accessibilityElement(children: .contain)
    }
}

/// The links the person said are not the same, each with Restore. Only pairs whose two items still exist are listed.
struct DismissedLinksSection: View {
    @Bindable var model: MeetingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dismissed links", comment: "Section title in a meeting’s Suggestions tab: the links to earlier meetings that the person said were not the same").font(.headline)
                .accessibilityAddTraits(.isHeader)
            ForEach(model.dismissedLinks) { link in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        ProtectedText(link.newerText).lineLimit(2)
                        Text(String(localized: "\(TaskDueFormat.text(link.earlierMeetingDate)) · \(link.earlierMeetingTitle): “\(link.earlierText)”", comment: "A dismissed link to an earlier meeting; the arguments are the date and title of that meeting and the earlier item’s text (quotation marks and colon follow the language)"))
                            .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer()
                    Button("Restore") { Task { await model.restore(link) } }.controlSize(.small)
                        // Every row has the same button: the item it brings back is the hint.
                        .accessibilityHint(Text(verbatim: link.newerText))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardBackground()
            }
        }
    }
}
