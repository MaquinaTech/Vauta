// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import SwiftUI

/// The voice-recognition scenes: Settings → Speakers in each state, the Meetings window with a user-named and a suggested
/// speaker, the pages of the speaker popover that save a voice, the consent sheet, the person's card, the consent
/// notice and the confirmations. The voices are invented bytes (`SampleWorld.seedSavedVoices`): never a real voice.
extension SnapshotScenes {
    static var voices: [SnapshotScene] {
        voiceSettingsScenes + voiceMeetingScenes + voicePopoverScenes + voiceSheetScenes
    }

    // MARK: Settings → Speakers

    /// Every voice settings scene starts from the same state: the Settings model is shared, so a clock or a snooze set by
    /// one scene must not leak into the next.
    private static func resetVoiceReminder(_ fixture: SnapshotFixture) {
        fixture.preferences.voiceReminderSnoozedUntil = 0
        fixture.settings.savedVoices.clock = { AppClock.now }
    }

    private static let voiceSettings = CGSize(width: 1020, height: 770)

    private static var voiceSettingsScenes: [SnapshotScene] {
        [
            // The default: recognition off, nothing saved. The explanation is under the switch.
            settingsScene("voices-off", .speakers, size: CGSize(width: 1020, height: 440)) { _, fixture in
                resetVoiceReminder(fixture)
                try? await fixture.world.resetSpeakerSamples()
                fixture.preferences.separateSpeakers = true
                fixture.preferences.recognizeVoices = false
            },
            // On, with three people saved (one with two fingerprints, one whose suggestion was accepted), and what it keeps.
            settingsScene("voices-on", .speakers, size: voiceSettings) { _, fixture in
                resetVoiceReminder(fixture)
                try? await fixture.world.seedSavedVoices()
                fixture.preferences.separateSpeakers = true
                fixture.preferences.recognizeVoices = true
            },
            // A voice made by an older speaker model: listed so it can be deleted, but never used.
            settingsScene("voices-old-model", .speakers, size: voiceSettings) { _, fixture in
                resetVoiceReminder(fixture)
                try? await fixture.world.seedSavedVoices(olderModel: true)
                fixture.preferences.separateSpeakers = true
                fixture.preferences.recognizeVoices = true
            },
            // Turned off again: the saved voices stay and the note says so.
            settingsScene("voices-off-saved", .speakers, size: CGSize(width: 1020, height: 760)) { _, fixture in
                resetVoiceReminder(fixture)
                try? await fixture.world.seedSavedVoices()
                fixture.preferences.separateSpeakers = true
                fixture.preferences.recognizeVoices = false
            },
            // Without separated speakers there is nothing to recognize: the switch is dimmed and says why.
            settingsScene("voices-no-separation", .speakers, size: CGSize(width: 1020, height: 440)) { _, fixture in
                resetVoiceReminder(fixture)
                try? await fixture.world.resetSpeakerSamples()
                fixture.preferences.separateSpeakers = false
                fixture.preferences.recognizeVoices = false
            },
            // The voices nobody matched for over a year: Vauta asks, the user decides.
            settingsScene("voices-unused", .speakers, size: CGSize(width: 1020, height: 900)) { _, fixture in
                resetVoiceReminder(fixture)
                // Dated 14 months back, so the reminder and the list below it tell the same story.
                try? await fixture.world.seedSavedVoices(monthsAgo: 14)
                fixture.preferences.separateSpeakers = true
                fixture.preferences.recognizeVoices = true
            },
            // The same reminder while Meetings is locked: no names, so no deleting; Unlock leads to the names.
            settingsScene("voices-unused-locked", .speakers, size: CGSize(width: 1020, height: 770)) { recorder, fixture in
                resetVoiceReminder(fixture)
                try? await fixture.world.seedSavedVoices(monthsAgo: 14)
                fixture.preferences.separateSpeakers = true
                fixture.preferences.recognizeVoices = true
                recorder.historyUnlocked = false
            },
            // Meetings locked: the names are hidden, the count of deleting stays available.
            settingsScene("voices-locked", .speakers, size: CGSize(width: 1020, height: 650)) { recorder, fixture in
                resetVoiceReminder(fixture)
                try? await fixture.world.seedSavedVoices()
                fixture.preferences.separateSpeakers = true
                fixture.preferences.recognizeVoices = true
                recorder.historyUnlocked = false
            },
            // The narrowest Settings window.
            settingsScene("voices-narrow", .speakers, size: CGSize(width: SettingsWindow.minimumWidth, height: 770)) { _, fixture in
                resetVoiceReminder(fixture)
                try? await fixture.world.seedSavedVoices()
                fixture.preferences.separateSpeakers = true
                fixture.preferences.recognizeVoices = true
            },
        ]
    }

    // MARK: The Meetings window

    private static let tallMeetings = CGSize(width: 1040, height: 900)

