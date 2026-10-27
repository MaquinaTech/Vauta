// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// Settings → Translation: Live Translation of the other participants.
struct TranslationPane: View {
    @Bindable var recorder: RecorderModel
    @Bindable var preferences: Preferences
    let speech: SpeechSettingsModel
    /// Opens the guided model setup (Settings → Models).
    let setUpModelServer: () -> Void
    /// Goes to Settings → Models.
    let showModels: () -> Void
    /// Goes to Settings → Recording, where the language being translated from is chosen.
    var showRecording: () -> Void = {}

    @ViewLocalState private var choosingLanguage = false

    private var live: LiveTranslationModel { recorder.liveTranslation }

    private var voiceOverOn: Bool {
        #if VAUTA_DIAGNOSTICS
        if let sample = SnapshotMode.voiceOver { return sample }
        #endif
        return NSWorkspace.shared.isVoiceOverEnabled
    }

    /// The language the next meeting is transcribed in (the one being spoken now while recording).
    private var source: Locale.Language? {
        live.sourceLanguage ?? speech.effectiveLanguage(preferences.transcriptionLanguage)?.locale.language
    }

    var body: some View {
        Form {
            // One card under the pane's first header, like every other pane (the switch, then the captions' settings).
            Section {
                Toggle(isOn: Binding(get: { live.isEnabled }, set: { live.setEnabled($0) })) {
                    Text("Live Translation", comment: "Settings → Translation; the switch, named as in the menu bar panel and the shortcut row of General")
                    Text(description: String(localized: "While you record, a floating panel shows what the other participants say, translated into your language. Turn it on or off with \(recorder.translationHotKeyText) in any app.",
                         comment: "Settings → Translation; the argument is a keyboard shortcut"))
                }
                Picker(String(localized: "Translate into", comment: "Settings → Translation"), selection: Binding(
                    get: { preferences.translationTarget ?? "" }, set: { preferences.translationTarget = $0.isEmpty ? nil : $0 })) {
                    Text(automaticLabel).tag("")
                    Divider()
                    ForEach(live.targets) { target in Text(target.name.standaloneCapitalized).tag(target.id) }
                }
                Picker(String(localized: "Text size", comment: "Settings → Translation"), selection: $preferences.captionTextSize) {
                    ForEach(CaptionTextSize.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show the original words under each caption", isOn: $preferences.captionShowOriginal)
                if voiceOverOn {
                    Toggle("Read captions aloud with VoiceOver", isOn: $preferences.readCaptionsWithVoiceOver)
                }
            } header: {
                Text("Captions")
            }

            Section {
                if let source {
                    LabeledContent {
                        HStack(spacing: 12) {
                            Text(TranslationPair.name(of: source).standaloneCapitalized)
                            Button(SettingsModel.Pane.recording.openTitle, action: showRecording)
                        }
                    } label: {
                        Text("Translating from", comment: "Settings → Translation")
                        Text(description: String(localized: "Captions are translated from the transcription language, set in Recording.",
                             comment: "Settings → Translation; the row beside it shows the language being translated from and a button to the Recording pane, where it is set"))
                    }
                    if live.targets.isEmpty {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel(Text("Loading languages…", comment: "Accessibility label of the spinner while the languages load"))
                    }
                    // As Recording's speech models: the languages on this Mac (and any download under way or failed),
                    // then one row that adds another, which starts its download.
                    let sorted = live.targets.sorted(by: Self.byName)
                    ForEach(sorted.filter { $0.availability == .installed || live.downloader.running?.target == $0.language || live.failedPair?.target == $0.language }) { target in
                        TranslationLanguageRow(model: live, pair: TranslationPair(source: source, target: target.language),
                                               availability: target.availability)
                    }
                    let toAdd = sorted.filter { target in
                        target.availability != .installed && live.downloader.running?.target != target.language && live.failedPair?.target != target.language
                    }
                    LabeledContent {
                        Button(String(localized: "Add Language…", comment: "Settings → Recording; opens the list of languages whose speech model can be downloaded")) {
                            choosingLanguage = true
                        }
                        .disabled(toAdd.isEmpty || live.downloader.running != nil)
                        .popover(isPresented: $choosingLanguage, arrowEdge: .bottom) {
                            LanguageChoiceList(choices: toAdd.map { .init(id: $0.id, name: $0.name) }) { id in
                                choosingLanguage = false
                                if let target = toAdd.first(where: { $0.id == id }) {
                                    live.download(TranslationPair(source: source, target: target.language), from: .settings)
                                }
                            }
                        }
                    } label: {
                        Text("Another language", comment: "Settings → Recording; title of the row with the menu that adds a speech model")
                        Text(description: String(localized: "Choosing one starts its download.", comment: "Settings → Recording; under the row that adds a speech model"))
                    }
                    // Like every other "Open … Settings" button: inside the row it fixes.
                    LabeledContent {
                        Button("Open Language & Region Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") { NSWorkspace.shared.open(url) }
                        }
                    } label: {
                        Text("Remove a language", comment: "Settings → Translation; title of the row with the button that opens System Settings to remove a language")
                        Text(description: String(localized: "Languages are removed in System Settings.", comment: "Settings → Translation; under the row that opens System Settings to remove a language"))
                    }
                } else {
                    SettingsNote(String(localized: "Choose a transcription language in Settings\u{00A0}→\u{00A0}Recording first.", comment: "Settings → Translation"))
                }
            } header: {
                Text("Languages")
            } footer: {
                SettingsNote(String(localized: "Each language downloads once from Apple. After that, Apple’s translation runs on this Mac.",
                                    comment: "Settings → Translation"))
            }

            TranslationRefinementSection(recorder: recorder, preferences: preferences, live: live, source: source,
                                         setUp: setUpModelServer, showModels: showModels)

            Section {
                Toggle("Show translations in transcripts", isOn: $preferences.showTranslationsInTranscript)
            } header: {
                Text("Transcripts")
            } footer: {
                SettingsNote(String(localized: "Translations of finished sentences are saved with the transcript, encrypted, and deleted with it. The text of the captions is never in notifications or logs.",
                                    comment: "Settings → Translation"))
            }
        }
        .formStyle(.grouped)
        .translationDownloads(live.downloader, host: .settings)
        .task {
            await speech.refresh()
            await live.refreshTargets(source: source)
        }
        .onChange(of: source) { _, new in
            Task { await live.refreshTargets(source: new) }
        }
    }

    /// By name, like the speech models: a download under way or failed keeps its place among the installed ones.
    private static func byName(_ a: TranslationTarget, _ b: TranslationTarget) -> Bool {
        LanguageNameSort.precedes(a.name, b.name)
    }

    private var automaticLabel: String {
        guard let source, let target = live.resolvedTarget(for: source) else {
            return String(localized: "Automatic", comment: "Settings → Translation: use the Mac’s language")
        }
        return String(localized: "Automatic (\(TranslationPair.name(of: target)))",
                      comment: "Settings → Translation: use the Mac’s language; the argument is that language")
    }
}

/// One language: ready, or a button to download it.
private struct TranslationLanguageRow: View {
    let model: LiveTranslationModel
    let pair: TranslationPair
    let availability: PairAvailability

