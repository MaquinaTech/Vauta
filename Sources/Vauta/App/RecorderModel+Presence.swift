// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit

/// Calls in meeting apps: the suggestion to record and the hang-up prompt.
extension RecorderModel {
    /// A call in progress that ends for this long while recording asks "Has the meeting ended?".
    static let hangupDelay: Duration = .seconds(30)

    func presenceChanged(_ state: PresenceState) {
        // Presence reports every change; a call is any known meeting app
        // holding the microphone.
        callApp = state.family
        currentCall = state.family.map {
            CallDescription(appName: Self.appName(for: state, family: $0), family: $0, service: nil)
        }
        let inCall = state.family != nil
        guard inCall != callInProgress else { return }
        callInProgress = inCall
        if inCall {
            hangupTimer?.cancel()
            if capture != nil {
                sawCallThisSession = true
                if hangupNotice { hangupNotice = false; notifier.remove(.hangup) }
            } else {
                suggestionDismissed = false
                considerSuggestion()
            }
        } else {
            if suggestion != nil { suggestion = nil; notifier.remove(.suggestion) }
            // Recording: if the app releases the microphone for 30 s, ask (never stop by itself).
            guard phase == .recording, sawCallThisSession else { return }
            hangupTimer?.cancel()
            let appName = recordingApp?.shortName
            hangupTimer = Task { [weak self] in
                try? await Task.sleep(for: Self.hangupDelay)
                guard !Task.isCancelled, let self, self.phase == .recording, !self.callInProgress else { return }
                self.hangupNotice = true
                self.post(.hangup(appName: appName))
            }
        }
    }

    /// The name of the app holding the microphone. Browser helpers (e.g.
    /// `com.apple.WebKit.GPU`) belong to no app: use the running browser of
    /// that family, if exactly one is clear.
    private static func appName(for state: PresenceState, family: MeetingAppFamily) -> String? {
        if let name = CallDescription.appName(bundleID: state.bundleID, family: family) { return name }
        let running = NSWorkspace.shared.runningApplications.compactMap { app -> String? in
            guard let id = app.bundleIdentifier, MeetingAppCatalog.family(forBundleID: id) == family else { return nil }
            return MeetingAppCatalog.app(forBundleID: id)?.name
        }
        let names = Set(running)
        return names.count == 1 ? names.first : nil
    }

    /// Suggests transcribing when a meeting app starts a call; with the
    /// calendar event's title and service when one is in progress. Never
    /// starts recording by itself.
    func considerSuggestion() {
        guard capture == nil, phase == .idle, callInProgress, !suggestionDismissed else { return }
        let event = calendar.currentEvent()
        guard suggestOnCall || event != nil else { return }
        var call = currentCall ?? CallDescription(appName: nil, family: callApp, service: nil)
        call.service = event?.service
        suggestion = RecordingSuggestion(event: event, call: call)
        let title = calendar.showTitleInNotifications ? event?.meeting.title : nil
        post(.suggestion(callDescription: call.sentence, eventTitle: title))
    }

    func acceptSuggestion() {
        guard capture == nil else { return }
        if suggestion == nil {
            let event = calendar.currentEvent()
            var call = currentCall ?? CallDescription(appName: nil, family: callApp, service: nil)
            call.service = event?.service
            suggestion = RecordingSuggestion(event: event, call: call)
        }
        start()
    }

    func dismissSuggestion() {
        suggestion = nil
        suggestionDismissed = true
        notifier.remove(.suggestion)
    }
}

extension RecorderModel {
    /// "Record at Start" was pressed in the brief's notification and the meeting is starting: the usual suggestion, in the panel and as a
    /// notification. It does not record by itself.
    func suggestScheduled(_ event: BriefEvent) {
        guard capture == nil, phase == .idle else { return }
        let call = CallDescription(appName: nil, family: nil, service: event.service)
        suggestion = RecordingSuggestion(event: CalendarEventMatch(meeting: event.calendarMeeting, service: event.service, occurrence: event.occurrence), call: call, scheduled: true)
        post(.suggestion(callDescription: RecordingSuggestion.scheduledSentence, eventTitle: calendar.showTitleInNotifications ? event.title : nil))
    }
}

extension RecorderModel {
    /// The meeting started or its recording began: the brief's notification no longer matters.
    func withdrawBriefNotification() { notifier.remove(.brief) }
}
