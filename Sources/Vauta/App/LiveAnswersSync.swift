// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// What keeps a running recording's live answers in step with the model that answers (decision D16): the recorder calls it, and the
/// tests drive it with a switchable backend.
@MainActor
enum LiveAnswersSync {
    /// Whether the settings the detector runs with are not what the person's choice and the backend say now.
    static func needsSync(running: LiveAnswerSettings?, preferences: Preferences) -> Bool {
        running?.enabled != preferences.liveAnswersActive
    }

    /// The settings the detector should run with now, handed to `update`. The switch applies at once, and so does keeping the
    /// questions; the other settings stay as the recording started with them. Not on Apple's on-device model, whatever the person
    /// chose: the choice stays stored and applies again when the model that answers offers live answers. When it stops, the card is
    /// cleared and the first-run hint goes (it is used up only when the person turned the switch off, not when the backend did).
    static func settingChanged(running: LiveAnswerSettings?, preferences: Preferences, answers: LiveAnswersModel,
                               update: (LiveAnswerSettings) -> Void) -> LiveAnswerSettings {
        var settings = running ?? preferences.liveAnswerSettings
        settings.enabled = preferences.liveAnswersActive
        settings.keepDetectedQuestions = preferences.liveAnswersKeepQuestions
        update(settings)
        if !settings.enabled {
            answers.reset()
            if answers.showsHint {
                answers.showsHint = false
                if !preferences.liveAnswersEnabled { preferences.liveAnswersHintSeen = true }
            }
        }
        return settings
    }

    /// The model that answers may have changed (status change, or "While recording" saved). Settings draws again when the backend really
    /// changed, and a running recording stops or resumes at once instead of at the next final line. Returns the settings now running
    /// when the detector was brought in step.
    @discardableResult
    static func backendMayHaveChanged(backend: LiveAnswerBackendKind, last: inout LiveAnswerBackendKind?, recording: Bool,
                                      running: LiveAnswerSettings?, preferences: Preferences, answers: LiveAnswersModel,
                                      update: (LiveAnswerSettings) -> Void) -> LiveAnswerSettings? {
        guard backend != last else { return nil }
        last = backend
        preferences.liveAnswersBackendTick += 1
        guard recording else { return nil }
        return settingChanged(running: running, preferences: preferences, answers: answers, update: update)
    }

    /// What happens at a final line: the backend may have changed since the recording started (so the detector is brought in step),
    /// and the line is handed to the detector only when live answers are active. Returns the settings now running and whether to ingest.
    static func admit(running: LiveAnswerSettings?, preferences: Preferences, answers: LiveAnswersModel,
                      update: (LiveAnswerSettings) -> Void) -> (settings: LiveAnswerSettings?, ingest: Bool) {
        var now = running
        if needsSync(running: running, preferences: preferences) {
            now = settingChanged(running: running, preferences: preferences, answers: answers, update: update)
        }
        return (now, preferences.liveAnswersActive)
    }

    /// A final line arrived: the backend is read first (a fallback can happen with no status change, such as the engine marking the
    /// integrated model damaged), so Settings and `last` follow it, and then the line is admitted as `admit` says.
    static func lineArrived(backend: LiveAnswerBackendKind, last: inout LiveAnswerBackendKind?, running: LiveAnswerSettings?,
                            preferences: Preferences, answers: LiveAnswersModel,
                            update: (LiveAnswerSettings) -> Void) -> (settings: LiveAnswerSettings?, ingest: Bool) {
        let changed = backendMayHaveChanged(backend: backend, last: &last, recording: true, running: running, preferences: preferences,
                                            answers: answers, update: update)
        return admit(running: changed ?? running, preferences: preferences, answers: answers, update: update)
    }

    /// The backend the recorder reports: the one that really answers, and, with no model ready (or none that can), the one the
    /// settings point to.
    static func backend(answering: LiveAnswerBackendKind?, chat: ModelProviderSettings.Chat,
                        liveTasks: ModelProviderSettings.LiveTasks) -> LiveAnswerBackendKind {
        answering ?? LiveAnswerBackendKind.current(chat: chat, liveTasks: liveTasks)
    }
}
