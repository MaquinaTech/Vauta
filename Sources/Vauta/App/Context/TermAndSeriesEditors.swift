// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Form of a glossary term.
struct TermEditor: View {
    @Bindable var model: ContextModel

    var body: some View {
        Form {
            Section {
                ContextFieldRow("Term") {
                    NoCopyField(title: String(localized: "Acronym or internal word", comment: "Placeholder of the glossary term field"),
                                text: $model.termForm.term, onCommit: save)
                        .accessibilityLabel(Text("Term"))
                }
                ContextFieldRow("Meaning") {
                    NoCopyField(title: String(localized: "What it stands for", comment: "Placeholder of the glossary meaning field"),
                                text: $model.termForm.expansion, onCommit: save)
                        .accessibilityLabel(Text("Meaning"))
                }
                ContextFieldRow("Note") {
                    NoCopyField(title: String(localized: "Where it’s used, who says it…", comment: "Placeholder of the glossary note field"),
                                text: $model.termForm.note, singleLine: false)
                        .accessibilityLabel(Text("Note"))
                }
                ContextFieldRow("Related entry") {
                    ContextPopUp(label: String(localized: "Related entry"), selection: $model.termForm.entityID,
                                 // A pending calendar person already linked stays listed, so the picker shows it.
                                 items: [.init(String(localized: "Not linked"), value: Int64?.none)]
                                    + model.entities.filter { $0.confirmed || $0.id == model.termForm.entityID }.map {
                                        .init(String(localized: "\($0.displayName) (\($0.kind.label))", comment: "Menu item: an entry and its kind, e.g. “Ana (Person)”"),
                                              value: Int64?.some($0.id))
                                    })
                }
                ContextFieldRow("Pinned", centersLabel: true, help: String(localized: "Pinned terms take priority in the vocabulary given to the speech recognizer.",
                                                        comment: "Help under the pinned toggle of a glossary term").avoidingWidow) {
                    Toggle("Pinned", isOn: $model.termForm.pinned)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            } header: {
                ContextFormHeader(title: model.isCreating ? String(localized: "New Term", comment: "Title of the form for a new glossary term")
                                                          : model.termForm.term,
                                  symbol: "character.book.closed")
            }
        }
        .formStyle(.grouped)
        .scrollIndicators(.visible)
    }

    private func save() {
        guard model.hasUnsavedChanges || model.isCreating else { return }
        Task { await model.saveCurrent() }
    }
}

/// Form of a recurring meeting.
struct SeriesEditor: View {
    @Bindable var model: ContextModel

    var body: some View {
        Form {
            Section {
                ContextFieldRow("Title", help: footer) {
                    NoCopyField(title: String(localized: "Weekly team meeting", comment: "Placeholder of the recurring meeting title field"),
                                text: $model.seriesForm.title, onCommit: save)
                        .accessibilityLabel(Text("Title"))
                }
                if let id = model.seriesForm.id, let count = model.seriesMeetingCounts[id], count > 0 {
                    ContextFieldRow("Recorded meetings", centersLabel: true) { Text(count, format: .number) }
                }
                ContextFieldRow("Minutes template", help: String(localized: "The minutes of new meetings in this series use it. “Default” is the template chosen in Settings\u{00A0}→\u{00A0}Models.",
                                                                 comment: "Help under the minutes template of a recurring meeting").avoidingWidow) {
                    templatePopUp
                }
            } header: {
                ContextFormHeader(title: model.isCreating
                                  ? String(localized: "New Recurring Meeting", comment: "Title of the form for a new recurring meeting")
                                  : model.seriesForm.title,
                                  symbol: "repeat")
            }
            // Calendar series list their attendees, who may still be pending: show them too.
            let candidates = MeetingsModel.selfFirst(model.entities.filter { $0.confirmed || model.seriesForm.entities.contains($0.id) })
            // Grouped like the Meetings People list: people first (you at the top), then projects and clients.
            let people = candidates.filter { $0.kind == .person }
            let work = candidates.filter { $0.kind != .person }
            if candidates.isEmpty {
                Section("Usual people and projects") {
                    Text("Add people or projects first.").foregroundStyle(.secondary)
                    Button("Show People") { model.navigate(.section(.people)) }
                }
            }
            if !people.isEmpty {
                Section {
                    ForEach(people) { memberToggle($0) }
                } header: {
                    Text("People")
                } footer: {
                    if work.isEmpty { Text(wrapping: Self.linksFooter) }
                }
            }
            if !work.isEmpty {
                Section {
                    ForEach(work) { memberToggle($0) }
                } header: {
                    Text("Projects & clients")
                } footer: {
                    Text(wrapping: Self.linksFooter)
                }
            }
        }
        .formStyle(.grouped)
        .scrollIndicators(.visible)
    }

    /// The default, Vauta's templates and the person's own, which are not evaluated (their group says so).
    private var templatePopUp: some View {
        let custom = model.customTemplates
        var items: [ContextPopUp<MinutesTemplateChoice?>.Item] = [.init(String(localized: "Default", comment: "Recurring meeting form: the minutes template item that uses the default template in Settings → Models"), value: nil)]
        items += MinutesTemplate.allCases.map { .init($0.displayName, value: .builtIn($0)) }
        var breaks: [Int: MenuBreak] = [1: .line]
        if !custom.isEmpty { breaks[items.count] = .title(CustomMinutesTemplate.label) }
        items += custom.map { .init($0.name, value: .custom($0.id)) }
        // A template deleted while the form was open shows as the default, which saving it writes.
        let chosen = model.seriesForm.template
        let shown: MinutesTemplateChoice? = if case .custom(let id) = chosen, !custom.contains(where: { $0.id == id }) { nil } else { chosen }
        return ContextPopUp(label: String(localized: "Minutes template", comment: "Recurring meeting form: the label of the minutes template pop-up"),
                            selection: Binding(get: { shown }, set: { model.seriesForm.template = $0 }), items: items, breaks: breaks)
    }

    /// One sentence under the last toggles list: it covers the people and the projects together.
    private static let linksFooter = String(localized: "Vauta links the people, projects and clients you turn on to every meeting of this series.").avoidingWidow

    private var footer: String {
        var lines = [String(localized: "Use the title as it appears in your calendar, or the one you give the meeting. Vauta links a meeting when its title contains these words.",
                            comment: "Help under the recurring meeting title")]
        if model.seriesForm.calendarKey != nil {
            lines.append(String(localized: "Created from a repeating calendar event.", comment: "Help: this recurring meeting came from the calendar"))
        }
        return lines.joined(separator: "\n")
    }

    private func memberToggle(_ e: Entity) -> some View {
        Toggle(isOn: member(e.id)) {
            HStack(spacing: 6) {
                Image(systemName: e.kind.symbol).foregroundStyle(Color(nsColor: .secondaryLabelColor)).frame(width: 20).accessibilityHidden(true)
                Text(e.displayName)
            }
        }
    }

    private func member(_ id: Int64) -> Binding<Bool> {
        Binding(get: { model.seriesForm.entities.contains(id) },
                set: { if $0 { model.seriesForm.entities.insert(id) } else { model.seriesForm.entities.remove(id) } })
    }

    private func save() {
        guard model.hasUnsavedChanges || model.isCreating else { return }
        Task { await model.saveCurrent() }
    }
}

/// Title row at the top of a form and of a person's or project's card in Meetings.
struct ContextFormHeader: View {
    let title: String
    let symbol: String

    var body: some View {
        Label {
            Text(title).font(.title2.bold()).foregroundStyle(.primary).lineLimit(2)
        } icon: {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
        }
        .textCase(nil)
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }
}
