// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// The sections of a brief, in the fixed order of the design: people, last time, open tasks, related meetings, documents and notes,
/// reminders, the invitation and, when a model wrote one, the suggested agenda. A section with nothing in it is not there. The window
/// shows three lines of each with "Show all (n)"; the panel's recording row shows the sections it names and three lines of each.
struct BriefContentView: View {
    let sections: [BriefSection]
    let agenda: BriefAgendaState
    /// Only these sections are drawn (the recording row shows "Last time" and "Open tasks").
    var only: Set<BriefSectionKind>?
    var showsAgenda = true
    /// A suggested agenda that has lines comes right after the header, before the sections (Upcoming and the Brief tab); the deterministic
    /// sections keep their order. The notes about an agenda that is missing stay at the end.
    var agendaFirst = false
    var compact = false
    /// Explains why the Reminders section is absent (Upcoming only).
    var reminders = BriefRemindersState.off
    /// A reminder of the page that Settings can fix: "Allow Reminders in Settings…" opens the pane.
    var openSettings: (() -> Void)?
    /// Closes the line about Reminders (Upcoming only); it is shown until then.
    var dismissRemindersHint: (() -> Void)?
    /// An agenda state worth a line: "No suggestions this time", "Suggestions need a model." (Upcoming only).
    var explainsAgenda = false
    var linkPerson: (() -> Void)?
    let open: (BriefLink) -> Void
    @ViewLocalState private var expanded: Set<BriefSectionKind> = []
    @Environment(\.briefViewOptions) private var options

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : PaneLayout.section) {
            if showsAgenda, agendaFirst, case .lines = agenda { agendaBlock }
            ForEach(visible, id: \.kind) { section in
                SectionBlock(section: section, compact: compact, expanded: expanded.contains(section.kind) || options.expandedSections.contains(section.kind), linkPerson: linkPerson, open: open) {
                    expanded.insert(section.kind)
                }
            }
            if showsReminderHint {
                RemindersHint(chooseList: reminders == .noLists, openSettings: openSettings, dismiss: dismissRemindersHint)
            }
            if showsAgenda, !(agendaFirst && agenda.lines.isEmpty == false) { agendaBlock }
        }
    }

    private var visible: [BriefSection] {
        sections.filter { (only?.contains($0.kind) ?? true) && !$0.items.isEmpty }
    }

    private var showsReminderHint: Bool {
        only == nil && explainsAgenda && [.notAsked, .denied, .noLists].contains(reminders)
    }

    @ViewBuilder private var agendaBlock: some View {
        switch agenda {
        case .lines(let lines):
            AgendaBlock(lines: lines, items: sections.flatMap(\.items), compact: compact, open: open)
        case .noSuggestions where explainsAgenda:
            AgendaNote(text: String(localized: "No suggestions this time", comment: "Meetings, Upcoming: the model wrote no usable suggested agenda; no reason is given"), symbol: "text.badge.xmark")
        case .unavailable where explainsAgenda:
            AgendaNote(text: String(localized: "Suggestions need a model.", comment: "Meetings, Upcoming: the suggested agenda needs a language model that is not available; Settings → Models sets one up"), symbol: "cpu",
                       showsModels: true)
        default:
            EmptyView()
        }
    }

    private struct SectionBlock: View {
        let section: BriefSection
        let compact: Bool
        let expanded: Bool
        let linkPerson: (() -> Void)?
        let open: (BriefLink) -> Void
        let showAll: () -> Void

        /// "Last time" shows what the previous meeting left (a summary line, up to three decisions, tasks and questions); the other sections
        /// show three lines and "Show all".
        private var limit: Int { expanded || section.kind == .lastTime ? BriefSnapshot.windowLimit : BriefSnapshot.panelLimit }
        private var items: [BriefItem] { Array(section.items.prefix(limit)) }
        private var hiddenCount: Int { section.items.count - items.count }

        var body: some View {
            VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                Label {
                    Text(verbatim: BriefLabels.title(section.kind))
                } icon: {
                    Image(systemName: BriefLabels.symbol(section.kind))
                }
                .font(compact ? .callout.weight(.semibold) : .headline)
                .accessibilityAddTraits(.isHeader)
                if section.kind == .openTasks, items.contains(where: \.isConfirmedYours), items.contains(where: { !$0.isConfirmedYours }) {
                    // What the person owes first, then what the others owe: each group says so, and "Me" needs no owner on its lines.
                    // A task whose owner nothing confirms is not listed under "Me" as if it were certain: it stays with the others,
                    // saying "Me" and carrying the mark.
                    group(BriefLabels.yours, items.filter(\.isConfirmedYours), hidesOwner: true)
                    group(BriefLabels.others, items.filter { !$0.isConfirmedYours })
                } else if section.kind == .lastTime {
                    lastTimeGroups
                } else {
                    ForEach(items) { item in BriefRow(item: item, compact: compact, linkPerson: linkPerson, open: open) }
                }
                if !compact, hiddenCount > 0 {
                    Button(BriefLabels.showAll(section.items.count), action: showAll)
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            .accessibilityElement(children: .contain)
        }

        /// The summary line, then what the meeting left, told apart by a sub-heading and not by an icon alone. Every line is of the same
        /// meeting, so the date is on the summary line only.
        @ViewBuilder private var lastTimeGroups: some View {
            ForEach(items.filter { $0.kind == .summary }) { item in BriefRow(item: item, compact: compact, linkPerson: linkPerson, open: open) }
            group(String(localized: "Decisions"), items.filter { $0.kind == .decision }, hidesDate: true)
            group(String(localized: "Tasks"), items.filter { $0.kind == .task })
            group(String(localized: "Open questions"), items.filter { $0.kind == .openQuestion }, hidesDate: true)
        }

        @ViewBuilder private func group(_ title: String?, _ rows: [BriefItem], hidesOwner: Bool = false, hidesDate: Bool = false) -> some View {
            if !rows.isEmpty {
                if let title {
                    Text(verbatim: title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                }
                ForEach(rows) { item in BriefRow(item: item, compact: compact, hidesOwner: hidesOwner, hidesDate: hidesDate, linkPerson: linkPerson, open: open) }
            }
        }
    }
}

private extension BriefItem {
    /// The person's own task with an owner the minutes back.
    var isConfirmedYours: Bool { isYours && !ownerUncertain }
}

/// One line of the brief.
struct BriefRow: View {
    let item: BriefItem
    var compact = false
    /// The line sits under a heading that names the owner ("Me") or the meeting's date (Last time).
    var hidesOwner = false
    var hidesDate = false
    var linkPerson: (() -> Void)?
    let open: (BriefLink) -> Void
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Group {
            if item.link == .none || item.kind == .invitationLine {
                content.accessibilityElement(children: .ignore).accessibilityLabel(Text(verbatim: BriefLabels.spoken(item)))
                    .accessibilityActions { linkPersonAction }
            } else {
                Button { open(item.link) } label: { content }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: BriefLabels.spoken(item)))
                    .accessibilityHint(BriefLabels.linkAction(item.link).map { Text(verbatim: $0) } ?? Text(verbatim: ""))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityActions { linkPersonAction }
            }
        }
        // In the panel's scrolling part each row is a place where the visible area may end: the card is taller than the screen leaves it,
        // and the cut falls between two rows, never through one.
        .panelRowStop(if: compact)
        .panelProbe(compact ? .note : nil)
    }

    @ViewBuilder private var linkPersonAction: some View {
        if item.kind == .person, item.entityID == nil, let linkPerson {
            Button(String(localized: "Link to a person…", comment: "Brief: opens Settings → Context to link a name from the invitation to a person; suggest-only, nothing is linked automatically")) { linkPerson() }
        }
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: BriefLabels.symbol(item.kind))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if item.kind == .invitationLine {
                        ProtectedText(item.text).font(compact ? .callout : .body)
                    } else {
                        Text(verbatim: item.text).font(compact ? .callout : .body)
                    }
                    if item.kind == .note { Text(verbatim: BriefLabels.noteBadge).font(.caption).padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule()) }
                }
                .lineLimit(compact ? 2 : 3)
                .multilineTextAlignment(.leading)
                if let detail = detailLine { detail }
                if let snippet = item.detail, [.relatedMeeting, .document, .note].contains(item.kind), !compact {
                    Text(verbatim: snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                // A decision the person confirmed replaces an earlier one: both are shown, the older one under it in secondary text.
                if let older = item.replacesText, item.kind == .decision, !compact {
                    Text(verbatim: older).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                marks
                if item.kind == .person, item.entityID == nil, let linkPerson, !compact {
                    Button(String(localized: "Link to a person…", comment: "Brief: opens Settings → Context to link a name from the invitation to a person; suggest-only, nothing is linked automatically")) { linkPerson() }
                        .buttonStyle(.link).font(.callout)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Date, owner, due date and source in one quiet line.
    private var detailLine: Text? {
        var pieces: [String] = []
        switch item.kind {
        case .person:
            if !item.historyKnown {
                break
            } else if item.meetingsTogether == 0 { pieces.append(BriefLabels.noEarlierMeetings) } else {
                if let met = item.lastMet { pieces.append(BriefLabels.lastMet(met)) }
                pieces.append(BriefLabels.meetingsTogether(item.meetingsTogether))
            }
        case .summary:
            if let date = item.meetingDate { pieces.append(date.formatted(date: .abbreviated, time: .omitted)) }
            if let title = item.source { pieces.append(title) }
        case .task:
            // The person's own tasks say "Me" wherever they are listed, not the name the calendar or the transcript gave them.
            if item.isYours { if !hidesOwner { pieces.append(BriefLabels.yours) } } else if let owner = item.owner, !owner.isEmpty, !hidesOwner { pieces.append(owner) }
            if let due = item.due { pieces.append(due.formatted(date: .abbreviated, time: .omitted)) }
        case .decision, .openQuestion:
            if let date = item.meetingDate, !hidesDate { pieces.append(date.formatted(date: .abbreviated, time: .omitted)) }
        case .relatedMeeting:
            if let date = item.meetingDate { pieces.append(date.formatted(date: .abbreviated, time: .omitted)) }
        case .reminder:
            if let list = item.source { pieces.append(list) }
            if let due = item.due { pieces.append(due.formatted(date: .abbreviated, time: .omitted)) }
        case .material, .document, .note, .invitationLine:
            break
        }
        guard !pieces.isEmpty else { return nil }
        return Text(verbatim: pieces.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
    }

    @ViewBuilder private var marks: some View { BriefMarks(item: item) }
}

/// The marks of a line: overdue, due before the meeting, unconfirmed, uncertain owner, from the minutes. Each is a glyph and a word.
/// The panel card draws the same row under its lines, so a line is never shown as plain fact when it is marked.
struct BriefMarks: View {
    let item: BriefItem

    var body: some View {
        let flags = item.overdue || item.dueBeforeMeeting || item.unconfirmed || item.ownerUncertain || item.fromMinutes || item.inReminders || BriefLabels.linkMark(item) != nil
        if flags {
            // Wraps onto a second line when the marks together are wider than the card, so a card never grows past its column.
            TokenFlowLayout(spacing: 6) {
                if item.overdue { Mark(symbol: "exclamationmark.triangle", text: BriefLabels.overdue) }
                if item.dueBeforeMeeting { Mark(symbol: "clock.badge.exclamationmark", text: BriefLabels.dueBeforeMeeting) }
                if item.unconfirmed { UnconfirmedBadge() }
                // A glyph of its own and the words, so it is never read as a second "Unconfirmed" (the owner is announced by the line's VoiceOver label).
                if item.ownerUncertain, item.owner != nil || item.isYours {
                    Mark(symbol: "person.crop.circle.badge.questionmark", text: String(localized: "Owner not confirmed", comment: "A short mark: nothing in the passage the model cited confirms the owner of a task (a note after the owner in exported minutes, a mark on a line of the brief)"))
                }
                if item.fromMinutes { Mark(symbol: "doc.plaintext", text: BriefLabels.fromTheMinutes, tint: false) }
                if item.inReminders { Mark(symbol: "checklist", text: BriefLabels.inReminders, tint: false) }
                if let link = BriefLabels.linkMark(item) { Mark(symbol: "arrow.triangle.2.circlepath", text: link, tint: false) }
            }
            .font(.footnote)
        }
    }
}

/// A glyph and a word, never a colour alone.
private struct Mark: View {
    let symbol: String
    let text: String
    var tint = true
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .foregroundStyle(tint && prominence != .increased ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            Text(verbatim: text).foregroundStyle(.secondary)
        }
        .fixedSize()
        .accessibilityHidden(true)
    }
}

private struct RemindersHint: View {
    /// Access is allowed but no list is chosen.
    let chooseList: Bool
    let openSettings: (() -> Void)?
    let dismiss: (() -> Void)?

    var body: some View {
        // The sentence and the button to Settings are on separate lines, so a longer translation wraps without leaving the button beside it.
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "bell.slash").foregroundStyle(.secondary).accessibilityHidden(true)
                if chooseList {
                    Text("Choose reminder lists in Settings to see related reminders", comment: "Meetings, Upcoming: a quiet line where the Reminders section would be, when Reminders is allowed but no list is chosen")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Allow Reminders in Settings to see related reminders", comment: "Meetings, Upcoming: a quiet line where the Reminders section would be, when reminders are on but not allowed")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if let dismiss {
                    Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                        .buttonStyle(.borderless)
                        .help(Text("Dismiss"))
                        .accessibilityLabel(Text("Dismiss"))
                }
            }
            if let openSettings {
                Button(SettingsModel.Pane.calendar.openTitle, action: openSettings).buttonStyle(.link).font(.callout)
                    .padding(.leading, 22)
            }
        }
    }
}

