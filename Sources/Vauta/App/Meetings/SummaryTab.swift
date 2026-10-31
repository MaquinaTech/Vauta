// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// The minutes of a meeting: title, people, summary, topics, decisions, open questions,
/// live notes, marks and notes (the outcomes first, as in the export). Edits are saved automatically.
struct SummaryTab: View {
    @Bindable var model: MeetingsModel
    let recorder: RecorderModel
    let meeting: MeetingStore.Meeting

    private static let titleFont: NSFont = {
        let base = NSFont.preferredFont(forTextStyle: .title2)
        return NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
    }()
    @ViewLocalState private var summaryWidth: CGFloat = 600
    private static let bodyFont = NSFont.preferredFont(forTextStyle: .body)

    /// The summary editor fits its text (at least three lines) instead of keeping a tall empty box.
    private var summaryHeight: CGFloat {
        let line = ceil(NSLayoutManager().defaultLineHeight(for: Self.bodyFont))
        let text = (model.draft?.summary ?? "") as NSString
        // 2 pt of inset and 5 pt of line padding on each side of the text.
        let width = max(100, summaryWidth - 8 - 14)
        let measured = text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading],
                                         attributes: [.font: Self.bodyFont]).height
        return max(3 * line, ceil(measured) + line * (text.hasSuffix("\n") ? 1 : 0)) + 14
    }

    /// While the integrated model reads this meeting's transcript to write the minutes and the summary is still empty: how far it has
    /// read (the status bar above shows it too; here it fills the empty summary box and replaces the editor's placeholder). Nil otherwise.
    private var writingProgressValue: (fraction: Double, text: String)? {
        let status = recorder.llmStatus
        guard status.activityMeeting == meeting.id, status.activity != nil, (model.draft?.summary ?? "").isEmpty,
              let fraction = MinutesActivity.fraction(status), let text = MinutesActivity.stageText(status) else { return nil }
        return (fraction, text)
    }

    private static let titleLine = ceil(NSLayoutManager().defaultLineHeight(for: titleFont))

    /// The title field shows the whole title on up to three lines (the same wrapping as the Upcoming brief's header); only a longer
    /// one is cut, by scrolling inside the field.
    private var titleHeight: CGFloat {
        let line = Self.titleLine
        let shown = (model.draft?.title.isEmpty == false ? model.draft?.title : nil) ?? meeting.displayTitle
        // The text view's own inset (2 pt) and line padding (5 pt) on each side of the text.
        let width = max(100, summaryWidth + 7 - 14)
        let measured = (shown as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                        attributes: [.font: Self.titleFont]).height
        return min(3 * line, max(line, ceil(measured))) + 10
    }

    var body: some View {
        ScrollViewReader { proxy in
            summaryScroll
                .task(id: model.revealQuestions) {
                    guard model.revealQuestions else { return }
                    try? await Task.sleep(for: .milliseconds(150))
                    proxy.scrollTo("questionsSection", anchor: .top)
                    model.revealQuestions = false
                }
        }
    }

    private var summaryScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PaneLayout.section) {
                MinutesStatusBar(model: model, recorder: recorder, meeting: meeting)
                if let state = model.voiceHistory {
                    VoiceHistoryBanner(state: state, look: { Task { await model.lookInEarlierMeetings() } }, review: { model.reviewPastVoices() },
                                       undo: { Task { await model.undoPastVoiceSearch() } }, dismiss: { model.dismissVoiceHistory() })
                }
                header
                people
                DetailSection(String(localized: "Summary", comment: "Section title in a meeting")) {
                    NoCopyText(text: draft(\.summary),
                               placeholder: writingProgressValue != nil ? "" : String(localized: "Write a summary, or let the model propose one for you to review.",
                                                                                         comment: "Placeholder of the summary editor"),
                               accessibilityLabel: String(localized: "Summary", comment: "Accessibility label of the summary editor"),
                               checksSpelling: false, avoidsInitialFocus: true)
                        .frame(height: summaryHeight)
                        .padding(4)
                        .background(GeometryReader { geometry in
                            Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in summaryWidth = width }
                        })
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                        .overlay(alignment: .topLeading) {
                            // Where the summary will appear: how far the model has read (the status bar above says it too, and scrolls away).
                            if let progress = writingProgressValue {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(verbatim: progress.text).font(.callout).foregroundStyle(.secondary)
                                    ProgressView(value: progress.fraction).frame(maxWidth: 220)
                                }
                                .padding(10)
                                .accessibilityHidden(true)
                            }
                        }
                }
                DetailSection(String(localized: "Topics", comment: "Section title in a meeting: the topics field")) {
                    NoCopyText(text: draft(\.topicsText),
                               placeholder: String(localized: "Topics, separated by commas", comment: "Placeholder of the topics field"),
                               accessibilityLabel: String(localized: "Topics", comment: "Accessibility label of the topics field"),
                               singleLine: true, checksSpelling: false, avoidsInitialFocus: true)
                        .frame(height: Self.fieldHeight)
                        .padding(.horizontal, 4)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                }
                decisions
                OtherPossibleItemsSection(model: model, meetingID: meeting.id, items: model.minutesGroups.items)
                DetailSection(String(localized: "Open questions", comment: "Section title in a meeting")) {
                    ForEach(Array(model.openQuestions.enumerated()), id: \.offset) { index, question in
                        HStack(alignment: .firstTextBaseline) {
                            // The same leading column as the decisions' badge, so both lists share one text edge.
                            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                                .frame(width: SourceBadge.columnWidth).accessibilityHidden(true)
                            ProtectedText(question)
                            Spacer()
                            IconButton(label: String(localized: "Delete Question…", comment: "Button; a confirmation follows"), systemImage: "minus.circle") {
                                model.pendingDeletion = .question(index: index, text: question)
                            }
                        }
                    }
                    NoCopyField(title: String(localized: "New question (press Return to add)", comment: "Placeholder"),
                                text: $model.newQuestion,
                                accessibilityLabel: String(localized: "New question", comment: "Accessibility label"), avoidsInitialFocus: true) {
                        Task { await model.addQuestion() }
                    }
                }
                LiveNotesSection(model: model, meeting: meeting)
                QuestionsSection(model: model, meeting: meeting).id("questionsSection")
                if model.documentsModel != nil { MaterialsSection(model: model) }
                if !model.relatedDocuments.isEmpty { RelatedDocumentsSection(model: model) }
                if !model.relatedMeetings.isEmpty { RelatedMeetingsSection(model: model) }
                if !model.marks.isEmpty || !model.notes.isEmpty { marksAndNotes }
                Text("Changes are saved automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(PaneLayout.pane)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private static let fieldHeight: CGFloat = {
        ceil(NSLayoutManager().defaultLineHeight(for: .preferredFont(forTextStyle: .body))) + 10
    }()

    private func draft(_ field: WritableKeyPath<MeetingDraft, String>) -> Binding<String> {
        Binding(get: { model.draft?[keyPath: field] ?? "" },
                set: { value in
                    guard model.draft?[keyPath: field] != value else { return }
                    model.draft?[keyPath: field] = value
                    model.draftEdited()
                })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Untitled meetings show the automatic title as a placeholder.
            NoCopyText(text: draft(\.title), placeholder: meeting.displayTitle,
                       accessibilityLabel: String(localized: "Meeting title", comment: "Accessibility label of the title field"),
                       singleLine: true, wraps: true, font: Self.titleFont, checksSpelling: false, avoidsInitialFocus: true)
                .frame(height: titleHeight)
                .help(model.draft?.title.isEmpty == false ? (model.draft?.title ?? "") : meeting.displayTitle)
                // The text view's own inset (2 + 5 pt) would put the title right of the column.
                .padding(.leading, -7)
            Text(dateLine).foregroundStyle(.secondary)
            informedLine
        }
    }

    /// Whether the user told the participants. A meeting where it wasn't recorded (or the reminder was
    /// dismissed) can be marked afterwards.
    @ViewBuilder
    private var informedLine: some View {
        if let informedAt = model.participantsInformedAt {
            Label {
                Text("Participants informed at \(informedAt.formatted(date: .omitted, time: .shortened))")
            } icon: {
                StatusSymbol.ok.image
            }
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("You marked the other participants as informed that this meeting was transcribed")
                .contextMenu {
                    Button("Clear") { Task { await model.setParticipantsInformed(false) } }
                }
        } else if model.activeMeetingID != meeting.id {
            HStack(spacing: 8) {
                Label("Participants not marked as informed", systemImage: "circle.dashed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Mark as Informed") { Task { await model.setParticipantsInformed(true) } }
                    .controlSize(.small)
                    .help("Record that you told the other participants this meeting was transcribed")
            }
        }
    }

    private var dateLine: String {
        let date = meeting.startedAt.formatted(date: .complete, time: .shortened)
        // Each “·” segment stands alone, so the language starts with a capital in every language.
        let language = (Locale.current.localizedString(forIdentifier: meeting.locale ?? MeetingStore.Meeting.legacyLocaleIdentifier) ?? "")
            .standaloneCapitalized
        guard let end = meeting.endedAt, model.activeMeetingID != meeting.id else {
            return String(localized: "\(date) · Recording", comment: "Meeting date line while recording")
        }
        let minutes = max(1, Int(end.timeIntervalSince(meeting.startedAt) / 60))
        return String(localized: "\(date) · \(minutes) min · \(language)",
                      comment: "Meeting date line: start date, duration in minutes, transcription language")
    }

    // MARK: People and topics

    @ViewBuilder
    private var people: some View {
        let persons = model.entities.filter { $0.kind == .person && !$0.isSelf }
        let projects = model.entities.filter { $0.kind != .person }
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: PaneLayout.item) {
            if !model.attendees.isEmpty || !persons.isEmpty {
                GridRow {
                    Text("Attendees", comment: "Meeting people row").foregroundStyle(.secondary).gridColumnAlignment(.leading)
                    HStack(alignment: .center, spacing: 6) {
                        chips(model.attendees)
                        if !persons.isEmpty {
                            linkMenu(persons, linked: model.attendees, empty: "Add an Attendee", add: "Add an Attendee",
                                     help: "Add the people who attended this meeting") { ids in
                                await model.setAttendees(ids)
                            }
                        }
                    }
                }
            }
            if !model.roster.isEmpty {
                // With speaker data, who spoke replaces the single "Others is…" name.
                GridRow {
                    Text("Who spoke", comment: "Meeting people row: each speaker with their share of the talking").foregroundStyle(.secondary)
                    WhoSpokeRows(model: model)
                }
            } else if !model.othersNamed.isEmpty {
                GridRow {
                    Text("“\(Channel.others.displayName)” is", comment: "Meeting people row: who the Others channel is").foregroundStyle(.secondary)
                    chips(model.othersNamed)
                }
            }
            if !model.topics.isEmpty || !projects.isEmpty {
                GridRow {
                    Text("Projects & clients", comment: "Meeting people row: the projects and clients this meeting is linked to (not the free-text Topics field)")
                        .foregroundStyle(.secondary)
                    HStack(alignment: .center, spacing: 6) {
                        chips(model.topics)
                        if !projects.isEmpty {
                            linkMenu(projects, linked: model.topics, empty: "Link a Project or Client", add: "Link a Project or Client",
                                     help: "Link a project or client to filter meetings by it") { ids in
                                await model.setTopics(ids)
                            }
                        }
                    }
                }
            }
        }
    }

    private func chips(_ items: [Entity]) -> some View {
        HStack(spacing: 6) {
            ForEach(items) { e in
                Button { model.showEntity(e.id) } label: {
                    ChipLabel(symbol: e.kind.symbol) { Text(e.displayName) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Show \(e.displayName)’s card")
            }
        }
    }

    /// "+" at the end of the chips (with its words when there are none yet): toggles which of `candidates` are linked.
    private func linkMenu(_ candidates: [Entity], linked: [Entity], empty: LocalizedStringKey, add: LocalizedStringKey,
                          help: LocalizedStringKey, set: @escaping ([Int64]) async -> Void) -> some View {
        let items = ForEach(candidates) { e in
            let on = linked.contains { $0.id == e.id }
            Toggle(isOn: Binding(get: { on }, set: { _ in
                let ids = on ? linked.map(\.id).filter { $0 != e.id } : linked.map(\.id) + [e.id]
                Task { await set(ids) }
            })) {
                Label(e.displayName, systemImage: e.kind.symbol)
            }
        }
        return Group {
            if linked.isEmpty {
                // With words: a small bordered menu button, so its type matches the chips and buttons around it (a
                // borderless menu ignores the label's font and draws the words at the body size).
                Menu { items } label: { Label(empty, systemImage: "plus") }
                    .menuIndicator(.hidden)
                    .menuStyle(.button)
                    .controlSize(.small)
                    .fixedSize()
                    .help(help)
            } else {
                Menu { items } label: {
                    // The same label metrics as the chips next to it, so the row is one strip of equal capsules. A menu's
                    // native bordered style ignores the label's height (it came out 6 pt shorter than the chips), so the
                    // capsule is drawn here with the chips' height.
                    ChipLabel(symbol: "plus") { EmptyView() }.accessibilityLabel(Text(add)).font(.caption)
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 2)
                .frame(height: 21)
                .background(Color(nsColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 5))
                .help(help)
            }
        }
    }

    // MARK: Decisions

    /// The decision with its badges inline after the last word, so a wrapped line runs to the time column and the
    /// glyphs follow the text instead of floating at the end of the first line.
    private func decisionText(_ d: Decision) -> Text {
        var t = Text(d.text)
        if d.source == "llm" { t = t + Text(verbatim: " ") + Text(Image(systemName: "sparkles")).font(.caption).foregroundColor(Brand.sparkle) }
        if d.unconfirmed {
            t = t + Text(verbatim: " ") + Text(Image(systemName: "questionmark.circle")).foregroundColor(.orange)
                + Text(verbatim: " ") + Text("Unconfirmed", comment: "Small badge after a decision the transcript doesn’t back").font(.footnote).foregroundColor(.secondary)
        }
        return t
    }

    private func decisionSpoken(_ d: Decision) -> String {
        var parts = [d.text]
        if d.source == "llm" { parts.append(String(localized: "Proposed by the model")) }
        if d.unconfirmed { parts.append(String(localized: "Unconfirmed", comment: "Small badge after a decision the transcript doesn’t back")) }
        return SpokenLabel.join(parts)
    }

    private func decisionHelp(_ d: Decision) -> String {
        if d.unconfirmed { return VerificationText.help(reason: d.unconfirmedReason) }
        return d.source == "llm" ? String(localized: "Proposed by the model: review it") : ""
    }

    private var decisions: some View {
        DetailSection(String(localized: "Decisions", comment: "Section title in a meeting")) {
            ForEach(model.minutesGroups.firmDecisions) { d in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        // The leading glyph is the kind (a decision), as in Live notes and Open questions;
                        // who proposed it is the small badge that follows the text.
                        Image(systemName: "checkmark.seal").foregroundStyle(.secondary)
                            .frame(width: SourceBadge.columnWidth).accessibilityHidden(true)
                        ProtectedText(decisionText(d))
                            .accessibilityLabel(Text(decisionSpoken(d)))
                            .help(decisionHelp(d))
                        Spacer()
                        if let t = d.t { TimeButton(t: t, passage: model.passage(at: t)) { model.open(meeting: meeting.id, at: t) } }
                        if d.unconfirmed {
                            IconButton(label: String(localized: "Mark as Checked", comment: "Button on an item the model proposed and nobody has confirmed: the user has checked it"), systemImage: "checkmark.circle") {
                                Task { await model.markDecisionChecked(d) }
                            }
                        }
                        IconButton(label: String(localized: "Delete Decision…", comment: "Button; a confirmation follows"), systemImage: "minus.circle") {
                            model.pendingDeletion = .decision(d)
                        }
                    }
                    .contextMenu {
                        if d.unconfirmed { Button("Mark as Checked") { Task { await model.markDecisionChecked(d) } } }
                    }
                    // A link to a decision of an earlier meeting, as a question until confirmed. Never under an item in "Other possible items".
                    LinkRowHost(model: model, kind: .decision, id: d.id).padding(.leading, SourceBadge.columnWidth + 6)
                }
            }
            NoCopyField(title: String(localized: "New decision (press Return to add)", comment: "Placeholder"),
                        text: $model.newDecision,
                        accessibilityLabel: String(localized: "New decision", comment: "Accessibility label"), avoidsInitialFocus: true) {
                Task { await model.addDecision() }
            }
            .help("Cite the highlighted transcript passage, if there is one")
        }
    }

    /// The marks, and a line that leads to the notes (they are shown once, in the Notes tab).
    @ViewBuilder private var marksAndNotes: some View {
        if !model.marks.isEmpty {
            DetailSection(String(localized: "Marks", comment: "Section title in a meeting: the moments the user marked")) {
                // The layout of the decisions: icon column, text, then the time and the delete button on the trailing side.
                ForEach(model.marks) { m in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "bookmark.fill").foregroundStyle(.orange)
                            .frame(width: SourceBadge.columnWidth).accessibilityHidden(true)
                        Text("Mark")
                        Spacer()
                        TimeButton(t: m.t, plain: model.transcript.isEmpty, passage: model.passage(at: m.t)) { model.open(meeting: meeting.id, at: m.t) }
                        IconButton(label: String(localized: "Delete Mark…", comment: "Button; a confirmation follows"), systemImage: "minus.circle") {
                            model.pendingDeletion = .mark(m)
                        }
                    }
                }
            }
        }
        if !model.notes.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "note.text").foregroundStyle(Color(nsColor: .systemYellow))
                    .frame(width: SourceBadge.columnWidth).accessibilityHidden(true)
                Text("\(model.notes.count) notes ·", comment: "Minutes tab: how many notes the user took; “Open Notes” follows as a link")
                Button("Open Notes") { model.tab = .notes }.buttonStyle(.link)
            }
        }
    }
}

