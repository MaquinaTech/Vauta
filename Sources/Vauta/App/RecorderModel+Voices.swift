// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// Keeping voice data to its rules, whatever the user did in a pane: at launch, once a day and after a restore.
extension RecorderModel {
    private static let voiceReminderNotifiedKey = "voiceReminderNotifiedAt"

    /// Applies the rule for the voice summaries kept with meetings (none while recognition is off, nor in a backup restored
    /// on a Mac where it is off; a few days at most while it is on) and reminds the user, at most once a week, of saved
    /// voices that had no suggestion accepted for a year. The reminder only asks: nothing is deleted without the user.
    func maintainVoices() async {
        guard let store else { return }
        _ = try? await store.enforceKeptVoicePolicy(recognizing: preferences.recognizesVoices)
        guard preferences.voiceReminderSnoozedUntil <= Date.now.timeIntervalSince1970,
              let unused = try? await store.unusedSavedVoices(), !unused.isEmpty else { return }
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: Self.voiceReminderNotifiedKey)
        guard Date.now.timeIntervalSince1970 - last > 7 * 86_400 else { return }
        defaults.set(Date.now.timeIntervalSince1970, forKey: Self.voiceReminderNotifiedKey)
        post(.voicesUnused())
    }
}
