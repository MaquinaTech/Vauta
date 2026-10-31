// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import Combine
import SwiftUI

/// The sidebar: the mode picker, then the list of the current mode.
struct MeetingsSidebar: View {
    @Bindable var model: MeetingsModel
    let onImport: () -> Void
    @ViewLocalState private var pickerWidth: CGFloat = 300
    /// The day the sections are counted from: moved on at midnight and when Vauta comes back to the front (after a sleep).
    @ViewLocalState private var now = Date.now

    var body: some View {
        VStack(spacing: 0) {
            ModePicker(selection: $model.mode, width: pickerWidth)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { pickerWidth = $0 }
                .frame(maxWidth: .infinity)
                .clipped()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            switch model.mode {
            case .meetings, .ask: meetingsList
            case .tasks: tasksList
            case .people: peopleList
            }
        }
    }

    // MARK: Meetings

    @ViewBuilder
    private var meetingsList: some View {
        Group {
            if model.query.trimmingCharacters(in: .whitespaces).count < 2 {
                // Sections by the day each meeting started, in the user's calendar: Today, Yesterday, Earlier This Week,
                // Earlier This Month, then one per month. The list is newest first, so the sections are too.
                List(selection: $model.selectedID) {
                    ForEach(MeetingDateSection.group(model.visibleMeetings, now: now, calendar: .autoupdatingCurrent) { $0.startedAt }) { group in
                        Section(group.section.title(now: now, calendar: .autoupdatingCurrent)) {
                            ForEach(group.items) { meeting in
                                MeetingRow(meeting: meeting, section: group.section, suggestions: model.suggestionCounts[meeting.id] ?? 0,
                                           recording: meeting.id == model.activeMeetingID, isSelected: meeting.id == model.selectedID)
                                    .tag(meeting.id)
                            }
                        }
                    }
                }
                .onDeleteCommand { model.confirmDeleteSelected() }
                .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in now = .now }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in now = .now }
                .overlay {
                    // Filters that match nothing are explained here, where the results would be (like a text search).
                    // With no meetings at all, the detail pane explains what to do, so the list stays empty.
                    if model.filterHasNoResults {
                        SearchEmptyStateView(query: filterTerm ?? "", filtered: true, message: filterMessage,
                                             clearTitle: model.tokens.count == 1 ? "Clear Filter" : "Clear Filters") { model.tokens = [] }
                    }
                }
            } else {
                List(selection: $model.openedHit) {
                    if !model.knowledgeHits.isEmpty {
                        Section("Minutes and notes") {
                            ForEach(model.knowledgeHits) { hit in
                                KnowledgeRow(hit: hit, query: model.query, title: context(of: hit)).tag("k\(hit.id)")
                            }
                        }
                    }
                    if !model.documentHits.isEmpty {
                        Section(String(localized: "Documents", comment: "Meetings sidebar search: the group of passages found in the person's documents")) {
                            ForEach(model.documentHits) { passage in
                                DocumentHitRow(passage: passage, query: model.query).tag("d\(passage.id)")
                            }
                        }
                    }
                    if !model.hits.isEmpty {
                        Section("Transcripts") {
                            ForEach(model.hits) { hit in
                                HitRow(hit: hit, query: model.query, selected: model.openedHit == "t\(hit.id)").tag("t\(hit.id)")
                            }
                        }
                    }
                    if hasMeaningHits {
                        // What the keywords above did not find: passages that mean the same. No highlights: nothing is matched word for word.
                        Section(String(localized: "By meaning", comment: "Meetings sidebar search: the group of passages that mean the same as the query (search model), under the keyword results")) {
                            ForEach(model.meaningMeetingHits) { passage in
                                MeaningHitRow(passage: passage).tag("m\(passage.id)")
                            }
                            ForEach(model.meaningDocumentHits) { passage in
                                // Nothing is matched word for word here: no highlights.
                                DocumentHitRow(passage: passage, query: "", symbol: "sparkle.magnifyingglass").tag("g\(passage.id)")
                            }
                        }
                    }
                }
                .onChange(of: model.query) { model.openedHit = nil }
                .onChange(of: model.openedHit) { _, id in
                    guard let id else { return }
                    if let hit = model.knowledgeHits.first(where: { "k\($0.id)" == id }) { model.open(hit) }
                    else if let hit = model.hits.first(where: { "t\($0.id)" == id }) { model.open(hit) }
                    else if let passage = model.documentHits.first(where: { "d\($0.id)" == id }) { model.openDocument(DocumentCitation(passage)) }
                    else if let passage = model.meaningMeetingHits.first(where: { "m\($0.id)" == id }) { model.open(passage) }
                    else if let passage = model.meaningDocumentHits.first(where: { "g\($0.id)" == id }) { model.openDocument(DocumentCitation(passage)) }
                }
                .overlay {
                    if model.hits.isEmpty && model.knowledgeHits.isEmpty && model.documentHits.isEmpty && !hasMeaningHits { SearchEmptyStateView(query: model.query) { model.query = "" } }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // The brief of the next meeting, above the list of meetings (not in Ask, not while searching).
            if model.mode == .meetings, model.query.trimmingCharacters(in: .whitespaces).count < 2, model.brief?.offersUpcoming == true { upcomingRow }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // The retention note belongs to the list of meetings, not to search results or Ask.
            if model.mode == .meetings, model.query.trimmingCharacters(in: .whitespaces).count < 2 { footer }
        }
    }

