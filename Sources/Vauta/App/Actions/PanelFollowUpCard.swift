// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import SwiftUI
import VautaCore

/// The Follow-up card in the menu-bar panel after a meeting's minutes are ready: above the record button, under the brief's card,
/// hidden while a recording runs. Review… opens the Follow-up sheet in Meetings; nothing in the card can create anything. While
/// Meetings are locked it says only "Minutes ready" (no counts, no titles).
struct FollowUpCardView: View {
    let model: RecorderModel

    var body: some View {
        if model.phase == .idle, !model.isRecording {
            let content = model.followUpCard
            if content != .hidden {
                FollowUpCardContent(content: content, locked: !model.historyUnlocked, review: { model.reviewFollowUp() }, close: { model.dismissFollowUpCard() })
            }
        }
    }
}

/// The card for one state (the scenes render it with invented counts).
struct FollowUpCardContent: View {
    let content: FollowUpCard.Content
    let locked: Bool
    let review: () -> Void
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label {
                    Text("Follow-up", comment: "Menu-bar panel: heading of the card that offers to review the tasks and follow-up meetings of a meeting. It names the feature (like the Follow Up sheet), not a meeting")
                } icon: {
                    Image(systemName: "checklist.checked")
                }
                    .panelCardTitle()
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Dismiss")
                    .accessibilityLabel(Text("Dismiss"))
            }
            summary
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            PanelActionRow {
                Button(locked ? "Unlock to Review" : "Review…", action: review)
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .panelVautaCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Follow-up", comment: "Menu-bar panel: heading of the card that offers to review the tasks and follow-up meetings of a meeting. It names the feature (like the Follow Up sheet), not a meeting"))
    }

    @ViewBuilder private var summary: some View {
        if locked {
            Label { Text("Minutes ready", comment: "Menu-bar panel, follow-up card: the minutes of a meeting are ready") } icon: { Image(systemName: "lock") }
        } else {
            switch content {
            case .hidden:
                EmptyView()
            case .several(let count, _):
                Text("Minutes ready for \(count) meetings", comment: "Menu-bar panel, follow-up card: several meetings have minutes to review; the argument is how many")
            case .one(let pending):
                switch (pending.tasks > 0, pending.followUps > 0) {
                case (true, true):
                    Text("Minutes ready · \(pending.tasks) tasks · \(pending.followUps) follow-up meetings", comment: "Menu-bar panel, follow-up card; the arguments are how many tasks and how many follow-up meetings are to review")
                case (true, false):
                    Text("Minutes ready · \(pending.tasks) tasks", comment: "Menu-bar panel, follow-up card; the argument is how many tasks are to review")
                default:
                    Text("Minutes ready · \(pending.followUps) follow-up meetings", comment: "Menu-bar panel, follow-up card; the argument is how many follow-up meetings are to review")
                }
            }
        }
    }
}
