// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// “Recognize voices across meetings”: off by default, with what it does and what it keeps.
struct RecognizeVoicesSection: View {
    let recorder: RecorderModel
    @Bindable var preferences: Preferences
    let voices: SavedVoicesModel

    var body: some View {
        Section {
            Toggle(isOn: $preferences.recognizeVoices) {
                Text("Recognize voices across meetings", comment: "Settings → Speakers; the switch that lets saved voices suggest who is speaking in later meetings")
                Text(description: String(localized: "Suggests who a speaker is (“Is this Ana?”) from voices you saved. Off unless you turn it on.",
                                         comment: "Settings → Speakers, description under the Recognize voices across meetings switch"))
            }
            .disabled(!preferences.separateSpeakers)
            .onChange(of: preferences.recognizeVoices) { _, on in
                if !on { Task { await voices.recognitionTurnedOff(recorder) } }
            }
        } header: {
            Text("Voice recognition", comment: "Settings → Speakers; header of the section with the switch that lets saved voices suggest who is speaking")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if !preferences.separateSpeakers {
                    SettingsNote(String(localized: "Turn on “Separate speakers” to use this.", comment: "Settings → Speakers, under the Recognize voices switch while speakers are not separated"))
                }
                if !preferences.recognizeVoices, !voices.voices.isEmpty {
                    // Said once, plainly: stopping recognition does not delete anything.
                    SettingsNote(String(localized: "Recognition is off, so no speaker is suggested from a saved voice. The voices already saved stay on this Mac until you delete them below.",
                                        comment: "Settings → Speakers, under the switch when it is off but voices are saved"))
                }
                // One paragraph; the commitments and limits are one click away, readable before opting in too.
                let whatItIs = String(localized: "A saved voice is a list of numbers, never audio. It stays in your encrypted data on this Mac.", comment: "Settings → Speakers, note under the switch: what a saved voice is")
                let limits = String(localized: "Only tested on English recordings with headsets: it can miss people or suggest the wrong one.", comment: "Settings → Speakers, note under the switch: accuracy limits")
                SettingsNote(String(localized: "\(whatItIs) \(limits)", comment: "Two sentences in a row (for example an error and what to do about it). Japanese and Chinese: no space between %1$@ and %2$@"))
                LearnMoreButton(accessibilityName: String(localized: "Learn more about voice recognition", comment: "VoiceOver label of the Learn More link under the Recognize voices switch")) {
                    RecognizeVoicesDetails(recognizing: preferences.recognizeVoices)
                }
            }
        }
    }
}

/// The Learn More popover of the voice-recognition switch. Everything the feature keeps is readable here with the switch
/// off too, so it can be read before opting in.
struct RecognizeVoicesDetails: View {
    let recognizing: Bool

    var body: some View {
        PopoverNote(String(localized: "A voice is saved only when you choose “Remember This Voice” for a person, and only after you confirm that the person agreed. A saved voice never names anyone by itself. Changes apply from the next recording or import.",
                           comment: "Settings → Speakers, details in the Learn More popover: when a voice is saved"))
        PopoverNote(String(localized: "A saved voice is a fingerprint, a list of numbers, not a recording. It stays in your encrypted data on this Mac, goes into encrypted backups and is removed when you erase your meetings and context (Settings\u{00A0}→\u{00A0}Privacy & Security). It never appears in exports, logs, search, prompts or on the network.",
                           comment: "Settings → Speakers, details in the Learn More popover: what a saved voice is and where it stays"))
        // Readable before opting in: what is kept, for how long, and what it is used for.
        PopoverNote(String(localized: "While this is on, Vauta keeps with the meeting a numeric summary of the voice of each speaker who speaks long and clearly enough, so you can choose “Remember This Voice” afterwards. It is deleted after \(VoiceProfileThresholds.keptSummaryDays) days, or sooner if you delete the meeting or turn this off.",
                           comment: "Settings → Speakers, details in the Learn More popover: the summary kept with a meeting; the argument is a number of days"))
        PopoverNote(String(localized: "That summary also lets Vauta look for a voice you just confirmed in the meetings that still have it. After you accept “Is this Ana?” or save a voice, Vauta can offer that search. It only runs when you say so, and what it finds are suggestions you accept or reject one meeting at a time. Turning this off deletes these summaries.",
                           comment: "Settings → Speakers, details in the Learn More popover: the same kept summary is used to look for a confirmed voice in the meetings that still have it"))
        if recognizing {
            PopoverNote(String(localized: "To teach Vauta your own voice, import a recording where you speak and choose “This Is My Voice” on your speaker. Later imported recordings can then suggest which speaker is you.",
                               comment: "Settings → Speakers, details in the Learn More popover when it is on: how to save the user’s own voice"))
        }
        PopoverNote(String(localized: "You are responsible for having each person’s agreement. Organizations should cover voice recognition in their data protection impact assessment.",
                           comment: "Settings → Speakers, details in the Learn More popover: consent is the recording user’s responsibility"))
        PopoverNote(String(localized: "Recognition was only tested on English recordings with headsets. With other languages, laptop microphones or phone audio it can miss people or suggest the wrong person more often, and it can confuse relatives with similar voices. In recordings, a saved person is often not suggested and is sometimes suggested as another saved person. The more voices you save, the more likely an unknown speaker resembles one of them. A suggestion is never a name until you accept it.",
                           comment: "Settings → Speakers, details in the Learn More popover: accuracy limits"))
    }
}

