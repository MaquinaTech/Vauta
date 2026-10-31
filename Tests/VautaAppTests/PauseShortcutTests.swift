// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

/// The shortcut that pauses and resumes a recording: its own combination, taken only while recording, and carried by a backup.
@Suite("Recording: the pause shortcut")
@MainActor
struct PauseShortcutTests {
    @Test func everyDefaultShortcutIsItsOwn() {
        let all = [Preferences.defaultRecordHotKey, Preferences.defaultMarkHotKey, Preferences.defaultNoteHotKey,
                   Preferences.defaultPauseHotKey, Preferences.defaultTranslationHotKey]
        for (i, a) in all.enumerated() {
            #expect(!all.enumerated().contains { $0.offset != i && $0.element == a }, "\(GlobalHotKey.displayString(a)) is used twice")
        }
        #expect(!RecorderModel.mayRegister(Preferences.defaultPauseHotKey, besides: [Preferences.defaultPauseHotKey], suspended: false),
                "a combination another Vauta shortcut has is not taken twice")
    }

    @Test func thePauseShortcutIsSavedAndBackedUp() {
        let suite = "vauta-pause-shortcut-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { Issue.record("no defaults"); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults, legacyInstall: false)
        #expect(preferences.pauseHotKey == Preferences.defaultPauseHotKey)
        let other = HotKeyCombo(keyCode: 35, modifiers: 0x1900)
        preferences.pauseHotKey = other
        #expect(Preferences(defaults: defaults, legacyInstall: false).pauseHotKey == other)
        #expect(BackupPreferences.allowed["pauseHotKey"] == .data)
    }
}
