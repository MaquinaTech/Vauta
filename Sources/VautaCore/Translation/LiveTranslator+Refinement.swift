// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Apple translates every caption at once; when the user's model server is
/// usable it translates each FINAL sentence again, with the previous sentences
/// of this meeting's "Others" channel as context. If its version arrives within
/// the budget it replaces Apple's caption in place and becomes the stored
/// translation. On timeout, error or no server Apple's text stays and nothing
/// is raised: the status is a small indicator, never an alert.
///
/// - Sentences are sent in order, at most `Tuning.refineInFlight` at a time;
///   one that waited its whole budget in the queue is dropped.
/// - A pause, a pair change and a hard stop (feature turned off) cancel what is in
///   flight and forget what is queued (the refine epoch makes late answers harmless).
///   The end of a recording only drops what is queued: requests already sent finish
///   in the background, bounded, and are stored (`waitForRefinements()`).
/// - After repeated failures the server is left alone for a while.
/// - Nothing here touches Apple's translation path: captions never wait for it.
extension LiveTranslator {
    /// Keeps the best translation of the last finals, for the context of the next one.
    func recordHistory(lineID: Int, source: String, translation: String) {
        history.removeAll { $0.lineID == lineID }
        history.append((lineID, source, translation))
        if history.count > max(tuning.refineContext, 1) + tuning.retranslateOnChange {
            history.removeFirst(history.count - (max(tuning.refineContext, 1) + tuning.retranslateOnChange))
        }
    }

    func enqueueRefinement(_ item: PendingFinal) {
        guard refiner != nil, !paused, !finished else { return }
        refineQueue.append(RefineItem(key: item.key, lineID: item.lineID, text: item.text,
                                      deadline: ContinuousClock.now + tuning.refineBudget))
        pumpRefinement()
    }

    /// Pause, pair change and a hard stop: whatever is in flight is cancelled and forgotten.
    func cancelRefinement() {
        refineEpoch += 1
        for task in refineTasks.values { task.cancel() }
        for task in lateTasks.values { task.cancel() }
        refineTasks.removeAll()
        lateTasks.removeAll()
        refineQueue.removeAll()
    }

    /// The recording ended: what has not started is dropped, what is in flight is left to finish.
    func dropQueuedRefinements() {
        refineQueue.removeAll()
    }

    /// Returns once every request still running has finished or reached its bound
    /// (`Tuning.refineLateBound`). Only for the code that keeps the translator alive after the stop.
    public func waitForRefinements() async {
        for _ in 0..<64 {
            let running = Array(refineTasks.values) + Array(lateTasks.values)
            if running.isEmpty { return }
            for task in running { await task.value }
        }
    }

    private func pumpRefinement() {
        guard let refiner, let pair else { return }
        while refineTasks.count < max(tuning.refineInFlight, 1), !paused, !finished, !refineQueue.isEmpty {
            let item = refineQueue.removeFirst()
            let now = ContinuousClock.now
            // Waited its whole budget: the caption has been Apple's for too long to swap it now.
            guard item.deadline > now else { continue }
            if let until = refinePausedUntil {
                if now < until { continue }
                refinePausedUntil = nil
            }
            // The context at the moment the request starts: the best text so far of the sentences before this one.
            let context = history.filter { $0.lineID < item.lineID }.suffix(tuning.refineContext)
                .map { TranslationExample(source: $0.source, translation: $0.translation) }
            let e = refineEpoch
            let budget = item.deadline - now
            let language = pair.targetCode
            refineTasks[item.lineID] = Task { [weak self] in
                guard let translator = await refiner(pair) else {
                    await self?.refinementSkipped(item, epoch: e)
                    return
                }
                await self?.refinementStarted(epoch: e)
                let request = Task { try await translator.refine(item.text, context: context) }
                let outcome = await withTaskCancellationHandler {
                    await Self.wait(for: request, within: budget)
                } onCancel: { request.cancel() }
                await self?.refinementFinished(item, language: language, outcome: outcome, request: request, waited: budget, epoch: e)
            }
        }
    }

    private func refinementStarted(epoch e: Int) {
        guard e == refineEpoch else { return }
        if refinement == .off { refinement = .active; markDirty() }
    }

    /// Refinement is off or there is no usable server: Apple's text is final.
    private func refinementSkipped(_ item: RefineItem, epoch e: Int) {
        guard e == refineEpoch else { return }
        refineTasks[item.lineID] = nil
        if refinement != .off { refinement = .off; markDirty() }
        pumpRefinement()
    }