/// Voices with no suggestion accepted for a year: Vauta asks, and only deletes if the user says so.
struct UnusedVoicesSection: View {
    let recorder: RecorderModel
    let preferences: Preferences
    @Bindable var voices: SavedVoicesModel

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                NoticeLabel(Text("Some saved voices haven’t had a suggestion accepted in over a year.",
                                 comment: "Settings → Speakers; the reminder about saved voices unused for 12 months"), status: .info)
                if recorder.historyUnlocked {
                    Text(description: voices.unused.map(\.displayName).formatted(.list(type: .and)))
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(String(localized: "Delete These Voices…", comment: "Settings → Speakers; button that opens the confirmation to delete the saved voices unused for a year"), role: .destructive) { voices.confirmingDeleteUnused = true }
                        Button(String(localized: "Keep for Now", comment: "Settings → Speakers; button that keeps the unused saved voices and asks again later")) { voices.keepUnused(preferences) }
                    }
                } else {
                    // Locked, the names are hidden, and nobody's voice is deleted without knowing whose it is.
                    Button("Unlock…") { Task { _ = await recorder.authorizeHistory() } }
                }
            }
            .confirmationDialog(String(localized: "Delete the unused voices?", comment: "Confirmation title for deleting the saved voices that were not used for a year"),
                                isPresented: $voices.confirmingDeleteUnused, titleVisibility: .visible) {
                Button(String(localized: "Delete These Voices", comment: "Settings → Speakers; confirm button: delete the saved voices unused for a year"), role: .destructive) { Task { await voices.deleteUnused(recorder) } }
                Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
            } message: {
                Text("Their voice fingerprints are removed from the encrypted store, with the voice summaries kept in meetings. You can save a voice again from a later meeting.",
                     comment: "Confirmation message when deleting the saved voices that were not used for a year")
            }
        } header: {
            Text("Unused voices", comment: "Settings → Speakers; header of the reminder about saved voices unused for a year")
        }
    }
}

/// The voices saved on this Mac, one row per person, with delete per person and for all.
struct SavedVoicesSection: View {
    let recorder: RecorderModel
    @Bindable var voices: SavedVoicesModel
    /// Unlock here: false while the reminder above already has the Unlock button.
    var offersUnlock = true

