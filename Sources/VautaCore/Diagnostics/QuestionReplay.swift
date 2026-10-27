// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Replays the final lines of a public transcript through the live-answer pipeline on a simulated clock (EVALUATION ONLY, used by
/// `llm-eval --tasks live-questions`). Lines arrive when they end; the model calls are real and their measured duration is added to
/// the simulated time, one at a time as the lane runs them. The rate limits, the settle time and the staleness use the simulated
/// clock. Nothing here touches the app, the user's store or a network.
public enum QuestionReplay {
    public struct Line: Sendable {
        public var id: Int64
        public var start: Double
        public var end: Double
        public var channel: Channel
        public var text: String
        /// The text stored in the scratch meeting (with the speaker's label, as the Ask evaluation stores it).
        public var stored: String

        public init(id: Int64, start: Double, end: Double, channel: Channel = .others, text: String, stored: String? = nil) {
            self.id = id
            self.start = start
            self.end = end
            self.channel = channel
            self.text = text
            self.stored = stored ?? text
        }
    }

    public struct Options: Sendable {
        public var settings: LiveAnswerSettings = { var on = LiveAnswerSettings(); on.enabled = true; return on }()
        public var timing = QuestionTiming()
        /// V0 of the design: no model check; the candidates that pass the evidence gate go straight to the answer.
        public var skipCheck = false
        /// No model at all: S1 and S4 only.
        public var detectOnly = false
        public var environment = LiveAnswerEnvironment()
        public var meetingLocale = "en-US"
        /// The integrated model reads the meeting every ~600 characters, as in the app (the replay calls `warmRead`).
        public var warmRead: (@Sendable () async -> Void)?
        /// false: the lines are stored and `warmRead` runs, but no stage of the detection does (the measurement without detection).
        public var detection = true
        /// Run once after the last line (a probe of the warm model's first token).
        public var closingProbe: (@Sendable () async -> Void)?
        /// Called before each line with the simulated time at which it arrives (a real-time replay waits here for the wall clock).
        public var pace: (@Sendable (Double) async -> Void)?
        public init() {}
    }

    /// One candidate sentence and what became of it. Text of public transcripts only.
    public struct Record: Codable, Sendable {
        public var line: Int64
        public var channel: String
        public var t: Double
        public var end: Double
        public var text: String
        public var score: Double
        public var cues: [String]
        /// `duplicate`, `no_evidence`, `stale_queue`, `check_failed`, `check_timeout`, `not_information`, `answered_aloud`, `no_answer`, `answered`,
        /// `rate_limited`, `stale`, `superseded`, `failed`, `paused`, `unavailable`.
        public var outcome: String
        public var evidenceSources: [String] = []
        public var evidenceMatches: [String: Int] = [:]
        public var evidenceSeconds: Double = 0
        public var checkKind: String?
        public var rewrite: String?
        public var answeredAloud: Bool?
        public var checkSeconds: Double = 0
        public var answerSeconds: Double = 0
        public var answer: String?
        public var sources: [String] = []
        public var cited: [Int64] = []
        public var shown = false
        /// Simulated seconds from the end of the question to the card.
        public var latencySeconds: Double?
        public var queueSeconds: Double = 0
    }

    struct Item: Sendable {
        var settled: SettledQuestion
        var score: Double
        var cues: [String]
        var arrival: Double
    }

