// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// The notes of the meeting being recorded: a field for short notes (one line, Return saves) and the list of every note
/// with what the model wrote from it. It is the "Notes" part of the menu-bar panel and the whole floating notepad.
/// ↑ in the empty field edits the last note; Esc cancels an edit.
struct NotesSection: View {
    @Bindable var model: RecorderModel
    /// The floating notepad: larger text, the list takes the room, the field sits at the bottom.
    var large = false
    /// The tallest the list may be in the panel; the notepad lets it fill the window.
    var maxListHeight: CGFloat? = 132
    /// Esc with nothing to cancel (the notepad closes).
    var onEscape: (() -> Void)?

    private var notepad: NotepadModel { model.notepad }
    /// While recording, and in the notepad after it: the notes then go to the saved meeting (the pad stays usable, as
    /// in Granola and Foresight, until it closes).
    private var canType: Bool { model.phase == .recording || (large && model.phase == .idle && model.notepadSavedMeeting != nil) }
    private var isEmpty: Bool { notepad.rows.isEmpty && notepad.deleted.isEmpty && (!model.isRecording || model.marks.isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if large {
                // The list takes whatever room is left, so the field stays at the bottom whether there are notes or not.
                if isEmpty {
                    Spacer(minLength: 0)
                    if canType { startHint }
                } else {
                    list
                }
                if canType { fieldGroup }
            } else {
                // The header and the field are one stop of the panel's scroll, the list another: a short screen can
                // end between them, but never hides the field.
                VStack(alignment: .leading, spacing: 6) {
                    header
                    if canType { fieldGroup }
                    if isEmpty && canType { startHint }
                }
                .panelRowStop()
                if !isEmpty { list.panelRowStop() }
            }
            notices
        }
    }

