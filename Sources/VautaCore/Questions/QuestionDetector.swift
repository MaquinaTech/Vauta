// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What the detector needs from the model side. `LLMService` is the real one; tests and the evaluation use their own.
public protocol LiveAnswerBackend: Sendable {
    func modelAvailable() async -> Bool
    func usesIntegratedModel() async -> Bool
    /// `embed`: whether the search model may embed the question (false when the check budget is already spent).
    func evidence(text: String, locale: String, meetingID: Int64, segmentID: Int64?, sources: LiveAnswerSources, embed: Bool) async -> QuestionEvidence
    func check(_ question: SettledQuestion, meetingID: Int64) async -> QuestionCheckResult
    func answer(_ rewrite: String, meetingID: Int64, request: AutoAskRequest) async throws -> AutoAnswerOutcome
}

extension LLMService: LiveAnswerBackend {
    public func modelAvailable() async -> Bool { liveAnswersModelAvailable() }
    public func usesIntegratedModel() async -> Bool { liveAnswersUseIntegratedModel() }
    public func evidence(text: String, locale: String, meetingID: Int64, segmentID: Int64?, sources: LiveAnswerSources, embed: Bool) async -> QuestionEvidence {
        await questionEvidence(text: text, locale: locale, meetingID: meetingID, segmentID: segmentID, sources: sources, embed: embed)
    }
    public func check(_ question: SettledQuestion, meetingID: Int64) async -> QuestionCheckResult {
        await checkQuestion(question, meetingID: meetingID)
    }
    public func answer(_ rewrite: String, meetingID: Int64, request: AutoAskRequest) async throws -> AutoAnswerOutcome {
        try await autoAnswer(rewrite, meetingID: meetingID, request: request)
    }
}

/// A row of the panel's Answers card: the question being answered.
public struct AnsweringRow: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// The words that were transcribed.
    public let question: String
    public let channel: Channel
    /// Seconds into the meeting.
    public let t: Double

    public init(id: UUID = UUID(), question: String, channel: Channel, t: Double) {
        self.id = id
        self.question = question
        self.channel = channel
        self.t = t
    }
}

/// A row of the card with its verified answer.
public struct AnswerRow: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let storedID: Int64?
    public let question: String
    public let channel: Channel
    public let t: Double
    public let content: AutoAnswerContent
    /// The standalone question the model wrote from the words (what "Open in Ask" asks); empty when there is none.
    public let rewrite: String
    public var late: Bool { content.late }

    public init(id: UUID = UUID(), storedID: Int64? = nil, question: String, rewrite: String = "", channel: Channel, t: Double, content: AutoAnswerContent) {
        self.rewrite = rewrite
        self.id = id
        self.storedID = storedID
        self.question = question
        self.channel = channel
        self.t = t
        self.content = content
    }
}

/// What the detector tells the panel.
public enum LiveAnswerEvent: Sendable, Equatable {
    case answering(AnsweringRow)
    case answer(AnswerRow)
    /// An answering row ends without a card (no answer, superseded, stopped, too late).
    case withdrawn(UUID)
    case paused(LiveAnswerPause?)
}

/// Counters of what each stage did, for the diagnostics and the evaluation. No text.
public struct QuestionCounters: Sendable, Equatable, Codable {
    public var lines = 0, candidates = 0, duplicates = 0, noEvidence = 0, paused = 0, queued = 0, staleQueued = 0
    /// S4 embeddings by the search model, and the candidates kept on keywords because the check budget was spent.
    public var embeddings = 0, embeddingsSkipped = 0
    public var checks = 0, checkFailed = 0, checkTimedOut = 0, notInformation = 0, answeredAloud = 0
    public var answers = 0, noAnswer = 0, superseded = 0, stale = 0, rateLimited = 0, shown = 0, stopped = 0, failed = 0
    public init() {}
}

