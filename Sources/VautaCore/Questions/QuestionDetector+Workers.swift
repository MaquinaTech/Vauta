// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// S5 to S7 of the live answers: the model check, the answer and the card rules.
extension QuestionDetector {
    func startCheckWorker() {
        guard checkWorker == nil else { return }
        checkWorker = Task { [weak self] in
            await self?.runChecks()
            await self?.checkWorkerEnded()
        }
    }

    func checkWorkerEnded() {
        checkWorker = nil
        if !checkQueue.isEmpty, running { startCheckWorker() }
    }

    /// Whether work started under `epoch` may go on: the recording runs, the switch is on, the heat has not latched it off and
    /// nothing was cancelled since.
    func mayContinue(epoch started: Int) -> Bool {
        running && !Task.isCancelled && started == epoch && settings.enabled && !latchedOff
    }

    /// Candidates that never reached the check (left the queue, were paused, or the check gave nothing) are not remembered as heard:
    /// a person who asks again because nobody answered is not dropped as a duplicate.
    func forget(_ items: [CheckItem]) {
        for item in items { dedup.forget(text: item.question.candidate.text, locale: meetingLocale) }
    }

    /// One S5 call at a time, at most one per ten seconds and twenty per ten minutes, newest question first in line.
    func runChecks() async {
        while running, !Task.isCancelled {
            let now = clock()
            // The first in line stays there while the rate limit makes it wait: a question that arrives meanwhile queues behind it
            // (and the oldest leaves if the queue is full), nothing is reordered.
            let (waiting, stale) = checkQueue.peek(now: now)
            counters.staleQueued += stale.count
            forget(stale)
            guard waiting != nil else { return }
            let wait = limiter.checkWait(now: now)
            if wait > 0 {
                await sleeper(wait)
                continue
            }
            guard let item = checkQueue.pop(now: now).item else { continue }
            let started = epoch
            guard mayContinue(epoch: started) else { forget([item]); return }
            guard environment().pauseReason(settings: settings.effective(lowPowerMode: environment().lowPowerMode)) == nil else {
                counters.paused += 1
                forget([item])
                continue
            }
            limiter.recordCheck(now: now)
            // Without the check (V0) the candidate's own words are the question.
            guard settings.modelCheck else {
                await afterCheck(QuestionCheck(kind: .information, question: String(item.question.candidate.text.prefix(QuestionCheck.maxQuestionCharacters)), answeredAloud: false), item: item, epoch: started)
                continue
            }
            counters.checks += 1
            let result = await backend.check(item.question.reading(after: heard, limit: timing.checkLinesAfter), meetingID: meetingID)
            // The switch went off, the heat latched it, or the recording ended while the model was reading: nothing is stored or answered.
            guard mayContinue(epoch: started) else { forget([item]); return }
            switch result {
            case .unavailable:
                forget([item])
                emitPause(.modelUnavailable)
            case .failed:
                forget([item])
                counters.checkFailed += 1
            case .timedOut:
                forget([item])
                counters.checkFailed += 1
                counters.checkTimedOut += 1
            case .checked(let check):
                await afterCheck(check, item: item, epoch: started)
            }
        }
    }

    func afterCheck(_ check: QuestionCheck, item: CheckItem, epoch started: Int) async {
        guard check.kind == .information, !check.question.isEmpty else {
            counters.notInformation += 1
            return
        }
        // Heat that turned serious while the model read: paused, nothing is stored.
        guard mayContinue(epoch: started), environment().pauseReason(settings: settings.effective(lowPowerMode: environment().lowPowerMode)) == nil else {
            counters.paused += 1
            forget([item])
            return
        }
        let q = item.question
        // The model judged it a question for the records: it is stored (a row to keep, remove or show on the meeting's page).
        let stored = try? await store?.addDetectedQuestion(DetectedQuestion(meetingID: meetingID, segmentID: q.line.segmentID, t: q.line.start,
                                                                            channel: q.line.channel, text: q.candidate.text, rewrite: check.question,
                                                                            outcome: .noAnswer))
        guard check.proceeds(hideWhenAnsweredAloud: settings.hideWhenAnsweredAloud) else {
            counters.answeredAloud += 1
            record(q, check: check, outcome: .noAnswer, content: nil, shown: false, evidence: item.evidence)
            return
        }
        // Turned off while the question was being stored: its row says stopped and no answer is started.
        guard mayContinue(epoch: started) else {
            if let stored { try? await store?.updateDetectedQuestion(stored, outcome: .stopped, answer: nil, shown: false) }
            counters.stopped += 1
            return
        }
        var answer = AnswerItem(row: UUID(), question: q, check: check, evidence: item.evidence, storedID: stored)
        answer.requeued = false
        let dropped = answerQueue.push(answer, at: q.arrivedAt)
        for old in dropped { await close(old, outcome: .stale) }
        startAnswerWorker()
    }

