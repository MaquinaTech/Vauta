// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("App: notifications")
struct AppNotificationTests {
    @Test func identifiersKeepThe010NamesAndAreUniquePerMeeting() {
        #expect(AppNotification.Kind.autoStopWarning.rawValue == "vauta.autostop")
        #expect(AppNotification.Kind.hangup.rawValue == "vauta.hangup")
        #expect(AppNotification.Kind.suggestion.rawValue == "vauta.suggestion")
        let a = AppNotification.minutesReady(meetingID: 7, meetingTitle: nil, startedAt: .now)
        let b = AppNotification.minutesReady(meetingID: 8, meetingTitle: nil, startedAt: .now)
        #expect(a.identifier == "vauta.minutes.ready.7")
        #expect(a.identifier != b.identifier)
        #expect(AppNotification.serverUnreachable().identifier == "vauta.server")
        #expect(Set(AppNotification.Kind.allCases.map(\.rawValue)).count == AppNotification.Kind.allCases.count)
    }

    @Test func aLongPauseIsRemindedWithResumeAndStop() {
        let n = AppNotification.pauseReminder(minutes: 15)
        #expect(n.kind == .pauseReminder && n.identifier == "vauta.paused")
        #expect(n.kind.actions == [.resumeRecording, .stopRecording] && n.kind.defaultAction == nil)
        #expect(AppNotification.isAllowed(.pauseReminder, notifyMinutesReady: false, notifyProblems: false), "a prompt about the recording in progress")
        #expect(n.body.contains("15"), "the time in words, in the language of the Mac")
    }

    @Test func actionIdentifiersKeepThe010Names() {
        #expect(AppNotification.Action.keepRecording.rawValue == "keep")
        #expect(AppNotification.Action.stopRecording.rawValue == "stop")
        #expect(AppNotification.Action.transcribe.rawValue == "transcribe")
    }

    @Test(arguments: [
        (AppNotification.Kind.minutesReady, true, false, true),
        (.minutesReady, false, true, false),
        (.minutesFailed, true, false, false),
        (.minutesFailed, false, true, true),
        (.recordingStopped, true, false, false),
        (.serverUnreachable, false, true, true),
        (.suggestion, false, false, true),
        (.autoStopWarning, false, false, true),
        (.hangup, false, false, true),
    ])
    func preferencesGateEachKind(kind: AppNotification.Kind, minutesReady: Bool, problems: Bool, allowed: Bool) {
        #expect(AppNotification.isAllowed(kind, notifyMinutesReady: minutesReady, notifyProblems: problems) == allowed)
    }

    @Test func clickingANotificationDoesTheObviousThing() {
        #expect(AppNotification.Kind.suggestion.defaultAction == .transcribe)
        #expect(AppNotification.Kind.minutesReady.defaultAction == .openMeeting)
        #expect(AppNotification.Kind.minutesFailed.defaultAction == .openMeeting)
        #expect(AppNotification.Kind.serverUnreachable.defaultAction == .showModels)
        #expect(AppNotification.Kind.autoStopWarning.defaultAction == nil)
        #expect(AppNotification.Kind.minutesFailed.actions == [.openMeeting, .retryMinutes])
        #expect(AppNotification.Kind.hangup.actions == [.stopRecording, .keepRecording])
    }

    @Test func minutesNotificationsShowTheTitleOnlyWhenGiven() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let titled = AppNotification.minutesReady(meetingID: 1, meetingTitle: "Budget review", startedAt: start)
        #expect(titled.body.contains("Budget review"))
        #expect(titled.meetingID == 1)
        let untitled = AppNotification.minutesReady(meetingID: 1, meetingTitle: nil, startedAt: start)
        #expect(untitled.body.contains(start.formatted(date: .abbreviated, time: .shortened)))
        let failed = AppNotification.minutesFailed(meetingID: 2, meetingTitle: "", startedAt: start)
        #expect(failed.body.contains(start.formatted(date: .abbreviated, time: .shortened)))
        #expect(!failed.body.contains("“”"))
        #expect(failed.kind == .minutesFailed)
    }

    @Test func notificationsNameTheAppAndTheReason() {
        #expect(AppNotification.hangup(appName: "Zoom").body.contains("Zoom"))
        #expect(!AppNotification.hangup(appName: nil).body.isEmpty)
        let stopped = AppNotification.recordingStopped(.silence(minutes: 5), meetingID: 3)
        #expect(stopped.body.contains("5"))
        #expect(stopped.meetingID == 3)
        #expect(AppNotification.autoStopWarning(secondsLeft: 42).body.contains("42"))
        let suggestion = AppNotification.suggestion(callDescription: "Zoom is using the microphone.", eventTitle: "Standup")
        #expect(suggestion.body.contains("Standup") && suggestion.body.contains("Zoom"))
        #expect(AppNotification.suggestion(callDescription: "Zoom is using the microphone.", eventTitle: nil).body
                == "Zoom is using the microphone.")
    }

    @Test func everyStopReasonExplainsItself() {
        let reasons: [RecordingStopReason] = [.silence(minutes: 3), .screenLocked, .sleep, .userSwitched]
        #expect(Set(reasons.map(\.explanation)).count == reasons.count)
        #expect(reasons.allSatisfy { $0.explanation.hasSuffix(".") })
    }

    @Test func theUnusedVoicesReminderNamesNobodyAndLeadsToTheSpeakersPane() {
        let n = AppNotification.voicesUnused()
        #expect(n.kind == .voicesUnused && n.kind.actions == [.showSpeakers] && n.kind.defaultAction == .showSpeakers)
        #expect(n.meetingID == nil, "no meeting and no person: notifications are stored outside the encrypted store")
        #expect(AppNotification.isAllowed(.voicesUnused, notifyMinutesReady: false, notifyProblems: false) == false)
        #expect(AppNotification.isAllowed(.voicesUnused, notifyMinutesReady: false, notifyProblems: true))
    }
}
