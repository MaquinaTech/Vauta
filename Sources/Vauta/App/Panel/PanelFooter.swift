// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Audio source and language for the next recording, model server status,
/// and the app's windows.
struct PanelFooter: View {
    @Bindable var model: RecorderModel

    var body: some View {
        VStack(spacing: 8) {
            // The same 12 pt above and below the divider (the panel's rhythm): the stack's 8 pt plus 4.
            Divider().padding(.bottom, 4)
            // These choose the next recording: while one is running, its source and
            // language are in the chips above, so the menus step aside.
            if !model.isRecording && model.phase != .stopping {
                // One row when both chips fit; otherwise the language goes under the source, with its whole name,
                // so it is never cut in the middle (the chip shows the language alone when it has one variant).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        AudioSourceMenu(model: model)
                        LanguageMenu(model: model)
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        AudioSourceMenu(model: model)
                        LanguageMenu(model: model)
                    }
                }
            }
            ServerStatusRow(model: model)
            // All four on one line when the labels fit (they do in most languages); otherwise two rows,
            // so no label ever wraps, is cut or turns into a bare icon in one language only.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    askButton
                    meetingsButton
                    hideButton
                    Spacer(minLength: 4)
                    settingsButton
                    quitButton
                }
                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        askButton
                        meetingsButton
                        hideButton
                        Spacer(minLength: 4)
                    }
                    HStack(spacing: 10) {
                        settingsButton
                        Spacer(minLength: 4)
                        quitButton
                    }
                }
            }
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
            .buttonStyle(.borderless)
            .font(.callout)
        }
    }

    private var askButton: some View {
        Button("Ask") { open(.ask) }
            .disabled(model.panelDataUnavailable)
            .unavailableHelp(model)
    }

    private var meetingsButton: some View {
        Button("Meetings") { open(.meetings) }
            .disabled(model.panelDataUnavailable)
            .unavailableHelp(model)
    }

    /// While recording, before sharing the screen in the call (Recording › Hide Vauta Windows the rest of the time).
    @ViewBuilder private var hideButton: some View {
        if model.isRecording, !model.concealer.isOn {
            Button("Hide Windows") { model.hideWindows() }
                .help("Takes Vauta’s windows, the notepad and the captions off the screen while you share it. The recording goes on.")
        }
    }

    private var settingsButton: some View {
        Button("Settings…") { model.showSettings() }
            .keyboardShortcut(",")
    }

    private var quitButton: some View {
        Button("Quit Vauta") { model.quit() }
            .keyboardShortcut("q")
            .disabled(model.phase == .stopping || model.isReplacingData)
            .help(model.isErasing ? Text("Vauta can quit when the erase finishes")
                  : model.isRestoring ? Text("Vauta can quit when the restore finishes")
                  : model.phase == .stopping ? Text("Vauta can quit when the transcript is saved")
                  : model.isRecording ? Text("Stop the recording, save the meeting and quit Vauta") : Text("Quit Vauta. Meetings can’t be recorded and the shortcuts stop working until you open it again."))
    }

    private func open(_ mode: MeetingsModel.Mode) {
        Task {
            guard await model.authorizeHistory() else { return }
            model.history?.mode = mode
            model.showWindow("meetings")
        }
    }
}

/// Which system audio becomes "Others" in the next recording.
struct AudioSourceMenu: View {
    @Bindable var model: RecorderModel

