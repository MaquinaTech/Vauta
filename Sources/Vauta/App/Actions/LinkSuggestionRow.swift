// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// The words of the link rows that are not in a view's literal text: button titles by the kind of link, and what VoiceOver reads.
enum LinkLabels {
    static func date(_ row: LinkRow) -> String { TaskDueFormat.text(row.earlierMeetingDate) }

    /// What the question names: the date of the earlier meeting, and for a task its title too ("12 Sep · Weekly sync").
    static func when(_ row: LinkRow) -> String {
        row.link.kind == .task ? "\(date(row)) · \(row.earlierMeetingTitle)" : date(row)
    }

    /// "due date changed from 10 Oct": a task offered as the same as an earlier one that had another due day (the earlier day is the detail).
    static func dueChanged(_ row: LinkRow) -> String? {
        guard row.link.kind == .task, row.link.relation == .same, let earlier = row.earlierDueDay, let now = row.newerDueDay, earlier != now else { return nil }
        return String(localized: "due date changed from \(TaskDueFormat.text(earlier))", comment: "Under a suggestion that a task is the same as an earlier one: the earlier task had another due day; the argument is that earlier day")
    }

    static func confirmTitle(_ row: LinkRow) -> String {
        switch (row.link.kind, row.link.relation) {
        case (_, .changes): String(localized: "Yes, It Changed", comment: "Button on a suggestion that a decision replaces an earlier one: the person confirms the decision changed")
        case (.task, _): String(localized: "Same Task", comment: "Button on a suggestion that a task is the same as one from an earlier meeting: the person confirms it")
        case (.decision, _): String(localized: "Same Decision", comment: "Button on a suggestion that a decision is the same as one from an earlier meeting: the person confirms it")
        }
    }

    static func dismissTitle(_ row: LinkRow) -> String {
        if row.link.kind == .task, row.link.relation == .same {
            return String(localized: "Not the Same", comment: "Button on a suggestion that a task is the same as an earlier one: the person says it is not, and it is not suggested again")
        }
        return String(localized: "Not Related", comment: "Button on a suggestion that a decision is the same as, or replaces, an earlier one: the person says it is not, and it is not suggested again")
    }

    /// What VoiceOver reads for a row: that it is a suggestion, the question, the earlier item, and the difference when there is one.
    static func spoken(_ row: LinkRow, newer: String?) -> String {
        var parts: [String] = []
        let date = Self.when(row)
        switch row.link.state {
        case .suggested:
            parts.append(String(localized: "Suggestion", comment: "VoiceOver: a link to an earlier meeting that the person has not confirmed yet"))
            switch (row.link.kind, row.link.relation) {
            case (_, .changes): parts.append(String(localized: "Different from \(date)?", comment: "Question under a decision: it may replace the decision of an earlier meeting; the argument is that meeting’s date"))
            case (.task, _): parts.append(String(localized: "Same task as on \(date)?", comment: "Question under a task: it may be the same as a task from an earlier meeting; the argument is that meeting’s date"))
            case (.decision, _): parts.append(String(localized: "Same decision as on \(date)?", comment: "Question under a decision: it may be the same as a decision from an earlier meeting; the argument is that meeting’s date"))
            }
        case .confirmed, .dismissed:
            parts.append(confirmed(row))
        }
        parts.append(row.earlierText)
        if let changed = dueChanged(row) { parts.append(changed) }
        if let evidence = row.link.evidence {
            let before = evidence.earlier.joined(separator: ", "), now = evidence.now.joined(separator: ", ")
            parts.append(String(localized: "Earlier: \(before.isEmpty ? "—" : before). Now: \(now.isEmpty ? "—" : now).", comment: "VoiceOver: what differs between a decision and the earlier one it may replace; the arguments are the earlier words and the new words"))
        }
        if row.earlierUnconfirmed { parts.append(VerificationText.unconfirmed) }
        return parts.joined(separator: ". ")
    }