    var body: some View {
        let downloading = model.downloader.running == pair
        let failed = !downloading && availability != .installed && model.failedPair == pair
        LabeledContent {
            Group {
                if downloading {
                    // The Translation framework reports no progress (macOS shows its own): the row can at least be cancelled.
                    HStack(spacing: 8) {
                        // The text says it: the spinner alone would be read as a bare "progress indicator".
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                        Text("Downloading…").foregroundStyle(.secondary)
                        Button("Cancel") { model.cancelDownload() }
                    }
                } else if availability == .installed {
                    ModelStatusLabel(state: .installed)
                } else {
                    Button(String(localized: "Try Again…", comment: "Captions: retry the language download. The ellipsis is on purpose: it asks for Apple’s download confirmation again, unlike the retry of a stopped translation (“Try Again”)")) { model.download(pair, from: .settings) }
                        .disabled(model.downloader.running != nil)
                }
            }
            // The height of a button, so the rows keep one rhythm installed or not.
            .frame(minHeight: 24)
        } label: {
            Text(verbatim: TranslationPair.name(of: pair.target).standaloneCapitalized)
            if failed {
                ModelFailureLabel(text: String(localized: "The download didn’t finish. Check your internet connection and try again.",
                                               comment: "Settings → Translation; under a language whose download failed"))
            }
        }
        .accessibilityElement(children: .combine)
    }
}