    /// Runs one meeting. `backend` nil with `detectOnly` uses no model. The scratch store must hold the meeting's lines as they are
    /// appended here (`appendLine` stores one and returns its row id).
    public static func run(lines: [Line], meetingID: Int64, options: Options, backend: (any LiveAnswerBackend)?,
                           appendLine: (Line) async throws -> Int64, citedMap: @Sendable (Int64) -> Int64? = { $0 }) async throws -> [Record] {
        var records: [Record] = []
        let effective = options.settings.effective(lowPowerMode: options.environment.lowPowerMode)
        var flow = QuestionFlow(meetingLocale: options.meetingLocale, sensitivity: effective.sensitivity, speakers: effective.speakers, timing: options.timing)
        var limiter = QuestionLimiter(timing: options.timing)
        var dedup = QuestionDedup(timing: options.timing)
        var queue = QuestionQueue<Item>(capacity: options.timing.queueCapacity, staleAfter: options.timing.staleAfter)
        var workerFree = 0.0
        var rowOf: [Int64: Int64] = [:]
        var charsSinceRead = 0

        func scoreOf(_ q: SettledQuestion) -> (Double, [String]) { (q.candidate.score, q.candidate.cues) }

        func enqueue(_ settled: [SettledQuestion]) {
            for q in settled {
                let (score, cues) = scoreOf(q)
                let dropped = queue.push(Item(settled: q, score: score, cues: cues, arrival: q.arrivedAt), at: q.settledAt)
                for old in dropped { records.append(base(old, outcome: "stale_queue")) }
            }
        }

        func base(_ item: Item, outcome: String) -> Record {
            Record(line: item.settled.line.segmentID.flatMap { rowLine[$0] } ?? 0, channel: item.settled.line.channel.rawValue, t: item.settled.line.start,
                   end: item.settled.line.end, text: item.settled.candidate.text, score: item.score, cues: item.cues, outcome: outcome)
        }
        var rowLine: [Int64: Int64] = [:]

        /// The lane works through the queue until simulated time `limit`.
        func service(until limit: Double, final: Bool = false) async {
            while true {
                let start = max(workerFree, queue.isEmpty ? limit : (queueFirstArrival(queue) ?? limit))
                if !final, start > limit { return }
                let (item, stale) = queue.pop(now: start)
                for old in stale { records.append(base(old, outcome: "stale_queue")) }
                guard let item else { return }
                var record = base(item, outcome: "paused")
                var t = start
                record.queueSeconds = max(0, t - item.settled.settledAt)
                let question = item.settled
                let env = options.environment
                if let reason = env.pauseReason(settings: effective) { record.outcome = reason == .noSources ? "no_sources" : "paused"; records.append(record); continue }
                if dedup.isDuplicate(text: question.candidate.text, locale: options.meetingLocale, now: t) { record.outcome = "duplicate"; records.append(record); continue }
                guard let backend else { record.outcome = "unavailable"; records.append(record); continue }
                let e0 = Date()
                let evidence = await backend.evidence(text: question.candidate.text, locale: options.meetingLocale, meetingID: meetingID,
                                                      segmentID: question.line.segmentID, sources: effective.sources,
                                                      embed: limiter.checkWait(now: t) <= options.timing.staleAfter && limiter.embedAllowed(now: t))
                record.evidenceSeconds = Date().timeIntervalSince(e0)
                if evidence.queryVector != nil { limiter.recordEmbed(now: t) }
                t += record.evidenceSeconds
                record.evidenceSources = names(evidence.passing)
                record.evidenceMatches = evidence.matches
                guard evidence.passes else { record.outcome = "no_evidence"; records.append(record); workerFree = t; continue }
                if options.detectOnly { record.outcome = "evidence"; records.append(record); workerFree = t; continue }
                // The check is rate limited: wait on the simulated clock.
                let wait = limiter.checkWait(now: t)
                if wait > 0 { t += wait }
                if t - item.settled.settledAt > options.timing.staleAfter { record.outcome = "stale_queue"; records.append(record); workerFree = t; continue }
                var rewrite = question.candidate.text
                var proceeds = true
                if !options.skipCheck {
                    limiter.recordCheck(now: t)
                    let c0 = Date()
                    // The lines that came in while the question waited are read too (as the detector does).
                    let arrived = lines.filter { $0.end <= t }.compactMap { l in rowOf[l.id].map { QuestionLine(segmentID: $0, channel: l.channel, start: l.start, end: l.end, text: l.text) } }
                    let result = await backend.check(question.reading(after: arrived, limit: options.timing.checkLinesAfter), meetingID: meetingID)
                    record.checkSeconds = Date().timeIntervalSince(c0)
                    t += record.checkSeconds
                    switch result {
                    case .unavailable: record.outcome = "unavailable"; records.append(record); workerFree = t; continue
                    case .failed: record.outcome = "check_failed"; records.append(record); workerFree = t; continue
                    case .timedOut: record.outcome = "check_timeout"; records.append(record); workerFree = t; continue
                    case .checked(let check):
                        record.checkKind = check.kind.rawValue
                        record.rewrite = check.question
                        record.answeredAloud = check.answeredAloud
                        proceeds = check.proceeds(hideWhenAnsweredAloud: effective.hideWhenAnsweredAloud)
                        if check.kind != .information || check.question.isEmpty { record.outcome = "not_information"; records.append(record); workerFree = t; continue }
                        if !proceeds { record.outcome = "answered_aloud"; records.append(record); workerFree = t; continue }
                        rewrite = check.question
                    }
                }
                dedup.remember(text: question.candidate.text, locale: options.meetingLocale, now: t)
                guard let segmentID = question.line.segmentID else { record.outcome = "failed"; records.append(record); workerFree = t; continue }
                let a0 = Date()
                let extras = await backend.usesIntegratedModel() ? evidence.best != .thisMeeting : true
                let request = AutoAskRequest(segmentID: segmentID, questionSegments: Set(question.ownSegments), sources: effective.sources, thisMeetingPassages: evidence.thisMeeting,
                                             pastPassages: evidence.past, documentPassages: evidence.documents, includeExtras: extras,
                                             heard: [question.candidate.text, question.line.text] + question.rephrased, locale: options.meetingLocale)
                do {
                    let outcome = try await backend.answer(rewrite, meetingID: meetingID, request: request)
                    record.answerSeconds = Date().timeIntervalSince(a0)
                    t += record.answerSeconds
                    switch outcome {
                    case .noAnswer: record.outcome = "no_answer"
                    case .superseded: record.outcome = "superseded"
                    case .answered(let content):
                        let age = t - item.arrival
                        let cardWait = limiter.cardWait(now: t, lowPowerMode: env.lowPowerMode)
                        if QuestionStaleness.classify(age: age, timing: options.timing) == .dropped { record.outcome = "stale" }
                        else if cardWait > options.timing.cardWaitMax { record.outcome = "rate_limited" }
                        else {
                            t += cardWait
                            limiter.recordCard(now: t)
                            record.outcome = "answered"
                            record.shown = true
                            record.latencySeconds = t - question.line.end
                        }
                        record.answer = content.answer
                        record.sources = content.labels.map { $0.kind.rawValue }
                        // This meeting's lines by their transcript id; a citation of another meeting or a document is the negated row id.
                        record.cited = content.claims.flatMap(\.cites).compactMap(\.segmentID).compactMap { rowLine[$0] ?? citedMap(-$0) }
                    }
                } catch {
                    record.answerSeconds = Date().timeIntervalSince(a0)
                    t += record.answerSeconds
                    record.outcome = "failed"
                }
                records.append(record)
                workerFree = t
            }
        }

        func queueFirstArrival(_ q: QuestionQueue<Item>) -> Double? { q.firstArrival }

        for line in lines {
            // Candidates whose settle time passed before this line arrived are ready first.
            while let deadline = flow.nextDeadline, deadline <= line.end { enqueue(flow.expire(now: deadline)); await service(until: deadline) }
            if let pace = options.pace { await pace(line.end) }
            let row = try await appendLine(line)
            rowOf[line.id] = row
            rowLine[row] = line.id
            charsSinceRead += line.text.count
            if charsSinceRead >= 600, let read = options.warmRead { charsSinceRead = 0; await read() }
            guard options.detection else { continue }
            let ql = QuestionLine(segmentID: row, channel: line.channel, start: line.start, end: line.end, text: line.text)
            enqueue(flow.ingest(ql, now: line.end))
            await service(until: line.end)
        }
        while let deadline = flow.nextDeadline { enqueue(flow.expire(now: deadline)) }
        await service(until: .infinity, final: true)
        if let probe = options.closingProbe { await probe() }
        return records
    }

    static func names(_ sources: LiveAnswerSources) -> [String] {
        var out: [String] = []
        if sources.contains(.thisMeeting) { out.append("thisMeeting") }
        if sources.contains(.pastMeetings) { out.append("pastMeetings") }
        if sources.contains(.documents) { out.append("documents") }
        return out
    }
}

extension QuestionQueue {
    /// The arrival time of the oldest entry.
    var firstArrival: Double? { peekAt }
}
