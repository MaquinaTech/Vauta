// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import SwiftUI

/// The Meetings window's model, while that window is key.
private struct MeetingsModelKey: FocusedValueKey {
    typealias Value = MeetingsModel
}

extension FocusedValues {
    var meetingsModel: MeetingsModel? {
        get { self[MeetingsModelKey.self] }
        set { self[MeetingsModelKey.self] = newValue }
    }
}

/// Menu commands of the Meetings window: Import Recording… and Export… in
/// the File menu, Copy Minutes in the Edit menu and the four modes in View.
struct MeetingsCommands: Commands {
    @FocusedValue(\.meetingsModel) private var model

    var body: some Commands {
        CommandGroup(replacing: .importExport) {
            Button("Import Recording…") { Task { await model?.importer.chooseFile() } }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("Export…") { model?.requestExport() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model?.shownMeeting == nil || model?.mode != .meetings)
            Button("Follow Up…") { model?.openFollowUp() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(model?.canOpenFollowUp != true)
        }
        CommandGroup(after: .pasteboard) {
            Button("Copy Minutes") { Task { await model?.copyMinutes(asMarkdown: true) } }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model?.shownMeeting == nil || model?.mode != .meetings)
            Button("Copy Minutes as Plain Text") { Task { await model?.copyMinutes(asMarkdown: false) } }
                .disabled(model?.shownMeeting == nil || model?.mode != .meetings)
        }
        CommandGroup(after: .textEditing) {
            // ⌘F finds in the transcript of the meeting shown, as in a document; with none it searches the meetings, which
            // ⌥⌘F always does (as Mail's Mailbox Search).
            Button(model?.canFindInMeeting == true
                   ? String(localized: "Find in Meeting", comment: "Edit menu (⌘F) and placeholder of its field: finds a text in the transcript of the meeting shown")
                   : String(localized: "Search Meetings")) { model?.showFind() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model == nil)
            Button("Find Next") { model?.findNext() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(model?.canFindNext != true)
            Button("Find Previous") { model?.findNext(forward: false) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model?.canFindNext != true)
            Button("Search Meetings") { model?.searchFocusRequest += 1 }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(model == nil)
            // The keyboard way into the speaker popover: the highlighted passage (arrow keys) is the one it is about.
            Button("Speaker Options for Highlighted Passage") { model?.openSpeakerOptionsOfHighlight() }
                .disabled(model?.canOpenSpeakerOptionsOfHighlight != true)
            Button("Correct Highlighted Passage") { model?.correctHighlight() }
                .disabled(model?.canCorrectHighlight != true)
            Button("Delete Meeting…") {
                // The ⌘⌫ key in a text field still deletes to the start of the line; choosing the menu item
                // with the mouse or VoiceOver always asks to delete the meeting.
                if NSApp.currentEvent?.type == .keyDown, let text = NSApp.keyWindow?.firstResponder as? NSTextView {
                    text.deleteToBeginningOfLine(nil)
                } else {
                    model?.confirmDeleteSelected()
                }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(model?.shownMeeting == nil || model?.mode != .meetings || model?.isActive == true)
        }
        CommandGroup(before: .sidebar) {
            ForEach(MeetingsModel.Mode.allCases) { mode in
                Button(mode.label) { model?.mode = mode }
                    .keyboardShortcut(KeyEquivalent(mode.shortcut), modifiers: .command)
                    .disabled(model == nil)
            }
            Divider()
        }
    }
}