    private static func openVoiceMeeting(_ history: MeetingsModel, _ fixture: SnapshotFixture, tab: MeetingsModel.DetailTab? = nil) async {
        try? await fixture.world.seedSuggestedSpeakers()
        fixture.preferences.recognizeVoices = true
        history.preferences = fixture.preferences
        await history.reload()
        history.selectedID = fixture.world.featuredMeetingID
        await history.loadDetail()
        if let tab { history.tab = tab }
    }

    private static var voiceMeetingScenes: [SnapshotScene] {
        [
            // Daniel's name was accepted by the user (a saved voice only suggests), Priya is a suggestion (“Is this Priya?” with Yes and No).
            meetingsAfterScene("voices-summary", size: CGSize(width: 1040, height: 800), prepare: { history, fixture in
                await openVoiceMeeting(history, fixture)
            }) { _, _ in },
            meetingsAfterScene("voices-transcript", size: tallMeetings, prepare: { history, fixture in
                await openVoiceMeeting(history, fixture, tab: .transcript)
            }) { _, _ in },
            // A person's card with the voice saved on this Mac and the one action that removes it.
            meetingsAfterScene("voices-person", size: CGSize(width: 1040, height: 800), prepare: { history, fixture in
                try? await fixture.world.seedFeaturedSpeakers()
                try? await fixture.world.seedSavedVoices()
                await history.reload()
                history.mode = .people
                history.selectedEntityID = fixture.world.peopleIDs[2]
                await history.loadEntity()
            }) { _, _ in },
        ]
    }

    // MARK: The speaker popover

    private enum VoicePage {
        case main, confirmOwnVoice
    }

    private static func voicePopoverScene(_ name: String, ordinal: Int, page: VoicePage = .main, offer: VoiceOffer, suggestion: Bool = false, suggestMe: Bool = false, userNamed: Bool = false, failure: String? = nil) -> SnapshotScene {
        SnapshotScene(name: "speaker-popover-\(name)", size: CGSize(width: SpeakerPopoverContent.width, height: 380), fitHeight: true, isSheet: true) { fixture in
            let recorder = await fixture.makeRecorder()
            guard let history = recorder.history else { return .init(view: AnyView(EmptyView())) }
            history.llm = nil
            try? await fixture.world.seedSuggestedSpeakers(thirdIsMe: suggestMe)
            await history.reload()
            history.selectedID = fixture.world.featuredMeetingID
            await history.loadDetail()
            if userNamed, let named = history.roster.entries.first(where: { $0.channel == .others && $0.speaker.ordinal == ordinal })?.speaker,
               let entity = named.entityID {
                // The user confirmed the name (or typed it): this is the speaker “Remember This Voice” is for.
                _ = try? await history.store.assignSpeaker(named.id, toEntity: entity)
                await history.reloadSpeakers()
            }
            guard let entry = history.roster.entries.first(where: { $0.channel == .others && $0.speaker.ordinal == ordinal }) else {
                return .init(view: AnyView(EmptyView()))
            }
            let people = history.speakerCandidates(for: entry.speaker)
            let view = SpeakerPopoverContent(roster: history.roster, speakerID: entry.id, line: nil, meetingID: fixture.world.featuredMeetingID,
                                             suggested: people.suggested, people: people.people, voice: offer,
                                             candidate: suggestion ? history.suggestion(for: entry.speaker) : nil,
                                             mode: page == .main ? .main : .confirmOwnVoice, failure: failure,
                                             perform: { _ in }, close: {})
                .background(Color(nsColor: .windowBackgroundColor))
            return .init(view: AnyView(view))
        }
    }

    private static var voicePopoverScenes: [SnapshotScene] {
        [
            // A speaker the user named (typed, or accepted from a suggestion): Remember This Voice (the consent sheet follows).
            voicePopoverScene("voices-remember-user", ordinal: 2, offer: VoiceOffer(recognizing: true, kept: true), userNamed: true),
            // A saved voice resembles Priya: the question comes first, and she is not named until the user says yes.
            voicePopoverScene("voices-suggestion", ordinal: 3, offer: VoiceOffer(recognizing: true, kept: true), suggestion: true),
            // An imported recording where the user's own saved voice resembles a speaker: “Is this you?”. (The sample meeting is a live one; the popover does not depend on the meeting kind.)
            voicePopoverScene("voices-suggestion-me", ordinal: 3, offer: VoiceOffer(recognizing: true, kept: true), suggestion: true, suggestMe: true),
            // Nobody named, in an imported recording (one channel, no Me side): only “This Is My Voice” is offered.
            voicePopoverScene("voices-unnamed", ordinal: 1, offer: VoiceOffer(recognizing: true, kept: true, ownVoiceAllowed: true)),
            // The page that confirms saving the user's own voice.
            voicePopoverScene("voices-own", ordinal: 1, page: .confirmOwnVoice, offer: VoiceOffer(recognizing: true, kept: true, ownVoiceAllowed: true)),
            // The errors of saving a voice, as the popover shows them.
            voicePopoverScene("voices-error-not-kept", ordinal: 2, offer: VoiceOffer(recognizing: true, kept: true), userNamed: true,
                              failure: StoreError(.voiceNotAvailable).localizedDescription),
            // Reachable only when the name is cleared between opening the consent sheet and confirming it: the speaker is
            // named in the popover, which still offers Remember This Voice.
            voicePopoverScene("voices-error-needs-person", ordinal: 2, offer: VoiceOffer(recognizing: true, kept: true), userNamed: true,
                              failure: StoreError(.voiceNeedsPerson).localizedDescription),
        ]
    }

