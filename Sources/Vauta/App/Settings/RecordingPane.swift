// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// Settings → Recording: what is captured, when recording stops, languages
/// and speech models.
struct RecordingPane: View {
    @Bindable var recorder: RecorderModel
    @Bindable var preferences: Preferences
    let speech: SpeechSettingsModel
    /// Goes to Settings → Models.
    var showModels: () -> Void = {}

    /// The minutes of silence the picker offers, plus a saved value that isn't one of them.
    private static func autoStopChoices(including current: Int) -> [Int] {
        Array(Set([2, 5, 10, 15, 30, current])).sorted()
    }

    var body: some View {
        Form {
            AudioSourceSection(recorder: recorder)

            Section {
                Toggle(isOn: $recorder.suggestOnCall) {
                    Text("Suggest recording when a call starts")
                    Text(description: String(localized: "Vauta shows a suggestion when a meeting app starts using the microphone. It never starts recording on its own.",
                         comment: "Settings → Recording"))
                }
                Toggle(isOn: $preferences.stopRecordingOnScreenLock) {
                    Text("Stop recording when the screen locks")
                    Text(description: String(localized: "Also when the Mac sleeps or you switch users. Everything transcribed so far is saved.", comment: "Settings → Recording, description under Stop recording when the screen locks"))
                }
                Picker(selection: $recorder.autoStopMinutes) {
                    ForEach(Self.autoStopChoices(including: recorder.autoStopMinutes), id: \.self) { minutes in
                        Text(Duration.seconds(minutes * 60).formatted(.units(allowed: [.minutes], width: .wide))).tag(minutes)
                    }
                } label: {
                    Text("Stop recording after a silence of", comment: "Settings → Recording; the picker beside it lists how many minutes without meeting audio")
                    Text(description: String(localized: "Before stopping, Vauta warns you in the menu bar and with a notification you can use to keep recording.",
                         comment: "Settings → Recording"))
                }
            } header: {
                Text("Starting and stopping")
            }

            LiveAnswersSection(recorder: recorder, preferences: preferences, showModels: showModels)

            Section {
                Picker(selection: $preferences.consentReminder) {
                    Text("Always").tag(ConsentReminder.always)
                    Text("First time with each meeting app").tag(ConsentReminder.firstPerApp)
                    Text("Never").tag(ConsentReminder.never)
                } label: {
                    Text("Remind me to inform participants")
                    Text(description: String(localized: "When recording starts, the menu-bar panel offers a notice to paste in the meeting chat, in the language of the meeting. Vauta never sends it for you and never blocks recording.",
                         comment: "Settings → Recording, consent helper"))
                }
            } header: {
                Text("Informing participants")
            } footer: {
                SettingsNote(String(localized: "Transcribing on your Mac doesn’t remove your duty to tell people they are being transcribed, and some places require everyone’s consent. This isn’t legal advice.",
                                    comment: "Settings → Recording, consent helper"))
            }

            TranscriptionLanguageSection(preferences: preferences, speech: speech)
            SpeechModelsSection(preferences: preferences, speech: speech)
            VocabularySection(recorder: recorder, preferences: preferences, speech: speech)
        }
        .formStyle(.grouped)
        .task { await speech.refresh() }
    }
}

/// Which system audio becomes "Others".
private struct AudioSourceSection: View {
    @Bindable var recorder: RecorderModel
    /// The apps chosen last, so switching to "Automatic" and back keeps them.
    @ViewLocalState private var lastFamilies: Set<MeetingAppFamily> = [.webkit]

    private enum Kind: Hashable { case auto, apps, all }

