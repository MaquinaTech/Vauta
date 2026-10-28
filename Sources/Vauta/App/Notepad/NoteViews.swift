// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// The words and glyphs of a note's state, the same in the panel, the notepad and the Notes tab. Every state has a glyph
/// and a sentence: colour never carries a state alone.
enum NoteText {
    static var waiting: String { String(localized: "Waiting for more of the meeting", comment: "State of a note the model has not written out yet: the speaker may still be explaining it") }
    static var expanding: String { String(localized: "Expanding…", comment: "State of a note while the model writes it out in full from the transcript") }
    static var notFound: String { String(localized: "Not found in the transcript", comment: "State of a note: the transcript does not talk about it") }
    static var stale: String { String(localized: "Your note changed", comment: "State of a note whose words the user changed after the model wrote it out; the model writes it again") }
    static var failed: String { String(localized: "Couldn’t expand this note.", comment: "State of a note the model could not write out") }
    static var expandingNotes: String { String(localized: "Expanding notes", comment: "Model server activity in the menu bar panel: the model writes the user’s short notes out in full") }
    static var notExpanded: String { String(localized: "Not expanded yet", comment: "State of a note in a meeting that is over: the model has not written it out yet") }
    // Only a model server can fail this way (the on-device model has no network or busy states), so the live-notes sentence is exact.
    static var notAnswering: String { String(localized: "The model server didn’t answer. Vauta will try again.", comment: "Live notes notice, temporary: the model server was slow, busy or not answering; the next try is automatic") }
    static var unsupportedLanguage: String { String(localized: "The model on this Mac can’t write in this language.", comment: "State of a note: Apple’s on-device model does not support the language of the meeting") }
    static var noTranscript: String { String(localized: "There’s no transcript to expand notes from.", comment: "Shown in the notes of a meeting that has no transcript (it was purged or never had one)") }
    static var edited: String { String(localized: "Edited by you", comment: "Badge on an expansion the user rewrote") }
    static var transcriptSays: String { String(localized: "The transcript says:", comment: "Starts a sentence when the transcript says something different from what the user noted; the sentence follows") }
    static var byModel: String { String(localized: "Written by the model from the transcript", comment: "Help and VoiceOver label of the sparkle before text the model wrote from the transcript") }
    static var noModel: String { String(localized: "Notes are saved. To expand them, choose a model in Settings\u{00A0}→\u{00A0}Models.", comment: "Shown once in the notes card when no model is set up") }
    static var yourNote: String { String(localized: "Your note", comment: "VoiceOver label of the notes the user typed") }
    static var purged: String { String(localized: "This part of the transcript is no longer kept", comment: "Help of a time on an expanded note whose transcript passage was deleted by retention") }

    static func spokenNote(_ row: NoteRow) -> String {
        String(localized: "Your note, \(ElapsedTime.spoken(Int(row.note.t))): \(row.note.text)", comment: "VoiceOver label of a note; the arguments are its time in the meeting and the user’s words")
    }

    static func spokenExpansion(_ row: NoteRow) -> String {
        let sentences = row.visibleSentences
        let text = sentences.map(\.text).joined(separator: " ")
        let passages = Set(sentences.flatMap { $0.cites.map(\.seg) }).count
        let edited = row.expansion?.userEdited == true
        let unconfirmed = edited ? 0 : sentences.filter(\.unconfirmed).count
        var parts = [edited ? String(localized: "Edited by you: \(text)", comment: "VoiceOver value of a note: the expansion the user rewrote; the argument is the text")
                            : String(localized: "Expanded from the transcript: \(text)", comment: "VoiceOver value of a note: what the model wrote from the transcript; the argument is the text")]
        if passages > 0 { parts.append(String(localized: "\(passages) passages", comment: "VoiceOver: how many transcript passages an expanded note cites")) }
        if unconfirmed > 0 { parts.append(String(localized: "\(unconfirmed) unconfirmed", comment: "VoiceOver: how many sentences of an expanded note the transcript does not back")) }
        return parts.joined(separator: "; ")
    }
}

