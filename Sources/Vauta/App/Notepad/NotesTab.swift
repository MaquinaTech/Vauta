// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// The user's notes of a saved meeting, first among its tabs: their document. Each note is the user's own words with what
/// the model wrote from the transcript indented under it, every sentence with the moments it cites (a click opens the
/// transcript there). The user's words always come first and are never replaced; ⌘Z takes back an edit, a delete and
/// every change to an expansion.
struct NotesTab: View {
    @Bindable var model: MeetingsModel
    let recorder: RecorderModel
    let meeting: MeetingStore.Meeting
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var notepad: NotepadModel { model.notepad }
    /// The meeting being recorded. Its notes belong to the menu-bar panel and the floating notepad (one list, one live pass):
    /// a second notepad here would write notes with the wrong time and ask the model while the call goes on.
    private var recordingThis: Bool { recorder.meetingID == meeting.id || model.activeMeetingID == meeting.id }

    private enum Item: Identifiable {
        case note(NoteRow)
        case deleted(NotepadModel.Deleted)
        var id: String {
            switch self {
            case .note(let row): "note-\(row.id)"
            case .deleted(let gone): "deleted-\(gone.id)"
            }
        }
        var key: (Double, Int64) {
            switch self {
            case .note(let row): (row.note.t, row.id)
            case .deleted(let gone): (gone.row.note.t, gone.row.id)
            }
        }
    }

    private var timeline: [Item] {
        (notepad.rows.map(Item.note) + notepad.deleted.map(Item.deleted)).sorted { $0.key < $1.key }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: PaneLayout.section) {
                    if notepad.rows.isEmpty && notepad.deleted.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No notes for this meeting.").font(.headline)
                            Text(notepad.modelConfigured && notepad.hasTranscript
                                 ? "Short notes are enough: Vauta fills in the details from what’s said."
                                 : "Notes you add are saved with the meeting.")
                                .foregroundStyle(.secondary)
                            if !notepad.hasTranscript {
                                Label { Text(verbatim: NoteText.noTranscript) } icon: { Image(systemName: "text.page.slash").accessibilityHidden(true) }
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    VStack(alignment: .leading, spacing: PaneLayout.item * 2) {
                        // A deleted note's "Undo" stays where the note was.
                        ForEach(timeline) { item in
                            switch item {
                            case .note(let row): NoteBlock(model: model, meeting: meeting, row: row, readOnly: recordingThis).id(row.id)
                            case .deleted(let gone): NoteDeletedLine(notepad: notepad, deleted: gone)
                            }
                        }
                    }
                    notices
                    if recordingThis {
                        Label { Text("This meeting is being recorded. Add and edit its notes in the menu bar panel or the floating notepad.", comment: "Notes tab of the meeting being recorded: the notes are read-only here") } icon: { StatusSymbol.info.image }
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        NoCopyField(title: String(localized: "Add a note", comment: "Placeholder of the field that adds a note to a saved meeting"),
                                    text: Bindable(notepad).draft,
                                    accessibilityLabel: String(localized: "Add a note", comment: "Accessibility label of the field that adds a note to a saved meeting"),
                                    avoidsInitialFocus: true, onCommit: { notepad.save() }, onFocus: { notepad.fieldFocused = $0 })
                    }
                }
                .padding(PaneLayout.pane)
                .frame(maxWidth: 760, alignment: .leading)
            }
            .onChange(of: model.highlightedNote, initial: true) {
                guard let id = model.highlightedNote, notepad.rows.contains(where: { $0.id == id }) else { return }
                withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(id, anchor: .center) }
            }
            // The highlight of a search result is a pointer, not a state: it goes after a few seconds.
            .task(id: model.highlightedNote) {
                guard let id = model.highlightedNote else { return }
                try? await Task.sleep(for: .seconds(6))
                if model.highlightedNote == id { model.highlightedNote = nil }
            }
            .onChange(of: notepad.rows.map(\.id)) {
                guard let id = model.highlightedNote, notepad.rows.contains(where: { $0.id == id }) else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
        // A model that is set up later: the notes typed after this meeting that have none yet are written now (once per
        // meeting and model). Never for the meeting being recorded, nor while its minutes job is queued or running: the
        // final pass writes those notes, and a request here would stop it.
        .task(id: "\(meeting.id)-\(notepad.modelConfigured)") {
            guard recorder.meetingID != meeting.id,
                  !model.jobs.contains(where: { $0.meetingID == meeting.id && $0.kind == .minutes && ($0.state == .queued || $0.state == .running) })
            else { return }
            await notepad.expandMissing()
        }
        .onChange(of: recorder.llmStatus.configured, initial: true) { notepad.modelConfigured = recorder.llmStatus.configured }
        // The meeting being recorded: its notes wait for more of the meeting, and follow what the panel and the notepad change.
        .onChange(of: recordingThis, initial: true) { notepad.live = recordingThis }
        .onChange(of: recorder.notepad.rows) {
            guard recordingThis, recorder.notepad.meetingID == meeting.id else { return }
            Task { await notepad.reload(markUpdates: false) }
        }
        .environment(\.copyProtection, model.copyProtected)
    }

    @ViewBuilder private var notices: some View {
        // Said once for the whole meeting, never under every note.
        if !notepad.rows.isEmpty, !notepad.hasTranscript {
            Label { Text(verbatim: NoteText.noTranscript) } icon: { Image(systemName: "text.page.slash").accessibilityHidden(true) }
                .font(.callout).foregroundStyle(.secondary)
        }
        if !notepad.rows.isEmpty, !notepad.modelConfigured {
            HStack(alignment: .firstTextBaseline) {
                Label { Text(verbatim: NoteText.noModel) } icon: { StatusSymbol.info.image }
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(SettingsModel.Pane.models.openTitle) { recorder.showSettings(.models) }
            }
        } else if notepad.languageProblem {
            HStack(alignment: .firstTextBaseline) {
                Label { Text(verbatim: NoteText.unsupportedLanguage) } icon: { StatusSymbol.warning.image }
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(SettingsModel.Pane.models.openTitle) { recorder.showSettings(.models) }
            }
        }
    }
}