    // MARK: Sheets, notices and confirmations

    /// A confirmation or alert, drawn by AppKit's own `NSAlert` (see `SnapshotAlert`).
    private static func confirmationScene(_ name: String, title: String, message: String, action: String, destructive: Bool = true) -> SnapshotScene {
        SnapshotScene(name: name, size: CGSize(width: 260, height: 160), isSheet: true) { _ in
            let buttons: [SnapshotAlert.Button] = destructive
                ? [.init(title: action, destructive: true), .init(title: String(localized: "Cancel", comment: "Alert button"))]
                : [.init(title: action)]
            return .init(view: AnyView(EmptyView()), alert: SnapshotAlert(title: title, message: message, buttons: buttons, defaultIndex: destructive ? 1 : 0))
        }
    }

    private static let sampleName = "Daniel"

    private static var voiceSheetScenes: [SnapshotScene] {
        [
            // The consent attestation: the box starts unchecked and the button is dimmed; then the same, checked.
            SnapshotScene(name: "voices-consent-sheet", size: CGSize(width: 460, height: 420), fitHeight: true, isSheet: true) { fixture in
                .init(view: AnyView(VoiceConsentSheet(name: fixture.world.speakerText.names[0], remember: {}, cancel: {})
                    .background(Color(nsColor: .windowBackgroundColor))))
            },
            SnapshotScene(name: "voices-consent-sheet-agreed", size: CGSize(width: 460, height: 420), fitHeight: true, isSheet: true) { fixture in
                .init(view: AnyView(VoiceConsentSheet(name: fixture.world.speakerText.names[0], agreed: true, remember: {}, cancel: {})
                    .background(Color(nsColor: .windowBackgroundColor))))
            },
            // A long name: the sheet wraps it.
            SnapshotScene(name: "voices-consent-sheet-long-name", size: CGSize(width: 460, height: 460), fitHeight: true, isSheet: true) { fixture in
                .init(view: AnyView(VoiceConsentSheet(name: fixture.world.speakerText.longName, remember: {}, cancel: {})
                    .background(Color(nsColor: .windowBackgroundColor))))
            },
            // The notice the user pastes into the meeting chat, the one that also says voices may be used to suggest who is speaking (recognition on).
            panelScene("consent-voices") { recorder, fixture in
                recording(recorder, fixture)
                recorder.consentPrompt = ConsentPrompt(ConsentNotice.resolve(meetingLocale: fixture.language, recognizesVoices: true))
            },
            confirmationScene("voices-delete-confirm", title: String(localized: "Delete the saved voice of \(sampleName)?", comment: "Confirmation title; the argument is a person's name"),
                              message: String(localized: "The voice of this person is removed from the encrypted store, with the voice summaries kept in meetings, and Vauta will no longer suggest them. Meetings and the names already in them stay as they are.", comment: "Confirmation message"),
                              action: String(localized: "Delete Voice", comment: "Alert button")),
            confirmationScene("voices-delete-own-confirm", title: PendingDeletion.ownVoiceTitle,
                              message: PendingDeletion.voiceMessage(isSelf: true),
                              action: String(localized: "Delete Voice", comment: "Alert button")),
            // The alert that follows a failed save (the message is the error's own text).
            confirmationScene("voices-save-failed-alert", title: String(localized: "Couldn’t save the voice", comment: "Alert title"),
                              message: StoreError(.voiceNotAvailable).localizedDescription, action: String(localized: "OK", comment: "Alert button"), destructive: false),
            confirmationScene("voices-delete-all-confirm", title: String(localized: "Delete all saved voices?", comment: "Confirmation title"),
                              message: String(localized: "Every saved voice fingerprint, and the voice summaries kept with meetings, are removed from the encrypted store. You can’t undo this.", comment: "Confirmation message"),
                              action: String(localized: "Delete All Saved Voices", comment: "Alert button")),
            confirmationScene("voices-delete-unused-confirm", title: String(localized: "Delete the unused voices?", comment: "Confirmation title"),
                              message: String(localized: "Their voice fingerprints are removed from the encrypted store, with the voice summaries kept in meetings. You can save a voice again from a later meeting.", comment: "Confirmation message"),
                              action: String(localized: "Delete These Voices", comment: "Alert button")),
        ]
    }
}
#endif
