// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import Observation
import ServiceManagement
import SwiftUI

extension RecorderModel {
    // MARK: Recording

    /// Decides by the capture, not by the phase: never leaves an orphan capture. While a start is under way it gives the start
    /// up: it can wait on macOS for long (a permission dialog behind other windows), and nothing else would end it.
    func toggle() {
        if phase == .starting {
            stopRequested = true
            return
        }
        if phase == .stopping || phase == .opening { return }
        if capture != nil { stop() } else { start() }
    }

    /// The record shortcut, pressed in any app: it says what happened, since the panel may not be
    /// in sight. A press while Vauta is busy changes nothing and says why (opening the data, saving the last
    /// meeting); while a start is already under way the press is redundant and answers with the alert sound and says it is starting.
    func toggleFromShortcut() {
        switch phase {
        case .opening: reportStartBlockedByStore()
        case .stopping: reportStartBlockedBySaving()
        case .starting:
            NSSound.beep()
            AccessibilityNotification.Announcement(String(localized: "Starting…", comment: "Record button state")).post()
        default: toggle()
        }
    }

    func start() {
        guard capture == nil, stopTask == nil, phase != .starting, phase != .opening else { return }
        // A restore is replacing the store: a meeting started now would be written into it or lost with it.
        guard !isReplacingData else {
            reportStartBlockedByRestore()
            return
        }
        guard let store else {
            reportStartBlockedByStore()
            openStore()
            return
        }
        // What is still typed in the notepad of the meeting that just ended is saved there first (the draft is never
        // discarded); if that fails the notepad keeps it and the recording does not start over it.
        if notepad.meetingID != nil, notepad.hasPendingWork {
            guard !savingNoteBeforeStart else { return }
            savingNoteBeforeStart = true
            Task {
                let saved = await notepad.flushPending()
                savingNoteBeforeStart = false
                if saved { start() }
            }
            return
        }
        phase = .starting
        resetPanelForNewRecording()
        sawCallThisSession = callInProgress
        // An in-person event on the Next meeting card is the recording's calendar event too: its attendees and series are saved with the
        // meeting, so the next occurrence finds this one.
        let event = suggestion?.event ?? calendar.currentEvent() ?? brief.inPersonEventOnCard()
        brief.recordingStarted(recordingOccurrence: event?.occurrence)
        suggestion = nil
        notifier.remove(.suggestion)
        // macOS must not kill the app with a meeting open (balanced in
        // resetSession, also when the start fails).
        preventSuddenTermination()

        let presence = MeetingPresence.currentState()
        let scope = audioSource.resolved(with: presence)
        let sourceFamily = audioSource.sourceApp(callFamily: presence.family)
        recordingSource = scope
        recordingApp = sourceFamily.map { family in
            let name = currentCall?.family == family ? currentCall?.appName : CallDescription.appName(bundleID: nil, family: family)
            return CallDescription(appName: name, family: family, service: event?.service)
        }
        let capture = MeetingCapture(systemAudioScope: scope)
        capture.onChannelHealth = { [weak self] channel, health in
            Task { @MainActor in self?.update(channel, health) }
        }
        self.capture = capture
        let (stream, input) = AsyncStream.makeStream(of: Segment.self)
        segmentInput = input
        consumer = Task { [weak self] in
            for await segment in stream { self?.receive(segment) }
        }

        Task {
            do {
                let plan = try await languagePlan()
                try checkStopRequested()
                // The meeting is created BEFORE capturing: no segment arrives without one.
                let now = Date.now
                let outputLocale: Locale? = if case .fixed(let id) = preferences.outputLanguage { Locale(identifier: id) } else { nil }
                let id = try await store.startMeeting(at: now, locale: plan.language.locale, outputLocale: outputLocale,
                                                      sourceApp: sourceFamily?.rawValue)
                meetingID = id
                prepareNotepad(meetingID: id)
                UserDefaults.standard.set(id, forKey: Self.recordingMeetingKey)
                recordingLanguage = plan.language
                await history?.refreshActive()
                var attendeeIDs: [Int64] = []
                if let event {
                    do {
                        attendeeIDs = try await store.applyCalendar(event.meeting, to: id)
                        attendees = try await store.meetingEntities(id, role: .attendee)
                    } catch {
                        lastError = String(localized: "The calendar details couldn’t be added. \(error.localizedDescription)",
                                           comment: "Warning while recording; the argument is the error")
                    }
                }
                try checkStopRequested()
                var vocabulary: [String] = []
                if plan.engines.values.contains(.dictation), dictationMe || dictationOthers {
                    let series = try? await store.seriesID(of: id)
                    vocabulary = (try? await store.recognitionVocabulary(attendees: attendeeIDs, seriesID: series ?? nil)) ?? []
                }
                let engines = plan.engines.mapValues { kind -> TranscriptionEngine in
                    kind == .dictation ? .dictation(vocabulary: vocabulary) : .speech
                }
                diarizer = preferences.separateSpeakers ? makeDiarizer(meetingID: id) : nil
                try await startCapture(capture, locale: plan.language.locale, engines: engines, input: input)
                try checkStopRequested()
                startedAt = now
                liveTranslation.recordingStarted(language: plan.language.locale)
                registerMarkHotKey()
                registerNoteHotKey()
                registerPauseHotKey()
                lastOthersHeard = .now
                lastMeHeard = nil
                phase = .recording
                NSSound(named: "Tink")?.play()
                AccessibilityNotification.Announcement(String(localized: "Recording started", comment: "VoiceOver announcement")).post()
                startTicker()
                startAutosave()
                speakersTipDismissed = false
                speakersHeard = false
                lastEchoCheck = nil
                outputWatcher = OutputRouteWatcher { [weak self] route in
                    MainActor.assumeIsolated { self?.outputRoute = route }
                }
                livePoints = []; liveDecisions = []; liveTasks = []; liveNotesError = nil
                lastLiveNotes = .now
                charsSinceLiveNotes = 0
                liveNotesHaveNewText = false
                liveNotesAsked = false
                serverDownNotified = false
                await llm?.setRecording(true, meetingID: id)
                // The recording may have been stopped (and even saved) during that wait: nothing more starts for it.
                guard phase == .recording, meetingID == id else {
                    if meetingID == nil, stopTask == nil { await llm?.setRecording(false, meetingID: nil) }
                    return
                }
                startLiveAnswers(meetingID: id, locale: plan.language.locale.identifier)
                await prepareConsentPrompt(meetingID: id, sourceApp: sourceFamily?.rawValue, language: plan.language.locale)
                // Asked once capture runs, never before: answering the prompt
                // must not delay the start of the meeting.
                Task { await notifier.requestAuthorization() }
            } catch {
                await abortStart(error is StopRequested ? nil : error)
            }
        }
    }

