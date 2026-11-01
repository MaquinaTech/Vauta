// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// Meetings → Transcript → Translate (`TranscriptTranslationModel`): the language the transcript is read in, translating it,
/// and the lines a correction changed.
extension MeetingsModel {
    /// The transcript of the meeting shown can be translated: it is finished, not being recorded, and has lines.
    var canTranslateTranscript: Bool {
        mode == .meetings && !isActive && shownMeeting?.endedAt != nil && !transcript.isEmpty
    }

    /// Shows the transcript of the meeting shown in `target` and translates its lines that don't have it yet (every line with
    /// `again`).
    func translateTranscript(into target: Locale.Language, again: Bool = false) {
        guard canTranslateTranscript, let meeting = shownMeeting else { return }
        noteActivity()
        chosenTranslations[meeting.id] = target.storageCode
        preferences?.showTranslationsInTranscript = true
        translation.translate(meeting.id, source: meeting.transcriptionLocale.language, into: target, scope: again ? .all : .missing)
        Task { await reloadTranslations(meeting.id) }
    }

    /// Reads the translations of the meeting shown again (while it is translated, after a correction).
    func reloadTranslations(_ meetingID: Int64) async {
        guard selectedID == meetingID, let stored = try? await store.translations(of: meetingID), selectedID == meetingID else { return }
        showTranslations(stored, of: meetingID)
    }

    /// The translations to show: in the language the person chose for the meeting, else the one with the most lines.
    func showTranslations(_ stored: [MeetingStore.StoredTranslation], of meetingID: Int64) {
        let chosen = chosenTranslations[meetingID]
        let preferred = preferences?.translationTarget
        translations = TranslationDisplay.texts(from: stored, preferred: preferred, chosen: chosen)
        translationLanguage = TranslationDisplay.chooseLanguage(from: stored, preferred: preferred, chosen: chosen)
    }

    /// After a correction: the lines whose translation is now of an earlier text are translated again, into the language the
    /// transcript is read in. A line that never had a translation stays without one.
    func translateCorrectedLines(_ meetingID: Int64) {
        guard selectedID == meetingID, let language = translationLanguage, let meeting = shownMeeting, meeting.id == meetingID else { return }
        translation.translate(meetingID, source: meeting.transcriptionLocale.language, into: Locale.Language(identifier: language),
                              scope: .changed, quiet: true)
    }

    /// Every meeting is gone (erased, or a backup takes their place, reusing their ids): no translation goes on, and no choice of
    /// language stays.
    func erasedTranslations() {
        translation.stopAll()
        chosenTranslations = [:]
    }
}
