// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What a week held, read from the store as it is: no model writes it, so it says exactly what the minutes and tasks say.
/// The week is the calendar's (its first weekday and time zone), so it starts on the day the person's week starts.
public struct WeekDigest: Sendable, Equatable {
    public struct OpenQuestion: Sendable, Equatable {
        public let meetingID: Int64
        public let text: String
    }

    public let week: DateInterval
    /// The meetings recorded in the week, oldest first (not the one being recorded).
    public let meetings: [MeetingStore.Meeting]
    /// The decisions of those meetings, in meeting order; not the ones the minutes ranked out.
    public let decisions: [Decision]
    /// Tasks added in the week (from its meetings or by hand), open or done; not the ones the minutes ranked out.
    public let tasksAdded: [TaskItem]
    /// Tasks marked done in the week.
    public let tasksDone: [TaskItem]
    /// Open tasks whose day is before the day of `now`, the oldest due first. Not tied to the week: what is late now.
    public let tasksOverdue: [TaskItem]
    /// The open questions of the week's minutes.
    public let openQuestions: [OpenQuestion]

    public var isEmpty: Bool {
        meetings.isEmpty && decisions.isEmpty && tasksAdded.isEmpty && tasksDone.isEmpty && tasksOverdue.isEmpty && openQuestions.isEmpty
    }

    /// The title of one of the week's meetings, for an item that came from it.
    public func meetingTitle(_ id: Int64?) -> String? { id.flatMap { id in meetings.first { $0.id == id }?.displayTitle } }
}

extension MeetingStore {
    /// The week that contains `date` in `calendar`, with what is overdue as of `now`.
    public func weekDigest(containing date: Date, calendar: Calendar = .current, now: Date = .now) throws -> WeekDigest {
        let week = calendar.dateInterval(of: .weekOfYear, for: date) ?? DateInterval(start: date, duration: 7 * 86_400)
        let (start, end) = (week.start.timeIntervalSince1970, week.end.timeIntervalSince1970)
        let meetings = try meetings().filter { $0.endedAt != nil && week.contains($0.startedAt) && $0.startedAt < week.end && $0.id != activeMeetingID }
            .sorted { $0.startedAt < $1.startedAt }
        var decisions: [Decision] = []
        var questions: [WeekDigest.OpenQuestion] = []
        for m in meetings {
            decisions += try self.decisions(m.id).filter { !$0.isRankedOut }
            questions += (try card(m.id)?.openQuestions ?? []).map { .init(meetingID: m.id, text: $0) }
        }
        func tasks(_ condition: String, _ order: String) throws -> [TaskItem] {
            try db.query(Self.taskColumns + " WHERE \(condition) ORDER BY \(order)", [.real(start), .real(end)]).map(Self.task).filter { !$0.isRankedOut }
        }
        let added = try tasks("t.created_at >= ?1 AND t.created_at < ?2 AND t.status <> 'dropped'", "t.created_at, t.id")
        let done = try tasks("t.status = 'done' AND t.done_at >= ?1 AND t.done_at < ?2", "t.done_at, t.id")
        let today = DueDay.containing(now, in: calendar.timeZone)
        let overdue = try openTasks().filter { !$0.isRankedOut && ($0.displayDay(in: calendar.timeZone).map { $0 < today } ?? false) }
            .sorted { ($0.displayDay(in: calendar.timeZone)!, $0.id) < ($1.displayDay(in: calendar.timeZone)!, $1.id) }
        return WeekDigest(week: week, meetings: meetings, decisions: decisions, tasksAdded: added, tasksDone: done, tasksOverdue: overdue,
                          openQuestions: questions)
    }
}

extension WeekDigest {
    /// "Week of 26 Oct – 1 Nov 2026", in the language of the app.
    public func title(calendar: Calendar = .current) -> String {
        let last = calendar.date(byAdding: .day, value: -1, to: week.end) ?? week.end
        var style = Date.IntervalFormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = calendar.timeZone
        return String(localized: "Week of \((week.start..<last).formatted(style))",
                      comment: "Title of the This Week view and of its export; the argument is the first and last day of the week, such as 26 Oct – 1 Nov 2026")
    }

    /// The week as Markdown (Export): its title, then a section for each kind of item that has some, each item with the meeting
    /// it came from; tasks as a task list, with their owner and day.
    public func markdown(calendar: Calendar = .current) -> String {
        var out = "# \(title(calendar: calendar))\n"
        func section(_ heading: String, _ lines: [String]) {
            guard !lines.isEmpty else { return }
            out += "\n## \(heading)\n\n" + lines.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        func from(_ text: String, _ meetingID: Int64?) -> String {
            [Markdown.inline(text), meetingTitle(meetingID).map(Markdown.inline)].compactMap { $0 }.joined(separator: " — ")
        }
        func task(_ t: TaskItem) -> String {
            var parts = [Markdown.inline(t.text)]
            if let owner = t.ownerName { parts.append(Markdown.inline(owner)) }
            if let day = t.displayDay(in: calendar.timeZone) {
                parts.append(String(localized: "due \(day.startOfDay(in: calendar.timeZone).formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: calendar.timeZone)))",
                                    comment: "Under a suggestion about a task: the due day of the earlier task"))
            }
            if let meeting = meetingTitle(t.meetingID) ?? t.meetingTitle { parts.append(Markdown.inline(meeting)) }
            return (t.status == .done ? "[x] " : "[ ] ") + parts.joined(separator: " — ")
        }
        var time = Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: calendar.timeZone)
        time.calendar = calendar
        section(String(localized: "Meetings", comment: "Meetings window mode"), meetings.map { "\($0.startedAt.formatted(time)) · \(Markdown.inline($0.displayTitle))" })
        section(String(localized: "Decisions", comment: "Exported minutes: section title"), decisions.map { from($0.text, $0.meetingID) })
        section(String(localized: "Tasks added", comment: "This Week: section of the tasks added in the week, and its title in the export"), tasksAdded.map(task))
        section(String(localized: "Tasks done", comment: "This Week: section of the tasks marked done in the week, and its title in the export"), tasksDone.map(task))
        section(String(localized: "Overdue tasks", comment: "This Week: section of the open tasks whose day has passed, and its title in the export"), tasksOverdue.map(task))
        section(String(localized: "Open questions", comment: "Exported minutes: section title"), openQuestions.map { from($0.text, $0.meetingID) })
        if isEmpty {
            out += "\n" + String(localized: "Nothing was recorded this week.", comment: "This Week: when the week has no meetings and no tasks") + "\n"
        }
        return out
    }
}
