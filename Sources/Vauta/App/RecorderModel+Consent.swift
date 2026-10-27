// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit

/// What the consent helper's row in the panel shows.
struct ConsentPrompt: Equatable {
    /// The notice, in the meeting's language, ready to paste.
    var text: String
    /// The language the notice is written in (BCP-47, for VoiceOver's pronunciation).
    var language: String?
    /// The name of that language when it isn't the interface language (the row then says so).
    var otherLanguageName: String?
    /// "Copied" is showing on the button.
    var copied = false
    /// The user marked the participants as informed (then the row is a quiet confirmation).
    var informedAt: Date?
}

extension ConsentPrompt {
    /// The prompt for a resolved notice. A notice in another language than the
    /// interface names its language, so the user knows what they are pasting.
    init(_ notice: ConsentNotice.Resolved, interface: String? = Bundle.main.preferredLocalizations.first) {
        let language = notice.language ?? "en"
        text = notice.text
        self.language = language
        let sameAsInterface = interface.map { Locale(identifier: $0).language.languageCode == Locale(identifier: language).language.languageCode } ?? true
        otherLanguageName = sameAsInterface ? nil : Locale(identifier: interface ?? "en").localizedString(forIdentifier: language)
    }
}

/// Consent helper: a discreet reminder, while recording, to tell the other
/// participants that the meeting is being transcribed, with a notice to paste
/// into the meeting chat. It never blocks recording and never sends anything.
extension RecorderModel {
    /// After the recording started: shows the reminder if the setting says so.
    func prepareConsentPrompt(meetingID id: Int64, sourceApp: String?, language: Locale) async {
        let informedBefore = preferences.consentReminder == .firstPerApp
            ? ((try? await store?.hasInformedParticipants(sourceApp: sourceApp)) ?? false)
            : false
        guard preferences.consentReminder.shouldRemind(informedBefore: informedBefore), meetingID == id, phase == .recording else { return }
        let notice = ConsentNotice.resolve(meetingLocale: language.identifier(.bcp47), recognizesVoices: preferences.recognizesVoices)
        consentPrompt = ConsentPrompt(notice)
    }

    /// Puts the notice on the clipboard (the clipboard only: nothing is sent anywhere).
    func copyConsentNotice() {
        guard var prompt = consentPrompt else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt.text, forType: .string)
        prompt.copied = true
        consentPrompt = prompt
        consentCopyReset?.cancel()
        consentCopyReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.consentPrompt?.copied = false
        }
    }

    /// "Mark as informed": the meeting records when the user told the participants.
    func markParticipantsInformed() {
        guard consentPrompt != nil, consentPrompt?.informedAt == nil, let store, let id = meetingID else { return }
        let now = Date.now
        consentPrompt?.informedAt = now
        Task {
            do {
                try await store.markParticipantsInformed(id, at: now)
            } catch {
                if meetingID == id { consentPrompt?.informedAt = nil }
                lastError = saveFailure(String(localized: "Couldn’t save that the participants were informed.", comment: "Warning while recording"), error)
            }
        }
    }

    /// Takes "informed" back (a tap by mistake): the reminder returns and the meeting's record is cleared.
    func undoParticipantsInformed() {
        guard consentPrompt?.informedAt != nil, let store, let id = meetingID else { return }
        let previous = consentPrompt?.informedAt
        consentPrompt?.informedAt = nil
        Task {
            do {
                try await store.clearParticipantsInformed(id)
            } catch {
                if meetingID == id { consentPrompt?.informedAt = previous }
                lastError = saveFailure(String(localized: "Couldn’t save that the participants were informed.", comment: "Warning while recording"), error)
            }
        }
    }

    /// Hides the reminder for this recording (nothing is recorded about it).
    func dismissConsentPrompt() {
        clearConsentPrompt()
    }

    func clearConsentPrompt() {
        consentCopyReset?.cancel()
        consentCopyReset = nil
        consentPrompt = nil
    }
}
