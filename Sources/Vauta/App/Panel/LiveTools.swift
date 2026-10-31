// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// While recording: marks, the notes and who "Others" is.
struct LiveTools: View {
    @Bindable var model: RecorderModel
    /// Who "Others" is sits in this card, or (on a short screen) in a card of its own among the scrolling ones.
    var showsOthers = true
    /// The height of the "Others" part, for the panel to know how much room the tools need.
    var onOthersHeight: (CGFloat) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { model.markMoment() } label: {
                    // The glyph is orange, like the marks in Meetings, so a mark is one colour from the panel to the minutes.
                    Label {
                        Text("Mark a Moment")
                    } icon: {
                        Image(systemName: "bookmark.fill").foregroundStyle(.orange)
                    }
                }
                .help(model.markHotKeyAvailable ? Text("Mark this minute of the meeting. Also \(model.markHotKeyText) in any app.")
                                                : Text("Mark this minute of the meeting"))
                Spacer()
                if model.markHotKeyAvailable {
                    Text(verbatim: model.markHotKeyText).font(.caption).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .controlSize(.small)
            // Where the tools scroll (a short screen) the visible area may end between these rows, never through one.
            .panelRowStop()
            if !model.markHotKeyAvailable {
                HotKeyConflictHint(text: model.markHotKeyText, alignment: .leading) { model.showSettings(.general) }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // The user's shorthand notes, with the marks: the header and field are one stop of the panel's scroll, the list
            // another (see `NotesSection`), so a short screen can cut the list but never hides the field.
            NotesSection(model: model)

            if showsOthers {
                OthersEditor(model: model, onHeight: onOthersHeight)
            }
        }
        .panelCard()
    }
}