    var body: some View {
        Section {
            if recorder.historyUnlocked {
                ForEach(voices.voices) { voice in
                    LabeledContent {
                        Button(String(localized: "Delete Voice…", comment: "Settings → Speakers; button on a saved voice row that opens the confirmation to delete it"), role: .destructive) { voices.pendingDelete = voice }
                            .accessibilityLabel(voice.isSelf
                                ? Text("Delete your saved voice", comment: "VoiceOver: deletes the user’s own saved voice")
                                : Text("Delete the saved voice of \(voice.displayName)", comment: "VoiceOver: deletes one person’s saved voice; the argument is the person’s name"))
                    } label: {
                        if voice.isSelf {
                            Text("Me (your voice)", comment: "Settings → Speakers; the row of the user’s own saved voice")
                        } else {
                            Text(verbatim: voice.displayName)
                        }
                        Text(description: Self.detail(voice))
                    }
                }
            } else {
                // Names are personal data: they wait for Touch ID, like the Context.
                LabeledContent {
                    if offersUnlock { Button("Unlock…") { Task { _ = await recorder.authorizeHistory() } } }
                } label: {
                    Text("Voices are saved on this Mac", comment: "Settings → Speakers; shown instead of the list of names while it is locked")
                    Text(description: String(localized: "Unlock with Touch ID or your password to see whose voices they are.", comment: "Settings → Speakers, under the saved voices row while locked"))
                }
            }
            LabeledContent {
                Button(String(localized: "Delete All Saved Voices…", comment: "Settings → Speakers; button that opens the confirmation to delete every saved voice"), role: .destructive) { voices.confirmingDeleteAll = true }
            } label: {
                Text("All saved voices", comment: "Settings → Speakers; title of the row that deletes every saved voice (not the erase of all meetings and context)")
                Text(description: String(localized: "Removes every saved voice and the voice summaries kept with meetings. Names and meetings stay.",
                                         comment: "Settings → Speakers; what Delete All Saved Voices removes"))
            }
            if let failure = voices.failure { NoticeLabel(Text(failure), status: .warning) }
        } header: {
            Text("Saved voices", comment: "Settings → Speakers; header of the list of people whose voice is saved on this Mac")
        } footer: {
            SettingsNote(String(localized: "Each person keeps up to \(MeetingStore.maxVoiceProfilesPerPerson) fingerprints; beyond that, saving another one replaces the oldest.",
                                comment: "Settings → Speakers, under the saved voices; the argument is the maximum number of fingerprints per person"))
        }
        .confirmationDialog(voices.pendingDelete.map { $0.isSelf ? PendingDeletion.ownVoiceTitle : String(localized: "Delete the saved voice of \($0.displayName)?", comment: "Confirmation title; the argument is a person's name") } ?? "",
                            isPresented: Binding(get: { voices.pendingDelete != nil }, set: { if !$0 { voices.pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: voices.pendingDelete) { voice in
            Button(String(localized: "Delete Voice", comment: "Settings → Speakers; confirm button: delete one person’s saved voice"), role: .destructive) { Task { await voices.delete(voice, recorder) } }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { voice in
            Text(verbatim: PendingDeletion.voiceMessage(isSelf: voice.isSelf))
        }
        .confirmationDialog(String(localized: "Delete all saved voices?", comment: "Confirmation title"),
                            isPresented: $voices.confirmingDeleteAll, titleVisibility: .visible) {
            Button(String(localized: "Delete All Saved Voices", comment: "Settings → Speakers; confirm button: delete every saved voice"), role: .destructive) { Task { await voices.deleteAll(recorder) } }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: {
            Text("Every saved voice fingerprint, and the voice summaries kept with meetings, are removed from the encrypted store. You can’t undo this.",
                 comment: "Confirmation message when deleting every saved voice")
        }
    }

    /// “2 fingerprints · last suggestion accepted Oct 3, 2026”, or when it never was, when the user confirmed it.
    static func detail(_ voice: SavedVoice) -> String {
        let count = String(localized: "\(voice.fingerprints) fingerprints", comment: "Settings → Speakers; how many voice fingerprints a person has; the argument is a number")
        let when: String
        if let matched = voice.lastMatchedAt {
            when = String(localized: "last suggestion accepted \(matched.formatted(date: .abbreviated, time: .omitted))", comment: "Settings → Speakers; when a suggestion from a saved voice was last accepted; the argument is a date")
        } else {
            when = voice.usable
                ? String(localized: "saved \(voice.consentRecordedAt.formatted(date: .abbreviated, time: .omitted)), no suggestion accepted yet", comment: "Settings → Speakers; a saved voice none of whose suggestions has been accepted yet; the argument is the date the user confirmed the person agreed")
                // A voice the current model cannot use will never be suggested: no "yet".
                : String(localized: "saved \(voice.consentRecordedAt.formatted(date: .abbreviated, time: .omitted))", comment: "Settings → Speakers; a saved voice that the current model cannot use; the argument is the date the user confirmed the person agreed")
        }
        var parts = [count, when]
        if !voice.usable { parts.append(String(localized: "made by an older voice model, not used", comment: "Settings → Speakers; a saved voice that the current model cannot use, so it can only be deleted")) }
        return parts.joined(separator: " · ")
    }
}
