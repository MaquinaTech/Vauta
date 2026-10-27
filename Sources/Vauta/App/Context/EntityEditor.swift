// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Form of a person, project, client, team, system or topic.
struct EntityEditor: View {
    @Bindable var model: ContextModel

    private var stored: Entity? { model.isCreating ? nil : model.selectedEntity }
    private var isSelf: Bool { stored?.isSelf == true }

    var body: some View {
        Form {
            if let e = stored, !e.confirmed {
                PendingPersonSection(model: model, entity: e)
            }
            Section {
                ContextFieldRow("Kind") {
                    ContextPopUp(label: String(localized: "Kind"), selection: $model.entityForm.kind,
                                 items: EntityKind.allCases.map { .init($0.label, symbol: $0.symbol, value: $0) })
                    .disabled(isSelf)
                    .help(Text("You are always a person"), when: isSelf)
                }
                ContextFieldRow(verbatim: nameLabel, help: isSelf ? String(localized: "This is you. It’s shown as “Me” until you type your name; your name helps Vauta recognize when others mention you.",
                                                              comment: "Help when editing the self entity") : nil) {
                    NoCopyField(title: namePlaceholder, text: $model.entityForm.name, onCommit: save)
                        .accessibilityLabel(Text(verbatim: nameLabel))
                }
                ContextFieldRow("Aliases", help: String(localized: "Aliases are other ways people say this name. Separate them with commas or press Return after each one.",
                                                        comment: "Help under the alias field")) {
                    AliasTokenField(aliases: $model.entityForm.aliases, input: $model.entityForm.aliasInput,
                                    name: model.entityForm.name, origins: model.aliasOrigins)
                }
                if model.entityForm.kind == .person {
                    ContextFieldRow("Email", help: String(localized: "The email links this person with calendar attendees.", comment: "Help under the email field")) {
                        NoCopyField(title: String(localized: "name@example.com", comment: "Placeholder of the email field of a person"),
                                    text: $model.entityForm.email, onCommit: save)
                            .accessibilityLabel(Text("Email"))
                    }
                }
                ContextFieldRow("Note") {
                    NoCopyField(title: String(localized: "Role, team, context…", comment: "Placeholder of the note field of a person or project"),
                                text: $model.entityForm.note, singleLine: false)
                        .accessibilityLabel(Text("Note"))
                }
            } header: {
                ContextFormHeader(title: headerTitle, symbol: model.entityForm.kind.symbol)
            }
            if let e = stored {
                RelationsSection(model: model, entity: e)
                ManageEntitySection(model: model, entity: e)
            }
        }
        .formStyle(.grouped)
        .scrollIndicators(.visible)
        .contentMargins(.bottom, 16, for: .scrollContent)
    }

    private var headerTitle: String {
        if model.isCreating {
            return model.entityForm.kind == .person
                ? String(localized: "New Person", comment: "Title of the form for a new person")
                : String(localized: "New Entry", comment: "Title of the form for a new project, client, team, system or topic")
        }
        return stored?.displayName ?? model.entityForm.name
    }

    /// A person's name and the name of a project, team or topic are different words in some languages.
    private var nameLabel: String {
        model.entityForm.kind == .person
            ? String(localized: "context.person.name", defaultValue: "Name", comment: "Context editor: label of a person's name field")
            : String(localized: "Name", comment: "Context editor: label of the name field of a project, client, team, system or topic")
    }

    private var namePlaceholder: String {
        isSelf
            ? String(localized: "Your name", comment: "Placeholder of the name field when editing the user themselves")
            : String(localized: "Full name", comment: "Placeholder of the name field of a person or project")
    }

    private func save() {
        guard model.hasUnsavedChanges || model.isCreating else { return }
        Task { await model.saveCurrent() }
    }
}

/// A calendar attendee waiting for the user's decision.
private struct PendingPersonSection: View {
    @Bindable var model: ContextModel
    let entity: Entity

    var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("From your calendar · Needs review").font(.headline)
                    Text("Vauta added this attendee from a calendar event. Confirm to keep them, merge them into someone you already have, or dismiss them.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "calendar.badge.plus").foregroundStyle(.secondary)
            }
            HStack {
                Button("Confirm") { Task { await model.confirm(entity) } }
                    .buttonStyle(.borderedProminent)
                Button("Merge Into…") { Task { await model.requestMerge(of: entity) } }
                    .disabled(model.mergeCandidates(for: entity).isEmpty || model.mergeBlockedByEdits(entity))
                    .help(Text("Save or revert your changes first"), when: model.mergeBlockedByEdits(entity))
                Spacer()
                Button("Dismiss Person") { Task { await model.dismiss(entity) } }
            }
            .disabled(model.isWorking)
        }
    }
}

/// Hand-made relations of the entity.
private struct RelationsSection: View {
    @Bindable var model: ContextModel
    let entity: Entity

    /// The relations without a "mentioned in" for a task the entry also owns (it would list the task twice).
    private var shown: [RelationInfo] {
        let owned = Set(model.relations.filter { $0.rel == RelationKind.owner.rawValue }.map(otherRef))
        return model.relations.filter { !($0.rel == RelationKind.about.rawValue && owned.contains(otherRef($0))) }
    }

    private func otherRef(_ r: RelationInfo) -> NodeRef { r.src == NodeRef(.entity, entity.id) ? r.dst : r.src }

