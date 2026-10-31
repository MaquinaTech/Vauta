// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit

/// Recording › Hide Vauta Windows, and the panel's Hide Windows, for sharing the screen in a call: Meetings, Settings and
/// Vauta's other windows, the notepad, the meeting companion and the captions leave the screen while the recording goes on. Nothing of Vauta comes up
/// by itself meanwhile (the notepad when a recording starts, the captions); a window opened on purpose shows as usual. Show
/// Vauta Windows brings back what was on screen, as it was. This doesn't rely on `sharingType`, which macOS no longer
/// guarantees with ScreenCaptureKit.
extension RecorderModel {
    func toggleWindowsHidden() {
        if concealer.isOn { showHiddenWindows() } else { hideWindows() }
    }

    func hideWindows() {
        guard !concealer.isOn else { return }
        // Front to back, so they come back stacked as they were. A minimized window stays in the Dock.
        concealer.conceal(NSApp.orderedWindows.filter { $0.isVisible && DockPresence.shared.isTracked($0) })
        // Closed as its own button does, so what is typed in it stays for when it comes back.
        notepadComesBack = notepadWindow.isVisible
        if notepadComesBack { notepadWindow.hide() }
        liveTranslation.holdsPanelBack = true
        placeCompanion()
        // The menu-bar panel closes, and the app that was in front (the meeting app) has the keyboard back.
        NSApp.deactivate()
    }

    func showHiddenWindows() {
        guard concealer.isOn else { return }
        concealer.reveal()
        liveTranslation.holdsPanelBack = false
        placeCompanion()
        // The notepad comes back to a recording, not after it: once the meeting is saved it has nothing to take.
        if notepadComesBack, phase == .recording, !notepadWindow.isVisible { notepadWindow.show(model: self, takesKeyboard: false) }
        notepadComesBack = false
    }
}
