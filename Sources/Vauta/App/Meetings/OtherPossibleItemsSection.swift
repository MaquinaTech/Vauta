// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// "Other possible items": what the model proposed from the meeting that did not make the main list, because it ranked below the
/// main items and not because the transcript does not back it. It starts collapsed. Each row can still be checked (which moves the
/// item to the main list), cited (its time), deleted, and a task edited in the Tasks tab. Items that a check on their words doubted
/// stay in the main lists with the "Unconfirmed" mark.
struct OtherPossibleItemsSection: View {
    @Bindable var model: MeetingsModel
    let meetingID: Int64
    let items: [OtherPossibleItems.Item]

    var body: some View {
        if !items.isEmpty {
            DisclosureGroup(isExpanded: $model.otherItemsExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: Self.rankedOutGroupHelp).font(.callout).foregroundStyle(.secondary)
                    ForEach(items) { item in
                        row(item)
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack(spacing: 6) {
                    Text("Other possible items", comment: "Section title in a meeting’s minutes: the decisions and tasks the model proposed that did not make the main list; it starts collapsed")
                        .font(.headline)
                    Text(items.count.formatted())
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .background(Color(nsColor: .secondarySystemFill), in: Capsule())
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Other possible items, \(items.count) items", comment: "VoiceOver label of the title of the group of other possible items: the title and how many there are"))
                .accessibilityAddTraits(.isHeader)
                .accessibilityHint(model.otherItemsExpanded ? Text(verbatim: "") : Text("Items the model proposed that are less certain than the main ones. Open the group to review them.",
                                                                                      comment: "VoiceOver hint of the collapsed group of other possible items in the minutes"))
            }
        }
    }

    @ViewBuilder
    private func row(_ item: OtherPossibleItems.Item) -> some View {
        switch item {
        case .decision(let d): decisionRow(d)
        case .task(let t): taskRow(t)
        }
    }

    private static var rankedOutGroupHelp: String {
        String(localized: "The model proposed these, but they are less certain than the main items of the meeting. Check them before relying on them.",
               comment: "Description under the heading of the group of other possible items (plural: it covers every item in the group)")
    }

    private static var rankedOutHelp: String {
        String(localized: "The model proposed this, but it is less certain than the main items of the meeting. Check it before relying on it.",
               comment: "Help of an item in the group of other possible items: it only ranked below the main items")
    }

    private func decisionRow(_ d: Decision) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "checkmark.seal").foregroundStyle(.secondary)
                .frame(width: SourceBadge.columnWidth).accessibilityHidden(true)
            ProtectedText(d.text)
                .accessibilityLabel(Text(verbatim: SpokenLabel.join([String(localized: "Decision", comment: "VoiceOver: the kind of an item in a list"), d.text])))
                .help(Self.rankedOutHelp)
            Spacer()
            if let t = d.t { TimeButton(t: t) { model.open(meeting: meetingID, at: t) } }
            // The slot of a task's pencil, so the times of decisions and tasks line up.
            IconButton(label: "", systemImage: "pencil") {}.hidden()
            IconButton(label: String(localized: "Mark as Checked", comment: "Button on an item the model proposed and nobody has confirmed: the user has checked it"), systemImage: "checkmark.circle") {
                Task { await model.markDecisionChecked(d) }
            }
            IconButton(label: String(localized: "Delete Decision…", comment: "Button; a confirmation follows"), systemImage: "minus.circle") {
                model.pendingDeletion = .decision(d)
            }
        }
        .contextMenu { Button("Mark as Checked") { Task { await model.markDecisionChecked(d) } } }
    }

    private func taskRow(_ task: TaskItem) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "checklist").foregroundStyle(.secondary)
                .frame(width: SourceBadge.columnWidth).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                ProtectedText(task.text)
                if let owner = task.ownerName {
                    HStack(spacing: 3) {
                        Text(verbatim: owner).font(.callout).foregroundStyle(.secondary)
                        if task.ownerMarked { OwnerMarkGlyph(name: owner).font(.callout) }
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: SpokenLabel.join([String(localized: "Task", comment: "Accessibility label"), task.text] + (task.ownerName.map { [task.ownerMarked ? VerificationText.ownerSpoken($0) : $0] } ?? []))))
            .help(task.ownerMarked ? [Self.rankedOutHelp, VerificationText.ownerHelp].joinedAsSentences() : Self.rankedOutHelp)
            Spacer()
            if let t = task.t { TimeButton(t: t) { model.open(meeting: meetingID, at: t) } }
            IconButton(label: String(localized: "Edit in Tasks", comment: "Button on a task in the group of other possible items: opens it in the Tasks tab, where it can be edited"), systemImage: "pencil") {
                model.tab = .tasks
                model.taskSelection = task.id
            }
            IconButton(label: String(localized: "Mark as Checked", comment: "Button on an item the model proposed and nobody has confirmed: the user has checked it"), systemImage: "checkmark.circle") {
                Task { await model.markTaskChecked(task) }
            }
            IconButton(label: String(localized: "Delete Task…", comment: "Button; a confirmation follows"), systemImage: "minus.circle") {
                model.pendingDeletion = .task(id: task.id, text: task.text)
            }
        }
        .contextMenu { Button("Mark as Checked") { Task { await model.markTaskChecked(task) } } }
    }
}