/// The live answers of one recording: S1 to S7 of the design. Runs off the main actor; the recorder only hands it the final lines.
public actor QuestionDetector {
    struct CheckItem: Sendable {
        let question: SettledQuestion
        let evidence: QuestionEvidence
    }

    struct AnswerItem: Sendable {
        let row: UUID
        let question: SettledQuestion
        let check: QuestionCheck
        let evidence: QuestionEvidence
        let storedID: Int64?
        var requeued = false
    }

    let backend: any LiveAnswerBackend
    let store: MeetingStore?
    let meetingID: Int64
    let meetingLocale: String
    var settings: LiveAnswerSettings
    let timing: QuestionTiming
    let clock: @Sendable () -> Double
    let sleeper: @Sendable (Double) async -> Void
    let environment: @Sendable () -> LiveAnswerEnvironment
    var onEvent: @Sendable (LiveAnswerEvent) -> Void

    var flow: QuestionFlow
    var limiter: QuestionLimiter
    var dedup: QuestionDedup
    /// What the person typed in Ask: a heard question that is superseded by a manual one is asked again only if it is not the same.
    var manualDedup: QuestionDedup
    /// Rows the person stopped (✕ on "Finding an answer"), and the one the switch cancelled: their answer closes as stopped.
    var cancelledRows: Set<UUID> = []
    var recheckingPause = false
    /// The last final lines in order, for the lines a check reads after its question (see `SettledQuestion.reading(after:limit:)`).
    var heard: [QuestionLine] = []
    var checkQueue: QuestionQueue<CheckItem>
    var answerQueue: QuestionQueue<AnswerItem>
    public internal(set) var counters = QuestionCounters()
    var settleTask: Task<Void, Never>?
    /// Settled questions whose evidence or queueing is still being worked on.
    var handling = 0
    /// Nothing is waiting to settle, being looked at, queued or being answered: what is going to happen has happened. Tests wait for it
    /// before asserting that nothing happened.
    var isIdle: Bool {
        handling == 0 && flow.nextDeadline == nil && checkQueue.isEmpty && answerQueue.isEmpty && checkWorker == nil && answerWorker == nil
    }
    var checkWorker: Task<Void, Never>?
    var answerWorker: Task<Void, Never>?
    var running = true
    /// Raised by every cancel-everything: a model check that started before it ends without storing or answering.
    var epoch = 0
    /// The row whose finished answer waits for the card budget (✕ on it is seen by the detector).
    var waitingRow: UUID?
    /// Critical heat: off until the recording ends.
    var latchedOff = false
    var lastPause: LiveAnswerPause?
    var answerStarted: Double?
    var answerRowInFlight: UUID?
    var answerInFlight: Task<AutoAnswerOutcome, Error>?
    /// Every outcome with the clock time of the question's arrival (the evaluation reads the latency from these).
    public internal(set) var log: [QuestionRecord] = []

    public struct QuestionRecord: Sendable, Equatable {
        public var text: String
        public var rewrite: String
        public var line: QuestionLine
        public var outcome: DetectedQuestion.Outcome
        public var arrivedAt: Double
        public var finishedAt: Double
        public var shown: Bool
        public var content: AutoAnswerContent?
        public var check: QuestionCheck?
        public var passing: LiveAnswerSources
    }

    public init(backend: any LiveAnswerBackend, store: MeetingStore?, meetingID: Int64, meetingLocale: String, settings: LiveAnswerSettings,
                timing: QuestionTiming = QuestionTiming(),
                clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
                sleeper: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
                environment: @escaping @Sendable () -> LiveAnswerEnvironment = { LiveAnswerEnvironment() },
                onEvent: @escaping @Sendable (LiveAnswerEvent) -> Void = { _ in }) {
        self.backend = backend
        self.store = store
        self.meetingID = meetingID
        self.meetingLocale = meetingLocale
        self.settings = settings
        self.timing = timing
        self.clock = clock
        self.sleeper = sleeper
        self.environment = environment
        self.onEvent = onEvent
        let effective = settings.effective(lowPowerMode: environment().lowPowerMode)
        flow = QuestionFlow(meetingLocale: meetingLocale, sensitivity: effective.sensitivity, speakers: effective.speakers, timing: timing)
        limiter = QuestionLimiter(timing: timing)
        dedup = QuestionDedup(timing: timing)
        manualDedup = QuestionDedup(timing: timing)
        checkQueue = QuestionQueue(capacity: timing.queueCapacity, staleAfter: timing.staleAfter)
        answerQueue = QuestionQueue(capacity: 1, staleAfter: timing.staleAfter)
    }

    public func setEventHandler(_ handler: @escaping @Sendable (LiveAnswerEvent) -> Void) { onEvent = handler }

    /// The toggle in Settings applies at once: off cancels what is in flight and hides the card; on resumes.
    public func update(settings new: LiveAnswerSettings) {
        let wasEnabled = settings.enabled
        settings = new
        let effective = new.effective(lowPowerMode: environment().lowPowerMode)
        flow.sensitivity = effective.sensitivity
        flow.speakers = effective.speakers
        if wasEnabled && !new.enabled {
            cancelEverything(outcome: .stopped, event: true)
            // A pause line is live-answer UI too: it goes with the feature, and a later start reports its pause again.
            lastPause = nil
            onEvent(.paused(nil))
        }
    }

    /// The person asked a question of their own (the Ask tab): the same question is not answered again, and the answer in flight is
    /// the model's to give up (`LLMService.ask` cancels it).
    public func manualQuestionAsked(_ text: String) {
        dedup.remember(text: text, locale: meetingLocale, now: clock())
        manualDedup.remember(text: text, locale: meetingLocale, now: clock())
    }

    /// The person stopped one row ("Finding an answer"): its answer is cancelled (or leaves the line) and closes as stopped. A row
    /// that is not working any more is not touched.
    public func cancel(row: UUID) async {
        if answerRowInFlight == row {
            cancelledRows.insert(row)
            answerInFlight?.cancel()
            return
        }
        if waitingRow == row {
            cancelledRows.insert(row)
            return
        }
        for item in answerQueue.remove(where: { $0.row == row }) { await close(item, outcome: .stopped) }
    }

    // MARK: Input

    /// A final line of the recording (Me or Others).
    public func ingest(_ line: QuestionLine) {
        guard running, settings.enabled, !latchedOff else { return }
        let now = clock()
        counters.lines += 1
        heard.append(line)
        if heard.count > 30 { heard.removeFirst(heard.count - 30) }
        if environment().thermal == .critical {
            latchedOff = true
            cancelEverything(outcome: .stopped, event: true)
            emitPause(.tooWarm)
            return
        }
        // Serious heat pauses new work, and an answer already being written is optional work that stops too.
        if environment().thermal == .serious { cancelAnswerForHeat() }
        // Low Power Mode may come and go during a recording: the cues follow it (the sources follow it per candidate).
        let effective = settings.effective(lowPowerMode: environment().lowPowerMode)
        flow.sensitivity = effective.sensitivity
        flow.speakers = effective.speakers
        if lastPause != nil, !recheckingPause {
            recheckingPause = true
            Task { await self.recheckPause() }
        }
        let settled = flow.ingest(line, now: now)
        counters.candidates = flow.candidates
        scheduleSettle()
        for question in settled { spawnHandle(question) }
    }

    private func scheduleSettle() {
        settleTask?.cancel()
        guard let deadline = flow.nextDeadline else { return }
        let wait = max(0, deadline - clock())
        settleTask = Task { [weak self] in
            await self?.sleeper(wait)
            guard !Task.isCancelled else { return }
            await self?.expire()
        }
    }

    private func expire() {
        guard running else { return }
        for question in flow.expire(now: clock()) { spawnHandle(question) }
        scheduleSettle()
    }

    // MARK: S3, S4

    /// Counted from the moment the question settles, before its task runs, so `isIdle` has no blind spot between the two.
    private func spawnHandle(_ question: SettledQuestion) {
        handling += 1
        Task {
            await self.handle(question)
            self.handling -= 1
        }
    }

    func handle(_ question: SettledQuestion) async {
        guard running, settings.enabled, !latchedOff else { return }
        let started = epoch
        let env = environment()
        let effective = settings.effective(lowPowerMode: env.lowPowerMode)
        if let reason = env.pauseReason(settings: effective) {
            counters.paused += 1
            emitPause(reason)
            if reason == .tooWarm { cancelAnswerForHeat() }
            return
        }
        guard await backend.modelAvailable() else {
            counters.paused += 1
            emitPause(.modelUnavailable)
            return
        }
        emitPause(nil)
        let text = question.candidate.text
        if dedup.isDuplicate(text: text, locale: meetingLocale, now: clock()) {
            counters.duplicates += 1
            return
        }
        // Remembered before the evidence is fetched, so a rephrasing that settles at the same time is not worked on twice (this actor
        // lets another candidate in while the evidence is awaited).
        dedup.remember(text: text, locale: meetingLocale, now: clock())
        // The search model's embedding (about a second of GPU) is spent only on a candidate the check can still reach: when the check
        // budget makes it wait longer than the queue keeps it, it would leave as stale, so the gate uses keywords.
        // The embeddings are also limited in number (`embedMax` in ten minutes): a meeting full of questions cannot keep the GPU busy.
        let embed = limiter.checkWait(now: clock()) <= timing.staleAfter && limiter.embedAllowed(now: clock())
        if !embed { counters.embeddingsSkipped += 1 }
        let evidence = await backend.evidence(text: text, locale: meetingLocale, meetingID: meetingID, segmentID: question.line.segmentID, sources: effective.sources, embed: embed)
        if evidence.queryVector != nil { counters.embeddings += 1; limiter.recordEmbed(now: clock()) }
        // The switch may have gone off (and on again) while the evidence was fetched: a question heard before is not checked after.
        guard mayContinue(epoch: started) else {
            dedup.forget(text: text, locale: meetingLocale)
            return
        }
        guard evidence.passes else {
            dedup.forget(text: text, locale: meetingLocale)
            counters.noEvidence += 1
            return
        }
        // With the search model the question's vector is compared too (a rephrasing shares few words but the same meaning).
        if let vector = evidence.queryVector {
            dedup.forget(text: text, locale: meetingLocale)
            if dedup.isDuplicate(text: text, vector: vector, locale: meetingLocale, now: clock()) {
                counters.duplicates += 1
                return
            }
            dedup.remember(text: text, vector: vector, locale: meetingLocale, now: clock())
        }
        let dropped = checkQueue.push(CheckItem(question: question, evidence: evidence), at: question.arrivedAt)
        counters.queued += 1
        counters.staleQueued += dropped.count
        forget(dropped)
        startCheckWorker()
    }

    /// The cause of a pause may have gone (the transcription caught up, the Mac cooled down, the model is back): the line leaves now
    /// and not at the next question.
    func recheckPause() async {
        defer { recheckingPause = false }
        guard running, lastPause != nil else { return }
        let effective = settings.effective(lowPowerMode: environment().lowPowerMode)
        guard environment().pauseReason(settings: effective) == nil, await backend.modelAvailable() else { return }
        emitPause(nil)
    }

    func emitPause(_ reason: LiveAnswerPause?) {
        guard reason != lastPause else { return }
        lastPause = reason
        onEvent(.paused(reason))
    }
}