    /// "Upcoming": selected like a meeting, it shows the brief of the next one instead.
    private var upcomingRow: some View {
        Button { model.showUpcoming() } label: {
            Label {
                Text("Upcoming", comment: "Meetings sidebar: the row above the list that shows the brief of the next meeting")
            } icon: {
                Image(systemName: "calendar.badge.clock")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(model.showingUpcoming ? AnyShapeStyle(Color.accentColor.opacity(0.2)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
        .accessibilityAddTraits(model.showingUpcoming ? [.isButton, .isSelected] : .isButton)
    }

    private var hasMeaningHits: Bool { !model.meaningMeetingHits.isEmpty || !model.meaningDocumentHits.isEmpty }

    /// The title's term when a single filter matches nothing: the token, as a search's term.
    private var filterTerm: String? { model.tokens.count == 1 ? model.tokens.first?.label : nil }

    /// What to say when only the filter tokens match nothing: what the one filter means, or that they don't match together.
    private var filterMessage: String? {
        guard !model.tokens.isEmpty else { return nil }
        if model.tokens.count == 1 {
            return String(localized: "No meetings are linked to this person or project.", comment: "Meetings: nothing matches the one active filter (a person or project)")
        }
        return String(localized: "No meetings match all these filters.", comment: "Meetings: nothing matches the active filters together")
    }

    /// One line on an opaque bar under a divider, so rows scrolling under it never collide with it.
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            Text("Transcripts are deleted after \(MeetingStore.retentionDays) days.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: MeetingsBottomBar.height)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// What a result belongs to: its meeting, or the person or project of a note.
    private func context(of hit: KnowledgeHit) -> String {
        if hit.kind == .entityNote { return model.entities.first { $0.id == hit.refID }?.displayName ?? "" }
        return hit.meetingID.flatMap { id in model.meetings.first { $0.id == id }?.displayTitle } ?? ""
    }

    // MARK: Tasks

    private var tasksList: some View {
        List(selection: taskFilter) {
            Label("All open tasks", systemImage: "checklist").tag(TaskFilter.all)
            // Only people with an open task (and the one being filtered, so the selection stays visible).
            let withTasks = model.people.filter { p in model.ownerFilter == p.id || model.openTasks.contains { $0.ownerID == p.id } }
            if !withTasks.isEmpty {
                Section("By person") {
                    ForEach(withTasks) { p in
                        EntityRowLabel(name: p.displayName, symbol: EntityKind.person.symbol, isSelected: model.ownerFilter == p.id).tag(TaskFilter.person(p.id))
                    }
                }
            }
        }
    }

    /// "All open tasks" is a real selection, so the sidebar always shows which filter is active.
    private enum TaskFilter: Hashable { case all, person(Int64) }

    private var taskFilter: Binding<TaskFilter?> {
        Binding(get: { model.ownerFilter.map(TaskFilter.person) ?? .all },
                set: { newValue in
                    if case .person(let id)? = newValue { model.ownerFilter = id } else { model.ownerFilter = nil }
                })
    }

    // MARK: People

    private var peopleList: some View {
        List(selection: $model.selectedEntityID) {
            ForEach(EntityKind.allCases) { kind in
                let items = MeetingsModel.selfFirst(model.visibleEntities.filter { $0.kind == kind })
                if !items.isEmpty {
                    Section(kind.plural) {
                        ForEach(items) { e in
                            // The same row as the Context editor's list.
                            EntityRowLabel(name: e.displayName, symbol: kind.symbol, aliases: e.aliases, mentions: e.mentionCount,
                                           isSelected: model.selectedEntityID == e.id)
                                .frame(minHeight: 32)
                                .tag(Int64?.some(e.id))
                        }
                    }
                }
            }
        }
        .overlay {
            // With no people or projects the detail pane explains what to do, so the list stays empty.
            if !model.entities.isEmpty, model.visibleEntities.isEmpty {
                SearchEmptyStateView(query: model.query) { model.query = "" }
            }
        }
    }
}

// MARK: Rows

/// The title of an untitled meeting is secondary (selected: primary, as every row).
private struct UntitledStyle: ViewModifier {
    let untitled: Bool
    var isSelected = false
    func body(content: Content) -> some View {
        if untitled { content.sidebarSecondary(isSelected: isSelected) } else { content }
    }
}

private struct MeetingRow: View {
    let meeting: MeetingStore.Meeting
    /// The section the row is in: its header already says the day, so the row doesn't repeat it.
    let section: MeetingDateSection
    let suggestions: Int
    let recording: Bool
    var isSelected = false
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        // This list doesn't report increased prominence for its selected row, so the selection is passed in.
        let onSelection = prominence == .increased || isSelected
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.displayTitle)
                    .lineLimit(1)
                    .modifier(UntitledStyle(untitled: meeting.title == nil, isSelected: isSelected))
                Text(subtitle).font(.caption).sidebarSecondary(isSelected: isSelected)
            }
            Spacer()
            if recording || meeting.endedAt == nil {
                // At the trailing side so every title starts at the same x. A drawn dot keeps its red on a selected row.
                // A Canvas draws with its own colours, so the selection style can't turn the dot white.
                Canvas { context, size in
                    let dot = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
                    context.fill(Path(ellipseIn: dot), with: .color(Color(nsColor: .systemRed)))
                    if onSelection {
                        context.stroke(Path(ellipseIn: dot), with: .color(.white), lineWidth: 1.5)
                    }
                }
                    .frame(width: 11, height: 11)
                    .help("Recording")
                    .accessibilityLabel(Text("Recording"))
            }
            if suggestions > 0 {
                Label(suggestions.formatted(), systemImage: "questionmark.bubble")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.bold())
                    .padding(.horizontal, 5)
                    // On a selected row the capsule is white, as the recording dot's outline: orange over the
                    // accent would turn muddy.
                    .foregroundStyle(onSelection ? Color.white : Color.primary)
                    .background(onSelection ? Color.white.opacity(0.25) : Color.orange.opacity(0.25), in: Capsule())
                    .help("To review")
                    .accessibilityLabel(Text("\(suggestions) to review"))
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let date = switch section {
        case .today, .yesterday: meeting.startedAt.formatted(date: .omitted, time: .shortened)
        case .thisWeek: meeting.startedAt.formatted(.dateTime.weekday(.wide).hour().minute())
        case .thisMonth, .month: meeting.startedAt.formatted(date: .abbreviated, time: .shortened)
        }
        if recording || meeting.endedAt == nil {
            return String(localized: "\(date) · Recording", comment: "Meeting list subtitle of a meeting being recorded")
        }
        let minutes = max(1, Int(meeting.endedAt!.timeIntervalSince(meeting.startedAt) / 60))
        return String(localized: "\(date) · \(minutes) min", comment: "Meeting list subtitle: start date and duration in minutes")
    }
}

extension AttributedString {
    /// The one way a search match is drawn (sidebar results, Ask, People mentions, transcript): bold plus a
    /// yellow background, so it also reads in CJK scripts where bold alone is barely visible. `background: false`
    /// is for rows with an accent fill, where the yellow would clash.
    /// In list rows (`background: false`) the background run is not drawn (List renders it jagged in dark mode and
    /// drops the bold), so the match is an explicit bold font, plus the yellow marker unless the row is selected.
    /// In a dark list the background run is jagged too, so there the marker is yellow bold text (`darkList`).
    /// `dark` is the same dark-mode marker outside a list (transcript, Ask, mentions), so one meaning has one look.
    mutating func markMatch(_ range: Range<AttributedString.Index>, background: Bool = true, accent: Bool = false, darkList: Bool = false, dark: Bool = false) {
        self[range].inlinePresentationIntent = .stronglyEmphasized
        if background {
            if dark { self[range].swiftUI.foregroundColor = Color(nsColor: .systemYellow) }
            else { self[range].backgroundColor = Color(nsColor: .systemYellow).opacity(0.35) }
        } else {
            self[range].font = .body.bold()
            // The same yellow marker as the transcript and Ask (the accent colour read as a link); a selected row keeps white bold.
            if accent {
                if darkList { self[range].swiftUI.foregroundColor = Color(nsColor: .systemYellow) }
                else { self[range].backgroundColor = Color(nsColor: .systemYellow).opacity(0.35) }
            }
        }
    }
}

/// A search snippet (transcript or knowledge search) with the words of `query` marked by `markMatch`.
/// The snippet's own FTS5 markers are dropped: the index (unicode61) takes a whole run of CJK text as one
/// token, so they would mark whole clauses. The words are found again with the same matcher as the transcript,
/// Ask and People mentions, so every script marks the same words. Only a snippet with no matched word that is
/// written with spaces keeps the markers.
func highlightedSnippet(_ snippet: String, query: String, prefix: AttributedString = AttributedString(),
                        background: Bool = true, accent: Bool = false, darkList: Bool = false) -> AttributedString {
    let runs = SearchHighlight.runs(in: snippet)
    let plain = runs.map(\.text).joined()
    var piece = AttributedString(plain)
    let ranges = MeetingStore.matchedRanges(of: query, in: plain)
    if ranges.isEmpty, !plain.contains(where: TextKeys.isNoSpaceScript) {
        piece = AttributedString()
        for run in runs {
            var part = AttributedString(run.text)
            if run.isMatch { part.markMatch(part.startIndex..<part.endIndex, background: background, accent: accent, darkList: darkList) }
            piece += part
        }
    }
    for range in ranges {
        if let lower = AttributedString.Index(range.lowerBound, within: piece), let upper = AttributedString.Index(range.upperBound, within: piece) {
            piece.markMatch(lower..<upper, background: background, accent: accent, darkList: darkList)
        }
    }
    return prefix + piece
}

private struct HitRow: View {
    let hit: MeetingStore.SearchHit
    let query: String
    let selected: Bool
    /// A selected row has an accent fill: the speaker's tint would vanish into it, so only the bold stays.
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "text.quote").font(.caption).sidebarSecondary().frame(width: 16).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(hit.meeting.displayTitle) · \(ElapsedTime.stamp(hit.segment.start))")
                    .font(.caption).sidebarSecondary().lineLimit(1)
                Text(snippet).lineLimit(3)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(verbatim: hit.segment.hasUncertainSpeaker ? SpeakerLabel.notes(hit.segment).joined(separator: " ") : ""))
        .accessibilityHint(Text("Opens the meeting at this moment"))
    }

    private var snippet: AttributedString {
        // The speaker's name when the meeting has speaker data, else the channel's.
        let tint = !selected && prominence != .increased ? hit.segment.channel.tint(ordinal: hit.segment.speaker?.ordinal ?? 1) : nil
        let who = hit.segment.channel.quotePrefix(for: hit.segment.speaker, tint: tint)
        return highlightedSnippet(hit.snippet, query: query, prefix: who, background: false, accent: !selected && prominence != .increased, darkList: colorScheme == .dark)
    }
}

