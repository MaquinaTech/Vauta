// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit

/// Ending a recording: stop, abort, quit and the emergency save.
extension RecorderModel {
    /// The single way out (menu, ⌘Q, log out, shut down, SIGTERM): stops the
    /// recording if any, waits until everything is written, and saves.
    func shutdown() async {
        // Edits typed in Meetings in the last moments are written first.
        await history?.flushDrafts()
        // Notes typed in the floating notepad after a stop are saved too, and every queued note write is waited for.
        await notepad.flushPending()
        if phase == .starting {
            stopRequested = true
            while phase == .starting { try? await Task.sleep(for: .milliseconds(50)) }
        }
        if phase == .recording { stop() }
        await stopTask?.value
        await writes?.value
        // The documents index is saved before the store is (it is derived data: at worst one batch of files is read again).
        await documents?.stop()
        try? await store?.flush()
    }

    /// Last resort when the orderly quit takes too long: waits (with a cap)
    /// for the pending write chain and flushes what is there.
    func emergencySave(within budget: Duration) async {
        let deadline = ContinuousClock.now + budget
        let writes = writes
        let store = store
        await waitAtMost(until: deadline) {
            await writes?.value
            try? await store?.flush()
        }
    }

    /// Runs `work` and returns when it finishes or at `deadline`, whichever
    /// comes first; `work` goes on in the background if it didn't finish.
    private func waitAtMost(until deadline: ContinuousClock.Instant, _ work: @escaping @Sendable () async -> Void) async {
        let once = ResumeOnce()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Task.detached {
                await work()
                if once.claim() { done.resume() }
            }
            Task.detached {
                try? await Task.sleep(until: deadline)
                if once.claim() { done.resume() }
            }
        }
    }


    func abortStart(_ error: Error?) async {
        // The recording never began (the panel says the start was cancelled or failed): what was transcribed while the
        // capture was starting is not kept. Only a start still in progress; a running recording is never discarded.
        let discardCaptured = phase == .starting
        // A start given up while it still waits on macOS is stopped when that call returns (`startCapture`): stopping it here
        // would wait on the same call.
        if !captureLeftStarting { try? await capture?.stop() }
        segmentInput?.finish()
        await consumer?.value
        segmentInput = nil
        consumer = nil
        // Live answers started with the recording: the detector stops with it.
        stopLiveAnswers()
        // The recording was abandoned: nothing the diarizer analysed is kept. It stops at once (it hands nothing more to
        // the sink), what it already spooled is dropped and the recorder forgets it, so a save that was already queued
        // finds no diarizer and does nothing.
        let hadDiarizer = diarizer != nil
        diarizer?.cancel()
        diarizer = nil
        _ = windowSpool.take()
        let lateTarget = beginEndedTranslationTarget()
        await liveTranslation.recordingEnded()
        await writes?.value
        writes = nil
        lateTarget?.complete(meetingID: meetingID, rows: segmentRowIDs)
        if hadDiarizer, let store, let id = meetingID { try? await store.deleteDiarizationWindows(meetingID: id) }
        if discardCaptured, let store, let id = meetingID {
            try? await store.discardTranscript(ofActiveMeeting: id)
            segments = []
            volatile = [:]
            volatileSegments = []
        }
        // endMeeting closes the meeting (or removes it when empty) and saves.
        if let store, let id = meetingID, (try? await store.endMeeting(id, at: .now)) != nil {
            UserDefaults.standard.removeObject(forKey: Self.recordingMeetingKey)
        }
        resetSession()
        brief.recordingDiscarded()
        switch error {
        case nil, is ModelMissing:
            phase = .idle
        case let error?:
            permissionProblem = SystemPrivacyPane(for: error)
            phase = .failed(Self.describe(error, inPanel: true))
        }
        reportStartFailure(error)
        await history?.refreshActive()
    }

    /// A start that failed says so beyond the panel, which may be closed (the record shortcut
    /// from another app): the alert sound, a VoiceOver announcement and, when Vauta is not the
    /// app in front, a notification with the reason and the way to fix it.
    private func reportStartFailure(_ error: Error?) {
        guard let error else { return }   // the user cancelled the start
        let kind: AppNotification.Kind
        let reason: String
        if error is ModelMissing, let missing = missingModel {
            kind = .startNeedsModel
            let language = missing.language.displayName
            reason = speechDownloadProgress != nil
                // The model is on its way (started in setup or Settings): say so instead of "isn’t installed".
                ? String(localized: "Downloading the \(shortLanguageName(missing.language, inSentence: true)) speech model…")
                : missing.engines.contains(.speech)
                ? String(localized: "The speech model for \(language) isn’t installed.", comment: "Capture error; the argument is a language name")
                : String(localized: "The dictation model for \(language) isn’t installed.", comment: "Capture error; the argument is a language name")
        } else {
            kind = permissionProblem == nil ? .startFailed : .startBlocked
            reason = Self.describe(error)
        }
        announceStartFailure(kind, reason: reason)
    }

    /// The same for a start that never began, because the store isn't open (still opening, or it failed).
    func reportStartBlockedByStore() {
        let reason: String
        if case .failed(let why) = phase { reason = why } else {
            reason = String(localized: "Vauta is still opening your data.", comment: "Why a recording didn’t start: the encrypted store isn’t open yet")
        }
        announceStartFailure(.startFailed, reason: reason)
    }

    /// The same for a start while the last meeting is still being saved.
    func reportStartBlockedBySaving() {
        announceStartFailure(.startFailed, reason: String(localized: "Vauta is still saving the last meeting. Try again in a moment.",
                                                           comment: "Why a recording didn’t start: the previous meeting is still being saved"))
    }

    /// The same for a start while a backup is being restored or all data is being erased.
    func reportStartBlockedByRestore() {
        let reason = isErasing
            ? String(localized: "Vauta is erasing your data. Try again when it finishes.",
                     comment: "Why a recording didn’t start: Erase Everything is running")
            : String(localized: "Vauta is restoring your meetings. Try again when it finishes.",
                     comment: "Why a recording didn’t start: a backup is being restored")
        announceStartFailure(.startFailed, reason: reason)
    }

    private func announceStartFailure(_ kind: AppNotification.Kind, reason: String) {
        NSSound(named: "Basso")?.play()
        AccessibilityNotification.Announcement(
            String(localized: "Recording didn’t start. \(reason)", comment: "VoiceOver announcement; the argument says why")).post()
        if !NSApp.isActive { post(.startFailed(kind, reason: reason)) }
    }

    /// Deadlines of the steps of saving a meeting that depend on work outside the store (finalizing the transcription
    /// has its own, in `SpeechAnalyzerSession`).
    static let diarizationFinishSeconds = 120.0
    static let speakerFinalizeSeconds = 180.0

    func finishSession() async {
        var problems: [String] = []
        let endOffset = currentOffset
        // The microphone and the system audio stop first: once the user hears that the recording stopped, nothing more
        // they say may reach the meeting, however long the note below takes to save.
        do {
            try await capture?.stop()
        } catch {
            problems.append(Self.describe(error))
        }
        // A note being typed (or an edit with ↑) when the recording ends is saved next, while the meeting is known, at
        // the end of the recording. If it cannot be saved the text stays in the notepad and the failure is shown.
        notepad.offset = { endOffset }
        await notepad.flushPending()
        // capture.stop() waits for the last results: all have been emitted.
        segmentInput?.finish()
        await consumer?.value
        segmentInput = nil
        consumer = nil
        // The audio is over: the diarizer analyses what it still holds (it never waited for the transcript).
        // With a deadline: a diarizer that never finishes must not keep the meeting in "Saving" (it is cancelled and the
        // meeting is saved without separated speakers).
        var diarization: DiarizationRun?
        if let diarizer {
            do {
                diarization = try await withDeadline(seconds: Self.diarizationFinishSeconds) { await diarizer.finish() }
            } catch {
                diarizer.cancel()
            }
        }
        if let id = meetingID { saveSpooledWindows(meetingID: id) }
        // The last sentences get a moment to be translated; their rows are queued before the writes are awaited.
        let lateTarget = beginEndedTranslationTarget()
        await liveTranslation.recordingEnded()
        await writes?.value
        writes = nil
        stopLiveAnswers()
        // Speakers next: the segments are all saved and nothing else has touched them yet. A late translation is
        // stored only after this (the target is completed below), so it is never cut by a split.
        // Also with a deadline; past it the speakers are written in the background and the meeting is saved now.
        let run = diarization
        await waitAtMost(until: .now + .seconds(Self.speakerFinalizeSeconds)) { await self.finalizeSpeakers(run: run) }
        lateTarget?.complete(meetingID: meetingID, rows: segmentRowIDs)
        await autosave?.value
        autosave = nil
        liveNotesTask?.cancel()
        liveNotesTask = nil
        liveNotesToken = nil
        liveNotesRunning = false
        liveNotesAsked = false
        noteExpansionTask?.cancel()
        noteExpansionTask = nil
        noteExpansionToken = nil
        noteRecheck?.cancel()
        let endedID = meetingID
        var removedEmpty = false
        if let store, let id = meetingID {
            do {
                // Over headphones the microphone never heard the others: no line of the user's is an echo of them.
                let heard = capture?.speakerEcho()
                removedEmpty = try await store.endMeeting(id, at: .now, marksEchoes: heard?.neverHeard != true) == false
                UserDefaults.standard.removeObject(forKey: Self.recordingMeetingKey)
                saveError = nil
            } catch {
                problems.append(saveFailure(String(localized: "The meeting couldn’t be saved.", comment: "Error at stop"), error))
                sessionLostData = true
            }
        }
        resetSession()
        if problems.isEmpty && !sessionLostData {
            segments = []   // already in the encrypted store
            elapsedSeconds = 0
            marks = []
            othersNamed = []
            resetLiveSpeakers()
            attendees = []
            othersQuery = ""
        } else if !problems.isEmpty {
            lastError = problems.joined(separator: "\n")
        }
        showTranscript = false
        phase = .idle
        let kept: Int64? = if let endedID, !removedEmpty, let store, (try? await store.meeting(endedID)) != nil { endedID } else { nil }
        notepadRecordingEnded(meetingID: kept, endOffset: endOffset)
        // The meeting keeps the brief it was started with (references and the verified agenda only).
        await brief.recordingEnded(meetingID: kept)
        let clean = problems.isEmpty && !sessionLostData
        // An empty recording leaves no meeting: say so (a neutral sound, the announcement and a notice in the panel)
        // instead of reporting a save that did not happen.
        nothingRecorded = clean && removedEmpty
        NSSound(named: !clean ? "Basso" : removedEmpty ? "Bottle" : "Pop")?.play()
        AccessibilityNotification.Announcement(
            !clean ? String(localized: "The meeting couldn’t be saved completely.", comment: "VoiceOver announcement when saving a recording had problems")
                : removedEmpty ? Self.nothingRecordedMessage
                : String(localized: "Meeting saved.", comment: "VoiceOver announcement after a recording is saved")).post()
        await llm?.setRecording(false, meetingID: nil)
        if let endedID, let store, (try? await store.meeting(endedID)) != nil {
            await llm?.meetingEnded(endedID, template: preferences.minutesTemplate, speakersEnabled: preferences.separateSpeakers,
                                   recognizeVoices: preferences.recognizesVoices)   // embeddings + minutes
        }
        await history?.reloadIfShowing()
    }

    /// Said when a recording ended with nothing in it, so no meeting exists to find in Meetings.
    static var nothingRecordedMessage: String {
        String(localized: "Nothing was recorded, so no meeting was saved.", comment: "VoiceOver announcement and panel notice after a recording with no speech, notes or marks")
    }

    func resetSession() {
        capture = nil
        isPaused = false
        diarizer = nil
        _ = windowSpool.take()
        meetingID = nil
        volatile = [:]
        volatileSegments = []
        levels = [:]
        startedAt = nil
        channelWarnings = [:]
        silenceWarning = nil
        captureAlert = nil
        captureAlertCoversSilence = false
        pendingAutoStopAt = nil
        autoStopRemaining = nil
        hangupNotice = false
        hangupTimer?.cancel()
        recordingLanguage = nil
        clearConsentPrompt()
        recordingSource = nil
        recordingApp = nil
        markHotKey = nil   // the mark shortcut is only taken while recording
        markHotKeyAvailable = false
        noteHotKey = nil
        noteHotKeyAvailable = false
        pauseHotKey = nil
        pauseHotKeyAvailable = false
        notifier.remove(.autoStopWarning)
        notifier.remove(.hangup)
        allowSuddenTermination()
    }

    func preventSuddenTermination() {
        guard !suddenTerminationDisabled else { return }
        suddenTerminationDisabled = true
        ProcessInfo.processInfo.disableSuddenTermination()
    }

    func allowSuddenTermination() {
        guard suddenTerminationDisabled else { return }
        suddenTerminationDisabled = false
        ProcessInfo.processInfo.enableSuddenTermination()
    }

    /// An error as one or two sentences: what happened and what to do.
    /// `inPanel` is the banner, where the Open System Settings button is beside the text and a short path is enough.
    static func describe(_ error: Error, inPanel: Bool = false) -> String {
        if let capture = error as? CaptureError, capture.code == .microphonePermissionDenied {
            return inPanel ? CaptureError.microphoneDeniedPanelMessage : CaptureError.microphoneDeniedMessage
        }
        var suggestion = (error as? LocalizedError)?.recoverySuggestion
        if inPanel, let capture = error as? CaptureError, capture.code == .systemAudioTapFailed || capture.code == .systemAudioStartFailed {
            suggestion = CaptureError.systemAudioDeniedPanelMessage
        }
        return [error.localizedDescription, suggestion].compactMap { $0 }.joinedAsSentences()
    }
}

/// Resumes a continuation once between two racing tasks.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
