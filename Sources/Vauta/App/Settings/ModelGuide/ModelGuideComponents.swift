// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import SwiftUI

/// Where a step stands: finished, the one to do now, or still to come.
enum GuideStepState {
    case done, current, upcoming

    var accessibilityName: String {
        switch self {
        case .done: String(localized: "done", comment: "VoiceOver: state of a setup step")
        case .current: String(localized: "current step", comment: "VoiceOver: state of a setup step")
        case .upcoming: String(localized: "not started", comment: "VoiceOver: state of a setup step")
        }
    }
}

/// A numbered step with a state badge on the left and its content on the right.
struct GuideStep<Content: View>: View {
    let number: Int
    let title: String
    let state: GuideStepState
    /// A finished step shows its title and this line; a click on the title opens or closes the rest.
    var summary: String?
    var isExpanded = true
    var toggle: (() -> Void)?
    @ViewBuilder var content: Content
    @Environment(\.colorSchemeContrast) private var systemContrast
    private var contrast: ColorSchemeContrast { systemContrast.snapshotResolved }
    @Environment(\.guideStepsLocked) private var locked

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 8) {
                header
                if isExpanded { content }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var header: some View {
        let titleText = Text(title)
            .font(.headline)
            // Primary in every state: the step's state is the number badge, and a dimmed title above full-contrast text
            // would invert the hierarchy.
            .foregroundStyle(.primary)
        if let toggle, state == .done {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    titleText
                    Spacer(minLength: 8)
                    if let summary, !isExpanded {
                        Text(summary).font(.callout).foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .opacity(locked ? 0.5 : 1)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(locked)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(isExpanded ? Text("expanded", comment: "VoiceOver: a finished setup step that shows its content")
                                           : Text("collapsed", comment: "VoiceOver: a finished setup step that shows only its title"))
            .accessibilityHint(Text("Shows or hides the step", comment: "VoiceOver hint of a finished setup step"))
        } else {
            titleText.accessibilityAddTraits(.isHeader)
        }
    }

    private var badge: some View {
        ZStack {
            switch state {
            case .done:
                // A white check on green is under 3:1: a tinted disc with a ring and a check in the text colour.
                Circle().fill(Color.green.opacity(0.2))
                Circle().strokeBorder(Color.green, lineWidth: 1.5)
                Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.primary)
            case .current:
                Circle().fill(Color.accentColor)
                Text(verbatim: "\(number)").font(.callout.bold()).foregroundStyle(.white)
            case .upcoming:
                Circle().strokeBorder(Color.secondary.opacity(contrast == .increased ? 1 : 0.6), lineWidth: 1.5)
                Text(verbatim: "\(number)").font(.callout.bold()).foregroundStyle(.secondary)
            }
        }
        .frame(width: 26, height: 26)
        // The finished steps dim with their titles while the choice is checked and saved.
        .opacity(locked && state == .done ? 0.5 : 1)
        // Centred on the title's first line, not on the top of the step.
        .padding(.top, -5)
        .accessibilityElement()
        .accessibilityLabel(Text("Step \(number), \(state.accessibilityName)", comment: "VoiceOver: setup step number and state"))
    }
}

/// An explanation in the guide: the settings note, but a text of several sentences puts each on its own line when the
/// whole does not fit one, so a line never ends with the first words of the next sentence.
struct GuideNote: View {
    let text: String
    var code: [String] = []

    init(_ text: String, code: [String] = []) {
        self.text = text
        self.code = code
    }

    var body: some View {
        Group {
            if text.sentences.count > 1 || !code.isEmpty {
                SentenceLines(text: text, code: code)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                SettingsNote(text)
            }
        }
    }
}

