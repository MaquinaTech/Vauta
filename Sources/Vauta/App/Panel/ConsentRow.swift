// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// The consent helper in the menu-bar panel: a ready-to-paste notice for the
/// meeting chat, in the language of the meeting. Quiet and dismissible; it never
/// blocks recording and Vauta never sends the notice anywhere.
struct ConsentRow: View {
    let model: RecorderModel
    let prompt: ConsentPrompt

    /// A notice of up to `wholeLines` lines is always shown whole. A longer one (the voices sentence) is cut to `clampedLines`
    /// until the person asks for all of it, so a panel shown during a call keeps Live Translation and the note within reach.
    /// The limit is higher than the cut: a notice that is only a line or two over is shorter whole than with the button
    /// that would reveal it, and its last sentence ("tell me if you'd rather I didn't") is the one that matters.
    private static let clampedLines = 4
    private static let wholeLines = 6
    @ViewLocalState private var expanded = false
    @ViewLocalState private var fullHeight: CGFloat = 0
    @ViewLocalState private var wholeHeight: CGFloat = 0
    private var overflows: Bool { fullHeight > wholeHeight + 1 }

    /// The width of the text column under the title: the panel minus its margins, the card padding and the title's indent.
    private static let textWidth = RecorderPanel.width - 32 - 24 - PanelMetrics.titleTextIndent

    var body: some View {
        if let informedAt = prompt.informedAt {
            informed(informedAt)
        } else {
            reminder
        }
    }

    private var reminder: some View {
        VStack(alignment: .leading, spacing: 8) {
            #if VAUTA_DIAGNOSTICS
            Color.clear.frame(height: 0).onAppear { if SnapshotMode.consentExpanded { expanded = true } }
            #endif
            HStack(spacing: 8) {
                Label {
                    Text("Tell the other participants")
                } icon: {
                    Image(systemName: "person.2")
                }
                    .panelCardTitle()
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                IconButton(label: String(localized: "Dismiss", comment: "Button"), systemImage: "xmark") { model.dismissConsentPrompt() }
                    .foregroundStyle(.secondary)
            }
            // The notice itself, in the meeting's language, as the others will read it.
            // Everything under the title starts where the title's text starts, like the other cards.
            noticeView
                .padding(.leading, PanelMetrics.titleTextIndent)
            if overflows {
                // A quiet link, so it is not read as a third action next to "Copy Notice" and "Mark as Informed".
                Button(expanded ? "Show Less" : "Show Full Notice") { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .padding(.leading, PanelMetrics.titleTextIndent)
            }
            // The language of the notice has its own line; the two standard sentences break the same way in every language.
            VStack(alignment: .leading, spacing: 0) {
                if let name = prompt.otherLanguageName {
                    Text("In the language of the meeting (\(name)).",
                         comment: "Consent helper in the panel, when the notice is in another language than the app; the argument is a language name")
                }
                Text(paragraph: String(localized: "Paste it in the meeting chat. Vauta never sends it for you.").breakingBeforeLastSentence(fittingIn: Self.textWidth))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, PanelMetrics.titleTextIndent)
            PanelActionRow {
                Button {
                    model.copyConsentNotice()
                } label: {
                    // Both labels are laid out, so "Copied" never changes the button's width.
                    ZStack {
                        Label("Copy Notice", systemImage: "doc.on.doc")
                            .opacity(prompt.copied ? 0 : 1)
                            .accessibilityHidden(prompt.copied)
                        Label("Copied", systemImage: "checkmark")
                            .opacity(prompt.copied ? 1 : 0)
                            .accessibilityHidden(!prompt.copied)
                    }
                }
                    .prominentButton(!prompt.copied)
                // Copying is the first step; once it is done, telling them is what gets recorded.
                Button("Mark as Informed") { model.markParticipantsInformed() }
                    .prominentButton(prompt.copied)
            }
            .controlSize(.small)
            .padding(.leading, PanelMetrics.titleTextIndent)
        }
        .panelCard()
        .accessibilityElement(children: .contain)
    }

    /// The notice in the meeting's language, as the others will read it, clamped to a few lines until expanded. The system
    /// wraps it; two hidden copies measure it whole and clamped to know whether anything is cut.
    private var noticeView: some View {
        return Text(displayedNotice)
            .accessibilityLabel(Text(noticeText))
            .font(.callout)
            .lineLimit(expanded || !overflows ? nil : Self.clampedLines)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(alignment: .top) {
                Text(displayedNotice).font(.callout).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .hidden().accessibilityHidden(true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
            }
            .background(alignment: .top) {
                Text(displayedNotice).font(.callout).lineLimit(Self.wholeLines).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .hidden().accessibilityHidden(true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { wholeHeight = $0 }
            }
    }

    /// Tagged with its language, so VoiceOver reads a German notice in German.
    private var noticeText: AttributedString {
        // Only what is shown avoids the one-word last line; "Copy Notice" copies `prompt.text` as it is.
        // The system wraps it; the last two words stay together, and no whole sentence is tied into one run (that left half-empty lines).
        // Japanese and Chinese have no spaces: the hard breaks measured for spaced text would cut sentences in the middle and
        // leave half-empty lines, so the system's own line breaking sets them.
        let broken = prompt.text.usesUnspacedScript ? prompt.text : prompt.text.avoidingWidow(pathOnItsOwnLine: false, tyingSentences: false)
        var text = AttributedString(broken)
        text.languageIdentifier = prompt.language
        return text
    }

    /// The same notice for the eyes: no hyphenation ("mei-/nem"), which the language tag would turn on.
    /// VoiceOver still gets `noticeText`, tagged with the language, through the accessibility label.
    private var displayedNotice: AttributedString {
        var text = noticeText
        text.disableHyphenation(of: prompt.text)
        return text
    }

    private func informed(_ date: Date) -> some View {
        let time = date.formatted(date: .omitted, time: .shortened)
        // A one-line card, like the Live Translation header: the same icon column and title indent.
        return HStack(spacing: 8) {
            Label {
                Text("Participants informed at \(time)")
            } icon: {
                StatusSymbol.ok.image
            }
            .panelCardTitle()
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            // A tap by mistake is not a fact about the meeting: the record can be taken back.
            Button("Undo") { model.undoParticipantsInformed() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
        }
        .panelCard()
    }
}