/// A passage of a meeting found by meaning: its meeting and moment, then what was said (no highlights).
private struct MeaningHitRow: View {
    let passage: RetrievedPassage
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "sparkle.magnifyingglass").font(.caption).sidebarSecondary().frame(width: 16).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(passage.meeting.displayTitle) · \(ElapsedTime.stamp(passage.start))")
                    .font(.caption).sidebarSecondary().lineLimit(1)
                Text(snippet).lineLimit(3)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens the meeting at this moment"))
    }

    /// Who said it (the first segment's speaker, as the keyword rows above show), then the passage.
    private var snippet: AttributedString {
        let text = AttributedString(passage.segments.map(\.text).joined(separator: " "))
        guard let first = passage.segments.first else { return text }
        let tint = prominence != .increased ? first.channel.tint(ordinal: first.speaker?.ordinal ?? 1) : nil
        return first.channel.quotePrefix(for: first.speaker, tint: tint) + text
    }
}

/// A passage of a document found by the sidebar search: its file and place, then the passage.
private struct DocumentHitRow: View {
    let passage: DocumentPassage
    let query: String
    /// The marker in front of the row: the same sparkle as meeting passages in the "By meaning" group.
    var symbol = "doc.text"
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(.caption).sidebarSecondary().frame(width: 16).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: DocumentCitation(passage).label).font(.caption).sidebarSecondary().lineLimit(1)
                Text(snippet).lineLimit(3)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens the passage in the document"))
    }

    private var snippet: AttributedString {
        var out = AttributedString(VautaPrompts.body(of: passage))
        for range in MeetingStore.matchedRanges(of: query, in: VautaPrompts.body(of: passage)) {
            if let lower = AttributedString.Index(range.lowerBound, within: out), let upper = AttributedString.Index(range.upperBound, within: out) {
                out.markMatch(lower..<upper, dark: colorScheme == .dark)
            }
        }
        return out
    }
}

