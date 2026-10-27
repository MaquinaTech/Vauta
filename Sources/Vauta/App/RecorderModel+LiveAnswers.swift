// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// What the detector reads about the Mac without the main actor: Low Power Mode and heat come from the system when asked; the lag
/// of a transcription channel is set from the recorder.
final class LiveAnswerEnvironmentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lagging: Set<Channel> = []

    func setLagging(_ on: Bool, channel: Channel) {
        lock.withLock { if on { lagging.insert(channel) } else { lagging.remove(channel) } }
    }

    func reset() { lock.withLock { lagging = [] } }

    func current() -> LiveAnswerEnvironment {
        LiveAnswerEnvironment(lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: ProcessInfo.processInfo.thermalState,
                              transcriptionLagging: lock.withLock { !lagging.isEmpty })
    }
}

/// Live answers to the questions heard in the meeting: the recorder hands each final line to a detector and shows what it returns.
extension RecorderModel {
    /// A recording started. The settings are read now (changes apply to the next recording, except the switch, which applies at once).
    func startLiveAnswers(meetingID id: Int64, locale: String) {
        answers.reset()
        liveAnswerEnvironment.reset()
        questionChain = nil
        questionMeetingID = nil
        // The switch and "Keep detected questions" reach a running recording from Settings, a restored backup or anywhere else.
        preferences.liveAnswersChanged = { [weak self] in self?.liveAnswersSettingChanged() }
        guard let llm else { return }
        // The first recording after the feature exists tells the person once, but only where it starts on by itself (decision D1): a
        // person who turned it on in Settings, or a model that starts with it off, needs no hint.
        answers.showsHint = preferences.liveAnswersOnByDefaultUnchosen && !preferences.liveAnswersHintSeen
        answers.onHintAnswered = { [weak self] _ in self?.preferences.liveAnswersHintSeen = true }
        answers.copyProtected = { [weak self] in self?.preferences.copyProtection ?? true }
        answers.onTurnOff = { [weak self] in self?.preferences.liveAnswersEnabled = false }
        answers.onKeep = { [weak self] row, kept in
            guard let id = row.storedID, let store = self?.store else { return }
            Task { try? await store.setQuestionKept(id, kept: kept) }
        }
        answers.onDismiss = { [weak self] row in
            guard let id = row.storedID, let store = self?.store else { return }
            Task { try? await store.setQuestionDismissed(id, dismissed: true) }
        }
        answers.onOpenInAsk = { [weak self] row in self?.openInAsk(row) }
        answers.onOpenMoment = { [weak self] cite in
            guard let self, let meeting = cite.meetingID else { return }
            self.openHistory(meeting: meeting, at: cite.t)
        }
        answers.onOpenDocument = { [weak self] cite in
            guard let citation = cite.documentCitation else { return }
            self?.history?.openDocument(citation)
            self?.showWindow("meetings")
        }
        let box = liveAnswerEnvironment
        runningAnswerSettings = preferences.liveAnswerSettings
        answerBridge?.finish()
        let bridge = LiveAnswersBridge(model: answers, accepting: { [weak self] in self?.preferences.liveAnswersActive ?? false })
        answerBridge = bridge
        let detector = QuestionDetector(backend: llm, store: store, meetingID: id, meetingLocale: locale, settings: preferences.liveAnswerSettings,
                                        environment: { box.current() }, onEvent: bridge.send)
        bridge.detector = detector
        questionDetector = detector
        // Written before anything is stored: a quit before the recording's own cleanup is finished at the next launch.
        questionMeetingID = id
        if !preferences.liveAnswersKeepQuestions { preferences.questionCleanup.add(id) }
    }

    /// The backend whose verdict sets the default: the one that answers, and, with no model ready, the one the settings point to.
    func liveAnswersBackendNow() -> LiveAnswerBackendKind {
        LiveAnswersSync.backend(answering: llm?.liveAnswersBackend(), chat: llmStatus.chatProvider, liveTasks: ModelProviderSettings.liveTasks())
    }

    /// The switch applies at once, and so does keeping the questions (it acts when the recording ends); the other settings wait for the
    /// next recording. Called by `Preferences` whenever either one changes.
    func liveAnswersSettingChanged() {
        guard questionDetector != nil else { return }
        _ = LiveAnswersSync.settingChanged(running: runningAnswerSettings, preferences: preferences, answers: answers, update: applyRunning)
    }

