// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// A next meeting found in a meeting, before the person looks at it.
public struct FollowUpCandidate: Sendable, Equatable {
    public var segmentID: Int64?
    public var t: Double?
    public var title: String
    public var day: DueDay?
    public var dayInferred: Bool
    public var minuteOfDay: Int?
    public var durationMinutes: Int?
    /// The words of the passage the candidate comes from, for the sheet ("from 41:05 …"). Not stored.
    public var quote: String

    public init(segmentID: Int64?, t: Double?, title: String, day: DueDay?, dayInferred: Bool, minuteOfDay: Int?, durationMinutes: Int?, quote: String) {
        self.segmentID = segmentID
        self.t = t
        self.title = title
        self.day = day
        self.dayInferred = dayInferred
        self.minuteOfDay = minuteOfDay
        self.durationMinutes = durationMinutes
        self.quote = quote
    }
}

/// What the detector reads: the transcript's lines, the segments the minutes cite, the tasks, and where and when the meeting happened.
public struct FollowUpInput: Sendable {
    public struct Line: Sendable, Equatable {
        public var id: Int64
        public var start: Double
        public var end: Double
        public var text: String
        public init(id: Int64, start: Double, end: Double, text: String) {
            self.id = id
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public struct TaskLine: Sendable, Equatable {
        public var segmentID: Int64?
        public var text: String
        public var dueDay: DueDay?
        /// The task is marked "to be confirmed" (its due day may be one the model worked out, not one the words say).
        public var unconfirmed: Bool
        public init(segmentID: Int64?, text: String, dueDay: DueDay?, unconfirmed: Bool = false) {
            self.segmentID = segmentID
            self.text = text
            self.dueDay = dueDay
            self.unconfirmed = unconfirmed
        }
    }

    public var lines: [Line]
    /// Segments cited by a decision or a task.
    public var citedSegments: Set<Int64>
    public var tasks: [TaskLine]
    public var meetingStart: Date
    public var timeZone: TimeZone
    /// The language of the meeting (BCP-47), for the order of numeric dates.
    public var locale: String?
    public var meetingTitle: String
    public var meetingDuration: TimeInterval?

    public init(lines: [Line], citedSegments: Set<Int64>, tasks: [TaskLine] = [], meetingStart: Date, timeZone: TimeZone, locale: String? = nil,
                meetingTitle: String = "", meetingDuration: TimeInterval? = nil) {
        self.lines = lines
        self.citedSegments = citedSegments
        self.tasks = tasks
        self.meetingStart = meetingStart
        self.timeZone = timeZone
        self.locale = locale
        self.meetingTitle = meetingTitle
        self.meetingDuration = meetingDuration
    }
}

/// Finds the next meetings people agreed on, with fixed rules: no model, so it behaves the same on every setup and can be tested.
///
/// After the minutes succeed, for each segment that a decision or a task cites and for the last tenth of the transcript:
/// 1. the segment holds a cue ("let's meet again", "next meeting", "nos vemos"…), and
/// 2. the same or the next segment (within 20 s) says a day, and
/// 3. the day is resolved from the meeting's own calendar day in the meeting's time zone (`FollowUpDateResolver`).
///
/// A cue with no day is dropped. Candidates on the same day merge, and at most two are kept. A task that is itself the scheduling of a
/// follow-up ("Schedule the follow-up call") with a plausible due day becomes a candidate on that day, time not said, unless the task is
/// marked "to be confirmed" and its cited passage does not say that day (the day is then not known to have been said).
public enum FollowUpDetector {
    /// Whether the passage a task cites, or the next one when it follows closely, says `due` as a day (not worked out by the model) in a
    /// clause that is not a question or a hedge.
    static func saysDay(_ due: DueDay, task: FollowUpInput.TaskLine, lines: [FollowUpInput.Line], meetingDay: DueDay, order: FollowUpDateResolver.DateOrder) -> Bool {
        guard let id = task.segmentID, let i = lines.firstIndex(where: { $0.id == id }) else { return false }
        var window = [lines[i]]
        if i + 1 < lines.count, lines[i + 1].start - lines[i].end <= nextSegmentGap { window.append(lines[i + 1]) }
        return window.contains { line in
            ItemCues.clauses(line.text).contains { clause in
                FollowUpDateResolver.day(in: clause, meetingDay: meetingDay, order: order)?.day == due && !ItemCues.isQuestion(clause) && !ItemCues.hedged(clause)
            }
        }
    }

    /// Bumped when the rules change, so a stored result says which rules made it.
    public static let recipe = 2
    public static let maximumPerMeeting = 2
    /// How long after one segment the next may start and still count as "the next words".
    static let nextSegmentGap = 20.0

