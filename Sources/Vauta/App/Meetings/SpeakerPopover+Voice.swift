// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// The voice-recognition parts of the speaker popover: the “Is this Ana?” question, “Remember this voice” and
/// “This is my voice” (imported recordings only). Only present while “Recognize voices across meetings” is on (or a voice suggested a person).
extension SpeakerPopoverContent {
    /// The middle band: a saved voice resembles this person. Never shown as
    /// a name; the user answers yes (an ordinary assignment, which then wins over anything) or no (remembered for this meeting).
    func suggestionBlock(_ candidate: SpeakerSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            candidate.question
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .accessibilityAddTraits(.isHeader)
            candidate.explanation
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            PopoverRow(title: candidate.yesTitle, symbol: "checkmark.circle") {
                run(.assign(speaker: speakerID, entity: candidate.entityID))
            }
            PopoverRow(title: candidate.noTitle, symbol: "xmark.circle") {
                run(.rejectSuggestion(speaker: speakerID))
            }
            Divider().padding(.vertical, 4)
        }
    }

    /// “Remember this voice” (for a speaker who has a name) and “This is my voice”, when the voice was kept.
    @ViewBuilder
    func voiceRows(_ entry: SpeakerRoster.Entry) -> some View {
        // The user's own speaker goes through “This is my voice”, never through a consent sheet about “Me”.
        let canRemember = entry.speaker.name != nil && !entry.speaker.entityIsSelf
        let canOwn = !entry.speaker.entityIsSelf && voice.ownVoiceAllowed
        if voice.canSave, canRemember || canOwn {
            Divider().padding(.vertical, 4)
            if canRemember {
                PopoverRow(title: Text("Remember This Voice…", comment: "Speaker popover: opens the sheet that saves a fingerprint of this speaker’s voice so later meetings can suggest this person"), symbol: "waveform.badge.plus",
                           detail: Text("Saved on this Mac only. You confirm that the person agreed.", comment: "Speaker popover: explains Remember This Voice")) {
                    rememberVoice()
                }
            }
            if canOwn {
                PopoverRow(title: Text("This Is My Voice", comment: "Speaker popover: the speaker is the user; saves their voice so later imported recordings can suggest it"), symbol: "waveform.badge.mic", drills: true) {
                    open(.confirmOwnVoice)
                }
            }
        }
    }

    func confirmOwnVoice(_ entry: SpeakerRoster.Entry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            BackBar(title: Text("This is my voice", comment: "Speaker popover: title of the page that confirms saving the user’s own voice")) { open(.main) }
            Text("Vauta saves a fingerprint of this voice as yours on this Mac only and names this speaker “Me”. Later imported recordings can then suggest which speaker is you.",
                 comment: "Speaker popover: what saving the user’s own voice does")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
            ViewThatFits(in: .horizontal) {
                HStack {
                    Spacer(minLength: 0)
                    cancelOwnVoiceButton
                    saveOwnVoiceButton
                }
                VStack(spacing: 6) {
                    saveOwnVoiceButton.frame(maxWidth: .infinity)
                    cancelOwnVoiceButton.frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 6)
    }

    private var cancelOwnVoiceButton: some View {
        Button("Cancel", role: .cancel) { open(.main) }.keyboardShortcut(.cancelAction)
    }

    private var saveOwnVoiceButton: some View {
        Button(String(localized: "Save My Voice", comment: "Speaker popover; button that saves the user’s own voice fingerprint")) {
            busy = true
            failure = nil
            Task {
                do {
                    try await saveOwnVoice()
                    close()
                } catch {
                    failure = error.localizedDescription
                }
                busy = false
            }
        }
        .keyboardShortcut(.defaultAction)
    }
}
