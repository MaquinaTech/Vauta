// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Settings → Speakers: whether the voices of a meeting are told apart, whether saved voices suggest who is speaking across
/// meetings (off unless the user turns it on), and the voices saved on this Mac.
struct SpeakersPane: View {
    let recorder: RecorderModel
    @Bindable var preferences: Preferences
    @Bindable var voices: SavedVoicesModel

    var body: some View {
        Form {
            SeparateSpeakersSection(preferences: preferences, remembersVoices: preferences.recognizeVoices || !voices.voices.isEmpty)
            RecognizeVoicesSection(recorder: recorder, preferences: preferences, voices: voices)
            if voices.showsReminder(preferences) { UnusedVoicesSection(recorder: recorder, preferences: preferences, voices: voices) }
            if !voices.voices.isEmpty { SavedVoicesSection(recorder: recorder, voices: voices, offersUnlock: !voices.showsReminder(preferences)) }
        }
        .formStyle(.grouped)
        .task { await voices.reload(recorder) }
        .onChange(of: recorder.historyUnlocked) { _, _ in Task { await voices.reload(recorder) } }
        // Without separated speakers nothing is matched or kept: the summaries kept with meetings go at once.
        .onChange(of: preferences.separateSpeakers) { _, _ in Task { await recorder.maintainVoices() } }
    }
}

/// "Separate speakers" and what it does with the audio.
private struct SeparateSpeakersSection: View {
    @Bindable var preferences: Preferences
    /// Recognition is on or voices are saved: separating speakers is then not the whole story about remembering voices.
    let remembersVoices: Bool

    var body: some View {
        Section {
            Toggle(isOn: $preferences.separateSpeakers) {
                Text("Separate speakers", comment: "Settings → Speakers; the switch that tells the voices of the other participants apart")
                Text(description: String(localized: "Tells the voices of the other participants apart as Speaker 1, Speaker 2… in the transcript, while recording and in imported recordings. Applies from the next recording or import.",
                                         comment: "Settings → Speakers, description under the Separate speakers switch"))
            }
        } header: {
            Text("Speaker separation", comment: "Settings → Speakers; header of the first section, with the switch that tells the voices of the other participants apart")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if preferences.separateSpeakers {
                    SettingsNote(String(localized: "Runs on this Mac. Vauta keeps no audio and sends nothing anywhere.",
                                        comment: "Settings → Speakers, short note under the switch: on-device, no audio kept"))
                    LearnMoreButton(accessibilityName: String(localized: "Learn more about speaker separation", comment: "VoiceOver label of the Learn More link under the Separate speakers switch")) {
                        if remembersVoices {
                            PopoverNote(String(localized: "This runs on this Mac. Vauta keeps no audio and sends nothing anywhere. On its own, separating speakers doesn’t remember a voice from one meeting to the next; see “Recognize voices across meetings” below. While you record, short numeric summaries of the voices are kept in the encrypted store, so the speakers can still be told apart if Vauta quits unexpectedly; they are deleted as soon as the meeting ends, unless “Recognize voices across meetings” is on.",
                                               comment: "Settings → Speakers, details in the Learn More popover while Recognize voices across meetings is on: on-device, no audio kept, the summaries kept with a meeting are explained below"))
                        } else {
                            PopoverNote(String(localized: "This runs on this Mac. Vauta keeps no audio, sends nothing anywhere, and doesn’t remember a voice from one meeting to the next. While you record, short numeric summaries of the voices are kept in the encrypted store, so the speakers can still be told apart if Vauta quits unexpectedly; they are deleted as soon as the meeting ends.",
                                               comment: "Settings → Speakers, details in the Learn More popover: on-device, no audio kept, nothing remembered between meetings"))
                        }
                        PopoverNote(String(localized: "You can also turn this off for a single meeting, by turning off “Separate speakers in this meeting” in its transcript.",
                                           comment: "Settings → Speakers, details in the Learn More popover: the per-meeting switch in Meetings"))
                    }
                } else {
                    // Nothing is processed any more, so nothing about processing is said.
                    SettingsNote(String(localized: "Recordings and imports aren’t separated into speakers.",
                                        comment: "Settings → Speakers, under the switch when it is off: new recordings and imports keep the plain Me and Others transcript"))
                }
            }
        }
    }
}

/// "Learn More" under a switch: the details that would make its note long, in a popover (Network Activity uses the same link).
struct LearnMoreButton<Details: View>: View {
    @ViewLocalState private var shown = false
    /// What VoiceOver says for this link: "Learn More" alone is ambiguous in the links rotor.
    let accessibilityName: String
    /// The details bring their own padding and width (Network Activity's note).
    var bare = false
    @ViewBuilder let details: Details

    var body: some View {
        Button { shown.toggle() } label: {
            Text("Learn More", comment: "Settings; link under a switch that opens a popover with the details")
        }
        .buttonStyle(.link)
        .font(.subheadline)
        .accessibilityLabel(accessibilityName)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            if bare {
                details
            } else {
                VStack(alignment: .leading, spacing: 10) { details }
                    .padding(16)
                    .frame(width: 400)
            }
        }
    }
}

/// A paragraph of a Learn More popover.
struct PopoverNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(description: text)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }
}