    public static func detect(_ input: FollowUpInput) -> [FollowUpCandidate] {
        let lines = input.lines
        guard !lines.isEmpty else { return [] }
        let meetingDay = DueDay.containing(input.meetingStart, in: input.timeZone)
        let order = FollowUpDateResolver.order(forLocale: input.locale)
        let tail = max(1, Int((Double(lines.count) * 0.1).rounded(.up)))
        let tailStart = lines.count - tail
        var found: [(candidate: FollowUpCandidate, strength: Int, index: Int)] = []

        for (i, line) in lines.enumerated() where input.citedSegments.contains(line.id) || i >= tailStart {
            guard FollowUpWords.hasCue(TextKeys.norm(line.text)) else { continue }
            // The day in this segment, else in the next one if it follows closely.
            var window = [line]
            if i + 1 < lines.count, lines[i + 1].start - line.end <= nextSegmentGap { window.append(lines[i + 1]) }
            for source in window {
                guard let day = FollowUpDateResolver.day(in: source.text, meetingDay: meetingDay, order: order) else { continue }
                // The time comes from the words of the segment that said the day; the other segment's only when it says no day of its own
                // (a time next to another day is that day's: "8:45" belongs to "next Wednesday", not to "the 18th").
                let time = ([source] + window.filter { other in
                    guard other.id != source.id else { return false }
                    let otherDay = FollowUpDateResolver.day(in: other.text, meetingDay: meetingDay, order: order)
                    return otherDay == nil || otherDay?.day == day.day
                })
                    .lazy.compactMap { FollowUpDateResolver.minuteOfDay(in: $0.text) }.first
                let quote = source.id == line.id ? line.text : line.text + " " + source.text
                let candidate = FollowUpCandidate(segmentID: line.id, t: line.start, title: ActionText.eventTitle(meeting: input.meetingTitle), day: day.day,
                                                  dayInferred: day.inferred, minuteOfDay: time, durationMinutes: EventDraft.duration(ofMeeting: input.meetingDuration),
                                                  quote: TextSanitizer.oneLine(quote, limit: 240))
                found.append((candidate, (day.inferred ? 0 : 2) + (time != nil ? 1 : 0), i))
                break
            }
        }

        for task in input.tasks {
            // A task "to be confirmed" may be so because the model worked its day out ("let's meet again soon" with a date), because the words
            // ask or hedge ("should we meet on Friday?", "maybe Tuesday"), or only because the ranking of Apple's items left it out of the main
            // ones; the stored task does not say which. It counts when the words of its cited passage (or the next one, if it follows
            // closely) say that very day in a clause that neither asks nor hedges.
            guard let due = task.dueDay, due > meetingDay, due.isPlausible(meetingDay: meetingDay),
                  FollowUpWords.hasCue(TextKeys.norm(task.text)),
                  !task.unconfirmed || saysDay(due, task: task, lines: lines, meetingDay: meetingDay, order: order) else { continue }
            let line = lines.first { $0.id == task.segmentID }
            let candidate = FollowUpCandidate(segmentID: task.segmentID, t: line?.start, title: ActionText.eventTitle(meeting: input.meetingTitle), day: due,
                                              dayInferred: false, minuteOfDay: nil, durationMinutes: EventDraft.duration(ofMeeting: input.meetingDuration),
                                              quote: TextSanitizer.oneLine(task.text, limit: 240))
            found.append((candidate, 0, line.flatMap { l in lines.firstIndex { $0.id == l.id } } ?? lines.count))
        }

        // One candidate per day: the one with the time, else the said day, else the later one.
        var perDay: [DueDay: (candidate: FollowUpCandidate, strength: Int, index: Int)] = [:]
        for entry in found {
            guard let day = entry.candidate.day else { continue }
            if let existing = perDay[day] {
                var best = existing.strength >= entry.strength ? existing : entry
                if best.candidate.minuteOfDay == nil, let time = (existing.candidate.minuteOfDay ?? entry.candidate.minuteOfDay) { best.candidate.minuteOfDay = time }
                perDay[day] = best
            } else {
                perDay[day] = entry
            }
        }
        let merged = perDay.values.sorted { a, b in
            if a.strength != b.strength { return a.strength > b.strength }
            return a.index > b.index   // the later passage is the one that settled it
        }.prefix(maximumPerMeeting)
        return merged.map(\.candidate).sorted { ($0.day ?? meetingDay) < ($1.day ?? meetingDay) }
    }
}

extension MeetingStore {
    /// Detects the follow-up meetings of a meeting from its stored transcript, tasks and decisions, and stores them as suggestions.
    /// Nothing is detected while the meeting is being recorded. Returns the candidates (also for the evaluation).
    @discardableResult
    public func detectFollowUps(_ meetingID: Int64) async throws -> [FollowUpCandidate] {
        guard activeMeetingID != meetingID, let meeting = try meeting(meetingID) else { return [] }
        let segments = try segments(of: meetingID)
        let tasks = try tasks(meetingID)
        let cited = Set(try decisions(meetingID).compactMap(\.segmentID) + tasks.compactMap(\.segmentID))
        let zone = try meetingTimeZone(meetingID) ?? .current
        let input = FollowUpInput(lines: segments.map { .init(id: $0.id, start: $0.start, end: $0.end, text: $0.text) }, citedSegments: cited,
                                  tasks: tasks.map { .init(segmentID: $0.segmentID, text: $0.text, dueDay: $0.dueDay, unconfirmed: $0.unconfirmed) }, meetingStart: meeting.startedAt,
                                  timeZone: zone, locale: meeting.minutesLocale.identifier, meetingTitle: meeting.displayTitle,
                                  meetingDuration: meeting.endedAt.map { $0.timeIntervalSince(meeting.startedAt) })
        let candidates = FollowUpDetector.detect(input)
        try await storeDetectedFollowUps(candidates, meetingID: meetingID)
        return candidates
    }

    /// After the person changed the transcript (a line corrected, or a correction undone), the follow-up meetings are looked for
    /// again, if they had been: a corrected "Tuesday" is a Tuesday no longer. What the person dismissed or acted on stays
    /// (`storeDetectedFollowUps`). Returns whether it looked.
    @discardableResult
    public func redetectFollowUps(_ meetingID: Int64) async throws -> Bool {
        guard ActionsRelease.followUpDetection, activeMeetingID != meetingID, try followUpsRecipe(meetingID) != 0 else { return false }
        try await detectFollowUps(meetingID)
        return true
    }
}