    static func confirmed(_ row: LinkRow) -> String {
        let date = Self.date(row)
        switch (row.link.kind, row.link.relation) {
        case (_, .changes): return String(localized: "Changed since \(date)", comment: "Under a decision the person confirmed replaces an earlier one; the argument is that meeting’s date")
        case (.task, _): return String(localized: "Same task as on \(date)", comment: "Under a task the person confirmed is the same as one from an earlier meeting; the argument is that meeting’s date")
        case (.decision, _): return String(localized: "Same decision as on \(date)", comment: "Under a decision the person confirmed is the same as one from an earlier meeting; the argument is that meeting’s date")
        }
    }
}

/// What the person can do with a row.
struct LinkRowActions {
    var confirm: () -> Void
    var dismiss: () -> Void
    var show: () -> Void
    var undo: () -> Void
}

/// Under a task or a decision: a link to an earlier meeting, always a question until the person confirms it. Differences are in
/// bold and spoken as "Earlier: … Now: …"; the earlier item keeps its "Unconfirmed" mark; nothing is changed by the row itself.
struct LinkSuggestionRow: View {
    let row: LinkRow
    let actions: LinkRowActions

    var body: some View {
        switch row.link.state {
        case .suggested: suggestion
        case .confirmed: confirmed
        case .dismissed: EmptyView()
        }
    }

    private var dateText: Text { Text(verbatim: LinkLabels.when(row)).bold() }

    private var question: Text {
        switch (row.link.kind, row.link.relation) {
        case (_, .changes): Text("Different from \(dateText)?", comment: "Question under a decision: it may replace the decision of an earlier meeting; the argument is that meeting’s date")
        case (.task, _): Text("Same task as on \(dateText)?", comment: "Question under a task: it may be the same as a task from an earlier meeting; the argument is that meeting’s date")
        case (.decision, _): Text("Same decision as on \(dateText)?", comment: "Question under a decision: it may be the same as a decision from an earlier meeting; the argument is that meeting’s date")
        }
    }

    private var suggestion: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary).accessibilityHidden(true)
                question.font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            // The label below says all of this once; the visible question is not read a second time.
            .accessibilityHidden(true)
            earlier
            // Ordinary bordered buttons (the table cell would flatten them to plain text otherwise), side by side when they fit and one
            // under the other when a longer language or a narrow column does not leave the room.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(alignment: .leading, spacing: 6) { buttons }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .quaternarySystemFill)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: LinkLabels.spoken(row, newer: nil)))
    }

    @ViewBuilder private var buttons: some View {
        Button(LinkLabels.confirmTitle(row), action: actions.confirm).buttonStyle(.borderedProminent)
        Button(LinkLabels.dismissTitle(row), action: actions.dismiss)
        showButton
    }

    private var showButton: some View {
        Button(action: actions.show) { Text("Show", comment: "Button on a link to an earlier meeting: opens that meeting at the item the link is about") }
            .help(Text("Open the earlier meeting at this item", comment: "Help tag of the Show button on a link to an earlier meeting"))
    }

    /// The earlier item: its words (the differing ones in bold, with the new words after an arrow) and, for a task, who, when and how it stands.
    @ViewBuilder private var earlier: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                ProtectedText(emphasizedEarlier).font(.callout).lineLimit(3)
                if row.earlierUnconfirmed { UnconfirmedBadge() }
            }
            if let meta = meta { Text(verbatim: meta).font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityHidden(true)
    }

    private var emphasizedEarlier: Text {
        LinkEmphasis.earlier(row.earlierText, bold: row.link.evidence?.earlier ?? [], now: row.link.evidence?.now ?? [])
    }

    private var meta: String? {
        // A task's question already names the meeting; a decision's names the date only.
        var pieces = row.link.kind == .task ? [] : [row.earlierMeetingTitle]
        if row.link.kind == .task {
            if let owner = row.earlierOwner, !owner.isEmpty { pieces.append(owner) }
            if let changed = LinkLabels.dueChanged(row) { pieces.append(changed) }
            else if let day = row.earlierDueDay { pieces.append(String(localized: "due \(TaskDueFormat.text(day))", comment: "Under a suggestion about a task: the due day of the earlier task")) }
            if let status = row.earlierStatus {
                pieces.append(status == .done ? String(localized: "Done", comment: "Task status") : status == .dropped ? String(localized: "Dropped", comment: "Task status") : String(localized: "Open", comment: "Task status"))
            }
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
    }

    private var confirmed: some View {
        HStack(spacing: 6) {
            Image(systemName: "link").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(verbatim: LinkLabels.confirmed(row)).font(.callout).foregroundStyle(.secondary)
            Button(action: actions.show) { Text("Show", comment: "Button on a link to an earlier meeting: opens that meeting at the item the link is about") }
                .buttonStyle(.link).font(.callout)
                .help(Text("Open the earlier meeting at this item", comment: "Help tag of the Show button on a link to an earlier meeting"))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: LinkLabels.spoken(row, newer: nil)))
        // The combined element hides its button, so the actions are named here for VoiceOver and the keyboard as well as for the menu.
        .accessibilityAction(named: Text("Show", comment: "Button on a link to an earlier meeting: opens that meeting at the item the link is about"), actions.show)
        .accessibilityAction(named: Text("Undo Link", comment: "Menu item on a confirmed link to an earlier meeting: it goes back to being a suggestion"), actions.undo)
        .contextMenu {
            Button(action: actions.undo) { Text("Undo Link", comment: "Menu item on a confirmed link to an earlier meeting: it goes back to being a suggestion") }
            Button(action: actions.show) { Text("Show", comment: "Button on a link to an earlier meeting: opens that meeting at the item the link is about") }
        }
    }
}