    func startAnswerWorker() {
        guard answerWorker == nil else { return }
        answerWorker = Task { [weak self] in
            await self?.runAnswers()
            await self?.answerWorkerEnded()
        }
    }

    func answerWorkerEnded() {
        answerWorker = nil
        if !answerQueue.isEmpty, running { startAnswerWorker() }
    }

    /// One answer at a time (S6), then the card rules (S7).
    func runAnswers() async {
        while running, !Task.isCancelled {
            let (next, stale) = answerQueue.pop(now: clock())
            for old in stale { await close(old, outcome: .stale) }
            guard let item = next else { return }
            await answer(item)
        }
    }

    func answer(_ item: AnswerItem) async {
        let q = item.question
        let env = environment()
        let effective = settings.effective(lowPowerMode: env.lowPowerMode)
        // Switched off, latched off by heat, paused (serious heat, a lagging transcript) or finished while it waited in line: not started.
        guard running, settings.enabled, !latchedOff, env.pauseReason(settings: effective) == nil else {
            await close(item, outcome: .stopped, announce: false)
            return
        }
        // The card budget is looked at for the moment the answer would be ready: one that could not be shown by then is not generated
        // (the model's energy is spent on answers that can reach the card).
        if limiter.cardWait(now: clock() + timing.expectedAnswerSeconds, lowPowerMode: env.lowPowerMode) > timing.cardWaitMax {
            await close(item, outcome: .rateLimited, announce: false)
            return
        }
        onEvent(.answering(AnsweringRow(id: item.row, question: q.candidate.text, channel: q.line.channel, t: q.line.start)))
        answerRowInFlight = item.row
        guard let segmentID = q.line.segmentID else {
            answerRowInFlight = nil
            await close(item, outcome: .failed)
            return
        }
        // On the integrated model the past meetings' and documents' passages are added only when the best evidence is not in this meeting.
        let extras = await backend.usesIntegratedModel() ? item.evidence.best != .thisMeeting : true
        // Stopped by the person while the setup was being awaited: the work never starts.
        if cancelledRows.remove(item.row) != nil || !running {
            answerRowInFlight = nil
            await close(item, outcome: .stopped)
            return
        }
        let request = AutoAskRequest(segmentID: segmentID, questionSegments: Set(q.ownSegments), sources: effective.sources,
                                     thisMeetingPassages: item.evidence.thisMeeting, pastPassages: item.evidence.past,
                                     documentPassages: item.evidence.documents, includeExtras: extras,
                                     heard: [q.candidate.text, q.line.text] + q.rephrased, locale: meetingLocale)
        answerStarted = clock()
        let backend = self.backend, meeting = meetingID, rewrite = item.check.question
        let task = Task { try await backend.answer(rewrite, meetingID: meeting, request: request) }
        answerInFlight = task
        let outcome: AutoAnswerOutcome
        do {
            outcome = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch is CancellationError {
            answerInFlight = nil; answerRowInFlight = nil; answerStarted = nil
            // Stopped by the person (✕), by the switch or by the end of the recording: stopped. Only the person's own question in Ask
            // takes the model as a supersede.
            let stopped = cancelledRows.remove(item.row) != nil || !running || !settings.enabled
            await close(item, outcome: stopped ? .stopped : .superseded)
            return
        } catch {
            answerInFlight = nil; answerRowInFlight = nil; answerStarted = nil
            // The model gave the GPU up because the Mac got too warm: the answer stops, it did not fail.
            if environment().pauseReason(settings: effective) == .tooWarm || !running || !settings.enabled || cancelledRows.remove(item.row) != nil {
                await close(item, outcome: .stopped)
                return
            }
            counters.failed += 1
            await close(item, outcome: .failed)
            return
        }
        answerInFlight = nil; answerRowInFlight = nil; answerStarted = nil
        // The person stopped the row just as its answer arrived: it is not shown.
        if cancelledRows.remove(item.row) != nil {
            await close(item, outcome: .stopped, content: outcome.answeredContent)
            return
        }
        switch outcome {
        case .superseded:
            // The person's own question took the model: this one is asked again once if it is still fresh and not the same question.
            // Only the person's own questions count here: the candidate itself is always in `dedup`.
            // A question that arrived meanwhile is newer and keeps the place: the older one is not put back over it.
            if !item.requeued, clock() - q.arrivedAt < timing.requeueWithin, answerQueue.isEmpty,
               !manualDedup.isDuplicate(text: q.candidate.text, locale: meetingLocale, now: clock()) {
                var again = item
                again.requeued = true
                for old in answerQueue.push(again, at: q.arrivedAt) { await close(old, outcome: .stale) }
                onEvent(.withdrawn(item.row))
            } else {
                await close(item, outcome: .superseded)
            }
        case .noAnswer:
            await close(item, outcome: .noAnswer)
        case .answered(let content):
            await show(content, item: item)
        }
    }

    /// S7: the card budget and the age of the answer.
    func show(_ content: AutoAnswerContent, item: AnswerItem) async {
        let q = item.question
        var now = clock()
        // Latched off by critical heat: the answer that finished meanwhile is stored as stopped, never shown.
        guard !latchedOff else {
            await close(item, outcome: .stopped, content: content)
            return
        }
        guard running, settings.enabled else {
            // The recording ended while the answer was being written: it is kept with the meeting, not shown.
            counters.answers += 1
            if let id = item.storedID { try? await store?.updateDetectedQuestion(id, outcome: .answered, answer: content, shown: false) }
            record(q, check: item.check, outcome: .answered, content: content, shown: false, evidence: item.evidence)
            onEvent(.withdrawn(item.row))
            return
        }
        switch QuestionStaleness.classify(age: now - q.arrivedAt, timing: timing) {
        case .dropped:
            await close(item, outcome: .stale, content: content)
            return
        default: break
        }
        let lowPower = environment().lowPowerMode
        let wait = limiter.cardWait(now: now, lowPowerMode: lowPower)
        if wait > timing.cardWaitMax {
            await close(item, outcome: .rateLimited, content: content)
            return
        }
        if wait > 0 {
            waitingRow = item.row
            await sleeper(wait)
            waitingRow = nil
            // Stopped (✕) while it waited: the row is gone from the card and the budget is not spent.
            guard running, settings.enabled, !latchedOff, cancelledRows.remove(item.row) == nil else {
                cancelledRows.remove(item.row)
                await close(item, outcome: .stopped, content: content)
                return
            }
            now = clock()
        }
        let age = now - q.arrivedAt
        if QuestionStaleness.classify(age: age, timing: timing) == .dropped {
            await close(item, outcome: .stale, content: content)
            return
        }
        let shown = content.marked(late: age > timing.lateAfter)
        limiter.recordCard(now: now)
        counters.answers += 1
        counters.shown += 1
        if let id = item.storedID { try? await store?.updateDetectedQuestion(id, outcome: .answered, answer: shown, shown: true) }
        record(q, check: item.check, outcome: .answered, content: shown, shown: true, evidence: item.evidence)
        onEvent(.answer(AnswerRow(id: item.row, storedID: item.storedID, question: q.candidate.text, rewrite: item.check.question, channel: q.line.channel, t: q.line.start, content: shown)))
    }

    /// An answer that ends without a card: the row (if it showed) leaves, and the question keeps its outcome.
    func close(_ item: AnswerItem, outcome: DetectedQuestion.Outcome, content: AutoAnswerContent? = nil, announce: Bool = true) async {
        switch outcome {
        case .noAnswer: counters.noAnswer += 1
        case .superseded: counters.superseded += 1
        case .stale: counters.stale += 1
        case .rateLimited: counters.rateLimited += 1
        case .stopped: counters.stopped += 1
        default: break
        }
        if let id = item.storedID { try? await store?.updateDetectedQuestion(id, outcome: outcome, answer: content, shown: false) }
        record(item.question, check: item.check, outcome: outcome, content: content, shown: false, evidence: item.evidence)
        if announce { onEvent(.withdrawn(item.row)) }
    }

    func record(_ q: SettledQuestion, check: QuestionCheck, outcome: DetectedQuestion.Outcome, content: AutoAnswerContent?, shown: Bool, evidence: QuestionEvidence) {
        log.append(QuestionRecord(text: q.candidate.text, rewrite: check.question, line: q.line, outcome: outcome, arrivedAt: q.arrivedAt, finishedAt: clock(),
                                  shown: shown, content: content, check: check, passing: evidence.passing))
    }

    // MARK: Stop

    /// The recording stopped: what is queued is dropped, an answer that started less than 20 seconds ago may finish, and questions the
    /// person did not want kept go when the setting is off. `keepQuestions` is the person's choice at the moment they stopped: a settings
    /// update sent just before is not guaranteed to have reached the actor yet, so the caller's value wins over the stored one.
    public func stop(keepQuestions: Bool? = nil) async {
        if let keepQuestions { settings.keepDetectedQuestions = keepQuestions }
        running = false
        settleTask?.cancel()
        counters.stopped += flow.stop()
        for item in checkQueue.removeAll() { _ = item; counters.stopped += 1 }
        for item in answerQueue.removeAll() { await close(item, outcome: .stopped) }
        checkWorker?.cancel()
        // A check in flight ends (it may be storing its question) before the unkept ones are removed.
        await checkWorker?.value
        if let started = answerStarted, clock() - started < timing.finishAfterStop, let task = answerInFlight {
            let limit = max(0.1, timing.finishAfterStop - (clock() - started))
            let finisher = Task { [weak self] in
                await self?.sleeper(limit)
                task.cancel()
            }
            _ = await answerWorker?.value
            finisher.cancel()
        } else {
            answerInFlight?.cancel()
            // An answer that waits for the card budget does not hold the end of the recording for up to 30 seconds.
            answerWorker?.cancel()
            _ = await answerWorker?.value
        }
        if !settings.keepDetectedQuestions { try? await store?.removeUnkeptQuestions(meetingID) }
    }

    /// Serious heat: the answer being written is optional work and ends as stopped (the model may have given the GPU up already).
    func cancelAnswerForHeat() {
        guard let row = answerRowInFlight else { return }
        cancelledRows.insert(row)
        answerInFlight?.cancel()
    }

    func cancelEverything(outcome: DetectedQuestion.Outcome, event: Bool) {
        epoch += 1
        _ = flow.stop()
        settleTask?.cancel()
        forget(checkQueue.removeAll())
        checkWorker?.cancel()
        let waiting = answerQueue.removeAll()
        if let row = answerRowInFlight { cancelledRows.insert(row) }
        // A finished answer that waits for the card budget is not shown after this: it closes as stopped.
        if let row = waitingRow { cancelledRows.insert(row) }
        answerInFlight?.cancel()
        if event, let row = answerRowInFlight { onEvent(.withdrawn(row)) }
        // What was queued never got an answer: its stored row says stopped (it was stored as "no answer" while it waited).
        if !waiting.isEmpty {
            Task { [weak self] in
                for item in waiting { await self?.close(item, outcome: .stopped, announce: event) }
            }
        }
    }
}
