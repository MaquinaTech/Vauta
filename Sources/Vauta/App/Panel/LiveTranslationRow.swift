// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// The Live Translation switch in the menu-bar panel, with the language and pause.
struct LiveTranslationRow: View {
    let model: RecorderModel

    var body: some View {
        let live = model.liveTranslation
        VStack(alignment: .leading, spacing: 8) {
            // Like every macOS settings row: the name leads, the switch trails.
            HStack(spacing: 8) {
                // The feature's name, with its capitals as in Settings and the shortcut list ("Live notes" is a section, not a feature).
                Label("Live Translation", systemImage: "character.bubble")
                    .panelCardTitle()
                    .lineLimit(1)
                    .layoutPriority(1)
                    // The switch beside it carries the name for VoiceOver.
                    .accessibilityHidden(true)
                Spacer(minLength: 4)
                if model.translationHotKeyAvailable {
                    Text(verbatim: model.translationHotKeyText).font(.caption).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Toggle(isOn: Binding(get: { live.isEnabled }, set: { live.setEnabled($0) })) {
                    Text("Live Translation")
                }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                // Nothing can be recorded or translated while the data is closed.
                .disabled(model.panelDataUnavailable)
                // The shortcut text beside it is hidden from VoiceOver, so the switch says it.
                .accessibilityHint(model.translationHotKeyAvailable ? Text("Shortcut: \(model.translationHotKeyText)") : Text(verbatim: ""))
            }
            // Greyed like the footer buttons beside it (a disabled switch alone is easy to miss).
            .opacity(model.panelDataUnavailable ? 0.5 : 1)
            .help(PanelUnavailable.reason(for: model).map { Text(verbatim: $0) }
                  ?? (model.translationHotKeyAvailable ? Text("Show what the others say, translated, in a floating panel. Also \(model.translationHotKeyText) in any app.")
                                                   : Text("Show what the others say, translated, in a floating panel")))
            if !model.translationHotKeyAvailable {
                HotKeyConflictHint(text: model.translationHotKeyText, alignment: .leading) { model.showSettings(.general) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, PanelMetrics.titleTextIndent)
            }
            if live.isEnabled {
                options(live)
            }
        }
        .panelCard()
        // While no meeting runs, the languages are read for the language the next one will use.
        .task(id: nextSource?.minimalIdentifier) {
            guard live.isEnabled, !model.isRecording, let source = nextSource else { return }
            await live.refreshTargets(source: source)
        }
    }

    private var nextSource: Locale.Language? { model.nextRecordingLanguage?.locale.language }

    /// Pausing only means something while captions run (or are about to). Before a language is downloaded, while it
    /// downloads, when it is unavailable or after a failure there is nothing to pause, and once paused the status line's
    /// "Resume" is the one way back, so the glyph is not a second control for the same thing.
    private func offersPause(_ live: LiveTranslationModel) -> Bool {
        if live.isPaused { return live.snapshot.status != .paused }
        return live.snapshot.status == .starting || live.snapshot.status == .listening
    }

    /// The language to translate into (also before the meeting starts), pause while it runs, and the
    /// caption options that otherwise only live in the hover bar of the captions panel.
    @ViewBuilder private func options(_ live: LiveTranslationModel) -> some View {
        @Bindable var preferences = live.preferences
        let target = model.translationTargetName
        let showsPause = model.isRecording && offersPause(live)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Translate into")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // The menu next to it has this name and the value.
                    .accessibilityHidden(true)
                Menu {
                    TranslationTargetPicker(model: live)
                } label: {
                    // The same chip as the menus in the footer.
                    Chip(text: target?.standaloneCapitalized ?? String(localized: "Choose Language", comment: "Menu title: no language to translate into yet"),
                         systemImage: nil, showsChevron: true, tint: target == nil ? .accentColor : nil)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize(horizontal: false, vertical: true)
                .disabled(model.panelDataUnavailable)
                .help(Text(verbatim: live.pairName(source: nextSource) ?? ""))
                .accessibilityLabel(Text("Translate into"))
                .accessibilityValue(Text(verbatim: live.pairName(source: nextSource) ?? target ?? ""))
                Spacer(minLength: 4)
                // The same order as the captions bar: text size, then pause.
                HStack(spacing: 4) {
                    GlyphMenuButton(symbol: "textformat.size", alignment: showsPause ? .center : .trailing) {
                        CaptionTextSize.allCases.map { size in
                            .item(size.title, checked: preferences.captionTextSize == size) { preferences.captionTextSize = size }
                        } + [.separator,
                             .item(String(localized: "Show Original Words"), checked: preferences.captionShowOriginal) {
                                 preferences.captionShowOriginal.toggle()
                             }]
                    }
                    .help(Text("Change the caption size and options"))
                    .accessibilityLabel(Text("Caption Options"))
                    if showsPause {
                        // An icon with a tooltip, like the captions panel's bar: no label to wrap in a long language.
                        let paused = live.showsPaused
                        Button { live.setPaused(!paused) } label: {
                            Image(systemName: paused ? "play.fill" : "pause.fill")
                                .font(.callout.weight(.medium))
                                .imageScale(.medium)
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22, alignment: .trailing)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(paused ? Text("Resume the translation") : Text("Pause the translation"))
                        .accessibilityLabel(paused ? Text("Resume Translation") : Text("Pause Translation"))
                    }
                }
                // The last glyph (pause while recording, otherwise the size menu) is aligned to the trailing side of its
                // frame, so it ends where the switch above ends.
            }
            .font(.callout)
            // The two hints share one form (plain secondary text on the title's edge); the accent chip above already
            // draws the eye to a missing language.
            if target == nil {
                Text(paragraph: String(localized: "Captions start once you choose a language.")).font(.caption).foregroundStyle(.secondary)
            } else if let status = StatusLine(live) {
                // What the captions panel says when it has nothing to show, here too: the panel never takes the keyboard.
                status.view(live)
            } else if !model.isRecording {
                Text(paragraph: String(localized: "Captions start with your next recording.")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, PanelMetrics.titleTextIndent)
    }
}

/// The state of the captions that the floating panel shows as a message, mirrored under the language menu so the
/// keyboard and VoiceOver reach its buttons. Here the languages are already named by the card (the chip above and the
/// tooltip), so the line is short and fits beside its button; the pair is in the tooltip and VoiceOver.
@MainActor private enum StatusLine {
    case needsDownload, downloadFailed, downloading, unsupported, stopped, paused

    init?(_ live: LiveTranslationModel) {
        switch live.snapshot.status {
        case .needsDownload: self = live.downloadFailed ? .downloadFailed : .needsDownload
        case .downloading: self = .downloading
        case .unsupported: self = .unsupported
        case .failed: self = .stopped
        case .paused: self = .paused
        case .starting, .listening, .sameLanguage: return nil
        }
    }

    @ViewBuilder func view(_ live: LiveTranslationModel) -> some View {
        let pair = live.snapshot.pair
        let name = pair?.labelName ?? ""
        switch self {
        case .needsDownload:
            StatusLineRow(symbol: "arrow.down.circle.fill", color: .accentColor, title: String(localized: "Needs a download", comment: "Menu-bar panel, Live Translation: the language pair needs a one-time download"),
                          full: String(localized: "\(name) needs a download")) {
                Button("Download…") { if let pair { live.download(pair, from: .panel) } }
            }
        case .downloadFailed:
            StatusLineRow(symbol: StatusSymbol.error.name, color: StatusSymbol.error.color,
                          title: String(localized: "Download didn’t finish", comment: "Menu-bar panel, Live Translation: the language download failed"),
                          full: String(localized: "\(name): download didn’t finish")) {
                Button("Try Again…") { if let pair { live.download(pair, from: .panel) } }
            }
        case .downloading:
            StatusLineRow(symbol: "arrow.down.circle.fill", color: .accentColor, title: String(localized: "Downloading…", comment: "Menu-bar panel, Live Translation: a language is downloading"),
                          full: String(localized: "Downloading \(name)…"), showsProgress: true) {
                Button("Cancel") { live.cancelDownload() }
            }
        case .unsupported:
            StatusLineRow(symbol: StatusSymbol.warning.name, color: StatusSymbol.warning.color,
                          title: String(localized: "Not available for these languages", comment: "Menu-bar panel, Live Translation: the pair cannot be translated"),
                          full: String(localized: "\(name) isn’t available")) { EmptyView() }
        case .stopped:
            StatusLineRow(symbol: StatusSymbol.error.name, color: StatusSymbol.error.color, title: String(localized: "Translation stopped"), full: String(localized: "Translation stopped")) {
                Button("Try Again") { live.setPaused(false); live.retry() }
            }
        case .paused:
            StatusLineRow(symbol: "pause.circle", color: .secondary, title: String(localized: "Paused"), full: String(localized: "Paused"), symbolScale: .medium) {
                Button("Resume") { live.setPaused(false) }
            }
        }
    }
}

/// One status of the card: a filled glyph, a short line and its button beside it; when the line does not fit one row
/// in a long language the button goes under it, in the text column. A download in progress shows a bar under it.
private struct StatusLineRow<Action: View>: View {
    let symbol: String
    let color: Color
    let title: String
    /// The sentence with the language pair, for the tooltip and VoiceOver.
    let full: String
    var showsProgress = false
    var symbolScale: Image.Scale = .small
    @ViewBuilder let action: () -> Action

    private static var glyphWidth: CGFloat { 14 }

    private var titleText: Text {
        var text = AttributedString(title)
        text.disableHyphenation(of: title)
        return Text(text).foregroundStyle(.secondary)
    }

    private var glyph: some View {
        Group {
            if showsProgress {
                // No figure is known: a small spinner says that it is running, as in the captions panel.
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: symbol).imageScale(symbolScale).foregroundStyle(color)
            }
        }
        .frame(width: Self.glyphWidth, alignment: .leading).accessibilityHidden(true)
    }

    private var button: some View {
        action().buttonStyle(.bordered).controlSize(.small).foregroundStyle(.primary).fixedSize()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    glyph
                    titleText.lineLimit(1).fixedSize().accessibilityHidden(true)
                    Spacer(minLength: 4)
                    button
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        glyph
                        titleText.fixedSize(horizontal: false, vertical: true).accessibilityHidden(true)
                    }
                    button.padding(.leading, Self.glyphWidth + 6)
                }
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(Text(verbatim: full))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: full))
    }
}