    /// `outcome` is nil when the caption budget ran out before the server answered: the
    /// caption stays Apple's, but the request goes on in the background and its answer is stored.
    private func refinementFinished(_ item: RefineItem, language: String, outcome: RefineOutcome?,
                                    request: Task<String, Error>, waited: Duration, epoch e: Int) async {
        // Cancelled work (pause, pair change, hard stop) was forgotten with its epoch.
        guard e == refineEpoch else { request.cancel(); return }
        refineTasks[item.lineID] = nil
        switch outcome {
        case .cancelled:
            request.cancel()
        case .failed:
            refineFailed()
            request.cancel()
        case .text(let text):
            refineFailures = 0
            refinePausedUntil = nil
            refinement = .improved
            if let index = finals.firstIndex(where: { $0.id == item.lineID }) {
                finals[index].translation = text
                finals[index].isRefined = true
            }
            recordHistory(lineID: item.lineID, source: item.text, translation: text)
            markDirty()
            await onFinal(FinalTranslation(key: item.key, language: language, text: text, isRefined: true, source: item.text))
        case nil:
            // Too late for the caption (it counts as slow for the pacing of requests), still worth keeping.
            refineFailed()
            let remaining = max(tuning.refineLateBound - waited, .zero)
            lateTasks[item.lineID] = Task { [weak self] in
                let late = await withTaskCancellationHandler {
                    await Self.wait(for: request, within: remaining)
                } onCancel: { request.cancel() }
                await self?.lateRefinementFinished(item, language: language, outcome: late, request: request, epoch: e)
            }
        }
        guard e == refineEpoch else { return }
        pumpRefinement()
    }

    private func refineFailed() {
        refineFailures += 1
        if refineFailures >= tuning.refineFailuresBeforePause { refinePausedUntil = ContinuousClock.now + tuning.refinePause }
        if refinement != .unavailable { refinement = .unavailable; markDirty() }
    }

    /// The server answered after the caption budget: the text is stored as the segment's translation
    /// (transcript, export) and the caption on screen is left alone.
    private func lateRefinementFinished(_ item: RefineItem, language: String, outcome: RefineOutcome?,
                                        request: Task<String, Error>, epoch e: Int) async {
        guard e == refineEpoch else { request.cancel(); return }
        lateTasks[item.lineID] = nil
        guard case .text(let text)? = outcome else {
            // Failed, cancelled or past the bound.
            request.cancel()
            return
        }
        recordHistory(lineID: item.lineID, source: item.text, translation: text)
        await onFinal(FinalTranslation(key: item.key, language: language, text: text, isRefined: true, source: item.text))
    }

    enum RefineOutcome: Sendable {
        case text(String)
        case failed
        case cancelled
    }

    /// The outcome of `request`, or nil when `within` runs out first (the request keeps running).
    /// Cancelling the waiting task ends the wait with `.cancelled`.
    static func wait(for request: Task<String, Error>, within: Duration) async -> RefineOutcome? {
        enum Wake: Sendable {
            case outcome(RefineOutcome)
            case timeout
        }
        let (signal, wake) = AsyncStream.makeStream(of: Wake.self, bufferingPolicy: .bufferingOldest(1))
        let work = Task {
            do {
                let text = try await request.value
                wake.yield(.outcome(text.isEmpty ? .failed : .text(text)))
            } catch is CancellationError {
                wake.yield(.outcome(.cancelled))
            } catch {
                wake.yield(.outcome(request.isCancelled ? .cancelled : .failed))
            }
        }
        let timer = Task {
            try? await Task.sleep(for: within)
            wake.yield(.timeout)
        }
        var result = Wake.outcome(.cancelled)
        for await next in signal {
            result = next
            break
        }
        work.cancel()
        timer.cancel()
        switch result {
        case .outcome(let outcome): return outcome
        case .timeout: return nil
        }
    }

    /// The result of `operation`, or `.failed` when `budget` runs out first. The operation is
    /// cancelled then; one that ignores cancellation cannot hold anything up.
    static func race(budget: Duration, _ operation: @escaping @Sendable () async throws -> String) async -> RefineOutcome {
        let request = Task { try await operation() }
        let outcome = await withTaskCancellationHandler {
            await wait(for: request, within: budget)
        } onCancel: { request.cancel() }
        guard let outcome else {
            request.cancel()
            return .failed
        }
        return outcome
    }
}
