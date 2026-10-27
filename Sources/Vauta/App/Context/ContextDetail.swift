// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// The detail pane: the open form, or what the section is for.
struct ContextDetail: View {
    @Bindable var model: ContextModel

    var body: some View {
        if !model.isEditing, model.hasLoaded, model.isListEmpty, model.isFiltering {
            // The list pane says "No Results"; the detail pane shows only the section's icon, as the Meetings window
            // does, so two messages don't compete.
            Image(systemName: model.section.symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
        } else if !model.isEditing {
            EmptyStateView(model.hasLoaded && model.isListEmpty
                               ? Text(ContextHelp.emptyTitle(model.section)) : Text(ContextHelp.selectTitle(model.section)),
                           symbol: model.section.symbol, message: ContextHelp.about(model.section),
                           messageWidth: model.section == .series ? 330 : nil) {
                // With calendar people waiting, reviewing them is the next step: that button is the prominent one.
                if model.section == .people && model.pendingCount > 0, let first = model.entities.first(where: { !$0.confirmed }) {
                    // One group, each button as wide as its label.
                    HStack(spacing: 8) {
                        Button("Review Calendar People (\(model.pendingCount))") { model.navigate(.select(.entity(first.id))) }
                            .buttonStyle(.borderedProminent)
                        Button(ContextHelp.addTitle(model.section)) { model.navigate(.create) }
                    }
                    .fixedSize()
                } else {
                    Button(ContextHelp.addTitle(model.section)) { model.navigate(.create) }
                }
            }
        } else {
            VStack(spacing: 0) {
                switch model.section {
                case .people, .work: EntityEditor(model: model)
                case .glossary: TermEditor(model: model)
                case .series: SeriesEditor(model: model)
                }
                Divider()
                ContextFormBar(model: model)
            }
        }
    }
}

/// The height of the bars under the list and under the form, so their dividers line up.
enum ContextBarLayout {
    static let height: CGFloat = 44
}

/// Revert and Save, under every form.
struct ContextFormBar: View {
    @Bindable var model: ContextModel

    var body: some View {
        // The full labels when they fit. Short of room, Revert loses its words first (its icon and tooltip say
        // enough); Delete, the action with a consequence, keeps its words and shrinks to its icon only where even
        // that doesn't fit, so the bar never makes the form wider than the window.
        ViewThatFits(in: .horizontal) {
            bar(compactRevert: false, compactDelete: false)
            bar(compactRevert: true, compactDelete: false)
            bar(compactRevert: true, compactDelete: true)
        }
        .padding(.horizontal, 20)
        .frame(height: ContextBarLayout.height)
    }

    private func bar(compactRevert: Bool, compactDelete: Bool) -> some View {
        HStack {
            if !model.isCreating, let title = deleteTitle, !isSelfEntry, !isPending {
                Button(role: .destructive) { Task { await model.requestRemoval(of: model.selection) } } label: {
                    if compactDelete {
                        Label(title, systemImage: "trash").labelStyle(.iconOnly)
                    } else {
                        Text(title)
                    }
                }
                .help(Text(title))
                .accessibilityLabel(Text(title))
                .disabled(model.isWorking)
            }
            if model.hasUnsavedChanges {
                Text("Edited").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { model.revert() } label: {
                if model.isCreating {
                    Text("Cancel")
                } else if compactRevert {
                    Label("Revert", systemImage: "arrow.uturn.backward").labelStyle(.iconOnly)
                } else {
                    Text("Revert")
                }
            }
            .help(model.isCreating ? Text("Cancel") : Text("Revert"))
            .accessibilityLabel(model.isCreating ? Text("Cancel") : Text("Revert"))
            .keyboardShortcut(model.isCreating ? .cancelAction : nil)
            .disabled(!model.isCreating && !model.hasUnsavedChanges)
            Button(model.isCreating ? "Add" as LocalizedStringKey : "Save") { Task { await model.saveCurrent() } }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave || model.isWorking || (!model.isCreating && !model.hasUnsavedChanges))
        }
    }

    /// Every kind of entry is deleted from the form bar.
    private var deleteTitle: LocalizedStringKey? {
        switch model.section {
        case .glossary: "Delete Term…"
        case .series: "Delete Recurring Meeting…"
        case .people: "Delete Person…"
        case .work: workDeleteTitle
        }
    }

