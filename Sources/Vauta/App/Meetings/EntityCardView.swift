// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// The card of a person or project: open tasks, what it's related to, the
/// meetings it appears in and where it is named.
struct EntityCardView: View {
    @Bindable var model: MeetingsModel
    let onOpenSettings: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    /// Opens the entity in Settings → Context.
    let onEdit: (Int64) -> Void

    var body: some View {
        if let e = model.selectedEntity {
            ScrollView {
                VStack(alignment: .leading, spacing: PaneLayout.section) {
                    VStack(alignment: .leading, spacing: 4) {
                        ContextFormHeader(title: e.displayName, symbol: e.kind.symbol)
                        Text(e.aliases.isEmpty ? e.kind.label
                             : String(localized: "\(e.kind.label) · also “\(e.aliases.joined(separator: "”, “"))”",
                                      comment: "Entity card subtitle: kind and other names"))
                            .foregroundStyle(.secondary)
                        if e.kind == .person, model.entitySpokeIn > 0 {
                            Label {
                                Text("Spoke in \(model.entitySpokeIn) meetings", comment: "Entity card of a person: in how many meetings the user named them as a speaker; the Meetings section below lists them")
                            } icon: {
                                Image(systemName: "quote.bubble").accessibilityHidden(true)
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                        }
                        // Biometric data: always visible on the card, with the one action that removes it.
                        if e.kind == .person, model.entityVoices > 0 {
                            HStack(spacing: 6) {
                                Label {
                                    Text("Voice saved on this Mac", comment: "Entity card of a person: a voice fingerprint of them is saved in the encrypted store; the Delete button follows")
                                } icon: {
                                    Image(systemName: "waveform").accessibilityHidden(true)
                                }
                                .foregroundStyle(.secondary)
                                Text(verbatim: "·").foregroundStyle(.secondary).accessibilityHidden(true)
                                // Not grey: it is the one action that removes biometric data, so it must look clickable.
                                Button("Delete") { model.confirmDeleteVoice(of: e) }
                                    .buttonStyle(.link)
                                    .accessibilityLabel(Text("Delete saved voice", comment: "VoiceOver: deletes the saved voice of the person on this card"))
                            }
                            .font(.callout)
                            .padding(.top, 2)
                        }
                        if let note = e.note { ProtectedText(note).padding(.top, 4) }
                    }
                    if !model.entityTasks.isEmpty { tasks }
                    related
                    if !model.entityTimeline.isEmpty { meetings }
                    if e.kind == .person, !model.entityQuotes.isEmpty { said }
                    if !model.entityRefs.isEmpty { mentions }
                    Button(SettingsModel.Pane.context.openTitle) { onEdit(e.id) }
                        .help("Edit people, projects and terms in the Context pane")
                }
                .padding(PaneLayout.pane)
                .frame(maxWidth: 760, alignment: .leading)
            }
        } else {
            if model.entities.isEmpty {
                EmptyStateView(Text("No People, Projects or Clients Yet"), symbol: "person.2",
                               message: String(localized: "Add people, projects and terms in the Context pane, or confirm the names Vauta suggests in a meeting.")) {
                    Button(SettingsModel.Pane.context.openTitle, action: onOpenSettings)
                }
            } else {
                EmptyStateView(Text("Select a Person, Project or Client"), symbol: "person.2",
                               message: String(localized: "See which meetings they appear in, the exact moment, their tasks and everything related.")) {
                    Button(SettingsModel.Pane.context.openTitle, action: onOpenSettings)
                }
            }
        }
    }

    private var tasks: some View {
        DetailSection(String(localized: "Open tasks", comment: "Heading of the Tasks mode and section of the People card (a heading inside the window: sentence case)")) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: PaneLayout.item) {
                ForEach(model.entityTasks) { t in
                    GridRow {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            TaskDoneButton(task: t) { status in Task { await model.setStatus(t.id, status) } }
                            ProtectedText(t.text)
                            if t.unconfirmed {
                                // One glyph per task, as in the task table: its help and VoiceOver text name
                                // both marks when the owner is also uncertain.
                                let ownerMarked = t.ownerMarked
                                Image(systemName: "questionmark.circle")
                                    .foregroundStyle(.orange)
                                    .help([VerificationText.unconfirmedHelp, ownerMarked ? VerificationText.ownerHelp : nil]
                                        .compactMap { $0 }.joined(separator: " "))
                                    .accessibilityLabel(Text(verbatim: [VerificationText.unconfirmed,
                                                                        ownerMarked ? VerificationText.ownerSpoken(t.ownerName ?? "") : nil]
                                        .compactMap { $0 }.joined(separator: ". ")))
                            } else if t.ownerMarked {
                                OwnerMarkGlyph(name: t.ownerName ?? "")
                            }
                        }
                        .gridColumnAlignment(.leading)
                        if t.due != nil {
                            TaskDueCell(task: t, normal: .secondary)
                                .font(.callout.monospacedDigit())
                                .gridColumnAlignment(.trailing)
                        } else {
                            Color.clear.frame(width: 0, height: 0).gridColumnAlignment(.trailing)
                        }
                    }
                }
            }
        }
    }

    /// Every related item except the open tasks, which the card lists in their own section just above (the Context
    /// editor keeps the full list).
    private var impact: [GraphNode] {
        let listed = Set(model.entityTasks.map(\.id))
        return model.entityImpact.filter { !($0.ref.kind == .task && listed.contains($0.ref.id)) }
    }

    private var related: some View {
        DetailSection(String(localized: "Relations", comment: "Entity card section: what is connected to this person or project (also the section of the Context editor)")) {
            if impact.isEmpty {
                // With open tasks listed above, "yet" would be wrong: only the other kinds of relation are missing.
                Group {
                    if model.entityImpact.isEmpty {
                        Text("No relations yet. Add them in the Context pane.")
                    } else {
                        Text("No other relations. Add them in the Context pane.")
                    }
                }
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
            // A grid: the relation column is as wide as its longest name (80 to 160 pt), so no name truncates.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: PaneLayout.item) {
                ForEach(impact) { n in
                    GridRow {
                        Text(relation(n.rel))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(minWidth: 80, maxWidth: 160, alignment: .leading)
                            .fixedSize(horizontal: true, vertical: false)
                        HStack(spacing: 8) {
                            Image(systemName: symbol(n.ref.kind))
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                                .accessibilityHidden(true)
                            if n.ref.kind == .entity || n.ref.kind == .meeting {
                                Button(n.label) { open(n) }.buttonStyle(.link).lineLimit(1)
                            } else {
                                Text(n.label).lineLimit(1)
                            }
                            Text(n.detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                            if n.depth > 1 { Text("(indirect)").font(.callout).foregroundStyle(.secondary) }
                            Spacer(minLength: 0)
                        }
                        .gridColumnAlignment(.leading)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            }
        }
    }

    /// "owner" → "Owner" (the relation's localized reading, capitalized).
    private func relation(_ raw: String) -> String {
        let text = RelationKind(rawValue: raw)?.label ?? raw
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private var meetings: some View {
        DetailSection(String(localized: "Meetings", comment: "Entity card section: the meetings where the person or project appears")) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: PaneLayout.item) {
                ForEach(model.entityTimeline) { item in
                    GridRow {
                        Button(item.meeting.displayTitle) {
                            if let t = item.firstT { model.open(meeting: item.meeting.id, at: t) } else { model.open(meeting: item.meeting.id) }
                        }
                        .buttonStyle(.link)
                        .lineLimit(1)
                        .gridColumnAlignment(.leading)
                        Group {
                            Text(verbatim: Self.roles(item, person: model.selectedEntity?.kind == .person))
                        }
                        .font(.callout).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                        Group {
                            if item.mentions > 0 { Text("\(item.mentions) mentions") } else { Text(verbatim: "") }
                        }
                        .font(.callout).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                        Text(item.meeting.startedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// How the person or project is in the meeting: "Spoke" or "Attended" (a project is "Linked"). Whoever spoke was there, so
    /// "Spoke" never leaves it open whether they attended; "attended" (a calendar attendee or mentioned) is not shown on top of it.
    private static func roles(_ item: TimelineEntry, person: Bool) -> String {
        switch (item.attended, item.spoke) {
        case (_, true) where person:
            return String(localized: "Spoke", comment: "Entity card, Meetings section: the person is the named speaker of a speaker of this meeting")
        case (true, _):
            return person ? String(localized: "Attended") : String(localized: "Linked")
        default:
            return ""
        }
    }

    /// What the person said: a passage per meeting, from the speakers the user named as them.
    private var said: some View {
        DetailSection(String(localized: "What they said", comment: "Section title on a person's card: passages the person said in meetings, from the speakers the user named as them")) {
            ForEach(model.entityQuotes) { quote in
                Button { model.open(meeting: quote.meeting.id, segment: quote.segmentID) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(quote.meeting.displayTitle) · \(ElapsedTime.stamp(quote.t))").font(.callout).foregroundStyle(Color(nsColor: .linkColor))
                        ProtectedText(quote.text).lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Opens the meeting at this moment"))
            }
        }
    }

    private var mentions: some View {
        DetailSection(String(localized: "Mentions", comment: "Section title: list of passages where the name appears in transcripts")) {
            ForEach(model.entityRefs) { r in
                Button {
                    if let s = r.segmentID { model.open(meeting: r.meeting.id, segment: s) } else { model.open(meeting: r.meeting.id, at: r.t) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(r.meeting.displayTitle) · \(ElapsedTime.stamp(r.t))").font(.callout).foregroundStyle(Color(nsColor: .linkColor))
                        if let context = r.context {
                            Text(Self.emphasized(context, matching: r.surface, channel: r.channel, speaker: r.speaker, dark: colorScheme == .dark)).lineLimit(2)
                        } else {
                            Text(String(localized: "“\(r.surface)” (the transcript has expired)", comment: "Mention whose transcript was purged"))
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Opens the meeting at this moment"))
            }
        }
    }

    /// The mention's text with the name that matched marked, as the search results show it.
    static func emphasized(_ text: String, matching surface: String, channel: Channel? = nil, speaker: SpeakerTag? = nil, dark: Bool = false) -> AttributedString {
        var out = AttributedString(text)
        if !surface.isEmpty {
            var start = out.startIndex
            while start < out.endIndex, let found = out[start...].range(of: surface, options: [.caseInsensitive, .diacriticInsensitive]) {
                out.markMatch(found, dark: dark)
                start = found.upperBound
            }
        }
        guard let channel else { return out }
        // "Me: " in the channel's color, as the search results and Ask show a quote.
        // The speaker's label when the meeting has speaker data, as the transcript and the search results print it.
        return channel.quotePrefix(for: speaker, tint: channel.tint(ordinal: speaker?.ordinal ?? 1)) + out
    }

    private func open(_ n: GraphNode) {
        switch n.ref.kind {
        case .entity: model.selectedEntityID = n.ref.id
        case .meeting: model.open(meeting: n.ref.id)
        case .task, .decision: break
        }
    }

    private func symbol(_ k: NodeKind) -> String {
        switch k {
        case .entity: "circle.hexagongrid"
        case .decision: "checkmark.seal"
        case .task: "checklist"
        case .meeting: "waveform"
        }
    }
}
