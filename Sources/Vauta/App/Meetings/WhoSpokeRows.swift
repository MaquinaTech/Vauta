// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// "Who spoke" in the Summary: each speaker with their share of the talking, most first. The name opens the
/// speaker popover (name, assign, merge). The share is written next to the bar, never only drawn.
struct WhoSpokeRows: View {
    @Bindable var model: MeetingsModel

    /// The width of the bar at 100%.
    static let barWidth: CGFloat = 120
    static let nameLimit: CGFloat = 170

    var body: some View {
        let entries = model.roster.byTalkTime
        let font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .semibold)
        let widest = entries.map { ($0.displayName as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let nameWidth = min(Self.nameLimit, ceil(widest) + 2)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(entries) { entry in
                WhoSpokeRow(model: model, entry: entry, nameWidth: nameWidth)
            }
        }
    }
}

private struct WhoSpokeRow: View {
    @Bindable var model: MeetingsModel
    let entry: SpeakerRoster.Entry
    let nameWidth: CGFloat
    @ViewLocalState private var hovering = false

    var body: some View {
        let tint = entry.channel.tint(ordinal: entry.speaker.ordinal)
        let share = model.roster.share(of: entry)
        VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button { model.speakerPopover = .speaker(entry.id) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(entry.displayName)
                        .fontWeight(.semibold)
                        .underline(hovering)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .foregroundStyle(tint)
                .frame(width: nameWidth, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help(Self.help(entry))
            // One reading per row: the name, then "3 min, 36%" as its value, so the share is read with the name.
            .accessibilityValue(Text(verbatim: spoken))
            .pointerStyle(.link)
            .onHover { hovering = $0 }
            .onDisappear { hovering = false }
            .popover(isPresented: Binding(
                get: { model.speakerPopover == .speaker(entry.id) },
                set: { if !$0, model.speakerPopover == .speaker(entry.id) { model.speakerPopover = nil } }
            ), arrowEdge: .trailing) {
                SpeakerPopover(model: model, target: .speaker(entry.id))
            }
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint).frame(width: max(share > 0 ? 4 : 0, WhoSpokeRows.barWidth * share))
            }
            .frame(width: WhoSpokeRows.barWidth, height: 6)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
            .accessibilityHidden(true)
            Text("\(SpeakerFormat.talkTime(entry.speaker.talkSeconds)) · \(SpeakerFormat.share(model.roster.displayShare(of: entry)))",
                 comment: "Speaker popover and Who spoke: how long the speaker talked and their share of the talking, as in “12 min · 42%”")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .accessibilityHidden(true)
        }
        if let candidate = model.suggestion(for: entry.speaker) { SpeakerSuggestionRow(model: model, speakerID: entry.id, candidate: candidate) }
        }
    }

    /// The full name first (the column cuts a long one after two lines), then what the button does.
    private static func help(_ entry: SpeakerRoster.Entry) -> String {
        [entry.displayName, String(localized: "Speaker options", comment: "Tooltip and VoiceOver action of a speaker's name in the transcript: opens the menu to name the speaker, merge it or fix who said a line")].joined(separator: "\n")
    }

    /// "3 min · 36%", read after the name.
    private var spoken: String {
        String(localized: "\(SpeakerFormat.talkTime(entry.speaker.talkSeconds)) · \(SpeakerFormat.share(model.roster.displayShare(of: entry)))",
               comment: "Speaker popover and Who spoke: how long the speaker talked and their share of the talking, as in “12 min · 42%”")
    }
}

/// “Is this Ana?” under a speaker whose voice resembles a saved voice: one click to accept or reject. A rejection is
/// remembered for this meeting.
struct SpeakerSuggestionRow: View {
    @Bindable var model: MeetingsModel
    let speakerID: Int64
    let candidate: SpeakerSuggestion

    var body: some View {
        HStack(spacing: 8) {
            Label {
                candidate.question
            } icon: {
                Image(systemName: "person.fill.questionmark").accessibilityHidden(true)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Button(String(localized: "Yes", comment: "Speaker popover; answer to “Is this Ana?”: the suggested person is right")) { Task { await model.performSpeakerAction(.assign(speaker: speakerID, entity: candidate.entityID)) } }
                .buttonStyle(.link)
                .accessibilityLabel(candidate.yesLabel)
            Button(String(localized: "No", comment: "Speaker popover; answer to “Is this Ana?”: the suggested person is wrong")) { Task { await model.performSpeakerAction(.rejectSuggestion(speaker: speakerID)) } }
                .buttonStyle(.link)
                .accessibilityLabel(candidate.noLabel)
        }
        .padding(.leading, 0)
    }
}
