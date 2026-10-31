// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// Pausing a recording (`MeetingCapture.pause`): the microphone and the meeting's sound stop being captured and macOS turns the
/// microphone indicator off, while the meeting stays open. The pause is stored with it (`MeetingStore.beginPause`), so its
/// transcript shows where nothing was captured. While paused there are no meters, no silence warnings and no automatic stop;
/// marks and notes still work, and Stop saves the meeting as usual.
extension RecorderModel {
    /// The recording can be paused or resumed now.
    var canTogglePause: Bool { phase == .recording && capture != nil }

    func togglePause() {
        if isPaused { resumeRecording() } else { pauseRecording() }
    }

    /// The pause shortcut from another app: the menu-bar icon shows the pause and VoiceOver says it; a press that can't act
    /// (the recording is starting or stopping) beeps.
    func togglePauseFromShortcut() {
        guard canTogglePause else {
            NSSound.beep()
            return
        }
        togglePause()
    }

    func pauseRecording() {
        guard canTogglePause, !isPaused, let capture, capture.pause() else { return }
        isPaused = true
        // Nothing is heard while paused: no meters frozen at their last level, no warning about a silence Vauta made.
        levels = [:]
        silenceWarning = nil
        captureAlert = nil
        if pendingAutoStopAt != nil {
            pendingAutoStopAt = nil
            autoStopRemaining = nil
            notifier.remove(.autoStopWarning)
        }
        writePause { store, id, at in try await store.beginPause(id, at: at) }
        AccessibilityNotification.Announcement(String(localized: "Recording paused. Nothing is captured until you resume.",
                                                      comment: "VoiceOver announcement when the recording is paused")).post()
    }

    func resumeRecording() {
        guard canTogglePause, isPaused, let capture else { return }
        do {
            try capture.resume()
        } catch {
            // Still paused, with both devices stopped: the person can try again or stop.
            lastError = String(localized: "The recording couldn’t resume: \(Self.describe(error))",
                               comment: "Warning when a paused recording can't capture again; the argument says why (the microphone could not start…)")
            return
        }
        isPaused = false
        // The silences start again from now: the pause never counts towards the automatic stop.
        lastOthersHeard = ContinuousClock.now
        writePause { store, id, at in try await store.endPause(id, at: at) }
        AccessibilityNotification.Announcement(String(localized: "Recording resumed.", comment: "VoiceOver announcement when a paused recording captures again")).post()
    }

    /// At stop: a pause that is on ends where the recording does.
    func endPauseAtStop() {
        guard isPaused else { return }
        isPaused = false
        writePause { store, id, at in try await store.endPause(id, at: at) }
    }

    /// Queues the write behind the segments, at the transcript's time of now. A pause that isn't stored only loses its line in the
    /// transcript, never any of it: the warning says so.
    private func writePause(_ write: @escaping @Sendable (MeetingStore, Int64, Double) async throws -> Void) {
        guard let store, let meetingID else { return }
        let at = currentOffset
        let previous = writes
        writes = Task {
            await previous?.value
            do {
                try await write(store, meetingID, at)
            } catch {
                lastError = saveFailure(String(localized: "The pause couldn’t be saved with the meeting.", comment: "Warning while recording"), error)
            }
        }
    }
}
