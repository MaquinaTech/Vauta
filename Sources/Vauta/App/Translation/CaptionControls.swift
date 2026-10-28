// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// The small bar that appears when the pointer is over the panel.
struct CaptionControls: View {
    let model: LiveTranslationModel
    /// The panel is wide enough to say in words how the server is doing.
    var showsStatusText = false

    var body: some View {
        @Bindable var preferences = model.preferences
        HStack(spacing: 2) {
            RefinementIndicator(status: model.refinementStatus, showsText: showsStatusText)
            languageMenu
            Divider().frame(height: 16).padding(.horizontal, 4)
            GlyphMenuButton(symbol: "textformat.size", font: .system(size: 12, weight: .semibold), size: 24) {
                CaptionTextSize.allCases.map { size in
                    .item(size.title, checked: preferences.captionTextSize == size) { preferences.captionTextSize = size }
                }
            }
            .help(Text("Change the text size"))
            .accessibilityLabel(Text("Text Size"))

            iconButton("character.textbox",
                       label: Text("Show Original Words"),
                       help: preferences.captionShowOriginal ? Text("Hide the original words") : Text("Show the original words"),
                       selected: preferences.captionShowOriginal) {
                preferences.captionShowOriginal.toggle()
            }
            iconButton(isPaused ? "play.fill" : "pause.fill",
                       label: isPaused ? Text("Resume Translation") : Text("Pause Translation"),
                       help: isPaused ? Text("Resume the translation") : Text("Pause the translation")) {
                model.setPaused(!isPaused)
            }
            iconButton("xmark", label: Text("Turn Off Live Translation"),
                       help: Text("Turn off Live Translation (\(model.hotKeyText))")) { model.setEnabled(false) }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        // Opaque: the captions underneath must not show through the controls. The 1 pt rim is a shape behind the
        // fill (a stroke drawn over the menus left stray ticks at both ends).
        .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
        .background(Capsule().fill(Color.primary.opacity(0.14)).padding(-1))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }

    /// Paused by the user, or showing the paused state.
    private var isPaused: Bool { model.showsPaused }

    private var pairName: String { model.snapshot.pair?.labelName ?? "" }

    private var languageMenu: some View {
        Menu {
            TranslationTargetPicker(model: model)
        } label: {
            // The chevron is part of the text (a menu label turns separate views into an icon before the title), a clear gap
            // after the name like the chips of the panel; the menu's own sat against the last letter.
            (Text(verbatim: model.pairName() ?? String(localized: "Language", comment: "Captions panel: language menu title"))
                + Text(verbatim: "\u{2004}")
                + Text(Image(systemName: "chevron.down")).font(.system(size: 8, weight: .semibold)).foregroundColor(.secondary))
                .padding(.horizontal, 4)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(Text("Choose the language to translate into"))
        .accessibilityLabel(Text("Translate into"))
        .accessibilityValue(Text(verbatim: pairName))
    }

    private func iconButton(_ symbol: String, label: Text, help: Text? = nil, selected: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .symbolVariant(selected ? .fill : .none)
                .imageScale(.medium)
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 24)
                .background(selected ? Color.accentColor.opacity(0.22) : .clear, in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// How the model server's refinement is going, in the hover bar: a symbol (and, when there is room, words).
/// Silent otherwise: nothing here is an alert, and Apple's caption always stays when the server can't help.
struct RefinementIndicator: View {
    let status: RefinementStatus
    let showsText: Bool

    /// What the indicator says for a status; nil when it has nothing to say.
    struct Content {
        let symbol: String
        /// A few words, for the bar and Settings.
        let text: String
        /// The full explanation, for the tooltip and VoiceOver.
        let help: String

        init?(_ status: RefinementStatus) {
            switch status {
            case .improved:
                symbol = "sparkles"
                text = String(localized: "Improved by your model server", comment: "Captions panel: the model server improved the latest translation")
                help = String(localized: "Your model server improved the latest sentence. Its version is the one saved.",
                              comment: "Captions panel tooltip and VoiceOver: the model server improved the latest translation")
            case .unavailable:
                // Calm and secondary: the server was not reached (a minus circle reads as "removed" on macOS).
                symbol = "exclamationmark.circle"
                text = String(localized: "Model server didn’t answer", comment: "Captions panel and Settings: the model server did not answer in time, so Apple's translation is shown")
                help = String(localized: "Your model server didn’t answer in time, so Apple’s translation stays.",
                              comment: "Captions panel tooltip and VoiceOver: the model server did not answer in time")
            case .off, .active:
                return nil
            }
        }
    }

    private var content: Content? { Content(status) }

    var body: some View {
        if let content {
            HStack(spacing: 4) {
                Image(systemName: content.symbol).foregroundStyle(.secondary).frame(width: 24, height: 24)
                if showsText {
                    Text(content.text).foregroundStyle(.secondary).lineLimit(1).padding(.trailing, 2)
                }
            }
            .help(Text(content.help))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(content.help))
            Divider().frame(height: 16).padding(.horizontal, 4)
        }
    }
}
