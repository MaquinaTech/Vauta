// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// The menu-bar icon: a waveform when idle; a dot and the clock while recording.
struct MenuBarLabel: View {
    let model: RecorderModel
    let preferences: Preferences
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        label
            .accessibilityLabel(Text(verbatim: "Vauta"))
            .accessibilityValue(Text(verbatim: accessibilityValue))
            .task {
                // The menu-bar label is the only view that always exists: it
                // lends the model the window actions (notifications, relock).
                model.openWindowAction = openWindow
                model.dismissWindowAction = dismissWindow
                if preferences.needsOnboarding { openWindow(id: "onboarding") }
            }
    }

    @ViewBuilder private var label: some View {
        switch model.phase {
        case .recording:
            HStack(spacing: 3) {
                if let left = model.autoStopRemaining {
                    // A warning during the countdown stays on the icon: the triangle replaces the timer glyph.
                    Image(systemName: model.hasWarning ? "exclamationmark.triangle.fill" : "timer.circle.fill")
                    // Time left, with a minus sign, so it never reads as the time recorded.
                    Text(verbatim: "\u{2212}" + StopBanner.countdown(left)).monospacedDigit()
                } else {
                    Image(systemName: model.hasWarning ? "exclamationmark.triangle.fill" : model.isPaused ? "pause.circle.fill" : "record.circle.fill")
                    Text(verbatim: model.elapsed).monospacedDigit()
                }
            }
        case .starting, .stopping, .opening:
            // Busy: the waveform pulses, so the item never looks empty while the app is working.
            Image(systemName: "waveform")
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
        case .failed:
            // A failure has its own badge; the exclamation mark is for "needs attention".
            Image(systemName: "waveform.badge.xmark")
        case .idle where model.isReplacingData:
            // A restore or an erase blocks recording like saving does: the same pulse says Vauta is busy.
            Image(systemName: "waveform")
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
        case .idle where model.missingModel != nil && model.speechDownloadProgress != nil:
            // The speech model is downloading: a normal step that is making progress, not a problem. The pulse says that
            // Vauta is busy (the exclamation badge stays for a missing model that is not downloading); VoiceOver says it too.
            Image(systemName: "waveform")
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
        case .idle where model.suggestion == nil && !model.hasWarning && notices > 0:
            // Information waiting in the panel (an automatic stop, an empty recording): a quiet dot, so the icon is not the
            // same as "Ready" for the eyes while VoiceOver says "Ready, 2 notices". It is not the exclamation badge of "needs attention".
            Image(systemName: "waveform")
                .overlay(alignment: .topTrailing) {
                    Circle().frame(width: 4.5, height: 4.5).offset(x: 2, y: -1)
                }
        case .idle:
            Image(systemName: model.suggestion != nil ? "waveform.badge.plus" : model.hasWarning ? "waveform.badge.exclamationmark" : "waveform")
        }
    }

    /// Each information notice (an automatic stop, an empty recording) counts: the panel can show both.
    private var notices: Int { (model.lastStopReason != nil ? 1 : 0) + (model.nothingRecorded ? 1 : 0) + (model.speakersUpdated ? 1 : 0) }

    /// What VoiceOver says about the icon (the render scene shows it beside each state).
    var accessibilityValue: String {
        switch model.phase {
        case .recording:
            if let left = model.autoStopRemaining {
                if model.hasWarning {
                    return String(localized: "Recording, needs attention, stops in \(ElapsedTime.spoken(left))", comment: "Menu-bar icon state for VoiceOver during the automatic-stop countdown with a warning; the argument is the time left")
                }
                return String(localized: "Recording, stops in \(ElapsedTime.spoken(left))", comment: "Menu-bar icon state for VoiceOver")
            }
            if model.isPaused {
                return String(localized: "Paused, \(ElapsedTime.spoken(model.elapsedSeconds))", comment: "Menu-bar icon state for VoiceOver while the recording is paused; the argument is the time on the meeting's clock")
            }
            // The icon turns into a warning triangle: VoiceOver says so too.
            if model.hasWarning {
                return String(localized: "Recording, needs attention, \(ElapsedTime.spoken(model.elapsedSeconds))", comment: "Menu-bar icon state for VoiceOver while recording with a warning; the argument is the elapsed time")
            }
            return String(localized: "Recording, \(ElapsedTime.spoken(model.elapsedSeconds))", comment: "Menu-bar icon state for VoiceOver")
        case .starting: return String(localized: "Starting", comment: "Menu-bar icon state for VoiceOver")
        case .stopping: return String(localized: "Saving the meeting", comment: "Menu-bar icon state for VoiceOver")
        case .opening: return String(localized: "Opening your data", comment: "Menu-bar icon state for VoiceOver while the store of meetings is being opened")
        case .failed:
            // Without the store nothing was recorded: the failure is the store's, not a recording's.
            return model.storeAvailable
                ? String(localized: "Recording failed", comment: "Menu-bar icon state for VoiceOver when the last recording could not be made")
                : String(localized: "Needs attention", comment: "Menu-bar icon state for VoiceOver")
        case .idle where model.isReplacingData:
            return model.isErasing
                ? String(localized: "Erasing your data", comment: "Menu-bar icon state for VoiceOver")
                : String(localized: "Restoring your data", comment: "Menu-bar icon state for VoiceOver")
        case .idle where model.missingModel != nil:
            return model.speechDownloadProgress != nil
                ? String(localized: "Downloading the speech model", comment: "Menu-bar icon state for VoiceOver while the speech model of the recording language downloads")
                : String(localized: "Needs attention", comment: "Menu-bar icon state for VoiceOver")
        case .idle:
            if model.suggestion != nil { return String(localized: "A meeting can be recorded", comment: "Menu-bar icon state for VoiceOver") }
            if model.hasWarning { return String(localized: "Needs attention", comment: "Menu-bar icon state for VoiceOver") }
            return notices > 0 ? String(localized: "Ready, \(notices) notices", comment: "Menu-bar icon state for VoiceOver when the panel has information notices (an automatic stop, an empty recording) and nothing is wrong; the argument is how many")
                : String(localized: "Ready", comment: "Menu-bar icon state for VoiceOver")
        }
    }
}
