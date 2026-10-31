// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// The bar of Find in Meeting, over the transcript: the text, how many places and which one, the previous and next place, the speaker
/// it is limited to, and Done. Return goes to the next place, Escape closes it; ⌘G and ⇧⌘G work from anywhere in the window.
struct TranscriptFindBar: View {
    @Bindable var model: MeetingsModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(String(localized: "Find in Meeting", comment: "Edit menu (⌘F) and placeholder of its field: finds a text in the transcript of the meeting shown"), text: $model.findText)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { model.findNext() }
                .frame(minWidth: 160, maxWidth: 320)
            if let count = model.findCount {
                Text(count).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityAddTraits(.updatesFrequently)
            }
            ControlGroup {
                Button { model.findNext(forward: false) } label: { Image(systemName: "chevron.up") }
                    .help(Text("Find Previous", comment: "Find in Meeting: goes to the previous place (⇧⌘G)"))
                    .accessibilityLabel(Text("Find Previous"))
                Button { model.findNext() } label: { Image(systemName: "chevron.down") }
                    .help(Text("Find Next", comment: "Find in Meeting: goes to the next place (⌘G)"))
                    .accessibilityLabel(Text("Find Next"))
            }
            .fixedSize()
            .disabled(model.findMatches.isEmpty)
            if !model.roster.entries.isEmpty { speakerMenu }
            Spacer(minLength: 0)
            // Escape closes it from the bar only (a cancel shortcut would take Escape from the whole window).
            Button(String(localized: "find.done", defaultValue: "Done",
                          comment: "Find in Meeting: the button that closes its bar, as in other apps' Find bars (not the state of a task)")) { model.closeFind() }
        }
        .controlSize(.small)
        .padding(.horizontal, PaneLayout.pane)
        .padding(.vertical, 8)
        .onAppear { focused = true }
        .onChange(of: model.findFocusRequest) { focused = true }
        .onKeyPress(.escape) {
            model.closeFind()
            return .handled
        }
        .accessibilityElement(children: .contain)
    }

    /// Everyone, or one speaker of the meeting.
    private var speakerMenu: some View {
        let chosen = model.roster.entries.first { $0.id == model.findSpeaker }
        return Menu {
            Picker(selection: $model.findSpeaker) {
                Text("Everyone").tag(Int64?.none)
                ForEach(model.roster.entries) { entry in Text(verbatim: entry.displayName).tag(Int64?.some(entry.id)) }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } label: {
            Text(verbatim: chosen?.displayName ?? String(localized: "Everyone"))
        }
        .fixedSize()
        .help(Text("Find only in what one speaker said", comment: "Find in Meeting: help on the menu that limits the places to one speaker"))
    }
}
