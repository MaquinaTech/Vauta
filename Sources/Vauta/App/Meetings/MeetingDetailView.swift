// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Spacing shared by the detail panes of the Meetings window (4/8 grid).
enum PaneLayout {
    /// Inset of a detail pane.
    static let pane: CGFloat = 20
    /// Between the sections of a pane.
    static let section: CGFloat = 16
    /// Between items inside a section.
    static let item: CGFloat = 8
}

/// One meeting: Notes, Minutes, Tasks, Transcript and To Review tabs.
struct MeetingDetailView: View {
    @Bindable var model: MeetingsModel
    let recorder: RecorderModel
    let meeting: MeetingStore.Meeting

    var body: some View {
        // A segmented picker over the content (a TabView also draws a box whose border ends in a stray tick at the picker's corner).
        VStack(spacing: 0) {
            Picker("View", selection: $model.tab) {
                Text(String(localized: "meeting.tab.notes", defaultValue: "Notes", comment: "Tab of a meeting with the notes the user typed, each with what the model wrote from the transcript. It comes first")).tag(MeetingsModel.DetailTab.notes)
                Text(String(localized: "meeting.tab.minutes", defaultValue: "Minutes", comment: "Tab of a meeting with its minutes: summary, topics, decisions and open questions. Same word as the minutes everywhere else (es acta, fr compte rendu, de Protokoll)")).tag(MeetingsModel.DetailTab.summary)
                (model.openTaskCount == 0 ? Text("Tasks") : Text("Tasks (\(model.openTaskCount))")).tag(MeetingsModel.DetailTab.tasks)
                Text("Transcript").tag(MeetingsModel.DetailTab.transcript)
                (model.suggestions.isEmpty ? Text("To Review") : Text("To Review (\(model.suggestions.count))"))
                    .tag(MeetingsModel.DetailTab.suggestions)
                // Only a meeting recorded with a brief has the tab (it shows what the person walked in with).
                if model.storedBrief != nil {
                    Text("Brief", comment: "Tab of a meeting with the brief it was recorded with: what Vauta showed before the meeting started").tag(MeetingsModel.DetailTab.brief)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            // The same size as the sidebar's mode switch, so both segmented controls match.
            .controlSize(.small)
            .fixedSize()
            .padding(.vertical, 10)
            Divider()
            switch model.tab {
            case .notes: NotesTab(model: model, recorder: recorder, meeting: meeting)
            case .summary: SummaryTab(model: model, recorder: recorder, meeting: meeting)
            case .tasks: MeetingTasksTab(model: model, recorder: recorder)
            case .transcript: TranscriptTab(model: model, meeting: meeting)
            case .suggestions: SuggestionsTab(model: model)
            case .brief:
                if let stored = model.storedBrief {
                    StoredBriefView(references: stored.references, createdAt: stored.createdAt) { model.open($0) }
                } else {
                    SummaryTab(model: model, recorder: recorder, meeting: meeting)
                }
            }
        }
        // Vauta's colours glow faintly behind the top of the meeting, as in the menu-bar panel.
        .background(alignment: .top) { PanelGlow(isRecording: false).frame(height: 280).opacity(0.7) }
    }
}

/// Text that can be selected and copied only when copy protection is off.
struct ProtectedText: View {
    let text: Text
    @Environment(\.copyProtection) private var copyProtection

    init(_ string: String) { text = Text(string) }
    init(_ text: Text) { self.text = text }

    var body: some View {
        if copyProtection {
            text
        } else {
            text.textSelection(.enabled)
        }
    }
}

/// A small icon-only button with a label for VoiceOver and a tooltip.
struct IconButton: View {
    let label: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(Text(label))
    }
}

/// A titled block of the Summary tab and the cards.
struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            content
        }
    }
}

/// A link-style button with a moment of the meeting ("12:34").
struct TimeButton: View {
    let t: Double
    /// With no transcript to go to, the time is plain text.
    var plain = false
    /// The line at that moment, previewed without leaving the tab (`passagePreview`); nil: a plain link.
    var passage: PreviewedPassage?
    let action: () -> Void

    var body: some View {
        if plain {
            Text(ElapsedTime.stamp(t)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        } else {
            Button(ElapsedTime.stamp(t), action: action)
                .buttonStyle(.link)
                .font(.callout.monospacedDigit())
                .accessibilityLabel(Text("Go to \(ElapsedTime.stamp(t)) in Transcript"))
                .passagePreview(ElapsedTime.stamp(t), passage: passage, open: action)
        }
    }
}
