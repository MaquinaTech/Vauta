// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import Testing
@testable import Vauta
@testable import VautaCore

/// The meeting companion's window: beside the meeting app on every Space, never taking the front or the keyboard from it, and
/// asking to stay out of screen sharing; its setting is carried by backups.
@MainActor
@Suite("Meeting companion · window")
struct CompanionPanelTests {
    @Test func theCompanionNeverTakesTheFrontOrTheKeyboardAndStaysOutOfScreenSharing() {
        let panel = CompanionPanelController.makeBarePanel()
        #expect(panel.styleMask.contains(.nonactivatingPanel) && panel.styleMask.contains(.borderless))
        #expect(!panel.canBecomeKey && !panel.canBecomeMain, "the meeting app keeps the keyboard")
        #expect(panel.sharingType == .none)
        #expect(panel.level == .floating && panel.isFloatingPanel && !panel.hidesOnDeactivate)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.isMovableByWindowBackground && !panel.isRestorable && !panel.isReleasedWhenClosed)
        #expect(panel.title == CompanionBar.title, "VoiceOver names the window")
    }

    @Test func itsSettingIsOnByDefaultAndCarriedByBackups() {
        let suite = "vauta-companion-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults, legacyInstall: false)
        #expect(preferences.showsCompanion)
        preferences.showsCompanion = false
        #expect(defaults.object(forKey: "showsCompanion") as? Bool == false)
        #expect(BackupPreferences.allowed["showsCompanion"] == .bool)
    }

    @Test func itsDetailsAreFoldedByDefaultAndTheChoiceIsKept() {
        let suite = "vauta-companion-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults, legacyInstall: false)
        #expect(!preferences.companionShowsDetails, "folded, the companion shows no meeting text")
        preferences.companionShowsDetails = true
        #expect(Preferences(defaults: defaults, legacyInstall: false).companionShowsDetails, "kept for the next recordings")
        #expect(BackupPreferences.allowed["companionShowsDetails"] == .bool)
    }

    @Test func theDetailsNeverCoverMoreThanAboutHalfTheScreen() {
        for height in [600.0, 800, 1_000, 1_400, 2_200] {
            let limits = CompanionDetails.limits(screenHeight: height)
            #expect(limits.answer > 80 && limits.notes > 80 && limits.transcript > 60, "each card shows a few lines on \(height)")
            #expect(limits.answer + limits.notes + limits.transcript <= max(360, height * 0.55) + 0.5)
        }
    }
}