/// One note of the Notes tab.
private struct NoteBlock: View {
    @Bindable var model: MeetingsModel
    let meeting: MeetingStore.Meeting
    let row: NoteRow
    /// The meeting is being recorded: the notes are shown, not changed, here.
    var readOnly = false
    private var editingWords: Bool { notepad.editingWordsID == row.id }
    private var editingExpansion: Bool { notepad.editingExpansionID == row.id }

    private var notepad: NotepadModel { model.notepad }
    private var status: NotepadModel.Status { notepad.status(of: row) }
    private var isHighlighted: Bool { model.highlightedNote == row.id }
    private var sentences: [NoteExpansion.Sentence] { row.visibleSentences }
    /// The user rewrote the expansion: its words are theirs, so it carries no verification marks.
    private var userEdited: Bool { row.expansion?.userEdited == true }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "note.text").foregroundStyle(Color(nsColor: .systemYellow))
                .frame(width: SourceBadge.columnWidth).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                words
                if editingExpansion {
                    expansionEditor
                } else if !sentences.isEmpty {
                    expansion
                }
                if let text = status.text, status != .noTranscript, status != .edited || sentences.isEmpty { statusLine(text, symbol: status.symbol) }
                if notepad.updated.contains(row.id) { updatedLine }
            }
        }
        .padding(8)
        .background(isHighlighted ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: isHighlighted ? 1.5 : 0))
        .contextMenu { menuItems }
        // Keyboard: Tab reaches the note, Return edits its words, ⌘⌫ asks to delete it.
        .focusable()
        .onKeyPress(.return) {
            guard !readOnly, !editingWords, !editingExpansion else { return .ignored }
            startEditingWords()
            return .handled
        }
        .onKeyPress(keys: [.delete, .deleteForward]) { press in
            guard !readOnly, press.modifiers.contains(.command), !editingWords, !editingExpansion else { return .ignored }
            model.pendingDeletion = .note(row.note)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NoteText.spokenNote(row)))
    }

    private func startEditingWords() {
        notepad.wordsDraft = row.note.text
        notepad.editingWordsID = row.id
    }

    // MARK: The user's words

    @ViewBuilder private var words: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TimeButton(t: row.note.t, plain: model.transcript.isEmpty) { model.open(meeting: meeting.id, at: row.note.t) }
            if editingWords {
                NoCopyText(text: Bindable(notepad).wordsDraft,
                           placeholder: String(localized: "Note", comment: "Placeholder of a note being edited"),
                           accessibilityLabel: String(localized: "Edit Note"), singleLine: true, checksSpelling: false, takesInitialFocus: true,
                           onCommit: commitWords, onFocusChange: { if !$0 { commitWords() } }, onCancel: { notepad.editingWordsID = nil })
                    .frame(height: 24)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            } else {
                // The user's words: primary colour, whole, never replaced by the model's.
                ProtectedText(row.note.text).frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    // Double-click to type over them, as in a notepad; the menu and Return do the same.
                    .simultaneousGesture(TapGesture(count: 2).onEnded { if !readOnly { startEditingWords() } })
                    .accessibilityHidden(true)
            }
            if !readOnly {
                Menu { menuItems } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(Text("Note actions", comment: "Tooltip of the menu of a note"))
                    .accessibilityLabel(Text("Note actions", comment: "Accessibility label of the menu of a note"))
            }
        }
    }

    private func commitWords() {
        guard editingWords else { return }
        // Plain words, one line: a note is a bullet (Return commits, so pasted line breaks are flattened).
        let text = notepad.wordsDraft.split(whereSeparator: \.isNewline).joined(separator: " ")
        let id = row.id
        notepad.editingWordsID = nil
        // Clearing the words asks before deleting (see `NotepadModel.confirmDelete`); the other changes are saved.
        Task { await notepad.change(id, to: text) }
    }

    @ViewBuilder private var menuItems: some View {
        if readOnly {
            Button("Copy") { copy() }.disabled(model.copyProtected)
        } else {
            editableMenuItems
        }
    }

    @ViewBuilder private var editableMenuItems: some View {
        Button("Edit Note") { startEditingWords() }
        Button("Expand Again") { Task { await notepad.expandAgain(row.id) } }.disabled(!notepad.modelConfigured || !notepad.hasTranscript)
        if !sentences.isEmpty {
            Button("Edit Expansion") { notepad.expansionDraft = NoteExpansionText.joined(sentences); notepad.editingExpansionID = row.id }
            Button("Remove Expansion") { Task { await notepad.removeExpansion(row.id) } }
        } else if row.expansion?.state == .dismissed {
            Button("Show Expansion") { Task { await notepad.showExpansion(row.id) } }
        }
        Divider()
        Button("Copy") { copy() }.disabled(model.copyProtected)
        Button("Delete Note…", role: .destructive) { model.pendingDeletion = .note(row.note) }
    }

    private func copy() {
        // The labels travel with the text, as in the exports: a sentence that differs and a claim the transcript does not back
        // keep their caveat when pasted.
        let lines = sentences.map { s -> String in
            let unconfirmed = s.unconfirmed && !userEdited
            let entry = MeetingExport.NoteEntry.Sentence(text: s.text, times: s.cites.map(\.t), segmentIDs: s.cites.map(\.seg),
                                                         unconfirmed: unconfirmed, differs: s.differs)
            return "  " + MeetingExportRenderer.sentenceText(entry) + (unconfirmed ? " — " + MeetingExportRenderer.unconfirmedLabel : "")
        }
        let text = ([row.note.text] + lines + (userEdited && !lines.isEmpty ? ["  " + MeetingExportRenderer.editedByYouLabel] : [])).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: What the model wrote

    private var expansion: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            ExpansionMark(edited: userEdited).frame(width: 16)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(sentences.enumerated()), id: \.offset) { index, s in sentenceView(s, index: index) }
                if userEdited {
                    Text(verbatim: NoteText.edited).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Always secondary: the user's words are the document. An out-of-date expansion keeps the same readable level (the
        // person has to read it to choose Expand Again) and is set apart in italics, not by lowering its contrast.
        .foregroundStyle(.secondary)
        .font(.callout)
        .italic(status == .stale)
        .padding(.leading, 4)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == Self.citeScheme, let seg = url.host.flatMap({ Int64($0) }) else { return .discarded }
            model.open(meeting: meeting.id, segment: seg)
            return .handled
        })
        .accessibilityElement(children: .contain)
    }

    private static let citeScheme = "vauta-segment"

    private func sentenceView(_ s: NoteExpansion.Sentence, index: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if s.differs {
                Image(systemName: "exclamationmark.bubble").foregroundStyle(.secondary).accessibilityHidden(true)
            }
            ProtectedText(sentenceText(s))
            if s.unconfirmed && !userEdited {
                UnconfirmedBadge()
                IconButton(label: String(localized: "Mark as Checked", comment: "Button on an item the model proposed and nobody has confirmed: the user has checked it"),
                           systemImage: "checkmark.circle") { Task { await notepad.markChecked(row.id, sentence: index) } }
            }
        }
    }

    /// The sentence with its moments at the end, in the line: a time that opens the transcript there; a passage that retention
    /// removed keeps its time and nothing to open.
    private func sentenceText(_ s: NoteExpansion.Sentence) -> Text {
        var out = AttributedString((s.differs ? NoteText.transcriptSays + " " : "") + s.text)
        for cite in s.cites {
            var chip = AttributedString("\u{00A0}" + ElapsedTime.stamp(cite.t))
            chip.font = .caption.monospacedDigit()
            if notepad.isCitationLive(cite) {
                chip.link = URL(string: "\(Self.citeScheme)://\(cite.seg)")
            }
            out += AttributedString(" ") + chip
        }
        return Text(out)
    }

    private var expansionEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            NoCopyText(text: Bindable(notepad).expansionDraft,
                       placeholder: String(localized: "One sentence per line", comment: "Placeholder of the editor of an expanded note"),
                       accessibilityLabel: String(localized: "Edit Expansion"), checksSpelling: false, takesInitialFocus: true,
                       onCancel: { notepad.editingExpansionID = nil })
                .frame(minHeight: 70, maxHeight: 180)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            Text("Changed sentences lose their links to the transcript.", comment: "Under the editor of an expanded note: a sentence the user changes has no citation any more")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Save") {
                    let text = notepad.expansionDraft
                    notepad.editingExpansionID = nil
                    Task { await notepad.saveExpansion(row.id, text: text) }
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .keyboardShortcut(.return, modifiers: .command)
                Button("Cancel") { notepad.editingExpansionID = nil }.controlSize(.small)
            }
        }
        .padding(.leading, 4)
    }

    private func statusLine(_ text: String, symbol: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if status == .working {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 12)
            } else if let symbol {
                Image(systemName: symbol).frame(width: 16).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                // The link follows the first line, close to it; the reason (a longer line) goes under both.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: text)
                    if let label = expandLink {
                        // The link keeps its own colour: the grey is only for the glyph and the words.
                        Button(label) { Task { await notepad.expandAgain(row.id) } }.buttonStyle(.link).foregroundStyle(Color.accentColor)
                    }
                }
                if let detail = notepad.failureDetail(of: row) { Text(verbatim: detail).font(.footnote) }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.leading, 4)
    }

    /// The one-click action of a state, only when it can work: a model is set up, there is a transcript, the meeting is not
    /// being recorded, and (for a note changed after) no final pass is about to write it.
    private var expandLink: String? {
        guard !readOnly, notepad.modelConfigured, notepad.hasTranscript else { return nil }
        switch status {
        case .notFound, .failed, .notAnswering: return String(localized: "Expand Again")
        case .stale: return notepad.finalPassComing() ? nil : String(localized: "Expand Again")
        case .notExpanded: return String(localized: "Expand Note", comment: "Link under a note of a finished meeting that the model has not written out yet")
        default: return nil
        }
    }

    private var updatedLine: some View {
        HStack(spacing: 6) {
            Text("Updated").foregroundStyle(.secondary)
            Text(verbatim: "·").foregroundStyle(.secondary).accessibilityHidden(true)
            Button("Undo") { Task { await notepad.revert(row.id) } }.buttonStyle(.link)
        }
        .font(.callout)
        .padding(.leading, 4)
    }
}