    var body: some View {
        Menu {
            Toggle("Automatic (App in the Call)", isOn: Binding(
                get: { model.audioSource == .auto },
                set: { if $0 { model.audioSource = .auto } }))
            Section("Meeting Apps") {
                ForEach(MeetingAppFamily.allCases) { family in
                    Toggle(isOn: Binding(get: { model.audioSource.includes(family) },
                                         set: { _ in model.audioSource = model.audioSource.toggling(family) })) {
                        Text(verbatim: family.displayName)
                    }
                }
            }
            Divider()
            Toggle("All System Audio", isOn: Binding(
                get: { model.audioSource == .allSystem },
                set: { model.audioSource = $0 ? .allSystem : .auto }))
            Divider()
            Text("Applies to the next recording. Automatic records all system audio when no meeting app is using the microphone.")
        } label: {
            Chip(text: model.audioSource.summary, systemImage: "speaker.wave.2", showsChevron: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        // Nothing can be recorded while the data is closed, so the choice is grey too, with the reason.
        .disabled(model.panelDataUnavailable)
        .help(PanelUnavailable.reason(for: model).map { Text(verbatim: $0) }
              ?? Text("Audio source for “\(Channel.others.displayName)”: \(model.audioSource.summary)"))
        .accessibilityLabel(Text("Audio source"))
        .accessibilityValue(Text(verbatim: model.audioSource.summary))
    }
}

/// The transcription language of the next recording.
struct LanguageMenu: View {
    let model: RecorderModel

    var body: some View {
        Menu {
            Toggle(isOn: Binding(get: { model.preferences.transcriptionLanguage == nil },
                                 set: { if $0 { model.preferences.transcriptionLanguage = nil } })) {
                if let automatic = model.speechCatalog?.defaultLanguage() {
                    Text("Automatic – \(automatic.displayName.standaloneCapitalized)", comment: "Language picker: the default, followed by the language it uses; the argument is a language name")
                } else {
                    Text("Automatic")
                }
            }
            if let catalog = model.speechCatalog {
                let installed = catalog.languages.filter(\.isInstalled)
                if !installed.isEmpty {
                    Section("Installed") {
                        ForEach(sorted(installed)) { item($0) }
                    }
                }
                let others = catalog.languages.filter { !$0.isInstalled }
                if !others.isEmpty {
                    Menu("More Languages") {
                        ForEach(sorted(others)) { item($0) }
                    }
                }
            }
            Divider()
            Text("Applies to the next recording. A language that isn’t installed downloads once from Apple.")
        } label: {
            Chip(text: languageName, systemImage: "globe", showsChevron: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(model.panelDataUnavailable)
        .help(PanelUnavailable.reason(for: model).map { Text(verbatim: $0) } ?? Text("Transcription language: \(fullName)"))
        .accessibilityLabel(Text("Transcription language"))
        .accessibilityValue(Text(verbatim: fullName))
    }

    /// The whole name, for the tooltip and VoiceOver, starting with a capital in every language.
    private var fullName: String {
        model.nextRecordingLanguage?.displayName.standaloneCapitalized
            ?? String(localized: "Automatic", comment: "Transcription language: chosen automatically")
    }

    /// The name in the chip (see `RecorderModel.shortLanguageName`); the same words as the recording status line.
    private var languageName: String {
        guard let language = model.nextRecordingLanguage else { return fullName }
        return model.shortLanguageName(language)
    }

    private func item(_ language: SpeechLanguage) -> some View {
        Toggle(isOn: Binding(get: { model.preferences.transcriptionLanguage == language.id },
                             set: { if $0 { model.preferences.transcriptionLanguage = language.id } })) {
            Text(verbatim: language.displayName.standaloneCapitalized)
        }
    }

    private func sorted(_ languages: [SpeechLanguage]) -> [SpeechLanguage] {
        languages.sorted { LanguageNameSort.precedes($0.displayName, $1.displayName) }
    }
}

/// The state of the model that writes minutes, in words (never by color alone),
/// with a button that goes to the fix when the model can't be used.
struct ServerStatusRow: View {
    let model: RecorderModel
    @Environment(\.panelClock) private var clock

    var body: some View {
        // A job in progress shows a stopwatch, so it ticks every second; otherwise nothing changes with time.
        TimelineView(.periodic(from: .now, by: model.llmStatus.activity != nil ? 1 : 30)) { _ in
            let line = text(at: clock ?? AppClock.now)
            // Name, quality badge and button share one line when they fit (the badge after the name, like Settings, the
            // button at the trailing edge); then the badge goes under the name with the button still trailing; on a
            // longer line the button goes under the text, in the text column, at a readable size.
            // When the action only goes to a pane, the line itself is the control (icon, text, chevron): no button to wrap.
            if action != nil && !opensGuide {
                linkRow(line: line, details: details(at: clock ?? AppClock.now))
            } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    icon.accessibilityHidden(true)
                    Text(verbatim: line).lineLimit(1).fixedSize()
                    if showsQualityBadge { qualityBadge }
                    Spacer(minLength: 2)
                    actionButton
                }
                HStack(alignment: .center, spacing: 6) {
                    icon.accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: line).lineLimit(1).fixedSize()
                        if showsQualityBadge { qualityBadge }
                    }
                    Spacer(minLength: 6)
                    actionButton
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    icon.accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: line)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if showsQualityBadge { qualityBadge }
                        // Wrapped, the button keeps the right edge it has beside the text in the other states.
                        actionButton.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(Text(verbatim: details(at: clock ?? AppClock.now) ?? ""))
            .accessibilityElement(children: .contain)
            .accessibilityHint(Text(verbatim: details(at: clock ?? AppClock.now) ?? ""))
            }
        }
    }