private struct KnowledgeRow: View {
    let hit: KnowledgeHit
    let query: String
    let title: String
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(.caption).sidebarSecondary().frame(width: 16).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(kind).font(.caption).sidebarSecondary().lineLimit(1)
                Text(highlightedSnippet(hit.snippet, query: query, background: false, accent: prominence != .increased, darkList: colorScheme == .dark)).lineLimit(3)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var kind: String {
        let what = switch hit.kind {
        case .decision: String(localized: "Decision", comment: "Search result kind")
        case .task: String(localized: "Task", comment: "Search result kind")
        case .note: String(localized: "Note", comment: "Search result kind")
        case .noteExpansion: String(localized: "Expanded note", comment: "Search result kind: the text the model wrote from the transcript under one of the user’s notes (not the user’s own words)")
        case .entityNote: String(localized: "Context", comment: "Search result kind: a note on a person or project")
        case .summary: String(localized: "Summary", comment: "Search result kind")
        case .question: String(localized: "Question", comment: "Search result kind: a question heard in a meeting that the person kept, with its answer")
        }
        return title.isEmpty ? what : String(localized: "\(what) · \(title)", comment: "Search result kind and meeting title")
    }

    private var symbol: String {
        switch hit.kind {
        case .decision: "checkmark.seal"
        case .task: "checklist"
        case .note: "note.text"
        case .noteExpansion: "sparkles"
        case .entityNote: "person.text.rectangle"
        case .summary: "doc.text"
        case .question: "questionmark.bubble"
        }
    }
}

