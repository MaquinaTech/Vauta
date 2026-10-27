// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Section picker, search, kind filter, the list and the add/remove/reanalyze bar.
struct ContextSidebar: View {
    @Bindable var model: ContextModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Picker("Category", selection: Binding(get: { model.section }, set: { model.navigate(.section($0)) })) {
                    ForEach(ContextSection.allCases) { s in
                        Label { Text(s.title) } icon: { Image(systemName: s.symbol) }.tag(s)
                    }
                }
                .labelsHidden()
                ContextSearchField(text: $model.searchText, section: model.section)
                if model.section == .work {
                    Picker("Kind", selection: $model.kindFilter) {
                        Text("All Kinds").tag(EntityKind?.none)
                        Divider()
                        ForEach(ContextSection.work.kinds) { kind in
                            Label(kind.plural, systemImage: kind.symbol).tag(EntityKind?.some(kind))
                        }
                    }
                    .labelsHidden()
                }
            }
            .padding(10)
            list
            Divider()
            ContextSidebarBar(model: model)
        }
    }

    private var selection: Binding<ContextSelection?> {
        Binding(get: { model.isCreating ? nil : model.selection }, set: { model.navigate(.select($0)) })
    }

    private var list: some View {
        List(selection: selection) {
            if model.isCreating, model.section == .glossary || model.section == .series {
                NewItemRow(title: newItemTitle, symbol: newItemSymbol)
            }
            switch model.section {
            case .people, .work:
                // Both section titles are plain header rows of one style: a pinned section header draws a hard rule
                // under itself in the first section only.
                if !model.visiblePending.isEmpty {
                    SectionTitleRow(title: String(localized: "From your calendar · Needs review"))
                    ForEach(model.visiblePending) { e in
                        EntityRow(entity: e, isSelected: !model.isCreating && model.selection == .entity(e.id)).tag(ContextSelection.entity(e.id))
                    }
                    SectionTitleRow(title: String(localized: model.section.title))
                }
                // Inside the list, so it keeps the same rhythm as the rows after it.
                if model.isCreating { NewItemRow(title: newItemTitle, symbol: newItemSymbol) }
                ForEach(model.visibleEntities) { e in
                    EntityRow(entity: e, isSelected: !model.isCreating && model.selection == .entity(e.id)).tag(ContextSelection.entity(e.id))
                }
            case .glossary:
                ForEach(model.visibleTerms, id: \.id) { g in
                    TermRow(term: g, isSelected: !model.isCreating && model.selection == .term(g.id ?? 0)).tag(ContextSelection.term(g.id ?? 0))
                }
            case .series:
                ForEach(model.visibleSeries, id: \.id) { s in
                    SeriesRow(series: s, meetings: s.id.flatMap { model.seriesMeetingCounts[$0] } ?? 0,
                              isSelected: !model.isCreating && model.selection == .series(s.id ?? 0))
                        .tag(ContextSelection.series(s.id ?? 0))
                }
            }
        }
        .listStyle(.inset)
        .listRowSeparator(.hidden)
        // The pinned first header gets no hard rule under it, like the section below it.
        .listSectionSeparator(.hidden)
        .scrollEdgeEffectHidden(true, for: .top)
        .contextMenu(forSelectionType: ContextSelection.self) { items in
            if let item = items.first, items.count == 1 { menu(for: item) }
        }
        .onDeleteCommand { requestDelete(model.selection) }
        .overlay { emptyState }
    }

    /// The glyph of the kind being created, as its saved row will show it.
    private var newItemSymbol: String? {
        switch model.section {
        case .people, .work: model.entityForm.kind.symbol
        case .glossary: "character.book.closed"
        case .series: "repeat"
        }
    }

    /// The row of the entry being created: what has been typed, or the form's title.
    private var newItemTitle: String {
        let typed: String = switch model.section {
        case .people, .work: model.entityForm.name
        case .glossary: model.termForm.term
        case .series: model.seriesForm.title
        }
        if !typed.trimmingCharacters(in: .whitespaces).isEmpty { return typed }
        return switch model.section {
        case .people: String(localized: "New Person", comment: "Title of the form for a new person")
        case .work: String(localized: "New Entry", comment: "Title of the form for a new project, client, team, system or topic")
        case .glossary: String(localized: "New Term", comment: "Title of the form for a new glossary term")
        case .series: String(localized: "New Recurring Meeting", comment: "Title of the form for a new recurring meeting")
        }
    }

    @ViewBuilder
    private func menu(for item: ContextSelection) -> some View {
        switch item {
        case .entity(let id):
            if let e = model.entity(id) {
                if !e.confirmed {
                    Button("Confirm") { Task { await model.confirm(e) } }
                }
                Button("Merge Into…") { Task { await model.requestMerge(of: e) } }
                    .disabled(model.mergeCandidates(for: e).isEmpty || model.mergeBlockedByEdits(e))
                Divider()
                if e.confirmed {
                    Button("Delete…", role: .destructive) { requestDelete(item) }
                        .disabled(e.isSelf)
                } else {
                    Button("Dismiss Person", role: .destructive) { Task { await model.dismiss(e) } }
                }
            }
        case .term, .series:
            Button("Delete…", role: .destructive) { requestDelete(item) }
        }
    }

    private func requestDelete(_ item: ContextSelection?) {
        Task { await model.requestRemoval(of: item) }
    }


    @ViewBuilder
    private var emptyState: some View {
        if model.hasLoaded && model.isListEmpty {
            // Without a search the detail pane carries the title and the button, so the list stays empty.
            if model.isFiltering {
                SearchEmptyStateView(query: model.searchText, filtered: model.kindFilter != nil,
                                     clearTitle: model.kindFilter == nil ? "Clear Search" : "Clear Filters") {
                    model.searchText = ""
                    model.kindFilter = nil
                }
            }
        }
    }
}

