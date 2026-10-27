// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The persistent background queue: embeddings and minutes after each
/// meeting, retries, cancellation and completion events.
extension LLMService {
    /// Consecutive "busy" answers tolerated without counting an attempt.
    static let maxBusyRetries = 10
    /// Attempts (failures that count) before a job fails for good.
    static let maxAttempts = 6

    // MARK: Enqueueing

    /// When a meeting ends: embeddings and minutes. `template` (the default
    /// from Preferences) is stored with the meeting; nil keeps the stored one.
    /// Speakers come first: a meeting whose speakers were not finalized yet (its recording never reached Stop) is
    /// finalized here (or its voice data dropped when that fails or `speakersEnabled` is off), so the minutes are never
    /// written from a transcript the aligner is still going to split.
    public func meetingEnded(_ meetingID: Int64, template: MinutesTemplate? = nil, speakersEnabled: Bool = true,
                             recognizeVoices: Bool = false) async {
        await SpeakerFinalizer.finalizePending(meetingID: meetingID, in: store, enabled: speakersEnabled, recognizeVoices: recognizeVoices)
        if let template { try? await store.setMinutesTemplate(template, for: meetingID) }
        if case .available = providers.embeddings() { try? await store.enqueueJob(.embed, meeting: meetingID) }
        try? await store.enqueueJob(.minutes, meeting: meetingID)
        await queueChanged()
    }

    public func regenerateMinutes(_ meetingID: Int64) async {
        await regenerateMinutes(meetingID, template: nil)
    }

    /// Writes the minutes again; `template` replaces the meeting's template
    /// (nil keeps the stored one, or the general template for older meetings).
    public func regenerateMinutes(_ meetingID: Int64, template: MinutesTemplate?) async {
        if let template { try? await store.setMinutesTemplate(template, for: meetingID) }
        try? await store.enqueueJob(.minutes, meeting: meetingID)
        await queueChanged()
    }

    /// Queues minutes and embeddings for the meetings that do not have them yet.
    /// `template` (the default from Preferences) is stored for meetings that
    /// have none yet (recorded before templates existed).
    public func backfill(template: MinutesTemplate? = nil) async {
        let embeddings = if case .available = providers.embeddings() { true } else { false }
        for id in (try? await store.meetingsWithoutMinutes()) ?? [] {
            if let template, (try? await store.minutesTemplate(id)) == nil {
                try? await store.setMinutesTemplate(template, for: id)
            }
            if embeddings { try? await store.enqueueJob(.embed, meeting: id) }
            try? await store.enqueueJob(.minutes, meeting: id)
        }
        await queueChanged()
    }

    func queueChanged() async {
        status.queued = (try? await store.pendingJobCount()) ?? status.queued
        publish()
        kick()
    }

    // MARK: Cancel

    /// Cancels the meeting's queued or running job of `kind` and emits
    /// `.cancelled` (no-op if there is none). A running request is stopped
    /// (its network request is cancelled) and the job is removed.
    public func cancel(meetingID: Int64, kind: LLMJob.Kind) async {
        if let job = currentJob, job.meetingID == meetingID, job.kind == kind {
            cancelledJobs.insert(job.id)
            backgroundTask?.cancel()   // the queue loop removes it and emits the event
            return
        }
        if (try? await store.removeQueuedJob(meetingID: meetingID, kind: kind)) == true {
            if kind == .minutes { await releaseWarm(meetingID) }
            emit(JobEvent(meetingID: meetingID, kind: kind, outcome: .cancelled))
            await queueChanged()
        }
    }

    func emit(_ event: JobEvent) {
        onJobEvent?(event)
    }

    // MARK: Loop

    public func kick() {
        if status.issue == .keychainLocked || status.searchIssue == .keychainLocked || status.issue == .onDeviceModel(.modelNotReady) {
            refreshProviders()
            publish()
        }
        guard worker == nil, !recording, !externalBusy, !restoring, canRunJobs else { return }
        worker = Task { await self.loop() }
    }

    /// Some provider can work on the queue (minutes need chat; embeddings
    /// can run without it).
    private var canRunJobs: Bool {
        if case .success = providers.chat() { return true }
        if case .available = providers.embeddings() { return true }
        return false
    }

    private func loop() async {
        defer {
            worker = nil
            scheduleWakeup()
        }
        outer: while !recording, !externalBusy, !restoring, canRunJobs {
            guard let job = try? await store.nextJob() else {
                await expandLeftoverNotes()
                break
            }
            currentJob = job
            defer { currentJob = nil }
            // Embedding with the search model waits for a quiet, powered Mac: the job goes back for a while, and the minutes
            // job behind it is not held up.
            if job.kind == .embed, bulkEmbeddingPaused != nil || searchModelRetiring {
                try? await store.markJob(job.id, .queued, retryAt: .now + 120, countAttempt: false)
                await refreshSearchCoverage()
                continue
            }
            do { try await acquire(.background) } catch { break }
            // Cancelled while waiting for the lane: settle it now, even if recording started meanwhile.
            if cancelledJobs.remove(job.id) != nil {
                release()
                await finishCancelled(job)
                continue
            }
            guard !recording, !restoring else { release(); break }
            // A question arrived while waiting for the lane: let it go first.
            if askWaiting > 0 { release(); await Task.yield(); continue }
            let task = Task { try await self.run(job) }
            backgroundTask = task
            let result = await task.result
            backgroundTask = nil
            release()
            status.activity = nil
            status.activityMeeting = nil
            status.activityStarted = nil
            status.progressTokens = 0
            clearProgress()
            switch result {
            case .success:
                cancelledJobs.remove(job.id)   // finished before the cancel reached it
                try? await store.markJob(job.id, .done)
                busyRetries[job.id] = nil
                if status.issue == nil { status.lastError = nil }
                status.busyUntil = nil
                emit(JobEvent(meetingID: job.meetingID, kind: job.kind, outcome: .succeeded))
            case .failure(let error):
                let stop = await handle(error, job: job)
                status.queued = (try? await store.pendingJobCount()) ?? status.queued
                publish()
                if stop { break outer }
            }
            status.queued = (try? await store.pendingJobCount()) ?? status.queued
            publish()
        }
    }

