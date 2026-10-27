// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The wording Vauta puts into Reminders and Calendar. It is in the app's language (what the person reads in the other apps), and it
/// never contains transcript text or Vauta identifiers.
enum ActionText {
    static func reminderNote(meeting: String, date: String) -> String {
        String(localized: "From the meeting “\(meeting)”, \(date)", comment: "Notes of a reminder Vauta adds: the first argument is the meeting’s name, the second its date")
    }

    static func reminderNoteWithoutName(date: String) -> String {
        String(localized: "From a meeting on \(date)", comment: "Notes of a reminder Vauta adds when the person left the meeting’s name out; the argument is the meeting’s date")
    }

    static func eventNote(meeting: String, date: String) -> String {
        String(localized: "Follow-up of “\(meeting)”, \(date).", comment: "Notes of a calendar event Vauta adds for a follow-up meeting: the first argument is the meeting’s name, the second its date")
    }

    static func eventNoteWithoutName(date: String) -> String {
        String(localized: "Follow-up of a meeting on \(date).", comment: "Notes of a calendar event Vauta adds for a follow-up meeting when the person left the meeting’s name out; the argument is the meeting’s date")
    }

    static func eventTitle(meeting: String) -> String {
        String(localized: "Follow-up: \(meeting)", comment: "Default title of a calendar event for the next meeting; the argument is the meeting’s name")
    }

    static func date(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.timeZone = timeZone
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }
}

/// Everything about one reminder that is going to be written, before it is written: the editor shows these fields and nothing else
/// reaches Reminders. Pure: no EventKit, no store.
public struct ReminderDraft: Sendable, Equatable {
    public static let titleLimit = 300
    /// The alert's wall-clock time when the setting is on: 09:00, floating.
    public static let defaultAlertMinute = 9 * 60

    public var title: String
    public var containerID: String
    public var dueDay: DueDay?
    /// nil = no alert (the default). Only used when there is a due day.
    public var alertMinuteOfDay: Int?
    public var notes: String?
    /// The task's own words without the owner's name in front: a reminder the person already made for it has no prefix, so the
    /// duplicate checks look for this title too.
    public var plainTitle: String?
    /// The task's stored due day when it looks wrong (before the meeting, or more than a year after it) and was left out of the draft:
    /// the editor says so.
    public var skippedDueDay: DueDay?

    public init(title: String, containerID: String, dueDay: DueDay?, alertMinuteOfDay: Int? = nil, notes: String? = nil, plainTitle: String? = nil,
                skippedDueDay: DueDay? = nil) {
        self.title = title
        self.containerID = containerID
        self.dueDay = dueDay
        self.alertMinuteOfDay = alertMinuteOfDay
        self.notes = notes
        self.plainTitle = plainTitle
        self.skippedDueDay = skippedDueDay
    }

    /// The titles an existing reminder may carry for this task: the written one, and the task's own words.
    var searchTitles: [String] {
        let written = write().title
        guard let plain = plainTitle.map({ TextSanitizer.oneLine($0, limit: Self.titleLimit) }), !plain.isEmpty, plain != written else { return [written] }
        return [written, plain]
    }

    var searchHashes: [String] { searchTitles.map(ActionTitle.hash) }

    /// The draft of a task. A task owned by someone else gets "Name: " in front (D6); the person's own and ownerless ones keep their
    /// text. A speaker nobody named is not a name and gets no prefix. `selfEntityID` is the person's own entity.
    public static func make(task: TaskItem, selfEntityID: Int64?, containerID: String, alertMinuteOfDay: Int? = nil,
                            meetingTitle: String?, meetingDate: Date?, meetingTimeZone: TimeZone = .current, includeMeetingName: Bool = true) -> ReminderDraft {
        var notes: String?
        if let meetingDate {
            let date = ActionText.date(meetingDate, timeZone: meetingTimeZone)
            if includeMeetingName, let meetingTitle, !meetingTitle.isEmpty {
                notes = ActionText.reminderNote(meeting: TextSanitizer.oneLine(meetingTitle, limit: 200), date: date)
            } else {
                notes = ActionText.reminderNoteWithoutName(date: date)
            }
        }
        let (due, skipped) = dueDay(of: task, meetingDate: meetingDate, meetingTimeZone: meetingTimeZone)
        return ReminderDraft(title: title(for: task, selfEntityID: selfEntityID), containerID: containerID, dueDay: due,
                             alertMinuteOfDay: due == nil ? nil : alertMinuteOfDay, notes: notes, plainTitle: task.text, skippedDueDay: skipped)
    }

    /// The due day a reminder gets from a task: its stored day, or none (`skipped`) when that day is before the meeting or more than a year
    /// after it. The Follow-up sheet's rows use this too, so a row shows what the batch will write.
    public static func dueDay(of task: TaskItem, meetingDate: Date?, meetingTimeZone: TimeZone = .current) -> (use: DueDay?, skipped: DueDay?) {
        guard let day = task.dueDay else { return (nil, nil) }
        if let meetingDate, !day.isPlausible(meetingDay: DueDay.containing(meetingDate, in: meetingTimeZone)) { return (nil, day) }
        return (day, nil)
    }

    public static func title(for task: TaskItem, selfEntityID: Int64?) -> String {
        var prefix = ""
        if let owner = task.ownerID, owner != selfEntityID, let name = task.ownerName {
            let clean = TextSanitizer.oneLine(name, limit: 60)
            if !clean.isEmpty { prefix = clean + ": " }
        }
        let room = max(1, titleLimit - prefix.count)
        return prefix + TextSanitizer.oneLine(task.text, limit: room)
    }

