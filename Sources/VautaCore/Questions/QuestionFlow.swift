// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// A candidate that waited for the lines after it (S2) and is ready for the later stages.
public struct SettledQuestion: Sendable, Equatable {
    public let candidate: QuestionCandidate
    /// The line the candidate sentence is in.
    public let line: QuestionLine
    /// The lines said before it (oldest first, at most `linesBefore`), with an earlier phrasing of the same question when the
    /// speaker rephrased it.
    public let before: [QuestionLine]
    /// The lines said after it (at most `linesAfter`).
    public let after: [QuestionLine]
    /// The earlier phrasings this one replaced.
    public let rephrased: [String]
    public let settledAt: Double
    /// The stored segments that make up the question: its line, the one before when the transcriber split it, and the lines of the
    /// phrasings it replaced. Their words are the question, not evidence for its answer.
    public var ownSegments: [Int64] = []
    /// The clock time (the flow's `now`) at which the line arrived.
    public let arrivedAt: Double

    /// Seconds into the meeting where the question ended.
    public var questionEnd: Double { line.end }

    /// The same question with the lines said after it as they are now: the check starts later than the settle (it waits in a queue and
    /// for the rate limit), and an answer given aloud may have come in the meantime. `heard` is every recent line in order; the lines
    /// after the question's own, at most `limit`, replace the ones it settled with when there are more.
    func reading(after heard: [QuestionLine], limit: Int) -> SettledQuestion {
        guard let index = heard.lastIndex(where: { $0.channel == line.channel && $0.start == line.start && $0.text == line.text }) else { return self }
        let later = Array(heard[(index + 1)...].prefix(limit))
        guard later.count > after.count else { return self }
        var copy = SettledQuestion(candidate: candidate, line: line, before: before, after: later, rephrased: rephrased, settledAt: settledAt, arrivedAt: arrivedAt)
        copy.ownSegments = ownSegments
        return copy
    }
}

/// S1 and S2 of the live answers: scores each final line, keeps a candidate until the next lines arrive (or the settle time passes),
/// and hands it on with its context. Pure and driven by explicit times, so the evaluation can replay a meeting on a simulated clock.
public struct QuestionFlow: Sendable {
    private struct Pending {
        var line: QuestionLine
        var candidate: QuestionCandidate
        var before: [QuestionLine]
        var after: [QuestionLine] = []
        var rephrased: [String] = []
        var own: [Int64] = []
        var deadline: Double
        var arrivedAt: Double
    }

    public let timing: QuestionTiming
    public var sensitivity: QuestionSensitivity
    public var speakers: LiveAnswerSpeakers
    public let meetingLocale: String
    private var lastFinal: [Channel: QuestionCues.Previous] = [:]
    private var lastSegment: [Channel: Int64] = [:]
    private var recent: [QuestionLine] = []
    private var pending: [Channel: Pending] = [:]
    /// Counters for the diagnostics (no text): lines seen, candidates, replaced ones.
    public private(set) var seen = 0
    public private(set) var candidates = 0

    public init(meetingLocale: String, sensitivity: QuestionSensitivity = .standard, speakers: LiveAnswerSpeakers = .everyone,
                timing: QuestionTiming = QuestionTiming()) {
        self.meetingLocale = meetingLocale
        self.sensitivity = sensitivity
        self.speakers = speakers
        self.timing = timing
    }

    /// The time of the next settle deadline, if a candidate waits.
    public var nextDeadline: Double? { pending.values.map(\.deadline).min() }

    /// A final line arrived at `now`. Returns the candidates that are ready: those that were waiting for a line.
    public mutating func ingest(_ line: QuestionLine, now: Double) -> [SettledQuestion] {
        seen += 1
        let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let previous = lastFinal[line.channel]
        let previousSegment = lastSegment[line.channel]
        lastFinal[line.channel] = QuestionCues.Previous(text: trimmed, end: line.end)
        lastSegment[line.channel] = line.segmentID
        let before = Array(recent.suffix(timing.linesBefore))
        recent.append(line)
        if recent.count > 12 { recent.removeFirst(recent.count - 12) }

        var found: QuestionCandidate?
        if speakers == .everyone || line.channel == .others,
           let best = QuestionCues.best(text: trimmed, channel: line.channel, start: line.start, end: line.end, previous: previous, meetingLocale: meetingLocale),
           QuestionCues.isCandidate(best, sensitivity: sensitivity) {
            found = best
        }

        var settled: [SettledQuestion] = []
        for channel in Array(pending.keys) {
            guard var waiting = pending[channel] else { continue }
            // The same speaker rephrasing within the settle window: the newer phrasing replaces the older one, which stays as context.
            if channel == line.channel, found != nil { continue }
            waiting.after.append(line)
            // It settles with the lines it is meant to read (`linesAfter`, from either channel) or at its deadline, whichever comes first:
            // an answer that takes two lines ("Hmm, let me think. It was 50k.") is still seen by the check.
            if waiting.after.count >= timing.linesAfter {
                pending[channel] = nil
                settled.append(ready(waiting, now: now))
            } else {
                pending[channel] = waiting
            }
        }
        if let found {
            candidates += 1
            var next = Pending(line: line, candidate: found, before: before, deadline: now + timing.settle, arrivedAt: now)
            next.own = [line.segmentID].compactMap { $0 }
            // The sentence came from two segments: the earlier one is part of the question too.
            if found.utterance != trimmed, let previousSegment { next.own.append(previousSegment) }
            if let old = pending[line.channel] {
                next.before = old.before
                next.rephrased = old.rephrased + [old.candidate.text]
                next.own += old.own
            }
            pending[line.channel] = next
        }
        return settled
    }

    /// Candidates whose settle time has passed.
    public mutating func expire(now: Double) -> [SettledQuestion] {
        let due = pending.filter { $0.value.deadline <= now }
        for channel in due.keys { pending[channel] = nil }
        return due.values.sorted { $0.line.start < $1.line.start }.map { ready($0, now: now) }
    }

    /// The recording stopped: what waits is dropped (counted, never judged).
    public mutating func stop() -> Int {
        defer { pending.removeAll() }
        return pending.count
    }

    private func ready(_ p: Pending, now: Double) -> SettledQuestion {
        SettledQuestion(candidate: p.candidate, line: p.line, before: p.before, after: Array(p.after.prefix(timing.linesAfter)),
                        rephrased: p.rephrased, settledAt: now, ownSegments: p.own, arrivedAt: p.arrivedAt)
    }
}