extension NotepadModel.Status {
    /// The glyph of the state; nil for a spinner or for a state without one.
    var symbol: String? {
        switch self {
        case .working, .done, .noModel, .dismissed: nil
        case .waiting, .notExpanded, .queued: "clock"
        case .noTranscript: "text.page.slash"
        case .edited: "pencil"
        case .stale: "arrow.triangle.2.circlepath"
        case .notFound: "magnifyingglass"
        case .notAnswering: "wifi.exclamationmark"
        case .unsupportedLanguage: "globe"
        case .failed: "exclamationmark.triangle"
        }
    }

    var text: String? {
        switch self {
        case .working: NoteText.expanding
        case .waiting: NoteText.waiting
        case .notExpanded: NoteText.notExpanded
        case .queued: NoteText.expandingNotes
        case .noTranscript: NoteText.noTranscript
        case .edited: NoteText.edited
        case .stale: NoteText.stale
        case .notFound: NoteText.notFound
        case .notAnswering: NoteText.notAnswering
        // The reason is the warning under the list (NoteText.unsupportedLanguage); the note's own line stays short so it is not read twice.
        case .unsupportedLanguage: NoteText.notExpanded
        case .failed: NoteText.failed
        case .done, .noModel, .dismissed: nil
        }
    }

    /// A state that needs a line of its own under the note (the quiet ones are only a glyph at the end of the row).
    var needsLine: Bool {
        switch self {
        case .notFound, .stale, .notAnswering, .unsupportedLanguage, .failed, .noTranscript, .edited, .notExpanded, .queued: true
        case .working, .waiting, .done, .noModel, .dismissed: false
        }
    }
}

/// The sparkle that says the text next to it was written by the model, never by the user.
struct ModelSparkle: View {
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Image(systemName: "sparkles")
            .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(Brand.sparkle))
            .help(NoteText.byModel)
            .accessibilityLabel(Text(NoteText.byModel))
    }
}

/// The glyph before an expansion: the sparkle while the text is the model's, a pencil once the user rewrote it ("Edited by
/// you"), because the words are no longer the model's.
struct ExpansionMark: View {
    var edited: Bool

    var body: some View {
        if edited {
            Image(systemName: "pencil").foregroundStyle(.secondary).help(NoteText.edited).accessibilityLabel(Text(NoteText.edited))
        } else {
            ModelSparkle()
        }
    }
}