/// A command in a monospaced box with a Copy button that confirms briefly.
struct CommandBlock: View {
    let command: String
    /// The command the person has to run now: outlined in the warning colour (the accent ring is the focus ring).
    var highlighted = false
    #if VAUTA_DIAGNOSTICS
    /// For `Vauta render-ui`: blocks that start in the "Copied" state.
    static var snapshotCopied = false
    #endif
    @ViewLocalState private var copied = Self.startsCopied
    @ViewLocalState private var copyCount = 0

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Each line of a command stays whole, in any language: in a window too narrow for it, it scrolls.
            ScrollView(.horizontal) {
                Text(verbatim: Self.displayed(command))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.automatic)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(Text("Command", comment: "VoiceOver: a command to copy"))
            .accessibilityValue(Text(verbatim: command))
            Button {
                copy()
            } label: {
                // Icon only, so the command keeps the width in every language. Both icons take part in the layout:
                // the button and the block keep their size when it says "Copied".
                ZStack {
                    Label("Copy", systemImage: "doc.on.doc").opacity(copied ? 0 : 1).accessibilityHidden(copied)
                    Label("Copied", systemImage: "checkmark").opacity(copied ? 1 : 0).accessibilityHidden(!copied)
                }
                .labelStyle(.iconOnly)
            }
            .controlSize(.small)
            .help(copied ? String(localized: "Copied", comment: "Confirmation after copying a command")
                         : String(localized: "Copy the command to the clipboard", comment: "Tooltip of the Copy button next to a command"))
            .accessibilityLabel(Text("Copy Command", comment: "VoiceOver: Copy button next to a command"))
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .cardBackground()
        .overlay {
            if highlighted {
                RoundedRectangle(cornerRadius: CardStyle.radius)
                    .strokeBorder(StatusSymbol.warning.color.opacity(0.7), lineWidth: 1)
            }
        }
    }

    private static var startsCopied: Bool {
        #if VAUTA_DIAGNOSTICS
        snapshotCopied
        #else
        false
        #endif
    }

    /// One command per line: `a && b` wraps after `&&`, never inside a word like `--context-length`.
    static func displayed(_ command: String) -> String {
        command.replacingOccurrences(of: " && ", with: " &&\n")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copied = true
        copyCount += 1
        let count = copyCount
        AccessibilityNotification.Announcement(String(localized: "Copied", comment: "Confirmation after copying a command")).post()
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copyCount == count { copied = false }
        }
    }
}

/// One line of live status: a spinner while waiting, otherwise an icon whose meaning
/// is also in the text, so it never depends on color.
struct GuideStatusRow: View {
    enum Kind { case waiting, info, warning, success, error }

    let kind: Kind
    /// The status strip: the icon is centred in the column of the step badges above (26 pt) and the text starts where
    /// the step titles do (12 pt after it), so the strip lines up with the steps.
    var inStepColumn = false
    let title: String
    var detail: String?
    /// A narrower icon column, so the text starts where a checkbox's label does (the warning under "Use one model only").
    var compactIcon = false

    /// Where the text starts: the icon's width plus the spacing.
    static let textIndent: CGFloat = 26
    /// Where the text starts with the narrower icon column (`compactIcon`).
    static let compactTextIndent: CGFloat = 14 + 7

    var body: some View {
        HStack(alignment: .top, spacing: inStepColumn ? 12 : compactIcon ? 7 : 8) {
            icon.frame(width: inStepColumn ? 26 : compactIcon ? 14 : 18, height: 18)
            // The shared notice rule: a semibold title when a detail follows, regular when it is alone.
            VStack(alignment: .leading, spacing: NoticeMetrics.gap) {
                Text(wrapping: title.avoidingWidow)
                    .fontWeight(detail == nil ? .regular : .semibold)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    // The warning of a step (compact icon) is set like the notes around it, so it does not outweigh the step's text.
                    SentenceLines(text: detail).font(compactIcon ? .subheadline : .callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch kind {
        case .waiting: ProgressView().controlSize(.small)
        case .info: StatusSymbol.info.image
        case .warning: StatusSymbol.warning.image
        case .success: StatusSymbol.ok.image
        case .error: StatusSymbol.error.image
        }
    }
}

private struct GuideStepsLockedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True while the guide checks and saves the choice: finished steps cannot be opened or closed.
    var guideStepsLocked: Bool {
        get { self[GuideStepsLockedKey.self] }
        set { self[GuideStepsLockedKey.self] = newValue }
    }
}