/// Who "Others" is: the chips of the people named, a field to name them and the attendees to pick from.
struct OthersEditor: View {
    @Bindable var model: RecorderModel
    var onHeight: (CGFloat) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let voice = model.namingLiveSpeaker {
                // Voices are told apart: one chip per voice, and the name field is for the chosen one. The label and the
                // chips are one stop: a short screen ends the visible area above them, never through the chips.
                VStack(alignment: .leading, spacing: 4) {
                    TokenFlowLayout(spacing: 4) {
                        Text("Name for “\(model.liveSpeakerLabel(voice))”").font(.caption).foregroundStyle(.secondary)
                    }
                    TokenFlowLayout(spacing: 4) {
                        ForEach(model.liveSpeakers, id: \.self) { ordinal in
                            LiveSpeakerChip(model: model, ordinal: ordinal, isChosen: ordinal == voice)
                        }
                    }
                    // People named before voices were told apart (or for the meeting as a whole) keep their chip.
                    let unassigned = model.othersNamed.filter { person in !model.liveSpeakerPeople.values.contains { $0.id == person.id } }
                    if !unassigned.isEmpty {
                        TokenFlowLayout(spacing: 4) {
                            ForEach(unassigned) { e in removeChip(e) }
                        }
                    }
                }
                .panelRowStop()
            } else {
                // The label and the chips wrap together when a long name or language does not fit one line.
                TokenFlowLayout(spacing: 4) {
                    Text("Name for “\(Channel.others.displayName)”").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.othersNamed) { e in removeChip(e) }
                }
                .panelRowStop()
            }
            NoCopyField(title: String(localized: "Their name (press Return to add)", comment: "Placeholder: who the other participants are; Return names the match or adds the typed name as a new person"),
                        text: $model.othersQuery, font: .preferredFont(forTextStyle: .callout)) { model.commitOthersName() }
            .panelRowStop()
            if let notice = model.othersNotice {
                Text(verbatim: notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            // "Me" is never one of the others.
            let attendees = model.attendees.filter { a in !a.isSelf && !model.othersNamed.contains { $0.id == a.id } }
            if model.othersQuery.isEmpty && !attendees.isEmpty {
                // Suggestions from the meeting's calendar event: nobody is named until the user picks them.
                chips(attendees.map { ($0.id, $0.displayName) },
                      caption: Text("From the calendar", comment: "Heading of the calendar attendees offered as suggestions for who a speaker or the other participants are (speaker popover and recording panel)"))
            }
            if !model.othersQuery.isEmpty {
                chips(model.othersHits.compactMap { hit in
                    if case .entity(let id) = hit.target { (id, hit.text) } else { nil }
                })
                // The user's own name is not offered: the note above says why, and the button would only repeat it.
                if model.othersNotice == nil {
                    Button("Add “\(model.othersQuery)” as a New Person") { model.addOthersAsNewPerson() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        // The voice the name is for stays put while the user types or points here, whoever speaks meanwhile.
        .onChange(of: model.othersQuery) { model.updateLiveNamingPin() }
        .onHover { model.updateLiveNamingPin(pointerInside: $0) }
        .onDisappear { model.updateLiveNamingPin(pointerInside: false) }
    }

    private func removeChip(_ e: Entity) -> some View {
        Button { model.unnameOthers(e.id) } label: {
            Text(verbatim: e.displayName).font(.caption)
            Image(systemName: "xmark").font(.system(size: 8))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        // A very long name is cut in the chip, never wider than the card.
        .frame(maxWidth: 230)
        .accessibilityLabel(Text("Remove \(e.displayName)"))
    }

    private func chips(_ items: [(Int64, String)], caption: Text? = nil) -> some View {
        TokenFlowLayout(spacing: 4) {
            if let caption { caption.font(.caption).foregroundStyle(.secondary) }
            ForEach(items.prefix(4), id: \.0) { id, name in
                // A suggestion adds a person: a plus and the accent colour tell it apart from a chosen one (filled, with the ×).
                Button { model.nameOthers(id) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                        Text(verbatim: name).font(.caption).lineLimit(1)
                    }
                }
                .buttonStyle(SuggestionChipStyle())
                .frame(maxWidth: 230)
                .accessibilityHint(Text("Adds this person"))
            }
        }
    }
}

/// One voice of the other participants in the panel: its name or "Speaker 2". Choosing it points the name field at it;
/// a named voice has its own button to forget the name. The chosen voice is filled and ringed, so it is never colour alone.
private struct LiveSpeakerChip: View {
    let model: RecorderModel
    let ordinal: Int
    let isChosen: Bool

    private var tint: Color { Channel.others.tint(ordinal: ordinal) }

    var body: some View {
        HStack(spacing: 2) {
            Button { model.chooseLiveSpeaker(ordinal) } label: {
                Text(verbatim: model.liveSpeakerLabel(ordinal)).font(.caption.weight(isChosen ? .semibold : .regular)).lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(tint)
            .accessibilityLabel(Text(verbatim: model.liveSpeakerLabel(ordinal)))
            .accessibilityAddTraits(isChosen ? .isSelected : [])
            .accessibilityHint(Text("Chooses who the name is for"))
            if let person = model.liveSpeakerPeople[ordinal] {
                Button { model.clearLiveSpeakerName(ordinal) } label: {
                    Image(systemName: "xmark").font(.system(size: 8)).frame(width: 14, height: 14).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Clear Name for \(person.displayName)"))
                .help("Clear the name of this speaker")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(isChosen ? 0.16 : 0.07), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(isChosen ? 0.8 : 0.25), lineWidth: isChosen ? 1.5 : 1))
        // A very long name is cut in the chip, never wider than the card.
        .frame(maxWidth: 230)
        .accessibilityElement(children: .contain)
    }
}

/// The "Others" tools in a card of their own: where the screen is too short to pin them under the other tools,
/// they scroll with the cards.
struct OthersCard: View {
    let model: RecorderModel
    var onHeight: (CGFloat) -> Void = { _ in }

    var body: some View {
        OthersEditor(model: model, onHeight: onHeight).panelCard()
    }
}

/// Notes the model takes while recording.
struct LiveNotesView: View {
    let model: RecorderModel
    /// The tallest the whole card may be. Taller notes scroll inside the card, so it always draws its own bottom edge
    /// and padding and the panel's scroll never cuts it (the same way the transcript card keeps its box).
    var maxHeight: CGFloat?
    /// Reports where the card starts in the panel's scrolling content.
    var onTop: (CGFloat) -> Void = { _ in }
    @ViewLocalState private var notesHeight: CGFloat = 0
    @ViewLocalState private var canScrollDown = false
    /// How far the notes are scrolled inside the card, and where their viewport starts in the panel's scrolling content.
    @ViewLocalState private var innerOffset: CGFloat = 0
    @ViewLocalState private var viewportTop: CGFloat = 0
    /// Where each note (and the warning) ends in the scrolling content, to cut the visible height between two of them.
    @ViewLocalState private var rowBottoms: [CGFloat] = []
    /// All the notes are shown (the card grows) instead of the first whole ones.
    @ViewLocalState private var expanded = false
    @Environment(\.panelNotesExpanded) private var startsExpanded

    /// The card around the notes: its padding and the title row with its gap.
    private static let chrome: CGFloat = 24 + 20 + 6

    var body: some View {
        if !model.livePoints.isEmpty || !model.liveDecisions.isEmpty || !model.liveTasks.isEmpty || model.liveNotesError != nil {
            VStack(alignment: .leading, spacing: 6) {
                // The count of the notes under the fold sits in the title row, so the card is no taller for it.
                HStack(spacing: 8) {
                    Label("Live notes", systemImage: "list.bullet.rectangle").panelCardTitle()
                    Spacer(minLength: 4)
                    if hiddenCount > 0 || expanded { moreButton }
                    updateNow
                }
                scrollingNotes
            }
            .panelVautaCard()
            .onAppear { if startsExpanded { expanded = true } }
            .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named(PanelRowStop.space)).minY }) { onTop($0) }
            // Each note that is whole inside the card is a place where the panel's visible area may end, so a card taller
            // than the room is cut between two notes and never through a line of one.
            .background(Color.clear.preference(key: PanelRowStop.Key.self, value: noteStops))
        }
    }

    /// Where the notes that are fully visible end, in the panel's scrolling content.
    private var noteStops: [CGFloat] {
        guard notesHeight > 0 else { return [] }
        let shown = visibleHeight(limit: limit)
        return rowBottoms.map { $0 - innerOffset }
            .filter { $0 > 0 && $0 + Self.fade <= shown + 0.5 }
            .map { viewportTop + $0 }
    }

    /// The most the notes may show: nothing is cut when they are all open or fit.
    private var limit: CGFloat? {
        expanded ? nil : maxHeight.map { max(28, $0 - Self.chrome) }
    }

    /// The notes that end below the visible part.
    private var hiddenCount: Int {
        Self.hiddenCount(rowBottoms: rowBottoms, notesHeight: notesHeight, limit: limit, shown: visibleHeight(limit: limit))
    }

    /// How many notes are not drawn: none when they all fit (or are all open), otherwise those that end below the
    /// last whole note the card shows.
    static func hiddenCount(rowBottoms: [CGFloat], notesHeight: CGFloat, limit: CGFloat?, shown: CGFloat) -> Int {
        guard let limit, notesHeight > 0, notesHeight > limit else { return 0 }
        return rowBottoms.filter { $0 > shown - fade + 0.5 }.count
    }

    /// Writing the notes: a spinner of the size of the title, as in the Answers card. Otherwise, while recording, "Update Now" writes
    /// them from what was said since the last ones (dimmed with nothing new), without waiting for the next 3 minutes.
    @ViewBuilder
    private var updateNow: some View {
        if model.liveNotesRunning {
            ThinkingOrb()
                .frame(width: 16, height: 16)
                .accessibilityElement()
                .accessibilityLabel(Text("Updating the live notes…", comment: "VoiceOver label of the spinner in the Live notes card while the model writes them"))
        } else if model.phase == .recording && model.llmStatus.configured {
            Button { model.updateLiveNotesNow() } label: {
                Image(systemName: "arrow.clockwise").font(.caption.weight(.semibold))
                    .frame(minWidth: 20, minHeight: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!model.canUpdateLiveNotesNow)
            .help(model.canUpdateLiveNotesNow
                  ? String(localized: "Update the live notes with what was said since the last ones", comment: "Help of the Update Now button in the Live notes card of the panel")
                  : String(localized: "Nothing new was said since the last live notes", comment: "Help of the dimmed Update Now button in the Live notes card"))
            .accessibilityLabel(Text("Update Now", comment: "VoiceOver label of the button in the Live notes card that writes the live notes at once"))
        }
    }

    private var moreButton: some View {
        Button { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } } label: {
            HStack(spacing: 4) {
                if expanded {
                    Text("Show Fewer")
                } else {
                    Text("\(hiddenCount) more")
                }
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The words the button shows, with the noun (a spoken label never differs from the visible one).
        .accessibilityLabel(expanded ? Text("Show Fewer") : Text("\(hiddenCount) more notes", comment: "VoiceOver label of the button under the live notes that shows the rest; the argument is how many notes are hidden"))
    }

    private var scrollingNotes: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if let error = model.liveNotesError {
                    // Like every warning in the panel: the icon carries the colour, the title is semibold and the detail
                    // secondary. It comes first, apart from the notes, so it never reads as one of the points.
                    Label {
                        PanelNoticeText(title: error.title, detail: error.detail)
                    } icon: {
                        StatusSymbol.warning.image
                    }
                    .panelBannerLabel(.warning)
                    .accessibilityElement(children: .combine)
                    .reportsRowBottom()
                    if !model.livePoints.isEmpty || !model.liveDecisions.isEmpty || !model.liveTasks.isEmpty {
                        Divider().padding(.vertical, 2)
                    }
                }
                if !model.livePoints.isEmpty {
                    kindHeading("Key points")
                    ForEach(Array(model.livePoints.suffix(5).enumerated()), id: \.offset) { _, point in
                        note(point, symbol: "text.alignleft", size: 10).reportsRowBottom()
                    }
                }
                // The same glyphs as in Meetings (a point, a decision, a task); the sparkle there means "proposed by the
                // model" and is not used here. The kinds also have a heading, so the glyph is never the only clue.
                if !model.liveDecisions.isEmpty {
                    kindHeading("Decisions")
                    ForEach(Array(model.liveDecisions.suffix(3).enumerated()), id: \.offset) { _, decision in
                        note(decision, symbol: "checkmark.seal", size: 10).reportsRowBottom()
                            .accessibilityLabel(Text("Decision: \(decision)"))
                    }
                }
                if !model.liveTasks.isEmpty {
                    kindHeading("Tasks")
                    ForEach(Array(model.liveTasks.suffix(3).enumerated()), id: \.offset) { _, task in
                        note(task, symbol: "checklist", size: 10).reportsRowBottom()
                            .accessibilityLabel(Text("Task: \(task)"))
                    }
                }
            }
            .coordinateSpace(.named(Self.space))
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { notesHeight = $0 }
            .onPreferenceChange(RowBottomsKey.self) { rowBottoms = $0.sorted() }
        }
        .scrollIndicators(.automatic)
        .onScrollGeometryChange(for: Bool.self) { $0.contentSize.height - $0.containerSize.height - $0.contentOffset.y > 1 } action: { _, down in
            canScrollDown = down
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in
            innerOffset = offset
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named(PanelRowStop.space)).minY }) { viewportTop = $0 }
        .mask {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .black.opacity(canScrollDown ? 0 : 1)], startPoint: .top, endPoint: .bottom).frame(height: Self.fade)
            }
        }
        .frame(height: notesHeight > 0 ? visibleHeight(limit: limit) : nil)
        .panelProbe(.notesViewport)
    }

    /// The height to show: all the notes when they fit, otherwise down to the end of the last whole note under the limit, so
    /// the fade covers spacing and never a half-drawn line.
    private func visibleHeight(limit: CGFloat?) -> CGFloat {
        guard let limit, notesHeight > limit else { return notesHeight }
        // The fade takes the gap under the last whole note (the spacing is 6 pt), so its text is fully drawn.
        // With no whole note in the room, the limit itself.
        // Never taller than the limit: the panel budgets the card by it, and a card over it would push the panel past the screen.
        // `notesFloor` keeps room for two whole notes, so a limit that fits none is a note taller than the card itself.
        return rowBottoms.filter { $0 + Self.fade <= limit + 0.5 }.last.map { max($0 + Self.fade, 28) } ?? limit
    }

    private static let space = "liveNotesContent"
    private static let fade: CGFloat = 5

    private func kindHeading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
            // The headings start where the card title's text starts, like everything else in the card.
            .padding(.leading, PanelMetrics.titleTextIndent)
            .accessibilityAddTraits(.isHeader)
    }

    /// One note: every kind has its icon centred on the first line, in a column of the same width,
    /// so the rows are equally tall and all the text starts at one edge.
    private func note(_ text: String, symbol: String, size: CGFloat, tint: Color? = nil, lines: Int = 2) -> some View {
        HStack(alignment: .top, spacing: 6) {
            // A space in the same font gives the column the height of one text line.
            Text(verbatim: " ")
                .frame(width: 16)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: size))
                        .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                        .accessibilityHidden(true)
                }
            Text(verbatim: text).lineLimit(lines).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

private struct RowBottomsKey: PreferenceKey {
    static let defaultValue: [CGFloat] = []
    static func reduce(value: inout [CGFloat], nextValue: () -> [CGFloat]) { value += nextValue() }
}

private extension View {
    /// Reports where this row ends in the notes' scrolling content.
    func reportsRowBottom() -> some View {
        panelProbe(.note).background {
            GeometryReader { proxy in
                Color.clear.preference(key: RowBottomsKey.self, value: [proxy.frame(in: .named("liveNotesContent")).maxY])
            }
        }
    }
}

/// A suggested person: an outlined capsule tinted with the accent colour and a plus, so it never passes for a
/// chosen person (the grey filled capsule with the ×).
private struct SuggestionChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.22 : 0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
            .contentShape(Capsule())
    }
}