    var body: some View {
        Section {
            RadioGroupRow(title: String(localized: "Record “\(Channel.others.displayName)” from", comment: "Settings → Recording; the argument is the name of the other participants' channel"),
                          selection: kind,
                          options: [(Kind.auto, String(localized: "Automatic (the app in the call)")),
                                    (Kind.apps, String(localized: "Only the apps I choose")),
                                    (Kind.all, String(localized: "All system audio"))])

            switch recorder.audioSource {
            case .auto, .allSystem:
                EmptyView()
            case .apps(let families):
                ForEach(MeetingAppFamily.allCases) { family in
                    Toggle(isOn: Binding(get: { families.contains(family) }, set: { toggle(family, $0) })) {
                        HStack(spacing: 8) {
                            FamilyIcon(family: family)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(family.displayName)
                                if family.kind == .browser {
                                    Text(family.apps.prefix(5).map(\.name).joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .disabled(families == [family])
                }
            }
            if let app = recorder.callApp {
                LabeledContent(String(localized: "In a call now", comment: "Settings → Recording"), value: app.displayName)
            }
        } header: {
            Text("Meeting audio")
        } footer: {
            // The explanation of the chosen option sits under the card, like every section's explanation.
            VStack(alignment: .leading, spacing: 6) {
                switch recorder.audioSource {
                case .auto:
                    SettingsNote(String(localized: "When you start recording, Vauta follows the meeting app that is using the microphone. If it doesn’t recognize the app, it records all system audio, so pause music and videos.",
                                        comment: "Settings → Recording audio source"))
                case .allSystem:
                    SettingsNote(String(localized: "Everything your Mac plays, except Vauta’s own sounds. Pause music and videos while you record.",
                                        comment: "Settings → Recording audio source"))
                case .apps:
                    SettingsNote(String(localized: "Web meetings such as Google Meet are recorded through the browser that runs them, including all its tabs.",
                                        comment: "Settings → Recording audio source"))
                }
                if recorder.isRecording || recorder.isBusy {
                    SettingsNote(String(localized: "Changes apply to the next recording.", comment: "Settings → Recording"))
                }
            }
        }
        .disabled(recorder.isRecording || recorder.isBusy)
        .onAppear {
            if case .apps(let families) = recorder.audioSource { lastFamilies = families }
        }
    }

    private var kind: Binding<Kind> {
        Binding {
            switch recorder.audioSource {
            case .auto: .auto
            case .apps: .apps
            case .allSystem: .all
            }
        } set: { newKind in
            switch newKind {
            case .auto: recorder.audioSource = .auto
            case .all: recorder.audioSource = .allSystem
            case .apps: recorder.audioSource = .apps(lastFamilies.isEmpty ? [.webkit] : lastFamilies)
            }
        }
    }

    private func toggle(_ family: MeetingAppFamily, _ on: Bool) {
        guard case .apps(var families) = recorder.audioSource else { return }
        if on { families.insert(family) } else { families.remove(family) }
        guard !families.isEmpty else { return }
        lastFamilies = families
        recorder.audioSource = .apps(families)
    }
}

/// The icon of the first installed app of a family, or a generic symbol.
private struct FamilyIcon: View {
    let family: MeetingAppFamily

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: family.kind == .browser ? "globe" : "video.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }

    private var icon: NSImage? {
        for app in family.apps {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        return nil
    }
}

/// The default transcription language and its model.
private struct TranscriptionLanguageSection: View {
    @Bindable var preferences: Preferences
    let speech: SpeechSettingsModel

    var body: some View {
        Section {
            if let catalog = speech.catalog {
                Picker(String(localized: "Language", comment: "Settings → Recording transcription language"), selection: $preferences.transcriptionLanguage) {
                    if let automatic = catalog.defaultLanguage()?.displayName.standaloneCapitalized {
                        Text("Automatic (\(automatic))").tag(String?.none)
                    } else {
                        Text("Automatic").tag(String?.none)
                    }
                    Divider()
                    ForEach(catalog.languages.sorted { LanguageNameSort.precedes($0.displayName, $1.displayName) }) { language in
                        Text(language.displayName.standaloneCapitalized).tag(Optional(language.id))
                    }
                }
                // An installed model is listed under Speech models just below: shown here only to download it.
                if let language = speech.effectiveLanguage(preferences.transcriptionLanguage), speech.state(language) != .installed {
                    SpeechModelRow(language: language, speech: speech, keeping: [language.id])
                }
            } else {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(Text("Loading languages…", comment: "Accessibility label of the spinner while the languages load"))
            }
        } header: {
            Text("Transcription language")
        } footer: {
            SettingsNote(String(localized: "The language people speak in your meetings. Automatic uses the first of your Mac’s preferred languages that Vauta can transcribe.",
                                comment: "Settings → Recording"))
        }
    }
}

/// The one way a speech or translation model's state is shown.
struct ModelStatusLabel: View {
    let state: SpeechModelState

    var body: some View {
        // Done is green here as everywhere else; the words stay secondary.
        TrailingStatus(text: Text(state.label)) {
            if state == .installed {
                StatusSymbol.ok.image
            } else {
                Image(systemName: "xmark.circle").foregroundStyle(.secondary)
            }
        }
    }
}

/// A download in progress: the bar, its percentage and Cancel (the same in every list).
struct DownloadProgressControls: View {
    let progress: Double
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: progress)
                .frame(width: 100)
                .accessibilityLabel(String(localized: "Download progress", comment: "Accessibility label"))
            Text(progress, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 36, alignment: .trailing)
            ActionButton("Cancel", action: cancel)
        }
    }
}

/// A button as wide as the widest action of a speech model row ("Remove…", "Cancel"), so the status or the percentage
/// before it ends on one edge in every row.
struct ActionButton: View {
    let title: LocalizedStringKey
    var accessibilityLabel: String?
    let action: () -> Void

    init(_ title: LocalizedStringKey, accessibilityLabel: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    var body: some View {
        ZStack {
            RemoveButtonSlot()
            Button(action: action) { Text(title).frame(maxWidth: .infinity) }
                .accessibilityLabel(accessibilityLabel.map { Text($0) } ?? Text(title))
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// One language's model state with Download / Cancel; a failed download says why in the row, with Try Again.
struct SpeechModelRow: View {
    let language: SpeechLanguage
    let speech: SpeechSettingsModel
    var engine: SpeechEngineKind?
    var keeping: Set<String> = []

    var body: some View {
        let state = speech.state(language, engine: engine)
        let failure = speech.failure(language, engine: engine)
        LabeledContent {
            if let progress = speech.progress(language, engine: engine) {
                DownloadProgressControls(progress: progress) { speech.cancelInstall(language, engine: engine) }
            } else if failure != nil {
                HStack(spacing: 8) {
                    if speech.failureNeedsSpace(language, engine: engine) { Button("Open Storage Settings") { Permissions.open(.storage) }.wrapsToTwoLines() }
                    Button("Try Again") { speech.install(language, engine: engine, keeping: keeping) }
                }
            } else if state == .notInstalled {
                Button("Download") { speech.install(language, engine: engine, keeping: keeping) }
            } else {
                // The status sits before the Remove… column, here and in the Speech models card above (the dictation
                // row has nothing to remove and keeps no empty slot: its status sits flush at the trailing edge).
                HStack(spacing: 8) {
                    ModelStatusLabel(state: state)
                    if state == .installed, engine != .dictation { RemoveButtonSlot() }
                }
            }
        } label: {
            Text((engine ?? language.preferredEngine).displayName)
            if let failure {
                ModelFailureLabel(text: failure)
            } else {
                Text(description: state == .installed ? String(localized: "Runs on this Mac.", comment: "Speech model detail")
                                                      : String(localized: "Downloads once from Apple, then runs on this Mac.", comment: "Speech model detail"))
            }
        }
    }
}

/// Why a language's download failed, inside the language's own row (the same in the speech and translation lists).
struct ModelFailureLabel: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            StatusSymbol.error.image
        }
        .labelStyle(.titleAndIcon)
    }
}

/// An invisible button as wide as the widest action of a speech model row: rows without one keep their status in
/// the same column as rows with one.
struct RemoveButtonSlot: View {
    var body: some View {
        ZStack {
            Button("Remove…") {}
            Button("Cancel") {}
        }
        .hidden()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