    var body: some View {
        Section {
            // Adding comes first, so it is in view as soon as the section is, whatever the window's height.
            // In the label column like the relations below, with the kind, the target and the button in the value column.
            ContextFieldRow("Add relation") {
                // One row when it fits; otherwise the kind on its own row. The pop-ups hug their titles, like the
                // Kind pop-up above and the task editor's.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { kindPopUp; targetPopUp(entity, maxWidth: 260, idealWidth: 140); addButton; Spacer(minLength: 0) }
                    VStack(alignment: .leading, spacing: 6) {
                        kindPopUp
                        HStack(spacing: 8) { targetPopUp(entity, fills: true); addButton }
                    }
                    // Even that short of room: the kind and the target shrink, the button stays whole.
                    VStack(alignment: .leading, spacing: 6) {
                        kindPopUp(fills: true)
                        targetPopUp(entity, fills: true)
                        addButton
                    }
                }
            }
            if shown.isEmpty {
                Text("No relations yet. For example, relate a person to the project they work on.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            // The same label column as the form above and the row that adds a relation.
            ForEach(shown) { r in
                ContextFieldRow(verbatim: relation(r), centersLabel: true, alignsFirstLine: true) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        // The kind of the target: a task, a person, a project or a meeting.
                        let target = otherKind(of: r)
                        Image(systemName: target.symbol).foregroundStyle(.secondary)
                            .frame(width: 18)
                            .help(Text(target.label))
                            .accessibilityLabel(Text(target.label))
                        // Up to two lines (a task is the main information of the row); the whole name is in the tooltip.
                        Text(other(of: r)).lineLimit(2).truncationMode(.tail)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(Text(verbatim: other(of: r)))
                        Button { Task { await model.removeRelation(r) } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove this relation")
                            .accessibilityLabel(Text("Remove Relation: \(relation(r)) \(other(of: r))"))
                    }
                }
            }
        } header: {
            Text("Relations")
        } footer: {
            // The fields above are saved with Save; relations take effect at once.
            Text("Relations are saved as soon as you add or remove them.")
        }
    }

    private var kindPopUp: some View { kindPopUp(fills: false) }

    private func kindPopUp(fills: Bool) -> some View {
        ContextPopUp(label: String(localized: "Relation"), selection: $model.relationKind,
                     items: RelationKind.manual.map { .init(Self.capitalized($0.label), value: $0) },
                     fillsWidth: fills)
    }

    private func targetPopUp(_ entity: Entity, maxWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, fills: Bool = false) -> some View {
        ContextPopUp(label: String(localized: "Related to"), selection: $model.relationTarget,
                     items: [.init(String(localized: "Choose…"), value: Int64?.none)]
                        + model.confirmedEntities(excluding: entity.id).map {
                            .init(String(localized: "\($0.displayName) (\($0.kind.label))", comment: "Menu item: an entry and its kind, e.g. “Ana (Person)”"),
                                  value: Int64?.some($0.id))
                        }, fillsWidth: fills, maxWidth: maxWidth, idealWidth: idealWidth)
    }

    private var addButton: some View {
        Button("Add") { Task { await model.addRelation() } }
            .fixedSize()
            .disabled(model.relationTarget == nil || model.isWorking)
    }

    private static func capitalized(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }

    /// Relative to the open entry: "Works on" + the other end.
    private func other(of r: RelationInfo) -> String {
        r.src == NodeRef(.entity, entity.id) ? r.dstLabel : r.srcLabel
    }

    /// What the other end of the relation is, as a symbol and a word.
    private func otherKind(of r: RelationInfo) -> (symbol: String, label: String) {
        let ref = r.src == NodeRef(.entity, entity.id) ? r.dst : r.src
        switch ref.kind {
        case .entity:
            let kind = model.entity(ref.id)?.kind ?? .person
            return (kind.symbol, kind.label)
        case .task: return ("checklist", String(localized: "Task", comment: "Kind of the target of a relation; also a field label"))
        case .decision: return ("checkmark.seal", String(localized: "Decision", comment: "Kind of the target of a relation"))
        case .meeting: return ("waveform", String(localized: "Meeting", comment: "Kind of the target of a relation"))
        }
    }

    private func relation(_ r: RelationInfo) -> String {
        Self.capitalized(RelationKind(rawValue: r.rel)?.label ?? r.rel)
    }
}

/// Usage numbers, merge and delete.
private struct ManageEntitySection: View {
    @Bindable var model: ContextModel
    let entity: Entity

    var body: some View {
        Section {
            if let f = model.footprint {
                // Plain rows (label, value at the trailing edge): a long label ("Anzahl der Erwähnungen")
                // never widens the label column of the form fields.
                LabeledContent("Times mentioned") { Text(f.mentions, format: .number) }
                LabeledContent("Meetings") { Text(f.meetings, format: .number) }
                    .help("Meetings that mention this entry or list it as an attendee")
                if f.openTasks > 0 {
                    LabeledContent("Open tasks") { Text(f.openTasks, format: .number) }
                }
            }
        } header: {
            if model.footprint != nil { Text("In your meetings") }
        }
        // The action is not part of the read-only statistics; with no other entry to merge into it isn't offered.
        if !model.mergeCandidates(for: entity).isEmpty {
            Section {
                HStack {
                    Button("Merge Into…") { Task { await model.requestMerge(of: entity) } }
                        .disabled(model.mergeBlockedByEdits(entity))
                        .help(model.mergeBlockedByEdits(entity) ? Text("Save or revert your changes first")
                              : Text("Combine this entry with another one for the same person or project"))
                    Spacer()
                }
                .disabled(model.isWorking)
            }
        }
    }
}