    /// If only deferred jobs are left, wakes up when they are due (no polling).
    private func scheduleWakeup() {
        wakeup?.cancel()
        wakeup = Task {
            guard let next = try? await store.nextJobTime() else { return }
            let wait = max(1, next.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            kick()
        }
    }

    private func finishCancelled(_ job: LLMJob) async {
        try? await store.removeJob(job.id)
        busyRetries[job.id] = nil
        if job.kind == .minutes { await releaseWarm(job.meetingID) }
        emit(JobEvent(meetingID: job.meetingID, kind: job.kind, outcome: .cancelled))
    }

    /// Records a failure and decides when to try again. Returns true when
    /// the rest of the queue should not be tried now (the setup is missing).
    private func handle(_ error: Error, job: LLMJob) async -> Bool {
        if cancelledJobs.remove(job.id) != nil {
            await finishCancelled(job)
            return false
        }
        if error is CancellationError || (error as? URLError)?.code == .cancelled || (job.kind == .embed && searchModelRetiring) {
            // Interrupted (question, recording): back to the queue without waiting or counting an attempt.
            try? await store.markJob(job.id, .queued, countAttempt: false)
            return false
        }
        let llm = (error as? LLMError) ?? (error as? URLError).map { LLMError.network(from: $0) }
        let code = llm.map(JobErrorCode.init) ?? JobErrorCode(error)
        let detail = JobErrorCode.detail(llm ?? error)
        status.lastError = (llm ?? error).localizedDescription
        if case .network = llm { status.reachable = false }

        func retry(after seconds: Double, counting: Bool) async {
            try? await store.markJob(job.id, .queued, code: code, detail: detail, retryAt: .now + seconds, countAttempt: counting)
        }
        func fail() async {
            busyRetries[job.id] = nil
            try? await store.markJob(job.id, .failed, code: code, detail: detail)
            if job.kind == .minutes { await releaseWarm(job.meetingID) }
            emit(JobEvent(meetingID: job.meetingID, kind: job.kind, outcome: .failed(code.localizedDescription)))
        }
        let backoff = min(1800, 60 * pow(2, Double(job.attempts)))

        switch llm {
        case .busy(let seconds)?:
            // "Busy" only needs waiting, but not forever: past the cap each
            // answer counts as a failed attempt with a longer wait.
            let count = (busyRetries[job.id] ?? 0) + 1
            busyRetries[job.id] = count
            if count <= Self.maxBusyRetries {
                status.busyUntil = .now + seconds
                await retry(after: seconds, counting: false)
            } else if job.attempts + 1 < Self.maxAttempts {
                let wait = max(300, backoff)
                status.busyUntil = .now + wait
                status.lastError = String(localized: "The model server has been busy for a long time. Vauta will keep trying every few minutes.",
                                          comment: "Model server status after many busy answers")
                await retry(after: wait, counting: true)
            } else {
                status.busyUntil = nil
                await fail()
            }
            return false
        case .keychainUnavailable?:
            // Locked Mac: wait for it to be unlocked, without using up attempts.
            await retry(after: 60, counting: false)
            return true
        case .notConfigured?, .unauthorized?, .invalidStoredToken?:
            // The user has to fix Settings; `configurationChanged()` kicks the queue.
            await retry(after: 300, counting: false)
            return true
        case .modelUnavailable?, .searchModelUnavailable?:
            // The on-device model is downloading or was turned off.
            await retry(after: 300, counting: false)
            return true
        default:
            if llm?.isRetryable == true && job.attempts + 1 < Self.maxAttempts {
                await retry(after: backoff, counting: true)
            } else {
                await fail()
            }
            return false
        }
    }

    private func run(_ job: LLMJob) async throws {
        try await store.markJob(job.id, .running)
        status.activityMeeting = job.meetingID
        status.activityStarted = .now
        switch job.kind {
        // Generic text: the menu bar panel is not behind Touch ID (no titles).
        case .embed:
            status.activity = String(localized: "Indexing a meeting for Ask", comment: "Model server activity in the menu bar panel")
            publish()
            try await embed(job.meetingID)
            try await embedLinkItems(job.meetingID)
        case .minutes:
            status.activity = String(localized: "Writing minutes", comment: "Model server activity in the menu bar panel")
            publish()
            try await writeMinutes(job.meetingID)
        }
    }

    func progress(_ tokens: Int) {
        guard status.activity != nil, tokens >= status.progressTokens else { return }   // late arrivals
        status.progressTokens = tokens
        publish()
    }
}
