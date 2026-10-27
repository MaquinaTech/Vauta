// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Speech models on this Mac: installed languages, adding and removing them.
struct SpeechModelsSection: View {
    let preferences: Preferences
    let speech: SpeechSettingsModel
    @ViewLocalState private var toAdd: String?
    @ViewLocalState private var removing: SpeechLanguage?
    @ViewLocalState private var choosingLanguage = false

    var body: some View {
        Section {
            // A failed download of the transcription language is shown in its own row under "Transcription language".
            let languages = speech.languagesOnThisMac.filter { !($0.id == speech.failedInstall?.id && active.contains($0.id) && speech.state($0) != .installed) }
            if speech.catalog != nil && languages.isEmpty {
                SettingsNote(String(localized: "No speech models yet. Download the model of the language you transcribe in.",
                                    comment: "Settings → Recording empty state"))
            }
            ForEach(languages) { language in
                LabeledContent {
                    if let progress = speech.progress(language) {
                        DownloadProgressControls(progress: progress) { speech.cancelInstall(language) }
                    } else if speech.failure(language) != nil {
                        HStack(spacing: 8) {
                            if speech.failureNeedsSpace(language) { Button("Open Storage Settings") { Permissions.open(.storage) }.wrapsToTwoLines() }
                            Button("Try Again") { speech.install(language, keeping: active) }
                        }
                    } else {
                        HStack(spacing: 8) {
                            ModelStatusLabel(state: speech.state(language))
                            if speech.isReserved(language) {
                                ActionButton("Remove…", accessibilityLabel: String(localized: "Remove \(language.displayName)", comment: "Accessibility label; argument is a language")) { removing = language }
                            } else {
                                RemoveButtonSlot()
                            }
                        }
                    }
                } label: {
                    Text(language.displayName.standaloneCapitalized)
                    if let failure = speech.failure(language) {
                        ModelFailureLabel(text: failure)
                    } else if language.preferredEngine != .speech {
                        // Only when the engine isn't the usual one: the section is already "Speech models".
                        Text(description: String(localized: "Dictation · less accurate", comment: "Settings → Recording; under a language whose model uses the Dictation engine, which is less accurate than speech recognition"))
                    }
                }
            }

            // Choosing a language starts its download: no second button.
            LabeledContent {
                // A bordered button like Remove… and Download…: a Menu inside a grouped Form is redrawn as the form's
                // bare popup, so the button opens a popover with the languages instead.
                Button(String(localized: "Add Language…", comment: "Settings → Recording; opens the list of languages whose speech model can be downloaded")) {
                    choosingLanguage = true
                }
                .disabled(speech.languagesToAdd.isEmpty)
                .popover(isPresented: $choosingLanguage, arrowEdge: .bottom) {
                    LanguageChoiceList(choices: speech.languagesToAdd.map { .init(id: $0.id, name: $0.displayName) }) { id in
                        choosingLanguage = false
                        if let language = speech.languagesToAdd.first(where: { $0.id == id }) { speech.install(language, keeping: active) }
                    }
                }
            } label: {
                Text("Another language", comment: "Settings → Recording; title of the row with the menu that adds a speech model")
                Text(description: String(localized: "Choosing one starts its download.", comment: "Settings → Recording; under the row that adds a speech model"))
            }

        } header: {
            Text("Speech models")
        } footer: {
            let limit = speech.reservationLimit
            SettingsNote(String(localized: "Each language downloads once from Apple. After that, transcription runs on this Mac, and audio never leaves it. macOS lets Vauta keep up to \(limit) languages: downloading another one releases the language you used least recently.",
                                comment: "Settings → Recording; argument is the maximum number of languages"))
        }
        .confirmationDialog(String(localized: "Remove the speech model for \(removing?.displayName ?? "")?", comment: "Confirmation title; argument is a language"),
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove Model", role: .destructive) {
                if let language = removing { Task { await speech.remove(language) } }
                removing = nil
            }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: {
            Text("Vauta will no longer transcribe this language until you download it again. macOS deletes the model when no other app uses it.")
        }
    }

    /// The default language is never released to make room.
    private var active: Set<String> {
        Set([speech.effectiveLanguage(preferences.transcriptionLanguage)?.id].compactMap { $0 })
    }
}

/// Custom vocabulary through dictation, per channel.
struct VocabularySection: View {
    @Bindable var recorder: RecorderModel
    let preferences: Preferences
    let speech: SpeechSettingsModel

    var body: some View {
        Section {
            if let language = speech.effectiveLanguage(preferences.transcriptionLanguage) {
                if language.engines.contains(.dictation) {
                    SpeechModelRow(language: language, speech: speech, engine: .dictation, keeping: [language.id])
                } else {
                    SettingsNote(String(localized: "Dictation isn’t available for \(language.displayName).", comment: "Settings → Recording; argument is a language"))
                }
            }
            Toggle(String(localized: "Use for “\(Channel.me.displayName)”", comment: "Dictation toggle; argument is the user's channel name"),
                   isOn: $recorder.dictationMe)
            Toggle(String(localized: "Use for “\(Channel.others.displayName)”", comment: "Dictation toggle; argument is the other participants' channel name"),
                   isOn: $recorder.dictationOthers)
        } header: {
            HStack(spacing: 8) {
                Text("Custom vocabulary")
                BadgeCapsule(String(localized: "Experimental", comment: "Badge on a feature that is still being evaluated"))
            }
        } footer: {
            SettingsNote(String(localized: "Dictation recognizes the names you use (attendees, pinned glossary terms, projects and clients, up to 100) but is less accurate overall. Try it on one channel and compare. Changes apply to the next recording.",
                                comment: "Settings → Recording"))
        }
        .disabled(recorder.isRecording)
    }
}
