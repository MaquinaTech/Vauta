// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation
import SwiftUI

/// Saving a speaker's voice from the Meetings window: “Remember this voice” (with the person's consent attested by the
/// user) and “This is my voice”. Both need “Recognize voices across meetings” to be on; neither can be undone with
/// Edit ▸ Undo (a saved voice is removed in Settings → Speakers or on the person's card).
extension MeetingsModel {
    /// Voice recognition is on in Settings.
    var recognizingVoices: Bool { preferences?.recognizesVoices ?? false }

    /// What the popover of a speaker may offer about voices.
    func voiceOffer(for speaker: MeetingSpeaker) -> VoiceOffer {
        // “This is my voice” is for imported recordings, which have one channel: in a live recording the user is the Me
        // channel (even when they said nothing), and a remote speaker must never be saved as the user.
        VoiceOffer(recognizing: recognizingVoices && !speakersOff, kept: keptVoices.contains(speaker.id),
                   ownVoiceAllowed: meetingImported && !speakers.contains { $0.channel == .me })
    }

    /// Opens the consent sheet for a named speaker. The popover closes first.
    func askToRememberVoice(of speakerID: Int64) {
        guard recognizingVoices, let entry = roster.entry(speakerID), let name = entry.speaker.name, entry.speaker.entityID != nil else { return }
        guard !entry.speaker.entityIsSelf else { return }
        voiceConsent = VoiceConsentRequest(speakerID: speakerID, name: name)
    }

    /// The user attested that the person agreed: saves the voice. The time of the attestation is the time of this call.
    func rememberVoice(_ request: VoiceConsentRequest) async {
        voiceConsent = nil
        noteActivity()
        do {
            let saved = try await store.rememberVoice(speakerID: request.speakerID, consentRecordedAt: .now)
            await reloadSpeakers()
            await offerVoiceHistory(entityID: saved.entityID, name: request.name, isSelf: false)
        } catch {
            present(String(localized: "Couldn’t save the voice", comment: "Alert title: saving a person’s voice failed"), error)
        }
        await reloadSpeakers()
        await loadEntity()
    }

    /// “This is my voice”: the speaker is the user, and their voice is saved.
    func rememberOwnVoice(of speakerID: Int64) async throws {
        noteActivity()
        let saved: (entityID: Int64, undo: SpeakerUndo, profileID: Int64)
        do {
            saved = try await store.rememberOwnVoice(speakerID: speakerID)
        } catch {
            await reloadSpeakers()
            await loadEntity()
            throw error
        }
        await reloadSpeakers()
        await loadEntity()
        await offerVoiceHistory(entityID: saved.entityID, name: "", isSelf: true)
    }

    /// The speaker's suggested person (“Is this Ana?”), if the speaker has one.
    func suggestion(for speaker: MeetingSpeaker) -> SpeakerSuggestion? {
        guard speaker.source == .suggested, let id = speaker.entityID, let name = speaker.entityName else { return nil }
        return SpeakerSuggestion(entityID: id, name: MeetingStore.displayName(name, isSelf: speaker.entityIsSelf), isSelf: speaker.entityIsSelf)
    }

    /// A saved voice was deleted in Settings: the entity card shows it.
    func voicesChanged() {
        Task { await loadEntity() }
    }

    /// Asks to delete a person's saved voices.
    func confirmDeleteVoice(of entity: Entity) {
        pendingDeletion = .voice(entity: entity.id, name: entity.displayName, isSelf: entity.isSelf)
    }
}

/// A person a saved voice suggests for a speaker. For the user's own voice the question and both answers have their own
/// wording (“Is this you?”, “Yes, That’s Me”): the localized name “Me” does not fit “It’s %@” in most languages.
struct SpeakerSuggestion: Equatable {
    let entityID: Int64
    let name: String
    var isSelf = false

    /// The question shown with Yes and No.
    var question: Text {
        isSelf
            ? Text("Is this you?", comment: "Speaker popover: question about a speaker whose voice resembles the user's own saved voice")
            : Text("Is this \(name)?", comment: "Speaker popover: question about a speaker whose voice resembles a person whose voice was saved; the argument is the person’s name")
    }

    /// Under the question in the popover: why the speaker is not named yet.
    var explanation: Text {
        isSelf
            ? Text("This voice resembles your saved voice. Vauta never names a speaker from a voice alone.", comment: "Speaker popover, under “Is this you?”: why the speaker is not named yet")
            : Text("This voice resembles a saved voice. Vauta never names a speaker from a voice alone.", comment: "Speaker popover, under “Is this Ana?”: why the speaker is not named yet")
    }

    /// The popover row that accepts the suggestion.
    var yesTitle: Text {
        isSelf
            ? Text("Yes, That’s Me", comment: "Speaker popover: accepts the suggestion that the speaker is the user")
            : Text("Yes, It’s \(name)", comment: "Speaker popover: accepts the suggested person; the argument is the person’s name")
    }

    /// The popover row that rejects the suggestion.
    var noTitle: Text {
        isSelf
            ? Text("No, Not Me", comment: "Speaker popover: rejects the suggestion that the speaker is the user, for this meeting")
            : Text("No, Not \(name)", comment: "Speaker popover: rejects the suggested person for this meeting; the argument is the person’s name")
    }

    /// VoiceOver label of the Yes button in Who spoke.
    var yesLabel: Text {
        isSelf
            ? Text("Yes, that’s me", comment: "VoiceOver: accepts the suggestion that a speaker is the user")
            : Text("Yes, it’s \(name)", comment: "VoiceOver: accepts the suggested person for a speaker; the argument is the person’s name")
    }

    /// VoiceOver label of the No button in Who spoke.
    var noLabel: Text {
        isSelf
            ? Text("No, not me", comment: "VoiceOver: rejects the suggestion that a speaker is the user")
            : Text("No, not \(name)", comment: "VoiceOver: rejects the suggested person for a speaker; the argument is the person’s name")
    }
}

/// What the speaker popover offers about voices.
struct VoiceOffer: Equatable {
    /// “Recognize voices across meetings” is on (and the meeting still has speakers).
    var recognizing = false
    /// Vauta kept this speaker's voice, so it can be saved.
    var kept = false
    /// “This is my voice” may be offered (the meeting is an imported recording without a Me side).
    var ownVoiceAllowed = false

    var canSave: Bool { recognizing && kept }
    static let none = VoiceOffer()
}