extension Channel {
    /// "Me: " before a quote. The punctuation belongs to the translation (full-width in Japanese and Chinese).
    var speakerPrefix: String { speakerPrefix(for: nil) }

    /// The same for a line with a speaker: "Ana: ", "Speaker 2: ", or the channel's name without speaker data.
    func speakerPrefix(for tag: SpeakerTag?) -> String {
        let name = tag?.displayName(channel: self) ?? displayName
        if tag?.isLowConfidence == true {
            return String(localized: "\(name) (not sure): ", comment: "Speaker name before what they said in a search result or quote when the app is not sure who said it; keep the trailing space (full-width colon in Japanese and Chinese)")
        }
        return String(localized: "\(name): ", comment: "Speaker name before what they said, in a search result or quote; keep the trailing space (full-width colon in Japanese and Chinese)")
    }

    /// The prefix of a quote, bold and in the speaker's tint; italic too when the speaker is a guess, as in the transcript.
    func quotePrefix(for tag: SpeakerTag?, tint: Color?) -> AttributedString {
        var who = AttributedString(speakerPrefix(for: tag))
        if let tint { who.swiftUI.foregroundColor = tint }
        who.inlinePresentationIntent = tag?.isLowConfidence == true ? [.stronglyEmphasized, .emphasized] : .stronglyEmphasized
        return who
    }
}

extension MeetingDateSection {
    /// The header of the section in the meetings list. An earlier month names its year only when it isn't this one.
    func title(now: Date, calendar: Calendar) -> String {
        switch self {
        case .today: return String(localized: "Today", comment: "Meetings list: the header of the meetings started today")
        case .yesterday: return String(localized: "Yesterday", comment: "Meetings list: the header of the meetings started yesterday")
        case .thisWeek:
            return String(localized: "Earlier This Week", comment: "Meetings list: the header of this week's meetings started before yesterday")
        case .thisMonth:
            return String(localized: "Earlier This Month", comment: "Meetings list: the header of this month's meetings started before this week")
        case .month(let year, let month):
            guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return "" }
            let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).month(.wide)
            return first.formatted(calendar.component(.year, from: now) == year ? style : style.year())
        }
    }
}
