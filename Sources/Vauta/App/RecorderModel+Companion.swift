// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit

/// The meeting companion (`CompanionBar`): it opens with each recording when Settings → General says so (on by default), goes
/// when the recording stops, and once closed stays closed for the rest of that recording unless Recording › Show Meeting
/// Companion opens it. Hide Vauta Windows takes it off the screen with the rest; opened on purpose meanwhile, it shows.
extension RecorderModel {
    /// A recording started or ended (`phase`).
    func companionRecordingChanged() {
        if phase == .recording {
            companion.recordingStarted(opensByItself: preferences.showsCompanion)
        } else {
            companion.recordingEnded()
        }
        placeCompanion()
    }

    /// Recording › Show Meeting Companion and Hide Meeting Companion.
    func toggleCompanion() {
        guard phase == .recording else { return }
        if companion.isShown {
            closeCompanion()
        } else {
            companion.open()
            placeCompanion(onPurpose: true)
        }
    }

    /// The bar's close button.
    func closeCompanion() {
        companion.close()
        placeCompanion()
    }

    /// On screen when it should be: not while Vauta's windows are hidden for presenting, unless it was opened on purpose.
    func placeCompanion(onPurpose: Bool = false) {
        if companion.isShown, onPurpose || !concealer.isOn {
            companionWindow.show(model: self) { [weak self] in self?.closeCompanion() }
        } else {
            companionWindow.hide()
        }
    }
}