    func stop() {
        guard phase == .recording, stopTask == nil else { return }
        endPauseAtStop()
        phase = .stopping
        // At once, like the start, and not the same sound (told apart by ear when the panel is closed): saving takes seconds.
        // "Bottle" is Live Translation off and an empty recording; "Pop" follows when the meeting is saved.
        NSSound(named: "Submarine")?.play()
        AccessibilityNotification.Announcement(String(localized: "Recording stopped. Saving the meeting.", comment: "VoiceOver announcement")).post()
        ticker?.cancel()
        ticker = nil
        autosave?.cancel()
        outputWatcher = nil
        outputRoute = .unknown
        speakersHeard = false
        stopTask = Task {
            await finishSession()
            stopTask = nil
        }
    }

    /// Quit Vauta (the panel's button and ⌘Q in the open panel). A recording running is stopped and saved by the
    /// termination, so a stray ⌘Q meant for the meeting app behind the panel asks first. Terminations the system
    /// starts (log out, restart) are not asked about: they go straight through `applicationShouldTerminate`.
    func quit() {
        guard confirmQuit() else { return }
        NSApp.terminate(nil)
    }

    /// True when quitting may go on: nothing is recording, or the person chose to stop and quit. The Dock menu and
    /// ⌘Tab → Q ask the same question as ⌘Q and the panel (see `applicationShouldTerminate`).
    func confirmQuit() -> Bool {
        if isRecording {
            let alert = NSAlert()
            alert.messageText = String(localized: "Stop recording and quit?", comment: "Alert title when quitting from the panel during a recording")
            alert.informativeText = String(localized: "The meeting so far is saved.", comment: "Alert text when quitting from the panel during a recording")
            // The safe choice is the default (Return).
            alert.addButton(withTitle: String(localized: "Cancel", comment: "Alert button"))
            alert.addButton(withTitle: String(localized: "Stop and Quit", comment: "Alert button: stops the recording, saves the meeting and quits Vauta"))
            alert.buttons[1].hasDestructiveAction = true
            NSApp.activate()
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
        }
        return true
    }

