// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Asks where to merge an entry and says exactly what moves.
struct MergeSheet: View {
    @Bindable var model: ContextModel
    let request: MergeRequest

    private var source: Entity { request.source }
    private var targetID: Binding<Int64?> {
        Binding(get: { model.mergeRequest?.targetID }, set: { model.mergeRequest?.targetID = $0 })
    }
    private var target: Entity? { model.entity(model.mergeRequest?.targetID) }
    private var summary: MergeSummary? { model.mergeRequest.flatMap(model.mergeSummary(for:)) }

    /// Names the kind of the entry, like the Delete buttons.
    private var title: Text {
        let name = source.displayName
        return switch source.kind {
        case .person: Text("Merge “\(name)” into Another Person")
        case .project: Text("Merge “\(name)” into Another Project")
        case .client: Text("Merge “\(name)” into Another Client")
        case .team: Text("Merge “\(name)” into Another Team")
        case .system: Text("Merge “\(name)” into Another System")
        case .topic: Text("Merge “\(name)” into Another Topic")
        }
    }

    private func notes(target: Entity, summary: MergeSummary) -> Text {
        var text = Text("“\(source.displayName)” is then removed from the list.")
        if summary.dropsNote { text = text + sentenceGap + Text("Its note is discarded.") }
        if summary.dropsEmail, let email = request.footprint.email {
            text = text + sentenceGap + Text("Its email address \(email) is discarded; “\(target.displayName)” keeps its own.")
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title, symbol: "arrow.triangle.merge")
            Text("Use this when two entries are the same person, project or client.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            // One group, like the Import and Backup sheets: the label in one column, the picker in another.
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Merge into").gridColumnAlignment(.leading)
                    Picker("Merge into", selection: targetID) {
                        Text("Choose…").tag(Int64?.none)
                        ForEach(model.mergeCandidates(for: source)) { e in
                            Text(e.displayName).tag(Int64?.some(e.id))
                        }
                    }
                    .labelsHidden()
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground()
            if let target, let summary {
                VStack(alignment: .leading, spacing: 6) {
                    Text("“\(target.displayName)” gets:").font(.subheadline.weight(.semibold))
                    if !summary.newAliases.isEmpty {
                        SummaryLine(symbol: "tag",
                                    text: String(localized: "\(summary.newAliases.count) aliases: \(summary.newAliases.formatted(.list(type: .and)))",
                                                 comment: "Merge summary; the first argument is a count (needs plural forms), the second a list of names"))
                    }
                    if summary.mentions > 0 {
                        SummaryLine(symbol: "text.quote",
                                    text: String(localized: "\(summary.mentions) mentions", comment: "Merge summary; count (needs plural forms)"))
                    }
                    if summary.meetings > 0 {
                        SummaryLine(symbol: "waveform",
                                    text: String(localized: "Links to \(summary.meetings) meetings",
                                                 comment: "Merge summary: meetings that mention the entry or list it as an attendee; count (needs plural forms)"))
                    }
                    if summary.tasks > 0 {
                        SummaryLine(symbol: "checklist", text: String(localized: "\(summary.tasks) tasks", comment: "Merge summary; count (needs plural forms)"))
                    }
                    if summary.relations > 0 {
                        SummaryLine(symbol: "link", text: String(localized: "\(summary.relations) relations", comment: "Merge summary; count (needs plural forms)"))
                    }
                    if summary.glossaryTerms > 0 {
                        SummaryLine(symbol: "character.book.closed",
                                    text: String(localized: "\(summary.glossaryTerms) glossary terms", comment: "Merge summary; count (needs plural forms)"))
                    }
                    if summary.series > 0 {
                        SummaryLine(symbol: "repeat",
                                    text: String(localized: "\(summary.series) recurring meetings", comment: "Merge summary; count (needs plural forms)"))
                    }
                    if summary.movesEmail, let email = request.footprint.email {
                        SummaryLine(symbol: "envelope", text: String(localized: "The email address \(email)", comment: "Merge summary: the email moves to the other entry"))
                    }
                    if summary.isEmpty {
                        SummaryLine(symbol: "minus.circle", text: String(localized: "Nothing else: this entry isn’t used yet.", comment: "Merge summary when nothing moves"))
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    // What happens to the entry, as one paragraph; the irreversible part stands last on its own.
                    notes(target: target, summary: summary)
                    Text("You can’t undo a merge, but you can remove aliases from “\(target.displayName)” afterwards.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.mergeRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Merge") { Task { await model.confirmMerge() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(target == nil || model.isWorking)
            }
        }
        .padding(20)
        .frame(width: SheetLayout.width)
        .environment(\.iconColumnAlignment, .leading)
    }
}

/// Says what deleting (or dismissing) an entry removes and what stays.
struct DeleteEntitySheet: View {
    @Bindable var model: ContextModel
    let request: DeleteRequest

    private var name: String { request.entity.displayName }
    private var s: DeletionSummary { request.summary }

    /// The sheet's notes as one paragraph.
    private var footnote: String {
        var sentences = [String(localized: "Transcripts and minutes don’t change.")]
        if request.isDismissal {
            sentences.append(String(localized: "If this person attends a future calendar event, Vauta suggests them again."))
        }
        sentences.append(String(localized: "You can’t undo this.", comment: "Footnote of a sheet that deletes something for good"))
        return sentences.joined(separator: " ")
    }

    /// Names the object, like the editor's "Delete <Kind>…" button and the term and recurring meeting dialogs.
    private var deleteTitle: LocalizedStringKey {
        switch request.entity.kind {
        case .person: "Delete Person"
        case .project: "Delete Project"
        case .client: "Delete Client"
        case .team: "Delete Team"
        case .system: "Delete System"
        case .topic: "Delete Topic"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(Text(request.isDismissal ? "Dismiss “\(name)”?" as LocalizedStringKey : "Delete “\(name)”?"),
                        symbol: request.isDismissal ? "person.crop.circle.badge.xmark" : "trash", tint: .red)
            if s.removesAnything {
                VStack(alignment: .leading, spacing: 6) {
                    Text("This removes:").font(.subheadline.weight(.semibold))
                    if s.aliases > 0 {
                        SummaryLine(symbol: "tag", text: String(localized: "\(s.aliases) aliases", comment: "Delete summary; count (needs plural forms)"))
                    }
                    if s.mentions > 0 {
                        SummaryLine(symbol: "text.quote",
                                    text: String(localized: "\(s.mentions) mentions", comment: "Delete summary; count (needs plural forms)"))
                    }
                    if s.meetings > 0 {
                        SummaryLine(symbol: "waveform",
                                    text: String(localized: "Links to \(s.meetings) meetings",
                                                 comment: "Delete summary: meetings that mention the entry or list it as an attendee; count (needs plural forms)"))
                    }
                    if s.relations > 0 {
                        SummaryLine(symbol: "link", text: String(localized: "\(s.relations) relations", comment: "Delete summary; count (needs plural forms)"))
                    }
                    if s.mergedEntries > 0 {
                        SummaryLine(symbol: "arrow.triangle.merge",
                                    text: String(localized: "\(s.mergedEntries) entries merged into it earlier", comment: "Delete summary; count (needs plural forms)"))
                    }
                }
            }
            if s.detachesAnything {
                VStack(alignment: .leading, spacing: 6) {
                    Text("These stay, without the link:").font(.subheadline.weight(.semibold))
                    if s.tasks > 0 {
                        SummaryLine(symbol: "checklist", text: String(localized: "\(s.tasks) tasks lose their owner", comment: "Delete summary; count (needs plural forms)"))
                    }
                    if s.glossaryTerms > 0 {
                        SummaryLine(symbol: "character.book.closed",
                                    text: String(localized: "\(s.glossaryTerms) glossary terms", comment: "Delete summary: terms that stay but lose the link; count (needs plural forms)"))
                    }
                    if s.series > 0 {
                        SummaryLine(symbol: "repeat",
                                    text: String(localized: "\(s.series) recurring meetings", comment: "Delete summary: series that no longer list the entry; count (needs plural forms)"))
                    }
                }
            }
            // One paragraph, like every other sheet's footnote.
            SheetFootnote(footnote)
            HStack {
                Spacer()
                // The same policy as the term and recurring-meeting confirmations: Cancel is the default button
                // and the destructive one is bordered with a red label, so Return never deletes.
                Button("Cancel", role: .cancel) { model.deleteRequest = nil }
                    .keyboardShortcut(.defaultAction)
                Button(request.isDismissal ? "Dismiss Person" : deleteTitle, role: .destructive) { Task { await model.confirmDelete() } }
                    .destructiveSheetButton()
                    .disabled(model.isWorking)
            }
        }
        .onExitCommand { model.deleteRequest = nil }
        .padding(20)
        .frame(width: SheetLayout.width)
        .environment(\.iconColumnAlignment, .leading)
    }
}

private struct SummaryLine: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
        .labelStyle(AlignedIconLabelStyle())
    }
}

/// What joins two sentences in one paragraph: a space, except in Japanese and Chinese, which don't put one after 。
private var sentenceGap: Text {
    Text(verbatim: String(localized: "sentence.separator", defaultValue: " ",
                          comment: "Joins two sentences of one paragraph: a space, empty in Japanese and Chinese"))
}