/// Search field that keeps the query inside Vauta (no copy, no services), drawn like the system search
/// field: the magnifier is inside it. It doesn't take focus when the pane opens.
private struct ContextSearchField: View {
    @Binding var text: String
    let section: ContextSection

    /// Filters the list the way the People list of the Meetings window does.
    private var prompt: String {
        switch section {
        case .people: String(localized: "Filter people", comment: "Placeholder of the Context list filter in People")
        case .work: String(localized: "Filter projects and clients", comment: "Placeholder of the Context list filter in Projects & Clients")
        case .glossary: String(localized: "Filter terms", comment: "Placeholder of the Context list filter in Glossary")
        case .series: String(localized: "Filter recurring meetings", comment: "Placeholder of the Context list filter in Recurring Meetings")
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            NoCopyText(text: $text, placeholder: prompt,
                       accessibilityLabel: prompt, singleLine: true,
                       checksSpelling: false, avoidsInitialFocus: true)
                .frame(height: 22)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear the search")
                    .accessibilityLabel(Text("Clear Search"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        // The hairline is the fill of a slightly larger capsule behind the field: a stroked outline
        // drew a stray tick at both ends of it.
        .background {
            ZStack {
                Capsule().fill(Color(nsColor: .separatorColor))
                Capsule().fill(Color(nsColor: .textBackgroundColor)).padding(1)
            }
        }
    }
}

/// Add, remove and reanalyze, under the list.
private struct ContextSidebarBar: View {
    @Bindable var model: ContextModel

    var body: some View {
        HStack(spacing: 6) {
            Button { model.navigate(.create) } label: { Image(systemName: "plus") }
                .help(addTitle)
                .accessibilityLabel(Text(addTitle))
                .keyboardShortcut("n", modifiers: .command)
            Button { removeSelection() } label: { Image(systemName: "minus") }
                .help("Delete the selected item")
                .accessibilityLabel(Text("Delete Selected Item…"))
                .disabled(!canRemove)
            Spacer(minLength: 4)
            if model.reanalysis.isRunning {
                ProgressView(value: model.reanalysis.fractionCompleted)
                    .frame(width: 60)
                    .accessibilityLabel(Text("Finding names…"))
                Text("\(model.reanalysis.current) of \(model.reanalysis.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { model.cancelReanalysis() } label: { Image(systemName: "xmark.circle.fill") }
                    .help("Stop finding names")
                    .accessibilityLabel(Text("Stop Finding Names"))
                    .disabled(model.isCancellingReanalysis)
            } else {
                Button { model.startReanalysis() } label: {
                    // The full label when it fits; the icon alone only where even the narrowest list can't hold it.
                    ViewThatFits(in: .horizontal) {
                        Label("Find Names Again", systemImage: "arrow.clockwise").lineLimit(1)
                        Label("Find Names Again", systemImage: "arrow.clockwise").lineLimit(1).font(.callout).minimumScaleFactor(0.85)
                        Label("Find Names Again", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                    }
                }
                .accessibilityLabel(Text("Find Names Again"))
                    .help("Search the names in your context again in every saved meeting that still has its transcript. It runs on this Mac and keeps the suggestions you already resolved.")
                    .disabled(!model.hasLoaded)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .frame(height: ContextBarLayout.height)
    }

    private var addTitle: String {
        switch model.section {
        case .people: String(localized: "Add Person", comment: "Button help and accessibility label")
        case .work: String(localized: "Add Project or Client", comment: "Button help and accessibility label")
        case .glossary: String(localized: "Add Term", comment: "Button help and accessibility label")
        case .series: String(localized: "Add Recurring Meeting", comment: "Button help and accessibility label")
        }
    }

    private var canRemove: Bool {
        guard let selection = model.selection, !model.isCreating else { return false }
        if case .entity(let id) = selection { return model.entity(id)?.isSelf == false }
        return true
    }

    private func removeSelection() {
        Task { await model.requestRemoval(of: model.selection) }
    }
}

// MARK: Rows

/// The temporary, selected row of an entry that isn't saved yet (as in Contacts).
private struct NewItemRow: View {
    let title: String
    let symbol: String?
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        Group {
            if let symbol { EntityRowLabel(name: title, symbol: symbol, isSelected: true) }
            else { Text(title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }
        }
            // White on the selection colour, like the text of a selected row.
            .foregroundStyle(Color(nsColor: activeState == .inactive ? .labelColor : .alternateSelectedControlTextColor))
            .frame(minHeight: 32)
            .listRowSeparator(.hidden)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 8)
                    .fill(activeState == .inactive ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
                                                   : Color(nsColor: .selectedContentBackgroundColor))
                    .padding(.horizontal, 9)
            )
            .accessibilityAddTraits(.isSelected)
    }
}

/// A section title inside the list, drawn like a section header.
private struct SectionTitleRow: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 8)
            .listRowSeparator(.hidden)
            .selectionDisabled()
            .accessibilityAddTraits(.isHeader)
    }
}

private struct EntityRow: View {
    let entity: Entity
    let isSelected: Bool

    var body: some View {
        EntityRowLabel(name: entity.displayName, symbol: entity.confirmed ? entity.kind.symbol : "calendar.badge.plus",
                       aliases: entity.aliases, mentions: entity.mentionCount, isSelected: isSelected)
        .frame(minHeight: 32)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(entity.displayName))
        .accessibilityValue(entity.mentionCount > 0 ? Text("\(entity.mentionCount) mentions") : Text(entity.kind.label))
        .accessibilityHint(entity.confirmed ? Text(verbatim: "") : Text("Suggested from your calendar. Confirm or dismiss this person."))
    }
}

private struct TermRow: View {
    let term: GlossaryTerm
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            RowIcon(symbol: "character.book.closed", isSelected: isSelected)
            VStack(alignment: .leading, spacing: 1) {
                Text(term.term).lineLimit(1)
                if !term.expansion.isEmpty {
                    Text(term.expansion).font(.caption).sidebarSecondary(isSelected: isSelected).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if term.pinned {
                Image(systemName: "pin.fill").font(.caption).sidebarSecondary(isSelected: isSelected)
                    .help("Pinned")
                    .accessibilityLabel(Text("Pinned"))
            }
        }
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
    }
}

private struct SeriesRow: View {
    let series: MeetingSeries
    let meetings: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            RowIcon(symbol: "repeat", isSelected: isSelected)
            Text(series.titlePattern).lineLimit(1)
            Spacer(minLength: 4)
            if series.calendarKey != nil {
                Image(systemName: "calendar").font(.caption).sidebarSecondary(isSelected: isSelected)
                    .help("From your calendar")
                    .accessibilityLabel(Text("From your calendar"))
            }
            if meetings > 0 {
                CountBadge(symbol: "person.crop.rectangle.stack", count: meetings, isSelected: isSelected)
                    .help("Recorded meetings in this series")
                    .accessibilityLabel(Text("\(meetings) meetings"))
            }
        }
        .accessibilityElement(children: .combine)
    }
}