    /// The status as one borderless button to the Models pane: the warning, the text (up to two lines, whatever the
    /// language) and a chevron that says it leads somewhere.
    private func linkRow(line: String, details: String?) -> some View {
        Button { model.showSettings(.models) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                icon.accessibilityHidden(true)
                Text(verbatim: line)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).accessibilityHidden(true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: details ?? ""))
        .accessibilityLabel(Text(verbatim: SettingsModel.Pane.models.openTitle))
        .accessibilityValue(Text(verbatim: line))
        .accessibilityHint(Text(verbatim: details ?? ""))
    }

    /// The same badge as Settings and setup (one rendering everywhere), one size smaller to fit the status line.
    private var qualityBadge: some View {
        BadgeCapsule(ModelQuality.shortBadge, size: .compact)
    }

    @ViewBuilder private var actionButton: some View {
        if let action {
            Button { opensGuide ? model.showModelGuide() : model.showSettings(.models) } label: { action }
                // A small bordered button, like the actions of the banners above and of Status and Settings.
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var onDevice: Bool { model.llmStatus.chatProvider == .onDevice }

    /// The live notes just got no answer from a server that otherwise looks ready: the status says so, like the notice above it.
    private var serverDidNotAnswer: Bool {
        let s = model.llmStatus
        return model.liveNotesError?.serverDidNotAnswer == true && !onDevice && s.configured && s.issue == nil && s.reachable != false
    }

    /// "Set Up…" opens the model server guide, like everywhere else; "Show Models Pane" (no ellipsis) only goes to the pane.
    private var opensGuide: Bool {
        let s = model.llmStatus
        if !s.configured, s.issue == nil || s.issue == .serverNotConfigured { return true }
        if !s.configured || s.reachable == false || s.issue != nil { return false }
        return onDevice
    }

    /// The quality badge follows the provider's name only while the on-device model is simply ready.
    private var showsQualityBadge: Bool {
        let s = model.llmStatus
        return onDevice && s.configured && s.issue == nil && s.activity == nil && s.queued == 0
    }

    private var action: Text? {
        let s = model.llmStatus
        if opensGuide { return Text("Set Up…") }
        if !s.configured || s.reachable == false || s.issue != nil { return Text(verbatim: SettingsModel.Pane.models.openTitle) }
        return nil
    }

    private func text(at now: Date) -> String {
        let s = model.llmStatus
        if !s.configured {
            if let issue = s.issue, issue != .serverNotConfigured { return issue.localizedDescription }
            return String(localized: "No model chosen", comment: "Panel model status")
        }
        if s.activity != nil { return MinutesActivity.text(s, now: now) }
        if s.queued > 0 {
            return onDevice
                ? String(localized: "\(s.queued) jobs waiting for the model", comment: "Panel model status; the argument is a count")
                : String(localized: "\(s.queued) jobs waiting for the model server", comment: "Panel model status; the argument is a count")
        }
        // A state, like the server rows below it; the name (Apple Intelligence on this Mac) is in the tooltip and in Settings.
        if onDevice { return String(localized: "Ready on this Mac", comment: "Apple Intelligence availability") }
        if serverDidNotAnswer {
            return String(localized: "Model server didn’t answer", comment: "Captions panel and Settings: the model server did not answer in time, so Apple's translation is shown")
        }
        return s.reachable == false
            ? String(localized: "Can’t reach the model server", comment: "Panel model status")
            : String(localized: "Model server ready", comment: "Panel model status")
    }

    static var onDeviceName: String {
        String(localized: "Apple Intelligence on this Mac", comment: "Panel model status: Apple's on-device model is ready; the quality badge follows it")
    }

    /// The full explanation (tooltip and VoiceOver): the problem and what to do.
    /// nil when it would only repeat the visible text.
    private func details(at now: Date) -> String? {
        let s = model.llmStatus
        var parts: [String] = []
        if let issue = s.issue {
            // "No model chosen" is already the visible text: the tooltip adds only what to do.
            parts += [issue == .serverNotConfigured ? nil : issue.localizedDescription, issue.recoverySuggestion].compactMap { $0 }
        } else if s.reachable == false, let error = s.lastError {
            parts.append(error)
        }
        if let issue = s.searchIssue {
            parts.append(String(localized: "Search by meaning: \(issue.localizedDescription)",
                                comment: "Panel model status detail; the argument says why search by meaning is unavailable"))
            if let suggestion = issue.recoverySuggestion { parts.append(suggestion) }
        }
        if onDevice, s.configured {
            parts.append(String(localized: "\(ModelQuality.badge). \(ModelQuality.recommendation) See Settings\u{00A0}→\u{00A0}Models.",
                                comment: "Panel model status detail; the arguments are the badge and the recommendation"))
        }
        guard !parts.isEmpty else { return nil }
        // The visible text is the short name; the whole one opens the tooltip, on its own line.
        let name = onDevice && s.configured ? Self.onDeviceName + "\n" : ""
        return name + parts.joined(separator: " ")
    }

    /// One column for all three states: the spinner, the check and the warning share a width, so the text starts at one place.
    private var icon: some View {
        statusIcon.frame(width: 16, height: 16, alignment: .leading)
    }

    @ViewBuilder private var statusIcon: some View {
        let s = model.llmStatus
        if !s.configured || s.reachable == false || serverDidNotAnswer {
            StatusSymbol.warning.image
        } else if s.activity != nil, let fraction = MinutesActivity.fraction(s) {
            // A small determinate ring that fills as the model reads (the text says the percentage): active work, not a static glyph.
            ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.small)
        } else if s.activity != nil {
            // Working: Vauta's small sphere turning reads as busy, where an empty circle read as off.
            ThinkingOrb()
        } else {
            StatusSymbol.ok.image
        }
    }
}