/// One shorthand note in the menu-bar panel and in the floating notepad: the user's words first, always whole, then (when
/// the model wrote one) the first sentence of the expansion under them in the secondary colour, with the sparkle.
struct NoteLine: View {
    let notepad: NotepadModel
    let row: NoteRow
    /// The floating notepad uses the larger text.
    var large = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var status: NotepadModel.Status { notepad.status(of: row) }
    private var isDisclosed: Bool { notepad.disclosed.contains(row.id) }
    private var isEditing: Bool { notepad.editingID == row.id }
    private var shownStatus: Bool {
        switch status {
        case .done, .edited, .stale: !row.visibleSentences.isEmpty
        default: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "note.text").font(.caption).foregroundStyle(Color(nsColor: .systemYellow))
                    .frame(width: 14).accessibilityHidden(true)
                Text(verbatim: ElapsedTime.stamp(Int(row.note.t))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                // The user's words: primary colour, shown whole (three lines in the panel, then a tooltip with all of it).
                // In the notepad, the main typing surface, the whole note shows; the panel is short on room.
                Text(verbatim: row.note.text).font(large ? .body : .callout).lineLimit(large ? nil : 3).help(row.note.text)
                    .fixedSize(horizontal: false, vertical: large)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            if shownStatus { expansion }
            if status.needsLine, let text = status.text { statusLine(text) }
            if notepad.updated.contains(row.id) { updatedLine }
        }
        // The note being changed in the field is marked in the list (a frame as well as a tint).
        .padding(isEditing ? 4 : 0)
        .background(isEditing ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: isEditing ? 1 : 0))
        .contentShape(Rectangle())
        // Keyboard: Tab reaches the row, Return edits it, ⌘⌫ deletes it (with Undo).
        .focusable()
        .onKeyPress(.return) {
            notepad.edit(row.id)
            return .handled
        }
        .onKeyPress(keys: [.delete, .deleteForward]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            Task { await notepad.delete(row.id) }
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(NoteText.spokenNote(row)))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityActions {
            if !row.visibleSentences.isEmpty {
                Button(isDisclosed ? String(localized: "Show Fewer") : String(localized: "Show Full Note", comment: "VoiceOver action on a note: opens the whole text the model wrote under it. Different from the menu command that brings back a removed expansion")) { notepad.toggle(row.id) }
            }
            if notepad.updated.contains(row.id) {
                Button(String(localized: "Undo Update", comment: "VoiceOver action on a note the model just wrote again: brings back the version before"))  { Task { await notepad.revert(row.id) } }
            }
            Button("Edit Note") { notepad.edit(row.id) }
            Button("Delete Note") { Task { await notepad.delete(row.id) } }
        }
        .contextMenu {
            Button("Edit Note") { notepad.edit(row.id) }
            Button("Expand Again") { Task { await notepad.expandAgain(row.id) } }.disabled(!notepad.modelConfigured || !notepad.hasTranscript)
            if row.expansion?.state == .dismissed {
                Button("Show Expansion") { Task { await notepad.showExpansion(row.id) } }
            } else if !row.visibleSentences.isEmpty {
                Button("Remove Expansion") { Task { await notepad.removeExpansion(row.id) } }
            }
            Divider()
            Button("Delete Note", role: .destructive) { Task { await notepad.delete(row.id) } }
        }
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if !row.visibleSentences.isEmpty { parts.append(NoteText.spokenExpansion(row)) }
        if let text = status.text { parts.append(text) }
        return parts.joined(separator: ". ")
    }

    @ViewBuilder private var trailing: some View {
        switch status {
        case .working:
            // Only the spinner, in the panel and the notepad, so the user's words keep their room (the state is also its
            // help and its VoiceOver value).
            HStack(spacing: 4) {
                ThinkingOrb(diameter: 12).frame(width: 14, height: 14)
            }
            .fixedSize()
            .help(NoteText.expanding)
        case .waiting:
            Image(systemName: "clock").font(.caption).foregroundStyle(.secondary).help(NoteText.waiting)
        default:
            EmptyView()
        }
    }

    /// The first sentence (all of them once opened), indented under the user's words.
    private var expansion: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { notepad.toggle(row.id) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ExpansionMark(edited: row.expansion?.userEdited == true).font(.caption).frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array((isDisclosed ? row.visibleSentences : Array(row.visibleSentences.prefix(1))).enumerated()), id: \.offset) { _, s in
                        sentence(s)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 20)
        .accessibilityHidden(true)
    }

    private func sentence(_ s: NoteExpansion.Sentence) -> some View {
        // "Unconfirmed" is a word with its glyph on a line of its own: never a colour or a glyph alone.
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if s.differs {
                    Image(systemName: "exclamationmark.bubble").accessibilityHidden(true)
                }
                Text(verbatim: (s.differs ? NoteText.transcriptSays + " " : "") + s.text)
                    .lineLimit(isDisclosed ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The user's own version carries no verification marks.
            if s.unconfirmed && row.expansion?.userEdited != true { UnconfirmedBadge() }
        }
        .font(large ? .callout : .caption)
        .foregroundStyle(status == .stale ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
    }

    private func statusLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // "Edited by you" already has its pencil before the sentence.
            if status == .edited && shownStatus {
                Color.clear.frame(width: 14, height: 1).accessibilityHidden(true)
            } else if let symbol = status.symbol {
                Image(systemName: symbol).font(.caption).frame(width: 14).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: text).font(.caption).fixedSize(horizontal: false, vertical: true)
                if let detail = notepad.failureDetail(of: row) {
                    Text(verbatim: detail).font(.caption2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 20)
    }

    /// "Updated · Undo": a pass wrote the note again; the version before is one click away.
    private var updatedLine: some View {
        HStack(spacing: 6) {
            Text("Updated").font(.caption).foregroundStyle(.secondary)
            Text(verbatim: "·").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            Button("Undo") { Task { await notepad.revert(row.id) } }.buttonStyle(.link).font(.caption)
        }
        .padding(.leading, 20)
    }
}

/// "Note deleted · Undo" for a few seconds after a note was removed from the panel or the notepad.
struct NoteDeletedLine: View {
    let notepad: NotepadModel
    let deleted: NotepadModel.Deleted

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "trash").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Note deleted").font(.callout).foregroundStyle(.secondary)
            Button("Undo") { Task { await notepad.undoDelete(deleted.id) } }.buttonStyle(.link).font(.callout)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }
}