    /// The entry's own kind, as for people and terms.
    private var workDeleteTitle: LocalizedStringKey {
        switch model.selectedEntity?.kind {
        case .project: "Delete Project…"
        case .client: "Delete Client…"
        case .team: "Delete Team…"
        case .system: "Delete System…"
        case .topic: "Delete Topic…"
        case .person, nil: "Delete Entry…"
        }
    }

    private var isSelfEntry: Bool { model.section.listsEntities && model.selectedEntity?.isSelf == true }
    /// A pending calendar person is confirmed or dismissed from its own section, not deleted.
    private var isPending: Bool { model.section.listsEntities && model.selectedEntity?.confirmed == false }

    private var canSave: Bool {
        switch model.section {
        case .people, .work: model.entityForm.canSave || model.selectedEntity?.isSelf == true
        case .glossary: model.termForm.canSave
        case .series: model.seriesForm.canSave
        }
    }
}

/// Explanations shown in empty states.
enum ContextHelp {
    static func about(_ section: ContextSection) -> String {
        switch section {
        case .people:
            String(localized: "Your colleagues and the nicknames people use for them. Vauta recognizes them in transcripts and remembers where and when they came up.",
                   comment: "Context editor: what the People section is for")
        case .work:
            String(localized: "Projects, clients, teams, systems and topics. Relate them to people (for example, “works on”) so Vauta knows which person a name refers to in each meeting.",
                   comment: "Context editor: what the Projects & Clients section is for")
        case .glossary:
            String(localized: "Acronyms and internal terms. When the transcript seems to have misheard one, Vauta suggests a correction; it never changes the text on its own.",
                   comment: "Context editor: what the Glossary section is for")
        case .series:
            String(localized: "Meetings that repeat, such as a weekly team meeting. Their usual people and projects help Vauta tell names apart.",
                   comment: "Context editor: what the Recurring Meetings section is for")
        }
    }

    static func selectTitle(_ section: ContextSection) -> String {
        switch section {
        case .people: String(localized: "Select a Person", comment: "Empty detail title when no person is selected in Context")
        case .work: String(localized: "Select a Project or Client", comment: "Empty detail title when no project or client is selected in Context")
        case .glossary: String(localized: "Select a Term", comment: "Empty detail title when no glossary term is selected in Context")
        case .series: String(localized: "Select a Recurring Meeting", comment: "Empty detail title when no recurring meeting is selected in Context")
        }
    }

    static func emptyTitle(_ section: ContextSection) -> String {
        switch section {
        case .people: String(localized: "No People Yet", comment: "Empty state title of the People section")
        case .work: String(localized: "No Projects or Clients Yet", comment: "Empty state title of the Projects & Clients section")
        case .glossary: String(localized: "No Terms Yet", comment: "Empty state title of the Glossary section")
        case .series: String(localized: "No Recurring Meetings Yet", comment: "Empty state title of the Recurring Meetings section")
        }
    }

    static func addTitle(_ section: ContextSection) -> LocalizedStringKey {
        switch section {
        case .people: "Add Person"
        case .work: "Add Project or Client"
        case .glossary: "Add Term"
        case .series: "Add Recurring Meeting"
        }
    }
}

extension View {
    /// A tooltip only when `condition` holds.
    @ViewBuilder
    func help(_ text: Text, when condition: Bool) -> some View {
        if condition { help(text) } else { self }
    }
}

/// A leading label with its field: the label above a field, or on the same line with its value at the trailing edge
/// (`centersLabel`), like the other Settings panes and System Settings. The field's help goes right under it.
struct ContextFieldRow<Content: View>: View {
    let label: Text
    var help: String?
    var centersLabel = false
    /// The label sits on the value's first line (a value that can wrap), not between its lines.
    var alignsFirstLine = false
    @ViewBuilder let content: Content

    init(_ label: LocalizedStringKey, centersLabel: Bool = false, help: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = Text(label)
        self.help = help
        self.centersLabel = centersLabel
        self.content = content()
    }

    /// A label that is already text (a relation's localized name).
    init(verbatim label: String, centersLabel: Bool = false, alignsFirstLine: Bool = false, help: String? = nil, @ViewBuilder content: () -> Content) {
        self.alignsFirstLine = alignsFirstLine
        self.label = Text(verbatim: label)
        self.help = help
        self.centersLabel = centersLabel
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if centersLabel {
                HStack(alignment: alignsFirstLine ? .firstTextBaseline : .center, spacing: 12) {
                    label.lineLimit(1).fixedSize().layoutPriority(1)
                    content.frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                label.fixedSize(horizontal: false, vertical: true)
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let help {
                Text(wrapping: help).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