    /// Start dates of the stored meetings (Settings → Privacy previews what a
    /// shorter retention deletes); nil when the store is not open.
    func meetingStartDates() async -> [Date]? {
        try? await store?.meetings().map(\.startedAt)
    }

    func clearWarnings() {
        lastError = nil
        saveError = nil
        lastStopReason = nil
        nothingRecorded = false
        speakersUpdated = false
        permissionProblem = nil
        missingModel = nil
        if case .failed = phase, store != nil { phase = .idle }
    }

    /// Diagnostics for Settings › Status.
    func storeStats() async -> (fileBytes: Int, journalBytes: Int, meetings: Int, segments: Int)? {
        try? await store?.stats()
    }

    /// Encrypted copies the migration from the earlier version kept (Settings › Status).
    func storeLeftovers() async -> StoreLeftovers? {
        await store?.leftovers()
    }

    /// Deletes those copies. The live store and its key are not touched.
    func deleteStoreLeftovers() async {
        await store?.deleteLeftovers()
    }

    // MARK: Session lifecycle

    struct StopRequested: Error {}

    /// The start can't go on until a speech model is installed (not an error:
    /// the panel offers the download).
    struct ModelMissing: Error {}

    func checkStopRequested() throws {
        if stopRequested { throw StopRequested() }
    }

    /// How long a start may wait on macOS (a permission dialog, a device) before the panel says what it waits for.
    static let startDeadline: Duration = .seconds(60)

    /// Starts the capture, unless the person gives up first (the record button while it starts, quitting) or it is still
    /// waiting at `startDeadline`: then it says which step waits, and the capture is stopped whenever that step ends.
    private func startCapture(_ capture: MeetingCapture, locale: Locale, engines: [Channel: TranscriptionEngine],
                              input: AsyncStream<Segment>.Continuation) async throws {
        let diarizer = diarizer
        do {
            try await GiveUp.run(deadline: Self.startDeadline, abandoned: { [weak self] in await MainActor.run { self?.stopRequested ?? true } },
                                 late: { result in if case .success = result { try? await capture.stop() } }) {
                try await capture.start(locale: locale, engines: engines, diarizer: diarizer) { input.yield($0) }
            }
        } catch let reason as GiveUp.Reason {
            captureLeftStarting = true
            throw reason == .abandoned ? StopRequested() : capture.stalledStartError()
        }
    }

    private func resetPanelForNewRecording() {
        segments = []
        segmentRowIDs = [:]
        volatile = [:]
        volatileSegments = []
        nextSegmentID = 0
        levels = [:]
        elapsedSeconds = 0
        isPaused = false
        lastError = nil
        saveError = nil
        channelWarnings = [:]
        silenceWarning = nil
        captureAlert = nil
        captureAlertCoversSilence = false
        silenceDetector = OthersSilenceDetector()
        lastStopReason = nil
        nothingRecorded = false
        speakersUpdated = false
        resetLiveSpeakers()
        permissionProblem = nil
        missingModel = nil
        showTranscript = false
        stopRequested = false
        captureLeftStarting = false
        sessionLostData = false
        clearConsentPrompt()
        pendingAutoStopAt = nil
        hangupNotice = false
        marks = []
        resetNotepad()
        othersQuery = ""
        othersHits = []
        othersNamed = []
        attendees = []
    }
}