private struct AgendaNote: View {
    let text: String
    let symbol: String
    var showsModels = false
    @Environment(\.openModelsSettings) private var openModels

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(verbatim: text).font(.callout).foregroundStyle(.secondary)
            if showsModels, let openModels {
                Button(SettingsModel.Pane.models.openTitle, action: openModels).buttonStyle(.link).font(.callout)
            }
        }
    }
}

/// The suggested agenda: lines the verifier accepted. Each cites the lines of the brief it comes from.
private struct AgendaBlock: View {
    let lines: [BriefAgendaLine]
    let items: [BriefItem]
    let compact: Bool
    let open: (BriefLink) -> Void
    @Environment(\.copyProtection) private var copyProtection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label {
                    Text(verbatim: BriefLabels.suggestedAgenda)
                } icon: {
                    Image(systemName: "list.bullet.clipboard")
                }
                .font(compact ? .callout.weight(.semibold) : .headline)
                .accessibilityAddTraits(.isHeader)
                Spacer()
                if !compact {
                    Button(String(localized: "Copy Agenda", comment: "Brief: copies the suggested agenda as plain text; blocked by Protect meeting text from copying")) { copy() }
                        .buttonStyle(.link)
                        .font(.callout)
                        .disabled(copyProtection)
                }
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: BriefLabels.agendaKind(line.kind))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .fixedSize()
                    Text(verbatim: line.text).font(compact ? .callout : .body).lineLimit(compact ? 3 : 4)
                    ForEach(line.cites, id: \.self) { id in
                        if let item = items.first(where: { $0.id == id }) {
                            if item.link != .none {
                                Button { open(item.link) } label: { Image(systemName: BriefLabels.symbol(item.kind)) }
                                    .buttonStyle(.borderless)
                                    .help(item.text)
                                    .accessibilityLabel(Text(verbatim: BriefLabels.spoken(item)))
                            } else {
                                // A line of the invitation has nothing to open; the glyph still shows what the suggestion rests on.
                                Image(systemName: BriefLabels.symbol(item.kind))
                                    .foregroundStyle(.secondary)
                                    .help(item.text)
                                    .accessibilityLabel(Text(verbatim: BriefLabels.spoken(item)))
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                // A line that rests on a decision or task the minutes could not back says so: the suggestion is no firmer than its source.
                if line.cites.contains(where: { id in items.first { $0.id == id }?.unconfirmed == true }) {
                    UnconfirmedBadge().font(.footnote).padding(.leading, 2)
                }
                }
                .accessibilityElement(children: .contain)
            }
            if !compact {
                Text("Each suggestion cites the lines it comes from.", comment: "Brief: under the suggested agenda; every line is checked against the lines of the brief it names")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func copy() {
        guard !copyProtection else { return }
        let text = lines.map { "\(BriefLabels.agendaKind($0.kind)): \($0.text)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// How the brief is drawn when a rendering needs a state that is otherwise reached by a click.
struct BriefViewOptions: Equatable {
    var startsExpanded = false
    var expandedSections: Set<BriefSectionKind> = []
}

private struct BriefViewOptionsKey: EnvironmentKey {
    static let defaultValue = BriefViewOptions()
}

extension EnvironmentValues {
    var briefViewOptions: BriefViewOptions {
        get { self[BriefViewOptionsKey.self] }
        set { self[BriefViewOptionsKey.self] = newValue }
    }
}