    /// What the writer receives. The due date is the day's year, month and day with no time zone; an alert adds the wall-clock hour and
    /// minute, still floating, plus one alarm at that time. The title is re-cleaned: whatever the editor holds, one line of at most 300.
    public func write() -> ReminderWrite {
        let due: DateComponents? = dueDay.map { day in alertMinuteOfDay.map { day.floatingComponents(minuteOfDay: $0) } ?? day.floatingComponents }
        return ReminderWrite(title: TextSanitizer.oneLine(title, limit: Self.titleLimit), containerID: containerID, due: due,
                             alert: dueDay != nil && alertMinuteOfDay != nil, notes: notes.flatMap { $0.isEmpty ? nil : TextSanitizer.oneLine($0, limit: 500) })
    }

    /// The hash the ledger keeps for this reminder (the written title, normalized).
    public var titleHash: String { ActionTitle.hash(write().title) }
}

/// One follow-up event before it is written.
public struct EventDraft: Sendable, Equatable {
    public var title: String
    public var containerID: String
    public var day: DueDay
    /// nil = all day.
    public var minuteOfDay: Int?
    public var durationMinutes: Int
    public var timeZone: TimeZone
    public var notes: String?

    public init(title: String, containerID: String, day: DueDay, minuteOfDay: Int?, durationMinutes: Int, timeZone: TimeZone, notes: String? = nil) {
        self.title = title
        self.containerID = containerID
        self.day = day
        self.minuteOfDay = minuteOfDay
        self.durationMinutes = durationMinutes
        self.timeZone = timeZone
        self.notes = notes
    }

    /// The meeting's duration rounded to 15 minutes, between 15 and 60; otherwise 30.
    public static func duration(ofMeeting seconds: TimeInterval?) -> Int {
        guard let seconds, seconds > 0 else { return 30 }
        let rounded = Int((seconds / 900).rounded()) * 15
        return (15...60).contains(rounded) ? rounded : 30
    }

    public static func make(from followUp: FollowUp, containerID: String, meetingTitle: String, meetingDate: Date, meetingDuration: TimeInterval?,
                            timeZone: TimeZone, includeAttendeeNames: Bool = false, attendeeNames: [String] = [], includeMeetingName: Bool = true) -> EventDraft? {
        guard let day = followUp.day else { return nil }
        return make(title: followUp.title, day: day, minuteOfDay: followUp.minuteOfDay, durationMinutes: followUp.durationMinutes ?? duration(ofMeeting: meetingDuration),
                    containerID: containerID, meetingTitle: meetingTitle, meetingDate: meetingDate, timeZone: timeZone,
                    includeAttendeeNames: includeAttendeeNames, attendeeNames: attendeeNames, includeMeetingName: includeMeetingName)
    }

    /// The draft for any event the editor holds (a detected follow-up or a new one): the title falls back to "Follow-up: <meeting>", the
    /// notes name the meeting (unless the person left its name out) and its date, and attendee names are added only when asked.
    public static func make(title: String, day: DueDay, minuteOfDay: Int?, durationMinutes: Int, containerID: String, meetingTitle: String, meetingDate: Date,
                            timeZone: TimeZone, includeAttendeeNames: Bool = false, attendeeNames: [String] = [], includeMeetingName: Bool = true) -> EventDraft {
        let when = ActionText.date(meetingDate, timeZone: timeZone)
        var notes = includeMeetingName ? ActionText.eventNote(meeting: TextSanitizer.oneLine(meetingTitle, limit: 200), date: when)
                                       : ActionText.eventNoteWithoutName(date: when)
        if includeAttendeeNames, !attendeeNames.isEmpty {
            notes += "\n" + attendeeNames.map { TextSanitizer.oneLine($0, limit: 80) }.joined(separator: ", ")
        }
        return EventDraft(title: title.isEmpty ? ActionText.eventTitle(meeting: meetingTitle) : title, containerID: containerID, day: day,
                          minuteOfDay: minuteOfDay, durationMinutes: durationMinutes, timeZone: timeZone, notes: notes)
    }

    /// "Follow-up: <meeting>", the title a new event starts with.
    public static func defaultTitle(meeting: String) -> String { ActionText.eventTitle(meeting: TextSanitizer.oneLine(meeting, limit: 200)) }

    public func write() -> EventWrite {
        EventWrite(title: TextSanitizer.oneLine(title, limit: 300), containerID: containerID, day: day, minuteOfDay: minuteOfDay,
                   durationMinutes: durationMinutes, timeZone: timeZone, notes: notes.flatMap { $0.isEmpty ? nil : String($0.prefix(1_000)) })
    }

    public var titleHash: String { ActionTitle.hash(write().title) }

    /// The start and end as moments (for an event with a time).
    public var interval: DateInterval? {
        guard let minuteOfDay else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let start = calendar.date(from: day.floatingComponents(minuteOfDay: minuteOfDay)) else { return nil }
        return DateInterval(start: start, duration: Double(durationMinutes) * 60)
    }
}

/// The order of the Follow-up sheet's reminders: the person's own tasks first, then tasks with no owner, then by owner name.
public enum ActionOrdering {
    public static func sheetOrder(_ tasks: [TaskItem], selfEntityID: Int64?) -> [TaskItem] {
        func rank(_ t: TaskItem) -> Int {
            if let owner = t.ownerID, owner == selfEntityID { return 0 }
            return t.ownerID == nil && t.ownerSpeakerID == nil ? 1 : 2
        }
        return tasks.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            if rank(x) != rank(y) { return rank(x) < rank(y) }
            if rank(x) == 2 {
                let c = (x.ownerName ?? "").localizedStandardCompare(y.ownerName ?? "")
                if c != .orderedSame { return c == .orderedAscending }
            }
            return a.offset < b.offset
        }.map(\.element)
    }
}