/// Who wrote an item: the model (to review) or the user.
struct SourceBadge: View {
    /// The width of the badge's column, which other lists reserve to line their text up with it.
    nonisolated static let columnWidth: CGFloat = 20
    let source: String
    /// A selected row has a coloured fill: an indigo or green glyph would vanish into it.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let byModel = source == "llm"
        Image(systemName: byModel ? "sparkles" : "person.crop.circle.badge.checkmark")
            .frame(width: Self.columnWidth)
            .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(byModel ? Brand.sparkle : Color.green))
            .help(byModel ? "Proposed by the model: review it" : "Added or edited by you")
            .accessibilityLabel(byModel ? Text("Proposed by the model") : Text("Added by you"))
    }
}

/// Notes the model took during the recording (points, decisions, tasks).
private struct LiveNotesSection: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: MeetingsModel
    let meeting: MeetingStore.Meeting

    var body: some View {
        let points = model.liveNotes.flatMap(\.points)
        let decisions = model.liveNotes.flatMap(\.decisions)
        let tasks = model.liveNotes.flatMap(\.tasks)
        if !points.isEmpty || !decisions.isEmpty || !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // The heading sits on the column edge like the other sections; the chevron follows the text.
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { model.liveNotesExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text("Live notes").font(.headline)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(model.liveNotesExpanded ? 90 : 0))
                            .accessibilityHidden(true)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(model.liveNotesExpanded ? Text("expanded") : Text("collapsed"))
                if model.liveNotesExpanded {
                VStack(alignment: .leading, spacing: PaneLayout.item) {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                        row(p.text, symbol: "text.alignleft", spoken: String(localized: "Point: \(p.text)", comment: "VoiceOver label of a live note that is a point; the argument is its text"),
                            segment: p.segment)
                    }
                    ForEach(Array(decisions.enumerated()), id: \.offset) { _, d in
                        row(d.text, symbol: "checkmark.seal", spoken: String(localized: "Decision: \(d.text)", comment: "VoiceOver label of a live note that is a decision; the argument is its text"),
                            segment: d.segment)
                    }
                    ForEach(Array(tasks.enumerated()), id: \.offset) { _, t in
                        let text = t.owner.map { owner in String(localized: "\(t.text) (\(owner))", comment: "Live note task and its owner") } ?? t.text
                        row(text, symbol: "checklist", spoken: String(localized: "Task: \(text)", comment: "VoiceOver label of a live note that is a task; the argument is its text and owner"),
                            segment: t.segment)
                    }
                }
                .padding(.top, PaneLayout.item)
                }
            }
        }
    }

    /// The layout of the decisions: icon column, text, then the time and the delete button's room on the trailing side.
    private func row(_ text: String, symbol: String, spoken: String, segment: Int64?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: symbol).foregroundStyle(.secondary)
                .frame(width: SourceBadge.columnWidth).accessibilityHidden(true)
            ProtectedText(text).accessibilityLabel(Text(spoken))
            Spacer()
            if let segment, let line = model.transcript.first(where: { $0.id == segment }) {
                TimeButton(t: line.start, passage: PreviewedPassage(line)) { model.open(meeting: meeting.id, segment: segment) }
            }
            // Live notes can't be deleted, but their times end on the same column as the lists above and below.
            IconButton(label: "", systemImage: "minus.circle") {}
                .hidden()
                .accessibilityHidden(true)
        }
    }
}

/// The label of a chip and of the "+" next to the chips: one fixed height whatever the symbol, so a person, a
/// building and a plus all make capsules of the same size.
private struct ChipLabel<Title: View>: View {
    let symbol: String
    @ViewBuilder let title: Title

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).imageScale(.small).frame(width: 14, height: 14)
            title
        }
        .frame(height: 16)
    }
}