extension RecorderModel {
    /// The data is closed or being replaced: what needs it (recording choices, Ask, Meetings, Live Translation) is grey.
    var panelDataUnavailable: Bool { !storeAvailable || isReplacingData }

    /// A language's name for a chip, before and during a recording alike. A language with a single variant is shown
    /// without its region ("Englisch" where only en-US exists), because the region would be the part to give way;
    /// with several variants the region is what tells them apart, so the whole name stays.
    /// `inSentence` keeps the language's own capitalization (lowercase in Spanish or French: "el modelo de francés").
    func shortLanguageName(_ language: SpeechLanguage, inSentence: Bool = false) -> String {
        func styled(_ name: String) -> String { inSentence ? name : name.standaloneCapitalized }
        let full = styled(language.displayName)
        guard language.locale.region != nil,
              let code = language.locale.language.languageCode,
              let catalog = speechCatalog,
              catalog.languages.filter({ $0.locale.language.languageCode == code }).count == 1,
              let name = Locale.current.localizedString(forLanguageCode: code.identifier) else { return full }
        return styled(name)
    }

    /// Settings → Models with the guide for a model server already open, like every other "Set Up…".
    func showModelGuide() {
        settingsModel?.pane = .models
        settingsModel?.models.guidePresented = true
        showWindow("settings")
    }
}

/// Why a control of the panel is grey while the encrypted store is closed.
enum PanelUnavailable {
    /// The reason a footer button is grey, nil when it is available: the data being replaced comes first (the store
    /// is closed during it), then a store that did not open.
    @MainActor static func reason(for model: RecorderModel) -> String? {
        if model.isErasing { return String(localized: "Vauta is erasing your data.", comment: "Tooltip of a grey panel button while Erase Everything runs") }
        if model.isRestoring { return String(localized: "Vauta is restoring your meetings.", comment: "Tooltip of a grey panel button while a backup is restored") }
        return model.storeAvailable ? nil : reason
    }

    /// The same words as the disabled controls of Privacy & Security.
    static var reason: String {
        String(localized: "Available once Vauta can open your data. Status shows what went wrong.",
               comment: "Settings → Privacy; the backup and erase controls are disabled because the encrypted store did not open")
    }
}

extension View {
    /// Why a footer button is grey.
    @ViewBuilder func unavailableHelp(_ model: RecorderModel) -> some View {
        if let reason = PanelUnavailable.reason(for: model) {
            help(Text(verbatim: reason)).accessibilityHint(Text(verbatim: reason))
        } else {
            self
        }
    }
}
