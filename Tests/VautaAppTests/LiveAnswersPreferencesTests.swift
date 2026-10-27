// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

/// The app-level switch the recorder reads: live answers stay off until the person turns them on.
@MainActor
@Suite("Live answers: the switch in Preferences")
struct LiveAnswersPreferencesTests {
    private static let backends: [LiveAnswerBackendKind?] = [.apple, .server, .integrated, nil]

    private func make(_ body: (UserDefaults, Preferences) throws -> Void) rethrows {
        let name = "vauta.test.liveanswers.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults, Preferences(defaults: defaults, legacyInstall: false))
    }

    @Test func withoutAChoiceTheFeatureIsOffForEveryModel() {
        make { defaults, prefs in
            #expect(defaults.object(forKey: Preferences.Keys.liveAnswersEnabled) == nil)
            for backend in Self.backends {
                prefs.liveAnswersBackend = { backend }
                #expect(prefs.liveAnswersEnabled == false, "\(String(describing: backend))")
                #expect(prefs.liveAnswerSettings.enabled == false, "\(String(describing: backend))")
                #expect(prefs.liveAnswersOnByDefaultUnchosen == false, "\(String(describing: backend)): no first-run hint")
            }
        }
    }

    @Test func anExplicitChoiceWinsEitherWay() {
        make { defaults, prefs in
            prefs.liveAnswersBackend = { .integrated }
            prefs.liveAnswersEnabled = true
            #expect(prefs.liveAnswersEnabled && prefs.liveAnswerSettings.enabled)
            #expect(defaults.object(forKey: Preferences.Keys.liveAnswersEnabled) as? Bool == true)
            #expect(prefs.liveAnswersOnByDefaultUnchosen == false, "a person who chose needs no hint")
            prefs.liveAnswersEnabled = false
            #expect(!prefs.liveAnswersEnabled && !prefs.liveAnswerSettings.enabled)
            #expect(Preferences(defaults: defaults, legacyInstall: false).liveAnswersChoice == false, "stored")
        }
    }

    @Test func aRestoredBackupAppliesAfterReload() {
        make { defaults, prefs in
            prefs.liveAnswersBackend = { .integrated }
            defaults.set(true, forKey: Preferences.Keys.liveAnswersEnabled)
            prefs.reloadFromDefaults()
            #expect(prefs.liveAnswersEnabled)
            defaults.removeObject(forKey: Preferences.Keys.liveAnswersEnabled)
            prefs.reloadFromDefaults()
            #expect(prefs.liveAnswersChoice == nil && !prefs.liveAnswersEnabled, "a backup without the key goes back to off")
        }
    }

    // MARK: Apple's on-device model does not offer live answers (decision D16)

    @Test func appleDoesNotOfferLiveAnswersWhateverWasStored() {
        make { defaults, prefs in
            prefs.liveAnswersBackend = { .integrated }
            prefs.liveAnswersEnabled = true
            #expect(prefs.liveAnswersOffered && prefs.liveAnswersActive && prefs.liveAnswerSettings.enabled)
            prefs.liveAnswersBackend = { .apple }
            #expect(!prefs.liveAnswersOffered && !prefs.liveAnswersActive)
            #expect(!prefs.liveAnswerSettings.enabled, "a recording on Apple never runs them")
            #expect(prefs.liveAnswersEnabled && prefs.liveAnswersChoice == true, "the choice is kept")
            #expect(defaults.object(forKey: Preferences.Keys.liveAnswersEnabled) as? Bool == true, "also on disk")
            prefs.liveAnswersBackend = { .server }
            #expect(prefs.liveAnswersActive && prefs.liveAnswerSettings.enabled, "it comes back with a model server")
            prefs.liveAnswersBackend = { .integrated }
            #expect(prefs.liveAnswersActive, "and with the integrated model")
        }
    }

    @Test func theOtherSettingsAreKeptWhileTheyAreNotOffered() {
        make { _, prefs in
            prefs.liveAnswersBackend = { .apple }
            prefs.liveAnswersSensitivity = .high
            prefs.liveAnswersSpeakers = .othersOnly
            prefs.liveAnswersSources = [.thisMeeting]
            prefs.liveAnswersBackend = { .integrated }
            let s = prefs.liveAnswerSettings
            #expect(s.sensitivity == .high && s.speakers == .othersOnly && s.sources == [.thisMeeting])
        }
    }

    @Test func noModelKnownYetDoesNotHideTheSwitches() {
        make { _, prefs in
            prefs.liveAnswersBackend = { nil }
            #expect(prefs.liveAnswersOffered)
        }
    }

    @Test func theFirstRunHintIsNeverShownOnApple() {
        make { _, prefs in
            prefs.liveAnswersBackend = { .apple }
            #expect(!prefs.liveAnswersOnByDefaultUnchosen)
        }
    }

    @Test func theRecorderPicksTheBackendFromTheModelSettings() {
        #expect(LiveAnswerBackendKind.current(chat: .onDevice, liveTasks: .integrated) == .apple)
        #expect(LiveAnswerBackendKind.current(chat: .integrated, liveTasks: .apple) == .apple, "the integrated model with the live tasks on Apple is Apple")
        #expect(LiveAnswerDefaults.offered(.current(chat: .integrated, liveTasks: .apple)) == false)
    }
}