    /// The detector runs with `settings` from now on (the unkept questions of this recording are removed when it ends, if asked).
    private func applyRunning(_ settings: LiveAnswerSettings) {
        guard let detector = questionDetector else { return }
        runningAnswerSettings = settings
        if let id = questionMeetingID {
            if settings.keepDetectedQuestions { preferences.questionCleanup.remove(id) } else { preferences.questionCleanup.add(id) }
        }
        // In the chain of lines, so a line that follows is read with these settings (an unordered task could lose the race).
        let previous = questionChain
        questionChain = Task {
            await previous?.value
            await detector.update(settings: settings)
        }
    }

    /// The model status changed: the model that answers while recording may be another one now (the integrated model finished loading,
    /// or Apple's stands in for it). Settings draws again, and a running recording stops or resumes at once instead of at the next
    /// final line.
    func liveAnswersBackendMayHaveChanged() {
        LiveAnswersSync.backendMayHaveChanged(backend: liveAnswersBackendNow(), last: &lastLiveAnswersBackend,
                                              recording: phase == .recording && questionDetector != nil, running: runningAnswerSettings,
                                              preferences: preferences, answers: answers, update: applyRunning)
    }

    /// The recording ended: the detector drops what is queued and finishes an answer that is under 20 seconds old, apart from the
    /// saving of the meeting.
    func stopLiveAnswers() {
        // The hint is shown until it has been on screen: a recording in which it never left the fold does not use it up.
        if answers.showsHint, answers.hintCountsAsSeen { preferences.liveAnswersHintSeen = true }
        guard let detector = questionDetector else { return }
        questionDetector = nil
        questionChain = nil
        let keep = preferences.liveAnswersKeepQuestions
        let cleanup = questionMeetingID.map { ($0, preferences.questionCleanup) }
        questionMeetingID = nil
        // What the stopped detector still says (a late answer, a withdrawal) is not shown: the card is gone with the recording.
        answerBridge?.finish()
        answerBridge = nil
        answers.reset()
        answers.showsHint = false
        Task {
            await detector.stop(keepQuestions: keep)
            // Its own cleanup has run: the launch pass has nothing to finish for this meeting.
            if let (id, ledger) = cleanup { ledger.remove(id) }
        }
    }

    /// A final line was saved: it goes to the detector in order, once its row id is known (the answer sees the meeting up to it).
    func considerQuestion(liveID: Int, segment: Segment) {
        guard phase == .recording, let detector = questionDetector else { return }
        // The model that answers may have changed in the middle of the meeting (Gemma unavailable, so Apple stands in; or back).
        // The backend is read here too: some fallbacks come with no status change, and Settings must follow them.
        let admitted = LiveAnswersSync.lineArrived(backend: liveAnswersBackendNow(), last: &lastLiveAnswersBackend, running: runningAnswerSettings,
                                                   preferences: preferences, answers: answers, update: applyRunning)
        guard admitted.ingest else { return }
        let pending = writes
        let previous = questionChain
        let line = QuestionLine(channel: segment.channel, start: segment.start, end: segment.end, text: segment.text)
        questionChain = Task { [weak self] in
            await previous?.value
            await pending?.value
            var ready = line
            ready.segmentID = await self?.segmentRowID(liveID)
            await detector.ingest(ready)
        }
    }

    private func segmentRowID(_ liveID: Int) -> Int64? { segmentRowIDs[liveID] }

    /// A question typed in Ask: the same one is not answered again.
    func noteManualQuestion(_ text: String) {
        guard let detector = questionDetector else { return }
        Task { await detector.manualQuestionAsked(text) }
    }

    /// The card's "Open in Ask": the Ask tab of Meetings with the rewritten question and the verified answer already there, with its
    /// citations. No model runs.
    private func openInAsk(_ row: AnswerRow) {
        guard let history, let id = meetingID else { return }
        // The meeting is selected, so the Ask tab shows that it is about this meeting (and a follow-up question is asked about it).
        history.selectedID = id
        history.mode = .ask
        history.ask.meetingID = id
        showWindow("meetings")
        Task { await history.ask.show(stored: row.content, question: row.rewrite.isEmpty ? row.question : row.rewrite, thisMeeting: id) }
    }

    private func openHistory(meeting: Int64, at t: Double?) {
        history?.open(meeting: meeting, at: t)
        showWindow("meetings")
    }
}