    private var fieldGroup: some View {
        VStack(alignment: .leading, spacing: 4) {
            field
            if notepad.editingID != nil {
                Text("Editing note. Return saves, Esc cancels.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var startHint: some View {
        Text("Short notes are enough: Vauta fills in the details from what’s said.")
            .font(large ? .callout : .caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 8) {
            // The count says how many notes the (scrolling) list holds when only the latest show.
            HStack(spacing: 6) {
                Label("Notes", systemImage: "note.text").panelCardTitle()
                if notepad.rows.count > 1 {
                    Text(verbatim: "\(notepad.rows.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            Button { model.openNotepad() } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(model.noteHotKeyAvailable ? Text("Open a floating notepad to type notes without leaving your meeting app. Also \(model.noteHotKeyText) in any app.")
                                            : Text("Open a floating notepad to type notes without leaving your meeting app"))
            .accessibilityLabel(Text("Open Notepad"))
            // The shortcut is shown where the button is, as for Mark a Moment; when another app holds it, the hint says so.
            if model.noteHotKeyAvailable {
                Text(verbatim: model.noteHotKeyText).font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        if !model.noteHotKeyAvailable && model.isRecording {
            HotKeyConflictHint(text: model.noteHotKeyText, alignment: .leading) { model.showSettings(.general) }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var field: some View {
        NoCopyField(title: String(localized: "Add a note", comment: "Placeholder of the field that adds a note to a saved meeting"),
                    text: Bindable(notepad).draft, accessibilityLabel: String(localized: "New note", comment: "Accessibility label of the notes field"),
                    takesInitialFocus: !large,
                    focusRequest: model.notepadFocusRequest + notepad.focusRequest,
                    font: .preferredFont(forTextStyle: large ? .body : .callout),
                    onCommit: { notepad.save() },
                    onFocus: { notepad.fieldFocused = $0 },
                    onMoveUp: { notepad.editLast() },
                    onCancel: { if notepad.editingID != nil { notepad.cancelEdit() } else { onEscape?() } })
    }

    private var list: some View {
        NotesList(notepad: notepad, marks: model.isRecording ? model.marks : [], large: large, maxHeight: large ? nil : maxListHeight)
    }

    @ViewBuilder private var notices: some View {
        if !notepad.rows.isEmpty, !notepad.modelConfigured {
            VStack(alignment: .leading, spacing: 4) {
                Label { Text(verbatim: NoteText.noModel).fixedSize(horizontal: false, vertical: true) } icon: { StatusSymbol.info.image }
                    .font(.caption).foregroundStyle(.secondary)
                Button(SettingsModel.Pane.models.openTitle) { model.showSettings(.models) }.controlSize(.small)
            }
        } else if notepad.languageProblem {
            VStack(alignment: .leading, spacing: 4) {
                Label { Text(verbatim: NoteText.unsupportedLanguage).fixedSize(horizontal: false, vertical: true) } icon: { StatusSymbol.warning.image }
                    .font(.caption).foregroundStyle(.secondary)
                Button(SettingsModel.Pane.models.openTitle) { model.showSettings(.models) }.controlSize(.small)
            }
        }
    }
}

/// The marks and the notes of the meeting in one timeline, oldest first. A deleted note keeps its place until its Undo
/// goes away.
private enum TimelineItem: Identifiable {
    case note(NoteRow)
    case mark(MeetingMark)
    case deleted(NotepadModel.Deleted)

    var id: String {
        switch self {
        case .note(let row): "note-\(row.id)"
        case .mark(let mark): "mark-\(mark.id)"
        case .deleted(let gone): "deleted-\(gone.id)"
        }
    }

    var t: Double {
        switch self {
        case .note(let row): row.note.t
        case .mark(let mark): mark.t
        case .deleted(let gone): gone.row.note.t
        }
    }

    var order: Int64 {
        switch self {
        case .note(let row): row.id
        case .mark(let mark): mark.id
        case .deleted(let gone): gone.row.id
        }
    }
}

/// Every mark and note, the newest last, scrolling inside its card. The newest stays in view; when the list is cut, it is
/// cut between two rows (a fade over the gap), so a half-drawn line never starts it.
struct NotesList: View {
    let notepad: NotepadModel
    var marks: [MeetingMark] = []
    var large: Bool
    var maxHeight: CGFloat?
    @ViewLocalState private var contentHeight: CGFloat = 0
    @ViewLocalState private var canScrollUp = false
    /// Where each row starts in the scrolling content.
    @ViewLocalState private var rowTops: [CGFloat] = []
    /// The room the floating notepad gives the list (the panel has a fixed limit instead).
    @ViewLocalState private var available: CGFloat = 0

    private var spacing: CGFloat { large ? 10 : 8 }

    private var items: [TimelineItem] {
        let all = notepad.rows.map(TimelineItem.note) + marks.map(TimelineItem.mark) + notepad.deleted.map(TimelineItem.deleted)
        return all.sorted { ($0.t, $0.order) < ($1.t, $1.order) }
    }

    /// The height to show: everything when it fits, otherwise from the start of the first row that fits under the limit
    /// (less the gap above it, where the fade is) to the end.
    private var visibleHeight: CGFloat? {
        guard let maxHeight = maxHeight ?? (available > 0 ? available : nil) else { return nil }
        guard contentHeight > maxHeight else { return max(contentHeight, 1) }
        let wanted = contentHeight - maxHeight + spacing
        guard let top = rowTops.first(where: { $0 >= wanted - 0.5 }) else { return maxHeight }
        return min(maxHeight, contentHeight - max(0, top - spacing))
    }

    var body: some View {
        let items = items
        if !items.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: spacing) {
                        ForEach(items) { item in
                            row(item).id(item.id).reportsRowTop()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .coordinateSpace(name: Self.space)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
                    .onPreferenceChange(RowTopsKey.self) { rowTops = $0.sorted() }
                }
                .scrollIndicators(.automatic)
                .defaultScrollAnchor(.bottom)
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 1 } action: { _, up in canScrollUp = up }
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.black.opacity(canScrollUp ? 0 : 1), .black], startPoint: .top, endPoint: .bottom).frame(height: spacing)
                        Rectangle()
                    }
                }
                .frame(height: visibleHeight)
                .frame(maxHeight: large ? .infinity : nil, alignment: .top)
                // The notepad cuts its list between two rows too: the room it has is measured, not guessed.
                .onGeometryChange(for: CGFloat.self, of: { large && maxHeight == nil ? $0.size.height : 0 }) { available = $0 }
                .onChange(of: items.map(\.id)) {
                    if let last = items.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
    }

    static let space = "notesListContent"

    @ViewBuilder private func row(_ item: TimelineItem) -> some View {
        switch item {
        case .note(let row): NoteLine(notepad: notepad, row: row, large: large)
        case .mark(let mark): MarkLine(mark: mark, large: large)
        case .deleted(let gone): NoteDeletedLine(notepad: notepad, deleted: gone)
        }
    }
}

/// A moment the user marked: its time and the orange bookmark, as in the minutes and in Meetings.
struct MarkLine: View {
    let mark: MeetingMark
    var large = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(.orange).frame(width: 14).accessibilityHidden(true)
            Text(verbatim: ElapsedTime.stamp(Int(mark.t))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .font(large ? .body : .callout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Moment marked at \(ElapsedTime.stamp(Int(mark.t))).", comment: "VoiceOver announcement; the argument is the time in the meeting"))
    }
}

private struct RowTopsKey: PreferenceKey {
    static let defaultValue: [CGFloat] = []
    static func reduce(value: inout [CGFloat], nextValue: () -> [CGFloat]) { value += nextValue() }
}

private extension View {
    /// Reports where this row starts in the list's scrolling content.
    func reportsRowTop() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: RowTopsKey.self, value: [proxy.frame(in: .named(NotesList.space)).minY])
            }
        }
    }
}
