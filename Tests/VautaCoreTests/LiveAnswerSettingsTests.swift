// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Live answers: settings and policies")
struct LiveAnswerSettingsTests {
    @Test func theProposedDefaultsAreTheOnesOfTheDesign() {
        let s = LiveAnswerSettings()
        #expect(!s.enabled, "every default starts off: whoever builds the settings of a recording chooses")
        #expect(s.sources == .all && s.sensitivity == .standard && s.speakers == .everyone)
        #expect(s.hideWhenAnsweredAloud && s.keepDetectedQuestions)
    }

    @Test func lowPowerModeUsesFewerAnswersAndLeavesThePastMeetingsOut() {
        let s = LiveAnswerSettings().effective(lowPowerMode: true)
        #expect(s.sensitivity == .low && s.sources == [.thisMeeting, .documents])
        #expect(LiveAnswerSettings().effective(lowPowerMode: false) == LiveAnswerSettings())
    }

    @Test func aWarmMacLagAndNoSourcesPauseTheAnswers() {
        let settings = LiveAnswerSettings()
        #expect(LiveAnswerEnvironment().pauseReason(settings: settings) == nil)
        #expect(LiveAnswerEnvironment(lowPowerMode: true).pauseReason(settings: settings) == nil, "Low Power Mode changes the settings, it does not pause")
        #expect(LiveAnswerEnvironment(thermal: .fair).pauseReason(settings: settings) == nil)
        #expect(LiveAnswerEnvironment(thermal: .serious).pauseReason(settings: settings) == .tooWarm)
        #expect(LiveAnswerEnvironment(thermal: .critical).pauseReason(settings: settings) == .tooWarm)
        #expect(LiveAnswerEnvironment(transcriptionLagging: true).pauseReason(settings: settings) == .transcriptBehind)
        var none = settings
        none.sources = []
        #expect(LiveAnswerEnvironment().pauseReason(settings: none) == .noSources)
    }

    @Test func theSourcesRoundTripThroughTheirRawValue() {
        #expect(LiveAnswerSources(rawValue: LiveAnswerSources.all.rawValue) == .all)
        #expect(LiveAnswerSources.all.rawValue == 7)
    }

    @Test func settingsTravelInABackupButTheHintMarkerDoesNot() {
        let keys = BackupPreferences.allowed
        for key in ["liveAnswersEnabled", "liveAnswersSources", "liveAnswersSensitivity", "liveAnswersSpeakers", "liveAnswersHideAnsweredAloud", "liveAnswersKeepQuestions"] {
            #expect(keys[key] != nil, "\(key)")
        }
        #expect(keys["liveAnswersHintSeen"] == nil)
    }
}