/// A text with some of its words in bold: the words that differ from the other decision.
enum LinkEmphasis {
    private static let marker = "\u{FFFC}"

    static func attributed(_ string: String, bold spans: [String]) -> AttributedString {
        var ranges: [Range<String.Index>] = []
        for span in spans where !span.isEmpty {
            if let r = string.range(of: span, options: [.caseInsensitive, .diacriticInsensitive]), !ranges.contains(where: { $0.overlaps(r) }) { ranges.append(r) }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var out = AttributedString()
        var cursor = string.startIndex
        for r in ranges {
            if cursor < r.lowerBound { out.append(AttributedString(String(string[cursor..<r.lowerBound]))) }
            var word = AttributedString(String(string[r]))
            word.inlinePresentationIntent = .stronglyEmphasized
            out.append(word)
            cursor = r.upperBound
        }
        if cursor < string.endIndex { out.append(AttributedString(String(string[cursor...]))) }
        return out
    }

    /// The earlier item between its language's quotation marks, the differing words in bold, and the new words after an arrow.
    static func earlier(_ string: String, bold spans: [String], now: [String]) -> Text {
        let template = String(localized: "“\(marker)”", comment: "The earlier item of a link, between quotation marks; the argument is its text")
        let parts = template.components(separatedBy: marker)
        var out = AttributedString(parts.first ?? "")
        out.append(attributed(string, bold: spans))
        if parts.count > 1 { out.append(AttributedString(parts[1...].joined())) }
        if !now.isEmpty {
            out.append(AttributedString(" → "))
            out.append(attributed(now.joined(separator: ", "), bold: [now.joined(separator: ", ")]))
        }
        return Text(out)
    }
}

/// The row of a task or decision in the Minutes and Tasks tabs, wired to the window's model. Nothing when the item has no link.
struct LinkRowHost: View {
    @Bindable var model: MeetingsModel
    let kind: LinkKind
    let id: Int64

    /// What a suggestion row takes in a table, for the first estimate of the table's height (it is measured afterwards).
    static let estimatedHeight: CGFloat = 96

    var body: some View {
        if let row = model.linkRow(kind, id) {
            LinkSuggestionRow(row: row, actions: LinkRowActions(
                confirm: { Task { await model.confirm(row) } },
                dismiss: { Task { await model.dismiss(row) } },
                show: { model.showEarlier(row) },
                undo: { Task { await model.undoLink(row) } }))
        }
    }
}
